resource "aws_iam_role" "lambda_exec" {
  name = "secure-genai-gateway-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = "sts:AssumeRole"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/secure-genai-gateway-handler"
  retention_in_days = 365 # was 14 — CKV_AWS_338 wants >= 1 yr for forensic/audit history

  #checkov:skip=CKV_AWS_158:Logs are encrypted at rest with the AWS-managed key and are metadata-only (no prompt text); a customer-managed KMS key isn't worth the cost here
}

resource "aws_iam_role_policy" "lambda_logging" {
  name = "lambda-logging"
  role = aws_iam_role.lambda_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "${aws_cloudwatch_log_group.lambda.arn}:*"
      }
    ]
  })
}

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../src"
  output_path = "${path.module}/lambda.zip"
}

resource "aws_lambda_function" "gateway" {
  function_name = "secure-genai-gateway-handler"
  role          = aws_iam_role.lambda_exec.arn
  handler       = "handler.lambda_handler"
  runtime       = "python3.13"
  timeout       = 30

  # Cap simultaneous runs: limits cost + blast radius if the endpoint gets flooded.
  reserved_concurrent_executions = 10

  #checkov:skip=CKV_AWS_116:Synchronous API Gateway invoke — a dead-letter queue applies to async invokes only
  #checkov:skip=CKV_AWS_117:Function only calls the public Bedrock API; no private resources to reach, so a VPC adds NAT cost for no security benefit
  #checkov:skip=CKV_AWS_173:Env vars are non-secret (model/guardrail IDs) and already encrypted at rest by default
  #checkov:skip=CKV_AWS_272:Code-signing is an enterprise supply-chain control, out of scope for a solo learning project
  #checkov:skip=CKV_AWS_50:X-Ray tracing is pure observability and would require widening the execution role; consciously deferred

  environment {
    variables = {
      MODEL_ID          = var.model_id
      GUARDRAIL_ID      = aws_bedrock_guardrail.gateway.guardrail_id
      GUARDRAIL_VERSION = aws_bedrock_guardrail_version.gateway.version
    }
  }

  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  depends_on = [
    aws_iam_role_policy.lambda_logging,
    aws_cloudwatch_log_group.lambda,
  ]
}