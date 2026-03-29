# --------------------------------------------------------------------------
# Required
# --------------------------------------------------------------------------

variable "sentinel_account_id" {
  description = "The AWS account ID where Sentinel is hosted. Used in the IAM trust policy."
  type        = string

  validation {
    condition     = can(regex("^\\d{12}$", var.sentinel_account_id))
    error_message = "sentinel_account_id must be a 12-digit AWS account ID."
  }
}

variable "sentinel_role_name" {
  description = "Name of the IAM role in the Sentinel account that will assume into this account. Defaults to 'SentinelService'."
  type        = string
  default     = "SentinelService"
}

# --------------------------------------------------------------------------
# Naming & tagging
# --------------------------------------------------------------------------

variable "name_prefix" {
  description = "Prefix for all resource names (e.g. 'prod', 'staging'). Helps avoid collisions in multi-environment accounts."
  type        = string
  default     = "sentinel"

  validation {
    condition     = can(regex("^[a-z0-9-]{1,24}$", var.name_prefix))
    error_message = "name_prefix must be lowercase alphanumeric with hyphens, max 24 chars."
  }
}

variable "tags" {
  description = "Tags applied to every resource. Merged with default Sentinel tags."
  type        = map(string)
  default     = {}
}

# --------------------------------------------------------------------------
# Event source
# --------------------------------------------------------------------------

variable "enable_eventbridge_rule" {
  description = "Create an EventBridge rule to route CloudTrail management events to the SQS queue. Disable if you prefer SNS or a custom pipeline."
  type        = bool
  default     = true
}

variable "eventbridge_event_pattern" {
  description = "Custom EventBridge event pattern JSON. If null, uses the default CloudTrail management-event pattern."
  type        = string
  default     = null
}

variable "enable_spot_interruption_rule" {
  description = "Create an EventBridge rule for EC2 Spot Instance interruption warnings."
  type        = bool
  default     = false
}

# --------------------------------------------------------------------------
# SQS
# --------------------------------------------------------------------------

variable "sqs_message_retention_seconds" {
  description = "How long unprocessed messages stay in the queue (seconds). 4 days by default — gives the team a weekend to respond to poller outages."
  type        = number
  default     = 345600 # 4 days

  validation {
    condition     = var.sqs_message_retention_seconds >= 60 && var.sqs_message_retention_seconds <= 1209600
    error_message = "Must be between 60 and 1209600 (14 days)."
  }
}

variable "sqs_visibility_timeout_seconds" {
  description = "How long a message is hidden after a consumer receives it. Must exceed Sentinel's processing time."
  type        = number
  default     = 120
}

# --------------------------------------------------------------------------
# Encryption
# --------------------------------------------------------------------------

variable "create_kms_key" {
  description = "Create a dedicated KMS key for SQS encryption. If false, uses the AWS-managed `aws/sqs` key."
  type        = bool
  default     = true
}

variable "kms_key_arn" {
  description = "ARN of an existing KMS key for SQS encryption. Only used when create_kms_key is false."
  type        = string
  default     = null
}

# --------------------------------------------------------------------------
# Cross-account
# --------------------------------------------------------------------------

variable "external_id" {
  description = "External ID for the cross-account assume-role trust policy. Prevents confused-deputy attacks. Sentinel provides this value during setup."
  type        = string
  default     = ""
}

# --------------------------------------------------------------------------
# Optional: existing CloudTrail SNS topic
# --------------------------------------------------------------------------

variable "cloudtrail_sns_topic_arn" {
  description = "ARN of an existing SNS topic that receives CloudTrail notifications (CloudTrail -> SNS -> SQS pattern). If set, the queue subscribes to this topic instead of using EventBridge."
  type        = string
  default     = null
}
