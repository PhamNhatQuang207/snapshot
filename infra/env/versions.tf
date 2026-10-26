terraform {
  required_version = ">= 1.10"

  # Same bucket as infra/bootstrap, different key. This layer is created and destroyed every session.
  backend "s3" {
    bucket       = "snapshot-tfstate-668302078083"
    key          = "env/terraform.tfstate"
    region       = "ap-southeast-1"
    use_lockfile = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.59"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.3"
    }
  }
}
