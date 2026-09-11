# Blockinator Infrastructure

This folder contains the cloud infrastructure (AWS Terraform) to support the Blockinator, the operator-managed IP and CIDR blocklist for PDS CloudFront access. It requires Terraform 1.16.0 or later, but less than Terraform 2.0.0.

Please see the tracking issue for detailed specifications: [NASA-PDS/pdc-cds-infra#121](https://github.com/NASA-PDS/pdc-cds-infra/issues/121).


## What this component creates

| Resource | Purpose |
|----------|---------|
| DynamoDB table `*-pds-ip-blocklist-policies` | Source of truth (who / when / reason / TTL) |
| SQS FIFO queue `*-pds-ip-blocklist-mutations.fifo` | Serialized ADD/REMOVE bus (single `MessageGroupId`) |
| Lambda `*-updater` | **Only** identity that calls `wafv2:UpdateIPSet` (`reserved_concurrent_executions = 1`) |
| Lambda `*-sweeper` | Every minute, expire rows whose `expires_at` has passed and enqueue REMOVE |
| Lambda `*-audit` | Structured CloudWatch Logs from the DynamoDB stream |
| WAFv2 IP sets (IPv4 + IPv6, `CLOUDFRONT` scope, `us-east-1`) | Enforcement list attached to the existing Web ACL **once** |

This component does **not** modify the CloudFront Web ACL. CloudFront already consumes an external `waf_arn`. WAF owners must manually attach the IP sets (see below) as a one-time setup.


## Deployment

To deploy the infrastructure to support the IP blocklist, use Terraform as follows:
```bash
cd terraform/backend-configs
cp <venue>.hcl.example dev.hcl  # Or substitute test.hcl or prod.hcl
# Edit the new .hcl file copied from above
terraform init -backend-config=../dev.hcl  # Or substitute test.hcl or prod.hcl
terraform plan
terraform apply
```
Outputs are also published under SSM prefix `/pds/cds-infra/ip-blocklist/` (`table-name`, `queue-url`, `ipv4-ipset-arn`, `ipv6-ipset-arn`, `audit-log-group`).


## One-time WAF attach (WAF owners only)

After Terraform application, attach both IP sets to the existing CloudFront Web ACL **above** any future allowlist rule and **without** changing other rules as follows:

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
