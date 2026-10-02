# IAM for the three Lambdas plus the operator CLI.
# Least privilege: only the updater role may call wafv2:UpdateIPSet.

# Shared trust policy: these roles can be assumed only by Lambda.
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "updater" {
  name                 = "${local.name_prefix}-updater"
  description          = "Sole identity allowed to call wafv2:UpdateIPSet for the operator blocklist"
  permissions_boundary = local.permissions_boundary
  assume_role_policy   = data.aws_iam_policy_document.lambda_assume.json
  tags                 = local.tags
}

resource "aws_iam_role" "sweeper" {
  name                 = "${local.name_prefix}-sweeper"
  description          = "Expire TTL'd blocklist rows and enqueue REMOVE mutations"
  permissions_boundary = local.permissions_boundary
  assume_role_policy   = data.aws_iam_policy_document.lambda_assume.json
  tags                 = local.tags
}

resource "aws_iam_role" "audit" {
  name                 = "${local.name_prefix}-audit"
  description          = "Log DynamoDB stream mutations for the operator blocklist"
  permissions_boundary = local.permissions_boundary
  assume_role_policy   = data.aws_iam_policy_document.lambda_assume.json
  tags                 = local.tags
}

data "aws_iam_policy_document" "updater" {
  statement {
    sid    = "Logs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.updater.arn}:*"]
  }

  # Consume the FIFO mutation bus (SQS event source mapping).
  statement {
    sid    = "SqsConsume"
    effect = "Allow"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:ChangeMessageVisibility",
    ]
    resources = [aws_sqs_queue.ipset_mutations.arn]
  }

  # Get-then-put of the full Addresses list; this is the only UpdateIPSet grant.
  statement {
    sid    = "UpdateIpSet"
    effect = "Allow"
    actions = [
      "wafv2:GetIPSet",
      "wafv2:UpdateIPSet",
    ]
    resources = [
      aws_wafv2_ip_set.ipv4.arn,
      aws_wafv2_ip_set.ipv6.arn,
    ]
  }
}

data "aws_iam_policy_document" "sweeper" {
  statement {
    sid    = "Logs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.sweeper.arn}:*"]
  }

  # Query ACTIVE rows whose expires_at has passed, then SET status = EXPIRED.
  # The GSI ARN is required in addition to the table ARN.
  statement {
    sid    = "DynamoExpiry"
    effect = "Allow"
    actions = [
      "dynamodb:Query",
      "dynamodb:UpdateItem",
    ]
    resources = [
      aws_dynamodb_table.ip_access_policies.arn,
      "${aws_dynamodb_table.ip_access_policies.arn}/index/status-expires_at-index",
    ]
  }

  statement {
    sid       = "EnqueueRemove"
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.ipset_mutations.arn]
  }
}

data "aws_iam_policy_document" "audit" {
  statement {
    sid    = "Logs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.audit.arn}:*"]
  }

  # Read the table stream (not the table itself); Lambda event source mapping.
  statement {
    sid    = "StreamRead"
    effect = "Allow"
    actions = [
      "dynamodb:DescribeStream",
      "dynamodb:GetRecords",
      "dynamodb:GetShardIterator",
      "dynamodb:ListStreams",
    ]
    resources = [aws_dynamodb_table.ip_access_policies.stream_arn]
  }
}

resource "aws_iam_role_policy" "updater" {
  name   = "updater"
  role   = aws_iam_role.updater.id
  policy = data.aws_iam_policy_document.updater.json
}

resource "aws_iam_role_policy" "sweeper" {
  name   = "sweeper"
  role   = aws_iam_role.sweeper.id
  policy = data.aws_iam_policy_document.sweeper.json
}

resource "aws_iam_role_policy" "audit" {
  name   = "audit"
  role   = aws_iam_role.audit.id
  policy = data.aws_iam_policy_document.audit.json
}

# Attach this managed policy to humans/automation that run pds-blockinator.
# Intentionally no wafv2:* — producers write DynamoDB + SQS; the updater applies WAF.
data "aws_iam_policy_document" "operator" {
  statement {
    sid    = "BlocklistTable"
    effect = "Allow"
    actions = [
      "dynamodb:PutItem",
      "dynamodb:UpdateItem",
      "dynamodb:GetItem",
      "dynamodb:Scan",
      "dynamodb:Query",
    ]
    resources = [
      aws_dynamodb_table.ip_access_policies.arn,
      "${aws_dynamodb_table.ip_access_policies.arn}/index/*",
    ]
  }

  statement {
    sid       = "EnqueueMutations"
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.ipset_mutations.arn]
  }

  # Discover table name / queue URL / IP set ARNs published under local.ssm_prefix.
  statement {
    sid       = "ReadSsm"
    effect    = "Allow"
    actions   = ["ssm:GetParameter"]
    resources = ["arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter${local.ssm_prefix}/*"]
  }
}

resource "aws_iam_policy" "operator" {
  name        = "${local.name_prefix}-operator"
  description = "Allow pds-blockinator CLI to write DynamoDB and SQS without WAF access"
  policy      = data.aws_iam_policy_document.operator.json
  tags        = local.tags
}
