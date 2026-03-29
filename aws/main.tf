# ==========================================================================
# Sentinel AWS Integration Setup
#
# This module provisions the AWS-side resources that Sentinel needs to
# ingest CloudTrail and EventBridge events from your account:
#
#   1. SQS queue        — Sentinel polls this for events
#   2. KMS key          — Encrypts messages at rest (optional)
#   3. IAM role         — Cross-account role Sentinel assumes
#   4. EventBridge rule — Routes CloudTrail events to the SQS queue
#
# See outputs.tf for the values to paste into Sentinel's integration form.
# ==========================================================================

locals {
  tags = merge(
    {
      "ManagedBy"   = "terraform"
      "Application" = "sentinel"
      "Component"   = "aws-integration"
    },
    var.tags,
  )

  kms_key_arn = var.create_kms_key ? aws_kms_key.sentinel[0].arn : var.kms_key_arn
  use_kms     = local.kms_key_arn != null
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# --------------------------------------------------------------------------
# KMS — encryption at rest for SQS
# --------------------------------------------------------------------------

resource "aws_kms_key" "sentinel" {
  count = var.create_kms_key ? 1 : 0

  description             = "Encrypts Sentinel SQS queue messages"
  deletion_window_in_days = 14
  enable_key_rotation     = true
  tags                    = local.tags

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # Account root — full admin
      {
        Sid       = "AllowAccountAdmin"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      # EventBridge needs GenerateDataKey + Decrypt to write encrypted messages
      {
        Sid       = "AllowEventBridgeEncrypt"
        Effect    = "Allow"
        Principal = { Service = "events.amazonaws.com" }
        Action    = ["kms:GenerateDataKey", "kms:Decrypt"]
        Resource  = "*"
      },
      # SNS (if using CloudTrail -> SNS -> SQS pattern)
      {
        Sid       = "AllowSNSEncrypt"
        Effect    = "Allow"
        Principal = { Service = "sns.amazonaws.com" }
        Action    = ["kms:GenerateDataKey", "kms:Decrypt"]
        Resource  = "*"
      },
      # Sentinel role needs Decrypt to read messages
      {
        Sid       = "AllowSentinelDecrypt"
        Effect    = "Allow"
        Principal = { AWS = aws_iam_role.sentinel.arn }
        Action    = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource  = "*"
      },
    ]
  })
}

resource "aws_kms_alias" "sentinel" {
  count = var.create_kms_key ? 1 : 0

  name          = "alias/${var.name_prefix}-sqs"
  target_key_id = aws_kms_key.sentinel[0].key_id
}

# --------------------------------------------------------------------------
# SQS — the queue Sentinel polls
# --------------------------------------------------------------------------

resource "aws_sqs_queue" "sentinel_dlq" {
  name                      = "${var.name_prefix}-events-dlq"
  message_retention_seconds = 1209600 # 14 days — max retention for forensic review
  tags                      = local.tags

  sqs_managed_sse_enabled = local.use_kms ? null : true
}

resource "aws_sqs_queue" "sentinel" {
  name                       = "${var.name_prefix}-events"
  visibility_timeout_seconds = var.sqs_visibility_timeout_seconds
  message_retention_seconds  = var.sqs_message_retention_seconds
  receive_wait_time_seconds  = 5 # long-polling reduces empty receives and cost
  tags                       = local.tags

  # Encryption
  kms_master_key_id                 = local.use_kms ? local.kms_key_arn : null
  kms_data_key_reuse_period_seconds = local.use_kms ? 300 : null
  sqs_managed_sse_enabled           = local.use_kms ? null : true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.sentinel_dlq.arn
    maxReceiveCount     = 5
  })
}

# Allow EventBridge and optionally SNS to send messages to the queue.
resource "aws_sqs_queue_policy" "sentinel" {
  queue_url = aws_sqs_queue.sentinel.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      # EventBridge -> SQS
      var.enable_eventbridge_rule || var.enable_spot_interruption_rule ? [
        {
          Sid       = "AllowEventBridge"
          Effect    = "Allow"
          Principal = { Service = "events.amazonaws.com" }
          Action    = "sqs:SendMessage"
          Resource  = aws_sqs_queue.sentinel.arn
          Condition = {
            ArnLike = {
              "aws:SourceArn" = "arn:aws:events:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:rule/${var.name_prefix}-*"
            }
          }
        }
      ] : [],

      # SNS -> SQS (optional CloudTrail fan-out)
      var.cloudtrail_sns_topic_arn != null ? [
        {
          Sid       = "AllowSNS"
          Effect    = "Allow"
          Principal = { Service = "sns.amazonaws.com" }
          Action    = "sqs:SendMessage"
          Resource  = aws_sqs_queue.sentinel.arn
          Condition = {
            ArnEquals = {
              "aws:SourceArn" = var.cloudtrail_sns_topic_arn
            }
          }
        }
      ] : [],
    )
  })
}

