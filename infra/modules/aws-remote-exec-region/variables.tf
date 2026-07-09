variable "aws_account_id" {
  description = "AWS Account ID to deploy resources into"
  type        = string
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
  description = "CIDR block for the VPC, /24 minimum"
  type        = string
  default     = "10.0.0.0/24"
}

variable "az_count" {
  description = "Number of Availability Zones to use"
  type        = number
  default     = 2
}

variable "development_role_arn" {
  description = "ARN of the global GitHub Actions / CI role granted EKS admin in this region"
  type        = string
}

variable "agent_role_arn" {
  description = "ARN of the global IAM role granted access to S3 and Secrets Manager in this region"
  type        = string
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
