# CLAUDE.md

Self-hosted Nextcloud for the OneVoice gospel/choir group, replacing a shared personal Dropbox.

Read this first for orientation and the rules that are easy to get wrong. The deep detail lives in the READMEs linked at the bottom — prefer them over re-deriving anything from the code.

## Two deployment targets

They are independent. Neither imports from the other. Always establish **which one** a question is about before acting — the answers usually differ.

| | `aws/` | `bluehost/` |
|---|---|---|
| Live at | *(decommissioned)* | `onevoice.knoch.dev` + `cloud.knoch.dev` (`50.6.226.196`) |
| Status | Decommissioned 2026-08-23 — cut over to `bluehost/` | **Authoritative — holds the group's real data** |
| Built by | Terraform + a Packer golden AMI | Two idempotent shell scripts |
| Database | RDS MySQL, private subnets | MariaDB 10.11 on `127.0.0.1` |
| Primary storage | S3, Object Lock 10y | 50 GB local disk |
| Secrets from | SSM Parameter Store (8 SecureStrings) | `/etc/onevoice/onevoice.env` (root, 0600) |
| PHP | 8.2 | 8.3 |

Both run Nextcloud 30, the same theming and seed users, a byte-identical nginx server block, and Cloudflare Tunnel as the only front door. Diagrams: [`docs/architecture.md`](docs/architecture.md).

## Layout

```
aws/terraform/      # main stack; state in S3
aws/packer/         # golden AMI: nextcloud.pkr.hcl, setup.sh, files/
infra/bootstrap/    # applied once, creates the state bucket the above depends on
bluehost/           # provision.sh (no secrets) + configure.sh (all secrets) + bootstrap.sh
docs/               # architecture, runbook, project plan, maintenance
systems/            # generated monthly maintenance checklists
```

## Branching — these are enforced, not conventions

- **`main` and `dev` are protected with `enforce_admins: true`.** Direct pushes fail even for the owner. Everything goes through a PR.
- **Any PR touching a `.md` file must come from a `docs/` branch.** This catches changes that feel like `feat/` or `chore/` work — if a README line changes, the branch is `docs/`.
- Branch format is `type/issue-number-slug`, so an issue must exist first. Create one with `gh issue create` rather than inventing a number.
- Flow is feature → `dev` → `main`, merged with merge commits.
- Before branching, **`git fetch`**. Local `origin/dev` and `origin/main` have been stale, which silently changes what a branch is based on.

Full detail in [`CONTRIBUTING.md`](CONTRIBUTING.md).

## Reaching the hosts

| Host | Command |
|---|---|
| Bluehost VPS | `ssh -i ~/.ssh/onevoice_bluehost root@50.6.226.196` |
| AWS EC2 | key at `~/.ssh/ec2-nextcloud-key` (and `aws/terraform/keys/nextcloud-key`); get the IP from `terraform output server_ip` or `aws ec2 describe-instances --profile onevoice` |

AWS SSH ingress is locked to `70.21.84.34/32`, so it only works from that address. The AWS CLI profile is `onevoice`.

`onevoice.knoch.dev` and `cloud.knoch.dev` resolve to Cloudflare, not the hosts — you cannot SSH to them.

## Running remote commands from this machine

The shell here is **PowerShell on Windows**. It mangles quotes, `$`, and `\n` on the way into `ssh`, and the sandbox rejects some of those strings outright. Inline `ssh host 'script'` fails in ways that look like remote bugs but are local quoting.

Send anything non-trivial as base64:

