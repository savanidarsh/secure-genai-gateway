# The front door: an HTTP API (API Gateway v2 — the cheap, simple kind).
resource "aws_apigatewayv2_api" "gateway" {
  name          = "secure-genai-gateway-api"
  protocol_type = "HTTP"
}

# The hallway: wire the door to our Lambda using "Lambda proxy".
resource "aws_apigatewayv2_integration" "lambda" {
  api_id                 = aws_apigatewayv2_api.gateway.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.gateway.invoke_arn
  payload_format_version = "2.0"
}

# The permission slip: allow API Gateway to wake our Lambda.
resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowInvokeFromHttpApi"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.gateway.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.gateway.execution_arn}/*/*"
}

# The bouncer: checks the JWT wristband and confirms OUR Cognito issued it.
resource "aws_apigatewayv2_authorizer" "cognito" {
  api_id           = aws_apigatewayv2_api.gateway.id
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]
  name             = "cognito-jwt"

  jwt_configuration {
    audience = [aws_cognito_user_pool_client.app.id]
    issuer   = "https://cognito-idp.us-east-1.amazonaws.com/${aws_cognito_user_pool.users.id}"
  }
}

# The rule: a POST to /chat is allowed, goes to the Lambda, and NEEDS a wristband.
resource "aws_apigatewayv2_route" "chat" {
  api_id             = aws_apigatewayv2_api.gateway.id
  route_key          = "POST /chat"
  target             = "integrations/${aws_apigatewayv2_integration.lambda.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}

# The live address: publish the door so it has a public URL.
resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.gateway.id
  name        = "$default"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_access.arn
    format = jsonencode({
      requestId      = "$context.requestId"
      ip             = "$context.identity.sourceIp"
      requestTime    = "$context.requestTime"
      httpMethod     = "$context.httpMethod"
      routeKey       = "$context.routeKey"
      status         = "$context.status"
      protocol       = "$context.protocol"
      responseLength = "$context.responseLength"
    })
  }
  default_route_settings {
    throttling_rate_limit  = 5  # steady pace: ~5 requests/second
    throttling_burst_limit = 10 # spike allowance before bouncing extras
  }
}

# Black box for the API: one JSON line per request (who / when / route / status).
resource "aws_cloudwatch_log_group" "api_access" {
  name              = "/aws/apigateway/secure-genai-gateway-access"
  retention_in_days = 365

  #checkov:skip=CKV_AWS_158:Access logs are metadata-only and already encrypted at rest with the AWS-managed key; a customer-managed KMS key isn't worth the cost here
}