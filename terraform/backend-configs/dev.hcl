region = "us-west-2"
bucket = "pds-dev-infra"
# Note that when Blockinator was known as `ip-blocklist` and lived in the `pdc-cds-infra` repository,
# its dev backend was originally keyed to `pdc-cds-infra/ip-blocklist/terraform.tfstate`.
#
# That state file has been migrated to this key location:
key    = "blockinator/terraform.tfstate"
