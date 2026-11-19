# Backend configuration for the IP blocklist component, the Blockinator
#
# Initialize with:
#   cd terraform
#   terraform init -backend-config=.../path/to/backend.hcl

terraform {
  required_version = ">= 1.16.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.70"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }

  backend "s3" {}
}
