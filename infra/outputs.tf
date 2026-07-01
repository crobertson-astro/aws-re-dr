// -----------------------------------------------------------------------------
// AWS (global + per-region)
// -----------------------------------------------------------------------------
output "development_iam_role_arn" {
  value = module.aws.development_iam_role_arn
}

output "agent_iam_role_arn" {
  value = module.aws.agent_iam_role_arn
}

output "astro_orchestration_plane_iam_role_arn" {
  value = module.aws.astro_orchestration_plane_iam_role_arn
}

output "primary" {
  description = "All outputs for the primary-region deployment"
  value       = module.aws.primary
}

output "failover" {
  description = "All outputs for the failover-region deployment"
  value       = module.aws.failover
}

output "primary_helm_airflow_conn_git_repo" {
  description = "Sensitive: AIRFLOW_CONN_GIT_REPO for the primary-region Helm release."
  sensitive   = true
  value       = module.aws.primary_helm_airflow_conn_git_repo
}

output "failover_helm_airflow_conn_git_repo" {
  description = "Sensitive: AIRFLOW_CONN_GIT_REPO for the failover-region Helm release."
  sensitive   = true
  value       = module.aws.failover_helm_airflow_conn_git_repo
}

// -----------------------------------------------------------------------------
// Astro
// -----------------------------------------------------------------------------
output "astro_organization_id" {
  value = var.astro_organization_id
}

output "astro_workspace_id" {
  value = var.workspace_id
}

output "astro_cluster_id" {
  value = astro_cluster.this.id
}

output "astro_deployment_id" {
  value = astro_deployment.this.id
}

output "astro_deployment_webserver_ingress_hostname" {
  value = astro_deployment.this.webserver_ingress_hostname
}

output "astro_deployment_namespace" {
  value = astro_deployment.this.namespace
}

output "astro_agent_token" {
  sensitive = true
  value     = astro_agent_token.remote_exec.token
}

output "astro_deployment_admin_token" {
  sensitive = true
  value     = astro_api_token.deployment_admin.token
}
