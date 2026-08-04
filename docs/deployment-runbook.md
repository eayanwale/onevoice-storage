# Deployment runbook

Step-by-step for standing up (or rebuilding) the `sandbox` or `prod` environment. Living doc — add to it as new steps/gotchas turn up.

## Prerequisites

- Terraform >= 1.7.0, Packer, AWS CLI
- `--profile onevoice` configured with credentials for the target AWS account
- Repo root: `d:\Enoch\workspace\personal\onevoice`

## 1. Bootstrap (once per environment)

```
cd infra\bootstrap
terraform workspace new <env>      # e.g. sandbox — skip for prod, it's already on the default workspace
terraform apply -var="environment=<env>"
```
Creates fresh `random_password`-generated DB/admin passwords in SSM at `/onevoice/<env>/nextcloud/{db-password,admin-password}`. Also creates an unused `onevoice-<env>-terraform-state` S3 bucket as a side effect (nothing actually uses it as a backend — safe to ignore).

## 2. Build the AMI

```
cd onevoice-storage\packer
packer init nextcloud.pkr.hcl
packer validate nextcloud.pkr.hcl
packer build nextcloud.pkr.hcl
```
One AMI serves all environments — `data.aws_ami.nextcloud` always picks the most recent `ami-nextcloud-*`, so a build here affects the *next* apply for every environment, not just the one you're working on.

## 3. Cloudflare Tunnel (once per environment)

Cloudflare Zero Trust dashboard → Networks → Tunnels → **Create a tunnel** (a new one per environment — never reuse another environment's tunnel/hostname).

Two public hostname routes on that tunnel:

| Hostname | Service | Notes |
|---|---|---|
| `<env>.knoch.dev` (prod uses bare `onevoice.knoch.dev`) | `HTTP`, `127.0.0.1:80` | nginx/Nextcloud |
| `mcp-<env>.knoch.dev` | `HTTP`, `127.0.0.1:8000` | MCP server — **use `127.0.0.1` explicitly, not `localhost`**. The MCP server only binds `127.0.0.1`; `localhost` can resolve to `::1` first and silently fail to connect. |

Copy the tunnel token — needed in step 4.

## 4. Create required SSM parameters (per environment)

Terraform grants read access to these but does not create them — they come from external systems Terraform has no way to generate.

```
aws ssm put-parameter --profile onevoice --type SecureString --region us-east-1 --name "/onevoice/<env>/cloudflared/tunnel-token" --value "<from step 3>"
aws ssm put-parameter --profile onevoice --type SecureString --region us-east-1 --name "/onevoice/<env>/nextcloud-mcp/username" --value "<nextcloud username for the MCP app password>"
aws ssm put-parameter --profile onevoice --type SecureString --region us-east-1 --name "/onevoice/<env>/nextcloud-mcp/app-password" --value "<generated in Nextcloud Settings > Security > Create new app password>"
aws ssm put-parameter --profile onevoice --type SecureString --region us-east-1 --name "/onevoice/<env>/maintenance/github-pat" --value "<fine-grained PAT, Contents/Issues/PRs write, scoped to this repo>"
```

For prod specifically, the MCP username/app-password can be read straight off the live `.env` (`cat ~/nextcloud-mcp-server/.env` over SSH) instead of generating new ones.

The migration bucket's access key is **not** on this list — Terraform generates and writes that one itself (`iam.tf` → SSM), nothing to do manually.

## 5. Deploy the main stack

```
cd onevoice-storage\terraform
terraform workspace new <env>      # skip for prod (default workspace)
terraform plan -var="environment=<env>"
```
Check the plan touches only `onevoice-<env>-*` resources — **stop and investigate if anything named `onevoice-prod-*` shows up** while working in a non-prod workspace.

```
terraform apply -var="environment=<env>"
```

## 6. Verify

```bash
curl -i https://<env>.knoch.dev/status.php          # expect real JSON, {"installed":true,...}
curl -i https://mcp-<env>.knoch.dev/mcp -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"curl-test","version":"1.0"}}}'
```
Log in via the web UI (in a private/incognito window — see caution below) and confirm Settings → Administration → External Storage shows the "Migration" mount.

## Cautions

- **Recreating the instance alone (`terraform apply -replace="aws_instance.nextcloud-server"`) is not equivalent to a clean install.** RDS isn't touched by `-replace`, so a fresh instance's `occ maintenance:install` collides with the already-installed database ("The Login is already being used") and `set -e` kills the rest of first-boot provisioning right there. For a genuinely clean end-to-end test, destroy and re-apply the **whole** stack, not just the instance.
- **`terraform destroy` will likely fail on `nextcloud-store`** (primary S3 bucket) if it has real objects and hasn't been emptied — safe to ignore and re-run `apply` afterward; Terraform recreates everything else and leaves the still-existing bucket alone. Note the old bucket contents become orphaned (invisible to a fresh install's empty database) rather than actually cleaned up.
- **Fresh instance + old browser session = "HMAC does not match" log spam.** Harmless — the browser has a session cookie encrypted under the previous instance's now-gone secret. Clear cookies or use a private window.
- **Before applying any of this to prod**, add `lifecycle { prevent_destroy = true }` and `force_destroy = false` to `aws_s3_bucket.onevoice_migration` in `s3.tf` — deliberately not added yet since it would block sandbox's destroy/apply test cycles. Migration bucket data must never be destroyable once this matters for real.
- **Trashbin is disabled instance-wide** (`files_trashbin` app) — S3-backed storage deletes crash its move-to-trash step (#28). No undo/trash anywhere on the instance as a result.
