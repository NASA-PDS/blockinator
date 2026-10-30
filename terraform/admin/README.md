# Blockinator Infrastructure — Admin Stage

**⚠️ System administrators only.** This stage requires elevated ("super user") AWS access — typically the PDS "Project Admin" role — because it creates IAM roles and policies and WAFv2 resources. It is applied **once per venue** to set up the environment; after that, platform engineers deploy and update everything else from the parent [`terraform/`](../README.md) directory using ordinary (e.g. "Power User") access.

## What this stage creates

| Resource | Purpose |
|----------|---------|
| IAM role `*-pds-ip-blocklist-updater` | Lambda execution role; **only** identity allowed to call `wafv2:UpdateIPSet` |
| IAM role `*-pds-ip-blocklist-sweeper` | Lambda execution role for TTL expiry (DynamoDB query/update + SQS send) |
| IAM role `*-pds-ip-blocklist-audit` | Lambda execution role for DynamoDB-stream audit logging |
| IAM managed policy `*-pds-ip-blocklist-operator` | Attach to humans/automation that run `pds-blockinator` (no `wafv2:*`) |
| IAM role `*-pds-ip-blocklist-deployer` | Assumed by platform engineers so the platform stage can create the Lambdas, which requires `iam:PassRole` on their execution roles. Trust is limited to the SSO role(s) matching `deployer_sso_role_name_regex` (default: `Project-Power-User`), named by exact ARN; permissions are limited to passing the three execution roles to Lambda and managing this component's functions. Because the deployer can deploy the updater Lambda, anyone who can assume it can, in effect, change these IP sets |
| WAFv2 IP sets (IPv4 + IPv6, `CLOUDFRONT` scope, `us-east-1`) | Enforcement lists; attached to the existing Web ACL **once**, manually |

The DynamoDB table, SQS queues, Lambdas, and log groups these IAM policies grant access to are created *later* by the platform stage. Their ARNs are constructed in `locals.tf` from the shared `<venue>-pds-ip-blocklist` naming convention, so **resource names must never drift** between the two stages.

## Deployment (run once per venue)

Deployment goes through **Terragrunt** in the `cds-infra-deploy` repository, which supplies the S3 backend, the state key, and all inputs (venue, tags). From a clone of that repository:

```bash
cd cds-infra-deploy/venues/dev/blockinator/admin   # Or substitute test/prod
terragrunt init
terragrunt plan
terragrunt apply
```

The leaf's path (`venues/<venue>/blockinator/admin`) automatically yields state key `blockinator/admin.tfstate` — **separate from the platform stage's** `blockinator/terraform.tfstate`, so the two stages never collide. Note that Terragrunt fetches this module from GitHub by ref (see `module_ref` in the venue's `blockinator.hcl`), so local changes here must be pushed to that ref before `terragrunt plan` will see them.

After applying, perform the one-time Web ACL attach described in [the main README](../README.md#one-time-waf-attach-system-administrators--waf-owners-only), then tell the platform engineers the venue is ready.

### Without Terragrunt (plain Terraform, e.g. for development)

`backend.tf` declares an *empty* `backend "s3" {}`, so every backend setting must be supplied at init time via `-backend-config`. That option can be repeated, and each occurrence is either a **file** of `KEY = VALUE` pairs or a single **inline** `KEY=VALUE`; Terraform merges them all. So:

```bash
cd terraform/admin
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars (venue)
terraform init \
  -backend-config=/path/to/venue-backend.hcl \      # file: bucket, region, lock table
  -backend-config='key=blockinator/admin.tfstate'   # inline: the state key for THIS stage
terraform plan
terraform apply
```

The venue backend file holds the per-venue settings (for dev: `bucket = "pds-dev-infra"`, `region = "us-west-2"`, `dynamodb_table = "pds-infra-tg-locks"`) and is not committed to this repository — take the values from `cds-infra-deploy` (`root.hcl` plus the venue's `venue.hcl`). The inline `key=` sets the one value that file doesn't: the state key, which **must** be `blockinator/admin.tfstate` so you don't clobber the platform stage's state.

## Re-running

"Run once" refers to the setup workflow, not a technical limitation: re-applying is safe and is the correct way to roll out future IAM/WAF changes. The IP sets carry `lifecycle { ignore_changes = [addresses] }`, so a re-apply will not wipe blocks the updater Lambda has written.

## Migrating a venue deployed from the old single stack

For venues (e.g. dev) deployed before this split, the IAM and WAF resources already exist in the *platform* state. Move them without destroying anything:

1. In `terraform/` (platform), remove them from state:

   ```bash
   terraform state rm \
     aws_iam_role.updater aws_iam_role.sweeper aws_iam_role.audit \
     aws_iam_role_policy.updater aws_iam_role_policy.sweeper aws_iam_role_policy.audit \
     aws_iam_policy.operator \
     aws_wafv2_ip_set.ipv4 aws_wafv2_ip_set.ipv6
   ```

2. In `terraform/admin/`, import them (substitute the venue prefix, account ID, and the IP set IDs from `aws wafv2 list-ip-sets --scope CLOUDFRONT --region us-east-1`):

   ```bash
   P=pdc-cds-dev-pds-ip-blocklist
   terraform import aws_iam_role.updater "$P-updater"
   terraform import aws_iam_role.sweeper "$P-sweeper"
   terraform import aws_iam_role.audit "$P-audit"
   terraform import aws_iam_role_policy.updater "$P-updater:updater"
   terraform import aws_iam_role_policy.sweeper "$P-sweeper:sweeper"
   terraform import aws_iam_role_policy.audit "$P-audit:audit"
   terraform import aws_iam_policy.operator "arn:aws:iam::<ACCOUNT_ID>:policy/$P-operator"
   terraform import aws_wafv2_ip_set.ipv4 "<IPV4_SET_ID>/$P-ipv4/CLOUDFRONT"
   terraform import aws_wafv2_ip_set.ipv6 "<IPV6_SET_ID>/$P-ipv6/CLOUDFRONT"
   ```

3. Run `terraform plan` in both stages and confirm no destroys. (The admin plan may show in-place IAM policy updates — the Lambda-log and stream statements now use constructed/wildcarded ARNs — which is expected and harmless.)
