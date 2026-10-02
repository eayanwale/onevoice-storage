# Bluehost VPS audit — pre-containerization

Read-only audit of the live Bluehost host (`cloud.knoch.dev`, `50.6.226.196`) taken
**2026-10-02 14:32 UTC**, ahead of moving Nextcloud from the native install to
Docker Compose. The audit itself changed nothing on the host. The only changes made
since are the pre-migration cleanup in #102 and the `onevoice.env` fix described under
"Risks and oddities" below. Secrets, bucket names and DB credentials are deliberately
omitted, because this repo is public.

## Summary

| Area | Finding |
|---|---|
| OS | AlmaLinux 10.2, kernel 6.12.0-211.47.1.el10_2, up 34 days |
| Hardware | 3 vCPU, 5.8 GiB RAM (≈4.3 GiB available), 2 GiB swap (293 MiB used) |
| Disk | Single 100 GB disk, `/` xfs 99 GB, **21 GB used / 78 GB free** |
| Docker | **Not installed** (no docker-ce, podman or moby) |
| Nextcloud | **30.0.0** (30.0.0.14), not in maintenance, no pending DB upgrade |
| PHP | 8.3.32, php-fpm as `nginx`, unix socket, `pm=dynamic` max 16 children, 512M memory, 2G upload |
| Web server | nginx 1.26.3, one `server` block on `:80`, `server_name _`, `client_max_body_size 2G` |
| Database | MariaDB 10.11.18 on `127.0.0.1:3306`, utf8mb4, READ-COMMITTED, buffer pool 781 MiB, **84 MB** `nextcloud` schema |
| Cache/locking | Valkey 8.0.9 on `127.0.0.1:6379`, used as `memcache.local` **and** `memcache.locking` (no APCu) |
| Background jobs | `cron` mode via `nextcloud-cron.timer` (every 5 min), last run healthy |
| Primary storage | **Local disk**, `/var/www/nextcloud/data`, 12 GB. Objectstore is **not** configured. |
| External storage | One Nextcloud **AmazonS3** mount (not rclone) to Backblaze B2, ~775 GB / 6,037 files |
| Ingress | Cloudflare Tunnel (remotely-managed, token auth) → `http://localhost:80` |
| Mail | Amazon SES SMTP (`email-smtp.us-east-1`, 587/TLS); setup check "Email test was successfully sent" |
| Backups | Nightly restic → dedicated B2 bucket, 08:00 UTC: data dir + `config.php` + DB dump |
| Firewall | firewalld: `ssh`, `dhcpv6-client`, `41641/udp` (Tailscale) only. Port 80 listens on 0.0.0.0 but is not open. |
| SELinux | **Enforcing.** Container bind mounts need `:z`/`:Z` labels. |
| nginx real IP | No `real_ip` config, so nginx sees every request as cloudflared's `127.0.0.1`. The `limit_req` zone (10 r/s, burst 20, keyed on `$binary_remote_addr`) is therefore **one shared bucket for all users**, not per-client. |

## What doesn't match the brief

The brief that kicked off this work describes a few things differently from what is on the host. **These need a decision before the plan is final.**

1. **There is no rclone.** No binary, no `rclone.conf`, no FUSE mounts, no rclone units. The B2 data is reached through Nextcloud's own `files_external` **AmazonS3** backend, which talks to the S3 API directly. That actually makes containerizing simpler: nothing to bind-mount from the host, because the mount config lives in the database and moves with it.
2. **The MCP server isn't on this host.** There's no `nextcloud-mcp` unit, no `uv`, and `mcp.knoch.dev` is **not** in the tunnel's ingress rules. `onevoice.env` has `ENABLE_MCP=false`. It ran on the AWS instance, and per `bluehost/README.md` it was left off because it needs an app password minted from a running instance. The Claude `nextcloud-mcp` connector is currently failing with a Cloudflare 502, which fits.
3. **The maintenance timer isn't on this host either.** `ENABLE_MAINTENANCE_TIMER=false`, and no unit is installed. It was kept off on purpose so the two hosts wouldn't file duplicate monthly PRs. AWS has since been decommissioned, so that reason no longer holds.
4. **The external mount is admin-only and is not read-only.** The mount is `/Enoch-Dropbox`, applicable to user `admin` only, with `readonly=False`. 28 shares point into it, and those shares are how other members see it.
5. **Some services aren't mentioned in the brief or in the repo:**
   - **A third-party log forwarder** (Splunk Universal Forwarder) and a **Tailscale node joined to a tailnet this project doesn't own.** Neither is referenced anywhere in the repo. Both were dealt with before migration work started (#102): the forwarder was removed completely, and Tailscale was logged out but left installed. `tailscale status` had also been reporting an iptables `MARK` module warning.
   - **Grafana + Prometheus + node_exporter.** These *are* in the repo (`ENABLE_MONITORING`). Grafana is published at `grafana.knoch.dev` through the same tunnel. They stay on the host for this migration.

## Storage detail

From `oc_filecache` (file bytes only, directories excluded):

