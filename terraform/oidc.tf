# oidc.tf
# Tell AWS to trust identity tokens issued by GitHub Actions' OIDC provider.

resource "aws_iam_openid_connect_provider" "github" {
  # GitHub's OIDC issuer — the "passport office" whose signature AWS will trust.
  url = "https://token.actions.githubusercontent.com"

  # The "audience": who each token is meant for. sts.amazonaws.com is AWS's
  # token-vending service (STS = Security Token Service). This makes sure a
  # token minted for some other service can't be replayed against AWS.
  client_id_list = [
    "sts.amazonaws.com",
  ]

  # NOTE: no thumbprint_list on purpose. (A thumbprint is a fingerprint of
  # GitHub's TLS certificate.) Since AWS provider v5+, AWS validates GitHub's
  # cert against its own trusted CA library automatically. Older tutorials
  # hardcode a thumbprint — GitHub rotated it in 2023 and broke everyone.
  # Leaving it out is the modern, non-brittle way.
}

# The role GitHub Actions will "assume" (borrow) to get a temporary badge.
resource "aws_iam_role" "github_actions" {
  name = "secure-genai-gateway-github-actions"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        # NOT "sts:AssumeRole" like the Lambda role — GitHub proves itself with
        # a web identity token, so the action is AssumeRoleWithWebIdentity.
        Action = "sts:AssumeRoleWithWebIdentity"
        Principal = {
          # WHO is trusted: the GitHub OIDC provider we declared above.
          Federated = aws_iam_openid_connect_provider.github.arn
        }
        Condition = {
          StringEquals = {
            # Token must be addressed to AWS STS...
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
            # ...AND come from THIS repo, on the main branch only.
            "token.actions.githubusercontent.com:sub" = "repo:savanidarsh/secure-genai-gateway:ref:refs/heads/main"
          }
        }
      }
    ]
  })
}

# WHAT the role may do. Read-only: enough to run `terraform plan`, and
# powerless to create, change, or delete anything.
resource "aws_iam_role_policy_attachment" "github_actions_readonly" {
  role       = aws_iam_role.github_actions.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# `terraform plan` reads the state file and takes a brief lock — both live
# in the state bucket. Scope these writes to THAT bucket only, nothing else.
resource "aws_iam_role_policy" "github_actions_state" {
  name = "tfstate-access"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadStateAndLock"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.tfstate.arn}/*"
      },
      {
        Sid      = "ListStateBucket"
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = aws_s3_bucket.tfstate.arn
      }
    ]
  })
}