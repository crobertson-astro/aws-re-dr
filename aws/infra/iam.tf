// -----------------------------------------------------------------------------
// Development role (GitHub Actions OIDC -> push to ECR, describe EKS)
// -----------------------------------------------------------------------------
resource "aws_iam_policy" "development_policy" {
  name        = "${var.project_name}-${var.environment}-development-policy"
  description = "Dev: push to ECR repo, describe EKS"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      # ---- ECR (required for docker login) ----
      {
        Sid : "EcrGetAuth",
        Effect : "Allow",
        Action : ["ecr:GetAuthorizationToken"],
        Resource : "*"
      },
      # ---- ECR push/pull ----
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
        Resource : aws_ecr_repository.remote_exec_demo.arn
      },
      # ---- EKS describe so AWS CLI can build kubeconfig ----
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
  name = "${var.project_name}-${var.environment}-development-role"
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

output "development_iam_role_arn" {
  value = aws_iam_role.development_role.arn
}

// -----------------------------------------------------------------------------
// Agent role (Astro Remote Execution Agent pods via IRSA)
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
// Astro Orchestration Plane role (remote logging)
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

output "astro_orchestration_plane_iam_role_arn" {
  value = aws_iam_role.astro_orchestration_plane_role.arn
}
