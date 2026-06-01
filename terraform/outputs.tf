output "alert_topic_arn" {
  value       = aws_sns_topic.alerts.arn
  description = "SNS topic ARN for alerts"
}

output "lambda_function_name" {
  value       = aws_lambda_function.remediation.function_name
  description = "Self-healing Lambda function name"
}

output "lambda_function_arn" {
  value       = aws_lambda_function.remediation.arn
  description = "Self-healing Lambda function ARN"
}

output "dashboard_url" {
  value       = "https://${data.aws_region.current.name}.console.aws.amazon.com/cloudwatch/home?region=${data.aws_region.current.name}#dashboards:name=TechStream-Golden-Signals"
  description = "CloudWatch dashboard URL"
}

output "instance_id" {
  value       = aws_instance.app.id
  description = "EC2 instance ID"
}

output "instance_public_ip" {
  value       = aws_instance.app.public_ip
  description = "EC2 instance public IP — use this to run chaos.sh"
}
