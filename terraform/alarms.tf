resource "aws_cloudwatch_metric_alarm" "error_rate" {
  alarm_name          = "techstream-high-error-rate"
  alarm_description   = "Error rate exceeds threshold — triggers self-healing"
  namespace           = var.cw_namespace
  metric_name         = "ErrorRate"
  dimensions          = { Service = "techstream-api" }
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 2
  threshold           = var.error_rate_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "high_latency" {
  alarm_name          = "techstream-high-latency"
  alarm_description   = "P99 latency exceeds threshold"
  namespace           = var.cw_namespace
  metric_name         = "AverageLatencyMs"
  dimensions          = { Service = "techstream-api" }
  extended_statistic  = "p99"
  period              = 60
  evaluation_periods  = 3
  threshold           = var.latency_threshold_ms
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "high_cpu" {
  alarm_name          = "techstream-high-cpu"
  alarm_description   = "CPU saturation — may require instance reboot"
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  dimensions          = { InstanceId = aws_instance.app.id }
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 3
  threshold           = var.cpu_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

# Composite alarm removed — costs $0.50/month and is not covered by free tier.
# The three standard alarms above are free (free tier includes 10).
# Remediation still works: the EventBridge rule catches every techstream-* alarm independently.
