# Astro Remote Execution — Cross-Region Disaster Recovery

This project deploys an [Astro Remote Execution](https://www.astronomer.io/docs/astro/remote-execution-overview) agent across two AWS regions for cross-region disaster recovery. Both regions register against the same Astro [cluster](https://cloud.astronomer.io/settings/clusters/cmqzgljvy857s01ny14w7jgpj), so if the primary region becomes unavailable, the secondary agent picks up task execution with no Astro control-plane changes.

## Layout

- [aws/](aws/) — Terraform for the per-region AWS footprint (EKS, S3, ECR, Secrets Manager, IRSA). See [aws/README.md](aws/README.md) for the full setup walkthrough.
  - [aws/infra/west2.tfvars](aws/infra/west2.tfvars) — primary region (`us-west-2`)
  - [aws/infra/west1.tfvars](aws/infra/west1.tfvars) — DR region (`us-west-1`)
- [astro/](astro/) — Astro project (DAGs, Dockerfile, requirements) deployed to the Remote Execution agent in each region.

## Deploying both regions

Each region is a separate Terraform workspace using its own `.tfvars` file. From [aws/infra/](aws/infra/):

```bash
# Primary
terraform workspace new west2 || terraform workspace select west2
terraform apply -var-file=west2.tfvars

# DR
terraform workspace new west1 || terraform workspace select west1
terraform apply -var-file=west1.tfvars
```

Then follow [aws/README.md](aws/README.md) starting at Step 3 for each region (build/push the agent image to that region's ECR, install the Helm chart against that region's EKS cluster, register the agent in the Astro UI).
