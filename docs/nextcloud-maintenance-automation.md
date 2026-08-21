# OneVoice Nextcloud: MCP Server Setup and Maintenance Automation

Session date: 2026-07-31
Server: OneVoice Nextcloud EC2 instance (`onevoice.knoch.dev`)

## Credit

The MCP server itself is [nextcloud-mcp-server](https://github.com/cbcoutinho/nextcloud-mcp-server) by [cbcoutinho](https://github.com/cbcoutinho). Installation and running followed the project's own docs, particularly [`docs/running.md`](https://github.com/cbcoutinho/nextcloud-mcp-server/blob/master/docs/running.md). All app-level tool access (Notes, Tables, WebDAV, Calendar, Contacts, Cookbook, Deck, News, Mail, Talk, Collectives, Sharing) comes from that project; the work below is the deployment, exposure, and downstream automation built around it.

---

## 1. MCP server: running without Docker

Deployed on the same EC2 box that hosts Nextcloud, using single-user BasicAuth mode (no OAuth, no Docker).

Run directly with `uv`:

```bash
export $(grep -v '^#' .env | xargs)
uv run nextcloud-mcp-server run --log-level info
```

Required in `.env` for BasicAuth mode:

```
NEXTCLOUD_HOST=https://onevoice.knoch.dev
NEXTCLOUD_USERNAME=<username>
NEXTCLOUD_PASSWORD=<app password, generated in Nextcloud Settings > Security>
```

Two additions beyond the defaults, since the plain run otherwise uses ephemeral, unencrypted token storage:

```
TOKEN_STORAGE_DB=/home/ec2-user/nextcloud-mcp-server/data/tokens.db
TOKEN_ENCRYPTION_KEY=<generated below>
```

Encryption key generated with:

```bash
python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"
```

### Persistence: systemd service

`/etc/systemd/system/nextcloud-mcp.service`:

```ini
[Unit]
Description=Nextcloud MCP Server
After=network.target

[Service]
Type=simple
User=ec2-user
WorkingDirectory=/home/ec2-user/nextcloud-mcp-server
EnvironmentFile=/home/ec2-user/nextcloud-mcp-server/.env
ExecStart=/home/ec2-user/.local/bin/uv run nextcloud-mcp-server run --log-level info
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now nextcloud-mcp
```

The server binds to `127.0.0.1:8000` by default and mounts its MCP endpoint at `/mcp` (confirmed from startup logs: `Routes: /user/* with SessionAuth, /mcp with FastMCP OAuth Bearer tokens`).

---

## 2. Exposure: Cloudflare Tunnel

The box already runs `cloudflared` as a token-based tunnel (`ExecStart=/usr/bin/cloudflared --no-autoupdate tunnel run --token-file /etc/cloudflared/token`) for `onevoice.knoch.dev`. Token-based tunnels have no local `config.yml`; ingress rules live in the Cloudflare Zero Trust dashboard instead.

Added a second public hostname on the same tunnel:

- Networks > Tunnels > (the tunnel running on this box) > Public Hostname tab
- Subdomain: `mcp`, Domain: `knoch.dev`
- Service Type: HTTP, URL: `localhost:8000`

No `cloudflared` restart needed; token-based tunnels pick up dashboard changes automatically.

Full client-facing URL: `https://mcp.knoch.dev/mcp` (the `/mcp` path is the server's own endpoint, not something added at the tunnel level).

---

## 3. Claude Desktop connection

`claude_desktop_config.json`:

- macOS: `~/Library/Application Support/Claude/claude_desktop_config.json`
- Windows: `%APPDATA%\Claude\claude_desktop_config.json`
- Linux: `~/.config/Claude/claude_desktop_config.json`

```json
{
  "mcpServers": {
    "nextcloud": {
      "url": "https://mcp.knoch.dev/mcp"
    }
  }
}
```

Restart Claude Desktop fully (quit, not just close window) after editing.

Later renamed and re-added via the `claude mcp` CLI (local, not project-specific):

```bash
claude mcp remove nextcloud -s local
claude mcp add --transport http 1v-nextcloud https://mcp.knoch.dev/mcp
```

Also removed a dead entry in the same session:

```bash
claude mcp remove clixx-k8s   # SSH-based MCP server, connection closed, unreachable
```

Current state (`claude mcp list`):
- `claude.ai Google Drive` — connected
- `1v-nextcloud` — connected (HTTP, `https://mcp.knoch.dev/mcp`)

---

## 4. What the Nextcloud MCP server does not cover

The MCP server only exposes user-facing app tools. No server administration: no `occ`, no app or package updates, no cron or system-level control. That gap is why the maintenance automation below runs over SSH against the box directly, rather than through the MCP server.

---

## 5. Access details for the automation

- SSH user: `ec2-user`
- SSH key (local): `D:\Enoch\workspace\personal\onevoice\onevoice-storage\aws\terraform\keys\nextcloud-key`
- Public IP: dynamic (no Elastic IP), looked up per session:
  ```bash
  aws ec2 describe-instances --profile onevoice \
    --filters "Name=instance-state-name,Values=running" \
    --query "Reservations[].Instances[].{Name:Tags[?Key=='Name']|[0].Value,ID:InstanceId,PublicIP:PublicIpAddress}" \
    --output table
  ```
- AWS profile: `onevoice` (account `622247620719`, region `us-east-1`)
- IAM role attached to the instance: `onevoice-prod-nextcloud-ec2-role`

### Environment quirk

Claude's sandboxed Bash tool has a different `$HOME` than the real Windows/Git Bash session, so it can't see the real `~/.aws/config`, even with `AWS_CONFIG_FILE` and `AWS_SHARED_CREDENTIALS_FILE` set explicitly, and even with the sandbox disabled. Real AWS CLI access requires either running the command directly (`!` prefix) or executing over SSH against a host with its own IAM role, which is how this automation is structured throughout.

---

## 6. First attempt: Anthropic cloud routine (abandoned)

A scheduled `claude.ai` cloud routine ("Nextcloud Monthly Maintenance Reminder") was tried first, intended to SSH in and/or open a PR monthly. Abandoned:

- Giving an unattended cloud routine the real SSH key and AWS credentials would mean storing a long-lived plaintext secret in the routine's stored config, and likely require opening inbound SSH broadly to reach Anthropic's cloud egress IPs. Rejected as disproportionate risk for a monthly checklist.
- Even the git-only version (no SSH) failed: the cloud environment's internal git proxy and GitHub API integration both returned 403s pushing or opening a PR, a GitHub App permissions gap on Anthropic's cloud side for this repo, unresolved.

The routine (`trig_01WxfvY55Hv6Z4TMgJzj9b82`) still exists but is disabled. All real automation now lives on the server itself.

---

## 7. Final architecture: on-server automation

Runs entirely on the EC2 box via a systemd timer. No inbound access needed, no secrets leave the server.

### 7.1 GitHub CLI install

AL2023 doesn't ship `gh` in default repos:

```bash
sudo dnf install -y 'dnf-command(config-manager)'
sudo dnf config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo
sudo dnf install -y gh --repo gh-cli
```

### 7.2 GitHub auth

A fine-grained Personal Access Token, scoped only to `eayanwale/onevoice-storage`:
- Contents: Read and Write
- Pull requests: Read and Write
- Metadata: Read (mandatory)
- Issues: Read and Write

```bash
gh auth login --with-token   # token piped via stdin, never left in shell history
gh auth setup-git            # makes plain `git push` use the same token
```

Token lives only in `~/.config/gh/hosts.yml` (mode 600, `ec2-user` only).

Confirmed fine-grained PAT limitations (tested directly, not assumed):
- Can create, label, and assign pull requests.
- Can create issues with content.
- Cannot set assignees on issues (403 via both GraphQL and REST).
- Cannot add labels to issues after or during creation (403 via REST).
- Cannot close or comment on issues via API (403 via both GraphQL and REST).

This looks like a genuine platform gap in fine-grained PAT support for issue-mutation endpoints, not a scope error (issue creation itself proves Issues:write is granted). Decision: accepted as-is rather than switching to a broader classic PAT. The linked PR auto-closes the issue on merge via GitHub's native `Closes #N` keyword, handled at merge time rather than needing API access. Only the issue's own label badge is cosmetically missing.

### 7.3 The script

`~/scripts/nextcloud-maintenance-check.sh` on the server (mode 700), run by `ec2-user`. Supports `--test` for dry runs on a distinct branch (`maintenance/test-<date>-<time>`, title prefixed `[TEST]`).

Steps, in order:

1. Gather findings (all read-only):
   - Nextcloud core version and `occ update:check`
   - Disk usage (`df -h /`), memory (`free -h`)
   - OS package update count (`dnf check-update`)
   - Kernel vs. latest-installed kernel (reboot-needed check)
   - Cron and backup job presence (user and root crontab)
   - Any exited Docker containers
2. Ensure a `maintenance` label exists on the repo (color `#0E8A16`), creating it if missing.
3. Open a GitHub issue with the findings as its body.
4. Clone `dev` (shallow), branch as `maintenance/<date>`, append findings to `systems/maintenance.md`, commit, push.
5. Open a PR against `dev`: title matches the issue, body starts with `Closes #<issue>`, labeled `maintenance`, assigned to `eayanwale`.
   - `--reviewer eayanwale` deliberately not used: GitHub blocks requesting review from a PR's own author, and since the token authenticates as the user's own account, every PR is self-authored. Assignee is the working substitute.
6. Publish to SNS on both success and failure.

Findings-gathering commands (also useful standalone for manual checks):

```bash
sudo -u nginx php /var/www/nextcloud/occ status
sudo -u nginx php /var/www/nextcloud/occ update:check
sudo -u nginx php /var/www/nextcloud/occ app:list
sudo dnf check-update
uname -r && rpm -q kernel
df -h; free -h
crontab -l; sudo crontab -l
systemctl list-timers --all
sudo docker ps -a --filter "status=exited"
```

### 7.4 Scheduling

`/etc/systemd/system/nextcloud-maintenance.service`:

```ini
[Unit]
Description=Nextcloud monthly maintenance check and PR
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=ec2-user
ExecStart=/home/ec2-user/scripts/nextcloud-maintenance-check.sh
StandardOutput=journal
StandardError=journal
```

`/etc/systemd/system/nextcloud-maintenance.timer`:

```ini
[Unit]
Description=Run Nextcloud maintenance check monthly on the 15th

[Timer]
OnCalendar=*-*-15 13:00:00 UTC
Persistent=true

[Install]
WantedBy=timers.target
```

`13:00 UTC` = 9am America/New_York. `Persistent=true` means a missed run (box off) catches up shortly after boot.

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now nextcloud-maintenance.timer
```

Check status:

```bash
sudo systemctl list-timers nextcloud-maintenance.timer --all
sudo journalctl -u nextcloud-maintenance.service
```

Next real run: 2026-08-15, 13:00 UTC (9am ET).

### 7.5 Notifications: SNS

GitHub does not send notifications for actions performed by the same account that would receive them (self-authored PR, self-assignment). Confirmed by testing, standard GitHub behavior rather than a bug. This also makes Dispatch (the user's iOS GitHub-notification app) unreliable for this specific automation.

Working channel: AWS SNS, publishing to the existing CloudWatch-alarms topic (reused rather than a new one):

```
arn:aws:sns:us-east-1:622247620719:onevoice-prod-ops-alerts
```

Required a one-time IAM grant, done directly in the AWS console (Claude's sandboxed AWS access can't reach the real account): `sns:Publish` on that topic ARN, attached to `onevoice-prod-nextcloud-ec2-role`.

The script publishes on success (`"<title> is ready: PR <url> (tracking issue <url>)"`) and on failure (`"Step failed: <step>. Host <hostname>, <timestamp>. Check the box directly - no PR was opened this run."`).

Delivery confirmed working, with several minutes of lag between `aws sns publish` returning a `MessageId` and the email arriving. Normal SNS-to-email latency, not a fault in the setup.

---

## 8. Testing performed

Multiple `--test` runs validated the full pipeline before trusting the real monthly run, producing test issues and PRs on the real repo (already cleaned up):

- PRs #31, #32, #33, #38
- Issues #34, #36, #37 (some used to isolate the label/assignee API limitation specifically)

Final verified end-to-end run (`~/scripts/nextcloud-maintenance-check.sh --test`) produced, in one pass: a GitHub issue with full findings, a PR referencing and closing it (labeled and assigned), and a confirmed SNS notification email.

---

## 9. Quick reference

```bash
# SSH in (look up current IP first if it's been a while)
ssh -i "D:\Enoch\workspace\personal\onevoice\onevoice-storage\aws\terraform\keys\nextcloud-key" ec2-user@<current-ip>

# Run the maintenance check manually (real run, opens a real PR)
~/scripts/nextcloud-maintenance-check.sh

# Run a safe test (distinct branch/title, still opens real PR/issue - close afterward)
~/scripts/nextcloud-maintenance-check.sh --test

# Check/edit the schedule
sudo systemctl list-timers nextcloud-maintenance.timer --all
sudo nano /etc/systemd/system/nextcloud-maintenance.timer
sudo systemctl daemon-reload && sudo systemctl restart nextcloud-maintenance.timer

# View last run's logs
sudo journalctl -u nextcloud-maintenance.service -n 100

# Rotate the GitHub token
gh auth login --with-token   # paste new fine-grained PAT via stdin

# Check MCP server
sudo systemctl status nextcloud-mcp
sudo journalctl -u nextcloud-mcp -n 100
```