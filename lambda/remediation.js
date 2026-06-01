'use strict';
/**
 * TechStream — Self-Healing Lambda (Node.js)
 * Triggered by EventBridge when a CloudWatch Alarm fires.
 *
 * Remediation steps (in order):
 *   1. Restart the app service on the EC2 instance via SSM Run Command
 *   2. If restart fails → reboot the EC2 instance entirely
 *   3. Publish a remediation metric and SNS notification for audit trail
 */

const { SSMClient, SendCommandCommand, ListCommandInvocationsCommand } = require('@aws-sdk/client-ssm');
const { EC2Client, DescribeInstancesCommand, RebootInstancesCommand } = require('@aws-sdk/client-ec2');
const { CloudWatchClient, PutMetricDataCommand } = require('@aws-sdk/client-cloudwatch');
const { SNSClient, PublishCommand } = require('@aws-sdk/client-sns');

// ── Config from environment variables ─────────────────────────────────────────
const INSTANCE_ID   = process.env.INSTANCE_ID   || '';
const SNS_TOPIC_ARN = process.env.SNS_TOPIC_ARN || '';
const REGION        = process.env.AWS_REGION    || 'us-east-1';
const SSM_DOCUMENT  = process.env.SSM_DOCUMENT  || 'AWS-RunShellScript';
const APP_SERVICE   = process.env.APP_SERVICE   || 'techstream-app';
const NAMESPACE     = process.env.CW_NAMESPACE  || 'TechStream/App';

const cfg = { region: REGION };
const ssm = new SSMClient(cfg);
const ec2 = new EC2Client(cfg);
const cw  = new CloudWatchClient(cfg);
const sns = new SNSClient(cfg);

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// ── Main entry point ──────────────────────────────────────────────────────────
exports.handler = async (event) => {
  console.info('Remediation triggered. Event:', JSON.stringify(event));

  const alarmName  = extractAlarmName(event);
  const alarmState = extractAlarmState(event);
  const timestamp  = new Date().toISOString();

  if (alarmState === 'OK') {
    console.info('Alarm returned to OK — no remediation needed');
    return { status: 'no_action', reason: 'alarm_resolved' };
  }

  if (!INSTANCE_ID) {
    console.error('INSTANCE_ID env var is not set');
    return { status: 'error', reason: 'missing_instance_id' };
  }

  console.warn(`Alarm '${alarmName}' is ALARM — starting remediation on ${INSTANCE_ID}`);

  const result = { alarm: alarmName, timestamp, instance: INSTANCE_ID, steps: [] };

  // ── Step 1: SSM service restart ───────────────────────────────────────────
  const ssmSuccess = await restartViaSSM(INSTANCE_ID);
  result.steps.push({ action: 'ssm_restart', success: ssmSuccess });

  if (ssmSuccess) {
    console.info('SSM restart succeeded — waiting 30s to verify recovery');
    await sleep(30_000);
    if (await verifyInstanceRunning(INSTANCE_ID)) {
      console.info('Instance healthy after SSM restart');
      result.outcome = 'self_healed_via_restart';
      await publishMetric('RemediationSuccess', 1);
      await notifyTeam(result, true);
      return result;
    }
    console.warn('Instance unhealthy after restart — escalating to reboot');
  }

  // ── Step 2: EC2 reboot ────────────────────────────────────────────────────
  console.info('Attempting EC2 instance reboot...');
  const rebootSuccess = await rebootInstance(INSTANCE_ID);
  result.steps.push({ action: 'ec2_reboot', success: rebootSuccess });

  if (rebootSuccess) {
    result.outcome = 'self_healed_via_reboot';
    await publishMetric('RemediationSuccess', 1);
  } else {
    result.outcome = 'remediation_failed_page_engineer';
    await publishMetric('RemediationFailure', 1);
    console.error('All remediation steps failed — engineer must be paged');
  }

  await notifyTeam(result, rebootSuccess);
  return result;
};

// ── Remediation actions ───────────────────────────────────────────────────────

async function restartViaSSM(instanceId) {
  const commands = [
    `systemctl restart ${APP_SERVICE}`,
    'sleep 5',
    `systemctl is-active ${APP_SERVICE} || (echo 'Service failed to start' && exit 1)`,
  ];
  try {
    const { Command } = await ssm.send(new SendCommandCommand({
      InstanceIds:    [instanceId],
      DocumentName:   SSM_DOCUMENT,
      Parameters:     { commands },
      TimeoutSeconds: 60,
      Comment:        `TechStream self-healing restart at ${new Date().toISOString()}`,
    }));
    const commandId = Command.CommandId;
    console.info(`SSM command sent: ${commandId}`);

    const terminal = new Set(['Success', 'Failed', 'TimedOut']);

    for (let i = 0; i < 18; i++) {      // poll up to 90 s
      await sleep(5_000);
      const { CommandInvocations = [] } = await ssm.send(
        new ListCommandInvocationsCommand({ CommandId: commandId, Details: true })
      );
      if (CommandInvocations.length === 0) continue;

      const statuses = CommandInvocations.map((inv) => inv.Status);
      console.info(`SSM status: ${statuses}`);

      if (statuses.every((s) => terminal.has(s))) {
        const success = statuses.every((s) => s === 'Success');
        console.info(`SSM command completed — success=${success}`);
        return success;
      }
    }
    console.warn('SSM command timed out');
    return false;
  } catch (err) {
    console.error('SSM restart failed:', err);
    return false;
  }
}

async function rebootInstance(instanceId) {
  try {
    await ec2.send(new RebootInstancesCommand({ InstanceIds: [instanceId] }));
    console.info(`EC2 reboot issued for ${instanceId}`);
    return true;
  } catch (err) {
    console.error('EC2 reboot failed:', err);
    return false;
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

async function verifyInstanceRunning(instanceId) {
  try {
    const { Reservations = [] } = await ec2.send(
      new DescribeInstancesCommand({ InstanceIds: [instanceId] })
    );
    const state = Reservations?.[0]?.Instances?.[0]?.State?.Name;
    console.info(`Instance state: ${state}`);
    return state === 'running';
  } catch (err) {
    console.error('Instance state check failed:', err);
    return false;
  }
}

function extractAlarmName(event) {
  return event?.detail?.alarmName ?? event?.source ?? 'unknown-alarm';
}

function extractAlarmState(event) {
  return event?.detail?.state?.value ?? 'ALARM';
}

async function publishMetric(metricName, value) {
  try {
    await cw.send(new PutMetricDataCommand({
      Namespace:  NAMESPACE,
      MetricData: [{
        MetricName: metricName,
        Value:      value,
        Unit:       'Count',
        Dimensions: [{ Name: 'Service', Value: 'techstream-api' }],
      }],
    }));
  } catch (err) {
    console.warn('Could not publish CloudWatch metric:', err);
  }
}

async function notifyTeam(result, success) {
  if (!SNS_TOPIC_ARN) return;
  const subject = success
    ? 'TechStream self-healed successfully'
    : 'TechStream remediation FAILED — engineer required';
  try {
    await sns.send(new PublishCommand({
      TopicArn: SNS_TOPIC_ARN,
      Subject:  subject,
      Message:  JSON.stringify(result, null, 2),
    }));
    console.info(`SNS notification sent: ${subject}`);
  } catch (err) {
    console.error('SNS publish failed:', err);
  }
}
