# Serialized ADD/REMOVE bus for WAF IP set mutations.
# FIFO + a single MessageGroupId ("ipset", set by producers) keeps order.
# The updater is the only consumer.

resource "aws_sqs_queue" "ipset_dlq" {
  name                        = "${local.name_prefix}-mutations-dlq.fifo"
  fifo_queue                  = true
  content_based_deduplication = true
  # 14 days (SQS maximum) so failed mutations can be inspected.
  message_retention_seconds = 1209600
  tags                      = merge(local.tags, { Name = "${local.name_prefix}-mutations-dlq" })
}

resource "aws_sqs_queue" "ipset_mutations" {
  name       = "${local.name_prefix}-mutations.fifo"
  fifo_queue = true
  # Dedup ID is a SHA-256 of the body; producers need not set MessageDeduplicationId.
  content_based_deduplication = true
  # 2× the updater timeout (60s) so a running invoke is not retried mid-flight.
  visibility_timeout_seconds = 120
  # 4 days (SQS default).
  message_retention_seconds = 345600
  # High-throughput FIFO: dedup and throughput are per message group, not the whole queue.
  deduplication_scope   = "messageGroup"
  fifo_throughput_limit = "perMessageGroupId"

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.ipset_dlq.arn
    # After 5 failed receives, the message lands on the DLQ.
    maxReceiveCount = 5
  })

  tags = merge(local.tags, { Name = "${local.name_prefix}-mutations" })
}
