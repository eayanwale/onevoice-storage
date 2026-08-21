#!/bin/bash
#
# provision.sh — OS-level provisioning for OneVoice Nextcloud on AlmaLinux 10.
#
# Refactor of onevoice-storage/packer/setup.sh, which ran as a Packer shell
# provisioner against Amazon Linux 2023 to bake an AMI. There is no image to
# bake on a Bluehost VPS, so this runs directly on the box.
#
# It keeps setup.sh's role: everything that does NOT need a secret. Installs
# packages, lays down Nextcloud source, writes nginx/php config, installs
# systemd units — but starts almost nothing and configures no application
# state. configure.sh does that half.
#
# Idempotent: safe to re-run.
#
#   sudo ./provision.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-/etc/onevoice/onevoice.env}"

if [[ $EUID -ne 0 ]]; then
  echo "provision.sh must run as root." >&2
  exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing $ENV_FILE. Copy onevoice.env.example there and fill it in." >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$ENV_FILE"

SERVICE_USER="${SERVICE_USER:-onevoice}"
SERVICE_HOME="/home/${SERVICE_USER}"
NEXTCLOUD_VERSION="${NEXTCLOUD_VERSION:-30.0.0}"
NEXTCLOUD_PATH="${NEXTCLOUD_PATH:-/var/www/nextcloud}"
DB_MODE="${DB_MODE:-local}"
OBJECT_STORE="${OBJECT_STORE:-local}"
ENABLE_REDIS="${ENABLE_REDIS:-true}"
ENABLE_CRON_TIMER="${ENABLE_CRON_TIMER:-true}"
ENABLE_MCP="${ENABLE_MCP:-true}"
ENABLE_CLOUDFLARED="${ENABLE_CLOUDFLARED:-true}"
ENABLE_MAINTENANCE_TIMER="${ENABLE_MAINTENANCE_TIMER:-false}"
OPEN_HTTP_PORT="${OPEN_HTTP_PORT:-false}"

log() { echo -e "\n==> $*"; }

# The EC2 build ran on a t3.medium with a known 4 GB and could hardcode sizes.
# A Bluehost VPS plan can be 2 GB or less, where stock php-fpm (pm.max_children
# = 50) plus a 512 MB InnoDB buffer pool plus Redis will hit the OOM killer
# under any real load. Size both to the RAM actually present.
TOTAL_MB="$(awk '/^MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo)"

INNODB_MB=$(( TOTAL_MB * 20 / 100 ))
if [[ "$INNODB_MB" -lt 128 ]];  then INNODB_MB=128;  fi
if [[ "$INNODB_MB" -gt 1024 ]]; then INNODB_MB=1024; fi

# php-fpm sizing. Budget what is LEFT after everything else, rather than a
# flat percentage of total RAM — the percentage approach was fine while
# Nextcloud had the box to itself, but it silently over-commits as soon as
# anything else is co-hosted.
#
# Reserve = InnoDB buffer pool + headroom for the OS, nginx, Valkey,
# cloudflared and (when enabled) Prometheus + Grafana + node_exporter, which
# together run about 700 MB.
#
# 100 MB per child, not the 60 MB a naive estimate suggests: measured RSS on
# this workload ranged 60-106 MB, and the number that matters for avoiding the
# OOM killer is the peak, not the average.
#
# On 3907 MB with a 781 MB pool that yields 16 children — ample for a handful
# of users, where 26 was a promise the box could not keep under load.
FPM_RESERVE_MB="${FPM_RESERVE_MB:-$(( INNODB_MB + 1500 ))}"
FPM_AVAIL_MB=$(( TOTAL_MB - FPM_RESERVE_MB ))
if [[ "$FPM_AVAIL_MB" -lt 400 ]]; then FPM_AVAIL_MB=400; fi

FPM_MAX_CHILDREN="${FPM_MAX_CHILDREN:-$(( FPM_AVAIL_MB / 100 ))}"
if [[ "$FPM_MAX_CHILDREN" -lt 4 ]];  then FPM_MAX_CHILDREN=4;  fi
if [[ "$FPM_MAX_CHILDREN" -gt 50 ]]; then FPM_MAX_CHILDREN=50; fi
FPM_START=$(( FPM_MAX_CHILDREN / 4 ));      if [[ "$FPM_START" -lt 2 ]]; then FPM_START=2; fi
FPM_MIN_SPARE="$FPM_START"
FPM_MAX_SPARE=$(( FPM_MAX_CHILDREN / 2 ));  if [[ "$FPM_MAX_SPARE" -lt 3 ]]; then FPM_MAX_SPARE=3; fi

log "Detected ${TOTAL_MB} MB RAM -> InnoDB pool ${INNODB_MB}M, php-fpm max_children ${FPM_MAX_CHILDREN}"
echo "    reserved for OS/DB/monitoring: ${FPM_RESERVE_MB} MB; php-fpm budget: ${FPM_AVAIL_MB} MB"
echo "    worst-case php-fpm RSS: $(( FPM_MAX_CHILDREN * 100 )) MB"

# The Bluehost image ships with ZERO swap. With no swap the OOM killer fires
# immediately on any spike rather than degrading, and the processes it picks
# are the big ones — MariaDB mid-install, or php-fpm mid-scan. Disk is the
# cheap resource here (47 GB free), so trade a little of it for a soft edge.
ENABLE_SWAPFILE="${ENABLE_SWAPFILE:-true}"
SWAPFILE_MB="${SWAPFILE_MB:-2048}"
if [[ "$ENABLE_SWAPFILE" == "true" ]]; then
  CURRENT_SWAP="$(awk '/^SwapTotal:/ {printf "%d", $2/1024}' /proc/meminfo)"
  if [[ "$CURRENT_SWAP" -gt 0 ]]; then
    log "Swap already present (${CURRENT_SWAP} MB), leaving it alone"
  else
    log "No swap configured — creating a ${SWAPFILE_MB} MB swapfile"
    if fallocate -l "${SWAPFILE_MB}M" /swapfile 2>/dev/null || \
       dd if=/dev/zero of=/swapfile bs=1M count="$SWAPFILE_MB" status=none; then
      chmod 600 /swapfile
      mkswap /swapfile >/dev/null
      swapon /swapfile
      grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
      echo "    swap active: $(awk '/^SwapTotal:/ {printf "%d MB", $2/1024}' /proc/meminfo)"
    else
      echo "WARNING: could not create swapfile; continuing without swap." >&2
      rm -f /swapfile
    fi
  fi
