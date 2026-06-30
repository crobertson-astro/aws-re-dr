module "aws" {
  source = "./modules/aws-remote-exec-cross-region"
  providers = {
    aws.primary  = aws.primary
    aws.failover = aws.failover
  }

  aws_account_id = var.aws_account_id
  project_name   = var.project_name
  environment    = var.environment
  owner          = var.owner
  vpc_cidr       = var.vpc_cidr
  az_count       = var.az_count

  git_repo_url = var.git_repo_url
  git_username = var.git_username
  git_pat      = var.git_pat
  git_branch   = var.git_branch
  dag_subdir   = var.dag_subdir
}

resource "astro_cluster" "this" {
  name             = var.cluster_name
  type             = "DEDICATED"
  cloud_provider   = "AWS"
  region           = var.primary_region
  vpc_subnet_range = var.cluster_vpc_subnet_range
  workspace_ids    = []

  secondary_vpc_cidr = var.cluster_secondary_vpc_cidr

  is_dr_enabled = true
  # Hardcoded: astro provider v1.2.6 ValidateConfig treats variable references
  # as Unknown and errors out. Must match var.failover_region.
  # See: https://github.com/astronomer/terraform-provider-astro/issues/197
  dr_region           = "us-west-1"
  dr_vpc_subnet_range = var.cluster_dr_vpc_subnet_range
  enable_replication_time_control = var.cluster_enable_replication_time_control
  is_failed_over                  = var.cluster_is_failed_over
}

resource "astro_deployment" "this" {
  name         = var.deployment_name
  description  = "Remote execution deployment with cross-region failover"
  type         = "DEDICATED"
  cluster_id   = astro_cluster.this.id
  workspace_id = var.workspace_id
  executor     = "ASTRO"

  scheduler_size        = var.deployment_scheduler_size
  is_cicd_enforced      = var.deployment_is_cicd_enforced
  is_dag_deploy_enabled = var.deployment_is_dag_deploy_enabled
  is_development_mode   = var.deployment_is_development_mode
  is_high_availability  = var.deployment_is_high_availability
  contact_emails        = var.deployment_contact_emails
  environment_variables = var.deployment_environment_variables

  desired_workload_identity = module.aws.agent_iam_role_arn
  remote_execution = {
    enabled = true
    allowed_ip_address_ranges = []
    task_log_bucket = var.cluster_is_failed_over ? module.aws.failover.s3_bucket_name : module.aws.primary.s3_bucket_name
  }
}
