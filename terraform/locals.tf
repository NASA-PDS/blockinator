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
  name_prefix = "${var.venue}-pds-ip-blocklist"

  # JPL MCP / USGS accounts require a permissions boundary on IAM roles.
  # Empty string → null so the AWS provider omits the argument.
  permissions_boundary = var.permissions_boundary_arn == "" ? null : var.permissions_boundary_arn

  # Strip everything through "terraform/" so a module at terraform/ip-blocklist
  # publishes SSM params under /pds/<component>/ip-blocklist/…
  module_relative_path = replace(abspath(path.module), "/^.*\\/terraform\\//", "")
  ssm_prefix           = "/pds/${var.component_name}/${local.module_relative_path}"
}
