resource "aws_cloudwatch_event_rule" "remediation" {
  name        = "techstream-alarm-to-remediation"
  description = "Routes CloudWatch Alarm state changes to self-healing Lambda"
  state       = "ENABLED"

  event_pattern = jsonencode({
    source      = ["aws.cloudwatch"]
    "detail-type" = ["CloudWatch Alarm State Change"]
    detail = {
      alarmName = [{ prefix = "techstream-" }]
      state = {
        value = ["ALARM"]
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "remediation_lambda" {
  rule      = aws_cloudwatch_event_rule.remediation.name
  target_id = "RemediationLambdaTarget"
  arn       = aws_lambda_function.remediation.arn
}

resource "aws_lambda_permission" "eventbridge_invoke" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.remediation.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.remediation.arn
}
