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
| **EventBridge Rule — us-east-1** (auto) | Forwards global events (IAM, STS, sign-in) to the primary region |
| **EventBridge Rule** (optional) | Routes EC2 Spot interruption warnings to the queue |
| **SNS Subscription** (optional) | Subscribes the queue to an existing CloudTrail SNS topic |

## Prerequisites

- Terraform >= 1.5
- AWS CLI configured with credentials for the target account
- Your Sentinel account ID (provided by your Sentinel admin)
- If deploying outside us-east-1, your Terraform config must define an `aws.us_east_1` provider alias (see Quick start)

## Quick start

### Step 1 — Start the integration in Sentinel

1. Open Sentinel and go to **AWS Integrations > New Integration**
2. Enter your integration name and AWS account ID
3. Sentinel generates a unique **external ID** — copy it

### Step 2 — Copy the external ID and run Terraform

```bash
cd aws

# Configure
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars:
#   - Set ca_sentinel_account_id
#   - Paste the external_id from Step 1
```

If your primary region is **not** us-east-1, add a provider alias so global events (IAM, STS, console sign-in) are forwarded automatically:

```hcl
# providers.tf
provider "aws" {
  region = "eu-west-1"  # your primary region
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}
```

If your primary region **is** us-east-1, the alias is still required but no forwarding resources are created:

```hcl
provider "aws" {
  region = "us-east-1"
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}
```

```bash
# Deploy
terraform init
terraform plan
terraform apply
```

### Step 3 — Paste Terraform outputs into Sentinel

```bash
terraform output
```

Copy the `role_arn`, `sqs_queue_url`, and `sqs_region` values back into the Sentinel integration setup screen, then click **Finalize** to activate the integration.

You can also use the JSON config output with the API:

```bash
curl -X PATCH https://your-ca_sentinel/api/modules/aws/integrations/YOUR_INTEGRATION_ID \
  -H "Cookie: $SESSION" \
  -H "Content-Type: application/json" \
  -d "$(terraform output -json ca_sentinel_integration_config | jq '. + {name: "production"}')"
```

## Event delivery patterns

### Pattern A: EventBridge (recommended)

```
CloudTrail ──> EventBridge Rule ──> SQS Queue ──> Sentinel
```

Set `enable_eventbridge_rule = true` (default). This captures management events and console sign-in events in the primary region. Customize the pattern with `eventbridge_event_pattern`.

**Global events:** IAM, STS, and console sign-in events only appear in us-east-1. When your primary region is different, the module automatically deploys a second EventBridge rule in us-east-1 that forwards these events to the primary region's event bus (bus-to-bus), where they're routed to the SQS queue. This is controlled by `enable_global_event_forwarding` (default: `true`).

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
module "ca_sentinel" {
  source = "./aws"

  ca_sentinel_account_id      = "111111111111"
  external_id              = "ca_sentinel:your-org-id:abc123..."  # from Sentinel UI
  name_prefix              = "ca_sentinel-org"
  cloudtrail_sns_topic_arn = "arn:aws:sns:us-east-1:222222222222:org-cloudtrail"
  enable_eventbridge_rule  = false
}
```

For per-account monitoring, run this module once in each account with a unique `name_prefix`.

## External ID rotation

If you rotate the external ID in Sentinel (via the **Rotate External ID** button), the integration enters a `needs_update` state. You must update the `external_id` in your `terraform.tfvars` with the new value and run `terraform apply` to update the IAM trust policy, then acknowledge the rotation in Sentinel.

## Security considerations

- **Least privilege**: the IAM role only has `sqs:ReceiveMessage`, `sqs:DeleteMessage`, `sqs:GetQueueAttributes`, `sqs:GetQueueUrl`, and optionally `kms:Decrypt`. No write access to any AWS service.
- **External ID**: always required to prevent [confused deputy attacks](https://docs.aws.amazon.com/IAM/latest/UserGuide/confused-deputy.html). Sentinel generates this value during setup — you cannot supply your own.
- **Encryption**: SQS messages are encrypted at rest using either a customer-managed KMS key (default) or AWS-managed SSE-SQS.
- **DLQ**: messages that fail processing 5 times are moved to the dead-letter queue with 14-day retention for forensic review.
- **Session duration**: the IAM role limits sessions to 1 hour. Sentinel automatically renews.

## Inputs

| Name | Description | Type | Default | Required |
|---|---|---|---|---|
| `ca_sentinel_account_id` | AWS account ID where Sentinel is hosted | `string` | — | yes |
| `external_id` | External ID from Sentinel's setup screen (must start with `ca_sentinel:`) | `string` | — | yes |
| `ca_sentinel_role_name` | IAM role name in the Sentinel account | `string` | `"CASentinelServiceRole"` | no |
| `name_prefix` | Prefix for resource names | `string` | `"ca_sentinel"` | no |
| `tags` | Additional tags for all resources | `map(string)` | `{}` | no |
| `enable_eventbridge_rule` | Create EventBridge rule for CloudTrail events | `bool` | `true` | no |
| `eventbridge_event_pattern` | Custom EventBridge event pattern (JSON) | `string` | `null` | no |
| `enable_spot_interruption_rule` | Create rule for EC2 Spot interruption warnings | `bool` | `false` | no |
| `enable_global_event_forwarding` | Forward IAM/STS/sign-in events from us-east-1 to primary region | `bool` | `true` | no |
| `sqs_message_retention_seconds` | Message retention period | `number` | `345600` (4d) | no |
| `sqs_visibility_timeout_seconds` | Message visibility timeout | `number` | `120` | no |
| `create_kms_key` | Create a dedicated KMS key for SQS | `bool` | `true` | no |
| `kms_key_arn` | ARN of an existing KMS key (when `create_kms_key = false`) | `string` | `null` | no |
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
| `ca_sentinel_integration_config` | JSON config block for Sentinel's integration API |

## Destroying

```bash
terraform destroy
```

This removes all AWS resources created by this module. It does **not** affect your CloudTrail trail, S3 bucket, or SNS topic. After destroying, disable the integration in Sentinel to stop poll attempts.