| Storage | Rows | Size |
|---|---|---|
| `amazon::external::<bucket>` (B2 mount) | 6,037 | **775.29 GB** |
| `home::admin` | 241 | 25.59 GB¹ |
| `home::dcole` | 270 | 6.41 GB |
| `home::cgyimah` | 62 | 0.03 GB |
| 9 other homes | 3–5 each | ~0 |
| `local::/var/www/nextcloud/data/` (appdata) | 41,447 | 1.48 GB |

¹ The filecache size includes the external mount's aggregated folder size. On disk, `admin/` is 3.3 GB.

On disk, 12 GB total:

- `dcole/` 6.5 GB, of which **6.5 GB is `files_trashbin`**. Effectively all of that user's data is sitting in the trash.
- `admin/` 3.3 GB: 2.5 GB `files_versions`, 581 MB trashbin.
- `appdata_ock3zaea7uyh/` 1.6 GB, mostly previews (1.5 GB).
- `nextcloud.log` 30 MB, `audit.log` 944 KB.

**Implication:** everything on local disk (12 GB data + 84 MB DB) fits easily on lab-lt-01, so the rehearsal can use a **full** copy. The 775 GB on B2 never has to be copied, because the containerized instance reaches it over the network exactly like the native one does.

## Users and shares

- 12 users.
- `oc_share` rows by type: 2 user shares (type 0), 3 group shares (type 1), 17 per-member rows for those group shares (type 2), and 7 public links (type 3).
- 28 of the share rows point at files on the B2 external mount.

## Database

- 84 MB total. Largest tables: `oc_filecache` 44.5 MB, `oc_activity` 27.6 MB.
- Root has no passwordless socket login. Access is through `DB_ROOT_PASSWORD` in `onevoice.env`.

## Nextcloud configuration (redacted)

- `dbtype=mysql`, `mysql.utf8mb4=true`.
- `memcache.local` and `memcache.locking` = Redis at a host-local address on 6379.
- `trusted_domains`: `50.6.226.196`, `cloud.knoch.dev`, `onevoice.knoch.dev`.
- `overwrite.cli.url=https://onevoice.knoch.dev`, `overwriteprotocol=https`, `trusted_proxies` set.
- `maintenance_window_start=2`, `log_rotate_size=100 MiB`.
- Preview settings: 2048 px max, 50 MB max image; providers include `Movie` (ffmpeg at `/usr/bin/ffmpeg`), `HEIC`, `PDF`, `MSOffice2007`, `Krita` and `Raw`.
- SMTP: SES, port 587, TLS, with auth.

## Apps

There are 58 enabled apps. These matter for the image:

