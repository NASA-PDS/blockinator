# IAM for the three Lambdas plus the operator CLI.
# Least privilege: only the updater role may call wafv2:UpdateIPSet.
#
# ⚠️ ADMIN STAGE: creating IAM roles and policies requires elevated ("super
# user") access, so this file lives here rather than in the platform stage.
# The DynamoDB table, SQS queue, and log groups referenced below are created
# LATER by the platform stage; their ARNs are constructed in locals.tf from
# the shared naming convention.

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
  name               = "${local.name_prefix}-updater"
  description        = "Sole identity allowed to call wafv2:UpdateIPSet for the operator blocklist"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = local.tags
}

resource "aws_iam_role" "sweeper" {
  name               = "${local.name_prefix}-sweeper"
  description        = "Expire TTL'd blocklist rows and enqueue REMOVE mutations"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = local.tags
}

resource "aws_iam_role" "audit" {
  name               = "${local.name_prefix}-audit"
  description        = "Log DynamoDB stream mutations for the operator blocklist"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = local.tags
}

data "aws_iam_policy_document" "updater" {
  statement {
    sid    = "Logs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${local.lambda_log_group_arns.updater}:*"]
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
    resources = [local.queue_arn]
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
    resources = ["${local.lambda_log_group_arns.sweeper}:*"]
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
      local.table_arn,
      "${local.table_arn}/index/status-expires_at-index",
    ]
  }

  statement {
    sid       = "EnqueueRemove"
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [local.queue_arn]
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
    resources = ["${local.lambda_log_group_arns.audit}:*"]
  }

  # Read the table stream (not the table itself); Lambda event source mapping.
  # Stream ARNs embed a creation timestamp that cannot be predicted here, so
  # this grants all streams of the (single) blocklist table.
  statement {
    sid    = "StreamRead"
    effect = "Allow"
    actions = [
      "dynamodb:DescribeStream",
      "dynamodb:GetRecords",
      "dynamodb:GetShardIterator",
      "dynamodb:ListStreams",
    ]
    resources = ["${local.table_arn}/stream/*"]
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
      local.table_arn,
      "${local.table_arn}/index/*",
    ]
  }

  statement {
    sid       = "EnqueueMutations"
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [local.queue_arn]
  }

  # Discover table name / queue URL / IP set ARNs published under local.ssm_prefix.
  statement {
    sid       = "ReadSsm"
    effect    = "Allow"
    actions   = ["ssm:GetParameter"]
    resources = ["arn:aws:ssm:${local.region}:${local.account_id}:parameter${local.ssm_prefix}/*"]
  }
}

resource "aws_iam_policy" "operator" {
  name        = "${local.name_prefix}-operator"
  description = "Allow pds-blockinator CLI to write DynamoDB and SQS without WAF access"
  policy      = data.aws_iam_policy_document.operator.json
  tags        = local.tags
}
