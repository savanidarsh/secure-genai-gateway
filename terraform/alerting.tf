# alerting.tf — Phase 6: observability & alerting

# A topic is the "channel" an alarm shouts into.
resource "aws_sns_topic" "alerts" {
  name = "secure-genai-gateway-alerts"

  #checkov:skip=CKV_AWS_26:AWS-managed SNS encryption (alias/aws/sns) breaks CloudWatch alarm delivery, and alerts are metadata-only (no PII). Proper fix needs a customer-managed KMS key with a policy allowing cloudwatch.amazonaws.com — flagged as a deferred hardening item.
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

# Pull the token count out of each ANSWER log line into a metric.
resource "aws_cloudwatch_log_metric_filter" "token_usage" {
  name           = "model-token-usage"
  log_group_name = aws_cloudwatch_log_group.lambda.name
  pattern        = "{ $.event = \"ANSWER\" }"

  metric_transformation {
    name          = "ModelTokenUsage"
    namespace     = "SecureGenAIGateway"
    value         = "$.total_tokens" # read the actual number, not just count lines
    default_value = "0"
  }
}

# Alert if total token usage in an hour crosses the threshold.
resource "aws_cloudwatch_metric_alarm" "high_token_usage" {
  alarm_name          = "secure-genai-gateway-high-token-usage"
  alarm_description   = "Model token usage crossed the expected threshold."
  namespace           = "SecureGenAIGateway"
  metric_name         = "ModelTokenUsage"
  statistic           = "Sum"
  period              = 3600 # 1 hour window
  evaluation_periods  = 1
  threshold           = 50000 # ~an hour of heavy-but-normal use; alert above this
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn] # reuse your email topic
}