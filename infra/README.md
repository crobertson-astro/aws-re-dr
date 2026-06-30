# Astro Remote Execution on AWS — Cross-Region DR

This template deploys the infrastructure and configuration needed to run [Astro Remote Execution](https://www.astronomer.io/docs/astro/remote-execution-overview) agents on AWS EKS in two regions, with the Astro control plane configured for cross-region disaster recovery.

## Architecture Overview

Global (created once, shared by both regions):

- **Astro cluster** with `is_dr_enabled = true` — primary in `primary_region`, DR replica in `failover_region`
- **Astro deployment** — task-log bucket and workload-identity role swap when `cluster_is_failed_over` flips
- **IAM roles** — development (GitHub OIDC), agent (IRSA, trusted by both EKS OIDC providers), Astro orchestration plane (remote logging)

Per region (one set in `primary_region`, one in `failover_region`):

- **EKS cluster** — runs the Astro Remote Execution Agent pods (DAG Processor, Worker, Triggerer)
- **VPC** — dedicated VPC and subnets for the EKS cluster
- **S3 bucket** — task logs and XCom data
- **ECR repository** — custom agent image
- **Secrets Manager** — Airflow connections, variables, and the Git connection for DAG bundles

---

## Prerequisites

- AWS CLI configured with SSO
- Terraform >= 1.3.0
- Helm 3+
- kubectl
- Astro CLI
- Docker
- Sufficient quota in both regions for: NAT Gateways (default 5/region), Elastic IPs, and EKS clusters

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
cd infra
cp terraform.tfvars.example terraform.tfvars
```

`terraform.tfvars` is gitignored — your credentials will never be committed. Edit it with your environment values:

| Variable | Description | Required |
|---|---|---|
| `aws_profile` | AWS CLI profile name | Yes |
| `aws_account_id` | AWS account ID | Yes |
| `primary_region` | Active AWS region | Yes |
| `failover_region` | DR replica AWS region (must differ from `primary_region`) | Yes |
| `project_name` | Short name used as a prefix for all resources | Yes |
| `environment` | e.g. `dev`, `staging`, `prod` | Yes |
| `owner` | Owner or team responsible for resources | Yes |
| `astro_organization_id` | Astro organization ID | Yes |
| `workspace_id` | Astro workspace ID for the cluster and deployment | Yes |
| `cluster_name` | Name of the Astro cluster | Yes |
| `deployment_name` | Name of the Astro deployment | Yes |
| `git_branch` | Git branch to track for DAG bundles | Yes |
| `dag_subdir` | Subdirectory within the repo containing DAG files | Yes |
| `vpc_cidr` | CIDR block for each regional VPC, /24 minimum | No (default: `10.0.0.0/24`) |
| `az_count` | Number of Availability Zones per region | No (default: `2`) |
| `git_repo_url` | Full HTTPS URL of your DAG repo. Leave unset to skip GitDagBundle setup. | No |
| `git_username` | GitHub username associated with the PAT. Required if `git_repo_url` is set. | No |
| `git_pat` | GitHub PAT with **Contents: Read-only** permission. Required if `git_repo_url` is set. | No |
| `cluster_is_failed_over` | Set to `true` to fail the Astro cluster over to the DR region | No (default: `false`) |

> **Note:** AWS NAT Gateway quota is per-region (default 5). Confirm capacity in both `primary_region` and `failover_region`.

Apply the Terraform:

```bash
terraform init
terraform validate
terraform plan -out tfplan
terraform apply tfplan
```

Once complete, retrieve regional outputs with:

```bash
terraform output -json primary | jq .
terraform output -json failover | jq .
```

Global IAM role ARNs (`agent_iam_role_arn`, `astro_orchestration_plane_iam_role_arn`, `development_iam_role_arn`) and Astro IDs (`astro_cluster_id`, `astro_deployment_id`) are top-level outputs.

---

## Step 3: Create required tokens

The Astro cluster and deployment are created by Terraform in Step 2; you only need tokens here.

**Agent Token** — authenticates agent pods to the Astro Orchestration Plane:
1. In the Astro UI, go to your Deployment → **Remote Agents** tab → **Tokens**
2. Click **+ Agent Token**, give it a name, and save the value securely

**Deployment API Token** — pulls the agent image from Astronomer's registry and authenticates OpenLineage:
1. Deployment → **Access** → **API Tokens** → **+ API Token**
2. Create with **Deployment Admin** permissions and save the value securely

---

## Step 4: Build and push your custom agent image (per region)

The base agent image needs the Amazon provider installed for S3 XCom and remote logging.

Log in to Astro:

```bash
astro login
```

Then, **for each region**, authenticate to that region's ECR and run `astro remote deploy` from the `astro/` directory:

```bash
# Primary region
aws ecr get-login-password --region <primary_region> | \
  docker login --username AWS --password-stdin <primary.ecr_repo_url>
astro remote deploy --platform linux/amd64
# When prompted, use primary.ecr_repo_url from terraform output

# Failover region
aws ecr get-login-password --region <failover_region> | \
  docker login --username AWS --password-stdin <failover.ecr_repo_url>
astro remote deploy --platform linux/amd64
# When prompted, use failover.ecr_repo_url from terraform output
```

The first run generates `astro/Dockerfile.client`. Add the Amazon provider install so S3 XCom and remote logging work:

```dockerfile
# Install the Amazon provider with the S3FS extra
# Update the constraints URL to match the Airflow version in your base image
# Check https://www.astronomer.io/docs/astro/agent-release-notes for the correct version
RUN pip install --no-cache-dir "apache-airflow-providers-amazon[s3fs]" \
    --constraint "https://raw.githubusercontent.com/apache/airflow/constraints-<airflow-version>/constraints-3.12.txt"
```

> **Important:** The constraints URL must match the Airflow version embedded in your base image. For example:
> - Agent based on Airflow 3.0.3 → `constraints-3.0.3`
> - Agent based on Airflow 3.1.0 → `constraints-3.1.0`

Re-run `astro remote deploy --platform linux/amd64` against each region's ECR to push the updated image. Note the image tags pushed — you'll need them in [values.yaml](../values.yaml).

See the [astro remote deploy docs](https://www.astronomer.io/docs/astro/cli/astro-remote) for all available options.

---

## Step 5: Configure kubectl (per region)

```bash
# Primary
aws eks update-kubeconfig --name <primary.eks_cluster_name> --region <primary_region> --alias primary

# Failover
aws eks update-kubeconfig --name <failover.eks_cluster_name> --region <failover_region> --alias failover
```

Switch contexts with `kubectl config use-context primary` / `failover`.

---

## Step 6: Create Kubernetes secrets (per region)

Repeat the following against each cluster context:

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

## Step 7: Configure values.yaml

The repo's [values.yaml](../values.yaml) is the working chart configuration. Most fields are region-agnostic, but a few must point at the right region's resources. The simplest pattern is to keep one base file and override the regional fields on the Helm command line (Step 8), or copy `values.yaml` per-region.

| Field | Source |
|---|---|
| `resourceNamePrefix` | Choose a name prefix for your k8s resources |
| `astroDeploymentAPIURL` | Astro UI → Deployment → Remote Agents → Register Agent |
| `image` | `<region>.ecr_repo_url:<image-tag-pushed-in-step-4>` |
| `commonEnv.AWS_REGION` | `primary_region` or `failover_region` |
| `commonEnv.ASTRO_*` taskLogBucket / agentIamRoleArn | `<region>.s3_bucket_name`, `agent_iam_role_arn` |
| `serviceAccount.annotations."eks.amazonaws.com/role-arn"` | `agent_iam_role_arn` (same role in both regions) |

### GitDagBundle (optional)

If you set `git_repo_url` in Step 2, Terraform creates per-region Git connection secrets in Secrets Manager and outputs the helper values:

- Set `dagBundleConfigList` using `terraform output -raw primary.helm_dag_bundle_config` (and the failover equivalent)
- Add `AIRFLOW_CONN_GIT_REPO` to `commonEnv` using `terraform output -raw primary_helm_airflow_conn_git_repo` (and `failover_helm_airflow_conn_git_repo`)

If you skipped `git_repo_url`, leave `dagBundleConfigList` as `LocalDagBundle`. You can switch to `GitDagBundle` later by setting the git variables and re-running `terraform apply`.

> ⚠️ **Do NOT include `repo_url` in `dagBundleConfigList` kwargs.** Including it prevents the `GitHook` from being instantiated, which means credentials are never applied and the clone will fail with `could not read Username`. The repo URL comes from the git connection stored in Secrets Manager by Terraform.

> ⚠️ **The `host` field in `AIRFLOW_CONN_GIT_REPO` must be the full HTTPS repo URL** (e.g. `https://github.com/your-org/your-repo.git`), not just `github.com`. The `GitHook` uses `connection.host` directly as the clone URL.

See [Configure DAG sources](https://www.astronomer.io/docs/astro/remote-execution-configure-dag-sources) for full documentation.

### OpenLineage (optional)

The `url` and `namespace` are pre-filled in the `values.yaml` template downloaded from the Astro UI. Add the secret reference:

```yaml
openLineage:
  enabled: true
  apiKeySecret: deployment-api-token
  url: "<pre-filled from Astro UI>"
  namespace: "<pre-filled from Astro UI>"
```

> Clear the `~` placeholder from `apiKey` after setting `apiKeySecret`.

In the Astro UI, set `OPENLINEAGE_DISABLED=False` on the Deployment to enable lineage in Observe and Astro Alerts.

### Sentinel (optional)

Sentinel monitors your agent pods and reports health status to Astro. Disabled by default; no task logs or DAG code are transmitted.

```yaml
sentinel:
  enabled: true
```

---

## Step 8: Install the Helm chart (per region)

Run against each cluster context:

```bash
helm repo add astronomer https://helm.astronomer.io
helm repo update

# Primary
kubectl config use-context primary
helm install astro-agent astronomer/astro-remote-execution-agent -n default -f ../values.yaml \
  --set image=<primary.ecr_repo_url>:<image-tag> \
  --set commonEnv.AWS_REGION=<primary_region>

# Failover
kubectl config use-context failover
helm install astro-agent astronomer/astro-remote-execution-agent -n default -f ../values.yaml \
  --set image=<failover.ecr_repo_url>:<image-tag> \
  --set commonEnv.AWS_REGION=<failover_region>
```

To upgrade after editing `values.yaml`:

```bash
helm upgrade astro-agent astronomer/astro-remote-execution-agent -n default -f ../values.yaml [overrides]
```

Verify pods:

```bash
kubectl get pods -n default
```

> **Note:** Pods (especially triggerer and worker) commonly restart 2–3 times during the first install while agent processes register with the Astro control plane and the EKS autoscaler provisions node capacity. Wait a couple of minutes — pods stable at `Running` `1/1` with no further restarts is healthy.

---

## Step 9: Configure remote logging in the Astro UI

The Astro deployment is created by Terraform, but the orchestration-plane remote-logging role still needs to be wired up in the UI (Astronomer needs an external ID, which is only generated after the deployment exists).

1. Astro UI → Deployment → **Edit**
2. Under **Bucket Storage Task Logs**, enter `<primary>.s3_bucket_name` (and `<failover>.s3_bucket_name` once you fail over)
3. Under **Customer Managed Identity**, enter `astro_orchestration_plane_iam_role_arn`
4. If the bucket region differs from the deployment region, add:
   ```
   AIRFLOW__ASTRONOMER_PROVIDERS_LOGGING__AWS_REGION=<bucket-region>
   ```

See [AWS Secrets Manager for Remote Execution](https://www.astronomer.io/docs/astro/secrets-backend/aws-secretsmanager#remote-execution) for related configuration.

---

## Step 10: Verify

In the Astro UI, Deployment → **Remote Agents**. A healthy agent shows:
- Health status: **Healthy**
- Last heartbeat: within the past minute

Trigger a sample DAG (e.g. `example_astronauts`) and confirm:
1. The task runs on the active region's remote agent
2. Task logs are visible in the Astro UI

If a task fails or logs are missing, check the worker pod logs:

```bash
kubectl logs <worker-pod-name> -n default --tail=100
```

---

## Failing over

To redirect task execution and log storage to the failover region:

1. Set `cluster_is_failed_over = true` in `terraform.tfvars`
2. `terraform apply`
3. In the Astro UI, update the **Bucket Storage Task Logs** field to the failover region's S3 bucket
4. Confirm the failover-region agent is `Healthy` in the Astro UI

To fail back, set `cluster_is_failed_over = false` and re-apply.

---

## Datadog metrics export (optional)

Ship Airflow metrics to Datadog by running a DogStatsD sidecar in each agent pod. Combine this with an Astro UI environment variable to also capture orchestration-plane metrics (scheduler, API server) that run on Astro's side.

### What you'll need

- Datadog **API Key** from [Org Settings → API Keys](https://app.datadoghq.com/organization-settings/api-keys) (32-char hex string). **Not an Application Key (`ddapp_*`)** — those can't submit metrics and return 403.
- Your Datadog site (e.g., `datadoghq.com`, `us5.datadoghq.com`, `datadoghq.eu`)

### 1. Add the `datadog` Python package and rebuild the image

In `astro/requirements-client.txt`:

```
datadog
```

Then rebuild and push (per region, as in Step 4):

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
helm upgrade astro-agent astronomer/astro-remote-execution-agent -n default -f ../values.yaml
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
- **Most `airflow.dag_processing.*` metrics do not surface** on Astro RE 1.6.x — Astro's RE dag-processor does not emit them via StatsD. Worker, triggerer, and scheduler-side metrics work normally.

---

## Adding connections and variables

Connections and variables are stored in Secrets Manager in each region under:

```
<project_name>-<environment>/connections/<conn_id>
<project_name>-<environment>/variables/<variable_key>
```

To add a connection manually via CLI (run once per region):

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
# Uninstall the helm chart in each region
kubectl config use-context primary  && helm uninstall astro-agent -n default
kubectl config use-context failover && helm uninstall astro-agent -n default

# Destroy AWS infrastructure (both regions + Astro cluster/deployment)
cd infra
terraform destroy
```
