#!/bin/bash
#
# configure.sh — application configuration for OneVoice Nextcloud on a
# Bluehost AlmaLinux 10 VPS.
#
# Refactor of aws/terraform/scripts/user-data.sh, which ran once
# at EC2 first boot as a Terraform templatefile().
#
# Two things changed structurally:
#
#   1. No SSM. Every `aws ssm get-parameter --with-decryption` call is now a
#      variable sourced from /etc/onevoice/onevoice.env (root:root 0600).
#   2. No templatefile(). Terraform's ${db_host} / ${s3_bucket} interpolation
#      is gone, and with it the $${VAR} double-dollar escaping that the
#      original needed to keep bash variables away from Terraform. Everything
#      here is plain bash "$VAR".
#
# Idempotent: safe to re-run. The install block is skipped once config.php
# exists, exactly as in the original.
#
#   sudo ./configure.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-/etc/onevoice/onevoice.env}"

if [[ $EUID -ne 0 ]]; then
  echo "configure.sh must run as root." >&2
  exit 1
fi
if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing $ENV_FILE. Copy onevoice.env.example there and fill it in." >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$ENV_FILE"

# ---------------------------------------------------------------------------
# Defaults + validation
# ---------------------------------------------------------------------------
ORGANIZATION="${ORGANIZATION:-onevoice}"
ENVIRONMENT="${ENVIRONMENT:-bluehost}"
SERVICE_USER="${SERVICE_USER:-onevoice}"
SERVICE_HOME="/home/${SERVICE_USER}"
NC="${NEXTCLOUD_PATH:-/var/www/nextcloud}"
DB_MODE="${DB_MODE:-local}"
DB_HOST="${DB_HOST:-127.0.0.1}"
DB_NAME="${DB_NAME:-nextcloud}"
DB_USER="${DB_USER:-nextcloud}"
ADMIN_USER="${ADMIN_USER:-admin}"
OBJECT_STORE="${OBJECT_STORE:-local}"
NEXTCLOUD_DATA_DIR="${NEXTCLOUD_DATA_DIR:-$NC/data}"
ENABLE_REDIS="${ENABLE_REDIS:-true}"
ENABLE_CRON_TIMER="${ENABLE_CRON_TIMER:-true}"
ENABLE_MCP="${ENABLE_MCP:-true}"
ENABLE_CLOUDFLARED="${ENABLE_CLOUDFLARED:-true}"
ENABLE_MAINTENANCE_TIMER="${ENABLE_MAINTENANCE_TIMER:-false}"
ENABLE_MIGRATION_MOUNT="${ENABLE_MIGRATION_MOUNT:-false}"
CREATE_SEED_USERS="${CREATE_SEED_USERS:-true}"
THEME_NAME="${THEME_NAME:-OneVoice}"
THEME_PRIMARY_COLOR="${THEME_PRIMARY_COLOR:-#1a5d3a}"
LOGO_SRC="${LOGO_SRC:-$SCRIPT_DIR/../aws/terraform/assets/logo.png}"
PASSWORD_FILE="/root/onevoice-user-passwords.txt"

