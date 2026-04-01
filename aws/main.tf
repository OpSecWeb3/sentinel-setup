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
      "Application" = "ca_sentinel"
      "Component"   = "aws-integration"
    },
    var.tags,
  )

  kms_key_arn = var.create_kms_key ? aws_kms_key.ca_sentinel[0].arn : var.kms_key_arn
  # Must not depend on kms_key_arn when create_kms_key is true — the new key's ARN is unknown until apply,
  # which would make count on aws_iam_role_policy.ca_sentinel_kms unknown.
  use_kms = var.create_kms_key || var.kms_key_arn != null
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# --------------------------------------------------------------------------
# KMS — encryption at rest for SQS
# --------------------------------------------------------------------------

resource "aws_kms_key" "ca_sentinel" {
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
        Principal = { AWS = aws_iam_role.ca_sentinel.arn }
        Action    = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource  = "*"
      },
    ]
  })
}

resource "aws_kms_alias" "ca_sentinel" {
  count = var.create_kms_key ? 1 : 0

  name          = "alias/${var.name_prefix}-sqs"
  target_key_id = aws_kms_key.ca_sentinel[0].key_id
}

# --------------------------------------------------------------------------
# SQS — the queue Sentinel polls
# --------------------------------------------------------------------------

resource "aws_sqs_queue" "ca_sentinel_dlq" {
  name                      = "${var.name_prefix}-events-dlq"
  message_retention_seconds = 1209600 # 14 days — max retention for forensic review
  tags                      = local.tags

  sqs_managed_sse_enabled = local.use_kms ? null : true
}

resource "aws_sqs_queue" "ca_sentinel" {
  name                       = "${var.name_prefix}-events"
  visibility_timeout_seconds = var.sqs_visibility_timeout_seconds
  message_retention_seconds  = var.sqs_message_retention_seconds
  receive_wait_time_seconds  = 20 # max long-polling — fewer empty receives vs shorter waits
  tags                       = local.tags

  # Encryption
  kms_master_key_id                 = local.use_kms ? local.kms_key_arn : null
  kms_data_key_reuse_period_seconds = local.use_kms ? 300 : null
  sqs_managed_sse_enabled           = local.use_kms ? null : true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.ca_sentinel_dlq.arn
    maxReceiveCount     = 5
  })
}

# Allow EventBridge and optionally SNS to send messages to the queue.
resource "aws_sqs_queue_policy" "ca_sentinel" {
  queue_url = aws_sqs_queue.ca_sentinel.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      # EventBridge -> SQS (primary region rules + forwarded global events rule)
      var.enable_eventbridge_rule || var.enable_spot_interruption_rule || local.deploy_global_forwarding ? [
        {
          Sid       = "AllowEventBridge"
          Effect    = "Allow"
          Principal = { Service = "events.amazonaws.com" }
          Action    = "sqs:SendMessage"
          Resource  = aws_sqs_queue.ca_sentinel.arn
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
          Resource  = aws_sqs_queue.ca_sentinel.arn
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
  endpoint             = aws_sqs_queue.ca_sentinel.arn
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
    source      = ["aws.cloudtrail", "aws.signin", "aws.iam", "aws.ec2", "aws.s3", "aws.route53", "aws.ssm", "aws.secretsmanager", "aws.dynamodb", "aws.ecs"]
    detail-type = ["AWS API Call via CloudTrail", "AWS Console Sign In via CloudTrail"]
    detail = {
      eventSource = [
        "iam.amazonaws.com",
        "cloudtrail.amazonaws.com",
        "ec2.amazonaws.com",
        "s3.amazonaws.com",
        "route53.amazonaws.com",
        "ssm.amazonaws.com",
        "secretsmanager.amazonaws.com",
        "dynamodb.amazonaws.com",
        "ecs.amazonaws.com"
      ]
    }
  })
}

resource "aws_cloudwatch_event_target" "cloudtrail_to_sqs" {
  count = var.enable_eventbridge_rule ? 1 : 0

  rule      = aws_cloudwatch_event_rule.cloudtrail[0].name
  target_id = "ca_sentinel-sqs"
  arn       = aws_sqs_queue.ca_sentinel.arn
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
  target_id = "ca_sentinel-sqs"
  arn       = aws_sqs_queue.ca_sentinel.arn
}

# --------------------------------------------------------------------------
# Global event forwarding — us-east-1 → primary region
#
# IAM, STS, and console sign-in events only appear in us-east-1. When the
# primary region is different, we deploy EventBridge rules in us-east-1 that
# forward events to the primary region's default event bus, where a catch
# rule routes them into the SQS queue.
# --------------------------------------------------------------------------

