output "s3_bucket_name" {
  description = "Name of the S3 bucket"
  value       = aws_s3_bucket.knowledge_assistant_docs.bucket
}

output "s3_bucket_arn" {
  description = "ARN of the S3 bucket"
  value       = aws_s3_bucket.knowledge_assistant_docs.arn
}

output "s3_bucket_domain_name" {
  description = "Domain name of the S3 bucket"
  value       = aws_s3_bucket.knowledge_assistant_docs.bucket_domain_name
}

output "dynamodb_table_name" {
  description = "Name of the DynamoDB table"
  value       = aws_dynamodb_table.knowledge_base.name
}

output "dynamodb_table_arn" {
  description = "ARN of the DynamoDB table"
  value       = aws_dynamodb_table.knowledge_base.arn
}

output "dynamodb_table_id" {
  description = "ID of the DynamoDB table"
  value       = aws_dynamodb_table.knowledge_base.id
}

output "opensearch_collection_id" {
  description = "ID of the OpenSearch Serverless collection"
  value       = aws_opensearchserverless_collection.kb_vector.id
}

output "opensearch_collection_arn" {
  description = "ARN of the OpenSearch Serverless collection"
  value       = aws_opensearchserverless_collection.kb_vector.arn
}

output "opensearch_collection_endpoint" {
  description = "Endpoint of the OpenSearch Serverless collection"
  value       = aws_opensearchserverless_collection.kb_vector.collection_endpoint
}

output "opensearch_dashboard_url" {
  description = "Dashboard URL for the OpenSearch Serverless collection"
  value       = aws_opensearchserverless_collection.kb_vector.dashboard_endpoint
}

# ECR Repository Outputs
output "ecr_repository_url" {
  description = "URL of the ECR repository for Lambda container images"
  value       = aws_ecr_repository.lambda_images.repository_url
}

output "ecr_repository_arn" {
  description = "ARN of the ECR repository for Lambda container images"
  value       = aws_ecr_repository.lambda_images.arn
}

# Lambda Function Outputs
output "doc_ingestor_lambda_arn" {
  description = "ARN of the doc_ingestor Lambda function"
  value       = aws_lambda_function.doc_ingestor.arn
}

output "doc_ingestor_lambda_name" {
  description = "Name of the doc_ingestor Lambda function"
  value       = aws_lambda_function.doc_ingestor.function_name
}

output "query_processor_lambda_arn" {
  description = "ARN of the query_processor Lambda function"
  value       = aws_lambda_function.query_processor.arn
}

output "query_processor_lambda_name" {
  description = "Name of the query_processor Lambda function"
  value       = aws_lambda_function.query_processor.function_name
}

output "http_api_id" {
  description = "ID of the HTTP API"
  value       = aws_apigatewayv2_api.query_api.id
}

output "http_api_invoke_url" {
  description = "Invoke URL for prod stage"
  value       = "${aws_apigatewayv2_api.query_api.api_endpoint}/prod"
}

output "http_api_ask_endpoint" {
  description = "Full POST /ask endpoint"
  value       = "${aws_apigatewayv2_api.query_api.api_endpoint}/prod/ask"
}

# Back-compat alias used by scripts
output "api_gateway_query_endpoint" {
  description = "Alias of http_api_ask_endpoint for script compatibility"
  value       = "${aws_apigatewayv2_api.query_api.api_endpoint}/prod/ask"
}
