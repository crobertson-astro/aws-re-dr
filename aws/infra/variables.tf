variable "aws_profile" {
  description = "Your AWS CLI profile name created with 'aws sso configure'"
  type        = string
}

variable "aws_account_id" {
  description = "AWS Account ID to deploy resources into"
  type        = string
}

variable "aws_region" {
  description = "AWS region to deploy resources"
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
  default     = "10.0.0.0/24" //256 IPs
}

variable "az_count" {
  description = "Number of Availability Zones to use"
  type        = number
  default     = 2
}

variable "git_repo_url" {
  description = "Full HTTPS URL of the Git repository containing your DAGs (e.g. https://github.com/your-org/your-dags.git). Leave null to skip GitDagBundle setup."
  type        = string
  default     = null
}

variable "git_username" {
  description = "GitHub username or service account name associated with the PAT. Required if git_repo_url is set."
  type        = string
  default     = null
}

variable "git_pat" {
  description = "GitHub Personal Access Token with Contents: Read-only permission scoped to the DAG repository. Required if git_repo_url is set."
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
