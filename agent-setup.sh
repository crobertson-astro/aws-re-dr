#!/bin/bash
set -euo pipefail

# verify script run from repo root
if [[ ! -d "infra" || ! -d "astro" ]]; then
    echo "Error: This script must be run from the root of the repository."
    exit 1
fi

echo "Retrieving Terraform outputs..."
cd infra
TF_OUTPUT_JSON=$(terraform output -json)
cd ..

echo "Parsing Terraform outputs..."
AGENT_TOKEN=$(echo $TF_OUTPUT_JSON | jq -r .astro_agent_token.value)
DEPLOYMENT_ADMIN_TOKEN=$(echo $TF_OUTPUT_JSON | jq -r .astro_deployment_admin_token.value)

PRIMARY_ECR_REPO_NAME=$(echo $TF_OUTPUT_JSON | jq -r .primary.value.ecr_repo_name)
PRIMARY_ECR_REPO_URL=$(echo $TF_OUTPUT_JSON | jq -r .primary.value.ecr_repo_url)
echo "Primary ECR repo URL: $PRIMARY_ECR_REPO_URL"
PRIMARY_REGION=$(echo $TF_OUTPUT_JSON | jq -r .primary.value.region)
echo "Primary region: $PRIMARY_REGION"

FAILOVER_ECR_REPO_NAME=$(echo $TF_OUTPUT_JSON | jq -r .failover.value.ecr_repo_name)
FAILOVER_ECR_REPO_URL=$(echo $TF_OUTPUT_JSON | jq -r .failover.value.ecr_repo_url)
echo "Failover ECR repo URL: $FAILOVER_ECR_REPO_URL"
FAILOVER_REGION=$(echo $TF_OUTPUT_JSON | jq -r .failover.value.region)
echo "Failover region: $FAILOVER_REGION"

cd astro

echo "Primary region: Logging in to ECR..."
aws ecr get-login-password --region "$PRIMARY_REGION" | \
    docker login --username AWS --password-stdin "$PRIMARY_ECR_REPO_URL"
echo "Primary region: Deploying to Astronomer..."
astro config set remote.client_registry "$PRIMARY_ECR_REPO_URL"
astro remote deploy --platform linux/amd64
PRIMARY_IMAGE_TAG=$(aws ecr describe-images --repository-name "$PRIMARY_ECR_REPO_NAME" --query 'sort_by(imageDetails, &imagePushedAt)[-1].imageTags' --output text)

cd ..