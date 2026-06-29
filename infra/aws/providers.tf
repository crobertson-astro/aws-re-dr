// Default provider is pinned to the primary region; used for global resources
// (IAM, GitHub OIDC). IAM is region-agnostic but every aws provider needs a region.
provider "aws" {
  region  = var.primary_region
  profile = var.aws_profile
}

provider "aws" {
  alias   = "primary"
  region  = var.primary_region
  profile = var.aws_profile
}

provider "aws" {
  alias   = "failover"
  region  = var.failover_region
  profile = var.aws_profile
}
