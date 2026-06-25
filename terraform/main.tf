terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }

  backend "s3" {
    bucket       = "secure-genai-gateway-tfstate-darsh-1522"
    key          = "global/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = "us-east-1"
}

resource "aws_s3_bucket" "logs" {
  bucket = "secure-genai-gateway-logs-darsh-1522"

  #checkov:skip=CKV_AWS_18:This bucket IS the access-log destination; making it log to itself or a third bucket is circular and adds no value
  #checkov:skip=CKV2_AWS_61:Cost-hygiene (expiring old versions), not a security control; deferred for this learning project
  #checkov:skip=CKV2_AWS_62:No consumer needs S3 event notifications for this bucket
  #checkov:skip=CKV_AWS_144:Cross-region replication is disaster-recovery, out of scope for a solo learning project
  #checkov:skip=CKV_AWS_145:Encrypted at rest with AES256 (SSE-S3); a customer-managed KMS key adds cost/key-management for marginal gain on these logs
}

resource "aws_s3_bucket_public_access_block" "logs" {
  bucket = aws_s3_bucket.logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "logs" {
  bucket = aws_s3_bucket.logs.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket" "tfstate" {
  bucket = "secure-genai-gateway-tfstate-darsh-1522"

  #checkov:skip=CKV2_AWS_61:Cost-hygiene (expiring old versions), not a security control; deferred for this learning project
  #checkov:skip=CKV2_AWS_62:No consumer needs S3 event notifications for this bucket
  #checkov:skip=CKV_AWS_144:Cross-region replication is disaster-recovery, out of scope for a solo learning project
  #checkov:skip=CKV_AWS_145:State is already encrypted at rest with AES256 (SSE-S3); a customer-managed KMS key adds cost/key-management here
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Audit trail: record every access to the state bucket, written into the logs bucket.
resource "aws_s3_bucket_logging" "tfstate" {
  bucket        = aws_s3_bucket.tfstate.id
  target_bucket = aws_s3_bucket.logs.id
  target_prefix = "s3-access/tfstate/"
}

# A log destination must grant the S3 logging service permission to write to it,
# or delivery silently fails. Scope it to our account + the access-log prefix only.
resource "aws_s3_bucket_policy" "logs" {
  bucket = aws_s3_bucket.logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowS3ServerAccessLogging"
        Effect    = "Allow"
        Principal = { Service = "logging.s3.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.logs.arn}/s3-access/*"
        Condition = {
          StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
        }
      }
    ]
  })
}