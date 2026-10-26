# CloudFront-associated WAF IP sets must be created in us-east-1 with scope CLOUDFRONT.
#
# ⚠️ ADMIN STAGE: WAF resources are owned by the WAF owners, so the IP sets
# are created here. Attaching them to the existing Web ACL is a separate
# one-time manual WAF-owner action; see README.md. The platform stage looks
# these sets up by name (data.aws_wafv2_ip_set) to wire the updater Lambda.

resource "aws_wafv2_ip_set" "ipv4" {
  provider           = aws.us_east_1
  name               = "${local.name_prefix}-ipv4"
  description        = "Operator-managed IPv4/CIDR blocklist for PDS CloudFront"
  scope              = "CLOUDFRONT"
  ip_address_version = "IPV4"
  addresses          = []
  tags               = merge(local.tags, { Name = "${local.name_prefix}-ipv4" })

  # The updater Lambda is the sole writer of the Addresses list; ignore its
  # runtime mutations so an admin re-apply never wipes active blocks.
  lifecycle {
    ignore_changes = [addresses]
  }
}

resource "aws_wafv2_ip_set" "ipv6" {
  provider           = aws.us_east_1
  name               = "${local.name_prefix}-ipv6"
  description        = "Operator-managed IPv6/CIDR blocklist for PDS CloudFront"
  scope              = "CLOUDFRONT"
  ip_address_version = "IPV6"
  addresses          = []
  tags               = merge(local.tags, { Name = "${local.name_prefix}-ipv6" })

  lifecycle {
    ignore_changes = [addresses]
  }
}