log()  { echo -e "\n==> $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

require() {
  local name="$1"
  [[ -n "${!name:-}" ]] || die "$name is required in $ENV_FILE"
}

# Full `if` blocks rather than `[[ cond ]] && require ...`. The one-liner form
# would not abort here (under `set -e` bash exempts a failed non-final element
# of an AND-list), but it does leave the list evaluating to 1, which turns into
# a bogus failure exit if such a line ever ends up last in a script or function.
require ADMIN_PASSWORD
require DB_PASSWORD

# DOMAIN_NAME is optional. The EC2 build always had one because the tunnel was
# the only way in; here the instance can legitimately run on a bare IP before
# any DNS or tunnel exists, so require only that SOMETHING addresses the box.
if [[ -z "${SERVER_IP:-}" && -z "${DOMAIN_NAME:-}" ]]; then
  die "Set SERVER_IP, DOMAIN_NAME, or both in $ENV_FILE — Nextcloud needs at
least one trusted domain or every request is rejected as untrusted."
fi

if [[ "$DB_MODE" == "local" ]]; then
  require DB_ROOT_PASSWORD
fi
if [[ "$ENABLE_CLOUDFLARED" == "true" ]]; then
  require CLOUDFLARE_TUNNEL_TOKEN
  require DOMAIN_NAME
fi

# How Nextcloud will actually be reached. This drives trusted_proxies,
# overwriteprotocol and overwrite.cli.url, which MUST agree with reality:
# telling Nextcloud it is behind an HTTPS proxy while it is really serving
# plain HTTP on a raw IP produces redirect loops and assets that never load.
if [[ "$ENABLE_CLOUDFLARED" == "true" && -n "${DOMAIN_NAME:-}" ]]; then
  BEHIND_TLS_PROXY="true"
  BASE_URL="https://${DOMAIN_NAME}"
else
  BEHIND_TLS_PROXY="false"
  BASE_URL="http://${SERVER_IP}"
fi
if [[ "$ENABLE_MAINTENANCE_TIMER" == "true" ]]; then
  require GITHUB_PAT
fi

# ---------------------------------------------------------------------------
# Safety guards — the two ways this clone can damage prod
# ---------------------------------------------------------------------------
if [[ "$OBJECT_STORE" == "s3" ]]; then
  require S3_BUCKET
  require S3_ACCESS_KEY
  require S3_SECRET_KEY

  # A primary object store keys objects as urn:oid:<fileid>, where fileid is a
  # row id in this instance's own database. This clone's database is empty, so
  # it will start allocating fileid 1, 2, 3... and overwrite prod's objects
  # one by one. There is no recovery short of S3 version rollback.
  if [[ "$S3_BUCKET" == *"prod"* && "${I_UNDERSTAND_SHARED_BUCKET:-}" != "yes" ]]; then
    die "S3_BUCKET '$S3_BUCKET' looks like a production bucket.

A second Nextcloud with a fresh database WILL overwrite objects in a bucket
that is already serving as another instance's primary object store, because
object keys (urn:oid:<fileid>) are derived from database row ids that both
instances allocate from 1.

Create a new, empty bucket for this clone. If you have genuinely verified the
bucket is unused, set I_UNDERSTAND_SHARED_BUCKET=yes."
  fi
fi

# ---------------------------------------------------------------------------
# Cloudflare Tunnel
# ---------------------------------------------------------------------------
if [[ "$ENABLE_CLOUDFLARED" == "true" ]]; then
  log "Configuring cloudflared"

  # A tunnel token identifies a TUNNEL, not a machine. If this token is the
  # prod one, cloudflared registers this VPS as an additional replica and
  # Cloudflare load-balances onevoice.knoch.dev across both boxes.
  if [[ -f /etc/cloudflared/token ]] && \
     ! cmp -s <(printf '%s' "$CLOUDFLARE_TUNNEL_TOKEN") /etc/cloudflared/token; then
    echo "NOTE: replacing existing tunnel token."
  fi

  mkdir -p /etc/cloudflared
  printf '%s' "$CLOUDFLARE_TUNNEL_TOKEN" > /etc/cloudflared/token
  chmod 600 /etc/cloudflared/token
  systemctl enable --now cloudflared
fi

# ---------------------------------------------------------------------------
# Database
# ---------------------------------------------------------------------------
if [[ "$DB_MODE" == "local" ]]; then
  log "Preparing local MariaDB database"

  # mariadb-server installs with a passwordless unix-socket root on EL. Set a
  # root password on first run only, then use it from here on.
  if mariadb -u root --protocol=socket -e "SELECT 1" &>/dev/null; then
    # `DROP USER IF EXISTS`, not `DELETE FROM mysql.user`: since MariaDB 10.4
    # mysql.user is a non-updatable VIEW over mysql.global_priv, so the DELETE
    # fails with "target table is not updatable", the client exits non-zero,
    # and `set -e` kills the whole run before Nextcloud is ever installed.
    mariadb -u root --protocol=socket <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASSWORD}';
