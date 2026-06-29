resource "aws_ecr_repository" "remote_exec_demo" {
  name                 = "${local.global_name}-registry"
  image_tag_mutability = "MUTABLE"
  tags                 = local.tags
}

module "s3_bucket" {
  source = "terraform-aws-modules/s3-bucket/aws"
  bucket = "${local.name_prefix}-bucket"
  tags   = local.tags
}

module "eks" {
  source                                   = "terraform-aws-modules/eks/aws"
  version                                  = "~> 21.0"
  name                                     = "${local.global_name}-eks"
  kubernetes_version                       = "1.33"
  endpoint_public_access                   = true
  enable_cluster_creator_admin_permissions = true
  enable_irsa                              = true
  access_entries = {
    ci_admin = {
      principal_arn = var.development_role_arn
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
  tags       = local.eks_tags
}

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
  description = "Airflow Git connection for DAG bundle - ${local.global_name}"
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
