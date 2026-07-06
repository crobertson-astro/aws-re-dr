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
  # Partial backend config. Copy backend.hcl.example to backend.hcl, fill in
  # your own S3 bucket / key / region, then run:
  #   terraform init -backend-config=backend.hcl
  backend "s3" {}
}
