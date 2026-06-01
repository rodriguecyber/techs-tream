"""
TechStream — Self-Healing Lambda
Triggered by EventBridge when a CloudWatch Alarm fires.

Remediation actions (attempted in order):
  1. Restart the web server process via SSM Run Command
  2. If restart fails or instance is unresponsive → scale out the ASG
  3. Publish a remediation event to CloudWatch and SNS for audit trail
"""

import json
import boto3
import logging
import os
import time
from datetime import datetime, timezone

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# ── Config from environment variables (set in Lambda config) ─────────────────
ASG_NAME        = os.environ.get("ASG_NAME",        "techstream-asg")
SNS_TOPIC_ARN   = os.environ.get("SNS_TOPIC_ARN",   "")
AWS_REGION      = os.environ.get("AWS_REGION",       "us-east-1")
SSM_DOCUMENT    = os.environ.get("SSM_DOCUMENT",    "AWS-RunShellScript")
APP_SERVICE     = os.environ.get("APP_SERVICE",     "techstream-app")
NAMESPACE       = os.environ.get("CW_NAMESPACE",    "TechStream/App")

ec2  = boto3.client("ec2",          region_name=AWS_REGION)
ssm  = boto3.client("ssm",          region_name=AWS_REGION)
asg  = boto3.client("autoscaling",  region_name=AWS_REGION)
cw   = boto3.client("cloudwatch",   region_name=AWS_REGION)
sns  = boto3.client("sns",          region_name=AWS_REGION)


def handler(event, context):
    """Main Lambda entry point — called by EventBridge."""
    logger.info(f"Remediation triggered. Event: {json.dumps(event)}")

    alarm_name  = _extract_alarm_name(event)
    alarm_state = _extract_alarm_state(event)
    timestamp   = datetime.now(timezone.utc).isoformat()

    # Only remediate on ALARM state, ignore OK transitions
    if alarm_state == "OK":
        logger.info("Alarm returned to OK — no remediation needed")
        return {"status": "no_action", "reason": "alarm_resolved"}

    logger.warning(f"Alarm '{alarm_name}' entered ALARM state — starting remediation")

    remediation_result = {
        "alarm":     alarm_name,
        "timestamp": timestamp,
        "steps":     []
    }

    # ── Step 1: Try SSM restart ───────────────────────────────────────────────
    instance_ids = _get_asg_instance_ids()
    if instance_ids:
        logger.info(f"Found {len(instance_ids)} instances: {instance_ids}")
        ssm_success = _restart_via_ssm(instance_ids)
        remediation_result["steps"].append({
            "action":  "ssm_restart",
            "success": ssm_success,
            "targets": instance_ids
        })

        if ssm_success:
            logger.info("SSM restart succeeded — waiting 30s to verify recovery")
            time.sleep(30)
            if _verify_health(instance_ids):
                logger.info("Health check passed after SSM restart")
                remediation_result["outcome"] = "self_healed_via_restart"
                _publish_remediation_metric("RemediationSuccess", 1)
                _notify_team(remediation_result, success=True)
                return remediation_result
            else:
                logger.warning("Health check failed after SSM restart — escalating to scale-out")
    else:
        logger.warning("No healthy instances found in ASG")

    # ── Step 2: Scale out ASG ─────────────────────────────────────────────────
    logger.info("Attempting ASG scale-out...")
    scale_success = _scale_out_asg()
    remediation_result["steps"].append({
        "action":  "asg_scale_out",
        "success": scale_success
    })

    if scale_success:
        remediation_result["outcome"] = "self_healed_via_scale_out"
        _publish_remediation_metric("RemediationSuccess", 1)
    else:
        remediation_result["outcome"] = "remediation_failed_page_engineer"
        _publish_remediation_metric("RemediationFailure", 1)
        logger.error("All remediation steps failed — engineer must be paged")

    _notify_team(remediation_result, success=scale_success)
    return remediation_result


# ── Remediation actions ───────────────────────────────────────────────────────

