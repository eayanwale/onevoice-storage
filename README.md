# OneVoice Storage

Self-hosted Nextcloud on AWS, replacing a shared personal Dropbox for the OneVoice gospel/choir group. Deployed with Terraform (infra) and Packer (golden AMI), applied manually/locally — no CI/CD.

## Why this exists

OneVoice is a gospel/choir group, and for a while all of the group's shared files — recordings, sheet music, event media, admin docs — lived in one member's personal Dropbox account. That meant one personal login shared around the group (or worse, credentials passed along informally), no real way to control who had access to what, and no accountability if something got deleted or someone left. It worked, in the sense that files existed somewhere, but it was never actually *ours* — the group's storage was one person's liability. It was unsecure and honestly kind of hectic to manage.

The fix was to give OneVoice its own storage, under its own AWS account, that isn't tied to any one person's personal credentials. That meant picking a self-hosted platform and standing up the infrastructure to run it.

**Why Nextcloud:** the shortlist was Nextcloud, ownCloud, and Syncthing. Syncthing was ruled out first — it's peer-to-peer sync between devices, not a central server with accounts/permissions, which isn't what a group with rotating membership needs. ownCloud (which Nextcloud actually forked from) was closer, but Nextcloud has the more active open-source community, faster feature/security cadence, and a friendlier admin/theming experience. Between free, open-source, self-hostable options, it was the clear pick.

## Design decisions

### Why S3 for storage

Nextcloud's data has to live *somewhere*, and the obvious naive option is just a big EBS volume attached to the EC2 instance. That's what the app server's own disk is for (OS, PHP, Nextcloud code) — but user files are a different story:

- **The instance becomes disposable.** If storage lived on the instance's own disk, replacing that instance (AMI rebake, instance type change, disaster recovery) would mean also migrating potentially tens of GB of member files. With S3 as the object store, the EC2 instance is just compute — it can be terminated and relaunched from the golden AMI without touching a single file.
- **Durability without babysitting a disk.** S3 gives 11-nines durability and versioning out of the box; an EBS volume needs its own snapshot/backup story to get anywhere close, and even then it's tied to one AZ.
- **It doesn't need capacity planning.** No resizing a volume as the choir uploads more recordings over time.
- **Nextcloud supports it natively.** Nextcloud's `objectstore` primary-storage backend talks to S3 directly, and on AWS that means the EC2 instance's IAM role can authenticate via instance-profile credentials — no access keys to generate, rotate, or leak. That's the same "no personal credentials floating around" principle the whole project started from, just applied to the app's own AWS access instead of a Dropbox login.

The tradeoff: Nextcloud's S3 objectstore mode stores files under internal object keys (`urn:oid:...`), not human-readable paths. That's fine for the app's own storage, but it's exactly why the Dropbox migration data went into a **separate** bucket (see below) instead of being dropped directly into the primary bucket.

### Migrating the old files: rclone over `aws s3 cp`, scp, or rsync

Moving years of files out of the old shared Dropbox and up to AWS was a one-shot, can't-mess-it-up job — there's no "redo it" if something silently drops files halfway through a multi-hour transfer. A few tools could technically move files to S3: `aws s3 cp`/`sync`, or copying to the EC2 instance over `scp`/`rsync` and re-uploading from there. `rclone` won out for a few concrete reasons:

- **Parallel transfers.** rclone moves many files concurrently instead of one at a time, which matters a lot when the payload is thousands of small files (photos, PDFs, individual audio takes) rather than a few huge ones.
- **Home internet was actually fast enough to make that matter.** At ~2000 Mbps, the bottleneck wasn't bandwidth — it was making sure the transfer used it. A serial copy (plain `aws s3 cp` one file at a time, or `scp`/`rsync` into the instance and back out) would've left most of that bandwidth on the table.
- **Built-in checksumming and progress.** rclone verifies transfers and shows real progress/retry state, which matters when you need confidence that "done" actually means every file made it, not just that the command exited.
- **It talks to S3 (and Dropbox) natively.** No detour through the EC2 instance's own disk as a relay, unlike scp/rsync which assume a filesystem-to-filesystem hop.

