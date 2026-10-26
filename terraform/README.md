# Blockinator Infrastructure

This folder contains the cloud infrastructure (AWS Terraform) to support the Blockinator, the operator-managed IP and CIDR blocklist for PDS CloudFront access. It requires Terraform 1.16.0 or later, but less than Terraform 2.0.0.

Please see the tracking issue for detailed specifications: [NASA-PDS/pdc-cds-infra#121](https://github.com/NASA-PDS/pdc-cds-infra/issues/121).


## Two stages: who runs what

The Terraform is split into **two independent stages with separate state**, based on the level of AWS access required:

| Stage | Directory | Who runs it | When | What it creates |
|-------|-----------|-------------|------|-----------------|
| **1. Admin** | [`admin/`](admin/) | **System administrators only** (elevated / "super user" access, e.g. PDS "Project Admin" role) | **Once** per venue, before anything else | IAM roles & policies, WAFv2 IP sets |
| **2. Platform** | this directory | **Any PDS platform engineer** (e.g. PDS "Power User" role) | As needed (new venues, Lambda code changes, config updates, etc.) | DynamoDB, SQS, Lambdas, log groups, schedules, SSM parameters |

The admin stage must be applied **first**: the platform stage looks up the IAM roles, operator policy, and IP sets by name (see `data.tf`) and fails with a clear "not found" error if they don't exist yet. After the one-time admin apply (plus the one-time manual Web ACL attach below), platform engineers never need elevated access again — day-to-day infrastructure changes all live in this stage.


## Stage 1 — Admin (system administrators, run once)

See [`admin/README.md`](admin/README.md) for full instructions. Summary, from a clone of the `cds-infra-deploy` repository:

```bash
cd cds-infra-deploy/venues/dev/blockinator/admin   # Or substitute test/prod
terragrunt init
terragrunt plan
terragrunt apply
```

The leaf's path gives this stage its own state key, `blockinator/admin.tfstate`, separate from the platform stage's `blockinator/terraform.tfstate`.

This creates, per venue:

| Resource | Purpose |
|----------|---------|
| IAM roles `*-updater`, `*-sweeper`, `*-audit` | Execution roles for the three Lambdas; **only** the updater role may call `wafv2:UpdateIPSet` |
| IAM managed policy `*-operator` | Attach to humans/automation that run `pds-blockinator` (DynamoDB + SQS + SSM read; no `wafv2:*`) |
| WAFv2 IP sets (IPv4 + IPv6, `CLOUDFRONT` scope, `us-east-1`) | Enforcement lists attached to the existing Web ACL **once** (manual step below) |

System administrators also perform the one-time Web ACL attach described at the bottom of this document.


## Stage 2 — Platform (platform engineers, run as needed)

### What this stage creates

| Resource | Purpose |
|----------|---------|
| DynamoDB table `*-pds-ip-blocklist-policies` | Source of truth (who / when / reason / TTL) |
| SQS FIFO queue `*-pds-ip-blocklist-mutations.fifo` | Serialized ADD/REMOVE bus (single `MessageGroupId`) |
| Lambda `*-updater` | **Only** identity that calls `wafv2:UpdateIPSet` (`reserved_concurrent_executions = 1`) |
| Lambda `*-sweeper` | Every minute, expire rows whose `expires_at` has passed and enqueue REMOVE |
| Lambda `*-audit` | Structured CloudWatch Logs from the DynamoDB stream |
| SSM parameters | Published discovery values for the CLI and WAF owners |

This stage does **not** create IAM or WAF resources (those belong to the admin stage), and it does not modify the CloudFront Web ACL.

### Deployment

Via Terragrunt, from a clone of the `cds-infra-deploy` repository:

```bash
cd cds-infra-deploy/venues/dev/blockinator/terraform   # Or substitute test/prod
terragrunt init
terragrunt plan
terragrunt apply
```

Or standalone with plain Terraform (e.g. for development), supplying the backend settings by hand — a `-backend-config` file for the venue's bucket/region/lock table plus the inline state key:

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars
terraform init \
  -backend-config=/path/to/venue-backend.hcl \
  -backend-config='key=blockinator/terraform.tfstate'
terraform plan
terraform apply
```

Outputs are also published under SSM prefix `/pds/cds-infra/ip-blocklist/` (`table-name`, `queue-url`, `ipv4-ipset-arn`, `ipv6-ipset-arn`, `audit-log-group`, `operator-policy-arn`).

If `terraform plan` fails with errors like *"no IAM role found matching criteria"* or *"WAFv2 IPSet not found"*, the admin stage has not been applied for this venue yet — ask a system administrator to run Stage 1 first.


## One-time WAF attach (system administrators / WAF owners only)

After both stages are applied, attach both IP sets to the existing CloudFront Web ACL **above** any future allowlist rule and **without** changing other rules as follows:

1.  Access the JPLOnlyWebACL in the AWS Console's WAF & Shield.
2.  Click "Manage Rules".
3.  Click Add Rule.
4.  Select "Custom Rule" then click Next.
5.  Choose "Custom Rule" on the next page and click Next.
6.  Enter as follows:
    -   Action: Block
    -   Rule name: "blockinator-ipv4"
    -   If a request: matches the statement
    -   Inspect: originates from an IP address in
    -   Statement: `pdc-cds-dev-pds-ip-blocklist-ipv4`
    -   Rule configuration: Source IP address
    -   Custom response
        -   Enable: ✓
        -   Response code: 403 (Forbidden)
        -   Response body: `Unusual traffic has been detected that looks like automated/bot activity. If you require access to this data, please contact the PDS Help Desk at pds-operator@jpl.nasa.gov.`
7. Click Add rule.

Repeat the above, but for the IPv6 version.

And if you ever need the Web ACL name/id and IP set ARNs from SSM:
```bash
aws ssm get-parameter --name /pds/cds-infra/ip-blocklist/ipv4-ipset-arn --query Parameter.Value --output text
aws ssm get-parameter --name /pds/cds-infra/ip-blocklist/ipv6-ipset-arn --query Parameter.Value --output text
```


## Enqueue contract (for #275 / #276)

Automated producers must **not** call `UpdateIPSet`. They write the same table and FIFO queue the CLI uses:

DynamoDB item:

- `cidr` (S, PK, canonical CIDR)
- `action` (S) `BLOCK` (`ALLOW` reserved for #277)
- `reason` (S)
- `added_by` (S) e.g. `cloudwatch-alarm:<name>`
- `added_at` (S, ISO-8601)
- `expires_at` (N, epoch seconds; omit for no expiry)
- `source` (S) `AUTOMATED`
- `status` (S) `ACTIVE`

SQS message (`MessageGroupId` = `ipset`):

```json
{"op": "ADD", "cidr": "203.0.113.10/32", "request_id": "<uuid>"}
```

`op` is `ADD` or `REMOVE`.

CloudFront JSON logs today land in **S3** via Logs Delivery, not a CloudWatch Logs group. Metric filters for auto-block (#275) need a Logs destination; do not assume they work against the S3 delivery as-is.
