# Astro Remote Execution — Cross-Region Disaster Recovery

This project deploys an [Astro Remote Execution](https://www.astronomer.io/docs/astro/remote-execution-overview) agent across two AWS regions for cross-region disaster recovery. Both regions register against the same Astro [cluster](https://cloud.astronomer.io/settings/clusters/cmqzgljvy857s01ny14w7jgpj) and back the same Astro [deployment](https://cloud.astronomer.io/cm7f419mg0no001jhunzjeer1/deployments/cmqzimj5p876501nyl7x8pktw), so if the primary region becomes unavailable, the secondary agent picks up task execution with no Astro control-plane changes.

## Layout

- [aws/](aws/) — Terraform for the multi-region AWS footprint. See [aws/README.md](aws/README.md) for the full setup walkthrough.
  - [aws/infra/](aws/infra/) — root module: global IAM roles (development, agent IRSA, Astro orchestration plane) plus two invocations of the regional module.
  - [aws/infra/modules/regional/](aws/infra/modules/regional/) — per-region module: VPC, EKS, S3, ECR, Secrets Manager.
- [astro/](astro/) — Astro project (DAGs, Dockerfile, requirements) deployed to the Remote Execution agent in each region.

## Deploying both regions

A single Terraform root module deploys both regions in one apply. The `primary_region` and `failover_region` variables in [aws/infra/terraform.tfvars](aws/infra/terraform.tfvars) drive which AWS regions get the `module.primary` and `module.failover` invocations. From [aws/infra/](aws/infra/):

```bash
aws sso login

terraform init
terraform apply
```

Per-region outputs are namespaced under `primary` and `failover` (e.g. `terraform output -json primary | jq -r .ecr_repo_url`). Global IAM role ARNs are top-level outputs.

Then follow [aws/README.md](aws/README.md) starting at Step 3 for each region (build/push the agent image to that region's ECR, install the Helm chart against that region's EKS cluster, register the agent in the Astro UI).
