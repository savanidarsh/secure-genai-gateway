output "api_base_url" {
  description = "Base URL of the HTTP API. Append /chat to call the gateway."
  value       = aws_apigatewayv2_stage.default.invoke_url
}

output "user_pool_id" {
  description = "Cognito user pool ID — needed to create a test user."
  value       = aws_cognito_user_pool.users.id
}

output "app_client_id" {
  description = "Cognito app client ID — needed to log in and get a token."
  value       = aws_cognito_user_pool_client.app.id
}