# OneVoice Nextcloud on a Bluehost VPS (AlmaLinux 10)

A port of the AWS deployment to a plain VPS. Same Nextcloud, same theming,
same seed users, same Cloudflare Tunnel front door — none of the AWS control
plane.

## Why there is no image to copy

The AMI cannot be moved to Bluehost, for two independent reasons:

1. **`aws ec2 export-image` rejects it.** VM Import/Export refuses images
   derived from AWS-provided Linux AMIs. `nextcloud.pkr.hcl` builds from
   `al2023-ami-*`, so the export is blocked at the licensing check.
2. **Bluehost VPS does not accept custom disk images.** You get their OS
   templates. That is why this box is AlmaLinux 10 and not a booted copy of
   the AMI.

Even with both solved, the AMI is the wrong artifact. Roughly half its value
is AWS-coupled — IMDS instance profile for S3, SSM Parameter Store for every
secret, an RDS endpoint. It would boot and immediately fail.

**The scripts are the portable artifact.** These are refactors of the two that
already build the EC2 host:

| AWS | Bluehost | Role |
| --- | --- | --- |
| `packer/setup.sh` (Packer, bake time) | `provision.sh` | OS, packages, nginx/php config, systemd units. No secrets. |
| `terraform/scripts/user-data.sh` (cloud-init, first boot) | `configure.sh` | Database, `occ maintenance:install`, theming, users. All secrets. |
| SSM Parameter Store + `templatefile()` vars | `/etc/onevoice/onevoice.env` | Configuration and secret input. |

The two-phase split is kept even though a VPS has no bake step: `provision.sh`
needs no credentials and is safe to re-run for OS maintenance, `configure.sh`
holds everything that touches secrets and application state. Both are
idempotent. `bootstrap.sh` runs them in order.

## Current deployment: `cloud.knoch.dev` (50.6.226.196)

The working config lives in `onevoice.env` (gitignored — it holds passwords,
the tunnel token, SMTP and object-storage keys). Shape of it:

| Setting | Value | Why |
| --- | --- | --- |
| Access | `https://cloud.knoch.dev` via Cloudflare Tunnel | TLS terminates at the edge; nginx serves plain HTTP locally, so `trusted_proxies` and `overwriteprotocol=https` are set. |
| Trusted domains | `cloud.knoch.dev` + the raw IP | `configure.sh` deletes and rewrites the array, so this is the exact list. |
| `OPEN_HTTP_PORT` | `false` | The tunnel is outbound-only. **SSH is the only externally reachable port.** |
| Database | local MariaDB, bound to `127.0.0.1` | Not RDS — see below. |
| Primary storage | local disk | Not the B2 bucket — see below. |
| External storage | Backblaze B2 via S3 API | `s3.us-east-005.backblazeb2.com`, region `us-east-005`. |
| Monitoring | Prometheus + node_exporter + Grafana | All bound to loopback; only Grafana gets a tunnel hostname. |
| Outbound email | Amazon SES, `noreply@knoch.dev` | Production access granted; password resets work. |
| MCP / maintenance timer | off | MCP needs an app password minted from a running instance; the maintenance timer is off so two hosts don't file duplicate monthly PRs. |

**Status: functional, not yet carrying the group's data.** Porting from the EC2
instance is deferred until after the OneVoice group meeting on **2026-08-22**.
Until then the AWS deployment remains authoritative and both run in parallel.

**Why the database is local and not RDS.** Your RDS instance holds the
*production* database. Pointing this box at it would not produce a clone — it
would attach a second Nextcloud to prod's `oc_filecache` with a different data
directory, corrupting both. It would also require making RDS publicly
accessible, and Nextcloud issues dozens of queries per page render, so
cross-internet round trips make the UI crawl and you pay egress on each one.

## Install

Clone the repo on the server and `scp` **only** the secrets file. Don't scp
just `bluehost/` on its own — the scripts read siblings outside it:

- `provision.sh` installs from `bluehost/files/` (unit files, `rate-limit.conf`,
  the maintenance script), so that subdirectory must come along;
- `configure.sh` defaults `LOGO_SRC` to `../aws/terraform/assets/logo.png`, which
  lives **outside** `bluehost/`. Copy only `bluehost/` and theming silently
  falls back to name and colour with no logo.

On the VPS:

```bash
sudo dnf install -y git
git clone https://github.com/eayanwale/onevoice-storage.git
cd onevoice-storage/bluehost
```

From your workstation — `onevoice.env` is gitignored, so it is the one file
that has to travel out of band:

```bash
scp onevoice.env root@50.6.226.196:/etc/onevoice/onevoice.env
```

