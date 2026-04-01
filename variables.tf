variable "ca_sentinel_account_id" {
  type = string
}

variable "ca_sentinel_role_name" {
  type    = string
  default = "CASentinelServiceRole"
}

variable "external_id" {
  type = string
}

variable "name_prefix" {
  type    = string
  default = "ca-sentinel"
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "enable_eventbridge_rule" {
  type    = bool
  default = true
}

variable "eventbridge_event_pattern" {
  type    = string
  default = null
}

variable "enable_spot_interruption_rule" {
  type    = bool
  default = false
}

variable "enable_global_event_forwarding" {
  type    = bool
  default = true
}

variable "sqs_message_retention_seconds" {
  type    = number
  default = 345600
}

variable "sqs_visibility_timeout_seconds" {
  type    = number
  default = 120
}

variable "create_kms_key" {
  type    = bool
  default = true
}

variable "kms_key_arn" {
  type    = string
  default = null
}

variable "cloudtrail_sns_topic_arn" {
  type    = string
  default = null
}
