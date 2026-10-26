terraform {
  required_version = ">= 1.10"

  # State lives in the bucket this layer creates. First apply ran with local state,
  # then `terraform init -migrate-state` moved it here. Backends can't use variables.
  backend "s3" {
    bucket       = "snapshot-tfstate-668302078083"
    key          = "bootstrap/terraform.tfstate"
    region       = "ap-southeast-1"
    use_lockfile = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      project = "snapshot"
      layer   = "bootstrap"
    }
  }
}