Back on the VPS:

```bash
sudo mkdir -p /etc/onevoice          # if scp failed on a missing directory
sudo chown root:root /etc/onevoice/onevoice.env
sudo chmod 600       /etc/onevoice/onevoice.env

sudo ./bootstrap.sh
```

Then browse to `https://cloud.knoch.dev` — or, before a tunnel exists, to
`http://<SERVER_IP>` with `OPEN_HTTP_PORT="true"` set.

If you would rather not clone on the server, copy from your workstation
instead — you need **both** `bluehost/` and the logo under `aws/`, preserving
their relative positions, because `LOGO_SRC` resolves across them:

```bash
ssh root@50.6.226.196 'mkdir -p /opt/onevoice-storage/aws/terraform/assets'
scp -r bluehost root@50.6.226.196:/opt/onevoice-storage/
scp aws/terraform/assets/logo.png \
    root@50.6.226.196:/opt/onevoice-storage/aws/terraform/assets/
```

Copying the whole repo works too, but drags along `aws/terraform/keys/`, which
holds private keys that have no business on this host.

## Two ways this clone can damage production

Both are guarded in `configure.sh`, but understand them before you edit the
env file.

### Sharing the primary S3 bucket destroys prod file content

A Nextcloud primary object store keys every object as `urn:oid:<fileid>`,
where `<fileid>` is a row id **in that instance's own database**. This clone
starts with an empty database, so it allocates fileid 1, 2, 3… and writes
`urn:oid:1`, `urn:oid:2` — straight over prod's objects. Recovery means S3
version rollback, object by object.

`OBJECT_STORE=local` (the default) makes this structurally impossible. If you
set `OBJECT_STORE=s3`, use a **new, empty bucket**. `configure.sh` refuses any
bucket name containing `prod` unless you also set
`I_UNDERSTAND_SHARED_BUCKET=yes`.

This does **not** apply to `ENABLE_MIGRATION_MOUNT` — external storage
addresses objects by real path, not by fileid, so sharing that bucket is safe.
That is why the Backblaze mount is fine to point anywhere.

### Backblaze: bucket NAME, not bucket ID

The B2 console shows a 24-hex-character bucket **ID** (e.g.
`f3dbc2d8047a262da4040313`). That identifier belongs to B2's native API. The
S3-compatible endpoint addresses buckets by **name** — the human-readable one
you chose at creation — and returns 404 for an ID.

`configure.sh` verifies the mount right after creating it and prints a warning
naming this as the likely cause rather than leaving a mount that just appears
empty in the UI. It warns and continues; Nextcloud still installs. To fix
without a full re-run:

```bash
sudo -u nginx php /var/www/nextcloud/occ files_external:list
sudo -u nginx php /var/www/nextcloud/occ files_external:option <id> bucket <name>
sudo -u nginx php /var/www/nextcloud/occ files_external:verify <id>
```

### Reusing the tunnel token hijacks the prod hostname

A Cloudflare tunnel token identifies a *tunnel*, not a machine. Running the
prod token here registers this VPS as a second replica, and Cloudflare will
round-robin `onevoice.knoch.dev` between the EC2 box and this one — users get
randomly served whichever answers. Create a new tunnel and hostname.

## What changed, and why

### Replaced outright

- **SSM Parameter Store → `/etc/onevoice/onevoice.env`.** All eight
  `aws ssm get-parameter --with-decryption` calls. Root-owned, `0600`.
- **RDS → local MariaDB.** `DB_MODE=local` installs it and writes
  `/etc/my.cnf.d/nextcloud.cnf` with `READ-COMMITTED` + `ROW` binlog, which RDS
  defaulted close enough to that the EC2 build never stated it. The database is
  created `utf8mb4` up front rather than converted later.
- **S3 instance profile → explicit IAM access key.** The EC2 script
  *deliberately* omitted `objectstore arguments key/secret` so the SDK would
  pick up the instance profile from IMDS. There is no IMDS on a VPS, so a key
  is mandatory when `OBJECT_STORE=s3`.
- **`aws ssm put-parameter` for seed-user passwords →
  `/root/onevoice-user-passwords.txt`** (`0600`).
- **`aws s3 cp s3://…/branding/logo.png` → the local repo copy** at
  `terraform/assets/logo.png`.
- **SNS alerting → optional.** With no ambient AWS identity, the maintenance
  script logs instead of publishing unless credentials are present.
- **`ec2-user` → `SERVICE_USER` (default `onevoice`),** created by
  `provision.sh`. The systemd units ship with `__SERVICE_USER__` /
  `__SERVICE_HOME__` placeholders instead of a hardcoded `/home/ec2-user`.
