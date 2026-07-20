variable "model_id" {
  description = "Bedrock inference profile ID the gateway calls."
  type        = string
  default     = "us.anthropic.claude-haiku-4-5-20251001-v1:0"
}

variable "alert_email" {
  description = "Email address that receives security and cost alerts. Override in terraform.tfvars (git-ignored) with your own address."
  type        = string
  default     = "alerts@example.com"
}
