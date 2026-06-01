locals {
  region     = data.aws_region.current.name
  account_id = data.aws_caller_identity.current.account_id
}

resource "aws_cloudwatch_dashboard" "golden_signals" {
  dashboard_name = "TechStream-Golden-Signals"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "Latency (avg ms)"
          region = local.region
          metrics = [
            [var.cw_namespace, "AverageLatencyMs", "Service", "techstream-api"]
          ]
          period = 60
          stat   = "Average"
          view   = "timeSeries"
          annotations = {
            horizontal = [{ value = var.latency_threshold_ms, color = "#ff0000", label = "Threshold" }]
          }
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "Traffic (requests/min)"
          region = local.region
          metrics = [
            [var.cw_namespace, "RequestCount", "Service", "techstream-api"]
          ]
          period = 60
          stat   = "Sum"
          view   = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "Error Rate (%)"
          region = local.region
          metrics = [
            [var.cw_namespace, "ErrorRate", "Service", "techstream-api"]
          ]
          period = 60
          stat   = "Average"
          view   = "timeSeries"
          annotations = {
            horizontal = [{ value = var.error_rate_threshold, color = "#ff0000", label = "Alarm threshold" }]
          }
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "Saturation — CPU %"
          region = local.region
          metrics = [
            ["AWS/EC2", "CPUUtilization", "InstanceId", aws_instance.app.id]
          ]
          period = 60
          stat   = "Average"
          view   = "timeSeries"
          annotations = {
            horizontal = [{ value = var.cpu_threshold, color = "#ff6600", label = "Saturation threshold" }]
          }
        }
      },
      {
        type   = "alarm"
        x      = 0
        y      = 12
        width  = 24
        height = 4
        properties = {
          title = "Alarm Status"
          alarms = [
            "arn:aws:cloudwatch:${local.region}:${local.account_id}:alarm:techstream-high-error-rate",
            "arn:aws:cloudwatch:${local.region}:${local.account_id}:alarm:techstream-high-latency",
            "arn:aws:cloudwatch:${local.region}:${local.account_id}:alarm:techstream-high-cpu",
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 16
        width  = 12
        height = 6
        properties = {
          title  = "Remediation Events"
          region = local.region
          metrics = [
            [var.cw_namespace, "RemediationSuccess", "Service", "techstream-api"],
            [var.cw_namespace, "RemediationFailure", "Service", "techstream-api"],
          ]
          period = 300
          stat   = "Sum"
          view   = "timeSeries"
        }
      },
    ]
  })
}
