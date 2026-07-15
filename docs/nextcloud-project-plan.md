# OneVoice Nextcloud Migration — Project Plan

**Project:** Self-hosted Nextcloud on AWS EC2, replacing shared personal Dropbox for the OneVoice gospel/choir group
**Org variable:** `onevoice`
**Deployment tooling:** Terraform (infra) + Packer (golden AMI), applied manually/locally
**Naming convention:** `${var.organization}-${var.environment}-<resource>`

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
| 9 — Ops basics | CloudWatch alarms, RDS scheduled snapshots | ✅ Done |

> **Open decision:** DB `skip_final_snapshot`/`deletion_protection` loosened to `true`/`false` for iteration. See [Deferred / Open Decisions Log](#deferred--open-decisions-log).
>
> All ops work (Phase 9) is done. Remaining open items are tracked in the [Deferred / Open Decisions Log](#deferred--open-decisions-log): domain/DNS, group folders, DB hardening rollback, Nextcloud version pin, and onboarding docs.

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
- ✅ CloudWatch alarms: EC2 status-check-failed and low CPU-credit-balance, both notifying via SNS (`monitoring.tf`)
- ✅ SNS topic (`ops_alerts`) with email subscriptions (`var.ops_alert_emails`)
- ✅ RDS scheduled snapshots via `aws_db_instance`'s automated backup window (already configured in `db.tf`: `backup_window`, `backup_retention_period = 7`)
- Onboarding documentation for the group (Nextcloud URL, sync client download links) — deferred, see [Deferred / Open Decisions Log](#deferred--open-decisions-log)

> Infra management note: Jenkins was descoped — `terraform apply` and Packer builds are run manually/locally. Revisit if the project grows to multiple maintainers or a second workload.

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
**Fix:** Use a separate, dedicated migration S3 bucket, mount it as **External Storage** (Settings → Administration → External Storage, or `occ files_external:create`), then run `occ files:scan --all` (or scoped to the mount path) to index.
**Status:** ✅ Resolved (plan confirmed, migration not yet executed)

### AWS CLI / s5cmd profile ambiguity

**Issue:** Multiple AWS profiles configured locally risked uploading the Dropbox migration data to the wrong account/bucket.
**Fix:** Explicitly set the target profile via `$env:AWS_PROFILE = "onevoice"` or `s5cmd --profile onevoice ...`; verify the target account first with `aws sts get-caller-identity --profile onevoice` before a multi-hour upload.
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

---

## Deferred / Open Decisions Log

- **Domain name:** not yet acquired; Phase 6 blocked until decided (Route53-registered vs. external registrar)
- ~~Phase 7 install method~~ — **resolved:** user-data automation via `occ` CLI, not manual SSH/web installer
- ~~S3 auth method in Nextcloud~~ — **resolved:** IAM instance role, no key/secret, via the `objectstore` primary-storage config
- ~~Packer `component` variable~~ — **resolved:** intentional, default is `"nextcloud"`
- **Nextcloud version pin:** still placeholder `30.0.0` in `packer/setup.sh` — confirm before final bake
- **DB hardening rollback:** `db.tf` has `skip_final_snapshot = true` and `deletion_protection = false` (was `false`/`true`) — a deliberate loosening for faster iteration while still testing; **decide whether to flip back before calling the DB stack production-final**
- **Groups & group folders (Phase 7 remainder):** `groupfolders` app enablement, group creation (media, general, music, IT), and folder-to-group permission assignment are not yet automated or done manually
- **Onboarding documentation (Phase 9 remainder):** Nextcloud URL, sync client download links, and account handoff instructions for the group not yet written