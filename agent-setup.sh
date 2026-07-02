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
AGENT_IAM_ROLE_ARN=$(echo $TF_OUTPUT_JSON | jq -r .agent_iam_role_arn.value)
DEPLOYMENT_ADMIN_TOKEN=$(echo $TF_OUTPUT_JSON | jq -r .astro_deployment_admin_token.value)

ASTRO_DEPLOYMENT_API_URL=https://$(echo $TF_OUTPUT_JSON | jq -r .astro_deployment_webserver_ingress_hostname.value | sed 's/.astronomer.run/.external.astronomer.run/')
ASTRO_ORGANIZATION_ID=$(echo $TF_OUTPUT_JSON | jq -r .astro_organization_id.value)
ASTRO_WORKSPACE_ID=$(echo $TF_OUTPUT_JSON | jq -r .astro_workspace_id.value)
ASTRO_DEPLOYMENT_ID=$(echo $TF_OUTPUT_JSON | jq -r .astro_deployment_id.value)
ASTRO_DEPLOYMENT_NAMESPACE=$(echo $TF_OUTPUT_JSON | jq -r .astro_deployment_namespace.value)

PRIMARY_ECR_REPO_NAME=$(echo $TF_OUTPUT_JSON | jq -r .primary.value.ecr_repo_name)
PRIMARY_ECR_REPO_URL=$(echo $TF_OUTPUT_JSON | jq -r .primary.value.ecr_repo_url)
PRIMARY_REGION=$(echo $TF_OUTPUT_JSON | jq -r .primary.value.region)
PRIMARY_EKS_CLUSTER_NAME=$(echo $TF_OUTPUT_JSON | jq -r .primary.value.eks_cluster_name)
PRIMARY_S3_BUCKET_NAME=$(echo $TF_OUTPUT_JSON | jq -r .primary.value.s3_bucket_name)
echo "Primary ECR repo URL: $PRIMARY_ECR_REPO_URL"
echo "Primary AWS region: $PRIMARY_REGION"
echo "Primary EKS cluster name: $PRIMARY_EKS_CLUSTER_NAME"

cd astro

echo "Primary: Logging in to ECR..."
aws ecr get-login-password --region "$PRIMARY_REGION" | \
    docker login --username AWS --password-stdin "$PRIMARY_ECR_REPO_URL"
echo "Primary: Deploying to Astronomer..."
astro config set remote.client_registry "$PRIMARY_ECR_REPO_URL"
astro remote deploy --platform linux/amd64
PRIMARY_IMAGE_TAG=$(aws ecr describe-images --repository-name "$PRIMARY_ECR_REPO_NAME" --query 'sort_by(imageDetails, &imagePushedAt)[-1].imageTags' --output text)

cd ..

echo "Primary: Configuring kubectl..."
aws eks update-kubeconfig --name "$PRIMARY_EKS_CLUSTER_NAME" --region "$PRIMARY_REGION" --alias primary
# Switch contexts with `kubectl config use-context primary` / `failover`.

echo "Primary: Creating Kubernetes secrets..."
# Image pull secret — uses your Deployment API token
kubectl delete secret docker-registry image-pull-secret -n default --ignore-not-found
kubectl create secret docker-registry image-pull-secret -n default \
  --docker-server=images.astronomer.cloud \
  --docker-username=cli \
  --docker-password="$DEPLOYMENT_ADMIN_TOKEN"

# Agent token
kubectl delete secret generic agent-token -n default --ignore-not-found
kubectl create secret generic agent-token -n default \
  --from-literal=token="$AGENT_TOKEN"

# OpenLineage API key — uses your Deployment API token
kubectl delete secret generic deployment-api-token -n default --ignore-not-found
kubectl create secret generic deployment-api-token -n default \
  --from-literal=api-key="$DEPLOYMENT_ADMIN_TOKEN"

echo "Primary: Initalizing Helm..."
helm repo add astronomer https://helm.astronomer.io
helm repo update
echo "Primary: Deploying Astro Remote Agent..."
helm uninstall astro-agent -n default --ignore-not-found
helm install astro-agent astronomer/astro-remote-execution-agent \
  -n default -f values.yaml \
  --set astroDeploymentAPIURL=$ASTRO_DEPLOYMENT_API_URL \
  --set image=$PRIMARY_ECR_REPO_URL:$PRIMARY_IMAGE_TAG \
  --set imagePullSecretName=image-pull-secret \
  --set agentTokenSecretName=agent-token \
  --set-json commonEnv="[ \
    {\"name\":\"ASTRO_ORGANIZATION_ID\",\"value\":\"$ASTRO_ORGANIZATION_ID\"}, \
    {\"name\":\"ASTRO_WORKSPACE_ID\",\"value\":\"$ASTRO_WORKSPACE_ID\"}, \
    {\"name\":\"ASTRO_DEPLOYMENT_ID\",\"value\":\"$ASTRO_DEPLOYMENT_ID\"}, \
    {\"name\":\"ASTRO_DEPLOYMENT_NAMESPACE\",\"value\":\"$ASTRO_DEPLOYMENT_NAMESPACE\"}, \
    {\"name\":\"AWS_REGION\",\"value\":\"$PRIMARY_REGION\"}, \
    {\"name\":\"AIRFLOW__COMMON_IO__XCOM_OBJECTSTORAGE_PATH\",\"value\":\"s3://$PRIMARY_S3_BUCKET_NAME/xcom\"}, \
    {\"name\":\"AIRFLOW__LOGGING__REMOTE_BASE_LOG_FOLDER\",\"value\":\"s3://$PRIMARY_S3_BUCKET_NAME/$ASTRO_DEPLOYMENT_ID\"} \
  ]" \
  --set-string annotations."eks\.amazonaws\.com/role-arn"="$AGENT_IAM_ROLE_ARN" \
  --set openLineage.namespace=$ASTRO_DEPLOYMENT_NAMESPACE \
  --set openLineage.endpoint="/api/v1/lineage?ASTRO_DEPLOYMENT_ID=$ASTRO_DEPLOYMENT_ID&ASTRO_DEPLOYMENT_NAMESPACE=$ASTRO_DEPLOYMENT_NAMESPACE&ASTRO_ORGANIZATION_ID=$ASTRO_ORGANIZATION_ID&ASTRO_WORKSPACE_ID=$ASTRO_WORKSPACE_ID" \
  --set openLineage.apiKeySecret=deployment-api-token

# to upgrade: helm upgrade ...

echo "Primary: Deployment complete."
echo "Verify with 'kubectl get pods -n default'."
echo "Inspect logs with 'kubectl logs <pod-name> -n default --tail=100'."
