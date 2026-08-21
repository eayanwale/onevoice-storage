# Config-drift implementation plan

Tracking doc for closing #41–#44 (fold cloudflared, nginx rate limiting, and the MCP server/maintenance timer back into `packer/setup.sh`). The actual implementation now lives in the real files — this doc is status/tracking only, not a code copy, to avoid the doc and the real files drifting out of sync with each other (which already happened once: two real bugs got fixed directly in the files and weren't worth mirroring back here).

Branch: `infra/44-bake-config-drift` off `dev` (not yet pushed).

## Files touched

New, under `aws/packer/files/`: `rate-limit.conf`, `cloudflared.service`, `nextcloud-mcp.service`, `nextcloud-maintenance.service`, `nextcloud-maintenance.timer`, `nextcloud-maintenance-check.sh`.

Edited: `aws/packer/nextcloud.pkr.hcl`, `aws/packer/setup.sh`, `aws/terraform/scripts/user-data.sh`, `aws/terraform/compute.tf`, `aws/terraform/data.tf`.

## Verification status

| Item | Status |
|---|---|
| nginx rate limiting (`rate-limit.conf`, `limit_req` line) | Implemented, not yet diffed against the live instance's actual `/etc/nginx/conf.d/rate-limit.conf` |
| `cloudflared.service` | Implemented with `Type=notify` + `TimeoutStartSec=15` (more accurate than an earlier `Type=simple` draft — cloudflared genuinely supports systemd readiness notification). Not yet diffed against `systemctl cat cloudflared` on the live box. |
| `nextcloud-mcp.service`, `nextcloud-maintenance.service`, `nextcloud-maintenance.timer` | Implemented, matches what's documented in `nextcloud-maintenance-automation.md` |
| `nextcloud-maintenance-check.sh` | Implemented as an independent rewrite (not a copy of the live script — SSH access to pull the exact original wasn't available). Includes two fixes an earlier draft was missing: a `trap cleanup EXIT` so the temp workdir is always removed even on failure, and `git config user.name`/`user.email` before committing (a fresh instance has no global git identity, so this was a real gap before) |
| MCP server install method | Confirmed via `ls -la` on the live instance: full `git clone` of the upstream repo (github.com/cbcoutinho/nextcloud-mcp-server) + `uv sync`, not a standalone `uv`-managed dependency project. Still open: whether the clone should pin to a specific tag/commit rather than always cloning `HEAD` — check `git log -1 --oneline` in that directory on the live box. |
| `.env` shape | Confirmed against the live `.env`: single-user BasicAuth mode, no OAuth — just `NEXTCLOUD_HOST`, `NEXTCLOUD_USERNAME`, `NEXTCLOUD_PASSWORD`. No `TOKEN_STORAGE_DB`/`TOKEN_ENCRYPTION_KEY`, so only 2 SSM params needed for the MCP server (not 3) |
| `setup.sh` cloudflared install | Fixed: `curl -fsSl` → `-fsSL` (was silently dropping `-L`/follow-redirects due to a lowercase-`l` typo) and `yum install cloudflared` → `yum install -y cloudflared` (was missing `-y`, which would've hung the non-interactive Packer build) |
| `data.tf` IAM policy | Fixed: dropped a leftover `nextcloud-mcp/token-encryption-key` ARN that had no corresponding SSM param once single-user mode was confirmed |
| Terraform workspace support (`data.tf`'s `terraform_remote_state.bootstrap`) | Implemented — reads whichever workspace the main stack is currently in, so it works correctly for both prod (default workspace) and the sandbox test environment |

## Testing in sandbox first

Before merging to `dev`/pushing to prod, this is being validated in an isolated `sandbox` environment (same AWS account, separate `environment` namespace, isolated via Terraform workspaces — not a separate AWS account). See the workspace/state-isolation discussion in this conversation for the full reasoning; short version:

1. `infra/bootstrap`: `terraform workspace new sandbox` → `terraform apply -var="environment=sandbox"` (fresh DB/admin passwords at `/onevoice/sandbox/...`, isolated from prod's state)
2. `aws/terraform`: `terraform workspace new sandbox`
3. Build a fresh AMI with the config-drift changes:
   ```
   cd aws/packer
   packer init nextcloud.pkr.hcl
   packer validate nextcloud.pkr.hcl
   packer build nextcloud.pkr.hcl
   ```
   Note: `ami_name` includes `{{timestamp}}`, and `data.aws_ami.nextcloud` always picks the most recent `ami-nextcloud-*` AMI regardless of environment — so this new AMI becomes what prod would use on its next apply too, not just sandbox.
4. Create a **separate** Cloudflare Tunnel + hostname for sandbox (don't reuse prod's — same hostname would make it impossible to tell which backend answered). Local service targets are the same as prod either way: `localhost:80` (nginx) and `localhost:8000` (MCP server).
5. Create sandbox's 4 SSM params (see below), then `terraform apply -var="environment=sandbox"` in the main stack.

## SSM parameters needed (per environment)

Not managed by Terraform — these come from external systems, so Terraform only grants read access (`data.tf`). Create manually before first boot in each environment:
```
aws ssm put-parameter --profile onevoice --type SecureString --name "/onevoice/<env>/cloudflared/tunnel-token" --value "<from that environment's Cloudflare Tunnel>"
aws ssm put-parameter --profile onevoice --type SecureString --name "/onevoice/<env>/nextcloud-mcp/username" --value "<NEXTCLOUD_USERNAME>"
aws ssm put-parameter --profile onevoice --type SecureString --name "/onevoice/<env>/nextcloud-mcp/app-password" --value "<NEXTCLOUD_PASSWORD>"
aws ssm put-parameter --profile onevoice --type SecureString --name "/onevoice/<env>/maintenance/github-pat" --value "<fine-grained PAT>"
```
For prod specifically, get the MCP username/app-password by reading them straight off the live `.env` (`cat ~/nextcloud-mcp-server/.env` over SSH) rather than generating new ones. For sandbox, generate fresh values (new app password created via the sandbox Nextcloud instance's own admin UI once it's up, new tunnel token from its own Cloudflare Tunnel).

## Once sandbox validates

```
git add aws/packer/files/ aws/packer/nextcloud.pkr.hcl aws/packer/setup.sh aws/terraform/compute.tf aws/terraform/data.tf aws/terraform/scripts/user-data.sh
git commit -m "Bake Cloudflare Tunnel, nginx rate limiting, and MCP/maintenance automation into the golden AMI

Closes #41, #42, #43."
git push -u origin infra/44-bake-config-drift
```
Open the PR: base `dev`, title `infra(config-drift): bake cloudflared, nginx rate limiting, and MCP/maintenance automation into the golden AMI (#44)`, body includes `Closes #41`, `Closes #42`, `Closes #43`.

## Still outstanding

`terraform validate` passes (confirmed). `packer validate`/`packer build` haven't been run yet. Also still worth pulling from the live prod instance to fully close out the Verification status table above:
```bash
cat /etc/nginx/conf.d/rate-limit.conf
cat /etc/nginx/conf.d/nextcloud.conf
systemctl cat cloudflared
cd /home/ec2-user/nextcloud-mcp-server && git log -1 --oneline
```
