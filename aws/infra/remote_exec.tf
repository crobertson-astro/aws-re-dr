// -----------------------------------------------------------------------------
// Reusable Variables - Customize these for your environment
// -----------------------------------------------------------------------------
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
  default     = "10.0.0.0/24"   //256 IPs
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


// -----------------------------------------------------------------------------
// Terraform and Provider Configuration
// -----------------------------------------------------------------------------
terraform {
  required_version = ">= 1.3.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
    }
  }
}


provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}


data "aws_availability_zones" "available" {
  state = "available"
}


// -----------------------------------------------------------------------------
// Locals and Tags
// -----------------------------------------------------------------------------
locals {
  # -----------------------------
  # Tags & naming
  # -----------------------------
  tags = {
    Project     = var.project_name
    Managed     = "terraform"
    Owner       = var.owner
    Environment = var.environment
  }
  eks_tags = {
    Project      = var.project_name
    Managed      = "terraform"
    Owner        = var.owner
    DeleteStatus = "DND"
    Environment  = var.environment
  }


  # IMPORTANT: secret_prefix must include environment to match the IAM policy resource ARN.
  # Secrets are stored as: {project_name}-{environment}/connections/<conn_id>
  #                    and: {project_name}-{environment}/variables/<var_name>
  secret_prefix = "${var.project_name}-${var.environment}"


  # -----------------------------
  # VPC / CIDR math
  # -----------------------------
  vpc_cidr   = var.vpc_cidr
  cidr_size  = tonumber(regex("[0-9]+$", var.vpc_cidr))
  # Force public subnets to /28
  public_prefix = 28


  # Real AZs (from provider region)
  azs    = slice(data.aws_availability_zones.available.names,    0, var.az_count)
  az_ids = slice(data.aws_availability_zones.available.zone_ids, 0, var.az_count)


  # -----------------------------
  # Public subnets (one /28 per AZ)
  # -----------------------------
  public_newbits = local.public_prefix - local.cidr_size


  # Map keyed by AZ name -> { cidr, az, az_id }
  public_subnets = {
    for i, az in local.azs :
    az => {
      cidr  = cidrsubnet(local.vpc_cidr, local.public_newbits, i)
      az    = az
      az_id = local.az_ids[i]
    }
  }


  # -----------------------------
  # Private subnets (largest equal size that fits remainder)
  # -----------------------------
  total_28_units      = pow(2, local.public_prefix - local.cidr_size)   # e.g. /24 -> 16
  remaining_28_units  = local.total_28_units - length(local.azs)        # subtract #publics
  units_per_private = max(1, pow(2, floor(log(floor(local.remaining_28_units / length(local.azs)), 2))))


  private_prefix  = local.public_prefix - floor(log(local.units_per_private, 2))
  private_newbits = local.private_prefix - local.cidr_size


  private_blocks_per_28 = pow(2, max(0, local.public_prefix - local.private_prefix))
  offset_private_blocks = ceil(length(local.azs) / local.private_blocks_per_28)


  private_subnets = {
    for i, az in local.azs :
    az => {
      cidr  = cidrsubnet(local.vpc_cidr, local.private_newbits, i + local.offset_private_blocks)
      az    = az
      az_id = local.az_ids[i]
    }
  }
}


// -----------------------------------------------------------------------------
// VPC and Networking
// -----------------------------------------------------------------------------
resource "aws_vpc" "remote_exec_vpc" {
  cidr_block           = local.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags = merge(local.tags, { Name = "${var.project_name}-${var.environment}-vpc" })
}


resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.remote_exec_vpc.id
  tags   = merge(local.tags, { Name = "${var.project_name}-${var.environment}-igw" })
}


resource "aws_subnet" "public" {
  for_each = local.public_subnets
  vpc_id                  = aws_vpc.remote_exec_vpc.id
  cidr_block              = each.value.cidr
  availability_zone       = each.value.az
  map_public_ip_on_launch = true
  tags = merge(local.tags, { Name = "${var.project_name}-${var.environment}-public-${each.key}" })
}


resource "aws_subnet" "private" {
  for_each = local.private_subnets
  vpc_id            = aws_vpc.remote_exec_vpc.id
  cidr_block        = each.value.cidr
  availability_zone = each.value.az
  tags = merge(local.tags, { Name = "${var.project_name}-${var.environment}-private-${each.key}" })
}


