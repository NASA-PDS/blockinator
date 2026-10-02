# Source of truth for the operator-managed IP/CIDR blocklist.
# Only attributes used as keys (table PK or GSI) must be declared here.
# Other item fields (action, reason, added_by, added_at, source, …) are
# schemaless and do not appear in this resource.
#
# DynamoDB attribute types used below:
#   S = String
#   N = Number (stored as a decimal string; used here for Unix epoch seconds)
resource "aws_dynamodb_table" "ip_access_policies" {
  name         = "${local.name_prefix}-policies"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "cidr"

  # Partition key: canonical CIDR, e.g. "203.0.113.10/32"
  attribute {
    name = "cidr"
    type = "S"
  }

  # Policy lifecycle: "ACTIVE" or "EXPIRED" (sweeper flips ACTIVE → EXPIRED)
  attribute {
    name = "status"
    type = "S"
  }

  # Unix epoch seconds when the policy should expire; omitted for no TTL
  attribute {
    name = "expires_at"
    type = "N"
  }

  # Sweeper query: status = "ACTIVE" AND expires_at <= now
  global_secondary_index {
    name            = "status-expires_at-index"
    hash_key        = "status"
    range_key       = "expires_at"
    projection_type = "ALL"
  }

  # NEW_AND_OLD_IMAGES so the audit Lambda can log both add and expire events
  stream_enabled   = true
  stream_view_type = "NEW_AND_OLD_IMAGES"

  point_in_time_recovery {
    enabled = true
  }

  tags = merge(local.tags, { Name = "${local.name_prefix}-policies" })
}
