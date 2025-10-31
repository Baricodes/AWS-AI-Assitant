#!/bin/bash

# AWS AI Assistant Lambda Container Deployment Script
# This script deploys the Terraform infrastructure and builds/pushes Lambda container images

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
AWS_REGION="us-east-1"
TERRAFORM_DIR="../terraform"
SCRIPTS_DIR="infra/scripts"
DOCKER_DIR="../../src/docker"
GEN_INFERENCE_PROFILE_ID_ENV_DEFAULT="${GEN_INFERENCE_PROFILE_ID:-}"

# Resolve repo root for writing frontend config
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

write_frontend_config() {
    local api_url="$1"
    if [ -z "$api_url" ]; then
        print_warning "API URL not provided; skipping frontend config generation."
        return
    fi
    local cfg_dir="$REPO_ROOT/frontend/config"
    local cfg_file="$cfg_dir/config.js"
    mkdir -p "$cfg_dir"
    cat > "$cfg_file" <<EOF
window.APP_CONFIG = {
  apiEndpoint: "$api_url"
};
EOF
    print_success "Wrote frontend config to $cfg_file"
}

# Function to print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check prerequisites
check_prerequisites() {
    print_status "Checking prerequisites..."
    
    local missing_tools=()
    
    if ! command_exists aws; then
        missing_tools+=("aws")
    fi
    
    if ! command_exists docker; then
        missing_tools+=("docker")
    fi
    
    if ! command_exists terraform; then
        missing_tools+=("terraform")
    fi
    
    if ! command_exists jq; then
        missing_tools+=("jq")
    fi
    
    if [ ${#missing_tools[@]} -ne 0 ]; then
        print_error "Missing required tools: ${missing_tools[*]}"
        print_error "Please install the missing tools and try again."
        exit 1
    fi
    
    print_success "All prerequisites are installed"
}

# Get AWS account ID
get_aws_account_id() {
    print_status "Getting AWS account ID..."
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    if [ -z "$AWS_ACCOUNT_ID" ]; then
        print_error "Failed to get AWS account ID. Please check your AWS credentials."
        exit 1
    fi
    print_success "AWS Account ID: $AWS_ACCOUNT_ID"
}

# Deploy ECR and basic infrastructure first
deploy_infrastructure_stage1() {
    print_status "Deploying stage 1 infrastructure (ECR, OpenSearch, etc.)..."
    
    local terraform_path
    terraform_path="$(pwd)/$TERRAFORM_DIR"
    
    if [ ! -d "$terraform_path" ]; then
        print_error "Terraform directory not found: $terraform_path"
        exit 1
    fi
    
    cd "$terraform_path"
    
    # Initialize Terraform if needed
    if [ ! -d ".terraform" ]; then
        print_status "Initializing Terraform..."
        terraform init
    fi
    
    # Target specific resources that Lambda doesn't depend on
    print_status "Creating ECR repository and basic infrastructure..."
    terraform apply -target=aws_ecr_repository.lambda_images \
                    -target=aws_dynamodb_table.knowledge_base \
                    -target=aws_s3_bucket.knowledge_assistant_docs \
                    -target=aws_s3_bucket_public_access_block.knowledge_assistant_docs \
                    -target=aws_s3_object.ingest_folder \
                    -target=aws_s3_object.processed_folder \
                    -target=aws_opensearchserverless_security_policy.encryption \
                    -target=aws_opensearchserverless_security_policy.network \
                    -target=aws_opensearchserverless_access_policy.data_access \
                    -target=aws_opensearchserverless_collection.kb_vector \
                    -target=aws_iam_role.doc_ingestor_role \
                    -target=aws_iam_policy.doc_ingestor_policy \
                    -target=aws_iam_role_policy_attachment.doc_ingestor_policy \
                    -target=aws_iam_role.query_processor_role \
                    -target=aws_iam_policy.query_processor_policy \
                    -target=aws_iam_role_policy_attachment.query_processor_policy \
                    -auto-approve
    
    # Get ECR URL for image push
    ECR_REPOSITORY_URL=$(terraform output -raw ecr_repository_url)
    print_success "ECR Repository created: $ECR_REPOSITORY_URL"
    
    cd - > /dev/null
}

# Deploy remaining Terraform infrastructure
deploy_terraform() {
    print_status "Deploying remaining Terraform infrastructure..."
    
    local terraform_path
    terraform_path="$(pwd)/$TERRAFORM_DIR"
    
    cd "$terraform_path"
    
    # Apply all resources
    print_status "Applying Terraform..."
    if [ -n "$GEN_INFERENCE_PROFILE_ID" ]; then
        print_status "Using Bedrock inference profile: $GEN_INFERENCE_PROFILE_ID"
        terraform apply -auto-approve \
            -var gen_inference_profile_id="$GEN_INFERENCE_PROFILE_ID"
    else
        print_warning "No Bedrock inference profile ID provided. Some models require it."
        terraform apply -auto-approve
    fi
    
    # Get outputs
    print_status "Getting Terraform outputs..."
    ECR_REPOSITORY_URL=$(terraform output -raw ecr_repository_url)
    OPENSEARCH_ENDPOINT=$(terraform output -raw opensearch_collection_endpoint)
    API_GATEWAY_URL=$(terraform output -raw api_gateway_query_endpoint)
    # Also try canonical output if present (no fail if missing)
    if command -v terraform >/dev/null 2>&1; then
        if terraform output -raw http_api_ask_endpoint >/dev/null 2>&1; then
            API_GATEWAY_URL=$(terraform output -raw http_api_ask_endpoint)
        fi
    fi
    
    print_success "Terraform deployment completed"
    print_status "ECR Repository URL: $ECR_REPOSITORY_URL"
    print_status "OpenSearch Endpoint: $OPENSEARCH_ENDPOINT"
    print_status "API Gateway URL: $API_GATEWAY_URL"
    # Generate frontend config
    write_frontend_config "$API_GATEWAY_URL"
    
    cd - > /dev/null
}

# Login to ECR
login_to_ecr() {
    if [ -z "$ECR_REPOSITORY_URL" ]; then
        print_error "ECR_REPOSITORY_URL is not set"
        exit 1
    fi
    
    print_status "Logging in to ECR..."
    aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $ECR_REPOSITORY_URL
    print_success "Successfully logged in to ECR"
}

# Build and push doc_ingestor image
build_and_push_doc_ingestor() {
    print_status "Building doc_ingestor Docker image..."
    
    # Get to project root
    cd "$(dirname "$(dirname "$(pwd)")")"
    
    # Build the image from project root
    docker build -f "src/docker/Dockerfile.doc_ingestor" \
        --build-arg BUILDKIT_INLINE_CACHE=1 \
        --provenance=false \
        -t doc_ingestor:latest .
    
    # Tag for ECR
    docker tag doc_ingestor:latest $ECR_REPOSITORY_URL:doc_ingestor-latest
    
    # Push to ECR
    print_status "Pushing doc_ingestor image to ECR..."
    docker push $ECR_REPOSITORY_URL:doc_ingestor-latest
    
    print_success "doc_ingestor image built and pushed successfully"
    
    # Return to original directory
    cd - > /dev/null
}

# Build and push query_processor image
build_and_push_query_processor() {
    print_status "Building query_processor Docker image..."
    
    # Get to project root
    cd "$(dirname "$(dirname "$(pwd)")")"
    
    # Build the image from project root
    docker build -f "src/docker/Dockerfile.query_processor" \
        --build-arg BUILDKIT_INLINE_CACHE=1 \
        --provenance=false \
        -t query_processor:latest .
    
    # Tag for ECR
    docker tag query_processor:latest $ECR_REPOSITORY_URL:query_processor-latest
    
    # Push to ECR
    print_status "Pushing query_processor image to ECR..."
    docker push $ECR_REPOSITORY_URL:query_processor-latest
    
    print_success "query_processor image built and pushed successfully"
    
    # Return to original directory
    cd - > /dev/null
}

# Update Lambda functions
update_lambda_functions() {
    print_status "Updating Lambda functions with new images..."
    
    # Update doc_ingestor
    print_status "Updating doc_ingestor Lambda function..."
    local output_file=$(mktemp)
    if aws lambda update-function-code \
        --function-name aws-ai-assistant-doc-ingestor \
        --image-uri $ECR_REPOSITORY_URL:doc_ingestor-latest \
        --region $AWS_REGION \
        --no-cli-pager \
        --output json > "$output_file" 2>&1; then
        print_success "doc_ingestor Lambda function updated successfully"
        rm -f "$output_file"
    else
        print_error "Failed to update doc_ingestor Lambda function"
        print_error "AWS CLI output:"
        cat "$output_file" >&2
        rm -f "$output_file"
        exit 1
    fi
    
    # Update query_processor
    print_status "Updating query_processor Lambda function..."
    if [ -z "$ECR_REPOSITORY_URL" ]; then
        print_error "ECR_REPOSITORY_URL is not set. Cannot update query_processor."
        exit 1
    fi
    print_status "Function: aws-ai-assistant-query-processor"
    print_status "Image URI: $ECR_REPOSITORY_URL:query_processor-latest"
    output_file=$(mktemp)
    if aws lambda update-function-code \
        --function-name aws-ai-assistant-query-processor \
        --image-uri $ECR_REPOSITORY_URL:query_processor-latest \
        --region $AWS_REGION \
        --no-cli-pager \
        --output json > "$output_file" 2>&1; then
        print_success "query_processor Lambda function updated successfully"
        rm -f "$output_file"
    else
        print_error "Failed to update query_processor Lambda function"
        print_error "AWS CLI output:"
        cat "$output_file" >&2
        rm -f "$output_file"
        exit 1
    fi
    
    print_success "All Lambda functions updated successfully"
}

# Wait for Lambda functions to be active
wait_for_lambda_functions() {
    print_status "Waiting for Lambda functions to be active..."
    
    # Wait for doc_ingestor
    print_status "Waiting for doc_ingestor to be active..."
    aws lambda wait function-active --function-name aws-ai-assistant-doc-ingestor --region $AWS_REGION
    
    # Wait for query_processor
    print_status "Waiting for query_processor to be active..."
    aws lambda wait function-active --function-name aws-ai-assistant-query-processor --region $AWS_REGION
    
    print_success "All Lambda functions are active"
}

# Initialize OpenSearch index
initialize_opensearch_index() {
    print_status "Initializing OpenSearch index..."
    
    # Create a temporary Python script to initialize the index
    cat > /tmp/init_opensearch.py << EOF
import os
import json
import boto3
from opensearchpy import OpenSearch, RequestsHttpConnection
from requests_aws4auth import AWS4Auth

# Configuration
OPENSEARCH_ENDPOINT = "$OPENSEARCH_ENDPOINT"
AWS_REGION = "$AWS_REGION"
INDEX_NAME = "kb_chunks"

# Setup OpenSearch client
session = boto3.Session()
credentials = session.get_credentials()
awsauth = AWS4Auth(credentials.access_key, credentials.secret_key, AWS_REGION, 'aoss', session_token=credentials.token)

os_client = OpenSearch(
    hosts=[{'host': OPENSEARCH_ENDPOINT.replace('https://',''), 'port': 443}],
    http_auth=awsauth,
    use_ssl=True,
    verify_certs=True,
    connection_class=RequestsHttpConnection
)

# Index mapping from the config file
index_mapping = {
    "settings": {
        "index.knn": True
    },
    "mappings": {
        "properties": {
            "embedding": {
                "type": "knn_vector",
                "dimension": 1024,
                "space_type": "cosinesimil",
                "mode": "on_disk",
                "compression_level": "16x",
                "method": {
                    "name": "hnsw",
                    "engine": "faiss",
                    "parameters": {
                        "m": 16,
                        "ef_construction": 100
                    }
                }
            },
            "chunk_text": {"type": "text"},
            "doc_id": {"type": "keyword"},
            "chunk_id": {"type": "integer"},
            "title": {"type": "text"},
            "section": {"type": "text"},
            "source": {"type": "keyword"},
            "s3_key": {"type": "keyword"},
            "url": {"type": "keyword"},
            "tags": {"type": "keyword"},
            "token_count": {"type": "integer"},
            "created_at": {"type": "date"},
            "updated_at": {"type": "date"}
        }
    }
}

try:
    # Check if index exists
    if os_client.indices.exists(index=INDEX_NAME):
        print(f"Index {INDEX_NAME} already exists")
    else:
        # Create the index
        os_client.indices.create(index=INDEX_NAME, body=index_mapping)
        print(f"Successfully created index {INDEX_NAME}")
except Exception as e:
    print(f"Error creating index: {e}")
    exit(1)
EOF

    # Install required Python packages
    print_status "Installing required Python packages..."
    pip3 install opensearch-py requests-aws4auth boto3 --quiet --no-warn-script-location
    
    # Run the initialization script
    python3 /tmp/init_opensearch.py
    
    # Clean up
    rm /tmp/init_opensearch.py
    
    print_success "OpenSearch index initialized successfully"
}

# Display deployment summary
display_summary() {
    print_success "Deployment completed successfully!"
    echo
    print_status "Deployment Summary:"
    echo "===================="
    echo "• ECR Repository: $ECR_REPOSITORY_URL"
    echo "• OpenSearch Endpoint: $OPENSEARCH_ENDPOINT"
    echo "• API Gateway URL: $API_GATEWAY_URL"
    echo
    print_status "Test the deployment:"
    echo "• Upload a document to S3 bucket 'aws-knowledge-assistant-docs-east1-232' in the 'ingest/' folder"
    echo "• Query the API: curl -X POST $API_GATEWAY_URL -H 'Content-Type: application/json' -d '{\"question\": \"Your question here\"}'"
    echo
    print_status "Lambda Functions:"
    echo "• doc_ingestor: aws-ai-assistant-doc-ingestor"
    echo "• query_processor: aws-ai-assistant-query-processor"
}

# Parse command-line arguments
parse_arguments() {
    UPDATE_MODE=false
    GEN_INFERENCE_PROFILE_ID_ARG=""
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --update)
                UPDATE_MODE=true
                shift
                ;;
            --gen-inference-profile-id)
                GEN_INFERENCE_PROFILE_ID_ARG="$2"
                shift 2
                ;;
            *)
                print_error "Unknown option: $1"
                echo "Usage: $0 [--update] [--gen-inference-profile-id <PROFILE_ID_OR_ARN>]"
                echo "  --update: Skip Terraform deployment and only update Lambda functions"
                echo "  --gen-inference-profile-id: Bedrock inference profile ID/ARN for generation"
                exit 1
                ;;
        esac
    done

    # Determine effective inference profile ID (arg takes precedence over env)
    if [ -n "$GEN_INFERENCE_PROFILE_ID_ARG" ]; then
        GEN_INFERENCE_PROFILE_ID="$GEN_INFERENCE_PROFILE_ID_ARG"
    else
        GEN_INFERENCE_PROFILE_ID="$GEN_INFERENCE_PROFILE_ID_ENV_DEFAULT"
    fi
}

