# alerting.tf — Phase 6: observability & alerting

# A topic is the "channel" an alarm shouts into.
resource "aws_sns_topic" "alerts" {
  name = "secure-genai-gateway-alerts"
}

# Subscribe your email to the topic.
# AWS will send a "Confirm subscription" email you must click before it works.
resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = "darsh@terpmail.umd.edu"
}

# Count every log line where the JSON field "event" == "GUARDRAIL_BLOCK".
resource "aws_cloudwatch_log_metric_filter" "guardrail_block" {
  name           = "guardrail-block-count"
  log_group_name = aws_cloudwatch_log_group.lambda.name
  pattern        = "{ $.event = \"GUARDRAIL_BLOCK\" }"

  metric_transformation {
    name          = "GuardrailBlocks"
    namespace     = "SecureGenAIGateway"
    value         = "1"
    default_value = "0"
  }
}

# Watch the count; if any block happens in a 60s window, notify SNS.
resource "aws_cloudwatch_metric_alarm" "guardrail_block" {
  alarm_name          = "secure-genai-gateway-guardrail-block"
  alarm_description   = "An attack was blocked by the Bedrock guardrail."
  namespace           = "SecureGenAIGateway"
  metric_name         = "GuardrailBlocks"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}