- **Terraform `templatefile()` → plain bash.** The `$${VAR}` escaping that
  `user-data.sh` needed to hide bash variables from Terraform interpolation is
  gone; everything is ordinary `"$VAR"`.

### New, because AlmaLinux is not Amazon Linux

- **SELinux.** The single biggest difference and the one most likely to cost
  you an afternoon. AL2023 boots *permissive*; AlmaLinux 10 boots
  **enforcing**. Without the `semanage fcontext` rules and
  `httpd_can_network_connect` / `_db` / `_memcache` booleans in `provision.sh`,
  nginx cannot read the docroot, php-fpm cannot write `config/`, and every
  outbound S3 call is denied.
- **firewalld.** Runs by default here; absent on AL2023, where inbound
  filtering was the EC2 security group's job — a Terraform resource, not a
  script concern. Left closed by default: Cloudflare Tunnel is outbound-only
  and needs no inbound port. `OPEN_HTTP_PORT=true` opens 80 for raw-IP
  debugging.
- **PHP 8.3 from AppStream, not `php8.2-*`.** AlmaLinux 10 (RHEL 10 rebuild)
  dropped modularity and ships plain `php-*` packages at 8.3, inside Nextcloud
  30's supported 8.1–8.3 range.
- **The stock `nginx.conf` default server is commented out.** AL2023's has no
  such block. Done by brace-counting `awk`, not a `sed` line range — the stock
  block contains nested `location { }` blocks, so a `/server {/,/^\s*}/` range
  terminates on the first nested closing brace and leaves a broken file.
- **Checksum verification on the Nextcloud tarball.** Packer downloaded at
  bake time on a trusted network; this downloads at deploy time.

### Deliberate additions beyond parity

Both are flags, both default on. Turn them off for strict parity.

- **`ENABLE_REDIS`** — distributed file locking and local cache. The EC2 build
  has neither and falls back to DB-backed locking.
- **`ENABLE_CRON_TIMER`** — a systemd timer running `cron.php` every 5 minutes,
  plus `occ background:cron`. The EC2 build leaves background jobs on **AJAX**,
  meaning they only fire when someone loads a page; on a quiet instance file
  scans, share expiry, preview generation and cleanup all stall.

`ENABLE_MAINTENANCE_TIMER` defaults **off**, in the other direction: the EC2
host already runs that timer on the 15th, and enabling it here too means two
hosts opening two near-identical issues and PRs each month. If you do enable
it, branches and titles are tagged with `ENVIRONMENT` so the two are
distinguishable, and the service account gets a scoped
`/etc/sudoers.d/onevoice-maintenance` rather than the blanket NOPASSWD sudo
`ec2-user` had from the AMI.

### Carried over unchanged, including its warts

The nginx server block is byte-identical to the one baked into the AMI, so
this is genuinely a clone. It has two known gaps, present on **both**
deployments and not silently patched here:

- no `.well-known/carddav` + `caldav` redirects — Nextcloud files a setup
  warning, and some DAV clients need them;
- no `fastcgi_param PATH_INFO` — matters for a few app routes.

