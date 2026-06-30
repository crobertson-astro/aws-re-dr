terraform {
  required_version = ">= 1.3.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
    astro = {
      source  = "astronomer/astro"
      version = "~> 1.0"
    }
  }
  backend "s3" {
    bucket       = "astro-chase"
    key          = "aws-re-dr/infra/terraform.tfstate"
    region       = "us-west-2"
    encrypt      = true
    use_lockfile = true
  }
}