# Deploy infrastructure (Terraform + Lambda updates)
deploy_infrastructure() {
    if [ "$UPDATE_MODE" = false ]; then
        # Stage 1: Deploy ECR and basic infrastructure
        deploy_infrastructure_stage1
        
        # Build and push images before creating Lambda functions
        login_to_ecr
        build_and_push_doc_ingestor
        build_and_push_query_processor
        
        # Stage 2: Deploy remaining infrastructure (including Lambda functions)
        deploy_terraform
    else
        print_status "Update mode: Skipping Terraform deployment"
        # Get existing outputs from Terraform state
        cd "$(pwd)/$TERRAFORM_DIR"
        print_status "Reading existing Terraform outputs..."
        ECR_REPOSITORY_URL=$(terraform output -raw ecr_repository_url)
        OPENSEARCH_ENDPOINT=$(terraform output -raw opensearch_collection_endpoint)
        API_GATEWAY_URL=$(terraform output -raw api_gateway_query_endpoint)
        if terraform output -raw http_api_ask_endpoint >/dev/null 2>&1; then
            API_GATEWAY_URL=$(terraform output -raw http_api_ask_endpoint)
        fi
        
        print_status "ECR Repository URL: $ECR_REPOSITORY_URL"
        print_status "OpenSearch Endpoint: $OPENSEARCH_ENDPOINT"
        print_status "API Gateway URL: $API_GATEWAY_URL"
        # Generate frontend config in update mode as well
        write_frontend_config "$API_GATEWAY_URL"
        cd - > /dev/null
    fi
}

# Main execution
main() {
    print_status "Starting AWS AI Assistant Lambda Container Deployment"
    echo "=============================================================="
    
    parse_arguments "$@"
    
    check_prerequisites
    
    if [ "$UPDATE_MODE" = true ]; then
        print_warning "Running in UPDATE MODE - will skip Terraform and only update Lambda functions"
    fi
    
    get_aws_account_id
    deploy_infrastructure
    
    if [ "$UPDATE_MODE" = true ]; then
        # In update mode, we need to build and push images
        login_to_ecr
        build_and_push_doc_ingestor
        build_and_push_query_processor
        update_lambda_functions
        wait_for_lambda_functions
    else
        # In fresh deployment mode, images were already pushed during deploy_infrastructure
        # Lambda functions were already created with the images
        print_status "Lambda functions already created with images during deployment"
    fi
    
    if [ "$UPDATE_MODE" = false ]; then
        initialize_opensearch_index
    fi
    
    display_summary
}

# Run main function
main "$@"