`files_trashbin` is still disabled, but now only when `OBJECT_STORE=s3`, since
the upstream bug (#28) is a move-to-trash handoff failure specific to object
storage. On local disk the clone keeps working trash.

## Verifying

```bash
sudo -u nginx php /var/www/nextcloud/occ status
sudo -u nginx php /var/www/nextcloud/occ setupchecks
systemctl status nginx php-fpm mariadb valkey cloudflared
systemctl status prometheus grafana-server node_exporter
systemctl list-timers 'nextcloud-*'
sudo cat /root/onevoice-user-passwords.txt

# nothing but SSH should answer on the public IP
ss -tlnp | grep -E ':(3000|9090|9100)\b'   # expect 127.0.0.1 only
firewall-cmd --list-services               # expect: dhcpv6-client ssh
```

If pages load by raw IP but not by hostname, the tunnel is the suspect:
`journalctl -u cloudflared -f`. If you get "HMAC does not match" or a login
that bounces back to the login screen, `trusted_proxies` / `overwriteprotocol`
did not apply — the same failure mode documented in `user-data.sh`.

## Local disk budget (50 GB volume)

Why primary storage is local disk and not B2: **`knoch-nextcloud-storage`
already contains files.** A primary object store is a flat namespace keyed
`urn:oid:<fileid>` from Nextcloud's own database — it has no concept of the
real paths already in the bucket, so every existing file would become
permanently unreadable through Nextcloud. The admin manual: *"Configuring a
primary object store on an existing Nextcloud instance will make all existing
files on the instance inaccessible."* External storage addresses objects by
real path and preserves them, so that is the correct backend here. One bucket
cannot do both — as an object store its contents are opaque blobs, and
mounting that same bucket in the UI would let users delete them.

**The B2 mount does not keep Nextcloud off the local volume.** Fixed cost:

| Component | Approx. |
| --- | --- |
| AlmaLinux 10 base | 2–3 GB |
| nginx, PHP + extensions, MariaDB, Valkey | ~1 GB |
| Nextcloud 30 source (extracted) | ~700 MB |
| Fresh Nextcloud schema | ~60 MB |
| **Total** | **~4–5 GB, leaving ~45 GB** |

Four things then grow on local disk, and the first two are what matter:

1. **Previews — the big one.** Nextcloud renders thumbnails for files *on the
   B2 mount* and caches them locally in
   `data/appdata_<instanceid>/preview`. Rough order: 100–500 KB per previewed
   file across the size variants, so ~50k images is 5–25 GB. `configure.sh`
   caps this (`preview_max_x/y` 2048, skip images over 50 MB, JPEG quality 80).
2. **Chunked upload staging.** Large uploads are assembled in
   `data/<user>/uploads` *before* being written to the destination — including
   uploads destined for B2. So the largest single file anyone can upload is
   bounded by free local disk, regardless of B2 capacity.
3. **`oc_filecache` in MariaDB** — one row per file, including every object on
   the B2 mount after `files:scan`. Roughly 1 KB per file with indexes: 100k
   files ≈ 100 MB, 1M files ≈ 1 GB.
4. **`nextcloud.log`** — capped at 100 MB with rotation by `configure.sh`.

Practical guidance: have people work **inside the mounted folder** so file
content goes to B2. Anything stored elsewhere in Nextcloud consumes the 45 GB.
Watch it with `df -h /` and
`du -sh /var/www/nextcloud/data/appdata_*/preview`.

## EL10 platform facts this depends on

Checked against package metadata rather than assumed, because AlmaLinux 10 is
not a small step from Amazon Linux 2023:

| Thing | Reality on AlmaLinux 10 | Consequence |
| --- | --- | --- |
| PHP | `php` **is 8.3** (10.1 ships 8.3.26); 8.4 is a separately named `php8.4` package, **not** a module stream — EL10 has no DNF modules at all | `dnf install php` lands in Nextcloud 30's supported range. Do not add `php8.4`. |
| zip extension | `php-pecl-zip` (1.22.3-5.el10). A plain `php-zip` exists on Mageia/OpenMandriva but **not** on EL | Several popular guides say `php-zip`; they are wrong for EL. |
| curl extension | bundled in `php-common`, no separate `php-curl` | Same guides list `php-curl`, which does not resolve. |
| Redis | **removed.** Redis Labs left open source at 7.4 (RSALv2/SSPLv1), so EL10 ships **Valkey** | `dnf install redis` fails outright. Valkey is wire/command/on-disk compatible, so the PHP client and `\OC\Memcache\Redis` are unchanged. |
| MariaDB | 10.11 in AppStream as `mariadb-server` | `mysql.user` is a non-updatable view (10.4+), so classic hardening snippets using `DELETE FROM mysql.user` fail. |
| SELinux | **enforcing** (AL2023 is permissive) | Without the fcontext rules and `httpd_can_network_*` booleans, nginx cannot read the docroot and php-fpm cannot write `config/`. |
| firewalld | present and running (absent on AL2023) | Inbound filtering was the EC2 security group's job; here it is a host concern. |

Rather than trusting any package name, `provision.sh` verifies the **loaded
extensions** after install (`php -m`), attempts one automatic repair under both
naming conventions, and fails with the specific missing list plus the
`dnf provides '*/<ext>.so'` command to resolve it.

## Remaining risks on first run

**1. The 50 GB local volume.** See the budget below — the B2 mount does *not*
keep Nextcloud off local disk, and previews are the thing that will fill it.

**2. Bluehost's own network firewall.** `provision.sh` opens 80/tcp in
firewalld, but some VPS products also filter upstream in the control panel. If
the box answers `curl localhost` but not the public IP, that's where to look.

**3. `php-pecl-imagick`** is best-effort (EPEL on EL10). Nextcloud runs without
it — admin warning only.

**4. Valkey not running.** `configure.sh` checks both that the PHP redis
extension loaded *and* that something answers on 127.0.0.1:6379 before setting
`memcache.locking`. Pointing file locking at a dead cache server fails every
request, turning "slower without caching" into "completely unreachable".

These scripts have not been run against a live AlmaLinux 10 host.
