# The platform stage does NOT read these outputs via remote state; it looks
# the roles, policy, and IP sets up by name. These outputs are informational.

output "updater_role_arn" {
  value       = aws_iam_role.updater.arn
  description = "Only IAM role with wafv2:UpdateIPSet on the blocklist IP sets"
}

output "sweeper_role_arn" {
  value       = aws_iam_role.sweeper.arn
  description = "IAM role for the TTL-expiry sweeper Lambda"
}

output "audit_role_arn" {
  value       = aws_iam_role.audit.arn
  description = "IAM role for the DynamoDB-stream audit Lambda"
}

output "deployer_role_arn" {
  value       = aws_iam_role.deployer.arn
  description = "IAM role the platform stage assumes to deploy the Lambdas"
}

output "operator_policy_arn" {
  value       = aws_iam_policy.operator.arn
  description = "IAM policy to attach to operators who run pds-blockinator"
}

output "ipv4_ipset_arn" {
  value       = aws_wafv2_ip_set.ipv4.arn
  description = "IPv4 WAFv2 IPSet ARN (attach to the CloudFront Web ACL once)"
}

output "ipv6_ipset_arn" {
  value       = aws_wafv2_ip_set.ipv6.arn
  description = "IPv6 WAFv2 IPSet ARN (attach to the CloudFront Web ACL once)"
}
