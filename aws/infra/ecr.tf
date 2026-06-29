resource "aws_ecr_repository" "remote_exec_demo" {
  name                 = "${var.project_name}-${var.environment}-registry"
  image_tag_mutability = "MUTABLE"
  tags                 = local.tags
}

output "ecr_repo_url" {
  value = aws_ecr_repository.remote_exec_demo.repository_url
}
