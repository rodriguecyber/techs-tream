# TechStream — Self-Healing System
**End-to-End Implementation Guide**
Version 1.2 — June 2026

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Golden Signals — What They Are and Why They Matter](#2-golden-signals)
3. [Prerequisites](#3-prerequisites)
4. [Step 1 — Deploy Infrastructure with Terraform](#4-step-1--deploy-infrastructure-with-terraform)
5. [Step 2 — Verify the Application](#5-step-2--verify-the-application)
6. [Step 3 — Set Up Monitoring](#6-step-3--set-up-monitoring)
7. [Step 4 — Run the Chaos Script](#7-step-4--run-the-chaos-script)
8. [Step 5 — Observe Automated Remediation](#8-step-5--observe-automated-remediation)
9. [Step 6 — DevOps Guru AI Analysis](#9-step-6--devops-guru-ai-analysis)
10. [Self-Healing Flow Explained](#10-self-healing-flow-explained)
11. [Files Reference](#11-files-reference)

---

## 1. Architecture Overview

```
                    ┌─────────────────────────────────────────────────┐
                    │              TechStream Self-Healing System       │
                    └─────────────────────────────────────────────────┘

   User Traffic          CloudWatch             EventBridge
       │                 Alarms                    Rule
       ▼                    │                        │
  ┌─────────┐          ┌────┴─────┐            ┌────┴──────┐
  │  EC2    │──────────│ 4 Golden │──ErrorRate─▶│ Route to  │
  │ app.js  │          │  Signal  │   ALARM only │  Lambda   │
  └─────────┘          │  Alarms  │            └────┬──────┘
       │               └──────────┘                 │
       │                    │                       ▼
  ┌─────────────┐           │                ┌──────────────┐
  │  CloudWatch │           ▼                │  Remediation │
  │    Agent    │    ┌────────────┐          │  Lambda      │
  │             │    │ CloudWatch │          │  (Node.js)   │
  │  Custom     │    │ Dashboard  │          │              │
  │  Metrics    │    │            │          │ 1. SSM restart
  └─────────────┘    │ Latency    │          │ 2. EC2 reboot│
                     │ Traffic    │          └──────┬───────┘
                     │ Errors     │                 │
                     │ Saturation │          ┌──────▼───────┐
                     └────────────┘          │     SNS      │
                                             │  (Email)     │
  ┌─────────────┐                            └──────────────┘
  │  chaos.sh   │   ← Bash script injects failures for testing
  └─────────────┘

  ┌──────────────┐
  │ DevOps Guru  │  ← AI/ML anomaly correlation across EC2 + Lambda
  │  (AI/ML)     │    scoped to CostCenter=Lab tag, alerts via SNS
  └──────────────┘
```

### What happens during an incident

1. `chaos.sh` spikes errors and CPU on the running instance
2. The app publishes custom metrics (ErrorRate, RequestCount, AverageLatencyMs) to CloudWatch
3. After 2 evaluation periods (~2 min), the error rate alarm enters `ALARM` state
4. EventBridge catches the alarm state change **for the error rate alarm only** and invokes the Lambda
5. Lambda sends an SSM `systemctl restart` to the EC2 instance
6. If restart fails or the instance remains unhealthy, Lambda reboots the EC2 instance
7. SNS sends an email with the full remediation report
8. Alarm transitions back to `OK` once metrics recover
9. DevOps Guru independently correlates the anomaly and surfaces an AI insight

> **Why only the error rate alarm triggers Lambda?**  
> CPU saturation and high latency need different fixes. Restarting the app process does not reduce CPU pressure — it makes it worse during the boot cycle. Only the error rate signal reliably indicates that a restart will help. Latency and CPU alarms send SNS emails for human review.

---

## 2. Golden Signals

Google SRE defined four signals that, together, tell you everything about the health of a service. We monitor all four.

| Signal | What it measures | Our metric | Alarm threshold | Auto-remediation |
|---|---|---|---|---|
| **Latency** | How long requests take | `AverageLatencyMs` | > 2,000 ms for 3 min | SNS only |
| **Traffic** | How many requests arrive | `RequestCount` | No alarm — visibility only | — |
| **Errors** | What fraction of requests fail | `ErrorRate` (%) | > 5% for 2 min | **Lambda restart** |
| **Saturation** | How full the system is | `CPUUtilization` (%) | > 80% for 3 min | SNS only |

All three custom metrics (`ErrorRate`, `RequestCount`, `AverageLatencyMs`) are pushed to the `TechStream/App` CloudWatch namespace by `chaos.sh` during traffic generation runs.

---

## 3. Prerequisites

### Required Tools

| Tool | Version | Check |
|---|---|---|
| AWS CLI | v2 | `aws --version` |
| Terraform | ≥ 1.5 | `terraform -version` |
| An AWS account | — | `aws sts get-caller-identity` |

### AWS CLI Configuration

```bash
aws configure
# AWS Access Key ID:     <your key>
# AWS Secret Access Key: <your secret>
# Default region name:   us-east-1
# Default output format: json
```

---

## 4. Step 1 — Deploy Infrastructure with Terraform

All infrastructure (EC2, CloudWatch alarms, EventBridge rule, Lambda, SNS, dashboard, IAM, DevOps Guru) is defined in `terraform/` and deployed in a single command.

### 4.1 Initialise (first time only)

```bash
cd terraform/
terraform init
```

### 4.2 Preview Changes

```bash
terraform plan
```

Key resources that will be created:

- EC2 instance (`t3.micro`) running the Node.js app via systemd
- 3 CloudWatch metric alarms (error rate, latency, CPU)
- EventBridge rule routing the **error rate alarm only** to Lambda
- Lambda function `techstream-self-healing` (Node.js 20.x, 300s timeout)
- SNS topic `techstream-alerts` with email subscription
- CloudWatch dashboard `TechStream-Golden-Signals`
- IAM roles for EC2 (SSM + CloudWatch) and Lambda (SSM + EC2 + SNS)
- DevOps Guru resource collection (scoped to `CostCenter=Lab` tag) + SNS notification channel

### 4.3 Apply

```bash
terraform apply
```

Type `yes` when prompted. The apply takes approximately 2–3 minutes.

### 4.4 Note the Outputs

After apply completes, Terraform prints the outputs you will need:

```
instance_id          = "i-0abc1234567890def"
instance_public_ip   = "54.123.45.67"
lambda_function_name = "techstream-self-healing"
dashboard_url        = "https://us-east-1.console.aws.amazon.com/cloudwatch/..."
alert_topic_arn      = "arn:aws:sns:us-east-1:123456789:techstream-alerts"
```

You can re-print them at any time with:

```bash
terraform output
```

### 4.5 Customising Variables

Override defaults in `variables.tf` by passing `-var` flags or creating a `terraform.tfvars` file:

```bash
terraform apply \
  -var="alert_email=your@email.com" \
  -var="error_rate_threshold=10" \
  -var="instance_type=t3.micro" \
  -var="key_name=my-keypair"
```

| Variable | Default | Description |
|---|---|---|
| `alert_email` | `rodriguerwi@gmail.com` | SNS notification recipient |
| `error_rate_threshold` | `5` | Error % that triggers remediation |
| `latency_threshold_ms` | `2000` | Average latency (ms) that triggers alert |
| `cpu_threshold` | `80` | CPU % that triggers saturation alert |
| `instance_type` | `t3.micro` | EC2 instance type (free-tier eligible) |
| `key_name` | `null` | EC2 key pair for SSH; omit to use SSM Session Manager (recommended) |

---

## 5. Step 2 — Verify the Application

### 5.1 Confirm SNS Email

Check your inbox for the SNS subscription confirmation email and click **Confirm subscription**. Without this step you will not receive incident notifications.

### 5.2 Check App Health

```bash
INSTANCE_IP=$(terraform -chdir=terraform output -raw instance_public_ip)

curl http://$INSTANCE_IP:5000/health
```

Expected response:

```json
{
  "status": "healthy",
  "cpu_percent": 3,
  "memory_percent": 18,
  "request_count": 0,
  "chaos_mode": false,
  "error_rate": 0
}
```

### 5.3 Explore Other Endpoints

```bash
# Normal API call (50–150ms simulated DB latency)
curl http://$INSTANCE_IP:5000/api/data

# CPU-heavy endpoint
curl http://$INSTANCE_IP:5000/api/heavy

# Prometheus-style metrics
curl http://$INSTANCE_IP:5000/metrics
```

---

## 6. Step 3 — Set Up Monitoring

### 6.1 Enable Detailed EC2 Monitoring

By default EC2 metrics are at 5-minute resolution. Enable 1-minute resolution (required for the alarms):

```bash
INSTANCE_ID=$(terraform -chdir=terraform output -raw instance_id)
aws ec2 monitor-instances --instance-ids $INSTANCE_ID
```

### 6.2 Verify Custom Metrics are Flowing

`chaos.sh` pushes three custom metrics to the `TechStream/App` namespace: `ErrorRate`, `RequestCount`, and `AverageLatencyMs`. After running any traffic, verify the namespace is populated:

```bash
aws cloudwatch list-metrics \
  --namespace "TechStream/App" \
  --query "Metrics[*].MetricName" \
  --output table
```

> If the namespace is empty, run `bash scripts/chaos.sh --traffic --duration 60` first to generate some data points.

### 6.3 Open the Dashboard

```bash
# Print the direct URL
terraform -chdir=terraform output dashboard_url
```

The dashboard shows all four golden signals, alarm status, and remediation event counters in a single view.

### 6.4 Verify Alarms and EventBridge

```bash
# Check all alarms were created and their current state
aws cloudwatch describe-alarms \
  --alarm-name-prefix "techstream-" \
  --query "MetricAlarms[*].{Name:AlarmName,State:StateValue}" \
  --output table

# Check EventBridge rule is enabled
aws events list-rules --name-prefix "techstream-" \
  --query "Rules[*].{Name:Name,State:State}" \
  --output table

# Confirm Lambda exists
aws lambda get-function \
  --function-name techstream-self-healing \
  --query "Configuration.{State:State,Handler:Handler,Timeout:Timeout}"
```

---

## 7. Step 4 — Run the Chaos Script

`scripts/chaos.sh` is a Bash script that injects failures into the running app. It must be run **on the EC2 instance** (or from any host with network access to port 5000 and AWS credentials).

### 7.1 SSH into the Instance

```bash
# If you provided a key_name in variables.tf:
ssh -i your-key.pem ec2-user@$INSTANCE_IP

# Or use SSM Session Manager (no key pair required — recommended):
INSTANCE_ID=$(terraform -chdir=terraform output -raw instance_id)
aws ssm start-session --target $INSTANCE_ID
```

### 7.2 Chaos Modes

| Command | What it does | Metrics published |
|---|---|---|
| `bash chaos.sh --mode errors` | 60% HTTP 500 errors + 500ms latency for 300s | ErrorRate, RequestCount, AverageLatencyMs |
| `bash chaos.sh --mode cpu` | CPU spike via `stress-ng` or shell burn for 300s | CPUChaosActive |
| `bash chaos.sh --mode latency` | 2000ms added to every request for 300s | ErrorRate, RequestCount, AverageLatencyMs |
| `bash chaos.sh --mode full` | All of the above in phases (see below) | All metrics |
| `bash chaos.sh --stop` | Disable chaos, restore normal operation | — |
| `bash chaos.sh --traffic` | Generate clean traffic only (no failures) | ErrorRate, RequestCount, AverageLatencyMs |

### 7.3 Full End-to-End Test

```bash
bash scripts/chaos.sh --mode full
```

The `full` scenario runs five phases:

```
Phase 1 (30s)  — clean baseline traffic (~10 req/s)
Phase 2        — enable 60% errors + 500ms latency
Phase 3 (300s) — CPU spike + chaotic traffic (~15 req/s)
Phase 4        — stop CPU spike, disable chaos
Phase 5 (30s)  — post-recovery verification traffic
```

### 7.4 Custom Options

```bash
# Override the app URL (if running chaos.sh from outside the instance)
bash scripts/chaos.sh --mode errors --url http://$INSTANCE_IP:5000

# Shorter duration for quick testing
bash scripts/chaos.sh --mode full --duration 60
```

### 7.5 What to Watch in the Console

While the chaos script runs, open the CloudWatch dashboard and watch:

- **Error Rate** spikes from ~0% to ~60% within the first minute
- **Latency** climbs from ~80ms to ~500ms (published as `AverageLatencyMs`)
- **CPU** rises sharply during Phase 3
- **Error rate alarm** turns red after 2 evaluation periods (~2 minutes) → triggers Lambda
- **Latency and CPU alarms** turn red but only send SNS email (no Lambda invocation)
- **Error Rate** drops back below 5% after Lambda restarts the service
- **SNS email** arrives with the remediation report

---

## 8. Step 5 — Observe Automated Remediation

### 8.1 Watch Lambda Logs Live

```bash
aws logs tail /aws/lambda/techstream-self-healing \
  --follow \
  --format short
```

Expected log sequence:

```
10:02:14 Remediation triggered. Alarm: techstream-high-error-rate
10:02:14 Alarm 'techstream-high-error-rate' is ALARM — starting remediation on i-0abc123
10:02:15 SSM command sent: abc-123-def-456
10:02:20 SSM status: InProgress
10:02:45 SSM status: Success
10:02:45 SSM restart succeeded — waiting 30s to verify recovery
10:03:15 Instance state: running
10:03:15 RECOVERY CONFIRMED — self_healed_via_restart
10:03:15 SNS notification sent: TechStream self-healed successfully
```

### 8.2 Verify SSM Command Execution

```bash
aws ssm list-commands \
  --filters "key=DocumentName,value=AWS-RunShellScript" \
  --query "Commands[*].{ID:CommandId,Status:StatusDetails,Time:RequestedDateTime}" \
  --output table
```

### 8.3 Check Remediation Metrics

```bash
aws cloudwatch get-metric-statistics \
  --namespace "TechStream/App" \
  --metric-name "RemediationSuccess" \
  --dimensions Name=Service,Value=techstream-api \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 300 \
  --statistics Sum \
  --output table
```

### 8.4 Measure MTTR

MTTR = time from alarm entering `ALARM` state to returning to `OK`.

```bash
aws cloudwatch describe-alarm-history \
  --alarm-name "techstream-high-error-rate" \
  --history-item-type StateUpdate \
  --query "AlarmHistoryItems[*].{Time:Timestamp,State:HistorySummary}" \
  --output table
```

A successful self-healing run shows MTTR of **2–5 minutes** versus 20–60 minutes for a manual response.

---

## 9. Step 6 — DevOps Guru AI Analysis

Amazon DevOps Guru uses ML to correlate anomalies across CloudWatch metrics, logs, and AWS resource configuration and surfaces root cause insights automatically.

DevOps Guru is **provisioned by Terraform** as part of `terraform apply` — no manual console steps required. It is scoped to all resources tagged `CostCenter=Lab` (the EC2 instance and Lambda function) and delivers insights to the same SNS topic used for alarm notifications.

> **Cost note:** DevOps Guru includes a 30-day free trial. After the trial, billing is ~$0.0028/resource-hour. To disable without destroying the rest of the stack: `terraform destroy -target=aws_devopsguru_resource_collection.techstream -target=aws_devopsguru_notification_channel.alerts`

### 9.1 Trigger Chaos

Run the full chaos scenario again after deploying so DevOps Guru has anomaly data to analyse:

```bash
bash scripts/chaos.sh --mode full
```

### 9.2 View DevOps Guru Insights

DevOps Guru typically surfaces an insight 5–15 minutes after an anomaly:

1. Go to **AWS Console → DevOps Guru → Insights**
2. Look for a reactive insight such as: *"Anomalous increase in error rate correlated with Lambda invocations"*
3. Click the insight to see the anomalous metrics, correlated events (SSM commands, Lambda invocations), and the automated timeline

### 9.3 Export Insights via CLI

```bash
# List recent reactive insights
aws devops-guru list-insights \
  --status-filter '{"Any":{"StartTimeRange":{"FromTime":"2026-06-01T00:00:00Z"},"Type":"REACTIVE"}}' \
  --query "ReactiveInsights[*].{Id:Id,Name:Name,Severity:Severity,Status:Status}" \
  --output table

# Export a specific insight to JSON
aws devops-guru describe-insight \
  --id <insight-id> \
  --output json > devops-guru-insight.json
```

---

## 10. Self-Healing Flow Explained

```
chaos.sh injects 60% errors + CPU spike
          │
          ▼  (published per traffic generation run)
CloudWatch receives ErrorRate=60%, AverageLatencyMs=~500ms metrics
          │
          ▼  (after 2 evaluation periods = 2 min)
Alarm: techstream-high-error-rate → ALARM
  └─ SNS: email sent immediately
          │
          ▼  (within seconds)
EventBridge catches state change event
  Pattern: source=aws.cloudwatch,
           alarmName=techstream-high-error-rate (exact match),
           state=ALARM
          │
          ▼
Lambda: techstream-self-healing (Node.js 20.x) invoked
          │
          ├─ Step 1: SSM SendCommand
          │     systemctl restart techstream-app
          │     Poll status every 5s for up to 90s
          │
          ├─ If SSM succeeds → wait 30s → verify instance state = "running"
          │     SUCCESS → publish RemediationSuccess metric
          │               send SNS: "TechStream self-healed successfully"
          │
          └─ If SSM fails or instance still unhealthy:
                Step 2: EC2 RebootInstances API call
                If reboot issued → publish RemediationSuccess metric
                                   send SNS: "self_healed_via_reboot"
                If reboot also fails → publish RemediationFailure metric
                                       send SNS: "remediation FAILED — engineer required"

(parallel, independent)
DevOps Guru analyses metric anomalies across EC2 + Lambda
  └─ Surfaces correlated insight → SNS notification → Insights console
```

### Why Only the Error Rate Alarm Triggers Lambda?

**SSM restart** is the right fix for application-level errors — crashed process, memory leak, hung thread. Triggering a restart in response to a CPU spike or latency spike would be wrong:

- **CPU spike**: Restarting the app adds a new boot cycle under an already-saturated CPU, making things worse. The right fix is to investigate the workload or scale out.
- **High latency**: Often caused by downstream dependencies (database, external API) — restarting the app has no effect. Human investigation is required.

Only the error rate alarm reliably indicates that restarting the process will restore service.

### Why Two Remediation Steps?

**SSM restart** is tried first because it is fast (30–60 seconds) and non-disruptive — it fixes a crashed or hung process without taking the instance offline. This resolves the majority of incidents.

**EC2 reboot** is the fallback for when the OS itself is degraded — disk full, OOM kill loop, kernel-level issue. A full reboot clears kernel state and restarts all services cleanly, at the cost of a longer recovery time (~2–3 minutes boot).

---

## 11. Files Reference

| File | Language | Purpose |
|---|---|---|
| `scripts/app.js` | Node.js / Express | Web server with chaos injection endpoints (`/chaos/enable`, `/chaos/disable`, `/health`, `/metrics`) |
| `scripts/chaos.sh` | Bash | Chaos injection — 4 modes: errors, cpu, latency, full. Generates traffic and publishes `ErrorRate`, `RequestCount`, and `AverageLatencyMs` to CloudWatch |
| `scripts/userdata.sh` | Bash | EC2 bootstrap (legacy reference). The active version is `terraform/userdata.tpl` |
| `lambda/remediation.js` | Node.js **(deployed)** | Self-healing Lambda — SSM service restart with EC2 reboot fallback, CloudWatch metrics, SNS notifications |
| `lambda/remediation.py` | Python **(reference)** | Equivalent Python/boto3 implementation of the same remediation logic |
| `terraform/main.tf` | HCL | AWS + Archive provider configuration |
| `terraform/variables.tf` | HCL | Input variables and defaults |
| `terraform/ec2.tf` | HCL | EC2 instance, security group, IAM role |
| `terraform/iam.tf` | HCL | Lambda execution role and permissions |
| `terraform/lambda.tf` | HCL | Lambda function, environment variables, zip archive |
| `terraform/alarms.tf` | HCL | 3 CloudWatch metric alarms (error rate triggers Lambda; latency and CPU notify only) |
| `terraform/eventbridge.tf` | HCL | EventBridge rule routing the error rate alarm to Lambda (exact alarm name match) |
| `terraform/sns.tf` | HCL | SNS topic and email subscription |
| `terraform/dashboard.tf` | HCL | CloudWatch dashboard with 6 widgets |
| `terraform/devopsguru.tf` | HCL | DevOps Guru resource collection (tag-scoped) and SNS notification channel |
| `terraform/outputs.tf` | HCL | Terraform outputs (IPs, ARNs, dashboard URL) |
| `terraform/userdata.tpl` | Bash template | EC2 bootstrap — installs Node.js 20, deploys app.js, registers systemd service, starts CloudWatch agent |

### Deploy Order (Quick Reference)

```
1.  cd terraform/
2.  terraform init
3.  terraform apply -var="alert_email=your@email.com"
4.  Confirm SNS email subscription in your inbox
5.  INSTANCE_IP=$(terraform output -raw instance_public_ip)
6.  curl http://$INSTANCE_IP:5000/health    # verify app is running
7.  aws ssm start-session --target $(terraform output -raw instance_id)
8.  bash scripts/chaos.sh --mode full      # trigger self-healing test
9.  Watch CloudWatch dashboard — observe remediation
10. Check DevOps Guru Insights (5–15 min after chaos run)
11. terraform destroy                       # tear down when done
```

---

### Tear Down

```bash
cd terraform/
terraform destroy
```

This removes all AWS resources created by this project. Confirm with `yes`.

---

*TechStream Engineering — Self-Healing System v1.2 — June 2026*