fi

# AlmaLinux splits packages across repos differently than Amazon Linux 2023,
# and a few PHP extensions live under different names depending on whether
# they come from AppStream, EPEL or Remi. Install the first name that resolves
# rather than hardcoding a guess that breaks the whole `dnf install`.
dnf_install_first() {
  local pkg
  for pkg in "$@"; do
    if dnf -q list --available "$pkg" &>/dev/null || dnf -q list --installed "$pkg" &>/dev/null; then
      dnf install -y "$pkg"
      return 0
    fi
  done
  echo "WARNING: none of these packages are available: $*" >&2
  return 1
}

# ---------------------------------------------------------------------------
# Base system
# ---------------------------------------------------------------------------
log "Updating base system"
dnf update -y

log "Installing base tooling"
dnf install -y \
  nginx unzip tar curl ca-certificates openssl \
  policycoreutils-python-utils firewalld git

# EPEL carries php-pecl-imagick and php-pecl-redis, which AppStream does not.
# Best-effort: Nextcloud runs without them, it just files admin warnings.
dnf install -y epel-release || echo "NOTE: EPEL unavailable; imagick/redis PHP extensions will be skipped."

# ---------------------------------------------------------------------------
# PHP
# ---------------------------------------------------------------------------
# Amazon Linux 2023 needed explicit php8.2-* package names.
#
# EL10 dropped DNF modules entirely. AlmaLinux 10 ships PHP 8.3 as the plain
# `php` package (10.1 AppStream carries 8.3.26-1.el10_1) and offers 8.4 as a
# SEPARATELY NAMED `php8.4` package — not a module stream. So a bare
# `dnf install php` lands on 8.3, which is inside Nextcloud 30's supported
# range (8.1-8.3, 8.3 recommended). Do not add php8.4 here.
log "Installing PHP"

# Core interpreter: these four genuinely must exist, so fail loudly if not.
dnf install -y php php-fpm php-cli php-common

# Extensions go in one at a time. A single renamed package in a combined
# `dnf install` fails the ENTIRE transaction and aborts the run — and EL
# extension naming is exactly the part that shifts between releases. Install
# each best-effort; verify_php_extensions below is the real gate and knows the
# difference between "required" and "nice to have".
for _pkg in php-gd php-mbstring php-xml php-intl php-mysqlnd \
            php-bcmath php-gmp php-opcache php-pdo php-process php-sodium; do
  dnf_install_first "$_pkg" || true
done

# On EL the zip extension is php-pecl-zip (confirmed 1.22.3-5.el10 in
# AlmaLinux 10 AppStream); a plain `php-zip` exists on Mageia/OpenMandriva but
# not on Enterprise Linux. Several install guides claim otherwise, so try the
# EL name first and fall through rather than trusting either.
dnf_install_first php-pecl-zip php-zip || true
# Optional performance/preview extensions.
dnf_install_first php-pecl-imagick php-pecl-imagick-im7 || true
REDIS_SERVICE=""
if [[ "$ENABLE_REDIS" == "true" ]]; then
  # EL10 has NO redis package. Redis Labs left open source at 7.4 (RSALv2 /
  # SSPLv1), so RHEL 10 and every rebuild dropped it and ship Valkey, the
  # community fork, in AppStream instead. Valkey is wire-, command- and
  # on-disk-compatible, so the php-pecl-redis client and Nextcloud's
  # \OC\Memcache\Redis backend talk to it unchanged — only the package and
  # systemd unit are named differently.
  # `|| true`: dnf_install_first returns 1 when nothing resolves, which would
  # otherwise abort here instead of falling through to the warning below.
  dnf_install_first valkey redis || true
  # `systemctl cat`, NOT `systemctl list-unit-files | grep -q`. Under
  # `set -o pipefail` that pipeline is racy: grep -q exits on first match and
  # closes the pipe, which can SIGPIPE the still-writing systemctl (exit 141)
  # and make the PIPELINE non-zero even though the match succeeded. It failed
  # exactly that way here — detected valkey on one run, missed it on the next.
  if systemctl cat valkey.service >/dev/null 2>&1; then
    REDIS_SERVICE="valkey"
  elif systemctl cat redis.service >/dev/null 2>&1; then
    REDIS_SERVICE="redis"
  else
    echo "WARNING: neither valkey nor redis installed; caching will be skipped." >&2
  fi
  if [[ -n "$REDIS_SERVICE" ]]; then
    log "Cache server: ${REDIS_SERVICE} (listens on 127.0.0.1:6379)"
  fi

  # The PHP client extension is still called redis regardless of the server.
  dnf_install_first php-pecl-redis6 php-pecl-redis5 php-pecl-redis || true
fi