def _restart_via_ssm(instance_ids: list) -> bool:
    """Restart the app service on all instances via SSM Run Command."""
    commands = [
        f"systemctl restart {APP_SERVICE}",
        f"sleep 5",
        f"systemctl is-active {APP_SERVICE} || (echo 'Service failed to start' && exit 1)",
    ]
    try:
        response = ssm.send_command(
            InstanceIds   = instance_ids,
            DocumentName  = SSM_DOCUMENT,
            Parameters    = {"commands": commands},
            TimeoutSeconds= 60,
            Comment       = f"TechStream self-healing restart at {datetime.now(timezone.utc).isoformat()}"
        )
        command_id = response["Command"]["CommandId"]
        logger.info(f"SSM command sent: {command_id}")

        # Poll for completion (max 90 seconds)
        for _ in range(18):
            time.sleep(5)
            result = ssm.list_command_invocations(CommandId=command_id, Details=True)
            invocations = result.get("CommandInvocations", [])
            if not invocations:
                continue
            statuses = [i["Status"] for i in invocations]
            logger.info(f"SSM statuses: {statuses}")
            if all(s in ("Success", "Failed", "TimedOut") for s in statuses):
                success = all(s == "Success" for s in statuses)
                logger.info(f"SSM command completed — success={success}")
                return success

        logger.warning("SSM command timed out waiting for completion")
        return False
    except Exception as e:
        logger.error(f"SSM restart failed: {e}")
        return False


def _scale_out_asg() -> bool:
    """Increase ASG desired capacity by 2 to bring in fresh instances."""
    try:
        response = asg.describe_auto_scaling_groups(AutoScalingGroupNames=[ASG_NAME])
        groups = response.get("AutoScalingGroups", [])
        if not groups:
            logger.error(f"ASG '{ASG_NAME}' not found")
            return False

        group       = groups[0]
        current     = group["DesiredCapacity"]
        maximum     = group["MaxSize"]
        new_desired = min(current + 2, maximum)

        if new_desired <= current:
            logger.warning(f"Already at max capacity ({maximum}) — cannot scale out")
            return False

        asg.set_desired_capacity(
            AutoScalingGroupName = ASG_NAME,
            DesiredCapacity      = new_desired,
            HonorCooldown        = False   # bypass cooldown during incident
        )
        logger.info(f"ASG scaled out: {current} → {new_desired} instances")
        return True
    except Exception as e:
        logger.error(f"ASG scale-out failed: {e}")
        return False


def _verify_health(instance_ids: list) -> bool:
    """Check that instances are in InService state in the ASG."""
    try:
        response = asg.describe_auto_scaling_instances(InstanceIds=instance_ids)
        instances = response.get("AutoScalingInstances", [])
        healthy   = [i for i in instances if i.get("LifecycleState") == "InService"
                     and i.get("HealthStatus") == "Healthy"]
        logger.info(f"Health check: {len(healthy)}/{len(instance_ids)} instances healthy")
        return len(healthy) >= max(1, len(instance_ids) // 2)
    except Exception as e:
        logger.error(f"Health check failed: {e}")
        return False


# ── Helpers ───────────────────────────────────────────────────────────────────

def _get_asg_instance_ids() -> list:
    """Return list of instance IDs currently InService in the ASG."""
    try:
        response = asg.describe_auto_scaling_groups(AutoScalingGroupNames=[ASG_NAME])
        groups   = response.get("AutoScalingGroups", [])
        if not groups:
            return []
        instances = groups[0].get("Instances", [])
        return [i["InstanceId"] for i in instances if i.get("LifecycleState") == "InService"]
    except Exception as e:
        logger.error(f"Could not get ASG instances: {e}")
        return []


def _extract_alarm_name(event: dict) -> str:
    try:
        detail = event.get("detail", {})
        return detail.get("alarmName", event.get("source", "unknown-alarm"))
    except Exception:
        return "unknown-alarm"


def _extract_alarm_state(event: dict) -> str:
    try:
        return event.get("detail", {}).get("state", {}).get("value", "ALARM")
    except Exception:
        return "ALARM"


def _publish_remediation_metric(metric_name: str, value: float):
    try:
        cw.put_metric_data(
            Namespace  = NAMESPACE,
            MetricData = [{
                "MetricName": metric_name,
                "Value":      value,
                "Unit":       "Count",
                "Dimensions": [{"Name": "Service", "Value": "techstream-api"}]
            }]
        )
    except Exception as e:
        logger.warning(f"Could not publish CloudWatch metric: {e}")


def _notify_team(result: dict, success: bool):
    """Send remediation summary to SNS (→ email / PagerDuty / Slack)."""
    if not SNS_TOPIC_ARN:
        return
    subject = (
        "✅ TechStream self-healed successfully"
        if success else
        "🚨 TechStream remediation FAILED — engineer required"
    )
    try:
        sns.publish(
            TopicArn = SNS_TOPIC_ARN,
            Subject  = subject,
            Message  = json.dumps(result, indent=2, default=str)
        )
        logger.info(f"SNS notification sent: {subject}")
    except Exception as e:
        logger.error(f"SNS publish failed: {e}")