- Non-shipped apps, according to `occ app:list --shipped=false`: `announcementbanner`, `assistant`, `audioplayer` (disabled), `calendar`, `camerarawpreviews`, `contacts`, `deck`, `direct_download`, `external`, `libresign`, `mail` (disabled), `notes`, `passwords`, `theming_customcss`, `whiteboard`, `workflow_media_converter`.
- `libresign` has no Java, pdftk or JSignPdf paths configured, so signing isn't functional today.
- `config/` also holds a custom `mimetypealiases.json`.
- **`direct_download` 0.1.0 is in-house** (issue #93). It lives in `apps/`, not `custom_apps/`, because this install has no `custom_apps`. The official image keeps shipped apps and installed apps in separate directories, so this app needs a deliberate home. Its source is in the repo at `nextcloud-app/direct_download`, but **no script deploys it**: it was copied onto the host by hand.
- `libresign` and `workflow_media_converter` depend on host binaries such as Java/pdftk and ffmpeg. The stock Apache and fpm images don't include them.
- Disabled: `audioplayer`, `encryption`, `mail`, `survey_client`, `suspicious_login`, `twofactor_nextcloud_notification`, `twofactor_totp`, `user_ldap`.

## Nextcloud core is patched on the host

`integrity:check-core` reports:

- `INVALID_HASH lib/private/Files/ObjectStore/S3ObjectTrait.php`. This is the **OneVoice patch from #76**: a 3-attempt retry around the `fopen()` that reads S3 objects. `configure.sh` applies it with `sed` and it was last modified 2026-09-02. **An official image will not have it.** It has to be re-applied in a derived image or an entrypoint hook, or dropped deliberately.
- `EXTRA_FILE done`: an empty marker file in the webroot (2026-08-21), apparently left over from provisioning.

## Health (`occ setupchecks`)

- ✗ Code integrity: the patch above.
- ✗ Whiteboard WebSocket server not configured. Basic whiteboard still works.
- ⚠ No HSTS header.
- ⚠ 18 log errors since 2026-09-25: 17 × "Could not decrypt or decode encrypted session data", 4 × WebDAV `TooManyRequests`, 3 × MariaDB deadlock on a WebDAV query, 1 × `WipeController::checkWipe` null token.
- ℹ No `default_phone_region`.
- Everything else passes: cron, memcache, file locking, DB indices, bigint and utf8mb4 checks, `.well-known`, and the mail test.

## systemd units related to OneVoice

| Unit | State | Runs |
|---|---|---|
| `nextcloud-cron.timer` | enabled, every 5 min | `php -f cron.php` as `nginx` |
| `nextcloud-chunk-cleanup.timer` | enabled, hourly | `/usr/local/sbin/nextcloud-chunk-cleanup.sh` as `nginx` (#89) |
| `nextcloud-backup.timer` | enabled, 08:00 UTC | `/usr/local/sbin/nextcloud-backup.sh` as root |
| `cloudflared.service` | running | token in `/etc/cloudflared/token` (root 0600) |
| `nginx`, `php-fpm`, `mariadb`, `valkey` | running | — |
| `grafana-server`, `prometheus`, `node_exporter` | running, all bound to 127.0.0.1 | — |

There is no `nextcloud-mcp` unit and no maintenance unit.

## Cloudflare Tunnel

The tunnel is token-based, so its ingress rules live in the Cloudflare dashboard, not on the host. Live rules, read from cloudflared's local `/config` endpoint:

| Hostname | Service |
|---|---|
| `cloud.knoch.dev` | `http://localhost:80` |
| `onevoice.knoch.dev` | `http://localhost:80` |
| `grafana.knoch.dev` | `http://localhost:3000` |
| *(catch-all)* | `http_status:404` |

Because the rules are dashboard-managed, cutover doesn't require any Cloudflare change **if** the container is published on `127.0.0.1:80`. Any other port means editing two dashboard rules, which is also the rollback lever.

## Backups

- `nextcloud-backup.sh`: puts Nextcloud in maintenance mode, takes a `mysqldump --single-transaction`, turns maintenance off, then runs `restic backup` of the data dir, `config.php` and the dump to `b2:<backup-bucket>:nextcloud`. Retention is 7 daily, 4 weekly, 6 monthly. The last run, 2026-10-02 08:00 UTC, succeeded (37 s CPU, 2.2 GB peak memory).
- **Not backed up by this job:** the 775 GB on the B2 external mount. It lives only in its B2 bucket, so its safety depends on that bucket's own settings (versioning or lifecycle; not checked here). Also not covered: the nginx/php config and `/etc/onevoice/onevoice.env`, which are reproducible from the repo plus the out-of-band env file.
- `/etc/onevoice/` holds two older env backups (`.bak.1787297260`, `.bak-20260824-030139`).

## Listening sockets

Everything is on loopback except:

- `sshd` on `0.0.0.0:22` / `[::]:22` (open in firewalld).
- nginx on `0.0.0.0:80`. It's **not** open in firewalld (`OPEN_HTTP_PORT=false`), so only the tunnel reaches it. Inside Docker this changes: Docker publishes ports through its own iptables/nft rules, which **bypass firewalld's zone rules**. The compose file must bind to `127.0.0.1` explicitly.
- Tailscale (logged out since #102, so it now has no tailnet addresses).

## Risks and oddities to carry into the plan

1. **`S3_BUCKET` (and the rest of the `S3_*` block) appeared twice in `onevoice.env` with different values.** The first block was an empty placeholder; the second pointed at the real primary-storage bucket, which exists and holds objects. This was **fixed on 2026-10-02**: the empty block was removed, the file was backed up first, and the effective value is unchanged because the second block already won when the file was sourced. The repo's local out-of-band copy of `onevoice.env` is stale on this block.
2. **A primary-storage → B2 objectstore migration is in progress (issue #83).** `bluehost/migrate-primary-storage.sh` exists only as an uncommitted local file, and the objectstore flip hasn't happened. Containerizing and changing the storage backend at the same time would mean two migrations in one window.
3. **Nextcloud 30 is end-of-life** (upstream support ended in 2025), and the host runs 30.0.0, the first release of that branch. Pinning `nextcloud:30.0.0` keeps the data compatible, but it's an old, unpatched image. Upgrading is a separate decision from containerizing.
4. **Docker on AlmaLinux 10 + firewalld + Tailscale.** Docker installs its own nftables/iptables chains. Tailscale is already logging an iptables `MARK` warning, so a third firewall manager needs testing.
5. **Memory headroom is moderate:** 5.8 GiB total, with ~1.5 GiB in use and Grafana, Prometheus, Splunk and Tailscale taking ~500 MiB between them. The backup job peaks at 2.2 GiB.
6. **The scripts are currently the source of truth** (`provision.sh`, `configure.sh`). After containerization, the app layer moves to `docker/`, and the plan has to say what `provision.sh` still owns, so a re-run can't reinstall native nginx/php-fpm on top of the containers.
7. **`dcole`'s 6.5 GB trash** will be auto-expired by `files_trashbin` according to its retention policy. That's worth confirming with the user before cutover, whether or not anything changes.
8. **The session-decrypt errors** in the log usually mean a `secret` or `passwordsalt` mismatch on old cookies. The container **must** reuse the existing `config.php` values (`instanceid`, `secret`, `passwordsalt`). If it doesn't, every session and every encrypted app value (Passwords app, external-storage credentials) breaks.
