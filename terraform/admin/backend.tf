# Backend configuration for the Blockinator ADMIN stage.
#
# ⚠️ This stage keeps its own state, SEPARATE from the platform stage in the
# parent directory. Use a distinct state key when initializing, e.g.:
#
#   cd terraform/admin
#   terraform init \
#     -backend-config=.../path/to/backend.hcl \
#     -backend-config='key=blockinator/admin.tfstate'

terraform {
  required_version = ">= 1.16.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {}
}
