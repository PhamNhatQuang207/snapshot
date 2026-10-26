variable "region" {
  type    = string
  default = "ap-southeast-1"
}

variable "github_repo" {
  description = "GitHub repository allowed to assume the CI role, as owner/name."
  type        = string
  default     = "PhamNhatQuang207/snapshot"
}

variable "ecr_repositories" {
  description = "One ECR repository per deployable image."
  type        = list(string)
  default     = ["post-service"]
}
