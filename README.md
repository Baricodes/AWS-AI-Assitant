# AWS AI Assistant

Infrastructure-as-code (Terraform), backend Lambdas (Python, container images), and a lightweight frontend for an AI-powered assistant on AWS.

## Components
- Infra (`infra/terraform`): API Gateway, Lambda, DynamoDB, S3, OpenSearch, ECR, IAM
- Backend (`src/python`): `doc_ingestor.py`, `query_processor.py`
- Dockerfiles (`src/docker`): Container images for Lambdas
- Frontend (`frontend/`): Static site assets

## Quick start
1. Set AWS credentials and region:
   ```bash
   export AWS_REGION=us-east-1
   ```
2. Deploy (wrapper around Terraform + ECR builds):
   ```bash
   bash infra/scripts/deploy.sh
   ```
3. Destroy:
   ```bash
   bash infra/scripts/destroy.sh
   ```

## Notes
- Terraform state files are ignored by Git; do not commit them.
- Use `us-east-1` as the AWS region.
- When building Docker container image Lambdas for deployment on AWS, use `--provenance=false`.