# SNS subscription (if using existing CloudTrail SNS topic)
resource "aws_sns_topic_subscription" "cloudtrail_to_sqs" {
  count = var.cloudtrail_sns_topic_arn != null ? 1 : 0

  topic_arn            = var.cloudtrail_sns_topic_arn
  protocol             = "sqs"
  endpoint             = aws_sqs_queue.sentinel.arn
  raw_message_delivery = true
}

# --------------------------------------------------------------------------
# EventBridge — route CloudTrail events to the SQS queue
# --------------------------------------------------------------------------

resource "aws_cloudwatch_event_rule" "cloudtrail" {
  count = var.enable_eventbridge_rule ? 1 : 0

  name        = "${var.name_prefix}-cloudtrail-events"
  description = "Routes CloudTrail management events to Sentinel SQS queue"
  tags        = local.tags

  event_pattern = var.eventbridge_event_pattern != null ? var.eventbridge_event_pattern : jsonencode({
    source      = ["aws.cloudtrail", "aws.signin"]
    detail-type = ["AWS API Call via CloudTrail", "AWS Console Sign In via CloudTrail"]
  })
}

resource "aws_cloudwatch_event_target" "cloudtrail_to_sqs" {
  count = var.enable_eventbridge_rule ? 1 : 0

  rule      = aws_cloudwatch_event_rule.cloudtrail[0].name
  target_id = "sentinel-sqs"
  arn       = aws_sqs_queue.sentinel.arn
}

# EC2 Spot Instance interruption warnings
resource "aws_cloudwatch_event_rule" "spot_interruption" {
  count = var.enable_spot_interruption_rule ? 1 : 0

  name        = "${var.name_prefix}-spot-interruption"
  description = "Routes EC2 Spot Instance interruption warnings to Sentinel"
  tags        = local.tags

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Spot Instance Interruption Warning"]
  })
}

resource "aws_cloudwatch_event_target" "spot_to_sqs" {
  count = var.enable_spot_interruption_rule ? 1 : 0

  rule      = aws_cloudwatch_event_rule.spot_interruption[0].name
  target_id = "sentinel-sqs"
  arn       = aws_sqs_queue.sentinel.arn
}

# --------------------------------------------------------------------------
# IAM — cross-account role for Sentinel
# --------------------------------------------------------------------------

resource "aws_iam_role" "sentinel" {
  name = "${var.name_prefix}-integration-role"
  tags = local.tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowSentinelAssume"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${var.sentinel_account_id}:role/${var.sentinel_role_name}" }
        Action    = "sts:AssumeRole"
        Condition = merge(
          # External ID prevents confused-deputy attacks
          var.external_id != "" ? {
            StringEquals = { "sts:ExternalId" = var.external_id }
          } : {},
          # Optional: restrict to tagged sessions
          {},
        )
      }
    ]
  })

  # Explicit max session duration — Sentinel renews every hour
  max_session_duration = 3600
}

resource "aws_iam_role_policy" "sentinel_sqs" {
  name = "${var.name_prefix}-sqs-read"
  role = aws_iam_role.sentinel.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SQSRead"
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "sqs:GetQueueUrl",
        ]
        Resource = [
          aws_sqs_queue.sentinel.arn,
        ]
      },
    ]
  })
}

resource "aws_iam_role_policy" "sentinel_kms" {
  count = local.use_kms ? 1 : 0

  name = "${var.name_prefix}-kms-decrypt"
  role = aws_iam_role.sentinel.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "KMSDecrypt"
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = [local.kms_key_arn]
      },
    ]
  })
}

# --------------------------------------------------------------------------
# DLQ redrive — allow main queue to push to DLQ
# --------------------------------------------------------------------------

resource "aws_sqs_queue_redrive_allow_policy" "dlq" {
  queue_url = aws_sqs_queue.sentinel_dlq.id

  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.sentinel.arn]
  })
}
