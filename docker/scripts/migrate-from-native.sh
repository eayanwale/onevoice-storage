#!/bin/bash
#
# migrate-from-native.sh: move a native Nextcloud install's state into the
# compose layout. The production cutover and the lab-lt-01 rehearsal run the
# same steps (docs/migration/plan.md, "Cutover runbook").
#
# The native install is only ever READ. Data is copied, never moved, and no
# native path is bind-mounted into a container (see own_www_data in lib.sh).
#
# Usage: migrate-from-native.sh <step> [...]
#   prepare        create the ${ONEVOICE_ROOT} tree, check secrets and image
#   data           rsync the native data dir (re-runnable: only the delta moves)
#   config         carry config.php over: rewrite dbhost, redis host and
#                  trusted_proxies only; every secret stays byte-identical
#   apps           copy non-shipped apps at their current versions into custom_apps
#   db             start db + valkey and load $DUMP (.sql or .sql.gz)
#   up             start app, web and cron; wait for healthy
#   check          post-start checks (status, apps, integrity, external storage)
#   counts         table row counts (compare against the native ones)
#
# Inputs (env):
#   NATIVE_DIR     native install root           (default /var/www/nextcloud)
#   NATIVE_DATA    native data dir               (default $NATIVE_DIR/data)
#   NATIVE_CONFIG  native config dir             (default $NATIVE_DIR/config)
#   NATIVE_APPS    native apps dir               (default $NATIVE_DIR/apps)
#   DUMP           database dump, for `db`
#   NATIVE_APPLIST `occ app:list --output=json` from native, for `check`
#   TIMING_LOG     append per-step timings here
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

NATIVE_DIR="${NATIVE_DIR:-/var/www/nextcloud}"
NATIVE_DATA="${NATIVE_DATA:-$NATIVE_DIR/data}"
NATIVE_CONFIG="${NATIVE_CONFIG:-$NATIVE_DIR/config}"
NATIVE_APPS="${NATIVE_APPS:-$NATIVE_DIR/apps}"
EXPECTED_DATADIR=/var/www/nextcloud/data   # compose mounts data here

step_prepare() {
  log "Preparing ${ONEVOICE_ROOT}"
  mkdir -p "$NC_ROOT"/{html,config,custom_apps,data} "$ONEVOICE_ROOT/mariadb"
  for s in db_password db_root_password; do
    [[ -s "${SECRETS_DIR}/$s" ]] || die "${SECRETS_DIR}/$s missing or empty"
  done
  docker image inspect "$IMAGE" >/dev/null 2>&1 || die "image $IMAGE not built (docker compose build app)"
  echo "    ok"
}

step_data() {
  log "Syncing data: ${NATIVE_DATA} -> ${NC_ROOT}/data"
  # .ncdata since Nextcloud 29 (.ocdata before).
  [[ -f "$NATIVE_DATA/.ncdata" || -f "$NATIVE_DATA/.ocdata" ]] \
    || die "$NATIVE_DATA has no .ncdata/.ocdata; not a Nextcloud data dir"
  rsync -aH --delete --numeric-ids "$NATIVE_DATA/" "$NC_ROOT/data/"
  own_www_data "$NC_ROOT/data"
  chmod 0770 "$NC_ROOT/data" 2>/dev/null || true
  du -sh "$NC_ROOT/data" 2>/dev/null | sed 's/^/    /' || true
}

