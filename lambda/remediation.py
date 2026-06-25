"""
TechStream — Self-Healing Lambda (Python / boto3)
Triggered by EventBridge when the high-error-rate CloudWatch Alarm fires.

Remediation steps (in order):
  1. Restart the app service on the EC2 instance via SSM Run Command
  2. If restart fails → reboot the EC2 instance entirely
  3. Publish a remediation metric and SNS notification for audit trail
"""

import json
import os
import time

import boto3

INSTANCE_ID   = os.environ.get("INSTANCE_ID", "")
SNS_TOPIC_ARN = os.environ.get("SNS_TOPIC_ARN", "")
REGION        = os.environ.get("AWS_REGION", "us-east-1")
APP_SERVICE   = os.environ.get("APP_SERVICE", "techstream-app")
NAMESPACE     = os.environ.get("CW_NAMESPACE", "TechStream/App")

ssm = boto3.client("ssm", region_name=REGION)
ec2 = boto3.client("ec2", region_name=REGION)
cw  = boto3.client("cloudwatch", region_name=REGION)
sns = boto3.client("sns", region_name=REGION)


def handler(event, context):
    print("Remediation triggered. Event:", json.dumps(event))

    alarm_name  = event.get("detail", {}).get("alarmName", "unknown-alarm")
    alarm_state = event.get("detail", {}).get("state", {}).get("value", "ALARM")

    if alarm_state == "OK":
        print("Alarm returned to OK — no remediation needed")
        return {"status": "no_action", "reason": "alarm_resolved"}

    if not INSTANCE_ID:
        print("INSTANCE_ID env var is not set")
        return {"status": "error", "reason": "missing_instance_id"}

    print(f"Alarm '{alarm_name}' is ALARM — starting remediation on {INSTANCE_ID}")

    result = {"alarm": alarm_name, "instance": INSTANCE_ID, "steps": []}

    # Step 1: SSM service restart
    ssm_success = _restart_via_ssm(INSTANCE_ID)
    result["steps"].append({"action": "ssm_restart", "success": ssm_success})

    if ssm_success:
        print("SSM restart succeeded — waiting 30s to verify recovery")
        time.sleep(30)
        if _verify_instance_running(INSTANCE_ID):
            print("Instance healthy after SSM restart")
            result["outcome"] = "self_healed_via_restart"
            _publish_metric("RemediationSuccess", 1)
            _notify_team(result, success=True)
            return result
        print("Instance unhealthy after restart — escalating to reboot")

    # Step 2: EC2 reboot
    print("Attempting EC2 instance reboot...")
    reboot_success = _reboot_instance(INSTANCE_ID)
    result["steps"].append({"action": "ec2_reboot", "success": reboot_success})

    if reboot_success:
        result["outcome"] = "self_healed_via_reboot"
        _publish_metric("RemediationSuccess", 1)
    else:
        result["outcome"] = "remediation_failed_page_engineer"
        _publish_metric("RemediationFailure", 1)
        print("All remediation steps failed — engineer must be paged")

    _notify_team(result, success=reboot_success)
    return result


# ── Remediation helpers ───────────────────────────────────────────────────────

def _restart_via_ssm(instance_id):
    commands = [
        f"systemctl restart {APP_SERVICE}",
        "sleep 5",
        f'systemctl is-active {APP_SERVICE} || (echo "Service failed to start" && exit 1)',
    ]
    try:
        resp = ssm.send_command(
            InstanceIds=[instance_id],
            DocumentName="AWS-RunShellScript",
            Parameters={"commands": commands},
            TimeoutSeconds=60,
            Comment="TechStream self-healing restart",
        )
        command_id = resp["Command"]["CommandId"]
        print(f"SSM command sent: {command_id}")

        terminal = {"Success", "Failed", "TimedOut", "Cancelled"}
        for _ in range(18):  # poll up to 90 s
            time.sleep(5)
            invocations = ssm.list_command_invocations(
                CommandId=command_id, Details=True
            ).get("CommandInvocations", [])
            if not invocations:
                continue
            statuses = [inv["Status"] for inv in invocations]
            print(f"SSM status: {statuses}")
            if all(s in terminal for s in statuses):
                success = all(s == "Success" for s in statuses)
                print(f"SSM command completed — success={success}")
                return success

        print("SSM command timed out")
        return False
    except Exception as exc:
        print(f"SSM restart failed: {exc}")
        return False


def _reboot_instance(instance_id):
    try:
        ec2.reboot_instances(InstanceIds=[instance_id])
        print(f"EC2 reboot issued for {instance_id}")
        return True
    except Exception as exc:
        print(f"EC2 reboot failed: {exc}")
        return False


def _verify_instance_running(instance_id):
    try:
        resp = ec2.describe_instances(InstanceIds=[instance_id])
        state = (
            resp.get("Reservations", [{}])[0]
                .get("Instances", [{}])[0]
                .get("State", {})
                .get("Name", "")
        )
        print(f"Instance state: {state}")
        return state == "running"
    except Exception as exc:
        print(f"Instance state check failed: {exc}")
        return False


def _publish_metric(metric_name, value):
    try:
        cw.put_metric_data(
            Namespace=NAMESPACE,
            MetricData=[{
                "MetricName": metric_name,
                "Value": value,
                "Unit": "Count",
                "Dimensions": [{"Name": "Service", "Value": "techstream-api"}],
            }],
        )
    except Exception as exc:
        print(f"Could not publish CloudWatch metric: {exc}")


def _notify_team(result, success):
    if not SNS_TOPIC_ARN:
        return
    subject = (
        "TechStream self-healed successfully"
        if success
        else "TechStream remediation FAILED — engineer required"
    )
    try:
        sns.publish(
            TopicArn=SNS_TOPIC_ARN,
            Subject=subject,
            Message=json.dumps(result, indent=2),
        )
        print(f"SNS notification sent: {subject}")
    except Exception as exc:
        print(f"SNS publish failed: {exc}")
