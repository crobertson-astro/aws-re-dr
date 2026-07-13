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

GIT_BUNDLE_REPO_URL=${GIT_BUNDLE_REPO_URL:-$(git remote get-url origin)}
GIT_BUNDLE_TRACKING_REF=${GIT_BUNDLE_TRACKING_REF:-$(git branch --show-current)}
GIT_BUNDLE_TRACKING_REF=${GIT_BUNDLE_TRACKING_REF:-$(git rev-parse --verify HEAD)}
GIT_BUNDLE_SUBDIR=${GIT_BUNDLE_SUBDIR:-astro/dags}
HELM_GIT_CONNECTION_ARGS=()

if [[ -n "${GIT_USERNAME:-}" || -n "${GIT_PAT:-}" ]]; then
  if [[ -z "${GIT_USERNAME:-}" || -z "${GIT_PAT:-}" ]]; then
    echo "Error: Set both GIT_USERNAME and GIT_PAT, or leave both unset for a public repository."
    exit 1
  fi

  GIT_CONN_HOST=${GIT_BUNDLE_REPO_URL#https://}
  GIT_CONN_HOST=${GIT_CONN_HOST#http://}
  GIT_CONN_REPO=${GIT_CONN_HOST#*/}
  GIT_CONN_HOST=${GIT_CONN_HOST%%/*}
  GIT_CONN_REPO=${GIT_CONN_REPO%.git}

  AIRFLOW_CONN_GIT_REPO=$(jq -cn \
    --arg login "$GIT_USERNAME" \
    --arg password "$GIT_PAT" \
    --arg host "$GIT_CONN_HOST" \
    --arg repo "$GIT_CONN_REPO" \
    --arg branch "$GIT_BUNDLE_TRACKING_REF" \
    '{conn_type: "git", login: $login, password: $password, host: $host, schema: "https", extra: {repo: $repo, branch: $branch}}')
  AIRFLOW_CONN_GIT_REPO_FILE=$(mktemp)
  chmod 600 "$AIRFLOW_CONN_GIT_REPO_FILE"
  printf '%s' "$AIRFLOW_CONN_GIT_REPO" > "$AIRFLOW_CONN_GIT_REPO_FILE"
  HELM_GIT_CONNECTION_ARGS=(
    --set commonEnv[8].name=AIRFLOW_CONN_GIT_REPO
    --set-file commonEnv[8].value="$AIRFLOW_CONN_GIT_REPO_FILE"
  )
  DAG_BUNDLE_CONFIG=$(jq -cn \
    --arg repo_url "$GIT_BUNDLE_REPO_URL" \
    --arg tracking_ref "$GIT_BUNDLE_TRACKING_REF" \
    --arg subdir "$GIT_BUNDLE_SUBDIR" \
    '[{"name": "repo-dags", "classpath": "airflow.providers.git.bundles.git.GitDagBundle", "kwargs": {"repo_url": $repo_url, "tracking_ref": $tracking_ref, "subdir": $subdir, "git_conn_id": "git_repo"}}]')
else
  DAG_BUNDLE_CONFIG=$(jq -cn \
    --arg repo_url "$GIT_BUNDLE_REPO_URL" \
    --arg tracking_ref "$GIT_BUNDLE_TRACKING_REF" \
    --arg subdir "$GIT_BUNDLE_SUBDIR" \
    '[{"name": "repo-dags", "classpath": "airflow.providers.git.bundles.git.GitDagBundle", "kwargs": {"repo_url": $repo_url, "tracking_ref": $tracking_ref, "subdir": $subdir}}]')
fi

DAG_BUNDLE_CONFIG_FILE=$(mktemp)
chmod 600 "$DAG_BUNDLE_CONFIG_FILE"
printf '%s' "$DAG_BUNDLE_CONFIG" > "$DAG_BUNDLE_CONFIG_FILE"
trap 'rm -f "${AIRFLOW_CONN_GIT_REPO_FILE:-}" "$DAG_BUNDLE_CONFIG_FILE"' EXIT

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
  HELM_ARGS=(
    install astro-agent astronomer/astro-remote-execution-agent
    -n default -f values.yaml
    --set resourceNamePrefix="$REGION_KEY"
    --set astroDeploymentAPIURL="$ASTRO_DEPLOYMENT_API_URL"
    --set image="$ECR_REPO_URL:$IMAGE_TAG"
    --set imagePullSecretName=image-pull-secret
    --set agentTokenSecretName=agent-token
    --set commonEnv[0].name=ASTRO_ORGANIZATION_ID
    --set commonEnv[0].value="$ASTRO_ORGANIZATION_ID"
    --set commonEnv[1].name=ASTRO_WORKSPACE_ID
    --set commonEnv[1].value="$ASTRO_WORKSPACE_ID"
    --set commonEnv[2].name=ASTRO_DEPLOYMENT_ID
    --set commonEnv[2].value="$ASTRO_DEPLOYMENT_ID"
    --set commonEnv[3].name=ASTRO_DEPLOYMENT_NAMESPACE
    --set commonEnv[3].value="$ASTRO_DEPLOYMENT_NAMESPACE"
    --set commonEnv[4].name=AWS_REGION
    --set commonEnv[4].value="$REGION"
    --set commonEnv[5].name=AIRFLOW__COMMON_IO__XCOM_OBJECTSTORAGE_PATH
    --set commonEnv[5].value="s3://$S3_BUCKET_NAME/$ASTRO_DEPLOYMENT_ID/xcom"
    --set-file dagBundleConfigList="$DAG_BUNDLE_CONFIG_FILE"
  )
  if ((${#HELM_GIT_CONNECTION_ARGS[@]})); then
    HELM_ARGS+=("${HELM_GIT_CONNECTION_ARGS[@]}")
  fi
  HELM_ARGS+=(
    --set annotations."eks\.amazonaws\.com/role-arn"="$AGENT_IAM_ROLE_ARN"
    --set openLineage.namespace="$ASTRO_DEPLOYMENT_NAMESPACE"
    --set openLineage.endpoint="/api/v1/lineage?ASTRO_DEPLOYMENT_ID=$ASTRO_DEPLOYMENT_ID&ASTRO_DEPLOYMENT_NAMESPACE=$ASTRO_DEPLOYMENT_NAMESPACE&ASTRO_ORGANIZATION_ID=$ASTRO_ORGANIZATION_ID&ASTRO_WORKSPACE_ID=$ASTRO_WORKSPACE_ID"
    --set openLineage.apiKeySecret=deployment-api-token
  )
  helm "${HELM_ARGS[@]}"

  echo "$REGION_KEY: Deployment complete."
done

# to upgrade: helm upgrade ...

echo "Scaling down failover deployments..."
kubectl config use-context failover
kubectl scale deployment --all --replicas=0
kubectl config use-context primary

echo "Verify with 'kubectl get pods -n default'."
echo "Inspect logs with 'kubectl logs <pod-name> -n default --tail=100'."
