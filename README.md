# TechStream — Self-Healing System
**End-to-End Implementation Guide**
Version 1.0 — May 2026

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Golden Signals — What They Are and Why They Matter](#2-golden-signals)
3. [Step 1 — Deploy the Application](#3-step-1--deploy-the-application)
4. [Step 2 — Set Up Monitoring and Dashboard](#4-step-2--set-up-monitoring-and-dashboard)
5. [Step 3 — Deploy the CloudFormation Stack](#5-step-3--deploy-the-cloudformation-stack)
6. [Step 4 — Run the Chaos Script](#6-step-4--run-the-chaos-script)
7. [Step 5 — Observe Automated Remediation](#7-step-5--observe-automated-remediation)
8. [Step 6 — Enable DevOps Guru for AI Analysis](#8-step-6--enable-devops-guru)
9. [Self-Healing Flow Explained](#9-self-healing-flow-explained)
10. [Files Reference](#10-files-reference)

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
  │   ALB   │──────────│ 4 Golden │──ALARM────▶│ Route to  │
  └────┬────┘          │  Signal  │            │  Lambda   │
       │               │  Alarms  │            └────┬──────┘
       ▼               └──────────┘                 │
  ┌─────────────┐           │                       ▼
  │  ASG with   │           │                ┌──────────────┐
  │  Mixed      │           ▼                │  Remediation │
  │  Instances  │    ┌────────────┐          │  Lambda      │
  │             │    │ CloudWatch │          │              │
  │  ┌────────┐ │    │ Dashboard  │          │ 1. SSM restart
  │  │ EC2 #1 │ │    │            │          │ 2. ASG scale │
  │  │(On-Dem)│ │    │ Latency    │          │    out       │
  │  └────────┘ │    │ Traffic    │          └──────┬───────┘
  │  ┌────────┐ │    │ Errors     │                 │
  │  │ EC2 #2 │ │    │ Saturation │          ┌──────▼───────┐
  │  │ (Spot) │ │    └────────────┘          │     SNS      │
  │  └────────┘ │                            │  (Email/     │
  └─────────────┘                            │   PagerDuty) │
        ▲                                    └──────────────┘
        │
  ┌─────┴─────┐
  │  Chaos    │   ← chaos.py artificially injects failures
  │  Script   │
  └───────────┘
```

### What happens during an incident

1. `chaos.py` spikes errors and CPU on the running instances
2. CloudWatch receives custom metrics every 60 seconds
3. After 2 evaluation periods (2 min), the alarm enters `ALARM` state
4. EventBridge catches the alarm state change and invokes the Lambda
5. Lambda attempts SSM `systemctl restart` on all InService instances
6. If restart fails, Lambda scales out the ASG by +2 instances
7. SNS sends email/notification with the remediation report
8. DevOps Guru correlates the anomalies and surfaces a root cause insight

---

## 2. Golden Signals

Google SRE defined four signals that, together, tell you everything about the health of a service. We monitor all four.

| Signal | What it measures | Our metric | Alarm threshold |
|---|---|---|---|
| **Latency** | How long requests take | `AverageLatencyMs` | > 2,000 ms for 3 min |
| **Traffic** | How many requests arrive | `RequestCount` | No alarm — visibility only |
| **Errors** | What fraction of requests fail | `ErrorRate` (%) | > 5% for 2 min |
| **Saturation** | How full the system is | `CPUUtilization` (%) | > 80% for 3 min |

We also use a **Composite Alarm** that fires only when *both* error rate and latency are high simultaneously — this reduces false positives from a single metric spike.

---

## 3. Step 1 — Deploy the Application

### 3.1 Create the Launch Template

1. Go to EC2 → Launch Templates → Create launch template
2. Name: `techstream-lt`
3. AMI: Amazon Linux 2023
4. Instance type: `t3.medium`
5. Key pair: your existing key pair
6. Security group: allow inbound 5000 (app), 22 (SSH), outbound all
7. Under **Advanced details → User data**: paste the contents of `scripts/userdata.sh`
8. Click **Create launch template**

### 3.2 Create the ASG (Mixed Instances)

```bash
aws autoscaling create-auto-scaling-group \
  --auto-scaling-group-name techstream-asg \
  --min-size 2 --max-size 6 --desired-capacity 2 \
  --vpc-zone-identifier "subnet-aaa,subnet-bbb" \
  --mixed-instances-policy '{
    "LaunchTemplate": {
      "LaunchTemplateSpecification": {
        "LaunchTemplateName": "techstream-lt",
        "Version": "$Latest"
      },
      "Overrides": [
        {"InstanceType": "t3.medium"},
        {"InstanceType": "t3a.medium"},
        {"InstanceType": "t2.medium"}
      ]
    },
    "InstancesDistribution": {
      "OnDemandBaseCapacity": 1,
      "OnDemandPercentageAboveBaseCapacity": 0,
      "SpotAllocationStrategy": "capacity-optimized"
    }
  }'
```

### 3.3 Verify the App Is Running

```bash
# Get the public IP of one of your instances
INSTANCE_IP=$(aws ec2 describe-instances \
  --filters "Name=tag:aws:autoscaling:groupName,Values=techstream-asg" \
  --query "Reservations[0].Instances[0].PublicIpAddress" \
  --output text)

# Check health endpoint
curl http://$INSTANCE_IP:5000/health

# Expected response:
# {
#   "status": "healthy",
#   "cpu_percent": 3.2,
#   "memory_percent": 18.1,
#   "chaos_mode": false,
#   "error_rate": 0.0
# }
```

---

## 4. Step 2 — Set Up Monitoring and Dashboard

### 4.1 Enable Detailed EC2 Monitoring

```bash
# Get all instance IDs in the ASG
INSTANCE_IDS=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names techstream-asg \
  --query "AutoScalingGroups[0].Instances[*].InstanceId" \
  --output text)

# Enable detailed monitoring (1-minute resolution instead of 5-minute)
for ID in $INSTANCE_IDS; do
  aws ec2 monitor-instances --instance-ids $ID
done
```

### 4.2 Create Custom Metric Namespace

The chaos script and app push metrics to `TechStream/App`. Verify they're flowing:

```bash
aws cloudwatch list-metrics \
  --namespace "TechStream/App" \
  --query "Metrics[*].MetricName" \
  --output table
```

> If the namespace is empty, run `python3 chaos.py --traffic --duration 60` first to generate some data points.

### 4.3 View the Dashboard

The CloudFormation stack creates the dashboard automatically. Access it at:

```
https://<region>.console.aws.amazon.com/cloudwatch/home#dashboards:name=TechStream-Golden-Signals
```

The dashboard shows all four golden signals plus alarm status and remediation event counters in a single view.

---

## 5. Step 3 — Deploy the CloudFormation Stack

This deploys everything in one command: alarms, EventBridge rule, Lambda, IAM roles, SNS, and the dashboard.

### 5.1 Package the Lambda

```bash
# Create deployment package
cd lambda/
zip lambda.zip remediation.py
cd ..
```

### 5.2 Deploy the Stack

```bash
aws cloudformation deploy \
  --template-file cloudformation/selfhealing-stack.yaml \
  --stack-name techstream-self-healing \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    AlertEmail=your@email.com \
    AppAsgName=techstream-asg \
    AppServiceName=techstream-app \
    ErrorRateThreshold=5 \
    LatencyThresholdMs=2000 \
    CpuThreshold=80
```

### 5.3 Upload the Real Lambda Code

```bash
FUNCTION_NAME=$(aws cloudformation describe-stacks \
  --stack-name techstream-self-healing \
  --query "Stacks[0].Outputs[?OutputKey=='LambdaFunctionName'].OutputValue" \
  --output text)

aws lambda update-function-code \
  --function-name $FUNCTION_NAME \
  --zip-file fileb://lambda/lambda.zip
```

### 5.4 Confirm Email Subscription

Check your inbox for an SNS confirmation email and click **Confirm subscription**. Without this, you will not receive incident notifications.

### 5.5 Verify the Stack

```bash
# Check all alarms were created
aws cloudwatch describe-alarms \
  --alarm-name-prefix "techstream-" \
  --query "MetricAlarms[*].{Name:AlarmName,State:StateValue}" \
  --output table

# Check EventBridge rule is enabled
aws events list-rules --name-prefix "techstream-" \
  --query "Rules[*].{Name:Name,State:State}" \
  --output table

# Check Lambda exists
aws lambda get-function \
  --function-name techstream-self-healing \
  --query "Configuration.{State:State,Handler:Handler,Timeout:Timeout}"
```

---

## 6. Step 4 — Run the Chaos Script

### 6.1 Install Dependencies

```bash
pip3 install requests boto3
```

### 6.2 Run Error Injection

```bash
# Inject 60% HTTP 500 errors + 500ms latency for 5 minutes
python3 scripts/chaos.py \
  --mode errors \
  --url http://$INSTANCE_IP:5000 \
  --duration 300
```

You will see output like:

```
2026-05-31 10:00:01  WARNING  CHAOS ENABLED — error_rate=0.6, latency_ms=500
2026-05-31 10:00:01  INFO     Generating 15 req/s for 300s
2026-05-31 10:01:02  INFO     Traffic done — 900 reqs | 542 errors | 60.2% error rate | 520ms avg latency
```

### 6.3 Run the Full Scenario

For a complete end-to-end test including CPU spike, error injection, and recovery verification:

```bash
python3 scripts/chaos.py \
  --mode full \
  --url http://$INSTANCE_IP:5000 \
  --duration 180
```

### 6.4 What to Watch in the Console

While the chaos script runs, open the CloudWatch dashboard and watch:

- **Error Rate** spikes from ~0% to ~60% within the first minute
- **Latency** climbs from ~80ms to ~500ms+
- **Alarms** turn red after 2 evaluation periods (~2 minutes)
- **EventBridge** fires the Lambda
- **Lambda logs** show the remediation steps (CloudWatch → Log Groups → `/aws/lambda/techstream-self-healing`)
- **Error Rate** drops back below 5% after Lambda restarts the service
- **SNS email** arrives with the remediation report

---

## 7. Step 5 — Observe Automated Remediation

### 7.1 Watch Lambda Logs Live

```bash
# Stream Lambda logs in real time
aws logs tail /aws/lambda/techstream-self-healing \
  --follow \
  --format short
```

Expected log sequence:

```
10:02:14 Remediation triggered. Alarm: techstream-high-error-rate
10:02:14 Found 2 instances: ['i-0abc123', 'i-0def456']
10:02:15 SSM command sent: abc-123-def
10:02:45 SSM statuses: ['Success', 'Success']
10:02:45 SSM restart succeeded — waiting 30s to verify recovery
10:03:15 Health check: 2/2 instances healthy
10:03:15 RECOVERY CONFIRMED — self_healed_via_restart
10:03:15 SNS notification sent: ✅ TechStream self-healed successfully
```

### 7.2 Verify SSM Command Execution

```bash
# List recent SSM commands
aws ssm list-commands \
  --filters "key=DocumentName,value=AWS-RunShellScript" \
  --query "Commands[*].{ID:CommandId,Status:StatusDetails,Time:RequestedDateTime}" \
  --output table
```

### 7.3 Check Remediation Metrics

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

### 7.4 MTTR Measurement

MTTR = time from alarm entering `ALARM` state to `OK` state.

```bash
# Get alarm state history to calculate MTTR
aws cloudwatch describe-alarm-history \
  --alarm-name "techstream-high-error-rate" \
  --history-item-type StateUpdate \
  --query "AlarmHistoryItems[*].{Time:Timestamp,State:HistorySummary}" \
  --output table
```

A successful self-healing run should show MTTR of **2–5 minutes** versus 20–60 minutes for a manual response.

---

## 8. Step 6 — Enable DevOps Guru

Amazon DevOps Guru uses ML to correlate anomalies across your CloudWatch metrics, logs, and AWS resource configuration and surface a root cause insight automatically.

### 8.1 Enable DevOps Guru

1. Go to AWS Console → **DevOps Guru** → Get started
2. Under **Resource analysis**, select **CloudFormation stack**
3. Choose `techstream-self-healing` → Enable

Or via CLI:

```bash
aws devops-guru update-resource-collection \
  --action ADD \
  --resource-collection '{
    "CloudFormation": {
      "StackNames": ["techstream-self-healing"]
    }
  }'
```

### 8.2 Trigger the Chaos Again

```bash
python3 scripts/chaos.py --mode full --url http://$INSTANCE_IP:5000 --duration 300
```

### 8.3 View DevOps Guru Insights

After the chaos run, DevOps Guru typically surfaces an insight within 5–15 minutes:

1. Go to **DevOps Guru → Insights**
2. Look for an insight named something like: *"Anomalous increase in error rate correlated with CPU spike"*
3. Click the insight to see:
   - **Anomalous metrics** — which signals deviated and by how much
   - **Related events** — SSM commands, ASG scaling events, Lambda invocations
   - **Recommendations** — suggested remediation steps
   - **Timeline** — exact correlation between CPU spike and error rate increase

### 8.4 Export the Insight

```bash
# List recent insights
aws devops-guru list-insights \
  --status-filter '{"Any":{"StartTimeRange":{"FromTime":"2026-05-31T00:00:00Z"},"Type":"REACTIVE"}}' \
  --query "ReactiveInsights[*].{Id:Id,Name:Name,Severity:Severity,Status:Status}" \
  --output table

# Export a specific insight
aws devops-guru describe-insight \
  --id <insight-id> \
  --output json > devops-guru-insight.json
```

---

## 9. Self-Healing Flow Explained

```
chaos.py injects 60% errors
          │
          ▼  (every 60s)
CloudWatch receives ErrorRate=60% metric
          │
          ▼  (after 2 evaluations = 2 min)
Alarm: techstream-high-error-rate → ALARM
          │
          ▼  (within seconds)
EventBridge catches state change event
          │
          ▼
Lambda: techstream-self-healing invoked
          │
          ├─ Step 1: Get InService instance IDs from ASG
          │
          ├─ Step 2: SSM SendCommand → systemctl restart techstream-app
          │          (runs on all instances in parallel)
          │
          ├─ Step 3: Poll SSM for completion (max 90s)
          │
          ├─ Step 4: Health check — are instances InService + Healthy?
          │
          ├─ [SUCCESS] → publish RemediationSuccess metric
          │              send SNS email: "✅ Self-healed"
          │
          └─ [FAILURE] → scale out ASG +2 instances
                         publish RemediationFailure metric
                         send SNS email: "🚨 Remediation failed"
```

### Why Two Remediation Steps?

**SSM restart** is tried first because it is faster (30–60 seconds) and less disruptive — it fixes a crashed or hung process without adding new capacity. This handles the majority of incidents: memory leaks, hung threads, config errors.

**ASG scale-out** is the fallback for when the instance itself is unhealthy — bad AMI, disk full, OOM kill, hardware issue. Bringing in fresh instances sidesteps the problem entirely, at the cost of a few minutes of boot time.

---

## 10. Files Reference

| File | Purpose |
|---|---|
| `scripts/app.py` | Flask web server with chaos injection endpoints |
| `scripts/chaos.py` | Chaos injection script — errors, CPU, latency, full scenario |
| `scripts/userdata.sh` | EC2 bootstrap — installs app, sets up systemd service + CloudWatch agent |
| `lambda/remediation.py` | Self-healing Lambda — SSM restart and ASG scale-out |
| `cloudformation/selfhealing-stack.yaml` | Full stack — alarms, EventBridge, Lambda, IAM, SNS, dashboard |

### Deploy Order

```
1. Upload app.py to S3 (or bake into AMI)
2. Create Launch Template with userdata.sh
3. Create ASG (techstream-asg)
4. zip lambda/remediation.py → lambda.zip
5. aws cloudformation deploy ... (selfhealing-stack.yaml)
6. aws lambda update-function-code ... (upload lambda.zip)
7. Confirm SNS email subscription
8. python3 scripts/chaos.py --mode full
9. Watch the dashboard — observe self-healing
10. Enable DevOps Guru on the stack
```

---

*TechStream Engineering — Self-Healing System v1.0 — May 2026*