```powershell
$lines = @('echo one', 'echo two')
$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($lines -join "`n")))
ssh -i "$env:USERPROFILE\.ssh\onevoice_bluehost" -o BatchMode=yes root@50.6.226.196 "echo $b64 | base64 -d | bash"
```

Avoid literal `\n` and `\$` inside the PowerShell string — both trip the sandbox guard.

## Secret hygiene

- **`occ files_external:list` prints the B2 access key and secret in cleartext** in its `Options` column. It redacts them in `Configuration` but not there. Never run it raw — filter it, or don't run it.
- `aws/terraform/keys/` holds a real private key. It is gitignored; never copy that directory to a server.
- `bluehost/onevoice.env` is gitignored and travels out of band. Only `.example` belongs in git.
- Seed-user passwords land in `/root/onevoice-user-passwords.txt` (0600) on the VPS, SSM on AWS.

## The scripts are the source of truth

Fixing something by editing a config **on a host** is half a fix — the next provision run reverts it. Every host-side change must also land in the script that generates that file:

- Bluehost: `bluehost/provision.sh` (OS, packages, nginx, php, systemd) or `bluehost/configure.sh` (database, install, theming, users)
- AWS: `aws/packer/setup.sh` (bake time) or `aws/terraform/scripts/user-data.sh` (first boot)

When a fix applies to both targets, say so explicitly — parity gaps between the two are a recurring source of bugs, and several fixes exist on one host only.

## Known landmines

- **Do not rename the Terraform backend keys.** `onevoice-storage/terraform.tfstate` and `infra/bootstrap/terraform.tfstate` are paths inside the state bucket, not repo paths. They look stale after the `aws/` rename; they are not. Rewriting either orphans the state and plans a full rebuild.
- **`-replace` on the EC2 instance is not a clean install.** RDS survives, so `occ maintenance:install` collides with the existing database and `set -e` kills first-boot provisioning. Destroy and re-apply the whole stack instead.
- **Never point the Bluehost clone at prod's S3 bucket or prod's tunnel token.** The first overwrites prod objects at `urn:oid:1,2,3…`; the second makes Cloudflare round-robin `onevoice.knoch.dev` between two hosts. Both are guarded in `configure.sh` and both defaults are safe.
- **`user-data.sh` is a Terraform `templatefile()`.** Bash variables need `$${VAR}` or Terraform interpolates them.
- **Trashbin is off on AWS** (S3 objectstore bug) — no undo anywhere on that instance. It works on Bluehost, which is on local disk.
- **Moving files across storages loses their shares.** Cross-storage moves are copy-then-delete, so the fileid changes and `oc_share` rows go with the original. Same-storage renames keep shares.
- **`terraform destroy` fails on the primary bucket** while it holds objects and now also because of Object Lock. Safe to re-run `apply`.

## Verifying a host

```bash
# Bluehost
sudo -u nginx php /var/www/nextcloud/occ status
sudo -u nginx php /var/www/nextcloud/occ setupchecks
systemctl status nginx php-fpm mariadb valkey cloudflared
ss -tlnp | grep -E ':(3000|9090|9100)\b'   # expect 127.0.0.1 only
firewall-cmd --list-services               # expect: dhcpv6-client ssh

# stale Nextcloud file locks (symptom: "Could not lock node")
valkey-cli -h 127.0.0.1 --scan --pattern '*lockfiles*' | while read -r k; do valkey-cli -h 127.0.0.1 del "$k"; done
```

## Where the real documentation is

| Question | File |
|---|---|
| Why the project exists, design decisions, cost | [`README.md`](README.md) |
| AWS operations, secrets, gotchas, monitoring | [`aws/README.md`](aws/README.md) |
| Bluehost install, `onevoice.env`, EL10 platform facts | [`bluehost/README.md`](bluehost/README.md) |
| Topology diagrams for both, and what differs | [`docs/architecture.md`](docs/architecture.md) |
| Deploy procedure, workspace isolation | [`docs/deployment-runbook.md`](docs/deployment-runbook.md) |
| Known-issues log, deferred decisions | [`docs/nextcloud-project-plan.md`](docs/nextcloud-project-plan.md) |
| Branch, PR, label and milestone conventions | [`CONTRIBUTING.md`](CONTRIBUTING.md) |

## Working notes

- Both targets are applied manually and locally. There is no CI/CD.
- `bluehost/` is now the live, authoritative deployment — the group's real data was ported over and `onevoice.knoch.dev` was cut over to it on 2026-08-23. See issue #73.
- `aws/` is being decommissioned (`terraform destroy`). Until that's done, its resources still exist but nothing points at them.
