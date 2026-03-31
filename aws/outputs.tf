# ==========================================================================
# Outputs — paste these values into Sentinel's AWS integration form
# ==========================================================================

output "sqs_queue_url" {
  description = "SQS queue URL — enter this in Sentinel as 'SQS Queue URL'."
  value       = aws_sqs_queue.ca_sentinel.url
}

output "sqs_queue_arn" {
  description = "SQS queue ARN — for reference and IAM policy audits."
  value       = aws_sqs_queue.ca_sentinel.arn
}

output "sqs_region" {
  description = "AWS region — enter this in Sentinel as 'SQS Region'."
  value       = data.aws_region.current.name
}

output "role_arn" {
  description = "IAM role ARN — enter this in Sentinel as 'Role ARN'."
  value       = aws_iam_role.ca_sentinel.arn
}

output "account_id" {
  description = "This AWS account ID — enter this in Sentinel as 'Account ID'."
  value       = data.aws_caller_identity.current.account_id
}

output "kms_key_arn" {
  description = "KMS key ARN used for SQS encryption (null if using AWS-managed key)."
  value       = local.use_kms ? local.kms_key_arn : null
}

output "dlq_url" {
  description = "Dead-letter queue URL — monitor this for failed messages."
  value       = aws_sqs_queue.ca_sentinel_dlq.url
}

# Convenience: a map you can feed directly to Sentinel's API.
output "ca_sentinel_integration_config" {
  description = "JSON-ready config block for Sentinel's POST /modules/aws/integrations endpoint."
  value = {
    accountId   = data.aws_caller_identity.current.account_id
    roleArn     = aws_iam_role.ca_sentinel.arn
    sqsQueueUrl = aws_sqs_queue.ca_sentinel.url
    sqsRegion   = data.aws_region.current.name
  }
}
