#!/bin/bash
set -e
exec > >(tee /var/log/userdata.log | logger -t userdata) 2>&1

echo "=== TechStream bootstrap starting ==="

# ── Packages ──────────────────────────────────────────────────────────────────
yum update -y
yum install -y git stress-ng amazon-cloudwatch-agent

# ── Node.js 20.x ─────────────────────────────────────────────────────────────
curl -fsSL https://rpm.nodesource.com/setup_20.x | bash -
yum install -y nodejs

# ── Write app.js (injected by Terraform as base64) ────────────────────────────
mkdir -p /opt/techstream
echo "${app_js_b64}" | base64 -d > /opt/techstream/app.js

cd /opt/techstream
npm init -y
npm install express

# ── systemd service ───────────────────────────────────────────────────────────
cat > /etc/systemd/system/techstream-app.service << 'SVCEOF'
[Unit]
Description=TechStream Web Application (Node.js)
After=network.target

[Service]
Type=simple
User=ec2-user
WorkingDirectory=/opt/techstream
ExecStart=/usr/bin/node app.js
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
Environment=PORT=5000

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable techstream-app
systemctl start techstream-app

# ── CloudWatch agent ──────────────────────────────────────────────────────────
cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json << 'CWEOF'
{
  "metrics": {
    "namespace": "TechStream/System",
    "metrics_collected": {
      "cpu": {
        "measurement": ["cpu_usage_idle", "cpu_usage_user", "cpu_usage_system"],
        "metrics_collection_interval": 30,
        "totalcpu": true
      },
      "mem": {
        "measurement": ["mem_used_percent"],
        "metrics_collection_interval": 30
      },
      "disk": {
        "measurement": ["used_percent"],
        "metrics_collection_interval": 60,
        "resources": ["/"]
      }
    },
    "append_dimensions": {
      "AutoScalingGroupName": "$${aws:AutoScalingGroupName}",
      "InstanceId": "$${aws:InstanceId}"
    }
  },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/userdata.log",
            "log_group_name": "/techstream/userdata",
            "log_stream_name": "$${instance_id}"
          }
        ]
      },
      "journald": {
        "collect_list": [
          {
            "log_group_name": "/techstream/app",
            "log_stream_name": "$${instance_id}",
            "units": ["techstream-app.service"]
          }
        ]
      }
    }
  }
}
CWEOF

/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config -m ec2 -s \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json

echo "=== TechStream bootstrap complete ==="
PUBLIC_IP=$(curl -sf http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || echo "no-public-ip")
echo "App URL: http://$PUBLIC_IP:5000"
