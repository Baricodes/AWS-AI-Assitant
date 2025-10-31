# ECR Repository for Lambda Container Images
resource "aws_ecr_repository" "lambda_images" {
  name                 = "aws-ai-assistant-lambdas"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name        = "AWS AI Assistant Lambda Images"
    Environment = "production"
    Project     = "aws-knowledge-assistant"
  }
}

# ECR Lifecycle Policy
resource "aws_ecr_lifecycle_policy" "lambda_images" {
  repository = aws_ecr_repository.lambda_images.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 3 images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["v"]
          countType     = "imageCountMoreThan"
          countNumber   = 3
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