resource "aws_route_table" "public" {
  vpc_id = aws_vpc.remote_exec_vpc.id
  tags   = merge(local.tags, { Name = "${var.project_name}-${var.environment}-public-rt" })
}


resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.igw.id
}


resource "aws_route_table_association" "public_assoc" {
  for_each = aws_subnet.public
  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}


# NAT Gateway EIPs for each public subnet
resource "aws_eip" "nat" {
  for_each = local.public_subnets
  domain = "vpc"
  tags   = merge(local.tags, { Name = "${var.project_name}-${var.environment}-nat-eip-${each.key}" })
}


# NAT Gateway in each public subnet
resource "aws_nat_gateway" "nat" {
  for_each      = local.public_subnets
  allocation_id = aws_eip.nat[each.key].id
  subnet_id     = aws_subnet.public[each.key].id
  tags = merge(local.tags, { Name = "${var.project_name}-${var.environment}-nat-${each.key}" })
  depends_on = [aws_internet_gateway.igw]
}


# Private Route Tables (to Internet via NAT)
resource "aws_route_table" "private" {
  for_each = aws_subnet.private
  vpc_id = aws_vpc.remote_exec_vpc.id
  tags   = merge(local.tags, { Name = "${var.project_name}-${var.environment}-private-rt-${each.key}" })
}


resource "aws_route" "private_to_internet_via_nat" {
  for_each = aws_route_table.private
  route_table_id         = each.value.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.nat[each.key].id
}


resource "aws_route_table_association" "private_assoc" {
  for_each       = aws_subnet.private
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private[each.key].id
}


// -----------------------------------------------------------------------------
// ECR Repository
// -----------------------------------------------------------------------------
resource "aws_ecr_repository" "remote_exec_demo" {
  name                 = "${var.project_name}-${var.environment}-registry"
  image_tag_mutability = "MUTABLE"
  tags                 = local.tags
}


output "ecr_repo_url" {
  value = aws_ecr_repository.remote_exec_demo.repository_url
}




// -----------------------------------------------------------------------------
// S3 Bucket (using module)
// -----------------------------------------------------------------------------
module "s3_bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  bucket  = "${var.project_name}-${var.environment}-bucket"
  tags    = local.tags
}


output "s3_bucket_name" {
  description = "Name of the S3 bucket"
  value       = module.s3_bucket.s3_bucket_id
}




// -----------------------------------------------------------------------------
// IAM Policies and Role for Development
// -----------------------------------------------------------------------------


resource "aws_iam_policy" "development_policy" {
  name        = "${var.project_name}-${var.environment}-development-policy"
  description = "Dev: push to ECR repo, describe EKS"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      # ---- ECR (required for docker login) ----
      {
        Sid: "EcrGetAuth",
        Effect: "Allow",
        Action: ["ecr:GetAuthorizationToken"],
        Resource: "*"
      },
      # ---- ECR push/pull ----
      {
        Sid: "EcrRepoPushPull",
        Effect: "Allow",
        Action: [
          "ecr:BatchCheckLayerAvailability",
          "ecr:CompleteLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
          "ecr:DescribeRepositories",
          "ecr:ListImages"
        ],
        Resource: aws_ecr_repository.remote_exec_demo.arn
      },


      # ---- EKS describe so AWS CLI can build kubeconfig ----
      {
        Sid: "EksDescribe",
        Effect: "Allow",
        Action: ["eks:DescribeCluster", "eks:ListClusters"],
        Resource: "*"
      },
    ]
  })
  tags = local.tags
}


resource "aws_iam_role" "development_role" {
  name = "${var.project_name}-${var.environment}-development-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
        {
            "Effect": "Allow",
            "Principal": {
                "Federated": "arn:aws:iam::${var.aws_account_id}:oidc-provider/token.actions.githubusercontent.com"
            },
            "Action": "sts:AssumeRoleWithWebIdentity",
            "Condition": {
                "StringEquals": {
                    "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
                },
                "StringLike": {
                    "token.actions.githubusercontent.com:sub": "repo:astronomer/remote-execution-aws-templates:*"
                }
            }
        },
    ]
  })
  tags = local.tags
}


resource "aws_iam_role_policy_attachment" "development_attach_policy" {
  role       = aws_iam_role.development_role.name
  policy_arn = aws_iam_policy.development_policy.arn
}


output "development_iam_role_arn" {
  value = aws_iam_role.development_role.arn
}


