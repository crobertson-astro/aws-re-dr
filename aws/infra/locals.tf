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
  vpc_cidr  = var.vpc_cidr
  cidr_size = tonumber(regex("[0-9]+$", var.vpc_cidr))
  # Force public subnets to /28
  public_prefix = 28

  # Real AZs (from provider region)
  azs    = slice(data.aws_availability_zones.available.names, 0, var.az_count)
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
  total_28_units     = pow(2, local.public_prefix - local.cidr_size) # e.g. /24 -> 16
  remaining_28_units = local.total_28_units - length(local.azs)      # subtract #publics
  units_per_private  = max(1, pow(2, floor(log(floor(local.remaining_28_units / length(local.azs)), 2))))

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
