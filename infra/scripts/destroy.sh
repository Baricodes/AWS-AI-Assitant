#!/bin/bash

# AWS AI Assistant Infrastructure Destroy Script
# This script safely destroys all Terraform infrastructure after cleaning up ECR repositories and S3 buckets

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration
AWS_REGION="us-east-1"

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Get the project root (assuming script is in infra/scripts/)
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TERRAFORM_DIR="$PROJECT_ROOT/infra/terraform"
SCRIPTS_DIR="$PROJECT_ROOT/infra/scripts"

# Global variables
DRY_RUN=false
FORCE=false
CONFIRMED=false

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

print_destroy() {
    echo -e "${CYAN}[DESTROY]${NC} $1"
}

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Show usage information
show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo
    echo "Options:"
    echo "  --dry-run    Show what would be destroyed without actually destroying anything"
    echo "  --force      Skip confirmation prompts and destroy immediately"
    echo "  --help       Show this help message"
    echo
    echo "This script will:"
    echo "  1. Empty all ECR repositories"
    echo "  2. Empty all S3 buckets"
    echo "  3. Destroy all Terraform-managed infrastructure"
    echo
}

# Parse command line arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --force)
                FORCE=true
                shift
                ;;
            --help)
                show_usage
                exit 0
                ;;
            *)
                print_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done
}

