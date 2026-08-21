# onevoice-storage — Issue Hierarchy, Full Drafts

Legend: **[EXISTING #N — needs body]** = filed on GitHub, currently empty, draft below is ready to paste in. **[EXISTING #N — has body]** = already complete, included for reference only, no action needed. **[NEW]** = not filed yet.

---

## Milestone: `v1.4.0 – Eliminate config drift`

### Parent: **[EXISTING #44 — needs body]** Eliminate config drift: fold live-server changes back into `packer/setup.sh`

Three things are running live on the EC2 instance, applied by hand over SSH, with no representation in `packer/setup.sh`, Terraform, or `user-data.sh`. A rebuild from the golden AMI today would come up missing all three. Tracked as sub-issues #41–#43 below (already linked).

- [ ] #41 — Cloudflare Tunnel (cloudflared)
- [ ] #42 — nginx rate limiting
- [ ] #43 — MCP server + maintenance-timer systemd units

**Done when:** a fresh Packer build + instance launch reproduces all three without a manual SSH step.

### Sub-issues (already filed, complete — no action needed)
- **[EXISTING #41 — has body]** Fold Cloudflare Tunnel (cloudflared) provisioning into the golden AMI
- **[EXISTING #42 — has body]** Fold nginx rate limiting into the golden AMI
- **[EXISTING #43 — has body]** Fold nextcloud-mcp.service and nextcloud-maintenance.timer into repo-tracked provisioning

---

## Milestone: `v1.5.0 – CI for the repo`

### Parent: **[NEW]** Stand up CI/CD for onevoice-storage

There is currently no `.github/workflows` directory and no CI of any kind — Terraform and Packer are both applied manually/locally (confirmed in README: *"applied manually/locally — no CI/CD"*). Every plan, security check, and AMI freshness check today depends on someone remembering to run it by hand.

- [ ] #(sub) — `terraform plan` on every PR
- [ ] #(sub) — `tfsec`/`checkov` static scanning
- [ ] #(sub) — scheduled Packer rebuild

**Done when:** a PR touching `aws/terraform/**` gets an automated plan + security-scan comment, and the AMI is rebuilt on a schedule without a human kicking it off.

### Sub-issue: **[NEW]** Add `terraform plan` GitHub Actions workflow on every PR

Add a workflow that runs `terraform init` + `terraform plan` against `aws/terraform/` (and `infra/bootstrap/` if touched) on every PR, posting the plan output as a PR comment.

- [ ] Add `.github/workflows/terraform-plan.yml`, triggered on `pull_request` for paths under `aws/terraform/**` and `infra/bootstrap/**`
- [ ] Wire up AWS credentials via OIDC (preferred) or repo secrets — scoped read-only, since this is plan-only, no apply
- [ ] Post the plan output back to the PR as a comment
- [ ] Confirm it runs cleanly against the current `dev` branch state without drift-related false failures

### Sub-issue: **[NEW]** Add `tfsec`/`checkov` static scanning to CI

Static-scan the Terraform on every PR so security regressions (open SGs, unencrypted resources, public buckets) get caught before `apply`, not after — this repo already went through one manual cost/security review (GuardDuty/Security Hub removal); a scanner catches the class of issue that review was doing by hand.

- [ ] Add `tfsec` (or `checkov`) as a step in the same or a sibling workflow to the `terraform plan` one
- [ ] Run against `aws/terraform/` and `infra/bootstrap/`
- [ ] Decide pass/fail policy — hard fail on PR, or report-only to start given the account is already hand-hardened
- [ ] Baseline/ignore any existing accepted-risk findings (e.g. 80/443 open by design, no NAT/ALB by design) so the scan doesn't cry wolf on intentional decisions already documented in the project plan

### Sub-issue: **[NEW]** Add a scheduled Packer rebuild workflow

Nothing currently rebuilds the golden AMI on a cadence — `packer build` is run manually/locally per the README. Once config drift (`v1.4.0` above) is folded back in, a scheduled rebuild keeps the AMI from silently going stale (unpatched nginx/PHP, outdated Nextcloud version pin).

- [ ] Add `.github/workflows/packer-build.yml` on a `schedule` trigger (e.g. weekly)
- [ ] Wire up AWS credentials for the Packer build (least-privilege, AMI-bake-only permissions)
- [ ] Decide on notification (SNS, GH Actions summary, or both) when a new AMI is produced, so it's known rather than silent
- [ ] Out of scope here: auto-swapping the running instance to the new AMI — that's a separate cutover decision, not automated by this issue

---

## Milestone: `v1.6.0 – Prove the disaster-recovery story`

### Parent: **[NEW]** Run and document a real disaster-recovery test

DR is currently theoretical: DLM takes weekly EBS snapshots and RDS has automated backups, but nothing has ever actually been restored. "We have backups" and "we've restored from backups" are different claims — this closes that gap with a real, timed, written-up test.

- [ ] #(sub) — terminate/relaunch EC2 from the golden AMI against existing S3 + RDS
- [ ] #(sub) — time and log the recovery
- [ ] #(sub) — write the runbook

**Done when:** there's a dated runbook in the repo showing an actual instance was terminated and successfully relaunched, with a real recovery-time number attached.

### Sub-issue: **[NEW]** Terminate and relaunch EC2 from the golden AMI against existing S3 + RDS

- [ ] Snapshot current state first (confirm DLM snapshot is current, note RDS latest automated backup timestamp)
- [ ] Terminate the running EC2 instance (staging window, not during active choir use)
- [ ] Relaunch via `terraform apply` from the current golden AMI, pointed at the existing S3 bucket + RDS instance (no data migration — proving the *instance* is disposable, not the data)
- [ ] Confirm Nextcloud comes up healthy: `occ status`, S3 objectstore reachable, RDS connection working, files visible
- [ ] Note anything that required manual intervention — those are new config-drift items, feed back into `v1.4.0`

### Sub-issue: **[NEW]** Time and log the full recovery process

- [ ] Capture wall-clock time from "terminate" to "Nextcloud healthy and reachable" for the test above
- [ ] Log every step taken, including anything not automated, with timestamps
- [ ] Record this as a baseline RTO (recovery time objective) number — currently no such number exists anywhere in the repo

### Sub-issue: **[NEW]** Write up the DR runbook

- [ ] Turn the logged steps into a repeatable runbook (new doc, e.g. `docs/disaster-recovery-runbook.md`)
- [ ] Include the RTO baseline, prerequisites (AMI ID/lookup, SSM parameters, RDS/S3 identifiers), and rollback notes if the relaunch fails
- [ ] Link it from the README alongside the existing project-plan doc

---

## Milestone: `v1.8.0 – Cross-region / tested backup for RDS and S3`

### Parent: **[NEW]** Add and test cross-region/automated backups for RDS and S3

DLM covers EBS snapshots, and RDS already has automated backups (`backup_retention_period = 7` in `db.tf`) — but there's no cross-region copy and no proven restore path for either RDS or S3, and no test has confirmed a restore actually works.

- [ ] #(sub) — automated RDS snapshot export / cross-region copy
- [ ] #(sub) — S3 cross-region replication
- [ ] #(sub) — an actual restore test

**Done when:** a real restore of both an RDS snapshot and an S3 object/version has been performed and timed, not just configured.

### Sub-issue: **[NEW]** Add automated RDS snapshot export / cross-region copy

- [ ] Add cross-region copy of RDS automated (or manual) snapshots via `aws_db_instance_automated_backups_replication` or a scheduled snapshot-copy Lambda/Terraform resource
- [ ] Pick the target region (consistent with any future on-prem/DR strategy)
- [ ] Confirm retention/cost tradeoff explicitly (this project already went through one cost review — treat this the same way)

### Sub-issue: **[NEW]** Add S3 cross-region replication (or equivalent)

- [ ] Evaluate CRR for the primary Nextcloud objectstore bucket vs. the migration bucket — likely different priority given the R2 migration (`v1.7.0`) may make this moot for one or both buckets
- [ ] If proceeding: add `aws_s3_bucket_replication_configuration` with versioning already in place as a prerequisite (confirm current bucket versioning state)
- [ ] Document the decision either way — including "explicitly deferred until R2 migration lands" if that's the call

### Sub-issue: **[NEW]** Run and document an actual restore test

- [ ] Restore an RDS snapshot to a scratch instance, verify data integrity, tear down
- [ ] Restore/verify an S3 object from a replica or noncurrent version, verify integrity
- [ ] Fold findings into the same DR runbook from `v1.6.0`, or a dedicated backup-restore runbook if it diverges enough

---

## Milestone: `v1.9.0 – Nextcloud group folders automation`

### Parent: **[NEW]** Automate Nextcloud group folders via `occ`

Called out as an open item in both the project plan (Phase 7 remainder) and the Known Issues log: the `groupfolders` app was enabled manually through the UI and was never baked into `user-data.sh` — a future instance replacement comes up without it. Groups (media, general, music, IT) and folder-to-group permission assignment are also not yet automated.

- [ ] #(sub) — script `groupfolders` app install/enable
- [ ] #(sub) — script group creation
- [ ] #(sub) — script folder-to-group permission assignment
- [ ] #(sub) — fold into onboarding docs

**Done when:** `user-data.sh` alone reproduces the current group-folders setup on a fresh instance, and the onboarding doc reflects it.

### Sub-issue: **[NEW]** Script `groupfolders` app install/enable via `occ`

- [ ] Add `occ app:install groupfolders` + `occ app:enable groupfolders` to `user-data.sh`, matching the idempotent pattern already used for the rest of Phase 7
- [ ] Confirm it works even when the instance can't reach `apps.nextcloud.com` at boot (see the known "connectivity banner" issue in the plan's Known Issues log) — may need a retry/wait step

### Sub-issue: **[NEW]** Script group creation (media, general, music, IT) via `occ`

- [ ] Add `occ group:add` calls for the four groups to `user-data.sh`, idempotent (skip if already exists)
- [ ] Confirm group names match what's actually live today before scripting (check current state first)

### Sub-issue: **[NEW]** Script folder-to-group permission assignment via `occ`

- [ ] Add `occ files_external:create` / groupfolders CLI equivalents to assign folders to the four groups with the correct permission levels
- [ ] Document the intended folder → group → permission mapping somewhere durable (this doc or the project plan) before scripting, since it doesn't seem to be written down yet

### Sub-issue: **[NEW]** Fold group folders steps into onboarding docs

- [ ] Update the existing onboarding documentation (referenced in project plan Phase 9) to describe how group membership maps to folder access, for new members joining the choir groups

---

## Milestone: `v2.0.0 – Centralized logging via Loki/Grafana`

### Parent: **[NEW]** Replace CloudWatch Logs with a self-hosted Loki/Grafana stack

Currently nginx access/error and the Nextcloud app log ship to CloudWatch Logs (three log groups, 30-day retention). Swapping to a self-hosted Loki/Grafana stack is called out specifically as good rep ahead of the planned on-prem migration, where CloudWatch won't be an option anyway.

- [ ] #(sub) — stand up Loki + Grafana
- [ ] #(sub) — ship logs to Loki
- [ ] #(sub) — build Grafana dashboards
- [ ] #(sub) — cut over from CloudWatch Logs

**Done when:** the existing CloudWatch ops dashboard's log-visibility value is fully replaced in Grafana, and CloudWatch Logs shipping can be turned off without losing anything.

### Sub-issue: **[NEW]** Stand up Loki + Grafana (Docker Compose)

- [ ] Decide placement: on the existing EC2 instance (adds load to the box CloudWatch metrics already watch closely), or a small dedicated instance — weigh against the project's existing "keep it simple, single box" philosophy
- [ ] Docker Compose stack: Loki + Grafana (+ Promtail as the shipping agent, see next issue)
- [ ] Expose Grafana via the existing Cloudflare Tunnel pattern (new hostname, e.g. `grafana.knoch.dev`) rather than opening a new port

### Sub-issue: **[NEW]** Ship nginx/php-fpm/Nextcloud logs to Loki

- [ ] Install and configure Promtail (or the CloudWatch-agent-equivalent) to tail nginx access/error, Nextcloud app log, and — notably, unlike the current CloudWatch setup — php-fpm's own log and syslog, since the 2026-07-17 outage's root cause was never confirmed for exactly this reason
- [ ] Confirm log volume/retention doesn't become a new disk-usage concern on the instance

### Sub-issue: **[NEW]** Build Grafana dashboards replacing the CloudWatch ops dashboard

- [ ] Recreate the log-search/visibility value currently only reachable via CloudWatch Logs Insights
- [ ] Optional: mirror the existing CPU/memory/disk CloudWatch alarms as Grafana panels if metrics get added to the stack later — out of scope for logs-only unless desired

### Sub-issue: **[NEW]** Decommission/cut over from CloudWatch Logs

- [ ] Run both systems in parallel for a burn-in period
- [ ] Once Grafana is trusted, stop the CloudWatch agent's `logs` block (keep metrics — alarms still depend on `CWAgent` namespace)
- [ ] Update README/project plan to reflect the new logging story

---

## Milestone: `v2.1.0 – Secrets rotation`

### Parent: **[NEW]** Rotate and shorten lifetime of long-lived secrets

Two long-lived credentials are called out explicitly in `docs/nextcloud-maintenance-automation.md`: the fine-grained GitHub PAT used by the maintenance automation, and the Cloudflare Tunnel token. Neither rotates automatically today.

- [ ] #(sub) — GitHub PAT rotation
- [ ] #(sub) — Cloudflare Tunnel token rotation
- [ ] #(sub) — audit for other long-lived secrets

**Done when:** both named secrets either rotate automatically or have a documented, followed cadence — and there's confidence nothing else long-lived is hiding on the instance.

### Sub-issue: **[NEW]** Replace/rotate the long-lived GitHub PAT, document rotation cadence

- [ ] Evaluate whether GitHub Apps (short-lived installation tokens) can replace the fine-grained PAT for the maintenance automation, given the PAT's already-documented limitations (can't label/assign/comment on issues via API)
- [ ] If a short-lived credential isn't practical yet, document an explicit manual rotation cadence (e.g. every 90 days) and where the token lives (`~/.config/gh/hosts.yml`, mode 600)
- [ ] Add a calendar/issue-based reminder for whichever cadence is chosen

### Sub-issue: **[NEW]** Replace/rotate the Cloudflare Tunnel token, document rotation cadence

- [ ] Check whether Cloudflare supports scoped/short-lived tunnel tokens as an alternative to the current long-lived token-based tunnel
- [ ] Document the rotation procedure (regenerate in Zero Trust dashboard, update `/etc/cloudflared/token` on the instance, restart `cloudflared`) — this becomes easier to do safely once `v1.4.0` bakes `cloudflared` into the AMI/SSM pattern
- [ ] Document a cadence, even if manual

### Sub-issue: **[NEW]** Audit for other long-lived secrets in SSM/on the instance

- [ ] Inventory everything in SSM Parameter Store under `/onevoice/prod/...` and confirm each is either short-lived, rotated, or has an accepted-risk note
- [ ] Check the instance directly (`.env` files, `~/.aws/credentials` if any, other API tokens) for anything not already accounted for
- [ ] Fold findings into README's Security notes section

---

## Milestone: `v1.7.0 – Finish the Cloudflare R2 migration` *(mostly already tracked)*

### Parent: **[EXISTING #9 — has body]** S3 → Cloudflare R2 migration

*(Existing body, included for reference — no action needed unless you want to expand it):*

> Interim step in the on-prem migration. Move both buckets (primary Nextcloud objectstore + migration bucket) from AWS S3 to Cloudflare R2 for lower cost, until a NAS is available for full on-prem storage.

### Sub-issues

- **[EXISTING #17 — needs body]** Create R2 buckets (primary + migration)
  - [ ] Create the R2 equivalent of the primary Nextcloud objectstore bucket and the migration bucket, matching current S3 bucket naming/purpose (`s3.tf` as reference)
  - [ ] Decide whether these live in Terraform (a Cloudflare provider block) or are created manually and referenced — note the auth-model difference from S3 means this isn't a drop-in provider swap
  - [ ] Confirm region/jurisdiction settings match project needs

- **[EXISTING #18 — needs body]** Set up R2 auth for primary Nextcloud objectstore
  - [ ] Resolve the open question flagged in `changelog.md`: there's no IAM-role equivalent on R2, so the primary bucket needs R2 API tokens or S3-compatible access keys instead of the current instance-role auth
  - [ ] Generate scoped R2 API token, store in SSM (matching existing DB/admin-password pattern, not in Terraform vars or state-visible plaintext)
  - [ ] Update Nextcloud's `objectstore` config (`occ config:system:set objectstore ...`) to point at R2 with the new auth

- **[EXISTING #19 — needs body]** Set up R2 auth for migration bucket External Storage mount
  - [ ] Since the migration bucket is already access-key based (via `aws_iam_user.nextcloud_migration_mount`), this should translate more directly than the primary bucket
  - [ ] Generate R2 access key, update the External Storage mount config (`occ files_external:create` or admin UI) to point at R2
  - [ ] Re-run `occ files:scan` after the mount change to confirm indexing still works

- **[EXISTING #20 — needs body]** Cutover and verify data integrity
  - [ ] Migrate/copy existing bucket contents from S3 to the new R2 buckets (rclone, consistent with the tooling choice already made for the original Dropbox migration)
  - [ ] Verify checksums/file counts match between source and destination for both buckets
  - [ ] Spot-check Nextcloud file access post-cutover (primary storage + External Storage mount)

- **[EXISTING #21 — needs body]** Cutover and decommission EC2 instance
  - [ ] *(Title suggests EC2 decommission — likely a copy/paste mismatch with the on-prem milestone below; confirm scope. If this is meant to be S3 bucket decommission rather than EC2, retitle before filling in the checklist.)*
  - [ ] Once R2 is confirmed authoritative, remove the S3 bucket resources from `s3.tf` (or downgrade to a documented rollback window before deleting)
  - [ ] Update README/project plan cost tables to reflect R2 instead of S3

### Also part of this milestone: **[NEW]** Write up R2 cost/latency before-after comparison

- [ ] Capture actual S3 costs pre-migration (Cost Explorer, same methodology as the 2026-07-18 cost review)
- [ ] Capture actual R2 costs post-migration, including confirming zero egress fees in practice
- [ ] Measure latency/perceived performance difference, if any, from the group's usage
- [ ] Write up as a short doc — this is explicitly called out as a good portfolio artifact

---

## Milestone: `v3.0.0 – On-prem migration groundwork` *(mostly already tracked)*

### Parent: **[EXISTING #11 — has body]** On-prem compute migration (Optiplex 7040)

*(Existing body, included for reference):*

> - Stand up a refurbished Optiplex 7040 as an on-prem compute target.
> - Run Nextcloud in a Docker container on that box.
> - Front it with its own Cloudflare Tunnel, same pattern as the AWS setup, specifically to avoid exposing the home router's public IP.
> - **Status:** hardware chosen, no build work started yet.

### Sub-issues

- **[EXISTING #14 — needs body]** Set up Docker on the Optiplex
  - [ ] Install Docker (+ Docker Compose) on the Optiplex 7040
  - [ ] Confirm OS choice/base image and document it (this is a meaningfully different deployment shape from Packer/EC2, per the project plan)
  - [ ] Basic hardening pass (updates, non-root Docker usage, firewall) before anything is exposed

- **[EXISTING #15 — needs body]** Port Nextcloud container config over
  - [ ] Translate the current nginx+PHP-FPM+Nextcloud stack (from `packer/setup.sh`) into a Docker Compose service definition
  - [ ] Point storage at R2 (assuming `v1.7.0` lands first) rather than re-deriving from S3
  - [ ] Confirm config/theming/user data parity with the current EC2 instance before considering this "ported"

- **[EXISTING #16 — needs body]** Set up Cloudflare Tunnel on the Optiplex
  - [ ] Install `cloudflared` on the Optiplex, same token-based tunnel pattern as EC2 (and per `v1.4.0`, sourced from the now-repo-tracked config rather than re-deriving it by hand)
  - [ ] Register a new public hostname for the on-prem instance, explicitly to avoid exposing the home router's public IP (per the parent issue's stated goal)
  - [ ] Confirm no port-forwarding/router changes are needed

### Related, already filed elsewhere
- **[EXISTING #12 — has body]** Migrate object storage: R2 to NAS — final step, once a NAS is acquired, moving off R2 onto on-prem storage
- **[EXISTING #27 — closed]** (Future/on-prem) Plan rollout to on-prem host — the original placeholder ticket that spawned #11/#14–16; already closed as superseded

---

## Summary: what needs action right now

1. **#44** — paste in the parent-issue body above (sub-issues already linked, nothing else to do there)
2. **#14, #15, #16, #17, #18, #19, #20, #21** — currently title-only; paste in bodies above (note the #21 title/scope mismatch flagged above — worth a second look before filling it in)
3. **New milestones/issues** — CI, DR, cross-region backup, group folders, Loki/Grafana, secrets rotation — none of these are filed yet; titles + bodies above are ready to copy in whenever you want to start creating them
