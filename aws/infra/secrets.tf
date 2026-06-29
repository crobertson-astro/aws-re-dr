# IMPORTANT NOTES for GitDagBundle configuration:
#
# 1. The "host" field in the connection must be the FULL repo URL
#    (e.g. https://github.com/your-org/your-repo.git), NOT just "github.com".
#    The GitHook uses connection.host directly as the repo URL.
#
# 2. Do NOT include repo_url in your dagBundleConfigList helm values kwargs.
#    Providing repo_url prevents the GitHook from being instantiated, which
#    means credentials are never applied and the clone will fail with
#    "could not read Username". Use only git_conn_id in kwargs.
#
# 3. Your values.yaml dagBundleConfigList should look like:
#    '[{"name": "private-dags", "classpath": "airflow.providers.git.bundles.git.GitDagBundle",
#      "kwargs": {"tracking_ref": "main", "subdir": "dags", "git_conn_id": "git_repo"}}]'

resource "aws_secretsmanager_secret" "git_repo_conn" {
  count       = var.git_repo_url != null ? 1 : 0
  name        = "${local.secret_prefix}/connections/git_repo"
  description = "Airflow Git connection for DAG bundle - ${var.project_name}-${var.environment}"
  tags        = local.tags
}

resource "aws_secretsmanager_secret_version" "git_repo_conn" {
  count     = var.git_repo_url != null ? 1 : 0
  secret_id = aws_secretsmanager_secret.git_repo_conn[0].id
  secret_string = jsonencode({
    conn_type = "git"
    login     = var.git_username
    password  = var.git_pat
    host      = var.git_repo_url
    schema    = "https"
    extra = {
      branch = var.git_branch
    }
  })
}

// -----------------------------------------------------------------------------
// Example for adding a Snowflake Connection to Secrets Manager
// -----------------------------------------------------------------------------
# variable "snowflake_login" {
#   description = "Snowflake login"
#   type        = string
# }
# variable "snowflake_password" {
#   description = "Snowflake password"
#   type        = string
#   sensitive   = true
# }
# variable "snowflake_account" {
#   description = "Snowflake account"
#   type        = string
# }
# variable "snowflake_warehouse" {
#   description = "Snowflake warehouse"
#   type        = string
# }
# variable "snowflake_database" {
#   description = "Snowflake database"
#   type        = string
# }
# variable "snowflake_schema" {
#   description = "Snowflake schema"
#   type        = string
# }
# variable "snowflake_region" {
#   description = "Snowflake region"
#   type        = string
# }
# variable "snowflake_role" {
#   description = "Snowflake role"
#   type        = string
# }

# resource "aws_secretsmanager_secret" "snowflake_conn" {
#   name        = "${local.secret_prefix}/connections/snowflake"
#   description = "Snowflake connection for ${var.project_name}-${var.environment}"
#   tags        = local.tags
# }

# resource "aws_secretsmanager_secret_version" "snowflake_conn" {
#   secret_id = aws_secretsmanager_secret.snowflake_conn.id
#   secret_string = jsonencode({
#     conn_type = "snowflake"
#     login     = var.snowflake_login
#     password  = var.snowflake_password
#     schema    = var.snowflake_schema
#     extra     = jsonencode({
#       account   = var.snowflake_account
#       warehouse = var.snowflake_warehouse
#       database  = var.snowflake_database
#       region    = var.snowflake_region
#       role      = var.snowflake_role
#     })
#   })
# }
