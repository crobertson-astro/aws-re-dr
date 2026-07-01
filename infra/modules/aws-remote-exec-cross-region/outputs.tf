// -----------------------------------------------------------------------------
// Global outputs (IAM — single role across both regions)
// -----------------------------------------------------------------------------
output "development_iam_role_arn" {
  value = aws_iam_role.development_role.arn
}

output "agent_iam_role_arn" {
  value = aws_iam_role.agent_role.arn
}

output "astro_orchestration_plane_iam_role_arn" {
  value = aws_iam_role.astro_orchestration_plane_role.arn
}

// -----------------------------------------------------------------------------
// Per-region outputs
// -----------------------------------------------------------------------------
output "primary" {
  description = "All outputs for the primary-region deployment"
  value = {
    region                         = module.primary.region
    vpc_id                         = module.primary.vpc_id
    ecr_repo_name                  = module.primary.ecr_repo_name
    ecr_repo_url                   = module.primary.ecr_repo_url
    eks_cluster_name               = module.primary.eks_cluster_name
    s3_bucket_name                 = module.primary.s3_bucket_name
    helm_dag_bundle_config         = module.primary.helm_dag_bundle_config
    secrets_manager_backend_kwargs = module.primary.secrets_manager_backend_kwargs
  }
}

output "failover" {
  description = "All outputs for the failover-region deployment"
  value = {
    region                         = module.failover.region
    vpc_id                         = module.failover.vpc_id
    ecr_repo_name                  = module.failover.ecr_repo_name
    ecr_repo_url                   = module.failover.ecr_repo_url
    eks_cluster_name               = module.failover.eks_cluster_name
    s3_bucket_name                 = module.failover.s3_bucket_name
    helm_dag_bundle_config         = module.failover.helm_dag_bundle_config
    secrets_manager_backend_kwargs = module.failover.secrets_manager_backend_kwargs
  }
}

output "primary_helm_airflow_conn_git_repo" {
  description = "Sensitive: AIRFLOW_CONN_GIT_REPO for the primary-region Helm release."
  sensitive   = true
  value       = module.primary.helm_airflow_conn_git_repo
}

output "failover_helm_airflow_conn_git_repo" {
  description = "Sensitive: AIRFLOW_CONN_GIT_REPO for the failover-region Helm release."
  sensitive   = true
  value       = module.failover.helm_airflow_conn_git_repo
}
