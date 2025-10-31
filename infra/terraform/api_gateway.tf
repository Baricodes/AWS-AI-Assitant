resource "aws_apigatewayv2_api" "query_api" {
  name          = "aws-ai-assistant-query-http-api"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["POST", "OPTIONS"]
    allow_headers = ["content-type", "authorization"]
  }

  tags = {
    Name        = "AWS AI Assistant Query HTTP API"
    Environment = "production"
    Project     = "aws-knowledge-assistant"
  }
}

resource "aws_apigatewayv2_integration" "query_integration" {
  api_id                 = aws_apigatewayv2_api.query_api.id
  integration_type       = "AWS_PROXY"
  integration_method     = "POST"
  integration_uri        = aws_lambda_function.query_processor.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "ask_route" {
  api_id    = aws_apigatewayv2_api.query_api.id
  route_key = "POST /ask"
  target    = "integrations/${aws_apigatewayv2_integration.query_integration.id}"
}

resource "aws_apigatewayv2_route" "ask_options_route" {
  api_id    = aws_apigatewayv2_api.query_api.id
  route_key = "OPTIONS /ask"
  target    = "integrations/${aws_apigatewayv2_integration.query_integration.id}"
}

resource "aws_apigatewayv2_stage" "prod" {
  api_id      = aws_apigatewayv2_api.query_api.id
  name        = "prod"
  auto_deploy = true
}

resource "aws_lambda_permission" "allow_http_api" {
  statement_id  = "AllowExecutionFromHTTPAPI"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.query_processor.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.query_api.execution_arn}/*/*"
}
