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

# Creating a Lambda requires iam:PassRole on its execution role, which platform
# engineers lack; the admin stage's deployer role holds it. Used only by the
# aws_lambda_function resources.
provider "aws" {
  alias   = "lambda_deployer"
  region  = var.aws_region
  profile = var.aws_profile

  assume_role {
    role_arn     = local.deployer_role_arn
    session_name = "blockinator-platform"
  }

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
