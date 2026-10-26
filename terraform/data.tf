# Privileged resources created by the ADMIN stage (terraform/admin), looked up
# by name. System administrators must apply that stage once per venue BEFORE
# this platform stage is applied; if they have not, these lookups fail with a
# clear "not found" error.
#
# Name construction here must stay in lock-step with terraform/admin/locals.tf
# (both derive from the same "<venue>-pds-ip-blocklist" prefix).

data "aws_iam_role" "updater" {
  name = "${local.name_prefix}-updater"
}

data "aws_iam_role" "sweeper" {
  name = "${local.name_prefix}-sweeper"
}

data "aws_iam_role" "audit" {
  name = "${local.name_prefix}-audit"
}

data "aws_iam_policy" "operator" {
  name = "${local.name_prefix}-operator"
}

# CloudFront-scoped IP sets live in us-east-1 regardless of var.aws_region.
data "aws_wafv2_ip_set" "ipv4" {
  provider = aws.us_east_1
  name     = "${local.name_prefix}-ipv4"
  scope    = "CLOUDFRONT"
}

data "aws_wafv2_ip_set" "ipv6" {
  provider = aws.us_east_1
  name     = "${local.name_prefix}-ipv6"
  scope    = "CLOUDFRONT"
}
