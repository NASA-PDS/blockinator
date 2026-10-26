# AWS Provider Configuration
#
# CloudFront-scoped WAFv2 IP sets must live in us-east-1.
provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile

  default_tags {
    tags = var.common_tags
  }
}

provider "aws" {
  alias   = "us_east_1"
  region  = "us-east-1"
  profile = var.aws_profile

  default_tags {
    tags = var.common_tags
  }
}
