provider "aws" {
  region = var.region
  default_tags {
    tags = {
      project = "snapshot"
      layer   = "env"
    }
  }
}
