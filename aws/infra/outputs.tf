// Cross-cutting outputs used to populate Helm values for the Astro deployment.
// Resource-specific outputs live alongside their resources (ecr.tf, s3.tf, eks.tf, iam.tf).

output "helm_dag_bundle_config" {
  description = "Use this value for dagBundleConfigList in your values.yaml. Do NOT add repo_url to kwargs. Only set when git_repo_url is provided."
  value       = var.git_repo_url != null ? "[{\"name\": \"private-dags\", \"classpath\": \"airflow.providers.git.bundles.git.GitDagBundle\", \"kwargs\": {\"tracking_ref\": \"${var.git_branch}\", \"subdir\": \"${var.dag_subdir}\", \"git_conn_id\": \"git_repo\"}}]" : null
}

output "helm_airflow_conn_git_repo" {
  description = "Use this value for AIRFLOW_CONN_GIT_REPO in commonEnv in your values.yaml. Acts as fallback if Secrets Manager is unavailable. Only set when git_repo_url is provided."
  sensitive   = true
  value       = var.git_repo_url != null ? "{\"conn_type\": \"git\", \"login\": \"${var.git_username}\", \"password\": \"${var.git_pat}\", \"host\": \"${var.git_repo_url}\", \"schema\": \"https\", \"extra\": {\"branch\": \"${var.git_branch}\"}}" : null
}

output "secrets_manager_backend_kwargs" {
  description = "Use this value for AIRFLOW__SECRETS__BACKEND_KWARGS in commonEnv in your values.yaml."
  value       = "{\"connections_prefix\": \"${local.secret_prefix}/connections\", \"variables_prefix\": \"${local.secret_prefix}/variables\", \"region_name\": \"${var.aws_region}\"}"
}
