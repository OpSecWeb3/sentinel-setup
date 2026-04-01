module "sentinel" {
  source = "./aws"

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  ca_sentinel_account_id = var.ca_sentinel_account_id
  ca_sentinel_role_name  = var.ca_sentinel_role_name
  external_id            = var.external_id

  name_prefix = var.name_prefix
  tags        = var.tags

  enable_eventbridge_rule        = var.enable_eventbridge_rule
  eventbridge_event_pattern      = var.eventbridge_event_pattern
  enable_spot_interruption_rule  = var.enable_spot_interruption_rule
  enable_global_event_forwarding = var.enable_global_event_forwarding

  sqs_message_retention_seconds  = var.sqs_message_retention_seconds
  sqs_visibility_timeout_seconds = var.sqs_visibility_timeout_seconds

  create_kms_key = var.create_kms_key
  kms_key_arn    = var.kms_key_arn

  cloudtrail_sns_topic_arn = var.cloudtrail_sns_topic_arn
}