# Verify what actually LOADED, not what was named on the command line. Package
# naming across EL rebuilds is the least reliable part of this script (php-zip
# vs php-pecl-zip; curl bundled in php-common vs a separate php-curl), and a
# missing extension otherwise surfaces as an opaque Nextcloud installer abort.
# Anything still missing gets one automatic repair attempt under both naming
# conventions before we give up.
verify_php_extensions() {
  local -a required=(
    ctype curl dom fileinfo filter gd hash iconv json libxml mbstring
    openssl pdo_mysql posix session simplexml xml xmlreader xmlwriter zip zlib
  )
  local -a recommended=(bcmath gmp intl sodium exif)
  local loaded missing=() weak=() ext

  loaded="$(php -m | tr '[:upper:]' '[:lower:]')"

  for ext in "${required[@]}"; do
    grep -qx "$ext" <<<"$loaded" || missing+=("$ext")
  done
  for ext in "${recommended[@]}"; do
    grep -qx "$ext" <<<"$loaded" || weak+=("$ext")
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Missing required PHP extensions: ${missing[*]} — attempting repair" >&2
    for ext in "${missing[@]}"; do
      dnf_install_first "php-${ext}" "php-pecl-${ext}" "php-${ext%%_*}" || true
    done
    loaded="$(php -m | tr '[:upper:]' '[:lower:]')"
    missing=()
    for ext in "${required[@]}"; do
      grep -qx "$ext" <<<"$loaded" || missing+=("$ext")
    done
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    cat >&2 <<EOF

ERROR: Nextcloud requires these PHP extensions and they are not loaded:
       ${missing[*]}

Find the package providing each, then re-run:
       dnf provides '*/<extension>.so'
       dnf search php | grep -i <extension>

EOF
    return 1
  fi

  echo "All required PHP extensions present."
  if [[ ${#weak[@]} -gt 0 ]]; then
    echo "NOTE: recommended but absent (admin warnings only): ${weak[*]}"
  fi
}
verify_php_extensions

PHP_VER="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
log "PHP version installed: $(php -r 'echo PHP_VERSION;')"

# Guard, not an expected failure: AlmaLinux 10's `php` is 8.3 today, so this
# should pass. It exists because Nextcloud hard-REFUSES to install on an
# unsupported PHP major.minor (it is not a warning), and a future AlmaLinux
# point release could repoint `php` at 8.4. Better to stop here in seconds
# than after MariaDB and Nextcloud are half configured.
NC_MAJOR="${NEXTCLOUD_VERSION%%.*}"
if [[ "$NC_MAJOR" -le 30 ]] && [[ "$(printf '%s\n' "$PHP_VER" "8.3" | sort -V | tail -1)" != "8.3" ]]; then
  cat >&2 <<EOF

ERROR: PHP ${PHP_VER} is too new for Nextcloud ${NEXTCLOUD_VERSION}
       (Nextcloud 30 supports PHP 8.1-8.3). The installer will refuse to run.

Pick one, in /etc/onevoice/onevoice.env, then re-run:

  1. Newer Nextcloud (recommended — 30 is past end-of-life anyway):
       NEXTCLOUD_VERSION="31.0.8"      # supports PHP 8.1-8.4

  2. Pin PHP 8.3 from Remi, keeping Nextcloud 30 for strict parity with the
     EC2 build:
       dnf install -y https://rpms.remirepo.net/enterprise/remi-release-10.rpm
       dnf module reset php -y 2>/dev/null || true
       dnf install -y php83 php83-php-fpm   # or enable the remi-8.3 stream
     then re-run this script.

EOF
  exit 1
fi

# ---------------------------------------------------------------------------
# MariaDB (replaces RDS)
# ---------------------------------------------------------------------------
if [[ "$DB_MODE" == "local" ]]; then
  log "Installing MariaDB server"
  # AlmaLinux 10 AppStream ships MariaDB 10.11 (lowercase `mariadb-server`;
  # the upstream MariaDB repo uses capitalised `MariaDB-server`, don't mix).
  # The client is listed explicitly because configure.sh invokes `mariadb`
  # directly and we do not want to rely on it arriving as a dependency.
  dnf install -y mariadb-server mariadb

  # Nextcloud's documented MySQL requirements. READ-COMMITTED + ROW binlog
  # avoid gap-lock deadlocks under concurrent uploads; RDS defaulted close
  # enough to this that the EC2 build never had to say so explicitly.
  cat > /etc/my.cnf.d/nextcloud.cnf <<EOF
[mysqld]
# MariaDB defaults to binding 0.0.0.0:3306 on EL. Nothing outside this host
# needs it — Nextcloud connects over 127.0.0.1 — and firewalld is the only
# thing keeping the database off the public internet. Bind to loopback so a
# future firewall change cannot silently expose it. (The AWS build did not
# need this: RDS lived in a private subnet behind a security group.)
bind-address = 127.0.0.1

transaction_isolation = READ-COMMITTED
binlog_format         = ROW
innodb_file_per_table = 1
innodb_buffer_pool_size = ${INNODB_MB}M
character_set_server  = utf8mb4
collation_server      = utf8mb4_general_ci
max_connections       = 200
EOF

  systemctl enable --now mariadb
fi

# ---------------------------------------------------------------------------
# Service account (the "ec2-user" stand-in)
# ---------------------------------------------------------------------------
if ! id -u "$SERVICE_USER" &>/dev/null; then
  log "Creating service account: $SERVICE_USER"
  useradd --create-home --shell /bin/bash "$SERVICE_USER"
fi

# ---------------------------------------------------------------------------
# Nextcloud source
# ---------------------------------------------------------------------------
if [[ -d "$NEXTCLOUD_PATH" ]]; then
  log "Nextcloud already present at $NEXTCLOUD_PATH, leaving it alone"
else
  log "Downloading Nextcloud ${NEXTCLOUD_VERSION}"
  cd /tmp
  NC_ZIP="nextcloud-${NEXTCLOUD_VERSION}.zip"
  NC_SUM="${NC_ZIP}.sha256"

  curl -fsSL -o "$NC_SUM" "https://download.nextcloud.com/server/releases/${NC_SUM}"

  # Reuse an archive already sitting in /tmp from an earlier run — the download
  # is ~230 MB and re-fetching it on every retry makes iteration painful.
  if [[ -f "$NC_ZIP" ]] && sha256sum --ignore-missing -c "$NC_SUM" >/dev/null 2>&1; then
    echo "    reusing verified ${NC_ZIP} already in /tmp"
  else
    curl -fsSL -o "$NC_ZIP" "https://download.nextcloud.com/server/releases/${NC_ZIP}"
  fi

  # The AMI build skipped checksum verification because Packer ran on a
  # trusted network at bake time. This box downloads at deploy time; verify.
  #
  # --ignore-missing is REQUIRED, not defensive: upstream's .sha256 lists both
  # the zip AND a nextcloud-<ver>.metadata file that we deliberately do not
  # fetch. Plain `sha256sum -c` exits 1 on the absent .metadata even when the
  # zip itself reports OK, which under `set -e` aborts the run right before
  # extraction.
  sha256sum --ignore-missing -c "$NC_SUM"

  mkdir -p "$(dirname "$NEXTCLOUD_PATH")"
  unzip -q "$NC_ZIP" -d "$(dirname "$NEXTCLOUD_PATH")"
  rm -f "$NC_ZIP" "$NC_SUM"
fi

log "Setting Nextcloud ownership and permissions"
chown -R nginx:nginx "$NEXTCLOUD_PATH"
find "$NEXTCLOUD_PATH/" -type d -exec chmod 750 {} \;
find "$NEXTCLOUD_PATH/" -type f -exec chmod 640 {} \;

if [[ "$OBJECT_STORE" == "local" ]]; then
  DATA_DIR="${NEXTCLOUD_DATA_DIR:-${NEXTCLOUD_PATH}/data}"
  mkdir -p "$DATA_DIR"
  chown -R nginx:nginx "$DATA_DIR"
  chmod 770 "$DATA_DIR"
fi

# ---------------------------------------------------------------------------
# php-fpm
# ---------------------------------------------------------------------------
log "Configuring php-fpm"
# EL ships www.conf owned by `apache`; the EC2 script made the same edits
# because AL2023 does too.
sed -i 's/^user = .*/user = nginx/'          /etc/php-fpm.d/www.conf
sed -i 's/^group = .*/group = nginx/'        /etc/php-fpm.d/www.conf
sed -i 's/^listen.owner = .*/listen.owner = nginx/' /etc/php-fpm.d/www.conf
sed -i 's/^listen.group = .*/listen.group = nginx/' /etc/php-fpm.d/www.conf

mkdir -p /var/lib/php/session
chown -R nginx:nginx /var/lib/php/session
chmod 700 /var/lib/php/session

# Process-manager sizing. Stock EL ships pm.max_children = 50, which against
# the 512M memory_limit below is a promise this box cannot keep.
sed -i "s/^pm.max_children = .*/pm.max_children = ${FPM_MAX_CHILDREN}/"        /etc/php-fpm.d/www.conf
sed -i "s/^pm.start_servers = .*/pm.start_servers = ${FPM_START}/"             /etc/php-fpm.d/www.conf
sed -i "s/^pm.min_spare_servers = .*/pm.min_spare_servers = ${FPM_MIN_SPARE}/" /etc/php-fpm.d/www.conf
sed -i "s/^pm.max_spare_servers = .*/pm.max_spare_servers = ${FPM_MAX_SPARE}/" /etc/php-fpm.d/www.conf

# php.ini tuning. The EC2 build set memory_limit at boot time inside
# user-data.sh; it belongs here with the rest of the static config.
cat > /etc/php.d/99-nextcloud.ini <<'EOF'
memory_limit = 512M
upload_max_filesize = 512M
post_max_size = 512M
max_execution_time = 3600
max_input_time = 3600
output_buffering = 0
date.timezone = UTC

opcache.enable = 1
opcache.enable_cli = 1
opcache.interned_strings_buffer = 16
opcache.max_accelerated_files = 10000
opcache.memory_consumption = 128
opcache.save_comments = 1
opcache.revalidate_freq = 60
EOF

# ---------------------------------------------------------------------------
# nginx
# ---------------------------------------------------------------------------
log "Configuring nginx"
install -m 0644 "$SCRIPT_DIR/files/rate-limit.conf" /etc/nginx/conf.d/rate-limit.conf

# Structurally the AMI's server block, with ONE addition: the `types` map.
#
# Nextcloud's own `occ setupchecks` flags the stock config with a hard failure
# on this box — "Your webserver does not serve .mjs files using the JavaScript
# MIME type. This will break some apps". nginx's default mime.types has no
# entry for .mjs, so it serves them as application/octet-stream and browsers
# refuse to execute them. The AMI's `location ~ \.(?:css|js|mjs|...)$` block
# matches .mjs for caching but never sets its type.
#
# This affects the EC2 deployment identically — worth fixing there too.
#
# Still absent, and still matching prod: .well-known/{caldav,carddav}
# redirects and the PATH_INFO fastcgi_param. Those are warnings rather than
# failures; see README.
cat > /etc/nginx/conf.d/nextcloud.conf <<EOF
server {
    listen 80;
    server_name _;
    root ${NEXTCLOUD_PATH};

    client_max_body_size 512M;
    fastcgi_buffers 64 4K;

    # No security headers are set here on purpose. Nextcloud emits its own
    # (Referrer-Policy, X-Content-Type-Options, X-Frame-Options,
    # X-Permitted-Cross-Domain-Policies, X-XSS-Protection, X-Robots-Tag, CSP)
    # from PHP; adding X-Robots-Tag in nginx just sends it twice.
    #
    # Strict-Transport-Security is the one setupchecks still asks for, and it
    # is deliberately omitted: this instance serves plain HTTP. Browsers only
    # honour HSTS over HTTPS, and if it did apply it would pin clients to an
    # https:// endpoint that does not exist. Add it with the Cloudflare Tunnel.

    # Service-discovery endpoints. Without these, `occ setupchecks` warns and
    # CalDAV/CardDAV desktop clients cannot autodiscover — they probe
    # /.well-known/caldav and get Nextcloud's 404 page instead of a redirect.
    # `location =` is an exact match and takes priority over the regex blocks
    # below regardless of ordering.
    location = /.well-known/carddav  { return 301 /remote.php/dav/; }
    location = /.well-known/caldav   { return 301 /remote.php/dav/; }
    location = /.well-known/webfinger { return 301 /index.php/.well-known/webfinger; }
    location = /.well-known/nodeinfo  { return 301 /index.php/.well-known/nodeinfo; }

    location / {
        limit_req zone=nextcloud_limit burst=20 nodelay;
        rewrite ^ /index.php\$request_uri;
    }

    location ~ ^/(?:build|tests|config|lib|3rdparty|templates|data)/ {
        deny all;
    }

    location ~ \.php(?:\$|/) {
        fastcgi_split_path_info ^(.+\.php)(/.*)\$;
        fastcgi_pass unix:/run/php-fpm/www.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        # fastcgi_split_path_info populates \$fastcgi_path_info, but nothing
        # passes it on — stock fastcgi_params has no PATH_INFO. Routes that
        # depend on it (WebDAV under /remote.php/dav/..., OCS under
        # /ocs-provider/) then see an empty path.
        fastcgi_param PATH_INFO \$fastcgi_path_info;
        include fastcgi_params;
    }

    # /ocs-provider/ and /updater/ are real directories served through their
    # own index.php.
    #
    # This MUST come after the \\.php block above. nginx takes the first
    # matching regex location, so placing it earlier makes it swallow
    # /ocs-provider/index.php, and \`try_files \$uri/\` then looks for
    # "/ocs-provider/index.php/" and 404s the very file it needs to serve.
    # Here, the bare directory falls through to \`index index.php\`, which
    # internally redirects to the .php handler above.
    #
    # ocm-provider is deliberately absent: Nextcloud 30 does not ship that
    # directory, so it is left to the catch-all rewrite and the PHP router.
    location ~ ^/(?:updater|ocs-provider)(?:\$|/) {
        try_files \$uri \$uri/ =404;
        index index.php;
    }

    # .mjs and .js.map have no entry in nginx's stock mime.types, so they are
    # served as application/octet-stream and browsers refuse to execute them
    # (occ setupchecks flags .mjs as a hard failure).
    #
    # Fixed with per-location default_type, NOT a \`types { }\` block. A types
    # block REPLACES the entire inherited MIME map for its context rather than
    # extending it — doing that here silently turned every .css into
    # octet-stream and rendered the whole UI unstyled. Regex locations match
    # in order, so these two must precede the general static block below.
    location ~ \.mjs\$ {
        default_type text/javascript;
        expires 30d;
        access_log off;
    }

    location ~ \.map\$ {
        default_type application/json;
        expires 30d;
        access_log off;
    }

    location ~ \.(?:css|js|svg|gif|png|jpg|ico|woff2?)\$ {
        expires 30d;
        access_log off;
    }
}
EOF

rm -f /etc/nginx/conf.d/default.conf 2>/dev/null || true

# AlmaLinux's stock nginx.conf carries its own `server {}` on :80 serving the
# distro welcome page; Amazon Linux 2023's does not, so the EC2 build never
# had to deal with it. Ours wins on ordering today (conf.d is included above
# that block), but that is a fragile thing to depend on — comment it out.
#
# Brace-counting rather than a sed line range: the stock block contains nested
# `location { }` blocks, so a `/server {/,/^\s*}/` range would terminate on the
# first nested closing brace and leave a syntactically broken file behind.
if grep -qE '^[[:space:]]*server[[:space:]]*\{' /etc/nginx/nginx.conf; then
  log "Commenting out the stock nginx default server block"
  cp -n /etc/nginx/nginx.conf /etc/nginx/nginx.conf.orig
  awk '
    BEGIN { depth = 0; inserver = 0 }
    {
      if (!inserver && $0 ~ /^[[:space:]]*server[[:space:]]*\{/) { inserver = 1; depth = 0 }
      if (inserver) {
        line = $0
        depth += gsub(/\{/, "{")
        depth -= gsub(/\}/, "}")
        print "#" line
        if (depth <= 0) { inserver = 0 }
        next
      }
      print
    }
  ' /etc/nginx/nginx.conf > /etc/nginx/.nginx.conf.new

  # Stage the temp file in /etc/nginx, NOT /tmp. `mv` preserves the SOURCE's
  # SELinux context, so moving in from /tmp lands the file labelled
  # user_tmp_t instead of httpd_config_t. nginx then fails to start with
  #   open() "/etc/nginx/nginx.conf" failed (13: Permission denied)
  # while `nginx -t` as unconfined root still passes — a genuinely confusing
  # pair of symptoms. Creating it inside /etc/nginx inherits the right label;
  # restorecon is belt-and-braces.
  chmod 0644 /etc/nginx/.nginx.conf.new
  mv /etc/nginx/.nginx.conf.new /etc/nginx/nginx.conf
  restorecon -F /etc/nginx/nginx.conf 2>/dev/null || true
fi

nginx -t

# ---------------------------------------------------------------------------
# SELinux
# ---------------------------------------------------------------------------
# The single biggest AL2023 -> AlmaLinux difference. Amazon Linux 2023 boots
# SELinux permissive, so the EC2 scripts never needed a line of this.
# AlmaLinux 10 boots ENFORCING: without the rules below, nginx cannot read
# the docroot, php-fpm cannot write config/ or data/, and every outbound S3
# call is denied.
if command -v getenforce &>/dev/null && [[ "$(getenforce)" != "Disabled" ]]; then
  log "Applying SELinux policy for Nextcloud (mode: $(getenforce))"

  semanage fcontext -a -t httpd_sys_rw_content_t "${NEXTCLOUD_PATH}/config(/.*)?"   2>/dev/null || true
  semanage fcontext -a -t httpd_sys_rw_content_t "${NEXTCLOUD_PATH}/apps(/.*)?"     2>/dev/null || true
  semanage fcontext -a -t httpd_sys_rw_content_t "${NEXTCLOUD_PATH}/.htaccess"      2>/dev/null || true
  semanage fcontext -a -t httpd_sys_rw_content_t "${NEXTCLOUD_PATH}/.user.ini"      2>/dev/null || true
  semanage fcontext -a -t httpd_sys_rw_content_t \
    "${NEXTCLOUD_PATH}/3rdparty/aws/aws-sdk-php/src/data/logs(/.*)?"                2>/dev/null || true
  if [[ "$OBJECT_STORE" == "local" ]]; then
    semanage fcontext -a -t httpd_sys_rw_content_t "${NEXTCLOUD_DATA_DIR:-$NEXTCLOUD_PATH/data}(/.*)?" 2>/dev/null || true
  fi

  restorecon -R "$NEXTCLOUD_PATH" >/dev/null 2>&1 || true
  if [[ "$OBJECT_STORE" == "local" ]]; then
    restorecon -R "${NEXTCLOUD_DATA_DIR:-$NEXTCLOUD_PATH/data}" >/dev/null 2>&1 || true
  fi

  # Outbound HTTP from php-fpm: S3 object store, files_external, app store,
  # update checks. Denied by default.
  setsebool -P httpd_can_network_connect on
  # php-fpm -> MariaDB over TCP on 127.0.0.1.
  setsebool -P httpd_can_network_connect_db on
  if [[ "$ENABLE_REDIS" == "true" ]]; then
    setsebool -P httpd_can_network_memcache on
  fi
fi

# ---------------------------------------------------------------------------
# firewalld
# ---------------------------------------------------------------------------
# Also absent on Amazon Linux 2023 — inbound filtering there was the EC2
# security group's job, which is a Terraform resource, not a script concern.
# A stock Bluehost AlmaLinux image ships firewalld NOT INSTALLED and not
# running — so this does not "configure the firewall", it INTRODUCES one where
# no filtering existed. Over SSH that is the classic way to lock yourself out
# of a remote box permanently.
#
# Allow SSH offline, before the daemon ever starts, so there is no window in
# which the running ruleset lacks it. firewalld's default public zone does
# permit ssh, but relying on a default you cannot recover from is a bad trade
# for one extra line.
log "Enabling firewalld (ensuring SSH survives first)"
firewall-offline-cmd --add-service=ssh >/dev/null 2>&1 || true
systemctl enable --now firewalld
firewall-cmd --permanent --add-service=ssh >/dev/null

# Symmetric on purpose. An add-only rule makes the flag one-way: flipping it
# back to false would silently leave 80/tcp open, so the box stays exposed
# while the config claims otherwise.
if [[ "$OPEN_HTTP_PORT" == "true" ]]; then
  log "Opening 80/tcp"
  firewall-cmd --permanent --add-service=http >/dev/null
else
  log "Closing 80/tcp — Cloudflare Tunnel is outbound-only and needs no inbound port"
  firewall-cmd --permanent --remove-service=http >/dev/null 2>&1 || true
fi

# cockpit is enabled by default on AlmaLinux and publishes a root-capable web
# console on 9090/tcp. Nothing here uses it, and 9090 is also Prometheus's
# port — leaving it open is both an unnecessary attack surface and confusing.
if [[ "${ALLOW_COCKPIT:-false}" != "true" ]]; then
  firewall-cmd --permanent --remove-service=cockpit >/dev/null 2>&1 || true
fi

firewall-cmd --reload >/dev/null

echo "    active services: $(firewall-cmd --list-services)"

# ---------------------------------------------------------------------------
# cloudflared
# ---------------------------------------------------------------------------
if [[ "$ENABLE_CLOUDFLARED" == "true" ]]; then
  log "Installing cloudflared"
  curl -fsSL https://pkg.cloudflare.com/cloudflared-ascii.repo -o /etc/yum.repos.d/cloudflared.repo
  dnf install -y cloudflared
  install -m 0644 "$SCRIPT_DIR/files/cloudflared.service" /etc/systemd/system/cloudflared.service
fi

# ---------------------------------------------------------------------------
# Monitoring: Prometheus + node_exporter + Grafana
# ---------------------------------------------------------------------------
# Everything binds to LOOPBACK ONLY. Prometheus in particular ships with no
# authentication whatsoever — anyone who can reach :9090 can read every metric
# and run arbitrary queries against the whole TSDB. It is never exposed; only
# Grafana is, and only through the Cloudflare Tunnel.
#
# Both packages default to 0.0.0.0, so the bind address is overridden before
# either service is started for the first time, not after.
if [[ "${ENABLE_MONITORING:-false}" == "true" ]]; then
  log "Installing monitoring stack"

  # prometheus is in EPEL, grafana in AppStream. grafana-selinux carries the
  # policy module — required here, SELinux is enforcing.
  dnf install -y prometheus grafana grafana-selinux

  # --- node_exporter ---------------------------------------------------
  # Not packaged for EL10 under any name, so it comes from the upstream
  # release tarball, checksum-verified.
  NE_VER="${NODE_EXPORTER_VERSION:-1.12.1}"
  NE_BIND="${NODE_EXPORTER_BIND:-127.0.0.1:9100}"
  if [[ -x /usr/local/bin/node_exporter ]] && \
     /usr/local/bin/node_exporter --version 2>&1 | grep -q "$NE_VER"; then
    log "node_exporter ${NE_VER} already installed"
  else
    log "Installing node_exporter ${NE_VER}"
    NE_TGZ="node_exporter-${NE_VER}.linux-amd64.tar.gz"
    cd /tmp
    curl -fsSL -O "https://github.com/prometheus/node_exporter/releases/download/v${NE_VER}/${NE_TGZ}"
    curl -fsSL -O "https://github.com/prometheus/node_exporter/releases/download/v${NE_VER}/sha256sums.txt"
    grep " ${NE_TGZ}\$" sha256sums.txt | sha256sum -c -
    tar xzf "$NE_TGZ"
    install -m 0755 "node_exporter-${NE_VER}.linux-amd64/node_exporter" /usr/local/bin/node_exporter
    rm -rf "$NE_TGZ" sha256sums.txt "node_exporter-${NE_VER}.linux-amd64"
    # A binary dropped into /usr/local/bin inherits no useful SELinux type;
    # relabel it so systemd can execute it under an enforcing policy.
    restorecon -F /usr/local/bin/node_exporter 2>/dev/null || true
  fi

  id -u node_exporter &>/dev/null || \
    useradd --system --no-create-home --shell /sbin/nologin node_exporter

  cat > /etc/systemd/system/node_exporter.service <<EOF
[Unit]
Description=Prometheus Node Exporter
After=network-online.target
Wants=network-online.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter --web.listen-address=${NE_BIND}
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
ProtectHome=yes
ProtectSystem=strict
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF

  # --- prometheus ------------------------------------------------------
  # The unit is ExecStart=/usr/bin/prometheus \$ARGS with ARGS sourced from
  # /etc/default/prometheus, so the listen address goes there.
  PROM_BIND="${PROMETHEUS_BIND:-127.0.0.1:9090}"
  cat > /etc/default/prometheus <<EOF
# Managed by provision.sh — see onevoice.env for the knobs.
# Loopback only: Prometheus has no authentication of any kind.
ARGS='--config.file=/etc/prometheus/prometheus.yml \
--storage.tsdb.path=/var/lib/prometheus/metrics2/ \
--storage.tsdb.retention.time=${PROMETHEUS_RETENTION:-15d} \
--web.listen-address=${PROM_BIND} \
--web.console.libraries=/etc/prometheus/console_libraries \
--web.console.templates=/etc/prometheus/consoles'
EOF

  cat > /etc/prometheus/prometheus.yml <<EOF
# Managed by provision.sh
global:
  scrape_interval: 30s
  evaluation_interval: 30s
  external_labels:
    host: '$(hostname -s)'

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['${PROM_BIND}']

  # Do NOT override the 'instance' label. Prometheus sets it to host:port by
  # convention, and community dashboards rely on that shape — Node Exporter
  # Full (ID 1860) splits it into \$node and \$port and matches
  # instance=~"\$node:\$port". A friendly bare hostname there has no colon, so
  # those queries match nothing and every panel renders N/A.
  # Host identity travels in external_labels above instead.
  - job_name: 'node'
    static_configs:
      - targets: ['${NE_BIND}']
EOF
  chown root:prometheus /etc/prometheus/prometheus.yml 2>/dev/null || true
  chmod 0640 /etc/prometheus/prometheus.yml

  # --- grafana ---------------------------------------------------------
  # Ships with http_addr commented out, which means 0.0.0.0. Pin it.
  GF_ADDR="${GRAFANA_BIND_ADDR:-127.0.0.1}"
  GF_PORT="${GRAFANA_PORT:-3000}"
  sed -i "s|^;\?http_addr =.*|http_addr = ${GF_ADDR}|" /etc/grafana/grafana.ini
  sed -i "s|^;\?http_port =.*|http_port = ${GF_PORT}|" /etc/grafana/grafana.ini

  if [[ -n "${GRAFANA_ROOT_URL:-}" ]]; then
    sed -i "s|^;\?root_url =.*|root_url = ${GRAFANA_ROOT_URL}|" /etc/grafana/grafana.ini
    sed -i "s|^;\?serve_from_sub_path =.*|serve_from_sub_path = ${GRAFANA_SERVE_FROM_SUBPATH:-false}|" \
      /etc/grafana/grafana.ini
  fi

  # Point Grafana at the local Prometheus without anyone clicking through a
  # setup wizard. Provisioned datasources are reconciled on every start.
  install -d -o root -g grafana -m 0750 /etc/grafana/provisioning/datasources
  cat > /etc/grafana/provisioning/datasources/prometheus.yml <<EOF
# Managed by provision.sh
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://${PROM_BIND}
    isDefault: true
    editable: false
EOF
  chown root:grafana /etc/grafana/provisioning/datasources/prometheus.yml
  chmod 0640 /etc/grafana/provisioning/datasources/prometheus.yml

  # --- SELinux ---------------------------------------------------------
  # grafana-selinux confines the server as grafana_t, which by default may
  # not open an outbound TCP connection to Prometheus. The symptom is not a
  # Grafana error but a datasource failure that reads like a network problem:
  #
  #   Status: 401. Message: Post "http://127.0.0.1:9090/api/v1/query":
  #   dial tcp 127.0.0.1:9090: connect: permission denied
  #
  # ...and every dashboard panel renders N/A. Note `curl` as the grafana user
  # succeeds, because that runs unconfined — only the service is confined, so
  # testing by hand is misleading.
  if command -v getsebool &>/dev/null && getsebool grafana_can_tcp_connect_prometheus_port &>/dev/null; then
    setsebool -P grafana_can_tcp_connect_prometheus_port on
    echo "    SELinux: grafana_can_tcp_connect_prometheus_port on"
  fi

  systemctl daemon-reload
  log "Monitoring bound to loopback: prometheus ${PROM_BIND}, node_exporter ${NE_BIND}, grafana ${GF_ADDR}:${GF_PORT}"
fi

# ---------------------------------------------------------------------------
# GitHub CLI (maintenance automation)
# ---------------------------------------------------------------------------
if [[ "$ENABLE_MAINTENANCE_TIMER" == "true" ]]; then
  log "Installing GitHub CLI"
  # AlmaLinux 10 uses DNF5, where the plugin lives in `dnf5-plugins` and the
  # old `dnf-command(config-manager)` provides-name may not resolve.
  dnf install -y 'dnf-command(config-manager)' 2>/dev/null \
    || dnf install -y dnf5-plugins \
    || true
  # DNF5 also renamed the subcommand: `config-manager addrepo --from-repofile=`
  # replaced `config-manager --add-repo`.
  dnf config-manager addrepo --from-repofile=https://cli.github.com/packages/rpm/gh-cli.repo 2>/dev/null \
    || dnf config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo
  dnf install -y gh --repo gh-cli
fi

# ---------------------------------------------------------------------------
# Nextcloud MCP server
# ---------------------------------------------------------------------------
if [[ "$ENABLE_MCP" == "true" ]]; then
  log "Installing nextcloud-mcp-server"
  # github.com/cbcoutinho/nextcloud-mcp-server: full clone + uv sync, not a
  # standalone uv-managed dependency project.
  if [[ ! -x "${SERVICE_HOME}/.local/bin/uv" ]]; then
    sudo -u "$SERVICE_USER" bash -c 'curl -LsSf https://astral.sh/uv/install.sh | sh'
  fi
  if [[ ! -d "${SERVICE_HOME}/nextcloud-mcp-server" ]]; then
    sudo -u "$SERVICE_USER" git clone \
      https://github.com/cbcoutinho/nextcloud-mcp-server.git \
      "${SERVICE_HOME}/nextcloud-mcp-server"
  fi
  sudo -u "$SERVICE_USER" bash -c "cd '${SERVICE_HOME}/nextcloud-mcp-server' && '${SERVICE_HOME}/.local/bin/uv' sync"
fi

# ---------------------------------------------------------------------------
# Scripts + systemd units
# ---------------------------------------------------------------------------
log "Installing scripts and systemd units"

install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0755 "${SERVICE_HOME}/scripts"
install -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0700 \
  "$SCRIPT_DIR/files/nextcloud-maintenance-check.sh" \
  "${SERVICE_HOME}/scripts/nextcloud-maintenance-check.sh"

# The unit files ship with placeholders instead of a hardcoded /home/ec2-user,
# so the service account is configurable rather than baked into the AMI.
render_unit() {
  local src="$1" dest="$2"
  sed -e "s|__SERVICE_USER__|${SERVICE_USER}|g" \
      -e "s|__SERVICE_HOME__|${SERVICE_HOME}|g" \
      -e "s|__NEXTCLOUD_PATH__|${NEXTCLOUD_PATH}|g" \
      -e "s|__ENV_FILE__|${ENV_FILE}|g" \
      "$src" > "$dest"
  chmod 0644 "$dest"
}

if [[ "$ENABLE_MCP" == "true" ]]; then
  render_unit "$SCRIPT_DIR/files/nextcloud-mcp.service" /etc/systemd/system/nextcloud-mcp.service
fi

if [[ "$ENABLE_MAINTENANCE_TIMER" == "true" ]]; then
  render_unit "$SCRIPT_DIR/files/nextcloud-maintenance.service" /etc/systemd/system/nextcloud-maintenance.service
  render_unit "$SCRIPT_DIR/files/nextcloud-maintenance.timer"   /etc/systemd/system/nextcloud-maintenance.timer

  # The maintenance script shells out to `sudo -u nginx php occ` and
  # `sudo dnf check-update`. ec2-user had blanket NOPASSWD sudo from the AMI;
  # this account gets only what the script actually calls.
  cat > /etc/sudoers.d/onevoice-maintenance <<EOF
${SERVICE_USER} ALL=(nginx) NOPASSWD: /usr/bin/php ${NEXTCLOUD_PATH}/occ *
${SERVICE_USER} ALL=(root)  NOPASSWD: /usr/bin/dnf check-update
EOF
  chmod 0440 /etc/sudoers.d/onevoice-maintenance
  visudo -cf /etc/sudoers.d/onevoice-maintenance
fi

if [[ "$ENABLE_CRON_TIMER" == "true" ]]; then
  render_unit "$SCRIPT_DIR/files/nextcloud-cron.service" /etc/systemd/system/nextcloud-cron.service
  render_unit "$SCRIPT_DIR/files/nextcloud-cron.timer"   /etc/systemd/system/nextcloud-cron.timer
fi

systemctl daemon-reload

log "Enabling services"
# Full `if` blocks rather than `[[ cond ]] && systemctl ...` one-liners. Under
# `set -e` a false condition in an AND-list does NOT abort (bash exempts a
# failed non-final element), but the list still evaluates to 1 — so such a
# line sitting last in a script or function silently makes it report failure.
# bootstrap.sh chains these two scripts, so exit status has to mean something.
systemctl enable nginx
systemctl enable php-fpm

if [[ "$ENABLE_REDIS" == "true" && -n "$REDIS_SERVICE" ]]; then
  systemctl enable --now "$REDIS_SERVICE"
fi
if [[ "$ENABLE_CLOUDFLARED" == "true" ]]; then
  systemctl enable cloudflared
fi
if [[ "$ENABLE_MCP" == "true" ]]; then
  systemctl enable nextcloud-mcp
fi
# maintenance/cron .service units are oneshots driven by their timers, never
# enabled directly.
if [[ "$ENABLE_MAINTENANCE_TIMER" == "true" ]]; then
  systemctl enable nextcloud-maintenance.timer
fi
if [[ "$ENABLE_CRON_TIMER" == "true" ]]; then
  systemctl enable nextcloud-cron.timer
fi
if [[ "${ENABLE_MONITORING:-false}" == "true" ]]; then
  systemctl enable --now node_exporter
  systemctl enable --now prometheus
  systemctl enable --now grafana-server
fi

echo
echo "Nextcloud OS provisioning complete."
echo "Next: sudo ./configure.sh"
