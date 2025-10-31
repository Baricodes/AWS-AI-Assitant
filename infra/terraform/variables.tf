variable "aws_region" {
  description = "AWS region for resources"
  type        = string
  default     = "us-east-1"
}

variable "bucket_name" {
  description = "Name of the S3 bucket for knowledge assistant documents"
  type        = string
  default     = "aws-knowledge-assistant-docs-east1-232"
}

variable "table_name" {
  description = "Name of the DynamoDB table for knowledge base"
  type        = string
  default     = "KnowledgeBase"
}

variable "collection_name" {
  description = "Name of the OpenSearch Serverless collection"
  type        = string
  default     = "kb-vector"
}

variable "gen_inference_profile_id" {
  description = "Bedrock inference profile ID or ARN to use for generation. If not provided, will fall back to GEN_MODEL_ID. Example: us.anthropic.claude-3-5-sonnet-20241022-v2:0"
  type        = string
  default     = ""
}
