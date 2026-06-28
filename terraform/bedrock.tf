# bedrock.tf — the safety filter (Guardrail) that inspects prompts and answers

resource "aws_bedrock_guardrail" "gateway" {
  name        = "secure-genai-gateway-guardrail"
  description = "Inspects prompts and answers for injection, PII, and toxicity."

  # Message returned when we block the user's PROMPT (the input).
  blocked_input_messaging = "Your request was blocked by the security gateway."
  # Message returned when we block the MODEL'S ANSWER (the output).
  blocked_outputs_messaging = "The response was blocked by the security gateway."

  # ---- Toxicity + prompt-injection filters ----
  content_policy_config {
    filters_config {
      type            = "HATE"
      input_strength  = "HIGH"
      output_strength = "HIGH"
    }
    filters_config {
      type            = "INSULTS"
      input_strength  = "HIGH"
      output_strength = "HIGH"
    }
    filters_config {
      type            = "SEXUAL"
      input_strength  = "HIGH"
      output_strength = "HIGH"
    }
    filters_config {
      type            = "VIOLENCE"
      input_strength  = "HIGH"
      output_strength = "HIGH"
    }
    filters_config {
      type            = "MISCONDUCT"
      input_strength  = "HIGH"
      output_strength = "HIGH"
    }
    filters_config {
      type            = "PROMPT_ATTACK"
      input_strength  = "HIGH"
      output_strength = "NONE"
    }
  }

  # ---- PII / sensitive-info filters ----
  sensitive_information_policy_config {
    pii_entities_config {
      type   = "EMAIL"
      action = "ANONYMIZE"
    }
    pii_entities_config {
      type   = "PHONE"
      action = "ANONYMIZE"
    }
    pii_entities_config {
      type   = "US_SOCIAL_SECURITY_NUMBER"
      action = "BLOCK"
    }
    pii_entities_config {
      type   = "CREDIT_DEBIT_CARD_NUMBER"
      action = "BLOCK"
    }
  }
}

# A frozen, numbered snapshot of the guardrail that our Lambda will point at.
resource "aws_bedrock_guardrail_version" "gateway" {
  guardrail_arn = aws_bedrock_guardrail.gateway.guardrail_arn
  description   = "Phase 5 initial version"
}

# Look up our own AWS account number, used to build the profile ARN below.
data "aws_caller_identity" "current" {}

# Let the Lambda call Claude Haiku (via the profile) and use our guardrail.
resource "aws_iam_role_policy" "lambda_bedrock" {
  name = "lambda-bedrock"
  role = aws_iam_role.lambda_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "InvokeHaikuViaInferenceProfile"
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:Converse",
          "bedrock:GetInferenceProfile"
        ]
        Resource = [
          # 1) The inference profile itself (in OUR account, us-east-1).
          "arn:aws:bedrock:us-east-1:${data.aws_caller_identity.current.account_id}:inference-profile/${var.model_id}",
          # 2) The real model, in EACH region the profile may route to.
          "arn:aws:bedrock:us-east-1::foundation-model/${trimprefix(var.model_id, "us.")}",
          "arn:aws:bedrock:us-east-2::foundation-model/${trimprefix(var.model_id, "us.")}",
          "arn:aws:bedrock:us-west-2::foundation-model/${trimprefix(var.model_id, "us.")}"
        ]
      },
      {
        Sid      = "ApplyOurGuardrail"
        Effect   = "Allow"
        Action   = "bedrock:ApplyGuardrail"
        Resource = aws_bedrock_guardrail.gateway.guardrail_arn
      }
    ]
  })
}