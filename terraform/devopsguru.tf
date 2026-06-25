# DevOps Guru — AI-powered anomaly detection and root cause analysis
#
# Scoped to TechStream resources via the CostCenter=Lab tag so DevOps Guru
# correlates EC2, Lambda, and CloudWatch metric anomalies automatically.
#
# Free trial: 30 days. After that: ~$0.0028/resource-hour.
# To disable: run `terraform destroy -target=aws_devopsguru_resource_collection.techstream`

resource "aws_devopsguru_resource_collection" "techstream" {
  type = "AWS_TAGS"

  tags {
    app_boundary_key = "CostCenter"
    tag_values       = ["Lab"]
  }
}

resource "aws_devopsguru_notification_channel" "alerts" {
  sns {
    topic_arn = aws_sns_topic.alerts.arn
  }
}