locals {
  # Only deploy forwarding if enabled AND primary region isn't already us-east-1
  deploy_global_forwarding = var.enable_global_event_forwarding && data.aws_region.current.name != "us-east-1"
}

# us-east-1: rule that matches CloudTrail global events
resource "aws_cloudwatch_event_rule" "global_cloudtrail" {
  count    = local.deploy_global_forwarding ? 1 : 0
  provider = aws.us_east_1

  name        = "${var.name_prefix}-global-events"
  description = "Forwards IAM/STS/sign-in events from us-east-1 to ${data.aws_region.current.name} for Sentinel"
  tags        = local.tags

  event_pattern = jsonencode({
    source      = ["aws.cloudtrail", "aws.signin", "aws.iam", "aws.route53"]
    detail-type = ["AWS API Call via CloudTrail", "AWS Console Sign In via CloudTrail"]
    detail = {
      eventSource = [
        "iam.amazonaws.com",
        "cloudtrail.amazonaws.com",
        "route53.amazonaws.com"
      ]
    }
  })
}

# us-east-1: forward matched events to the primary region's default event bus
resource "aws_cloudwatch_event_target" "global_to_primary_bus" {
  count    = local.deploy_global_forwarding ? 1 : 0
  provider = aws.us_east_1

  rule      = aws_cloudwatch_event_rule.global_cloudtrail[0].name
  target_id = "${var.name_prefix}-fwd-to-primary"
  arn       = "arn:aws:events:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:event-bus/default"
  role_arn  = aws_iam_role.global_event_forwarder[0].arn
}

# IAM role that allows EventBridge in us-east-1 to PutEvents on the primary bus
resource "aws_iam_role" "global_event_forwarder" {
  count = local.deploy_global_forwarding ? 1 : 0

  name = "${var.name_prefix}-global-fwd-role"
  tags = local.tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "global_event_forwarder" {
  count = local.deploy_global_forwarding ? 1 : 0

  name = "${var.name_prefix}-global-fwd-put-events"
  role = aws_iam_role.global_event_forwarder[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "events:PutEvents"
      Resource = "arn:aws:events:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:event-bus/default"
    }]
  })
}

# Primary region: catch forwarded events from us-east-1 and route to SQS
resource "aws_cloudwatch_event_rule" "forwarded_global" {
  count = local.deploy_global_forwarding ? 1 : 0

  name        = "${var.name_prefix}-forwarded-global-events"
  description = "Catches global events forwarded from us-east-1 and routes to Sentinel SQS"
  tags        = local.tags

  event_pattern = jsonencode({
    source      = ["aws.cloudtrail", "aws.signin", "aws.iam", "aws.route53"]
    detail-type = ["AWS API Call via CloudTrail", "AWS Console Sign In via CloudTrail"]
    detail = {
      eventSource = [
        "iam.amazonaws.com",
        "sts.amazonaws.com",
        "signin.amazonaws.com",
        "organizations.amazonaws.com",
        "cloudtrail.amazonaws.com",
        "route53.amazonaws.com"
      ]
    }
  })
}

resource "aws_cloudwatch_event_target" "forwarded_global_to_sqs" {
  count = local.deploy_global_forwarding ? 1 : 0

  rule      = aws_cloudwatch_event_rule.forwarded_global[0].name
  target_id = "${var.name_prefix}-global-sqs"
  arn       = aws_sqs_queue.ca_sentinel.arn
}

# --------------------------------------------------------------------------
# IAM — cross-account role for Sentinel
# --------------------------------------------------------------------------

resource "aws_iam_role" "ca_sentinel" {
  name = "${var.name_prefix}-integration-role"
  tags = local.tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowCASentinelAssume"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${var.ca_sentinel_account_id}:role/${var.ca_sentinel_role_name}" }
        Action    = "sts:AssumeRole"
        Condition = {
          # External ID prevents confused-deputy attacks by ensuring only Sentinel can assume this role.
          StringEquals = { "sts:ExternalId" = var.external_id }
        }
      }
    ]
  })

  # Explicit max session duration — Sentinel renews every hour
  max_session_duration = 3600
}

resource "aws_iam_role_policy" "ca_sentinel_sqs" {
  name = "${var.name_prefix}-sqs-read"
  role = aws_iam_role.ca_sentinel.id

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
          aws_sqs_queue.ca_sentinel.arn,
        ]
      },
    ]
  })
}

resource "aws_iam_role_policy" "ca_sentinel_kms" {
  count = local.use_kms ? 1 : 0

  name = "${var.name_prefix}-kms-decrypt"
  role = aws_iam_role.ca_sentinel.id

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
  queue_url = aws_sqs_queue.ca_sentinel_dlq.id

  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.ca_sentinel.arn]
  })
}
