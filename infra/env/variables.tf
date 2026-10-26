variable "region" {
  type    = string
  default = "ap-southeast-1"
}

variable "name" {
  description = "Prefix for resource names."
  type        = string
  default     = "snapshot"
}

variable "github_repo_url" {
  description = "Public Git repo Argo CD watches."
  type        = string
  default     = "https://github.com/PhamNhatQuang207/snapshot.git"
}
