resource "aws_cognito_user_pool" "users" {
  name = "secure-genai-gateway-users"

  # Passwords must be reasonably strong.
  password_policy {
    minimum_length    = 12
    require_lowercase = true
    require_uppercase = true
    require_numbers   = true
    require_symbols   = true
  }



  # Sign in with an email address as the username.
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  # Make Cognito enforce MFA-capable account recovery via email.
  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }
}

resource "aws_cognito_user_pool_client" "app" {
  name         = "secure-genai-gateway-client"
  user_pool_id = aws_cognito_user_pool.users.id

  # No client secret. This client is for a "public" app (a CLI or browser)
  # that can't reliably hide a secret, so we don't generate one. We prove
  # identity with username + password instead.
  generate_secret = false

  # Which sign-in methods this client is allowed to use.
  explicit_auth_flows = [
    "ALLOW_USER_PASSWORD_AUTH", # send username+password, get tokens back
    "ALLOW_REFRESH_TOKEN_AUTH", # swap an expiring token for a fresh one
  ]
}