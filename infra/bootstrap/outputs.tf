output "state_bucket" {
  value = aws_s3_bucket.tfstate.bucket
}

output "ecr_repository_urls" {
  value = { for name, r in aws_ecr_repository.this : name => r.repository_url }
}

output "github_actions_role_arn" {
  value = aws_iam_role.github_actions.arn
}