DROP USER IF EXISTS ''@'localhost';
DROP USER IF EXISTS ''@'$(hostname)';
DROP DATABASE IF EXISTS test;
FLUSH PRIVILEGES;
EOF
  fi

  # utf8mb4 at creation time — retrofitting a latin1/utf8 database later means
  # occ db:convert-mysql-charset against live data.
  mariadb -u root -p"${DB_ROOT_PASSWORD}" <<EOF
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`
  CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF
fi

# ---------------------------------------------------------------------------
# Web stack up
# ---------------------------------------------------------------------------
log "Starting php-fpm and nginx"
systemctl restart php-fpm
systemctl restart nginx

# ---------------------------------------------------------------------------
# occ helper
# ---------------------------------------------------------------------------
occ() { sudo -u nginx php "$NC/occ" "$@"; }

# ---------------------------------------------------------------------------
# Nextcloud install
# ---------------------------------------------------------------------------
if [[ ! -f "$NC/config/config.php" ]]; then
  log "Running Nextcloud installer"

  INSTALL_DATA_DIR="$NEXTCLOUD_DATA_DIR"
  if [[ "$OBJECT_STORE" == "s3" ]]; then
    # Still required even with an object store — Nextcloud keeps its log,
    # appdata and temp files on local disk.
    INSTALL_DATA_DIR="$NC/data"
    mkdir -p "$INSTALL_DATA_DIR"
    chown nginx:nginx "$INSTALL_DATA_DIR"
    chmod 770 "$INSTALL_DATA_DIR"
  fi

  occ maintenance:install \
    --database "mysql" \
    --database-host "$DB_HOST" \
    --database-name "$DB_NAME" \
    --database-user "$DB_USER" \
    --database-pass "$DB_PASSWORD" \
    --admin-user "$ADMIN_USER" \
    --admin-pass "$ADMIN_PASSWORD" \
    --data-dir "$INSTALL_DATA_DIR"

  # 4-byte UTF-8 (emoji in filenames). Harmless if the DB is already utf8mb4.
  occ config:system:set mysql.utf8mb4 --value true --type boolean
  occ maintenance:repair --include-expensive || true

  if [[ "$OBJECT_STORE" == "s3" ]]; then
    log "Configuring S3 primary object store"

    # class must be a sub-key, not the top-level value, or Nextcloud throws
    # "No class given for objectstore"
    occ config:system:set objectstore class --value "OC\\Files\\ObjectStore\\S3"
    occ config:system:set objectstore arguments bucket --value "$S3_BUCKET"
    occ config:system:set objectstore arguments region --value "$S3_REGION"
    occ config:system:set objectstore arguments use_path_style \
      --value "${S3_USE_PATH_STYLE:-false}" --type boolean
    occ config:system:set objectstore arguments use_ssl \
      --value "${S3_USE_SSL:-true}" --type boolean

    # THE key difference from the EC2 deployment. On EC2 the credentials were
    # deliberately omitted so the AWS SDK would pick up the instance profile
    # from IMDS. There is no IMDS and no instance profile on a Bluehost VPS,
    # so an explicit IAM user access key is mandatory here.
    occ config:system:set objectstore arguments key    --value "$S3_ACCESS_KEY"
    occ config:system:set objectstore arguments secret --value "$S3_SECRET_KEY"

    # Non-AWS S3 endpoints (B2/Wasabi/MinIO) need an explicit hostname.
    if [[ -n "${S3_HOSTNAME:-}" ]]; then
      occ config:system:set objectstore arguments hostname --value "$S3_HOSTNAME"
    fi
  fi

  # deletes on S3 storage crash Trashbin's move-to-trash handoff (upstream bug,
  # #28) — disabled instance-wide, no undo/trash as a trade-off.
  # Only relevant when S3 is the primary store; on local disk trash works fine,
  # so the clone keeps it unless it is actually running on S3.
  if [[ "$OBJECT_STORE" == "s3" ]]; then
    occ app:disable files_trashbin
  fi

  log "Nextcloud install complete."
else
  log "Nextcloud already configured, skipping install."
fi

# ---------------------------------------------------------------------------
# Trusted domains / proxies  (re-applied every run, unlike the original)
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Migration bucket as external storage
# ---------------------------------------------------------------------------
# Deliberately OUTSIDE the install-only block above. In the EC2 script this
# lived inside it, so once config.php existed the mount could never be created
# or corrected by re-running — and getting an S3-compatible endpoint right on
# the first attempt is exactly the thing that needs a second pass.
if [[ "$ENABLE_MIGRATION_MOUNT" == "true" ]]; then
  require MIGRATION_BUCKET
  require MIGRATION_ACCESS_KEY_ID
  require MIGRATION_SECRET_ACCESS_KEY

  log "Configuring migration bucket as external storage"

  # files_external ships with Nextcloud but isn't enabled by default
  occ app:enable files_external

  # The EC2 script hardcoded s3.<region>.amazonaws.com. Backblaze B2, Wasabi
  # and MinIO all speak the same S3 API on a different endpoint, so the host
  # is configurable; leaving MIGRATION_HOSTNAME blank keeps the AWS default.
  MIGRATION_HOST="${MIGRATION_HOSTNAME:-s3.${MIGRATION_REGION:-us-east-1}.amazonaws.com}"
  MOUNT_NAME="${MIGRATION_MOUNT_NAME:-Migration}"
  echo "    endpoint: ${MIGRATION_HOST}  bucket: ${MIGRATION_BUCKET}"
  echo "    mount name: ${MOUNT_NAME}"

  # Reuse an existing "Migration" mount rather than stacking up duplicates on
  # every run. files_external:list is tabular, so pull the id off the row.
  MOUNT_ID="$(occ files_external:list --output=json 2>/dev/null \
    | grep -o '"mount_id":[0-9]*' | head -1 | grep -oE '[0-9]+' || true)"

  if [[ -n "$MOUNT_ID" ]]; then
    echo "    updating existing mount id ${MOUNT_ID}"
    occ files_external:option "$MOUNT_ID" bucket         "$MIGRATION_BUCKET"
    occ files_external:option "$MOUNT_ID" hostname       "$MIGRATION_HOST"
    occ files_external:option "$MOUNT_ID" region         "${MIGRATION_REGION:-us-east-1}"
    occ files_external:option "$MOUNT_ID" key            "$MIGRATION_ACCESS_KEY_ID"
    occ files_external:option "$MOUNT_ID" secret         "$MIGRATION_SECRET_ACCESS_KEY"
    occ files_external:option "$MOUNT_ID" use_ssl        "${MIGRATION_USE_SSL:-true}"
    occ files_external:option "$MOUNT_ID" use_path_style "${MIGRATION_USE_PATH_STYLE:-false}"
  else
    # The `amazons3` backend id is the S3 backend generally, not AWS
    # specifically — it is the correct one for any S3-compatible provider.
    #
    # No --user flag, so this is a SYSTEM mount: visible to every user, which
    # is what you want when the bucket is the instance's real storage rather
    # than one person's staging area.
    CREATE_OUT="$(occ files_external:create \
      "$MOUNT_NAME" amazons3 amazons3::accesskey \
      --config bucket="$MIGRATION_BUCKET" \
      --config hostname="$MIGRATION_HOST" \
      --config region="${MIGRATION_REGION:-us-east-1}" \
      --config use_ssl="${MIGRATION_USE_SSL:-true}" \
      --config use_path_style="${MIGRATION_USE_PATH_STYLE:-false}" \
      --config key="$MIGRATION_ACCESS_KEY_ID" \
      --config secret="$MIGRATION_SECRET_ACCESS_KEY")"
    echo "$CREATE_OUT"
    # Read the id back rather than assuming 1 — it is only 1 on a virgin
    # instance with no other external mounts.
    MOUNT_ID="$(grep -oE '[0-9]+' <<<"$CREATE_OUT" | tail -1)"
  fi

  # Verify now, so a bad bucket or key surfaces here instead of as a mount that
  # silently shows up empty in the UI.
  MIGRATION_VERIFIED="false"
  # Capture first — piping into `grep -q` under pipefail can report failure on
  # a successful match (SIGPIPE race), which here would mean a scary false
  # "mount did not verify" warning on a mount that is actually fine.
  VERIFY_OUT="$(occ files_external:verify "$MOUNT_ID" 2>&1 || true)"
  echo "$VERIFY_OUT" | sed 's/^/    /'
  if [[ -n "$MOUNT_ID" ]] && ! grep -q 'status: ok' <<<"$VERIFY_OUT"; then
    echo "
WARNING: the Migration mount did not verify.
  Confirm MIGRATION_BUCKET is the bucket NAME (the S3 endpoint 404s on a
  Backblaze bucket ID), that the key has access to it, and that
  MIGRATION_REGION matches the endpoint host.
  Nextcloud itself is installed and usable. Fix the env file and re-run this
  script, or inspect with:
    sudo -u nginx php $NC/occ files_external:list
    sudo -u nginx php $NC/occ files_external:verify $MOUNT_ID"
  else
    MIGRATION_VERIFIED="true"
    echo "    mount verified OK"
  fi
fi

log "Setting trusted domains and proxy trust"

# The EC2 script wrote indices 1 and 2 on top of whatever the installer left at
# index 0 (usually "localhost"), so the array only ever grew and you could not
# express "this IP and nothing else". Delete and rewrite instead: the list ends
# up exactly what the env file asks for, and re-running never accumulates
# stale entries.
TRUSTED_DOMAINS=()
if [[ -n "${SERVER_IP:-}" ]];   then TRUSTED_DOMAINS+=("$SERVER_IP");   fi
if [[ -n "${DOMAIN_NAME:-}" ]]; then TRUSTED_DOMAINS+=("$DOMAIN_NAME"); fi

# `|| true`: deleting a key that was never set is a no-op we do not want to
# abort on, and trusted_domains is absent on a brand new install.
occ config:system:delete trusted_domains || true
for i in "${!TRUSTED_DOMAINS[@]}"; do
  occ config:system:set trusted_domains "$i" --value "${TRUSTED_DOMAINS[$i]}"
  echo "    trusted_domains[$i] = ${TRUSTED_DOMAINS[$i]}"
done

occ config:system:set overwrite.cli.url --value "$BASE_URL"

if [[ "$BEHIND_TLS_PROXY" == "true" ]]; then
  # Nextcloud sits behind Cloudflare Tunnel (HTTPS at the edge, plain HTTP
  # locally) — without trusting that, protocol detection is inconsistent
  # between requests and corrupts session cookie encryption ("HMAC does not
  # match", spinning logins, getting bounced back to the login screen).
  occ config:system:set trusted_proxies 0 --value "127.0.0.1"
  occ config:system:set overwriteprotocol --value "https"
else
  # Reached directly over plain HTTP on the raw IP. Forcing overwriteprotocol
  # to https here would make Nextcloud emit https:// URLs that nothing is
  # listening on — infinite redirects and missing CSS. Clear both so they do
  # not linger from an earlier tunnel-enabled run.
  occ config:system:delete overwriteprotocol || true
  occ config:system:delete trusted_proxies   || true
  echo "    plain HTTP on ${BASE_URL} — proxy overrides cleared"
fi

# ---------------------------------------------------------------------------
# Redis  (addition — see README "Deliberate differences")
# ---------------------------------------------------------------------------
# On AlmaLinux 10 the server is Valkey, not Redis — EL10 dropped redis after
# its 7.4 license change. Valkey is wire-compatible, so the PHP extension and
# Nextcloud's \OC\Memcache\Redis backend are unchanged; only the package and
# unit names differ.
#
# Both checks matter. memcache.locking pointing at a cache server that is not
# actually listening fails EVERY request, so an instance that would merely have
# been slower without caching becomes completely unreachable. Verify the
# extension AND the socket before committing the config.
if [[ "$ENABLE_REDIS" == "true" ]]; then
  # Capture then match on a here-string. `php -m | grep -qx` under pipefail is
  # the same racy SIGPIPE pattern that made valkey detection flaky.
  PHP_MODULES="$(php -m 2>/dev/null || true)"
  if ! grep -qx redis <<<"$PHP_MODULES"; then
    echo "NOTE: ENABLE_REDIS=true but the PHP redis extension is not loaded; skipping cache config."
  elif ! timeout 3 bash -c 'echo > /dev/tcp/127.0.0.1/6379' 2>/dev/null; then
    echo "NOTE: nothing is listening on 127.0.0.1:6379 (valkey/redis not running);
      skipping cache config rather than pointing file locking at a dead server.
      Check with: systemctl status valkey"
  else
    log "Configuring Valkey/Redis for local cache and file locking"
    occ config:system:set redis host --value "127.0.0.1"
    occ config:system:set redis port --value 6379 --type integer
    occ config:system:set memcache.local   --value "\\OC\\Memcache\\Redis"
    occ config:system:set memcache.locking --value "\\OC\\Memcache\\Redis"
  fi
fi

# ---------------------------------------------------------------------------
# Background jobs  (addition — see README "Deliberate differences")
# ---------------------------------------------------------------------------
if [[ "$ENABLE_CRON_TIMER" == "true" ]]; then
  log "Switching background jobs to cron mode"
  occ background:cron
  systemctl enable --now nextcloud-cron.timer
fi

# ---------------------------------------------------------------------------
# Theming
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Local-disk containment
# ---------------------------------------------------------------------------
# External storage does NOT keep Nextcloud off the local volume. Previews for
# files on the B2 mount are generated and cached in the LOCAL data directory
# (data/appdata_<instanceid>/preview), and on a bucket with many images that
# is the single largest consumer of the VPS's 50 GB.
#
# Bound it: cap preview dimensions, skip previewing very large files, and keep
# the provider list to cheap formats. Video previews in particular are
# expensive in both CPU and disk and are off by default here.
log "Bounding local disk usage (previews, logs)"

occ config:system:set preview_max_x --value "${PREVIEW_MAX_PX:-2048}" --type integer
occ config:system:set preview_max_y --value "${PREVIEW_MAX_PX:-2048}" --type integer
occ config:system:set preview_max_filesize_image \
  --value "${PREVIEW_MAX_FILESIZE_MB:-50}" --type integer
occ config:app:set preview jpeg_quality --value "${PREVIEW_JPEG_QUALITY:-80}"

# nextcloud.log also lives on local disk and grows without bound by default.
occ config:system:set log_rotate_size \
  --value "${LOG_ROTATE_BYTES:-104857600}" --type integer

# Run the heavy daily background jobs at a quiet hour instead of during the
# working day. Nextcloud warns when this is unset. Value is a UTC hour.
occ config:system:set maintenance_window_start \
  --value "${MAINTENANCE_WINDOW_START_UTC:-2}" --type integer

# Optional indices Nextcloud adds over time but never applies automatically,
# because on a large instance the ALTER can take a while. Cheap here and it
# clears a standing admin warning.
log "Adding missing database indices"
occ db:add-missing-indices

# ---------------------------------------------------------------------------
# Outbound email
# ---------------------------------------------------------------------------
# Nextcloud fails SILENTLY when this is unconfigured — no error in the UI, the
# mail simply never goes. Password resets are the case that bites, because the
# user just sees "check your email" forever.
#
# mail_from_address is the LOCAL PART ONLY; Nextcloud joins it with
# mail_domain. Both must be set or sending is refused outright.
if [[ "${ENABLE_SMTP:-false}" == "true" ]]; then
  require SMTP_HOST
  require SMTP_USER
  require SMTP_PASSWORD
  require MAIL_DOMAIN

  log "Configuring outbound email via ${SMTP_HOST}:${SMTP_PORT:-587}"

  occ config:system:set mail_smtpmode     --value smtp
  occ config:system:set mail_smtphost     --value "$SMTP_HOST"
  occ config:system:set mail_smtpport     --value "${SMTP_PORT:-587}" --type integer
  occ config:system:set mail_smtpsecure   --value "${SMTP_SECURE:-tls}"
  occ config:system:set mail_smtpauth     --value "${SMTP_AUTH:-true}" --type boolean
  occ config:system:set mail_smtpname     --value "$SMTP_USER"
  occ config:system:set mail_smtppassword --value "$SMTP_PASSWORD"
  occ config:system:set mail_from_address --value "${MAIL_FROM_ADDRESS:-noreply}"
  occ config:system:set mail_domain       --value "$MAIL_DOMAIN"

  echo "    from: ${MAIL_FROM_ADDRESS:-noreply}@${MAIL_DOMAIN}"

  # Reachability check only — proves the relay is routable and not blocked.
  # It does NOT prove the credentials work; use Settings > Administration >
  # Basic settings > "Send email" for that, which surfaces the real SMTP error.
  if timeout 8 bash -c "echo > /dev/tcp/${SMTP_HOST}/${SMTP_PORT:-587}" 2>/dev/null; then
    echo "    relay reachable on ${SMTP_PORT:-587}"
  else
    echo "WARNING: cannot open ${SMTP_HOST}:${SMTP_PORT:-587} from this host.
      Mail will not send. Check outbound filtering, then retry with:
        timeout 8 bash -c 'echo > /dev/tcp/${SMTP_HOST}/${SMTP_PORT:-587}'" >&2
  fi
else
  log "Outbound email not configured (ENABLE_SMTP=false)"
  echo "    Nextcloud cannot send password resets until this is set."
fi

# ---------------------------------------------------------------------------
# Camera RAW mimetype alias
# ---------------------------------------------------------------------------
# Nextcloud ships a mismatch between its two mimetype config files:
#
#   mimetypemapping.dist.json : "arw": ["image/x-dcraw"]        <- what files get
#   mimetypealiases.dist.json : "application/x-dcraw": "image"  <- what is aliased
#
# The alias that classifies a mimetype as an *image* is keyed to
# application/x-dcraw, but the extension mapping produces image/x-dcraw. They
# never meet, so the web UI never treats .arw/.cr2/.nef/.dng/.orf/.raf as
# images: no thumbnail is requested and clicking one downloads it instead of
# opening the viewer. Server-side preview generation is fine — the frontend
# simply never asks.
#
# config/ is the supported override location and is not covered by the signed
# manifest, so this does not affect integrity:check-core (verified).
if [[ "${FIX_RAW_MIMETYPE:-true}" == "true" ]]; then
  log "Aliasing image/x-dcraw to image (camera RAW previews)"

  ALIAS_FILE="$NC/config/mimetypealiases.json"
  if [[ ! -f "$ALIAS_FILE" ]]; then
    cat > "$ALIAS_FILE" <<'EOF'
{
    "image/x-dcraw": "image"
}
EOF
    chown nginx:nginx "$ALIAS_FILE"
    chmod 640 "$ALIAS_FILE"
  else
    echo "    $ALIAS_FILE already present, leaving it alone"
  fi

  # Regenerates core/js/mimetypelist.js, which is what the frontend reads.
  # Without this the alias exists in PHP but the browser never sees it.
  occ maintenance:mimetype:update-js

  # Re-tag rows scanned before the alias/app existed.
  occ maintenance:mimetype:update-db --repair-filecache
fi

# ---------------------------------------------------------------------------
# Camera RAW viewer patches
# ---------------------------------------------------------------------------
# Two hand-edits that make clicking a RAW file OPEN it instead of downloading
# it. Both were applied by hand on the EC2 box on 2026-07-18 and recorded
# nowhere — rediscovering them cost about an hour, which is the entire reason
# they are scripted here.
#
# Neither is optional: the first alone registers a handler the Viewer refuses
# to use, the second alone has nothing to register.
#
#   1. camerarawpreviews/js/register-viewer.js
#      Stock file registers its handler behind an `if (OCA.Viewer)` guard, but
#      is loaded via Util::addInitScript as a DEFERRED CLASSIC script while the
#      Viewer's own bundle is an ES MODULE later in the document. Deferred
#      classic and module scripts execute in document order, so the guard is
#      always false and the handler never registers. Replaced with a version
#      that polls until OCA.Viewer exists.
#
#   2. viewer/js/viewer-main.mjs
#      The Viewer's supported-image mimetype array does not include
#      image/x-dcraw, so even a correctly registered handler is ignored.
#
# COSTS, both accepted and matching EC2:
#   - camerarawpreviews is signed, so `occ integrity:check-app` reports
#     INVALID_HASH for it. Core integrity (integrity:check-core) is unaffected.
#   - An app update to either app silently reverts its patch and RAW files go
#     back to downloading. This block re-applies on every run, so re-running
#     configure.sh after any app update restores them.
#
# Pristine originals are kept alongside as *.stock.bak (first run only).
if [[ "${FIX_RAW_VIEWER:-true}" == "true" ]]; then
  RV="$NC/apps/camerarawpreviews/js/register-viewer.js"
  VM="$NC/apps/viewer/js/viewer-main.mjs"
  RV_SRC="$SCRIPT_DIR/files/camerarawpreviews-register-viewer.js"

  if [[ ! -f "$RV" ]]; then
    echo "NOTE: camerarawpreviews not installed; skipping RAW viewer patches."
    echo "      Install it with: occ app:install camerarawpreviews"
  else
    log "Patching camera RAW viewer support"

    # --- patch 1: register-viewer.js -------------------------------------
    if [[ ! -f "$RV_SRC" ]]; then
      echo "WARNING: $RV_SRC missing; cannot patch register-viewer.js" >&2
    elif cmp -s "$RV_SRC" "$RV"; then
      echo "    register-viewer.js already patched"
    else
      [[ -f "$RV.stock.bak" ]] || cp -a "$RV" "$RV.stock.bak"
      install -o nginx -g nginx -m 0644 "$RV_SRC" "$RV"
      echo "    register-viewer.js patched (stock kept as register-viewer.js.stock.bak)"
    fi

    # --- patch 2: viewer-main.mjs ----------------------------------------
    # Matched against the literal mimetype array in the minified bundle. If a
    # Viewer update changes that array, the substitution silently matches
    # nothing — so the result is verified rather than assumed. Silent failure
    # is exactly how this bug hid for a month.
    VIEWER_MIMES='"image/apng","image/bmp","image/gif","image/jpeg","image/png","image/svg+xml","image/webp","image/x-icon"'
    if [[ ! -f "$VM" ]]; then
      echo "WARNING: $VM not found; Viewer app missing?" >&2
    elif grep -q '"image/x-dcraw"' "$VM"; then
      echo "    viewer-main.mjs already claims image/x-dcraw"
    else
      [[ -f "$VM.stock.bak" ]] || cp -a "$VM" "$VM.stock.bak"
      sed -i "s|${VIEWER_MIMES}|${VIEWER_MIMES},\"image/x-dcraw\"|g" "$VM"
      chown nginx:nginx "$VM"
      if grep -q '"image/x-dcraw"' "$VM"; then
        echo "    viewer-main.mjs patched (stock kept as viewer-main.mjs.stock.bak)"
      else
        echo "WARNING: could not patch viewer-main.mjs — the mimetype array no
      longer matches the expected literal, probably because the Viewer app was
      updated. RAW files will download instead of opening. Re-derive the array
      with:  grep -o '\"image/apng\"[^]]*' $VM" >&2
      fi
    fi
  fi
fi

log "Applying OneVoice theming"

# Stage the logo OUTSIDE the Nextcloud root. The EC2 build writes it to
# <nextcloud>/branding/logo.png, which `occ integrity:check-core` reports as
#   EXTRA_FILE: branding/logo.png
# and that turns Administration > Overview's code-integrity check into a hard
# failure. Nextcloud's signed manifest covers the whole tree, so ANY extra file
# under it fails — the logo is not special. theming:config reads the file and
# stores its own copy in appdata, so the source does not need to live there.
BRANDING_DIR="/var/lib/onevoice/branding"
LOGO_PATH="${BRANDING_DIR}/logo.png"
mkdir -p "$BRANDING_DIR"

# Clean up the in-tree copy left by an earlier run of this script.
if [[ -d "$NC/branding" ]]; then
  echo "    removing in-tree $NC/branding (fails integrity check)"
  rm -rf "$NC/branding"
fi

# The EC2 build pulled this with `aws s3 cp s3://<bucket>/branding/logo.png`,
# which needed the instance profile. Out here the file ships with the repo.
if [[ -f "$LOGO_SRC" ]]; then
  install -o nginx -g nginx -m 0644 "$LOGO_SRC" "$LOGO_PATH"
  occ theming:config logo "$LOGO_PATH"