step_config() {
  log "Carrying config.php over"
  [[ -f "$NATIVE_CONFIG/config.php" ]] || die "$NATIVE_CONFIG/config.php not found"
  if [[ -f "$NC_ROOT/config/config.php" && "${FORCE:-0}" != 1 ]]; then
    die "$NC_ROOT/config/config.php already exists (FORCE=1 to overwrite)"
  fi
  # Stage with host tools; the container only ever sees our own directory.
  cp "$NATIVE_CONFIG/config.php" "$NC_ROOT/config/config.php.native"
  local f
  for f in "$NATIVE_CONFIG"/*.json; do
    [[ -e "$f" ]] && cp "$f" "$NC_ROOT/config/"
  done

  docker run --rm -i --network none --user 0 --entrypoint "" \
    -e FRONTEND_SUBNET -e DB_NAME -e DB_USER -e EXPECTED_DATADIR="$EXPECTED_DATADIR" \
    -v "$NC_ROOT/config:/cfg:z" "$IMAGE" php <<'PHP'
<?php
function fail($m) { fwrite(STDERR, "FATAL: $m\n"); exit(1); }
$CONFIG = null;
require '/cfg/config.php.native';
if (!is_array($CONFIG)) fail('native config.php did not define $CONFIG');
$native = $CONFIG;
$c = $native;

if (($c['dbtype'] ?? '') !== 'mysql') fail('dbtype is not mysql');
if (($c['dbname'] ?? null) !== getenv('DB_NAME')) fail('config.php dbname != DB_NAME in .env');
if (($c['dbuser'] ?? null) !== getenv('DB_USER')) fail('config.php dbuser != DB_USER in .env');
if (rtrim($c['datadirectory'] ?? '', '/') !== getenv('EXPECTED_DATADIR'))
  fail('datadirectory is not ' . getenv('EXPECTED_DATADIR') . '; compose mounts the data dir there');

$c['dbhost'] = 'db';
$c['dbport'] = '';
if (isset($c['redis']) && is_array($c['redis'])) {
  $c['redis']['host'] = 'valkey';
  $c['redis']['port'] = 6379;
}
$tp = $c['trusted_proxies'] ?? [];
if (!is_array($tp)) $tp = [$tp];
$subnet = getenv('FRONTEND_SUBNET');
if (!in_array($subnet, $tp, true)) $tp[] = $subnet;
$c['trusted_proxies'] = array_values($tp);
$c['maintenance'] = true;     // turned off by hand once checks pass
unset($c['apps_paths']);      // apps.config.php owns this

file_put_contents('/cfg/config.php', "<?php\n\$CONFIG = " . var_export($c, true) . ";\n");
file_put_contents('/cfg/apps.config.php', <<<'APPS'
<?php
// Shipped apps are read-only image content; app-store and in-house apps live
// in custom_apps (a bind mount). Mirrors the official image's own file.
$CONFIG = array (
  'apps_paths' => array (
    0 => array ('path' => OC::$SERVERROOT.'/apps', 'url' => '/apps', 'writable' => false),
    1 => array ('path' => OC::$SERVERROOT.'/custom_apps', 'url' => '/custom_apps', 'writable' => true),
  ),
);
APPS);

$keys = array_unique(array_merge(array_keys($native), array_keys($c)));
foreach ($keys as $k) {
  if (($native[$k] ?? null) !== ($c[$k] ?? null)) echo "    changed: $k\n";
}
foreach (['secret', 'passwordsalt', 'instanceid', 'dbpassword', 'mail_smtppassword'] as $k) {
  if (($native[$k] ?? null) !== ($c[$k] ?? null)) fail("$k changed - refusing");
  echo "    unchanged: $k\n";
}
unlink('/cfg/config.php.native');
chown('/cfg/config.php', 33); chgrp('/cfg/config.php', 33); chmod('/cfg/config.php', 0640);
PHP
  own_www_data "$NC_ROOT/config"
}

step_apps() {
  log "Copying non-shipped apps into custom_apps"
  local shipped n v d
  shipped="$(docker run --rm --network none --entrypoint "" "$IMAGE" ls /usr/src/nextcloud/apps)"
  for d in "$NATIVE_APPS"/*/; do
    n="$(basename "$d")"
    [[ "$n" == direct_download ]] && continue   # bind-mounted from the repo
    grep -qx "$n" <<<"$shipped" && continue
    rsync -a --delete "$d" "$NC_ROOT/custom_apps/$n/"
    v="$(sed -n 's:.*<version>\(.*\)</version>.*:\1:p' "$d/appinfo/info.xml" | head -1)"
    echo "    $n ${v}"
  done
  mkdir -p "$NC_ROOT/custom_apps/direct_download"   # mount point
  own_www_data "$NC_ROOT/custom_apps"
}

step_db() {
  : "${DUMP:?set DUMP to the database dump}"
  [[ -s "$DUMP" ]] || die "$DUMP missing or empty"
  log "Starting db + valkey"
  docker compose up -d --wait db valkey
  log "Loading ${DUMP}"
  if [[ "$DUMP" == *.gz ]]; then gunzip -c "$DUMP"; else cat "$DUMP"; fi | db_sql
  step_counts
}

step_counts() {
  log "Row counts (container DB)"
  echo "$TABLE_COUNTS_SQL" | db_sql | sed 's/^/    /'
}

step_up() {
  log "Starting app + web + cron"
  docker compose up -d --wait app web cron
  docker compose ps --format 'table {{.Service}}\t{{.Status}}\t{{.Ports}}'
}

step_check() {
  log "occ status"
  occ status
  log "Integrity (expect only the #76 S3ObjectTrait.php entry)"
  occ integrity:check-core --output=json | php_json_summary || true
  if [[ -n "${NATIVE_APPLIST:-}" ]]; then
    log "App list vs native"
    diff <(app_versions < "$NATIVE_APPLIST") <(occ app:list --output=json | app_versions) \
      && echo "    identical (enabled apps and versions)"
  fi
  log "External storage (status only; never print files_external:list)"
  local id
  for id in $(occ files_external:list --output=json | python3 -c 'import json,sys;[print(m["mount_id"]) for m in json.load(sys.stdin)]'); do
    echo "    mount $id: $(occ files_external:verify "$id" | grep -E 'status' | tr -s ' ')"
  done
}

app_versions() { python3 -c 'import json,sys;d=json.load(sys.stdin);[print(k,v) for k,v in sorted(d["enabled"].items())]'; }
php_json_summary() { python3 -c 'import json,sys;d=json.load(sys.stdin) or {};[print("   ",k,list(v)) for k,v in d.items()] or print("    clean")'; }

[[ $# -ge 1 ]] || { sed -n '2,32p' "$0"; exit 1; }
for step in "$@"; do
  case "$step" in
    prepare|data|config|apps|db|up|check|counts) timed "$step" "step_$step" ;;
    *) die "unknown step: $step" ;;
  esac
done
