# Three Lambdas: updater (WAF writer), sweeper (TTL expiry), audit (stream → logs).
# Source is inlined from lambda/*.py and zipped at plan/apply time.

data "archive_file" "updater" {
  type        = "zip"
  output_path = "${path.module}/build/updater.zip"
  source {
    content  = file("${path.module}/lambda/updater.py")
    filename = "updater.py"
  }
}

data "archive_file" "sweeper" {
  type        = "zip"
  output_path = "${path.module}/build/sweeper.zip"
  source {
    content  = file("${path.module}/lambda/sweeper.py")
    filename = "sweeper.py"
  }
}

data "archive_file" "audit" {
  type        = "zip"
  output_path = "${path.module}/build/audit.zip"
  source {
    content  = file("${path.module}/lambda/audit.py")
    filename = "audit.py"
  }
}

resource "aws_cloudwatch_log_group" "updater" {
  name              = "/aws/lambda/${local.name_prefix}-updater"
  retention_in_days = var.log_retention_days
  tags              = local.tags
}

resource "aws_cloudwatch_log_group" "sweeper" {
  name              = "/aws/lambda/${local.name_prefix}-sweeper"
  retention_in_days = var.log_retention_days
  tags              = local.tags
}

resource "aws_cloudwatch_log_group" "audit" {
  name              = "/aws/lambda/${local.name_prefix}-audit"
  retention_in_days = var.log_retention_days
  tags              = local.tags
}

resource "aws_lambda_function" "updater" {
  function_name    = "${local.name_prefix}-updater"
  description      = "Single-writer WAF IPSet updater for the operator blocklist"
  role             = local.updater_role_arn # created by the admin stage
  handler          = "updater.lambda_handler"
  runtime          = "python3.12"
  filename         = data.archive_file.updater.output_path
  source_code_hash = data.archive_file.updater.output_base64sha256
  timeout          = 60
  memory_size      = 256
  # Cap at 1 so concurrent batches cannot race on the WAF LockToken.
  reserved_concurrent_executions = 1

  # CloudFront-scoped IP sets live in us-east-1 regardless of var.aws_region.
  environment {
    variables = {
      IPV4_IP_SET_ID   = data.aws_wafv2_ip_set.ipv4.id
      IPV4_IP_SET_NAME = data.aws_wafv2_ip_set.ipv4.name
      IPV6_IP_SET_ID   = data.aws_wafv2_ip_set.ipv6.id
      IPV6_IP_SET_NAME = data.aws_wafv2_ip_set.ipv6.name
      WAF_SCOPE        = "CLOUDFRONT"
      WAF_REGION       = "us-east-1"
    }
  }

  depends_on = [aws_cloudwatch_log_group.updater]
  tags       = local.tags
}

resource "aws_lambda_function" "sweeper" {
  function_name    = "${local.name_prefix}-sweeper"
  description      = "Expire TTL'd blocklist rows and enqueue REMOVE"
  role             = local.sweeper_role_arn # created by the admin stage
  handler          = "sweeper.lambda_handler"
  runtime          = "python3.12"
  filename         = data.archive_file.sweeper.output_path
  source_code_hash = data.archive_file.sweeper.output_base64sha256
  timeout          = 60
  memory_size      = 256

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.ip_access_policies.name
      QUEUE_URL  = aws_sqs_queue.ipset_mutations.url
    }
  }

  depends_on = [aws_cloudwatch_log_group.sweeper]
  tags       = local.tags
}

resource "aws_lambda_function" "audit" {
  function_name    = "${local.name_prefix}-audit"
  description      = "Structured audit log of blocklist DynamoDB mutations"
  role             = local.audit_role_arn # created by the admin stage
  handler          = "audit.lambda_handler"
  runtime          = "python3.12"
  filename         = data.archive_file.audit.output_path
  source_code_hash = data.archive_file.audit.output_base64sha256
  timeout          = 60
  memory_size      = 128

  depends_on = [aws_cloudwatch_log_group.audit]
  tags       = local.tags
}

resource "aws_lambda_event_source_mapping" "updater_sqs" {
  event_source_arn = aws_sqs_queue.ipset_mutations.arn
  function_name    = aws_lambda_function.updater.arn
  batch_size       = 10 # FIFO queues cap BatchSize at 10; batching window is unsupported
  # Return failed message IDs so SQS retries only those, not the whole batch.
  function_response_types = ["ReportBatchItemFailures"]
}

resource "aws_lambda_event_source_mapping" "audit_stream" {
  event_source_arn = aws_dynamodb_table.ip_access_policies.stream_arn
  function_name    = aws_lambda_function.audit.arn
  # Skip history; audit from the moment this mapping is created.
  starting_position = "LATEST"
  batch_size        = 100
}

# EventBridge schedule: run the sweeper every minute.
resource "aws_cloudwatch_event_rule" "sweeper" {
  name                = "${local.name_prefix}-sweeper"
  description         = "Expire blocklist entries whose TTL has passed"
  schedule_expression = "rate(1 minute)"
  tags                = local.tags
}

resource "aws_cloudwatch_event_target" "sweeper" {
  rule = aws_cloudwatch_event_rule.sweeper.name
  arn  = aws_lambda_function.sweeper.arn
}

resource "aws_lambda_permission" "sweeper_events" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.sweeper.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.sweeper.arn
}
