module "s3_bucket" {
  source = "terraform-aws-modules/s3-bucket/aws"
  bucket = "${var.project_name}-${var.environment}-bucket"
  tags   = local.tags
}

output "s3_bucket_name" {
  description = "Name of the S3 bucket"
  value       = module.s3_bucket.s3_bucket_id
}