# Check prerequisites
check_prerequisites() {
    print_status "Checking prerequisites..."
    
    local missing_tools=()
    
    if ! command_exists aws; then
        missing_tools+=("aws")
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

# Get AWS account ID and validate credentials
get_aws_account_id() {
    print_status "Validating AWS credentials..."
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")
    if [ -z "$AWS_ACCOUNT_ID" ]; then
        print_error "Failed to get AWS account ID. Please check your AWS credentials."
        print_error "Run 'aws configure' to set up your credentials."
        exit 1
    fi
    print_success "AWS Account ID: $AWS_ACCOUNT_ID"
}

# Check if Terraform state exists
check_terraform_state() {
    print_status "Checking Terraform state..."
    
    if [ ! -d "$TERRAFORM_DIR" ]; then
        print_error "Terraform directory not found: $TERRAFORM_DIR"
        exit 1
    fi
    
    cd "$TERRAFORM_DIR"
    
    if [ ! -f "terraform.tfstate" ] && [ ! -f ".terraform/terraform.tfstate" ]; then
        print_warning "No Terraform state file found. Infrastructure may not exist."
        cd - > /dev/null
        return 1
    fi
    
    # Initialize Terraform to ensure we can read outputs
    if [ ! -d ".terraform" ]; then
        print_status "Initializing Terraform..."
        terraform init -input=false
    fi
    
    cd - > /dev/null
    print_success "Terraform state found"
    return 0
}

# Get Terraform outputs
get_terraform_outputs() {
    print_status "Getting Terraform outputs..."
    
    cd "$TERRAFORM_DIR"
    
    # Check if we can get outputs
    if ! terraform output > /dev/null 2>&1; then
        print_warning "Cannot read Terraform outputs. Infrastructure may already be destroyed."
        cd - > /dev/null
        return 1
    fi
    
    # Get ECR repository URL
    ECR_REPOSITORY_URL=$(terraform output -raw ecr_repository_url 2>/dev/null || echo "")
    
    # Get S3 bucket name
    S3_BUCKET_NAME=$(terraform output -raw s3_bucket_name 2>/dev/null || echo "")
    
    cd - > /dev/null
    
    if [ -n "$ECR_REPOSITORY_URL" ]; then
        print_status "Found ECR Repository: $ECR_REPOSITORY_URL"
    fi
    
    if [ -n "$S3_BUCKET_NAME" ]; then
        print_status "Found S3 Bucket: $S3_BUCKET_NAME"
    fi
    
    return 0
}

# Empty ECR repository
empty_ecr_repository() {
    if [ -z "$ECR_REPOSITORY_URL" ]; then
        print_warning "No ECR repository URL found, skipping ECR cleanup"
        return 0
    fi
    
    local repo_name
    repo_name=$(echo "$ECR_REPOSITORY_URL" | cut -d'/' -f2)
    
    print_destroy "Emptying ECR repository: $repo_name"
    
    if [ "$DRY_RUN" = true ]; then
        print_status "[DRY RUN] Would delete all images from ECR repository: $repo_name"
        return 0
    fi
    
    # Check if repository exists
    if ! aws ecr describe-repositories --repository-names "$repo_name" --region "$AWS_REGION" > /dev/null 2>&1; then
        print_warning "ECR repository $repo_name not found, skipping cleanup"
        return 0
    fi
    
    # Get all images in the repository
    local images
    images=$(aws ecr list-images --repository-name "$repo_name" --region "$AWS_REGION" --output json)
    
    # Check if there are any images
    local image_count
    image_count=$(echo "$images" | jq '.imageIds | length')
    
    if [ "$image_count" -eq 0 ]; then
        print_status "ECR repository is already empty"
        return 0
    fi
    
    print_status "Found $image_count images to delete"
    
    # Delete all images
    echo "$images" | jq -c '.imageIds[]' | while read -r image; do
        local image_tag
        local image_digest
        image_tag=$(echo "$image" | jq -r '.imageTag // "null"')
        image_digest=$(echo "$image" | jq -r '.imageDigest // "null"')
        
        if [ "$image_tag" != "null" ]; then
            print_status "Deleting image with tag: $image_tag"
        elif [ "$image_digest" != "null" ]; then
            print_status "Deleting image with digest: ${image_digest:0:20}..."
        fi
    done
    
    # Batch delete all images
    aws ecr batch-delete-image \
        --repository-name "$repo_name" \
        --region "$AWS_REGION" \
        --image-ids "$(echo "$images" | jq -c '.imageIds')" > /dev/null
    
    print_success "ECR repository emptied successfully"
}

# Empty S3 bucket
empty_s3_bucket() {
    if [ -z "$S3_BUCKET_NAME" ]; then
        print_warning "No S3 bucket name found, skipping S3 cleanup"
        return 0
    fi
    
    print_destroy "Emptying S3 bucket: $S3_BUCKET_NAME"
    
    if [ "$DRY_RUN" = true ]; then
        print_status "[DRY RUN] Would delete all objects from S3 bucket: $S3_BUCKET_NAME"
        return 0
    fi
    
    # Check if bucket exists
    if ! aws s3api head-bucket --bucket "$S3_BUCKET_NAME" --region "$AWS_REGION" > /dev/null 2>&1; then
        print_warning "S3 bucket $S3_BUCKET_NAME not found, skipping cleanup"
        return 0
    fi
    
    # Delete all objects and versions
    print_status "Deleting all objects in bucket..."
    aws s3 rm "s3://$S3_BUCKET_NAME" --recursive --region "$AWS_REGION" || true
    
    # Delete all object versions if versioning is enabled
    print_status "Deleting all object versions..."
    aws s3api list-object-versions --bucket "$S3_BUCKET_NAME" --region "$AWS_REGION" --output json | \
    jq -r '.Versions[]? | .Key + " " + .VersionId' | \
    while read -r key version_id; do
        if [ -n "$key" ] && [ -n "$version_id" ]; then
            aws s3api delete-object --bucket "$S3_BUCKET_NAME" --key "$key" --version-id "$version_id" --region "$AWS_REGION" > /dev/null || true
        fi
    done
    
    # Delete all delete markers
    print_status "Deleting all delete markers..."
    aws s3api list-object-versions --bucket "$S3_BUCKET_NAME" --region "$AWS_REGION" --output json | \
    jq -r '.DeleteMarkers[]? | .Key + " " + .VersionId' | \
    while read -r key version_id; do
        if [ -n "$key" ] && [ -n "$version_id" ]; then
            aws s3api delete-object --bucket "$S3_BUCKET_NAME" --key "$key" --version-id "$version_id" --region "$AWS_REGION" > /dev/null || true
        fi
    done
    
    # Abort incomplete multipart uploads
    print_status "Aborting incomplete multipart uploads..."
    aws s3api list-multipart-uploads --bucket "$S3_BUCKET_NAME" --region "$AWS_REGION" --output json | \
    jq -r '.Uploads[]? | .Key + " " + .UploadId' | \
    while read -r key upload_id; do
        if [ -n "$key" ] && [ -n "$upload_id" ]; then
            aws s3api abort-multipart-upload --bucket "$S3_BUCKET_NAME" --key "$key" --upload-id "$upload_id" --region "$AWS_REGION" > /dev/null || true
        fi
    done
    
    print_success "S3 bucket emptied successfully"
}

# Run Terraform destroy
destroy_terraform() {
    print_destroy "Destroying Terraform infrastructure..."
    
    cd "$TERRAFORM_DIR"
    
    if [ "$DRY_RUN" = true ]; then
        print_status "[DRY RUN] Would run: terraform destroy -auto-approve"
        cd - > /dev/null
        return 0
    fi
    
    # Run terraform destroy
    print_status "Running terraform destroy..."
    terraform destroy -auto-approve
    
    print_success "Terraform infrastructure destroyed successfully"
    cd - > /dev/null
}

# Get confirmation from user
get_confirmation() {
    if [ "$FORCE" = true ]; then
        CONFIRMED=true
        return 0
    fi
    
    echo
    print_warning "This will permanently destroy all AWS infrastructure managed by Terraform!"
    print_warning "This includes:"
    echo "  • ECR repositories and all Docker images"
    echo "  • S3 buckets and all stored documents"
    echo "  • Lambda functions"
    echo "  • API Gateway"
    echo "  • DynamoDB tables"
    echo "  • OpenSearch Serverless collections"
    echo "  • IAM roles and policies"
    echo
    
    if [ "$DRY_RUN" = true ]; then
        print_status "Running in dry-run mode - no resources will actually be destroyed"
        CONFIRMED=true
        return 0
    fi
    
    read -r -p "Are you sure you want to proceed? [y/N]: " response
    case "$response" in
        [yY][eE][sS]|[yY])
            CONFIRMED=true
            ;;
        *)
            CONFIRMED=false
            ;;
    esac
}

