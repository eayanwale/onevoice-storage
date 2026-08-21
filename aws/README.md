# AWS deployment target

Nextcloud on EC2 + RDS + S3, built with Terraform and a Packer golden AMI. Live at **`onevoice.knoch.dev`**, and currently the authoritative copy of the group's data.

For *why* this shape — S3 over EBS, a single EC2 instance over containers/K8s/serverless, rclone for the Dropbox migration — see the [root README](../README.md#design-decisions). This document is the operational one.

The other deployment target is [`bluehost/`](../bluehost/README.md). Nothing here depends on it.

A diagram of this stack — VPC, subnets, the four managed-service relationships and the account-wide pieces — is in [`docs/architecture.md`](../docs/architecture.md).

## Layout

```
terraform/           # main stack — reads bootstrap state via terraform_remote_state
├── vpc.tf            # VPC, subnets, security groups, S3 gateway endpoint
├── iam.tf            # EC2 instance role + S3/SSM policies, migration-mount IAM user
├── db.tf             # RDS MySQL
├── s3.tf             # primary + migration buckets, Object Lock, lifecycle, branding
├── compute.tf        # EC2 instance, key pair
├── data.tf           # remote state, AMI lookup, SSM lookups
├── monitoring.tf     # CloudWatch alarms + SNS ops alerts
├── security.tf       # CloudTrail + VPC Flow Logs
├── cost.tf           # monthly budget alarm
├── scripts/user-data.sh   # first-boot install/config
└── keys/             # EC2 key pair — public half only

packer/
├── nextcloud.pkr.hcl # golden AMI template
├── setup.sh          # AMI provisioning
└── files/            # units + configs baked in (#41, #42, #43)
```

`infra/bootstrap/` lives at the repo root, not here — it is applied once and creates the state bucket that this stack's backend depends on, so it cannot live inside the stack it bootstraps.

## Deploying

**Prerequisites:** Terraform >= 1.7.0 (AWS provider ~> 5.0), Packer with the `amazon` plugin, and an AWS CLI profile named `onevoice`.

```bash
# 1. Bootstrap — once, rarely touched
cd infra/bootstrap && terraform init && terraform apply

# 2. Golden AMI
cd aws/packer && packer build nextcloud.pkr.hcl

# 3. Main stack
cd aws/terraform && terraform init && terraform apply
```

The full procedure, including workspace/environment isolation, is in [`docs/deployment-runbook.md`](../docs/deployment-runbook.md).

## Do not change the backend keys

```hcl
# terraform/versions.tf
key = "onevoice-storage/terraform.tfstate"

# terraform/data.tf
key = "infra/bootstrap/terraform.tfstate"
```

These are paths inside the S3 **state bucket**, not paths in this repo. They kept the name `onevoice-storage` after the directory was renamed to `aws/`, so they look like stale references — they are not. Rewriting either one orphans the existing state and makes Terraform plan to recreate the entire stack.

## Secrets

Nothing sensitive is in Terraform variables or committed files. `user-data.sh` pulls eight SecureString parameters from SSM at first boot:

| Parameter | For |
|---|---|
| `nextcloud/db-password`, `nextcloud/admin-password` | Nextcloud install |
| `cloudflared/tunnel-token` | tunnel ingress |
| `nextcloud-mcp/username`, `nextcloud-mcp/app-password` | MCP server |
| `maintenance/github-pat` | maintenance automation |
| `nextcloud/migration-bucket/{access-key-id,secret-access-key}` | External Storage mount |

Terraform only grants **read** access to most of these. The tunnel token, MCP credentials and GitHub PAT are created out-of-band — Terraform cannot generate a Cloudflare token or a GitHub PAT — so **they must exist in SSM before any instance using this `user-data.sh` launches**, or first-boot provisioning fails partway.

Storage auth splits two ways, deliberately: the **primary** bucket is reached via the instance's IAM role with no static keys, but Nextcloud's External Storage app doesn't support instance-role auth, so the **migration** bucket has a dedicated scoped IAM user (`aws_iam_user.nextcloud_migration_mount`).

## Operational gotchas

These have each cost real time. All are documented at length in the [project plan's Known Issues log](../docs/nextcloud-project-plan.md).

**Replacing only the instance is not a clean install.** `terraform apply -replace="aws_instance.nextcloud-server"` leaves RDS untouched, so the new instance's `occ maintenance:install` collides with the existing database ("The Login is already being used") and `set -e` kills the rest of first-boot provisioning right there. For a genuinely clean test, destroy and re-apply the whole stack.

**A fresh instance plus an old browser session produces `HMAC does not match` log spam.** Harmless — the cookie is encrypted under the previous instance's now-gone secret. Use a private window.

**`terraform destroy` will fail on the primary bucket** if it holds objects, and now also because Object Lock is enabled. Safe to ignore and re-run `apply`; the old contents become orphaned rather than cleaned up.

**Trashbin is disabled instance-wide.** Deletes on S3-backed storage crash its move-to-trash step (#28), so there is no undo anywhere on the instance.

**`user-data.sh` is a Terraform `templatefile()`.** Bash variables must be escaped `$${VAR}` or Terraform tries to interpolate them — `${!NEW_USERS[@]}` in particular. Only the real template variables use single `${...}`.

## Monitoring

`monitoring.tf` creates an SNS topic (`ops_alerts`) and CloudWatch alarms on status check, CPU utilization, CPU credit balance, memory and disk, all feeding a `nextcloud-ops` dashboard.

Memory and disk are **not** published by EC2 by default — they come from the CloudWatch agent, under the `CWAgent` namespace rather than `AWS/EC2`. The agent also ships nginx access/error logs and the Nextcloud app log with 30-day retention.

The agent's config is still applied by hand, and its real path is `/opt/aws/amazon-cloudwatch-agent/etc/config.json` — *not* the commonly-cited `amazon-cloudwatch-agent.json`, which does not exist on this instance.

## Cost

Roughly **$53-55/mo**, itemised in the [root README](../README.md#cost). Two things worth knowing:

The instance moved `t3.small` → `t3.medium` after the OOM killer began terminating `php-fpm` workers. That is about +$15/mo and puts spend **above** the $35 budget alarm, so the alarm will fire monthly until either it or the instance size is revisited.

`aws_ebs_volume.nextcloud-data` (40 GB) is provisioned but never attached or mounted — ~$4/mo for nothing. Left in place deliberately; see the project plan's Deferred Decisions log.

## Known parity gaps with `bluehost/`

Fixes developed on the Bluehost host and back-ported here in #58 — but **not yet exercised by a real `packer build`**:

- `.well-known/{carddav,caldav}` redirects, absent so DAV clients cannot autodiscover
- `PATH_INFO` never forwarded to fastcgi
- `.mjs` served as `application/octet-stream`, a hard `occ setupchecks` failure
- the theming logo written inside the Nextcloud root, failing `integrity:check-core` with `EXTRA_FILE`

Still **not** fixed here: camera RAW files download instead of opening. The two patches that fix it were applied by hand to this instance in July and are scripted only on the Bluehost side. See [`bluehost/README.md`](../bluehost/README.md).
