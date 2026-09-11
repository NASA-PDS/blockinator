# CloudFront-associated WAF IP sets must be created in us-east-1 with scope CLOUDFRONT.
# This component creates the sets. Attaching them to the existing Web ACL is a
# one-time WAF-owner action; see README.md.

resource "aws_wafv2_ip_set" "ipv4" {
  provider           = aws.us_east_1
  name               = "${local.name_prefix}-ipv4"
  description        = "Operator-managed IPv4/CIDR blocklist for PDS CloudFront"
  scope              = "CLOUDFRONT"
  ip_address_version = "IPV4"
  addresses          = []
  tags               = merge(local.tags, { Name = "${local.name_prefix}-ipv4" })
}

resource "aws_wafv2_ip_set" "ipv6" {
  provider           = aws.us_east_1
  name               = "${local.name_prefix}-ipv6"
  description        = "Operator-managed IPv6/CIDR blocklist for PDS CloudFront"
  scope              = "CLOUDFRONT"
  ip_address_version = "IPV6"
  addresses          = []
  tags               = merge(local.tags, { Name = "${local.name_prefix}-ipv6" })
}
