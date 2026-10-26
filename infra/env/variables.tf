variable "region" {
  type    = string
  default = "ap-southeast-1"
}

variable "name" {
  description = "Prefix for resource names."
  type        = string
  default     = "snapshot"
}
