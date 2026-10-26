variable "region" {
  type    = string
  default = "ap-southeast-1"
}

variable "github_repo" {
  description = <<-EOT
    GitHub repository allowed to assume the CI role, in GitHub's immutable OIDC subject form
    owner@owner_id/name@repo_id. The numeric IDs never get reused, so a deleted or renamed repo
    can't be re-created by someone else to inherit this access.
    Find it with: gh api repos/<owner>/<name>/actions/oidc/customization/sub
  EOT
  type        = string
  default     = "PhamNhatQuang207@156569397/snapshot@1433890568"
}

variable "ecr_repositories" {
  description = "One ECR repository per deployable image."
  type        = list(string)
  default     = ["post-service"]
}
