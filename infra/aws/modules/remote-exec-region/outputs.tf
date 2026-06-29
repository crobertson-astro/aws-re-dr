output "region" {
  value = local.region
}

output "vpc_id" {
  value = aws_vpc.remote_exec_vpc.id
}

output "ecr_repo_url" {
  value = aws_ecr_repository.remote_exec_demo.repository_url
}

output "ecr_repo_arn" {
  value = aws_ecr_repository.remote_exec_demo.arn
}

output "eks_cluster_name" {
  description = "The name of the EKS cluster"
  value       = module.eks.cluster_name
}

output "s3_bucket_name" {
  value = module.s3_bucket.s3_bucket_id
}

output "s3_bucket_arn" {
  value = module.s3_bucket.s3_bucket_arn
}

output "eks_oidc_provider_arn" {
  value = module.eks.oidc_provider_arn
}

output "eks_oidc_provider" {
  description = "OIDC provider host (issuer minus scheme), used in trust-policy condition keys"
  value       = module.eks.oidc_provider
}

output "helm_dag_bundle_config" {
  description = "Use this value for dagBundleConfigList in your values.yaml."
  value       = var.git_repo_url != null ? "[{\"name\": \"private-dags\", \"classpath\": \"airflow.providers.git.bundles.git.GitDagBundle\", \"kwargs\": {\"tracking_ref\": \"${var.git_branch}\", \"subdir\": \"${var.dag_subdir}\", \"git_conn_id\": \"git_repo\"}}]" : null
}

output "helm_airflow_conn_git_repo" {
  description = "Use this value for AIRFLOW_CONN_GIT_REPO in commonEnv. Only set when git_repo_url is provided."
  sensitive   = true
  value       = var.git_repo_url != null ? "{\"conn_type\": \"git\", \"login\": \"${var.git_username}\", \"password\": \"${var.git_pat}\", \"host\": \"${var.git_repo_url}\", \"schema\": \"https\", \"extra\": {\"branch\": \"${var.git_branch}\"}}" : null
}

output "secrets_manager_backend_kwargs" {
  description = "Use this value for AIRFLOW__SECRETS__BACKEND_KWARGS in commonEnv in your values.yaml."
  value       = "{\"connections_prefix\": \"${local.secret_prefix}/connections\", \"variables_prefix\": \"${local.secret_prefix}/variables\", \"region_name\": \"${local.region}\"}"
}
