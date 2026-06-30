data "aws_region" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  region      = data.aws_region.current.region
  name_prefix = "${var.project_name}-${var.environment}-${local.region}"
  global_name = "${var.project_name}-${var.environment}"

  tags = {
    Project     = var.project_name
    Managed     = "terraform"
    Owner       = var.owner
    Environment = var.environment
    Region      = local.region
  }
  eks_tags = merge(local.tags, { DeleteStatus = "DND" })

  # Secrets are stored as: {project_name}-{environment}/connections/<conn_id>
  #                    and: {project_name}-{environment}/variables/<var_name>
  # Prefix is identical across regions; the secret itself lives in a regional
  # Secrets Manager, so there's no global collision.
  secret_prefix = local.global_name

  # -----------------------------
  # VPC / CIDR math
  # -----------------------------
  vpc_cidr      = var.vpc_cidr
  cidr_size     = tonumber(regex("[0-9]+$", var.vpc_cidr))
  public_prefix = 28

  azs    = slice(data.aws_availability_zones.available.names, 0, var.az_count)
  az_ids = slice(data.aws_availability_zones.available.zone_ids, 0, var.az_count)

  public_newbits = local.public_prefix - local.cidr_size

  public_subnets = {
    for i, az in local.azs :
    az => {
      cidr  = cidrsubnet(local.vpc_cidr, local.public_newbits, i)
      az    = az
      az_id = local.az_ids[i]
    }
  }

  total_28_units     = pow(2, local.public_prefix - local.cidr_size)
  remaining_28_units = local.total_28_units - length(local.azs)
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
