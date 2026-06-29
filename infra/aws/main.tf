module "primary" {
  source    = "./modules/remote-exec-region"
  providers = { aws = aws.primary }

  aws_account_id       = var.aws_account_id
  project_name         = var.project_name
  environment          = var.environment
  owner                = var.owner
  vpc_cidr             = var.vpc_cidr
  az_count             = var.az_count
  development_role_arn = aws_iam_role.development_role.arn

  git_repo_url = var.git_repo_url
  git_username = var.git_username
  git_pat      = var.git_pat
  git_branch   = var.git_branch
  dag_subdir   = var.dag_subdir
}

module "failover" {
  source    = "./modules/remote-exec-region"
  providers = { aws = aws.failover }

  aws_account_id       = var.aws_account_id
  project_name         = var.project_name
  environment          = var.environment
  owner                = var.owner
  vpc_cidr             = var.vpc_cidr
  az_count             = var.az_count
  development_role_arn = aws_iam_role.development_role.arn

  git_repo_url = var.git_repo_url
  git_username = var.git_username
  git_pat      = var.git_pat
  git_branch   = var.git_branch
  dag_subdir   = var.dag_subdir
}


// -----------------------------------------------------------------------------
// Global development role (GitHub Actions OIDC -> push to ECR, describe EKS).
// IAM is account-global, so this is created once and referenced by both regions.
// -----------------------------------------------------------------------------
resource "aws_iam_policy" "development_policy" {
  name        = "${local.global_name}-development-policy"
  description = "Dev: push to ECR repos in all regions, describe EKS"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid : "EcrGetAuth",
        Effect : "Allow",
        Action : ["ecr:GetAuthorizationToken"],
        Resource : "*"
      },
      {
        Sid : "EcrRepoPushPull",
        Effect : "Allow",
        Action : [
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
        Resource : [
          module.primary.ecr_repo_arn,
          module.failover.ecr_repo_arn,
        ]
      },
      {
        Sid : "EksDescribe",
        Effect : "Allow",
        Action : ["eks:DescribeCluster", "eks:ListClusters"],
        Resource : "*"
      },
    ]
  })
  tags = local.tags
}

resource "aws_iam_role" "development_role" {
  name = "${local.global_name}-development-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        "Effect" : "Allow",
        "Principal" : {
          "Federated" : "arn:aws:iam::${var.aws_account_id}:oidc-provider/token.actions.githubusercontent.com"
        },
        "Action" : "sts:AssumeRoleWithWebIdentity",
        "Condition" : {
          "StringEquals" : {
            "token.actions.githubusercontent.com:aud" : "sts.amazonaws.com"
          },
          "StringLike" : {
            "token.actions.githubusercontent.com:sub" : "repo:astronomer/remote-execution-aws-templates:*"
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

// -----------------------------------------------------------------------------
// Agent role (Astro Remote Execution Agent pods via IRSA).
// One global role trusted by the EKS OIDC provider in each region; grants
// access to S3 buckets and Secrets Manager secrets in both regions.
// -----------------------------------------------------------------------------
resource "aws_iam_policy" "agent_policy" {
  name        = "${local.global_name}-agent-policy"
  description = "IAM policy used by Astro Remote Execution Agent Pods (multi-region)"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SecretsManagerAccess"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret",
          "secretsmanager:ListSecrets"
        ]
        Resource = [
          "arn:aws:secretsmanager:${module.primary.region}:${var.aws_account_id}:secret:${local.global_name}/*",
          "arn:aws:secretsmanager:${module.failover.region}:${var.aws_account_id}:secret:${local.global_name}/*",
        ]
      },
      {
        Sid    = "S3Access"
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetObject",
          "s3:PutObject"
        ]
        Resource = [
          module.primary.s3_bucket_arn,
          "${module.primary.s3_bucket_arn}/*",
          module.failover.s3_bucket_arn,
          "${module.failover.s3_bucket_arn}/*",
        ]
      }
    ]
  })
  tags = local.tags
}

resource "aws_iam_role" "agent_role" {
  name = "${local.global_name}-agent-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Federated = module.primary.eks_oidc_provider_arn }
        Action    = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringLike = {
            "${module.primary.eks_oidc_provider}:aud" = "sts.amazonaws.com"
            "${module.primary.eks_oidc_provider}:sub" = "system:serviceaccount:default:*"
          }
        }
      },
      {
        Effect    = "Allow"
        Principal = { Federated = module.failover.eks_oidc_provider_arn }
        Action    = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringLike = {
            "${module.failover.eks_oidc_provider}:aud" = "sts.amazonaws.com"
            "${module.failover.eks_oidc_provider}:sub" = "system:serviceaccount:default:*"
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

// -----------------------------------------------------------------------------
// Astro Orchestration Plane role (remote logging).
// One global role granted read access to both regional S3 buckets.
// -----------------------------------------------------------------------------
resource "aws_iam_policy" "astro_orchestration_plane_policy" {
  name        = "${local.global_name}-astro-policy"
  description = "IAM policy used by Astro Orchestration Plane for remote logging (multi-region)"
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
          module.primary.s3_bucket_arn,
          "${module.primary.s3_bucket_arn}/*",
          module.failover.s3_bucket_arn,
          "${module.failover.s3_bucket_arn}/*",
        ]
      }
    ]
  })
  tags = local.tags
}

# placeholder - once Astro deployment is created, update the trust policy to allow Astro to assume this role
resource "aws_iam_role" "astro_orchestration_plane_role" {
  name = "${local.global_name}-astro-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid       = "PlaceholderTrust",
        Effect    = "Allow",
        Principal = { AWS = "arn:aws:iam::${var.aws_account_id}:root" },
        Action    = "sts:AssumeRole",
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