else
  echo "NOTE: logo not found at $LOGO_SRC; skipping logo, keeping name/colour."
fi

occ theming:config name "$THEME_NAME"
occ theming:config primary_color "$THEME_PRIMARY_COLOR"

# ---------------------------------------------------------------------------
# MCP server
# ---------------------------------------------------------------------------
if [[ "$ENABLE_MCP" == "true" ]]; then
  log "Configuring nextcloud-mcp-server"
  require MCP_USERNAME
  require MCP_APP_PASSWORD

  # BASE_URL, not a hardcoded https://$DOMAIN_NAME — on an IP-only instance
  # that would point the MCP server at an HTTPS endpoint that does not exist.
  cat > "${SERVICE_HOME}/nextcloud-mcp-server/.env" <<EOF
NEXTCLOUD_HOST=${BASE_URL}
NEXTCLOUD_USERNAME=${MCP_USERNAME}
NEXTCLOUD_PASSWORD=${MCP_APP_PASSWORD}
EOF
  chown "${SERVICE_USER}:${SERVICE_USER}" "${SERVICE_HOME}/nextcloud-mcp-server/.env"
  chmod 600 "${SERVICE_HOME}/nextcloud-mcp-server/.env"
  systemctl enable --now nextcloud-mcp
fi

# ---------------------------------------------------------------------------
# Maintenance automation
# ---------------------------------------------------------------------------
if [[ "$ENABLE_MAINTENANCE_TIMER" == "true" ]]; then
  log "Configuring maintenance automation"
  sudo -u "$SERVICE_USER" bash -c "echo '${GITHUB_PAT}' | gh auth login --with-token"
  sudo -u "$SERVICE_USER" gh auth setup-git
  systemctl enable --now nextcloud-maintenance.timer
