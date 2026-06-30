variable "astro_organization_id" {
  description = "Your Astronomer organization ID"
  type        = string
}

variable "aws_profile" {
  description = "Your AWS CLI profile name created with 'aws sso configure'"
  type        = string
}

variable "aws_account_id" {
  description = "AWS Account ID to deploy resources into"
  type        = string
}

variable "primary_region" {
  description = "Primary AWS region for the active deployment"
  type        = string
}

variable "failover_region" {
  description = "Failover AWS region for the DR replica"
  type        = string
  validation {
    condition     = var.failover_region != var.primary_region
    error_message = "failover_region must differ from primary_region."
  }
}

variable "project_name" {
  description = "Project name for tagging and resource naming"
  type        = string
}

variable "environment" {
  description = "Environment (e.g., dev, staging, prod)"
  type        = string
}

variable "owner" {
  description = "Owner or team responsible for resources"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC, /24 minimum. Used for both regions."
  type        = string
  default     = "10.0.0.0/24"
}

variable "az_count" {
  description = "Number of Availability Zones to use per region"
  type        = number
  default     = 2
}

variable "git_repo_url" {
  description = "Full HTTPS URL of the Git repository containing your DAGs. Leave null to skip GitDagBundle setup."
  type        = string
  default     = null
}

variable "git_username" {
  description = "GitHub username or service account name associated with the PAT."
  type        = string
  default     = null
}

variable "git_pat" {
  description = "GitHub PAT with Contents: Read-only on the DAG repository."
  type        = string
  sensitive   = true
  default     = null
}

variable "git_branch" {
  description = "Git branch to track for DAG bundles"
  type        = string
}

variable "dag_subdir" {
  description = "Subdirectory within the repository containing DAG files"
  type        = string
}

variable "workspace_id" {
  description = "Astro workspace ID that owns the cluster and deployment"
  type        = string
}

variable "cluster_name" {
  description = "Name of the Astro cluster"
  type        = string
}

variable "cluster_vpc_subnet_range" {
  description = "CIDR range for the Astro cluster VPC in the primary region"
  type        = string
  default     = "172.20.0.0/20"
}

variable "cluster_secondary_vpc_cidr" {
  description = "Secondary CIDR block attached to the Astro cluster VPC"
  type        = string
  default     = "172.21.0.0/20"
}

variable "cluster_dr_vpc_subnet_range" {
  description = "CIDR range for the Astro cluster VPC in the failover (DR) region"
  type        = string
  default     = "172.22.0.0/20"
}

variable "cluster_enable_replication_time_control" {
  description = "Enable S3 Replication Time Control for cross-region replication of cluster state"
  type        = bool
  default     = false
}

variable "cluster_is_failed_over" {
  description = "Set to true to fail the cluster over to the DR region"
  type        = bool
  default     = false
}

variable "deployment_name" {
  description = "Name of the Astro deployment"
  type        = string
}

variable "deployment_scheduler_size" {
  description = "Scheduler size for the Astro deployment (SMALL, MEDIUM, LARGE)"
  type        = string
  default     = "SMALL"
}

variable "deployment_is_cicd_enforced" {
  description = "Require an API token / CI flow for code pushes to this deployment"
  type        = bool
  default     = false
}

variable "deployment_is_development_mode" {
  description = "Mark this deployment as development mode (allows hibernation, no SLAs)"
  type        = bool
  default     = false
}

variable "deployment_is_high_availability" {
  description = "Run the deployment in high-availability mode"
  type        = bool
  default     = false
}

variable "deployment_contact_emails" {
  description = "List of contact emails for deployment alerts"
  type        = list(string)
  default     = []
}

variable "deployment_environment_variables" {
  description = "Environment variables to set on the deployment"
  type = list(object({
    key       = string
    value     = string
    is_secret = bool
  }))
  default = []
}