The migration files land in a dedicated `onevoice-<env>-migration` S3 bucket (see `s3.tf`) — not the primary Nextcloud storage bucket, since Nextcloud's objectstore mode can't see directly-uploaded objects. That bucket is mounted into Nextcloud as **External Storage** (`occ files_external:create`, authenticated via a dedicated IAM user/access key since External Storage doesn't support instance-role auth the way the primary objectstore does) and indexed with `occ files:scan`. The migration is complete — see the [project plan](docs/nextcloud-project-plan.md) for current status.

## Architecture

```
VPC/IGW → EC2 (Packer-baked AMI) + IAM instance role → S3 (primary storage) + RDS MySQL
                                                       ↳ Elastic IP (DNS/TLS once a domain is acquired)
```

- **Storage:** Nextcloud's primary object storage is an S3 bucket, accessed via the EC2 instance's IAM role (no static keys). See [Why S3 for storage](#why-s3-for-storage).
- **Database:** RDS MySQL in private subnets, reachable only from the app server's security group.
- **Compute:** EC2 instance built from a Packer AMI (nginx, PHP 8.2, Nextcloud, certbot), configured on first boot via `user-data.sh` (idempotent — pulls secrets from SSM, runs `occ` install, sets up S3 object storage, theming, and initial user accounts).
- **Monitoring:** CloudWatch alarms (status check, CPU utilization, CPU credit balance, memory, disk) + an ops dashboard, alerting to email via SNS. See [Monitoring & ops](#monitoring--ops).
- **State backend:** S3 only, SSE-KMS + versioning + `use_lockfile` for native locking — no DynamoDB table.

See [docs/nextcloud-project-plan.md](docs/nextcloud-project-plan.md) for full phase-by-phase status and design decisions.

## Repo layout

```
infra/
└── bootstrap/           # random_password, SSM parameters, state bucket — applied once, rarely touched

onevoice-storage/
├── terraform/            # main stack — reads bootstrap state via data "terraform_remote_state"
│   ├── vpc.tf             # VPC, subnets, security groups, S3 gateway endpoint
│   ├── iam.tf             # EC2 role + S3/SSM access policies
│   ├── db.tf              # RDS MySQL
│   ├── s3.tf              # Primary storage bucket + branding asset
│   ├── compute.tf         # EC2 instance, key pair, EBS data volume, EIP
│   ├── data.tf             # remote state, AMI lookup, SSM lookups
│   ├── monitoring.tf       # CloudWatch alarms + SNS ops alerts
│   ├── security.tf         # CloudTrail, GuardDuty, Security Hub, finding alerts
│   ├── backup.tf           # DLM weekly EBS snapshot policy
│   ├── cost.tf             # monthly budget alarm
│   ├── scripts/user-data.sh  # first-boot Nextcloud install/config
│   └── keys/               # EC2 key pair — public half only, see Security below
└── packer/
    ├── nextcloud.pkr.hcl   # golden AMI template
    └── setup.sh            # AMI provisioning script
```

## Prerequisites

- Terraform >= 1.7.0, AWS provider ~> 5.0
- Packer with the `amazon` plugin
- An AWS CLI profile named `onevoice` with credentials for the target account

## Deploying

1. **Bootstrap** (once, rarely touched):
   ```
   cd infra/bootstrap
   terraform init && terraform apply
   ```
   Creates the Terraform state bucket and generates the DB/admin passwords in SSM.

2. **Golden AMI**:
   ```
   cd onevoice-storage/packer
   packer build nextcloud.pkr.hcl
   ```
   Bakes an AMI (`ami-nextcloud-*`) with nginx, PHP, Nextcloud, and certbot pre-installed.

3. **Main stack**:
   ```
   cd onevoice-storage/terraform
   terraform init && terraform apply
   ```
   Provisions the VPC, IAM role, RDS instance, S3 bucket, and EC2 instance. The instance runs `scripts/user-data.sh` on first boot to install and configure Nextcloud automatically. Check the `server_ip` output for the app's public address.

## Monitoring & ops

`monitoring.tf` wires up an SNS topic (`ops_alerts`, emailing the addresses in `var.ops_alert_emails`) and a set of CloudWatch alarms on the EC2 instance:

- **Status check failed** — instance/system health, `AWS/EC2` namespace
- **CPU credit balance low** — this is a `t`-family burstable instance, so a drained credit balance is an early warning before performance actually tanks
- **CPU utilization high** — sustained load above 80%
- **Memory / disk utilization high** — `mem_used_percent` / `disk_used_percent`, published under the `CWAgent` namespace, not `AWS/EC2`

All five feed a `nextcloud-ops` CloudWatch dashboard for at-a-glance status.

Memory and disk aren't metrics AWS publishes for EC2 by default — they require the CloudWatch agent running on the instance. The EC2 IAM role has `CloudWatchAgentServerPolicy` attached (`iam.tf`), and the agent itself is now installed, configured, and running, so the memory and disk alarms have real data behind them instead of relying on `treat_missing_data = "notBreaching"` to stay quiet.

The agent also ships `nginx` access/error logs and the Nextcloud app log to CloudWatch Logs (`onevoice-prod-nginx-access`, `onevoice-prod-nginx-error`, `onevoice-prod-nextcloud-app`, 30-day retention).

## Security & cost hardening

`security.tf`, `backup.tf`, and `cost.tf` add a second layer beyond the Phase 9 basics — written and validated, plan is clean, not yet applied:

- **CloudTrail** — multi-region trail with log file validation, writing to a dedicated, encrypted, non-public `onevoice-prod-cloudtrail-logs` bucket
- **GuardDuty** — threat detection, 15-minute finding frequency
- **Security Hub** — enabled with AWS Foundational Security Best Practices, auto-ingests GuardDuty findings
- **Finding alerts** — GuardDuty (severity ≥ 7) and Security Hub (CRITICAL/HIGH) findings route through EventBridge into the same `ops_alerts` SNS topic as the CloudWatch alarms
- **EBS snapshot automation** — a DLM policy takes weekly snapshots of the `nextcloud-data` volume (Sundays 03:00 UTC), retaining 4
- **S3 lifecycle rule** — the primary Nextcloud bucket transitions noncurrent object versions to Standard-IA after 30 days and expires them after 365
- **Budget alarm** — monthly cost budget (`var.monthly_budget_limit`), alerting at 80%/100% actual and 100% forecasted to the same ops emails

Two related items were done by hand instead, since they touch the live server directly: **nginx rate limiting** (`limit_req_zone`/`limit_req` in `conf.d/`, applied and verified over SSH — not yet folded into `packer/setup.sh`) and the **CloudWatch log shipping** config above. See the project plan's Phase 10 for the full rundown, including why the agent's real config path (`config.json`) differs from the commonly-assumed one.

## Security notes

- The EC2 key pair's **public** half (`keys/nextcloud-key.pub`) is meant to be the only committed artifact; the private key and any `.pem` files are excluded via `.gitignore`.
- DB and admin credentials are generated with `random_password` and stored in SSM (`SecureString`), never in Terraform variables or state-visible plaintext.
- SSH (22) is restricted to a single admin IP in `vpc.tf`; 80/443 are open for Nextcloud access until a domain + TLS (Phase 6) is in place.
- The primary Nextcloud storage bucket is accessed purely via the EC2 instance's IAM role — no access keys anywhere. The one exception is the migration bucket: Nextcloud's External Storage app doesn't support instance-role auth, so a dedicated IAM user with a scoped access key exists just for that mount (`aws_iam_user.nextcloud_migration_mount` in `iam.tf`).

## Status

Networking, IAM, database, golden AMI, compute, and ops basics (CloudWatch alarms across status/CPU/memory/disk + a dashboard + SNS email alerts + the CloudWatch agent itself, RDS scheduled snapshots) are deployed. Nextcloud app config (install, DB, S3 storage, theming, users) is automated via user-data. The Dropbox-to-S3 migration and onboarding docs for the group are done. nginx rate limiting and CloudWatch log shipping are live. CloudTrail, GuardDuty, Security Hub, EBS snapshot automation, S3 lifecycle rules, and the budget alarm are written in Terraform and validated but await `terraform apply`. Remaining open items: DNS/TLS (pending a domain), group folders automation, the DB hardening rollback decision, and the Nextcloud version pin. See the project plan doc for the full breakdown.
