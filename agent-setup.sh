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

ASTRO_DEPLOYMENT_API_URL=$(echo $TF_OUTPUT_JSON | jq -r .astro_deployment_remote_exec_api_url.value)
ASTRO_ORGANIZATION_ID=$(echo $TF_OUTPUT_JSON | jq -r .astro_organization_id.value)
ASTRO_WORKSPACE_ID=$(echo $TF_OUTPUT_JSON | jq -r .astro_workspace_id.value)
ASTRO_DEPLOYMENT_ID=$(echo $TF_OUTPUT_JSON | jq -r .astro_deployment_id.value)
ASTRO_DEPLOYMENT_NAMESPACE=$(echo $TF_OUTPUT_JSON | jq -r .astro_deployment_namespace.value)

echo "Initalizing Helm..."
helm repo add astronomer https://helm.astronomer.io
helm repo update

for REGION_KEY in failover primary; do
  echo "Setting up agent for $REGION_KEY region..."
  ECR_REPO_NAME=$(echo $TF_OUTPUT_JSON | jq -r .$REGION_KEY.value.ecr_repo_name)
  ECR_REPO_URL=$(echo $TF_OUTPUT_JSON | jq -r .$REGION_KEY.value.ecr_repo_url)
  REGION=$(echo $TF_OUTPUT_JSON | jq -r .$REGION_KEY.value.region)
  EKS_CLUSTER_NAME=$(echo $TF_OUTPUT_JSON | jq -r .$REGION_KEY.value.eks_cluster_name)
  S3_BUCKET_NAME=$(echo $TF_OUTPUT_JSON | jq -r .$REGION_KEY.value.s3_bucket_name)
  echo "$REGION_KEY ECR repo URL: $ECR_REPO_URL"
  echo "$REGION_KEY AWS region: $REGION"
  echo "$REGION_KEY EKS cluster name: $EKS_CLUSTER_NAME"

  echo "$REGION_KEY: Logging in to ECR..."
  aws ecr get-login-password --region "$REGION" | \
      docker login --username AWS --password-stdin "$ECR_REPO_URL"
  echo "$REGION_KEY: Deploying to Astronomer..."
  (cd astro && \
    astro config set remote.client_registry "$ECR_REPO_URL" && \
    astro remote deploy --platform linux/amd64)
  IMAGE_TAG=$(aws ecr describe-images --repository-name "$ECR_REPO_NAME" --region "$REGION" --query 'sort_by(imageDetails, &imagePushedAt)[-1].imageTags' --output text)

  echo "$REGION_KEY: Configuring kubectl..."
  # Switch contexts with `kubectl config use-context primary` / `failover`.
  aws eks update-kubeconfig --name "$EKS_CLUSTER_NAME" --region "$REGION" --alias "$REGION_KEY"
  kubectl config use-context "$REGION_KEY"

  echo "$REGION_KEY: Creating Kubernetes secrets..."
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

  echo "$REGION_KEY: Deploying Astro Remote Agent..."
  helm uninstall astro-agent -n default --ignore-not-found
  helm install astro-agent astronomer/astro-remote-execution-agent \
    -n default -f values.yaml \
    --set resourceNamePrefix=$REGION_KEY \
    --set astroDeploymentAPIURL=$ASTRO_DEPLOYMENT_API_URL \
    --set image=$ECR_REPO_URL:$IMAGE_TAG \
    --set imagePullSecretName=image-pull-secret \
    --set agentTokenSecretName=agent-token \
    --set commonEnv[0].name=ASTRO_ORGANIZATION_ID \
    --set commonEnv[0].value=$ASTRO_ORGANIZATION_ID \
    --set commonEnv[1].name=ASTRO_WORKSPACE_ID \
    --set commonEnv[1].value=$ASTRO_WORKSPACE_ID \
    --set commonEnv[2].name=ASTRO_DEPLOYMENT_ID \
    --set commonEnv[2].value=$ASTRO_DEPLOYMENT_ID \
    --set commonEnv[3].name=ASTRO_DEPLOYMENT_NAMESPACE \
    --set commonEnv[3].value=$ASTRO_DEPLOYMENT_NAMESPACE \
    --set commonEnv[4].name=AWS_REGION \
    --set commonEnv[4].value=$REGION \
    --set commonEnv[5].name=AIRFLOW__COMMON_IO__XCOM_OBJECTSTORAGE_PATH \
    --set commonEnv[5].value=s3://$S3_BUCKET_NAME/$ASTRO_DEPLOYMENT_ID/xcom \
    --set annotations."eks\.amazonaws\.com/role-arn"="$AGENT_IAM_ROLE_ARN" \
    --set openLineage.namespace=$ASTRO_DEPLOYMENT_NAMESPACE \
    --set openLineage.endpoint="/api/v1/lineage?ASTRO_DEPLOYMENT_ID=$ASTRO_DEPLOYMENT_ID&ASTRO_DEPLOYMENT_NAMESPACE=$ASTRO_DEPLOYMENT_NAMESPACE&ASTRO_ORGANIZATION_ID=$ASTRO_ORGANIZATION_ID&ASTRO_WORKSPACE_ID=$ASTRO_WORKSPACE_ID" \
    --set openLineage.apiKeySecret=deployment-api-token

  echo "$REGION_KEY: Deployment complete."
done

# to upgrade: helm upgrade ...

echo "Scaling down failover deployments..."
kubectl config use-context failover
kubectl scale deployment --all --replicas=0
kubectl config use-context primary

echo "Verify with 'kubectl get pods -n default'."
echo "Inspect logs with 'kubectl logs <pod-name> -n default --tail=100'."
