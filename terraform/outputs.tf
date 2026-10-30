resource "aws_ssm_parameter" "table_name" {
  name        = "${local.ssm_prefix}/table-name"
  type        = "String"
  value       = aws_dynamodb_table.ip_access_policies.name
  description = "DynamoDB table for operator IP/CIDR blocklist policies"
  tags        = local.tags
}

resource "aws_ssm_parameter" "queue_url" {
  name        = "${local.ssm_prefix}/queue-url"
  type        = "String"
  value       = aws_sqs_queue.ipset_mutations.url
  description = "SQS FIFO queue URL for WAF IPSet mutations"
  tags        = local.tags
}

resource "aws_ssm_parameter" "ipv4_ipset_arn" {
  name        = "${local.ssm_prefix}/ipv4-ipset-arn"
  type        = "String"
  value       = data.aws_wafv2_ip_set.ipv4.arn
  description = "ARN of the CloudFront-scoped IPv4 blocklist IP set"
  tags        = local.tags
}

resource "aws_ssm_parameter" "ipv6_ipset_arn" {
  name        = "${local.ssm_prefix}/ipv6-ipset-arn"
  type        = "String"
  value       = data.aws_wafv2_ip_set.ipv6.arn
  description = "ARN of the CloudFront-scoped IPv6 blocklist IP set"
  tags        = local.tags
}

resource "aws_ssm_parameter" "audit_log_group" {
  name        = "${local.ssm_prefix}/audit-log-group"
  type        = "String"
  value       = aws_cloudwatch_log_group.audit.name
  description = "CloudWatch log group for blocklist add/remove/expire audit events"
  tags        = local.tags
}

resource "aws_ssm_parameter" "operator_policy_arn" {
  name        = "${local.ssm_prefix}/operator-policy-arn"
  type        = "String"
  value       = local.operator_policy_arn
  description = "IAM policy ARN to attach to operators who run pds-blockinator"
  tags        = local.tags
}

output "table_name" {
  value       = aws_dynamodb_table.ip_access_policies.name
  description = "DynamoDB table name"
}

output "queue_url" {
  value       = aws_sqs_queue.ipset_mutations.url
  description = "SQS FIFO mutation queue URL"
}

output "ipv4_ipset_arn" {
  value       = data.aws_wafv2_ip_set.ipv4.arn
  description = "IPv4 WAFv2 IPSet ARN (attach to the CloudFront Web ACL once)"
}

output "ipv6_ipset_arn" {
  value       = data.aws_wafv2_ip_set.ipv6.arn
  description = "IPv6 WAFv2 IPSet ARN (attach to the CloudFront Web ACL once)"
}

output "ssm_prefix" {
  value       = local.ssm_prefix
  description = "SSM prefix for this component's outputs"
}

output "updater_role_arn" {
  value       = local.updater_role_arn
  description = "Only IAM role with wafv2:UpdateIPSet on the blocklist IP sets"
}

output "operator_policy_arn" {
  value       = local.operator_policy_arn
  description = "IAM policy to attach to operators who run pds-blockinator"
}
