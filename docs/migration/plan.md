# Containerization plan: Bluehost native install → Docker Compose

**Status: approved by the owner on 2026-10-02.** Phase 3 (build and lab rehearsal) can start. Phase 4 (production cutover) still needs a second, separate go-ahead.

Tracking: #103. Based on the host audit in [`audit.md`](audit.md) (2026-10-02).

## Goals and non-goals

**Goals**
- Run the same Nextcloud (**exactly 30.0.0**, same apps, same data, same database) in Docker Compose on the same VPS.
- Keep it reachable only through the existing Cloudflare Tunnel.
- Keep the native install stopped but intact as a fallback for at least 7 days.

**Non-goals** (each is a deliberate later phase; see [Later phases](#later-phases))
- Any Nextcloud version upgrade.
- The primary-storage move to B2 (#83). It's **paused** until after containerization.
- The MCP server and the monthly maintenance timer.
- Containerizing monitoring (Grafana, Prometheus, node_exporter).

Two things the brief assumed turned out not to exist on this host:
- **`mcp.knoch.dev` is currently broken.** The MCP server still lives on the decommissioned AWS instance, and the hostname isn't in this host's tunnel ingress, so Cloudflare returns a 502. This migration doesn't fix it; the follow-up phase does.
- **There are no rclone mounts.** The B2 data is a Nextcloud `files_external` AmazonS3 mount whose configuration lives in the database.

## Target architecture

```
                   Cloudflare edge
                         │  (tunnel, outbound-only)
┌────────────────────────┼──────────────────────────────────────────────┐
│ VPS host               ▼                                              │
│   cloudflared (host, unchanged) ──► 127.0.0.1:80 ──┐                  │
│                                 └─► 127.0.0.1:3000 grafana (host)     │
│   prometheus / node_exporter (host, unchanged)     │                  │
│   restic backup timer, chunk-cleanup timer (host)  │                  │
│ ┌──────────────── docker compose project "onevoice" ┼───────────────┐ │
│ │  frontend net                                     ▼               │ │
│ │                      web (nginx 1.26) ──fastcgi──► app (fpm)      │ │
│ │                                                    │   ▲          │ │
│ │  backend net (internal: no egress)                 │   │          │ │
│ │                 db (MariaDB 10.11) ◄───────────────┤   │          │ │
│ │                 valkey (8.0)       ◄───────────────┘   │          │ │
│ │                 cron (same image as app, /cron.sh) ────┘          │ │
│ └───────────────────────────────────────────────────────────────────┘ │
│   /srv/onevoice/…   bind-mounted state (data, config, apps, db)       │
└───────────────────────────────────────────────────────────────────────┘
        app ──► B2 (external-storage mount), SES SMTP, appstore (egress)
```

| Service | Image | Why |
|---|---|---|
| `app` | `onevoice/nextcloud:30.0.0-fpm-ov1`, built `FROM nextcloud:30.0.0-fpm` | Same version as production, fpm like today. The custom layer carries the #76 patch and the extra packages listed below. |
| `web` | `nginx:1.26-alpine` | Same major/minor as the host. It reuses the production server block from `provision.sh` almost byte-for-byte, including the #101 static-types fix, the `limit_req` zone and the `.well-known` rules. Using the `-apache` image would mean re-deriving all of that. |
| `db` | `mariadb:10.11` (pinned to the patch release in `.env`) | Same engine and series as production (10.11.18). There's no reason to switch to Postgres: it would mean a cross-engine conversion of a working database for no gain. |
| `valkey` | `valkey/valkey:8.0` | Same as the host (8.0.9). Used for memcache and file locking. No persistence; it's a cache. |
| `cron` | same image as `app`, `entrypoint: /cron.sh` | The official pattern. Busybox crond runs `cron.php` every 5 minutes as `www-data`, replacing `nextcloud-cron.timer`. |
| `cadvisor` *(optional, compose profile `metrics`)* | `gcr.io/cadvisor/cadvisor` | Per-container CPU and memory for the existing Prometheus. Bound to `127.0.0.1:8081` only and off by default. It's one service plus one scrape job, which is cheap, so it's included. It gets enabled a week after cutover once things are stable. |

There's **no extra reverse proxy**. cloudflared already terminates TLS at Cloudflare's edge and forwards plain HTTP to `localhost:80`, so the `web` container takes over exactly that address.

### The custom `app` image (`docker/nextcloud/Dockerfile`)

- **`FROM nextcloud:30.0.0-fpm`**. Tags are pinned, and the digest is recorded in `.env.example` after the rehearsal.
- **#76 patch.** `COPY` the patched `lib/private/Files/ObjectStore/S3ObjectTrait.php` over the image's `/usr/src/nextcloud` copy. Before copying, a `RUN` step checks the sha256 of the upstream file it's replacing, so the build **fails loudly** if the base image's file has changed, for example after a version bump. That failure is the cue to check whether upstream has fixed the retry problem and the patch can go. The Dockerfile comment links to #76. `integrity:check-core` will keep reporting this one file as `INVALID_HASH`, exactly as it does today, and that's expected.
- **Extra packages.** `ffmpeg` is required, because `preview_ffmpeg_path=/usr/bin/ffmpeg`, the Movie preview provider and `workflow_media_converter` all use it. Also the PHP extension `bz2`. Anything else an enabled app's `info.xml` requires that is missing from the image gets added during the rehearsal: compare `php -m` on the host with `php -m` in the container.
- **PHP settings** match the host: `memory_limit=512M`, `upload_max_filesize`/`post_max_size=2G`, `max_execution_time=3600`, and opcache `interned_strings_buffer=16`, `max_accelerated_files=10000`, `memory_consumption=128`, `revalidate_freq=60`. They're applied with `PHP_MEMORY_LIMIT`/`PHP_UPLOAD_LIMIT` plus a mounted `zz-onevoice.ini`.
- **fpm pool:** `pm=dynamic`, `max_children=12`, down from 16 to fit the memory limit (see [Resource limits](#resource-limits)), `start_servers=4`, `min/max_spare=4/8`.

### Where the `direct_download` app lives

`direct_download` goes in as a **read-only bind mount from the repo**: `nextcloud-app/direct_download` is mounted at `/var/www/html/custom_apps/direct_download:ro`. It isn't baked into the image. The reasons:

- The official entrypoint copies code from the image into `/var/www/html` only on first start and on version upgrades, so anything baked into the image wouldn't reliably reach the running tree.
- Today no script deploys this app at all; it was copied onto the host by hand. With the bind mount, the deployed copy is always the checked-out repo: `git pull`, then `docker compose restart app cron`.
- It's not on the app store, so the in-app updater never tries to replace it. Read-only enforces that.

Every other non-shipped app (`announcementbanner`, `assistant`, `calendar`, `camerarawpreviews`, `contacts`, `deck`, `external`, `libresign`, `notes`, `passwords`, `theming_customcss`, `whiteboard`, `workflow_media_converter`, plus the disabled `audioplayer` and `mail`) is **copied at its current version** from the native `apps/` directory into `custom_apps/` during migration. That way no app version changes as a side effect of the move.

## What runs in containers and what stays on the host

| Component | Where | Reasoning |
|---|---|---|
| Nextcloud (fpm), nginx, MariaDB, Valkey, cron | **Containers** | This is the migration. |
| cloudflared | **Host, unchanged** | Its ingress rules are managed in the Cloudflare dashboard and point at `localhost:80` and `localhost:3000`. If the `web` container publishes `127.0.0.1:80`, cutover needs **no Cloudflare change at all**, and rollback is just swapping which process owns port 80. In a container it would need host networking to keep reaching Grafana, which gains nothing, and the tunnel token would have to move into compose. |
| Grafana, Prometheus, node_exporter | **Host, unchanged** | Your decision; containerizing monitoring is a later step. `grafana.knoch.dev` is untouched. |
| restic backup (`nextcloud-backup.timer`) | **Host**, script updated | It backs up host paths and needs root, the B2 credentials and the env file. It reaches into the containers with `docker compose exec`. |
| Stale-chunk cleanup (`nextcloud-chunk-cleanup.timer`) | **Host**, path updated | It's a plain `find`/`rm` over `uploads/` directories, so it works fine against the bind-mounted data dir. It switches from user `nginx` to the container's uid 33. |
| MCP server | **Neither, for now** | It isn't on this host. Deferred to a follow-up phase. |
| Monthly maintenance timer | **Neither, for now** | It isn't installed here (`ENABLE_MAINTENANCE_TIMER=false`). Deferred to a follow-up phase. It would need rewriting anyway, because it calls `occ` on the host. |
| rclone | **n/a** | There isn't any. The B2 mount travels inside the database. |
| Tailscale | Host, logged out (#102) | You'll rejoin it to your own tailnet. Docker's nftables chains and Tailscale's need a coexistence check during the rehearsal. |

## Volumes and where data lives

Everything stateful is a **bind mount under `/srv/onevoice/`**, never an anonymous volume. That keeps it visible to restic, `du` and `ls`, and it means `docker compose down -v` can't destroy it. SELinux is enforcing, so each mount gets `:z` (shared) or `:Z` (private) as noted.

| Host path | Container path | Contents | Backed up |
|---|---|---|---|
| `/srv/onevoice/nextcloud/html` | `app`, `cron`, `web`(ro): `/var/www/html` | Nextcloud code, populated by the image entrypoint | No. It's reproducible from the image. |
| `/srv/onevoice/nextcloud/config` | `/var/www/html/config` | `config.php` (secrets), `apps.config.php`, `mimetypealiases.json` | **Yes** |
| `/srv/onevoice/nextcloud/custom_apps` | `/var/www/html/custom_apps` | Apps copied from the native install | **Yes** |
| repo `nextcloud-app/direct_download` | `…/custom_apps/direct_download` (ro) | In-house app | It's in git |
| `/srv/onevoice/nextcloud/data` | **`/var/www/nextcloud/data`** | User files, appdata, trash, versions, logs | **Yes** |
| `/srv/onevoice/mariadb` | `/var/lib/mysql` (`db`) | Database files | Via a dump, not the raw files |
| repo `docker/nginx/` | `/etc/nginx/conf.d` (ro, `web`) | Server block | It's in git |

**The data dir keeps its native path *inside* the container: `/var/www/nextcloud/data`, not the image default `/var/www/html/data`.** The appdata storage's ID in `oc_storages` is literally `local::/var/www/nextcloud/data/`. If `datadirectory` changed, Nextcloud would treat appdata as a brand-new storage, orphan 41,447 filecache rows and regenerate previews and theming. Keeping the path means `config.php`'s `datadirectory` and every storage ID stay exactly as they are. User homes are `home::<user>` and don't depend on the path, but they keep working either way.

**Ownership.** The container runs as `www-data` (uid 33). The native install owns files as `nginx` (uid 994). The migration **copies** data with `rsync` and sets ownership to `33:33` on the copy. Nothing under `/var/www/nextcloud` is touched, which is what keeps rollback trivial.

**The external storage mount (B2) needs nothing on the host.** Its configuration (bucket, endpoint, encrypted credentials) lives in `oc_external_*`, which arrives with the database dump. The `app` container reaches `s3.us-east-005.backblazeb2.com` through the `frontend` network's normal egress. The credentials are encrypted with `config.php`'s `secret`, which is another reason `config.php` must carry over unchanged.

**Disk budget.** Today 21 GB is used and 78 GB is free. The migration adds about 13 GB (12 GB data copy, 0.3 GB DB, about 1.2 GB code, about 1 GB images), leaving about 64 GB free while both copies exist. The native data copy can be freed after the 7-day fallback window, with a separate approval.

## Secrets

Nothing secret is committed. `.gitignore` covers `docker/.env`, `docker/secrets/`, any `config.php`, any `*.sql*` and anything under `/srv`.

| Secret | Lives in | Used by |
|---|---|---|
| MariaDB root password | `/etc/onevoice/secrets/db_root_password` (root, 0600) | `db` via a compose `secrets:` entry, read through `MARIADB_ROOT_PASSWORD_FILE` |
| MariaDB app password | `/etc/onevoice/secrets/db_password` (root, 0600) | `db` (`MARIADB_PASSWORD_FILE`), backup script |
| Nextcloud's own secrets (`secret`, `passwordsalt`, `instanceid`, `dbpassword`, SMTP password) | `config.php`, carried over **unchanged** | `app`, `cron` |
| B2 backup keys, restic password | `/etc/onevoice/onevoice.env` (as today) | Host backup script only |
| Tunnel token | `/etc/cloudflared/token` (as today) | Host cloudflared only |

The secret files are generated from the existing `onevoice.env` values, so **no password changes as part of the migration**. If you decide to rotate credentials after #102, that's a separate step done **before** cutover, so each change can be verified on its own.

`docker/.env` (from `.env.example`) holds only non-secret settings: image tags and digests, the `/srv/onevoice` root, resource limits and the published bind address.

Valkey gets no password. It sits only on the `internal: true` backend network, which no other service can reach and which can't reach the internet, same as today's loopback-only Valkey.

## Ports

| Published | Service | Notes |
|---|---|---|
| `127.0.0.1:80:80` | `web` | The only published port. cloudflared reaches it at `localhost:80`. |
| `127.0.0.1:8081:8080` | `cadvisor` (profile `metrics`, off by default) | Scraped by the host Prometheus. |

Nothing is published on `0.0.0.0`. The `db` and `valkey` services publish nothing at all.

Docker inserts its own nftables/iptables rules, and those **bypass firewalld zones**. That means the `127.0.0.1:` prefix is the real control, not firewalld. The verification checklist includes `ss -tlnp` and an external probe of port 80 from outside the VPS, which must fail.

**Real client IPs.** Today nginx sees every request as `127.0.0.1` (cloudflared), so the `limit_req` zone is one bucket shared by all users. In Docker it would see the Docker bridge gateway instead, which is the same behavior with a different IP. The plan **keeps that behavior identical** for the migration and only extends `trusted_proxies` to include the compose subnet, so Nextcloud keeps reading `X-Forwarded-For` correctly. Making rate limiting per-client, by trusting `CF-Connecting-IP` with `real_ip`, is a follow-up, not part of this change.

## Resource limits

The VPS has 3 vCPU and 5.8 GiB RAM plus 2 GiB swap. Things that stay on the host use about 0.6 GiB (Grafana, Prometheus, node_exporter, cloudflared, tailscaled, sshd, system), and the nightly restic run peaks at 2.2 GiB. The limits below are ceilings, not reservations. Typical use today is about 1.5 GiB.

| Service | `mem_limit` | `cpus` | Notes |
|---|---|---|---|
| `app` | 2 GiB | 2.0 | 12 fpm children × about 120 MiB, plus opcache |
| `cron` | 768 MiB | 1.0 | Background jobs plus preview generation (ffmpeg, imagick) |
| `db` | 768 MiB | 1.0 | `innodb_buffer_pool_size=384M`, down from 781 MiB; the whole database is 84 MB |
| `valkey` | 192 MiB | 0.5 | `maxmemory 128mb`, `allkeys-lru`. Today it uses 1.7 MiB. |
| `web` | 128 MiB | 0.5 | |
| `cadvisor` | 192 MiB | 0.3 | Only when the `metrics` profile is on |
| **Total ceiling** | **about 3.9 GiB** | | Leaves about 1.9 GiB plus swap for the host and the backup peak |

The backup script also gets `GOMAXPROCS=1` and runs under `systemd-run -p MemoryHigh=1.5G`, so the nightly restic peak can't push the containers into swap. These limits are tuned with measurements from the rehearsal.

## Backups

**Before cutover** there are three independent copies, each verified:
1. A restic snapshot from the **existing** nightly script, run by hand inside the maintenance window. Its snapshot ID is recorded.
2. A local `mysqldump` at `/root/pre-cutover-YYYYMMDD/nextcloud.sql.gz`, plus a tar of the native `config/` and `apps/`.
3. The native install itself, stopped and intact for at least 7 days.

**After cutover**, `nextcloud-backup.sh` is updated in the repo and on the host, and keeps the same timer, B2 bucket, restic repo and retention:
- Maintenance mode on: `docker compose exec -T -u www-data app php occ maintenance:mode --on`.
- `docker compose exec -T db mariadb-dump --single-transaction …`, written to a temp file.
- Maintenance mode off.
- `restic backup /srv/onevoice/nextcloud/{config,custom_apps,data}`, the dump, and `docker/.env`. The `/etc/onevoice/secrets/*` files aren't included: they're regenerated from `onevoice.env`, which lives out of band as today.
- Same `--keep-daily 7 --keep-weekly 4 --keep-monthly 6`.
- It runs once **immediately after cutover**, and that snapshot gets restore-tested on lab-lt-01 within the 7-day window.

The repository keeps native-layout snapshots alongside docker-layout snapshots. Retention ages the native ones out on its own. They're tagged differently (`nextcloud-nightly` vs `nextcloud-docker`) so restores pick the right layout.

**Still not covered, as today:** the 775 GB in the B2 external bucket. Its protection is B2 bucket versioning and lifecycle, which the audit didn't check. A separate look is recommended, but it's out of scope here.

## Rehearsal on lab-lt-01 (Phase 3, summary)

1. **Source is the restic backup, not live production.** Restore the latest nightly snapshot onto lab-lt-01. This tests the real disaster-recovery path, puts no load on prod, and the snapshot already holds exactly what the migration consumes: the data dir, `config.php` and the DB dump. Everything local fits (about 12 GB).
2. Run the same `docker/scripts/migrate-from-native.sh` that production will use, with timing for each step.
3. **Lab safety guards**, applied to the lab copy's database **before** the first `up`:
   - Set the B2 external mount `readonly=true`, because the lab must not be able to delete or modify the real bucket.
   - Rewrite every user email except a test account's to `@example.invalid`, so no real member gets mail from the lab.
   - Point `trusted_domains` and `overwrite.cli.url` at the lab URL.
   - Keep the cron container stopped until the guards are verified.
4. Verify the checklist below. That includes the password-reset email through SES to your own address, and a restic restore of a **docker-layout** snapshot into a clean directory, then booting from it.
5. Fold the timings and lessons into this plan.
6. Afterwards, wipe the lab copy of the member data, or keep it at your discretion.

The brief's check that "the MCP server can reach the containerized Nextcloud" is **deferred** with the MCP phase.

## Cutover runbook (Phase 4)

All commands run as root on the VPS from `/opt/onevoice-storage/docker`, a git checkout of the release tag. `NC_NATIVE="sudo -u nginx php /var/www/nextcloud/occ"` and `NC="docker compose exec -T -u www-data app php occ"`.

**Estimated user-visible downtime: about 20–30 minutes** (to be refined from rehearsal timings). Announce a 60-minute window to the group, outside the 02:00–08:00 UTC maintenance window and away from the 08:00 UTC backup.

### Standing rules (owner, 2026-10-02): they apply to every step below and to rollback

1. **No changes to any member's account.** Nobody's password, 2FA, email or account state (enabled/disabled, groups, quota) is changed without the owner's explicit approval. That applies even on a rehearsal copy, and even for testing. A test that needs to log in uses a **dedicated test user** (`cutover-test`), created for the test and deleted afterwards.
2. **No test email to members.** Any test mail goes only to the owner's own address. On any non-production copy, outbound mail is switched off (`mail_smtpmode=null`). Removing members' email addresses isn't enough on its own, because calendar events carry attendee `mailto:` addresses.

Both rules are enforced as explicit checks: **A1–A3** and **E1–E2** in the T0 table, plus the last two items of the verification checklist.

### T-1 day: preparation (no user impact)
1. Install docker-ce and the compose plugin from Docker's EL repo. Confirm sshd, cloudflared and firewalld still behave: `firewall-cmd --list-all`, an external SSH check, and the tunnel's connections in the dashboard.
2. Clone or update the repo at `/opt/onevoice-storage` and check out the release tag. Build the image: `docker compose build app`. Pull the other images.
3. Create `/srv/onevoice/{nextcloud/{html,config,custom_apps,data},mariadb}` and `/etc/onevoice/secrets/` (0700). Generate the secret files from `onevoice.env`.
4. **Pre-seed the data:** `rsync -aHAX --numeric-ids /var/www/nextcloud/data/ /srv/onevoice/nextcloud/data/` while prod runs. It's about 12 GB, local to local, and only the delta gets redone at T0.
5. Run the backup once by hand (`systemctl start nextcloud-backup.service`) to confirm it's healthy the day before.

### T0: cutover
| # | Step | Command / check |
|---|---|---|
| A1 | **Account baseline (rule 1)** | On native, record a fingerprint of every account's state: `SELECT uid, MD5(password) FROM oc_users`, plus `oc_preferences` rows for `settings/email` and `core/enabled`, plus `oc_twofactor_providers`. Store it under `/root/pre-cutover-*/accounts.tsv` (root, 0600; hashes of hashes only). |
| 1 | Stop native background work | `systemctl disable --now nextcloud-cron.timer nextcloud-chunk-cleanup.timer nextcloud-backup.timer`; wait for any running `cron.php` to exit (`pgrep -f cron.php`). |
| 2 | **Full backup #1 (restic)** | `systemctl start nextcloud-backup.service`. The native script turns maintenance mode on for its DB dump and **off again when it finishes**, which is why this runs *before* step 3. Record the snapshot ID: `restic snapshots --latest 1`. |
| 3 | Maintenance mode on (native); the outage starts here | `$NC_NATIVE maintenance:mode --on`. Anything written between steps 2 and 3 is captured by steps 4 and 5. |
| 4 | **Full backup #2 (local, exact final state)** | `mysqldump --single-transaction … \| gzip > /root/pre-cutover-$(date +%F)/nextcloud.sql.gz`; `tar czf …/native-config-apps.tgz -C /var/www/nextcloud config apps`. Check `gunzip -t` and sizes. This dump is the one restored in step 8. |
| 5 | Final data sync | `rsync -aHAX --delete --numeric-ids /var/www/nextcloud/data/ /srv/onevoice/nextcloud/data/`, then `chown -R 33:33 /srv/onevoice/nextcloud/data` |
| 6 | Config and apps | `docker/scripts/migrate-from-native.sh config`: copies `config.php` and `mimetypealiases.json`, writes `apps.config.php`, and rewrites `dbhost→db`, `redis.host→valkey`, `trusted_proxies` += compose subnet. It leaves `maintenance` true and every secret byte-identical. It then copies the non-shipped apps into `custom_apps/` (excluding `direct_download`, which is bind-mounted). |
| 7 | Start DB and cache | `docker compose up -d db valkey`; wait for healthy |
| 8 | Restore DB | `gunzip -c …/nextcloud.sql.gz \| docker compose exec -T db mariadb -u nextcloud -p"…" nextcloud`; compare row counts of `oc_filecache`, `oc_share`, `oc_users` and `oc_external_mounts` against native. |
| 9 | **Stop native stack** (frees `:80`) | `systemctl disable --now nginx php-fpm mariadb valkey`. These are disabled so a reboot can't reclaim port 80. Packages, files and data stay in place. |
| 10 | Start app, web, cron | `docker compose up -d app web cron`; the entrypoint populates `html/` from the image (the #76 patch arrives this way) |
| 11 | In-container checks (still in maintenance) | `$NC status` (expect 30.0.0.14, no upgrade needed); `$NC app:list` diffed against the native list; `$NC integrity:check-core` (expect only the #76 file plus the image's `nextcloud-init-sync.lock`). Run `$NC setupchecks`. The external-storage check (`migrate-from-native.sh check-external`) needs maintenance **off**, so it moves to step 12. Never run `files_external:list` unfiltered. |
| A2 | **Account state unchanged (rule 1)** | Recompute the A1 fingerprint against the container DB and `diff` it with `accounts.tsv`. It must be **identical**. Any difference is a no-go. |
| E1 | **Mail recipients before mail can flow (rule 2)** | The SMTP settings in `config.php` are production's (SES). Nothing in this runbook sends a test message except E2. Check that `oc_activity_mq` holds only normal member notifications queued during the outage. Those are production behaviour, not test mail. List them by count only. |
| 12 | Maintenance off | `$NC maintenance:mode --off`, then `migrate-from-native.sh check-external` |
| 13 | Verify end-to-end | Run the [checklist](#verification-checklist) through `https://onevoice.knoch.dev` |
| E2 | **The only test email (rule 2)** | Create `cutover-test` with `OC_PASS=… $NC user:add --password-from-env`, then set its email to **the owner's own address only**. Request a password reset for `cutover-test`, then confirm with the owner that it arrived. No other test mail is sent. |
| A3 | **Clean up the test user, re-check accounts (rule 1)** | `$NC user:delete cutover-test`; re-run the A2 diff. It must still be identical, with `cutover-test` absent from both. |
| 14 | Host timers back on | Install the updated `nextcloud-backup.sh` and `nextcloud-chunk-cleanup.sh`; `systemctl enable --now nextcloud-backup.timer nextcloud-chunk-cleanup.timer`; run one backup now and record the snapshot ID. |
| 15 | Announce done | |

**Go/no-go points:** after step 8 (DB row counts match), after step 11 (all in-container checks pass) and after step 13. A failure at any of these goes to rollback, not to improvising.

### Verification checklist
- [ ] `https://onevoice.knoch.dev` and `https://cloud.knoch.dev` load, and the theming is intact
- [ ] The owner logs in as themselves, and a member logs in **themselves** if one is available; nobody's credentials are touched. Existing sessions and app passwords keep working (desktop client on macOS, mobile). Automated login and WebDAV tests use `cutover-test` only.
- [ ] File counts and sizes per user match the native `oc_filecache` numbers; a sample of files opens and downloads, including a video (#101) and a PDF
- [ ] All 29 share rows are present; a sample public link opens logged out; a group share is visible to a member
- [ ] The B2 mount `/Enoch-Dropbox` lists, opens a file and uploads and deletes a scratch file (prod only, not lab)
- [ ] Upload a file larger than 100 MB (chunked) through the web UI
- [ ] Background jobs: `occ setupchecks` shows "Cron last run" under 10 minutes, and `oc_jobs` is advancing
- [ ] Step E2: the password reset for `cutover-test` (owner's address) arrives through SES
- [ ] `direct_download` redirect behaves as before (#93 test procedure)
- [ ] Admin overview: no new errors compared with the audit baseline (the #76 integrity entry, the whiteboard WebSocket note and missing HSTS are known and accepted)
- [ ] `ss -tlnp`: only `127.0.0.1:80` published by Docker; `curl -m5 http://50.6.226.196/` from outside the VPS **fails**
- [ ] `grafana.knoch.dev` still works
- [ ] The new backup ran and its snapshot shows the docker layout
- [ ] **Rule 1:** the A3 account diff is identical, and `cutover-test` no longer exists
- [ ] **Rule 2:** the only test email sent during the cutover went to the owner's address (step E2)

### Rollback procedure (back to native)

Use this when a go/no-go check fails, or at any point within 7 days.

**A. Fast rollback, discarding post-cutover changes.** This is right during the cutover window, before users have written anything.
1. `docker compose down`. Volumes are bind mounts and survive.
2. `systemctl enable --now mariadb valkey php-fpm nginx`
3. `systemctl enable --now nextcloud-cron.timer nextcloud-chunk-cleanup.timer nextcloud-backup.timer`
4. `$NC_NATIVE maintenance:mode --off`
5. If anything was written to the B2 mount through the container, run `$NC_NATIVE files:scan --path="admin/files/Enoch-Dropbox"` so the native filecache sees it.
6. Verify the checklist against native.

Estimated time: about 5 minutes. The tunnel needs no change.

**B. Rollback keeping post-cutover changes.** This is for days 1–7, after members have used the containers.
1. Maintenance on in the container, then dump the container's DB.
2. `docker compose down`
3. Restore that dump into the native MariaDB. Start `mariadb` alone first, and dump the native DB to a file before overwriting it.
4. `rsync -aHAX --delete /srv/onevoice/nextcloud/data/ /var/www/nextcloud/data/`, then `chown -R nginx:nginx`.
5. Copy back only the `config.php` keys that changed in the container, normally none, keeping the native `dbhost`, `redis` and `datadirectory`.
6. Native steps A2–A6.

Estimated time: about 20 minutes.

The native install is **not decommissioned** after 7 days without an explicit, separate approval. Even then, decommissioning means disabling packages, and the native data copy is deleted only on your say-so.

## Keeping the scripts the source of truth

The scripts stay authoritative, but what they own changes:
- **`provision.sh`** gains `NEXTCLOUD_RUNTIME=native|docker` (default `native`, so nothing changes until cutover).
  - With `docker`, it installs docker-ce, keeps OS/firewall/monitoring/cloudflared as today, and **disables** rather than installs the native nginx/php-fpm/mariadb/valkey units. That way a re-run after cutover can't reclaim port 80.
  - It also installs the host timers in their docker-aware form.
- **`configure.sh`** stays the native path. The docker equivalents are `docker/scripts/` (`migrate-from-native.sh`, `backup.sh`, `restore.sh`) and the compose file itself.
- **The #76 patch** moves from a `sed` in `configure.sh` to the Dockerfile.
- **Parity note.** The AWS target is decommissioned, so there's no third target to keep in step. `aws/` isn't touched.

## Risks and mitigations

| # | Risk | Mitigation |
|---|---|---|
| 1 | Data loss during the move | The native data is **never modified** (copy, not move). There are three backups before cutover. A rehearsal is required first. |
| 2 | `config.php` secrets drift, so sessions, the Passwords app and the B2 mount credentials break | `config.php` is copied, and only `dbhost`, `redis.host` and `trusted_proxies` are rewritten, by a script whose diff is reviewed in the rehearsal. `secret`, `passwordsalt` and `instanceid` are byte-identical, and a checksum is compared. |
| 3 | The appdata storage ID changes, orphaning previews and appdata | The data dir is mounted at its native path inside the container (see [Volumes](#volumes-and-where-data-lives)). |
| 4 | The lab rehearsal deletes or modifies real B2 data, or emails real members | The lab safety guards: read-only mount, rewritten emails, cron held until verified. |
| 5 | Docker's firewall rules expose a port publicly, or conflict with firewalld or Tailscale | Explicit `127.0.0.1` binds and an external probe in the checklist. Docker, firewalld and Tailscale coexistence is checked in the rehearsal and again at T-1. |
| 6 | SELinux denies container access to the bind mounts | `:z`/`:Z` labels. The rehearsal host is Ubuntu (AppArmor, not SELinux), so the **T-1 day step includes a production-host dry run**: `docker compose up` of `db` alone against an empty scratch dir to prove the labels work before T0. |
| 7 | The #76 patch is silently lost on rebuild | The Dockerfile checksum guard fails the build. The integrity check output is part of the checklist. |
| 8 | An app version changes as a side effect | Apps are copied at their current versions. The app store auto-updater is left at its current setting, and nothing runs `app:update` during cutover. |
| 9 | Memory pressure during the nightly backup | Container limits are sized with headroom, and the backup is capped with `MemoryHigh` and `GOMAXPROCS`. Both are measured in the rehearsal. |
| 10 | Nextcloud 30 is EOL and the 30.0.0 image is old | Accepted for the migration by your decision. The [upgrade path](#later-phases) starts right after stabilization. |
| 11 | A re-run of `provision.sh` resurrects the native stack | The `NEXTCLOUD_RUNTIME=docker` guard. The native units are disabled, not just stopped. |
| 12 | Rollback after days of use loses members' changes | Rollback B carries the container's DB and data back. |
| 13 | Rate limiting stays a single shared bucket | Same as today, documented. Per-client limiting is a follow-up. |

## Notes, out of scope here

- **Member A's trash** (see the audit): 6.5 GB, effectively all of that member's data, sits in `files_trashbin` and will eventually expire under the default retention. It migrates untouched, and the owner is talking to the user.
- **Exposure from #102:** credential rotation is decided privately by the owner. If any rotation happens, it's done and verified before T0, not during cutover.
- **The local out-of-band `bluehost/onevoice.env`** is stale relative to the host (primary-bucket block). The host copy is authoritative.

## Later phases

1. **Upgrade path, one step at a time, each preceded by a restic snapshot and a local DB dump:** 30.0.0 → **30.0.latest** → **31.x latest** → **32.x latest** → onward, one major at a time. Never skip a major; Nextcloud doesn't support it. For each step:
   - Bump `FROM` and rebuild. If the #76 checksum guard fails, check upstream for a fix to the S3 read retry and drop the patch once it isn't needed.
   - `docker compose up -d`. The entrypoint runs `occ upgrade`.
   - Run `occ app:update --all`, then the verification checklist.
   - Check that the MariaDB 10.11 and PHP versions are still within the new release's supported range before each major.
2. **Primary storage → B2 objectstore (#83):** resumes after the upgrade path. `migrate-primary-storage.sh` needs adapting to the container paths and uid 33 first.
3. **MCP server + monthly maintenance timer:** redeploy the MCP server against the containerized instance (that also fixes `mcp.knoch.dev`, which needs a tunnel ingress rule), and re-enable the maintenance timer, rewritten for `docker compose exec`.
4. **Monitoring in containers**, if wanted: Grafana and Prometheus join compose. The cAdvisor profile is the first step.
5. **Per-client rate limiting** with `real_ip` from `CF-Connecting-IP`, plus HSTS.
6. **Decommission the native stack** after the 7-day window, with explicit approval.
7. Microsoft Teams → Nextcloud calendar sync (planned, not designed).
