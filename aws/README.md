# Astro Remote Execution on AWS

This template deploys the infrastructure and configuration needed to run [Astro Remote Execution](https://www.astronomer.io/docs/astro/remote-execution-overview) agents on AWS EKS.

## Architecture Overview

- **EKS cluster** — runs the Astro Remote Execution Agent pods (DAG Processor, Worker, Triggerer)
- **S3 bucket** — stores task logs and XCom data
- **ECR repository** — hosts your custom agent image
- **Secrets Manager** — stores Airflow connections and variables (including the Git connection for DAG bundles)
- **IAM roles** — IRSA-based roles for agent pods and the Astro Orchestration Plane

---

## Prerequisites

- AWS CLI configured with SSO
- Terraform >= 1.3.0
- Helm 3+
- kubectl
- Astro CLI
- Docker

---

## Step 1: Configure AWS CLI

```bash
aws configure sso
aws sso login --profile <your-profile-name>
export AWS_PROFILE=<your-profile-name>
```

---

## Step 2: Customize and apply Terraform

Copy the example file and fill in your values:

```bash
cd aws/infra
cp terraform.tfvars.example terraform.tfvars
```

`terraform.tfvars` is gitignored — your credentials will never be committed. Edit it with your environment values:

| Variable | Description | Required |
|---|---|---|
| `aws_profile` | AWS CLI profile name created with `aws sso configure` | Yes |
| `aws_account_id` | Your AWS account ID | Yes |
| `aws_region` | AWS region to deploy into | Yes |
| `project_name` | Short name used as a prefix for all resources | Yes |
| `environment` | e.g. `dev`, `staging`, `prod` | Yes |
| `owner` | Owner or team responsible for resources | Yes |
| `git_branch` | Git branch to track for DAG bundles | Yes |
| `dag_subdir` | Subdirectory within the repository containing DAG files | Yes |
| `vpc_cidr` | CIDR block for the VPC, /24 minimum | No (default: `10.0.0.0/24`) |
| `az_count` | Number of Availability Zones to use | No (default: `2`) |
| `git_repo_url` | Full HTTPS URL of your DAG repo. Leave unset to skip GitDagBundle setup. | No |
| `git_username` | GitHub username associated with the PAT. Required if `git_repo_url` is set. | No |
| `git_pat` | GitHub Personal Access Token with **Contents: Read-only** permission. Required if `git_repo_url` is set. | No |

> **Note:** AWS has a NAT Gateway quota per region (default 5). Choose a region with available quota.

Apply the Terraform:

```bash
terraform init
terraform validate
terraform plan -out tfplan
terraform apply tfplan
```

> If you haven't already, run `cd aws/infra` before these commands.

Once complete, run `terraform output` to retrieve values needed for later steps.

---

## Step 3: Create your Astro Deployment

Create an Airflow 3.x Deployment in the [Astro UI](https://cloud.astronomer.io) configured for Remote Execution mode.

---

## Step 4: Create required tokens

**Agent Token** — authenticates your agent pods to the Astro Orchestration Plane:
1. In the Astro UI, go to your Deployment → **Remote Agents** tab → **Tokens**
2. Click **+ Agent Token**, give it a name, and save the value securely

**Deployment API Token** — used to pull the agent image from Astronomer's registry and for OpenLineage:
1. Go to your Deployment → **Access** → **API Tokens** → **+ API Token**
2. Create with **Deployment Admin** permissions and save the value securely

---

## Step 5: Build and push your custom agent image

The base agent image needs the Amazon provider installed for S3 XCom and remote logging to work.

Log in to Astro and authenticate to ECR:

```bash
astro login
aws ecr get-login-password --region <aws-region> | docker login --username AWS --password-stdin <ecr_repo_url>
# ecr_repo_url is available from: terraform output ecr_repo_url
```

Then run `astro remote deploy`, which auto-generates a `Dockerfile.client` in your project and builds and pushes the image to your ECR registry. Use `--platform linux/amd64` for EKS compatibility:

```bash
astro remote deploy --platform linux/amd64
```

When prompted for the registry URL, use the `ecr_repo_url` from your Terraform output.

Once `Dockerfile.client` is generated, add the Amazon provider installation so that S3 XCom and remote logging work:

```dockerfile
# Install the Amazon provider with the S3FS extra
# Update the constraints URL to match the Airflow version in your base image
# Check https://www.astronomer.io/docs/astro/agent-release-notes for the correct version
RUN pip install --no-cache-dir "apache-airflow-providers-amazon[s3fs]" \
    --constraint "https://raw.githubusercontent.com/apache/airflow/constraints-<airflow-version>/constraints-3.12.txt"
```

> **Important:** The constraints URL must match the Airflow version embedded in your base image. For example:
> - Agent based on Airflow 3.0.3 → use `constraints-3.0.3`
> - Agent based on Airflow 3.1.0 → use `constraints-3.1.0`

Then run `astro remote deploy` again to rebuild and push with the updated `Dockerfile.client`:

```bash
astro remote deploy --platform linux/amd64
```

Note the full image tag that was pushed — you'll need it for `values.yaml`.

See the [astro remote deploy docs](https://www.astronomer.io/docs/astro/cli/astro-remote) for all available options.

---

## Step 6: Configure kubectl

```bash
aws eks update-kubeconfig --name <cluster-name> --region <aws-region>
# cluster-name is available from: terraform output eks_cluster_name
```

---

## Step 7: Create Kubernetes secrets

```bash
# Image pull secret — uses your Deployment API token
kubectl create secret docker-registry image-pull-secret -n default \
  --docker-server=images.astronomer.cloud \
  --docker-username=cli \
  --docker-password=<your-deployment-api-token>

# Agent token
kubectl create secret generic agent-token -n default \
  --from-literal=token=<your-agent-token>

# OpenLineage API key — uses your Deployment API token
kubectl create secret generic deployment-api-token -n default \
  --from-literal=api-key=<your-deployment-api-token>
```

To update a secret, delete and recreate it:

```bash
kubectl delete secret <secret-name> -n default --ignore-not-found
```

---

## Step 8: Configure values.yaml

Download the Helm chart values by clicking **Register a Remote Agent** in the Astro UI, then fill in all `<REPLACE_...>` placeholders. Most values come directly from `terraform output`:

| Placeholder | Terraform output / source |
|---|---|
| `<REPLACE_RESOURCE_NAME_PREFIX>` | Choose a name prefix for your k8s resources |
| `<REPLACE_ASTRO_DEPLOYMENT_API_URL>` | Astro UI → Deployment → Remote Agents → Register Agent |
| `<REPLACE_S3_BUCKET_NAME>` | `terraform output s3_bucket_name` |
| `<REPLACE_PROJECT_NAME>` | Your `project_name` variable value |
| `<REPLACE_ENVIRONMENT>` | Your `environment` variable value |
| `<REPLACE_AWS_REGION>` | Your `aws_region` variable value |
| `<REPLACE_AGENT_IAM_ROLE_ARN>` | `terraform output agent_iam_role_arn` |
| `<REPLACE_ASTRO_DEPLOYMENT_RELEASE_NAME>` | Astro UI → Deployment settings |
| `<REPLACE_ECR_REPO_URL>` | `terraform output ecr_repo_url` |
| `<REPLACE_IMAGE_TAG>` | The image tag pushed in Step 5 |

### GitDagBundle (optional)

If you set `git_repo_url` in Step 2, Terraform creates a git connection secret in Secrets Manager and outputs the values you need for `values.yaml`:

- Set `dagBundleConfigList` using `terraform output helm_dag_bundle_config`
- Add `AIRFLOW_CONN_GIT_REPO` to `commonEnv` using `terraform output helm_airflow_conn_git_repo`

If you skipped `git_repo_url`, leave `dagBundleConfigList` as `LocalDagBundle` for now. You can switch to `GitDagBundle` later by setting the git variables and re-running `terraform apply`.

> ⚠️ **Do NOT include `repo_url` in `dagBundleConfigList` kwargs.** Including it prevents the `GitHook` from being instantiated, which means credentials are never applied and the clone will fail with `could not read Username`. The repo URL comes from the git connection stored in Secrets Manager by Terraform.

> ⚠️ **The `host` field in the `AIRFLOW_CONN_GIT_REPO` env var must be the full HTTPS repo URL** (e.g. `https://github.com/your-org/your-repo.git`), not just `github.com`. The `GitHook` uses `connection.host` directly as the clone URL.

See [Configure DAG sources](https://www.astronomer.io/docs/astro/remote-execution-configure-dag-sources) for full documentation.

### OpenLineage (optional)

The `url` and `namespace` fields are pre-filled in the `values.yaml` template downloaded from the Astro UI. Add the secret reference:

```yaml
openLineage:
  enabled: true
  apiKeySecret: deployment-api-token
  url: "<pre-filled from Astro UI>"
  namespace: "<pre-filled from Astro UI>"
```

> Clear the `~` placeholder from `apiKey` after setting `apiKeySecret`.

After installing the Helm chart, go to your Deployment → **Environment Variables** in the Astro UI and add:

```
OPENLINEAGE_DISABLED=False
```

This enables full lineage collection in Observe and Astro Alerts.

### Sentinel (optional)

Sentinel monitors your agent pods and reports health status to Astro's orchestration plane. It is included in the Helm chart starting in v1.2.0 and is disabled by default. No task logs or DAG code are transmitted.

```yaml
sentinel:
  enabled: true
```

---

## Step 9: Install the Helm chart

```bash
helm repo add astronomer https://helm.astronomer.io
helm repo update
helm install astro-agent astronomer/astro-remote-execution-agent -n default -f values.yaml
```

To upgrade after making changes to `values.yaml`:
```bash
helm upgrade astro-agent astronomer/astro-remote-execution-agent -n default -f values.yaml
```

Verify pods are running:
```bash
kubectl get pods -n default
```

> **Note:** It's normal for pods (especially the triggerer and worker) to restart 2–3 times during the first deployment while agent processes register with the Astro control plane and the EKS autoscaler provisions node capacity. Wait a couple of minutes and re-check — as long as pods stabilize to `Running` with `1/1` Ready and no further restarts, everything is healthy.

---

## Step 10: Configure remote logging in the Astro UI

1. In the Astro UI, go to your Deployment → **Edit**
2. Under **Bucket Storage Task Logs**, enter your S3 bucket name (`terraform output s3_bucket_name`)
3. Under **Customer Managed Identity**, enter the Astro orchestration role ARN (`terraform output astro_orchestration_plane_iam_role_arn`)
4. If your S3 bucket is in a different region than your Astro Deployment, add this environment variable to the Deployment:
   ```
   AIRFLOW__ASTRONOMER_PROVIDERS_LOGGING__AWS_REGION=<your-bucket-region>
   ```

See [AWS Secrets Manager for Remote Execution](https://www.astronomer.io/docs/astro/secrets-backend/aws-secretsmanager#remote-execution) for additional configuration details.

---

## Step 11: Verify the agent

In the Astro UI, go to your Deployment → **Remote Agents** tab. A healthy agent shows:
- Health status: **Healthy**
- Last heartbeat: Within the past minute

---

## Step 12: Test with a sample DAG

Trigger the `example_astronauts` DAG (or any sample DAG) from the Astro UI and verify:
1. The task runs successfully on the remote agent
2. Task logs are visible in the Astro UI

If the task fails or logs aren't visible, check the worker pod logs for errors:

```bash
kubectl logs <worker-pod-name> -n default --tail=100
```

---

## Datadog metrics export (optional)

Ship Airflow metrics to Datadog by running a DogStatsD sidecar in each agent pod. Combine this with an Astro UI environment variable to also capture orchestration-plane metrics (scheduler, API server) that run on Astro's side.

### What you'll need

- Datadog **API Key** from [Org Settings → API Keys](https://app.datadoghq.com/organization-settings/api-keys) (32-char hex string). **Not an Application Key (`ddapp_*`)** — those can't submit metrics and will return 403.
- Your Datadog site (e.g., `datadoghq.com`, `us5.datadoghq.com`, `datadoghq.eu`)

### 1. Add the `datadog` Python package and rebuild the image

In your Astro project's `requirements-client.txt`:

```
datadog
```

Then rebuild and push:

```bash
astro remote deploy --platform linux/amd64
```

> Without the `datadog` package, Airflow falls back to `NoStatsLogger` silently when `STATSD_DATADOG_ENABLED=True`. No metrics flow.

### 2. Add Airflow StatsD config to `commonEnv` in `values.yaml`

```yaml
commonEnv:
  # ... existing env vars ...
  - name: AIRFLOW__METRICS__STATSD_ON
    value: "True"
  - name: AIRFLOW__METRICS__STATSD_HOST
    value: "localhost"
  - name: AIRFLOW__METRICS__STATSD_PORT
    value: "8125"
  - name: AIRFLOW__METRICS__STATSD_PREFIX
    value: "airflow"
  - name: AIRFLOW__METRICS__STATSD_DATADOG_ENABLED
    value: "True"
```

### 3. Add a DogStatsD sidecar to each component

For each of `workers[0]`, `dagProcessor`, and `triggerer`, set `extraContainers` to:

```yaml
extraContainers:
  - name: dogstatsd
    image: gcr.io/datadoghq/agent:latest
    ports:
      - containerPort: 8125
        protocol: UDP
    env:
      - name: DD_API_KEY
        value: "<YOUR_DATADOG_API_KEY>"
      - name: DD_SITE
        value: "<YOUR_DATADOG_SITE>"   # e.g. datadoghq.com or us5.datadoghq.com
      - name: DD_DOGSTATSD_NON_LOCAL_TRAFFIC
        value: "true"
      - name: DD_USE_DOGSTATSD
        value: "true"
      - name: DD_APM_ENABLED
        value: "false"
      - name: DD_LOGS_ENABLED
        value: "false"
      - name: DD_PROCESS_AGENT_ENABLED
        value: "false"
      - name: DD_DOGSTATSD_TAGS
        value: '["deployment:<your-deployment-tag>","component:<worker|dag-processor|triggerer>"]'
    resources:
      requests:
        cpu: 100m
        memory: 256Mi
      limits:
        cpu: 500m
        memory: 512Mi
```

> **Use `DD_DOGSTATSD_TAGS`, not `DD_TAGS`.** `DD_TAGS` are host-level and collide between sidecars on the same node — the `component:` tag ends up wrong on every metric. `DD_DOGSTATSD_TAGS` scopes tags to that one sidecar.

> **Tag values must be a JSON array.** Space-separated strings don't parse for `DD_DOGSTATSD_TAGS`.

### 4. Increase liveness/readiness probe timing

The image with `datadog` and provider packages takes longer to start. The default `initialDelaySeconds: 5` kills slow-starting components in a restart loop. For all three components:

```yaml
livenessProbe:
  initialDelaySeconds: 60
  periodSeconds: 10
  failureThreshold: 6

readinessProbe:
  initialDelaySeconds: 60
  periodSeconds: 10
  failureThreshold: 6
```

### 5. Update the image tag

Update top-level `image:` and each component's `image:` override to the new tag from `astro remote deploy`.

### 6. Apply the chart

```bash
helm upgrade astro-agent astronomer/astro-remote-execution-agent -n default -f values.yaml
```

### 7. (Optional) Add `DATADOG_API_KEY` in the Astro UI for orchestration-plane metrics

For scheduler and API-server metrics from Astro's side, add to **Deployment → Environment Variables**:

```
DATADOG_API_KEY = <your-api-key>     # mark as Secret
DATADOG_SITE    = <your-datadog-site>
```

This isn't officially documented for Remote Execution but works. Without it you only get customer-side metrics.

### Verifying

```bash
WORKER=$(kubectl get pods -n default -l component=worker -o jsonpath='{.items[0].metadata.name}')

# DogStatsD listener bound
kubectl logs -n default $WORKER -c dogstatsd | grep "dogstatsd-udp: starting to listen"

# API key valid (no output = good)
kubectl logs -n default $WORKER -c dogstatsd | grep "API Key invalid"

# Successful metric submission
kubectl logs -n default $WORKER -c dogstatsd | grep "Successfully posted"
```

In Datadog → Metrics Explorer, search for `airflow.ti.start` filtered by `deployment:<your-tag>`. Metrics typically appear within 1–3 minutes of first emission.

### Known limitations

- **Datadog Application Keys (`ddapp_*`) cannot submit metrics.** Use API Keys.
- **Most `airflow.dag_processing.*` metrics do not surface** on Astro RE 1.6.x — Astro's RE dag-processor does not emit them via StatsD. Worker, triggerer, and scheduler-side metrics work normally. Astronomer is migrating dag-processor metrics to a Prometheus-via-coordinator path; future agent versions will expose `/metrics` for scraping.

---

## Adding connections and variables

Connections and variables are stored in Secrets Manager under the path:
```
<project_name>-<environment>/connections/<conn_id>
<project_name>-<environment>/variables/<variable_key>
```

An example for adding a Snowflake connection is included as commented-out code in `remote_exec.tf`.

To add a connection manually via CLI:
```bash
aws secretsmanager create-secret \
  --name "<project_name>-<environment>/connections/<conn_id>" \
  --secret-string '{"conn_type": "...", "login": "...", "password": "...", "host": "..."}' \
  --region <aws-region> \
  --profile <your-profile>
```

See [AWS Secrets Manager for Remote Execution](https://www.astronomer.io/docs/astro/secrets-backend/aws-secretsmanager#remote-execution) for the full connection JSON format.

---

## Cleanup

```bash
# Uninstall the helm chart
helm uninstall astro-agent -n default

# Destroy AWS infrastructure
cd aws/infra
terraform destroy

# Delete the Astro Deployment from the UI
```