else
  log "Maintenance timer disabled (the EC2 host already runs it)"
fi

# ---------------------------------------------------------------------------
# Seed users
# ---------------------------------------------------------------------------
if [[ "$CREATE_SEED_USERS" == "true" ]]; then
  log "Creating seed users"

  declare -A NEW_USERS=(
    ["jsomori"]="Joseph Somori"
    ["eayanwale"]="Enoch Ayanwale"
    ["dcole"]="Dionne Cole"
    ["dsomori"]="Deborah Somori"
    ["nakinsanmi"]="Naomi Akinsanmi"
    ["aakinsanmi"]="Ayomide Akinsanmi"
    ["fbajere"]="Feyisola Bajere"
    ["gawogbade"]="Goodness Awogbade"
    ["famure"]="Fiyin Amure"
    ["fojo"]="Favor Ojo"
  )

  touch "$PASSWORD_FILE"
  chmod 600 "$PASSWORD_FILE"
  chown root:root "$PASSWORD_FILE"

  EXISTING_USERS="$(occ user:list --output=json)"

  for USERNAME in "${!NEW_USERS[@]}"; do
    DISPLAY_NAME="${NEW_USERS[$USERNAME]}"

    if grep -q "\"${USERNAME}\":" <<<"$EXISTING_USERS"; then
      echo "User $USERNAME already exists, skipping."
      continue
    fi

    GENERATED_PASSWORD="$(openssl rand -base64 18)"

    sudo -u nginx OC_PASS="$GENERATED_PASSWORD" php "$NC/occ" user:add \
      --password-from-env \
      --display-name="$DISPLAY_NAME" \
      "$USERNAME"

    # Replaces `aws ssm put-parameter --type SecureString`. There is no SSM
    # out here; root-only file on the box instead.
    printf '%s\t%s\t%s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$USERNAME" "$GENERATED_PASSWORD" \
      >> "$PASSWORD_FILE"

    echo "Created user $USERNAME, password recorded in $PASSWORD_FILE"
  done
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# External storage scan — LAST, and off by default
# ---------------------------------------------------------------------------
# `files:scan --all` walks every object in the bucket over the S3 API and
# writes an oc_filecache row per file. On a bucket with real data that is hours,
# not minutes. It runs last so it can never delay the rest of the configuration,
# and it is opt-in because external storage does NOT require it — Nextcloud
# scans those mounts lazily when a user browses them. Pre-populating the cache
# only makes the first browse and search faster.
if [[ "${SCAN_EXTERNAL_ON_SETUP:-false}" == "true" && "${MIGRATION_VERIFIED:-false}" == "true" ]]; then
  log "Scanning external storage (this can take a long time)"
  occ files:scan --all
elif [[ "${MIGRATION_VERIFIED:-false}" == "true" ]]; then
  log "Skipping external storage scan (SCAN_EXTERNAL_ON_SETUP=false)"
  echo "    The mount works and its files appear when browsed. To pre-populate"
  echo "    the file cache in the background later:"
  echo "      sudo -u nginx nohup php $NC/occ files:scan --all >/var/log/nc-scan.log 2>&1 &"
fi

log "Post-install status"
occ status
occ config:system:get trusted_domains

cat <<EOF

Nextcloud configuration complete.

  URL          ${BASE_URL}
  Trusted      ${TRUSTED_DOMAINS[*]}
  Admin user   ${ADMIN_USER}
  Object store ${OBJECT_STORE}
  Database     ${DB_MODE} (${DB_HOST}/${DB_NAME})
  Seed user passwords: ${PASSWORD_FILE}

Check for remaining warnings in Administration settings > Overview, or:
  sudo -u nginx php ${NC}/occ setupchecks
EOF
