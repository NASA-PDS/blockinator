# Privileged resources created by the ADMIN stage (terraform/admin). System
# administrators must apply that stage once per venue BEFORE this platform
# stage is applied; if they have not, the IP set lookups below fail with a
# clear "not found" error.
#
# Name construction here must stay in lock-step with terraform/admin/locals.tf
# (both derive from the same "<venue>-pds-ip-blocklist" prefix).
#
# The IAM ARNs are constructed rather than looked up: platform engineers lack
# iam:GetRole / iam:GetPolicy, and IAM ARNs are fully determined by name.

locals {
  iam_arn_prefix = "arn:aws:iam::${data.aws_caller_identity.current.account_id}"

  updater_role_arn    = "${local.iam_arn_prefix}:role/${local.name_prefix}-updater"
  sweeper_role_arn    = "${local.iam_arn_prefix}:role/${local.name_prefix}-sweeper"
  audit_role_arn      = "${local.iam_arn_prefix}:role/${local.name_prefix}-audit"
  operator_policy_arn = "${local.iam_arn_prefix}:policy/${local.name_prefix}-operator"
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
