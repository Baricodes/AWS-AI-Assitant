# DynamoDB Table for Knowledge Base
resource "aws_dynamodb_table" "knowledge_base" {
  name           = var.table_name
  billing_mode   = "PAY_PER_REQUEST"
  hash_key       = "pk"
  range_key      = "sk"

  attribute {
    name = "pk"
    type = "S"
  }

  attribute {
    name = "sk"
    type = "S"
  }

  tags = {
    Name        = "Knowledge Base"
    Environment = "production"
    Project     = "aws-knowledge-assistant"
  }
}