# Display summary of what was destroyed
display_summary() {
    echo
    if [ "$DRY_RUN" = true ]; then
        print_success "Dry run completed successfully!"
        echo "The following would be destroyed:"
    else
        print_success "Infrastructure destruction completed successfully!"
        echo "The following resources were destroyed:"
    fi
    
    echo "=================="
    [ -n "$ECR_REPOSITORY_URL" ] && echo "• ECR Repository: $ECR_REPOSITORY_URL"
    [ -n "$S3_BUCKET_NAME" ] && echo "• S3 Bucket: $S3_BUCKET_NAME"
    echo "• All Lambda functions"
    echo "• API Gateway"
    echo "• DynamoDB tables"
    echo "• OpenSearch Serverless collections"
    echo "• IAM roles and policies"
    echo
    
    if [ "$DRY_RUN" = false ]; then
        print_status "AWS resources have been completely removed."
        print_status "You may want to clean up any local Terraform state files if desired."
    fi
}

# Main execution
main() {
    print_status "Starting AWS AI Assistant Infrastructure Destruction"
    echo "=============================================================="
    
    # Parse command line arguments
    parse_arguments "$@"
    
    # Run prerequisite checks
    check_prerequisites
    get_aws_account_id
    
    # Check if infrastructure exists
    if ! check_terraform_state; then
        print_warning "No Terraform state found. Infrastructure may not exist or has already been destroyed."
        exit 0
    fi
    
    # Get infrastructure details
    if ! get_terraform_outputs; then
        print_warning "Cannot read Terraform outputs. Proceeding with destruction anyway."
    fi
    
    # Get user confirmation
    get_confirmation
    
    if [ "$CONFIRMED" = false ]; then
        print_status "Destruction cancelled by user."
        exit 0
    fi
    
    # Perform the destruction sequence
    empty_ecr_repository
    empty_s3_bucket
    destroy_terraform
    
    # Show summary
    display_summary
}

# Run main function with all arguments
main "$@"
