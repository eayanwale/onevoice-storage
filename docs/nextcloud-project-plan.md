# OneVoice Nextcloud Migration — Project Plan

**Project:** Self-hosted Nextcloud on AWS EC2, replacing shared personal Dropbox for the OneVoice gospel/choir group
**Org variable:** `onevoice`
**Deployment tooling:** Terraform (infra) + Packer (golden AMI), applied manually/locally
**Naming convention:** `${var.organization}-${var.environment}-<resource>`

**Background:** the group's files used to live in one member's personal Dropbox — one shared login, no access control, no accountability. This project gives OneVoice its own storage under its own AWS account. See the [README](../README.md#why-this-exists) for the full story and the reasoning behind Nextcloud vs. ownCloud/Syncthing, S3 vs. instance-local storage, and rclone vs. `aws s3 cp`/scp/rsync for the migration — this doc stays focused on phase-by-phase technical status.

---

## Architecture Summary

VPC/IGW → EC2 (launched from Packer-baked AMI) + IAM instance role → S3 bucket (primary file storage) + RDS MySQL (app database), fronted by an Elastic IP. DNS/TLS layered on once a domain is acquired. Terraform and Packer are run manually/locally rather than through a CI/CD pipeline.

**Actual layout differs from the original phase-split plan below** — the main stack ended up flat under `onevoice-storage/terraform/` instead of a `networking.tf`/`iam.tf`/`database.tf`/`compute.tf` split inside `infra/main/`. Bootstrap stayed put and is read via `data "terraform_remote_state"`:

```
infra/
└── bootstrap/       # random_password, SSM parameters, state bucket — applied once, rarely touched
    ├── versions.tf
    ├── main.tf
    └── outputs.tf

onevoice-storage/
├── terraform/        # everything else — reads bootstrap state via data "terraform_remote_state"
│   ├── provider.tf / versions.tf / vars.tf
│   ├── vpc.tf           # Phase 1
│   ├── iam.tf           # Phase 2
│   ├── db.tf            # Phase 3
│   ├── s3.tf            # Phase 3 (storage) + branding asset upload
│   ├── data.tf          # remote state, AMI lookup, SSM lookups
│   ├── compute.tf       # Phase 5
│   ├── monitoring.tf    # Phase 9 — CloudWatch alarms + SNS ops alerts
│   ├── security.tf      # Phase 10 — CloudTrail, GuardDuty, Security Hub, finding alerts
│   ├── backup.tf        # Phase 10 — DLM weekly EBS snapshot policy
│   ├── cost.tf          # Phase 10 — monthly budget alarm
│   ├── scripts/user-data.sh  # Phase 7, runs on first boot
│   ├── keys/            # EC2 key pair (public half only committed)
│   ├── assets/logo.png  # OneVoice branding asset, pushed to S3
│   └── outputs.tf
└── packer/
    ├── nextcloud.pkr.hcl # Phase 4
    └── setup.sh
```

State backend: S3 only (SSE-KMS, versioning enabled, `use_lockfile = true` for native S3 locking) — no DynamoDB lock table.

---

## Phase Status

| Phase | Description | Status |
|---|---|---|
| Bootstrap | Password generation, SSM parameter, state bucket | ✅ Done |
| 1 — Networking | VPC, IGW, subnets, security groups, EIP, S3 gateway endpoint | ✅ Done |
| 2 — IAM | EC2 role, S3 access policy, instance profile | ✅ Done |
| 3 — Database | RDS MySQL, subnet group, security group, SSM-sourced password | ✅ Done |
| 4 — Golden AMI | Packer template + provisioner script (nginx, PHP 8.2, Nextcloud, certbot) | ✅ Done |
| 5 — Compute | EC2 instance, key pair, EBS volume, EIP association | ✅ Deployed — instance live, `server_ip` output wired up |
| 6 — DNS & TLS | Route53 record, certbot cert | ⏸️ Deferred — no domain yet |
| 7 — Nextcloud app config | Automated install, DB connection, S3 primary storage, theming, users, group folders | 🔄 In progress — install/DB/S3/theming/users automated; groups still to do |
| 9 — Ops basics | CloudWatch alarms (status/CPU/memory/disk) + dashboard, RDS scheduled snapshots, CloudWatch agent, onboarding docs | ✅ Done |
| 10 — Security & cost hardening | CloudTrail, GuardDuty, Security Hub, EBS snapshot automation, S3 lifecycle rules, budget alarm, nginx rate limiting, CloudWatch log shipping | ✅ Applied 2026-07-17 — then GuardDuty + Security Hub **removed** 2026-07-18 after a cost review; CloudTrail/DLM/S3 lifecycle/budget alarm remain live. Removal plan is clean (7 to destroy, 0 to add/change); `terraform apply` for the removal not yet run |
| — Cost review | Bottom-up cost audit against actual Cost Explorer data and live AWS resource state | ✅ Done 2026-07-18 — see [Cost Review](#cost-review-2026-07-18) below |

> **Open decision:** DB `skip_final_snapshot`/`deletion_protection` loosened to `true`/`false` for iteration. See [Deferred / Open Decisions Log](#deferred--open-decisions-log).
>
> Ops alarms, the dashboard, and the CloudWatch agent are all live — memory/disk metrics now have real data behind them. The Dropbox-to-S3 migration and onboarding docs are also done. Remaining open items are tracked in the [Deferred / Open Decisions Log](#deferred--open-decisions-log): domain/DNS, group folders, DB hardening rollback, the Nextcloud version pin, the unattached EBS data volume, the GuardDuty/Security Hub removal apply, and 2026-07-17's inconclusive php-fpm outage.

---

## Phase Details

### Phase 1 — Networking ✅
- VPC with public subnet (non-overlapping CIDR)
- Internet Gateway + route table
- Security group: 443/80 open, 22 restricted to admin IP
- Elastic IP allocated
- S3 gateway endpoint

### Phase 2 — IAM ✅
- IAM role for EC2 scoped to the Nextcloud S3 bucket (Get/Put/Delete/List)
- Instance profile attaching the role

### Phase 3 — Database ✅
- RDS MySQL instance
- DB subnet group (private subnets)
- Security group: 3306 inbound restricted to EC2 SG only
- Password read via `data "aws_ssm_parameter"` from bootstrap — main stack never owns the secret
- Outputs: RDS endpoint for downstream use in Phase 7

### Phase 4 — Golden AMI ✅
- Base: Amazon Linux 2023 (`al2023-ami-*-x86_64`), selected via `data "aws_ami"`
- Packer builds an EBS-backed AMI, shared to specified accounts/regions
- Provisioner installs: nginx, PHP 8.2 (+ gd, mbstring, xml, curl, zip, intl, mysqlnd, bcmath, gmp, opcache), Nextcloud (unpacked to `/var/www/nextcloud`), certbot (binary only — no cert issuance at bake time)
- nginx server block configured for PHP-FPM via Unix socket
- Services enabled but not started at bake time
- ~~Open item: confirm `component = "clixx"` variable~~ — resolved, `component` default is `"nextcloud"`

### Phase 5 — Compute ✅ Deployed
- `data "aws_ami"` lookup (owner: self, filtered by name pattern `ami-nextcloud-*`)
- `aws_key_pair` for SSH (`nextcloud-key`) — only the public half is committed (`keys/nextcloud-key.pub`); private key + `test-staging.pem` stay untracked
- EC2 instance: public subnet, instance profile, Phase 1 SG, `user_data` wired to `scripts/user-data.sh`
- EBS data volume (40G) + snapshot resource — separate from the OS/app root volume, since files live in S3
- Elastic IP association
- `server_ip` output added so the instance's public IP is surfaced after apply
- ~~Open decision: user-data vs. manual SSH~~ — resolved in favor of **user-data automation** (see Phase 7)
- ~~EBS data volume AZ mismatch~~ — resolved, was hardcoded to `us-west-1a`, fixed to `us-east-1a` and committed

### Phase 6 — DNS & TLS ⏸️ Deferred
- Blocked: no domain registered yet
- Interim approach: access Nextcloud via the AWS-assigned public DNS name over plain HTTP (port 80)
- ACM is not usable here without adding a load balancer in front of the instance — not planned for this scope
- When a domain is acquired:
  - `data "aws_route53_zone"` lookup
  - `aws_route53_record` (A record → Elastic IP)
  - `certbot --nginx` run manually or via user-data once DNS propagates

### Phase 7 — Nextcloud Application Config 🔄 In Progress

Implemented as `scripts/user-data.sh`, run automatically on first boot (idempotent — skips the install block if `config.php` already exists):

1. ✅ Pull DB + admin passwords from SSM (`aws ssm get-parameter --with-decryption`)
2. ✅ Start nginx + php-fpm, bump PHP `memory_limit` to 512M
3. ✅ Run `occ maintenance:install` (CLI install, not the web installer) with RDS endpoint + generated admin creds
4. ✅ Configure S3 bucket as **primary storage** via `occ config:system:set objectstore ...` — auth is IAM-role-based (instance profile), no key/secret set
5. ✅ Set `trusted_domains` to the Elastic IP (and a DNS name slot reserved for when Phase 6 lands)
6. ✅ Theming: pull `branding/logo.png` from S3, apply OneVoice name/color/logo via `occ theming:config`
7. ✅ Create the 10 initial member accounts (`occ user:add`), each with a generated password written to SSM at `/onevoice/prod/nextcloud/users/<user>/password`
8. ⬜ Enable `groupfolders` app
9. ⬜ Create groups: media, general, music, IT
10. ⬜ Assign folders to groups with appropriate permission levels

Note the S3 approach ended up as **primary object storage** (`objectstore` config), not the originally planned `files_external` secondary mount — simpler, and the whole bucket already existed for this purpose.

### Phase 9 — Ops Basics ✅ Done
- ✅ CloudWatch alarms (`monitoring.tf`), all notifying via SNS:
  - EC2 status-check-failed (`AWS/EC2`, `StatusCheckFailed`)
  - CPU credit balance low (`AWS/EC2`, `CPUCreditBalance`) — early warning for this `t`-family burstable instance before performance degrades
  - CPU utilization high (`AWS/EC2`, `CPUUtilization`, sustained >80%)
  - Memory utilization high (`CWAgent`, `mem_used_percent`, sustained >85%)
  - Disk utilization high (`CWAgent`, `disk_used_percent`, root volume, sustained >85%)
- ✅ `nextcloud-ops` CloudWatch dashboard: CPU utilization, CPU credit balance, memory used, disk used, and status-check-failed in one view
- ✅ SNS topic (`ops_alerts`) with email subscriptions (`var.ops_alert_emails`)
- ✅ EC2 IAM role has `CloudWatchAgentServerPolicy` attached (`iam.tf`), so the agent has permission to publish custom metrics
- ✅ CloudWatch agent installed, configured, and running on the instance — the `CWAgent`-namespace alarms (memory, disk) now have a real data source instead of `treat_missing_data = "notBreaching"` covering for an absent feed
- ✅ RDS scheduled snapshots via `aws_db_instance`'s automated backup window (already configured in `db.tf`: `backup_window`, `backup_retention_period = 7`)
- ✅ Onboarding documentation for the group (Nextcloud URL, sync client download links, account handoff) written and delivered

### Phase 10 — Security & Cost Hardening ✅ Applied, then partially rolled back

**Manual (server-touching, done and verified):**
- ✅ **nginx rate limiting** — `limit_req_zone` (10r/s, zone `nextcloud_limit`) in `/etc/nginx/conf.d/rate-limit.conf`, `limit_req zone=nextcloud_limit burst=20 nodelay;` applied to `location /` in `nextcloud.conf`. Applied by hand over SSH, not yet baked into `packer/setup.sh` — won't survive an AMI rebuild until it's folded in there.
- ✅ **CloudWatch log shipping** — CloudWatch agent's config (`/opt/aws/amazon-cloudwatch-agent/etc/config.json`, not `amazon-cloudwatch-agent.json` as originally assumed — see Known Issues) extended with a `logs` block shipping nginx access/error logs and the Nextcloud app log. Three log groups live with 30-day retention: `onevoice-prod-nginx-access`, `onevoice-prod-nginx-error`, `onevoice-prod-nextcloud-app`. Notably does **not** ship php-fpm's own log or syslog — relevant to the 2026-07-17 outage below.

**Terraform, applied 2026-07-17:**
- ✅ **CloudTrail** (`security.tf`) — dedicated `onevoice-prod-cloudtrail-logs` bucket (versioned, SSE, blocked public access, scoped bucket policy), multi-region trail with log file validation. Still live — not part of the rollback.
- ✅ **EBS snapshot automation** (`backup.tf`) — DLM policy + service role, weekly snapshots of `nextcloud-data` (Sundays 03:00 UTC via `cron_expression`, since DLM's interval-based scheduling tops out at 24 hours), 4 retained (~1 month). Supersedes the one-off `aws_ebs_snapshot.nextcloud-data-snapshot` in `compute.tf`, which was left in place rather than removed (removing it would destroy an existing snapshot). Still live.
- ✅ **S3 lifecycle rule** (`s3.tf`) — primary Nextcloud bucket: noncurrent versions → Standard-IA after 30 days, expire after 365, abort incomplete multipart uploads after 7. Still live.
- ✅ **Budget alarm** (`cost.tf`) — monthly cost budget (`var.monthly_budget_limit`, default $35), alerts at 80%/100% actual and 100% forecasted, emailed to `var.ops_alert_emails`. Still live.
- 🔴 **GuardDuty** (`security.tf`) — detector enabled, 15-minute finding frequency, default feature set (CloudTrail/DNS/VPC Flow/S3 analysis, EBS malware protection, plus EKS Audit Logs and Lambda Network Logs the account has no use for). **Removed from config 2026-07-18** — see [Cost Review](#cost-review-2026-07-18).
- 🔴 **Security Hub** (`security.tf`) — account enabled, auto-subscribed to AWS Foundational Security Best Practices, auto-ingested GuardDuty findings. **Removed from config 2026-07-18.**
- 🔴 **Finding alerts** (`security.tf`) — EventBridge rules routing GuardDuty findings (severity ≥ 7) and Security Hub findings (CRITICAL/HIGH, status NEW) into `ops_alerts`, plus the SNS topic policy allowing EventBridge to publish. **Removed from config 2026-07-18** along with their sources.

> Infra management note: Jenkins was descoped — `terraform apply` and Packer builds are run manually/locally. Revisit if the project grows to multiple maintainers or a second workload.

---

## Cost Review (2026-07-18)

Triggered by a $2 charge two days after go-live and a prior $88/mo estimate the group wanted to get closer to $40/mo. Investigated using live Cost Explorer data and direct AWS resource inventory (`aws ec2 describe-instances`, `describe-volumes`, `guardduty list-detectors`, `cloudtrail describe-trails`, `securityhub describe-hub`, all `--profile onevoice`) rather than assumption.

**Findings:**
- Cost Explorer showed a one-time ~$1.91 launch-day spike (2026-07-16) settling to ~$0.13/day since — normal, not a sign of a problem.
- GuardDuty and Security Hub were live in the account (detector/subscription created 2026-07-17, contradicting this doc's prior "not yet applied" status) but still inside their 30-day free trial, so not yet reflected in the daily spend.
- Bottom-up estimate from actual deployed resources + current AWS on-demand pricing (us-east-1) put steady-state cost at **~$45-50/mo** on-demand with GuardDuty/Security Hub billing, or **~$38-40/mo** without them — well under the original $88 estimate either way; no NAT Gateway or Multi-AZ RDS is in play, which are the usual drivers of a number that high.
- `aws_ebs_volume.nextcloud-data` (40GB) is provisioned but was never attached to the instance or mounted (no `aws_volume_attachment`, no mount step in `user-data.sh`) — dead cost (~$4/mo) left over from before the project settled on S3 objectstore for all Nextcloud data.
- A private-subnet + ALB + NAT Gateway architecture was costed out and rejected: real pricing is ALB ~$17-19/mo + NAT Gateway ~$33-35/mo, i.e. **+$50-53/mo**, which would land total spend back near the original $88 figure and works against this project's own single-EC2 design rationale (see README).

**Decisions:**
- **Keep** the unattached 40GB EBS volume and its gp2 type as-is — explicitly declined, not an oversight. See Deferred / Open Decisions Log.
- **Remove GuardDuty and Security Hub.** Reasoning: Security Hub's marginal value was judged low given how tightly the account is already configured by hand (SSH locked to one IP, no public buckets, encryption everywhere). GuardDuty was a closer call — it's genuinely different from raw VPC Flow Logs (which the instance already has): flow logs are raw metadata a person would have to notice a pattern in by eye, where GuardDuty correlates that same data plus CloudTrail/DNS activity against AWS threat intel and live EBS malware scanning. It even caught a real live example during the review — a bot scanning the instance's public IP for planted webshells (`wp_filemanager.php`, `stdin.php`, ~40 similar requests from `20.226.66.230` in a 5-second burst at 2026-07-17 23:36, all harmlessly 404'd). That's exactly the pattern GuardDuty is built to flag automatically. The group decided the cost (~$5-10/mo combined once trials end) wasn't worth it for a project this size and chose manual review instead — an explicit risk tradeoff, not an oversight.
- `terraform plan` for the removal is clean: **7 to destroy, 0 to add, 0 to change** (the GuardDuty detector, the Security Hub account subscription, both EventBridge finding-alert rules and their SNS targets, and the now-unused SNS topic policy allowing EventBridge to publish). `terraform apply` has not been run yet.

**Not done as part of this review, but identified as worth a follow-up:** during the same investigation, CloudWatch metrics showed the instance's PHP service stopped once on 2026-07-17 despite the instance never running low on CPU credits (steady at the 576 max all day) or disk (~19% used all day) — memory climbed steadily from ~48% to ~66% used over the day instead, consistent with preview-generation (imagick/ffmpeg workers) accumulating memory pressure on the `t3.small`'s 2GB RAM. Real MySQL deadlocks (`SQLSTATE[40001]`) also showed up in `nginx-error` starting ~00:31, consistent with concurrent preview jobs contending on the DB. No definitive root cause was confirmed, because neither php-fpm's own log nor syslog/kernel messages are in the three CloudWatch log groups currently shipped (only nginx access/error and the Nextcloud app log are) — there's no OOM-kill message to point to directly. Two cheap, zero-downtime mitigations were identified but not yet implemented: add a 1-2GB swapfile, and extend the CloudWatch agent's log shipping to include php-fpm's log. See Deferred / Open Decisions Log.

---

## Known Issues & Fixes Log

Consolidated across Phases 4, 5, 7, and Dropbox-migration prep work. Ordered roughly by where each was hit.

### Packer / AMI

**Issue:** Uncertainty whether `component = "clixx"` in the Packer template was a leftover from a prior template or intentional.
**Fix:** Confirmed intentional — default value is `"nextcloud"`.
**Status:** ✅ Resolved

### Terraform `templatefile()` variable collision

**Issue:** `user-data.sh` uses bash-native `${...}` syntax (especially `${!NEW_USERS[@]}` array expansion), which Terraform's `templatefile()` function parses as HCL interpolation — breaking the script.
**Fix:** Escaped all bash-only variable references as `$${...}`. Only the 13 real template variables (`db_password_ssm_path`, `admin_password_ssm_path`, `db_host`, `db_name`, `db_user`, `admin_user`, `s3_bucket`, `aws_region`, `elastic_ip`, `public_dns`, `organization`, `environment`, `domain_name`) keep single `${...}`.
**Status:** ✅ Resolved

### Amazon Linux 2023 web server user

**Issue:** `occ` CLI commands failed under the assumption of the Debian/Ubuntu convention (`www-data`) — AL2023 doesn't use that user.
**Fix:** Confirmed correct user is `nginx` (via `ps aux`); all `occ` commands run as `sudo -u nginx php occ ...`.
**Status:** ✅ Resolved

### Deprecated theming parameter

**Issue:** `occ theming:config` didn't apply correctly using the `color` parameter.
**Fix:** Use `primary_color` instead — `color` is deprecated.
**Status:** ✅ Resolved

### Theming CSS caching

**Issue:** Logo/branding changes didn't appear in the UI immediately after `occ theming:config` ran, due to server-side CSS caching.
**Fix:** Not fully resolved — custom CSS for logo sizing was also deferred. Likely needs a cache-clear step added to the theming workflow.
**Status:** ⬜ Open / deferred

### S3 primary objectstore vs. human-readable paths

**Issue:** Early assumption that migration files could be uploaded directly into the primary Nextcloud S3 bucket. This doesn't work — the primary objectstore uses internal keys (`urn:oid:xxxx`), not real file paths, so directly-written objects are invisible to Nextcloud.
**Fix:** Use a separate, dedicated migration S3 bucket (`onevoice_migration` in `s3.tf`), mount it as **External Storage** (Settings → Administration → External Storage, or `occ files_external:create`), then run `occ files:scan --all` (or scoped to the mount path) to index.
**Status:** ✅ Resolved — migration executed, bucket mounted as External Storage, files indexed

### Migration tooling: rclone chosen over `aws s3 cp`, scp, or rsync

**Context:** Moving years of files out of the old shared Dropbox to the migration bucket is a one-shot job — thousands of files, no room for a silent partial failure. Plain `aws s3 cp`/`sync` uploads serially; routing through the EC2 instance via `scp`/`rsync` adds an unnecessary disk hop and doesn't speak S3 natively either way.
**Decision:** Use `rclone` from the local machine straight to the `onevoice-<env>-migration` bucket. It transfers many files in parallel (matters more than raw bandwidth when the payload is lots of small files), checksums and reports real progress, and a ~2000 Mbps home connection was fast enough that the serial alternatives would have left most of that throughput unused.
**Status:** ✅ Resolved — bucket + migration IAM user (`aws_iam_user.nextcloud_migration_mount`, `iam.tf`) provisioned, `rclone` copy completed, and the External Storage mount/scan (previous entry) executed

### AWS CLI / s5cmd profile ambiguity

**Issue:** Multiple AWS profiles configured locally risked uploading the Dropbox migration data to the wrong account/bucket.
**Fix:** Explicitly set the target profile before running any upload tool — `$env:AWS_PROFILE = "onevoice"` for rclone (which reads AWS env vars/credentials) or `--profile onevoice` for direct AWS CLI/s5cmd invocations; verify the target account first with `aws sts get-caller-identity --profile onevoice` before a multi-hour upload.
**Status:** ✅ Resolved (procedural safeguard, not a code fix)

### EBS data volume AZ mismatch

**Issue:** `compute.tf` had the EBS data volume's AZ hardcoded to `us-west-1a`, mismatched against the `us-east-1` stack.
**Fix:** Changed to `us-east-1a`.
**Status:** ✅ Resolved and committed.

### S3 branding-object bucket reference

**Issue:** `s3.tf`'s branding asset upload resource referenced `bucket_domain_name` instead of `bucket`, pointing at the wrong attribute for the logo object.
**Fix:** Changed to reference `bucket`.
**Status:** ✅ Resolved and committed.

### DB hardening settings loosened

**Issue:** Not a bug, but a flagged risk — `db.tf`'s `skip_final_snapshot` / `deletion_protection` were changed to `true` / `false` (from `false` / `true`) to speed up iteration while testing.
**Fix:** No fix applied yet — needs an explicit decision on whether to flip back to `false` / `true` before treating the DB stack as production-final.
**Status:** ⬜ Open decision

### Groupfolders app not visible in Nextcloud UI

**Issue:** App not found when browsing Settings → Apps.
**Fix:** The app lives under the **"Organization"** category filter in the left sidebar — not Featured or Productivity, which is easy to miss. If it's missing even there, the instance likely can't reach `apps.nextcloud.com` to populate the catalog (check Settings → Administration → Overview for a connectivity banner); if so, `occ app:install groupfolders` via CLI will surface the actual error.
**Status:** 🟡 Guidance given — pending confirmation from testing

### UI-installed apps don't survive instance replacement

**Issue:** Groups, folder assignments, and files all live in RDS/S3 and would survive an instance termination + AMI-relaunch — but the `groupfolders` **app installation itself** was enabled manually through the UI, and was never baked into the AMI or scripted into `user-data.sh`. A future instance replacement would come up without it installed.
**Fix (recommended, not yet implemented):** Add `occ app:install groupfolders` + `occ app:enable groupfolders` to `user-data.sh`, matching the pattern already used for the rest of Phase 7 (idempotent, runs on first boot).
**Status:** ⬜ Open — fix identified, not yet implemented

### CloudWatch agent config file path assumption

**Issue:** Assumed the agent's editable config lived at `/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json` (the common convention) — that path doesn't exist on this instance.
**Fix:** The actual file-sourced config is `/opt/aws/amazon-cloudwatch-agent/etc/config.json` (mirrored to `amazon-cloudwatch-agent.d/file_config.json` by the ctl script, translated to `.toml` at runtime for the running agent). Confirmed via `ls` on the instance and cross-checked against live `CWAgent`-namespace metrics in CloudWatch (`mem_used_percent`, `disk_used_percent` were already flowing from `i-08018a6a2f4dcba89`, proving the agent was running off *some* valid config). No SSM parameter is involved — it's a plain local file, edited directly and re-applied via `amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -s -c file:...`.
**Status:** ✅ Resolved

---

## Deferred / Open Decisions Log

- **Domain name:** not yet acquired; Phase 6 blocked until decided (Route53-registered vs. external registrar)
- ~~Phase 7 install method~~ — **resolved:** user-data automation via `occ` CLI, not manual SSH/web installer
- ~~S3 auth method in Nextcloud~~ — **resolved:** IAM instance role, no key/secret, via the `objectstore` primary-storage config
- ~~Packer `component` variable~~ — **resolved:** intentional, default is `"nextcloud"`
- **Nextcloud version pin:** still placeholder `30.0.0` in `packer/setup.sh` — confirm before final bake
- **DB hardening rollback:** `db.tf` has `skip_final_snapshot = true` and `deletion_protection = false` (was `false`/`true`) — a deliberate loosening for faster iteration while still testing; **decide whether to flip back before calling the DB stack production-final**
- **Groups & group folders (Phase 7 remainder):** `groupfolders` app enablement, group creation (media, general, music, IT), and folder-to-group permission assignment are not yet automated or done manually
- ~~CloudWatch agent install~~ — **resolved:** agent installed/configured/started, memory/disk alarms now have a real data source
- ~~Dropbox migration execution~~ — **resolved:** rclone copy, External Storage mount, and `occ files:scan` indexing all completed
- ~~Onboarding documentation~~ — **resolved:** Nextcloud URL, sync client download links, and account handoff instructions delivered to the group
- ~~Phase 10 Terraform apply~~ — **resolved:** `security.tf`, `backup.tf`, `cost.tf`, and the `s3.tf` lifecycle rule were applied 2026-07-17 — CloudTrail, DLM snapshots, S3 lifecycle, and the budget alarm are all live
- **GuardDuty/Security Hub removal apply:** removed from `security.tf` 2026-07-18 after the [cost review](#cost-review-2026-07-18); `terraform plan` is clean (7 to destroy) but `terraform apply` hasn't been run — both are still live/billing in AWS until it is
- **Unattached EBS data volume:** `aws_ebs_volume.nextcloud-data` (40GB, gp2) is provisioned but never attached to the instance or mounted — costs ~$4/mo for nothing. Identified 2026-07-18 during the cost review; **explicitly kept as-is by decision**, not scheduled for cleanup
- **2026-07-17 php-fpm outage:** service stopped once; CPU credits and disk were fine all day, but memory climbed steadily (~48%→66%), pointing at preview-generation memory pressure rather than undersized compute. Root cause not confirmed — php-fpm's log and syslog aren't in the CloudWatch log groups currently shipped, only nginx + the Nextcloud app log. Two fixes identified but not implemented: add a swapfile, and extend CloudWatch agent log shipping to include php-fpm's log
- **nginx rate limiting → AMI:** applied manually over SSH (`limit_req_zone`/`limit_req`), not yet folded into `packer/setup.sh` — won't survive an AMI rebuild until it is