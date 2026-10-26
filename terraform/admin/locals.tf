data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  tags = merge(
    var.common_tags,
    {
      venue     = var.venue
      component = var.component_name
      managedby = "NASA-PDS/pdc-cds-infra"
      tenant    = "en"
      cicd      = var.cicd
    }
  )

  # Resource names: "<venue>-pds-ip-blocklist-…", e.g. pdc-cds-dev-pds-ip-blocklist-policies
  # ⚠️ Must stay in lock-step with the platform stage (terraform/locals.tf): the IAM
  # policies below are written against ARNs constructed from this prefix.
  name_prefix = "${var.venue}-pds-ip-blocklist"

  # SSM prefix the operator policy may read; must match where the platform
  # stage publishes its parameters (default /pds/cds-infra/ip-blocklist).
  ssm_prefix = var.ssm_prefix == "" ? "/pds/${var.component_name}/ip-blocklist" : var.ssm_prefix

  # This admin stage runs BEFORE the platform stage, so the platform resources
  # these IAM policies grant access to do not exist yet. All platform resource
  # names are deterministic (derived from name_prefix), so their ARNs are
  # constructed here rather than read from resource attributes.
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.name

  table_arn = "arn:aws:dynamodb:${local.region}:${local.account_id}:table/${local.name_prefix}-policies"
  queue_arn = "arn:aws:sqs:${local.region}:${local.account_id}:${local.name_prefix}-mutations.fifo"

  lambda_log_group_arns = {
    updater = "arn:aws:logs:${local.region}:${local.account_id}:log-group:/aws/lambda/${local.name_prefix}-updater"
    sweeper = "arn:aws:logs:${local.region}:${local.account_id}:log-group:/aws/lambda/${local.name_prefix}-sweeper"
    audit   = "arn:aws:logs:${local.region}:${local.account_id}:log-group:/aws/lambda/${local.name_prefix}-audit"
  }
}
