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

  # Must match the admin stage's ssm_prefix (its operator policy grants read on
  # it) and the CLI's DEFAULT_SSM_PREFIX.
  ssm_prefix = "/pds/${var.component_name}/ip-blocklist"
}