// -----------------------------------------------------------------------------
// EKS Cluster
// -----------------------------------------------------------------------------
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"
  name = "${var.project_name}-${var.environment}-eks"
  kubernetes_version = "1.33"
  endpoint_public_access = true
  enable_cluster_creator_admin_permissions = true
  enable_irsa = true
  access_entries = {
    ci_admin = {
      principal_arn = aws_iam_role.development_role.arn
      policy_associations = {
        admin_access = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            namespaces = ["default"]
            type       = "namespace"
          }
        }
      }
    }
  }
  compute_config = {
    enabled    = true
    node_pools = ["general-purpose"]
  }
  vpc_id     = aws_vpc.remote_exec_vpc.id
  subnet_ids = values(aws_subnet.private)[*].id
  tags = local.eks_tags
}


output "eks_cluster_name" {
  description = "The name of the EKS cluster"
  value       = module.eks.cluster_name
}


// -----------------------------------------------------------------------------
// IAM Policies and Roles for Astro Remote Execution Agents
// -----------------------------------------------------------------------------
resource "aws_iam_policy" "agent_policy" {
  name        = "${var.project_name}-${var.environment}-agent-policy"
  description = "IAM policy used by Astro Remote Execution Agent Pods"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      // Access to Secrets Manager secrets for Airflow connections and variables.
      // NOTE: Resource uses {project_name}-{environment} prefix to match secret naming convention.
      {
        Sid    = "SecretsManagerAccess"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret",
          "secretsmanager:ListSecrets"
        ]
        Resource = "arn:aws:secretsmanager:${var.aws_region}:${var.aws_account_id}:secret:${var.project_name}-${var.environment}/*"
      },
      // Access to S3 bucket to write task logs and XCom
      {
        Sid    = "S3Access"
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetObject",
          "s3:PutObject"
        ]
        Resource = [
          module.s3_bucket.s3_bucket_arn,
          "${module.s3_bucket.s3_bucket_arn}/*"
        ]
      }
    ]
  })
  tags = local.tags
}


resource "aws_iam_role" "agent_role" {
  name = "${var.project_name}-${var.environment}-agent-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = module.eks.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringLike = {
            "${module.eks.oidc_provider}:aud" = "sts.amazonaws.com"
            "${module.eks.oidc_provider}:sub" = "system:serviceaccount:default:*"
          }
        }
      },
    ]
  })
  tags = local.tags
}


resource "aws_iam_role_policy_attachment" "agent_attach_policy" {
  role       = aws_iam_role.agent_role.name
  policy_arn = aws_iam_policy.agent_policy.arn
}


output "agent_iam_role_arn" {
  value = aws_iam_role.agent_role.arn
}


// -----------------------------------------------------------------------------
// Git Connection Secret for DAG Bundles
// -----------------------------------------------------------------------------
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
    extra     = {
      branch = var.git_branch
    }
  })
}


// -----------------------------------------------------------------------------
// IAM Policies and Roles for Astro Orchestration Plane for Remote Logging
// -----------------------------------------------------------------------------


resource "aws_iam_policy" "astro_orchestration_plane_policy" {
  name        = "${var.project_name}-${var.environment}-astro-policy"
  description = "IAM policy used by Astro Orchestration Plane for remote logging"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3Access"
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetObject"
        ]
        Resource = [
          module.s3_bucket.s3_bucket_arn,
          "${module.s3_bucket.s3_bucket_arn}/*"
        ]
      }
    ]
  })
  tags = local.tags
}


// placeholder - once Astro deployment is created, we will update the trust policy to allow Astro to assume this role
resource "aws_iam_role" "astro_orchestration_plane_role" {
  name = "${var.project_name}-${var.environment}-astro-role"


  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid = "PlaceholderTrust",
        Effect = "Allow",
        Principal = { AWS = "arn:aws:iam::${var.aws_account_id}:root" },
        Action = "sts:AssumeRole",
        Condition = {
          StringEquals = { "sts:ExternalId" = "placeholder" }
        }
      }
    ]
  })


  tags = local.tags
}


resource "aws_iam_role_policy_attachment" "astro_orchestration_plane_attach_policy" {
  role       = aws_iam_role.astro_orchestration_plane_role.name
  policy_arn = aws_iam_policy.astro_orchestration_plane_policy.arn
}


output "astro_orchestration_plane_iam_role_arn" {
  value = aws_iam_role.astro_orchestration_plane_role.arn
}


// -----------------------------------------------------------------------------
// Outputs to help configure values.yaml
// -----------------------------------------------------------------------------
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
