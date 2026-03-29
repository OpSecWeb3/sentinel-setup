# Sentinel AWS Integration — Terraform Setup

This Terraform module provisions the AWS-side resources required to connect your AWS account to Sentinel for CloudTrail event monitoring.

## What it creates

| Resource | Purpose |
|---|---|
| **SQS Queue** | Sentinel polls this queue for events |
| **SQS Dead-Letter Queue** | Captures messages that fail processing (monitor for issues) |
| **IAM Role** | Cross-account role that Sentinel assumes — least-privilege SQS read-only |
| **KMS Key** (optional) | Customer-managed encryption for queue messages at rest |
| **EventBridge Rule** (optional) | Routes CloudTrail management events and sign-in events to the queue |
| **EventBridge Rule** (optional) | Routes EC2 Spot interruption warnings to the queue |
| **SNS Subscription** (optional) | Subscribes the queue to an existing CloudTrail SNS topic |

## Prerequisites

- Terraform >= 1.5
- AWS CLI configured with credentials for the target account
- Your Sentinel account ID (provided by your Sentinel admin)

## Quick start

```bash
cd scripts/aws-setup

# 1. Configure
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values

# 2. Deploy
terraform init
terraform plan
terraform apply

# 3. Copy outputs into Sentinel
terraform output sentinel_integration_config
```

The `sentinel_integration_config` output is a JSON object you can paste directly into Sentinel's AWS integration form, or use with the API:

```bash
curl -X POST https://your-sentinel/api/modules/aws/integrations \
  -H "Cookie: $SESSION" \
  -H "Content-Type: application/json" \
  -d "$(terraform output -json sentinel_integration_config | jq '. + {name: "production"}')"
```

## Event delivery patterns

### Pattern A: EventBridge (recommended)

```
CloudTrail ──> EventBridge Rule ──> SQS Queue ──> Sentinel
```

Set `enable_eventbridge_rule = true` (default). This captures management events and console sign-in events. Customize the pattern with `eventbridge_event_pattern`.

### Pattern B: Existing SNS topic

```
CloudTrail ──> S3 ──> SNS Topic ──> SQS Queue ──> Sentinel
```

Set `enable_eventbridge_rule = false` and provide `cloudtrail_sns_topic_arn`. Use this if you already have a CloudTrail trail publishing to SNS.

### Pattern C: Both

You can enable both EventBridge and SNS subscription if you want to capture events from multiple sources. The SQS queue accepts messages from both.

## Multi-account setup

For AWS Organizations with a centralized CloudTrail org trail:

```hcl
# In the management account — trail already sends to SNS
module "sentinel" {
  source = "./scripts/aws-setup"

  sentinel_account_id      = "111111111111"
  external_id              = "sentinel:org:your-org-id"
  name_prefix              = "sentinel-org"
  cloudtrail_sns_topic_arn = "arn:aws:sns:us-east-1:222222222222:org-cloudtrail"
  enable_eventbridge_rule  = false
}
```

For per-account monitoring, run this module once in each account with a unique `name_prefix`.

## Security considerations

- **Least privilege**: the IAM role only has `sqs:ReceiveMessage`, `sqs:DeleteMessage`, `sqs:GetQueueAttributes`, `sqs:GetQueueUrl`, and optionally `kms:Decrypt`. No write access to any AWS service.
- **External ID**: use `external_id` to prevent [confused deputy attacks](https://docs.aws.amazon.com/IAM/latest/UserGuide/confused-deputy.html). Sentinel generates this value during setup.
- **Encryption**: SQS messages are encrypted at rest using either a customer-managed KMS key (default) or AWS-managed SSE-SQS.
- **DLQ**: messages that fail processing 5 times are moved to the dead-letter queue with 14-day retention for forensic review.
- **Session duration**: the IAM role limits sessions to 1 hour. Sentinel automatically renews.

## Inputs

| Name | Description | Type | Default | Required |
|---|---|---|---|---|
| `sentinel_account_id` | AWS account ID where Sentinel is hosted | `string` | — | yes |
| `sentinel_role_name` | IAM role name in the Sentinel account | `string` | `"SentinelService"` | no |
| `name_prefix` | Prefix for resource names | `string` | `"sentinel"` | no |
| `tags` | Additional tags for all resources | `map(string)` | `{}` | no |
| `enable_eventbridge_rule` | Create EventBridge rule for CloudTrail events | `bool` | `true` | no |
| `eventbridge_event_pattern` | Custom EventBridge event pattern (JSON) | `string` | `null` | no |
| `enable_spot_interruption_rule` | Create rule for EC2 Spot interruption warnings | `bool` | `false` | no |
| `sqs_message_retention_seconds` | Message retention period | `number` | `345600` (4d) | no |
| `sqs_visibility_timeout_seconds` | Message visibility timeout | `number` | `120` | no |
| `create_kms_key` | Create a dedicated KMS key for SQS | `bool` | `true` | no |
| `kms_key_arn` | ARN of an existing KMS key (when `create_kms_key = false`) | `string` | `null` | no |
| `external_id` | External ID for assume-role trust policy | `string` | `""` | no |
| `cloudtrail_sns_topic_arn` | ARN of existing CloudTrail SNS topic | `string` | `null` | no |

## Outputs

| Name | Description |
|---|---|
| `sqs_queue_url` | SQS queue URL for Sentinel |
| `sqs_queue_arn` | SQS queue ARN |
| `sqs_region` | AWS region |
| `role_arn` | IAM role ARN for Sentinel |
| `account_id` | This AWS account ID |
| `kms_key_arn` | KMS key ARN (if created) |
| `dlq_url` | Dead-letter queue URL |
| `sentinel_integration_config` | JSON config block for Sentinel's integration API |

## Destroying

```bash
terraform destroy
```

This removes all AWS resources created by this module. It does **not** affect your CloudTrail trail, S3 bucket, or SNS topic. After destroying, disable the integration in Sentinel to stop poll attempts.
