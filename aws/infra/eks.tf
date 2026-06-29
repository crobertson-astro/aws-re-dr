module "eks" {
  source                                   = "terraform-aws-modules/eks/aws"
  version                                  = "~> 21.0"
  name                                     = "${var.project_name}-${var.environment}-eks"
  kubernetes_version                       = "1.33"
  endpoint_public_access                   = true
  enable_cluster_creator_admin_permissions = true
  enable_irsa                              = true
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
  tags       = local.eks_tags
}

output "eks_cluster_name" {
  description = "The name of the EKS cluster"
  value       = module.eks.cluster_name
}
