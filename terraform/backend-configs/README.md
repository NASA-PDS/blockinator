# EC2: Backend Configurations

These files tell Terraform where to keep state for the **EC2** stack. EFS and snapshots have their own folders with their own keys. Mixing them up is how two stacks try to share a brain. Please do not.

    terraform init -reconfigure -backend-config=backend-configs/dev.hcl


## What's here

| File | Venue |
|:-----|:------|
| `dev.hcl` | Development (`pds-dev-infra`, key `blockinator/terraform.tfstate`) |
| `test.hcl` | Testing (`pds-infra-test`, key `blockinator/terraform.tfstate`) |
| `prod.hcl` | Production (`pds-prod-infra`, key `blockinator/terraform.tfstate`) |
| `<venue>.hcl.example` | Blank template for a new venue |

Each file sets `bucket`, `key`, and `region` for the empty `backend "s3" {}` in `../backend.tf`. If you already initialized against another venue, use `-reconfigure`. That avoids a well-meaning but disastrous attempt to copy state between buckets.
