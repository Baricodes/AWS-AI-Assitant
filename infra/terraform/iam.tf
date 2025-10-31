# IAM Role for doc_ingestor Lambda
resource "aws_iam_role" "doc_ingestor_role" {
  name = "aws-ai-assistant-doc-ingestor-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name        = "AWS AI Assistant Doc Ingestor Role"
    Environment = "production"
    Project     = "aws-knowledge-assistant"
  }
}

# IAM Policy for doc_ingestor Lambda
resource "aws_iam_policy" "doc_ingestor_policy" {
  name        = "aws-ai-assistant-doc-ingestor-policy"
  description = "Policy for doc_ingestor Lambda function"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject"
        ]
        Resource = "${aws_s3_bucket.knowledge_assistant_docs.arn}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "aoss:APIAccessAll"
        ]
        Resource = aws_opensearchserverless_collection.kb_vector.arn
      },
      {
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel"
        ]
        Resource = "arn:aws:bedrock:${var.aws_region}::foundation-model/amazon.titan-embed-text-v2:0"
      }
    ]
  })
}

# Attach policy to doc_ingestor role
resource "aws_iam_role_policy_attachment" "doc_ingestor_policy" {
  role       = aws_iam_role.doc_ingestor_role.name
  policy_arn = aws_iam_policy.doc_ingestor_policy.arn
}

# IAM Role for query_processor Lambda
resource "aws_iam_role" "query_processor_role" {
  name = "aws-ai-assistant-query-processor-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name        = "AWS AI Assistant Query Processor Role"
    Environment = "production"
    Project     = "aws-knowledge-assistant"
  }
}

# IAM Policy for query_processor Lambda
resource "aws_iam_policy" "query_processor_policy" {
  name        = "aws-ai-assistant-query-processor-policy"
  description = "Policy for query_processor Lambda function"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect = "Allow"
        Action = [
          "aoss:APIAccessAll"
        ]
        Resource = aws_opensearchserverless_collection.kb_vector.arn
      },
      {
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel"
        ]
        Resource = "arn:aws:bedrock:${var.aws_region}::foundation-model/amazon.titan-embed-text-v2:0"
      },
      {
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel"
        ]
        Resource = [
          "arn:aws:bedrock:${var.aws_region}::foundation-model/anthropic.claude-3-5-sonnet-20241022-v2:0",
          "arn:aws:bedrock:*::foundation-model/anthropic.claude-3-5-sonnet-20241022-v2:0"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel"
        ]
        Resource = [
          "arn:aws:bedrock:${var.aws_region}:*:inference-profile/*",
          "arn:aws:bedrock:*:*:inference-profile/*"
        ]
      }
    ]
  })
}

# Attach policy to query_processor role
resource "aws_iam_role_policy_attachment" "query_processor_policy" {
  role       = aws_iam_role.query_processor_role.name
  policy_arn = aws_iam_policy.query_processor_policy.arn
}
