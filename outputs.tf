output "sqs_queue_url" {
  value = module.sentinel.sqs_queue_url
}

output "sqs_queue_arn" {
  value = module.sentinel.sqs_queue_arn
}

output "sqs_region" {
  value = module.sentinel.sqs_region
}

output "role_arn" {
  value = module.sentinel.role_arn
}

output "account_id" {
  value = module.sentinel.account_id
}

output "kms_key_arn" {
  value = module.sentinel.kms_key_arn
}

output "dlq_url" {
  value = module.sentinel.dlq_url
}

output "ca_sentinel_integration_config" {
  value = module.sentinel.ca_sentinel_integration_config
}
