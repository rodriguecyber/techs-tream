data "archive_file" "remediation" {
  type        = "zip"
  source_file = "${path.module}/../lambda/remediation.js"
  output_path = "${path.module}/remediation.zip"
}

resource "aws_lambda_function" "remediation" {
  function_name = "techstream-self-healing"
  description   = "Automatically remediates TechStream incidents"
  runtime       = "nodejs20.x"
  handler       = "remediation.handler"
  role          = aws_iam_role.remediation_lambda.arn
  timeout       = 300
  memory_size   = 256

  filename         = data.archive_file.remediation.output_path
  source_code_hash = data.archive_file.remediation.output_base64sha256

  environment {
    variables = {
      INSTANCE_ID   = aws_instance.app.id
      SNS_TOPIC_ARN = aws_sns_topic.alerts.arn
      APP_SERVICE   = var.app_service_name
      CW_NAMESPACE  = var.cw_namespace
    }
  }
}
