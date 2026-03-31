# Sentinel Setup Scripts

Infrastructure-as-code modules for connecting external services to [Sentinel](https://github.com/your-org/ca_sentinel), the security monitoring platform.

Each directory is a self-contained setup module that provisions the resources Sentinel needs in your cloud account. Run them before creating the corresponding integration in the Sentinel UI.

## Available modules

| Module | Cloud | Tool | Description |
|---|---|---|---|
| [`aws`](./aws) | AWS | Terraform | SQS queue, IAM role, EventBridge rules, KMS encryption for CloudTrail event ingestion |

## Usage

### As a Terraform module source

```hcl
module "ca_sentinel_aws" {
  source = "github.com/your-org/ca_sentinel-setup//aws?ref=v1.0.0"

  ca_sentinel_account_id = "123456789012"
  external_id         = "ca_sentinel:org:your-org-id"
}
```

### Standalone

```bash
git clone https://github.com/your-org/sentinel-setup.git
cd ca_sentinel-setup/aws
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars
terraform init && terraform apply
```

After `apply`, copy the outputs into Sentinel's integration form.

## Adding a new module

1. Create a directory named after the integration (e.g. `gcp/`, `azure/`, `cloudflare/`)
2. Include at minimum: the IaC files, a `README.md` with inputs/outputs, and an example config
3. Add an entry to `modules.json` so the Sentinel web app can discover it
4. Tag a release

## Versioning

This repo uses git tags (`v1.0.0`, `v1.1.0`, etc.). Pin to a specific tag in your Terraform `source` to avoid unexpected changes. Each module follows the same version — if a release only changes `aws/`, other modules are unaffected.

## License

MIT
