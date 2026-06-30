locals {
  global_name = "${var.project_name}-${var.environment}"

  tags = {
    Project     = var.project_name
    Managed     = "terraform"
    Owner       = var.owner
    Environment = var.environment
  }
}
