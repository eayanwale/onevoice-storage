#!/bin/bash
# Shared helpers for docker/scripts/*. Sourced, not run.
#
# Loads docker/.env and defines occ/db helpers that work the same on the
# production host (root) and on lab-lt-01 (an unprivileged docker-group user).

DOCKER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DOCKER_DIR"

log()  { printf '\n==> %s\n' "$*"; }
die()  { echo "FATAL: $*" >&2; exit 1; }

[[ -f .env ]] || die "$DOCKER_DIR/.env missing. Copy .env.example and fill it in."
# Same precedence as docker compose itself: a variable already in the
# environment wins over .env. restore.sh relies on this to point a second
# project at a different root without editing .env.
while IFS='=' read -r k v; do
  [[ "$k" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
  [[ -n "${!k+x}" ]] && continue
  export "$k=$v"
done < .env
: "${ONEVOICE_ROOT:?ONEVOICE_ROOT must be set in .env}"
NC_ROOT="$ONEVOICE_ROOT/nextcloud"
IMAGE="${NEXTCLOUD_IMAGE:-onevoice/nextcloud:30.0.0-fpm-ov2}"

# Run a step and append "<name> <seconds>" to $TIMING_LOG (if set), so the
# rehearsal produces the numbers the cutover estimate is built from.
timed() {
  local name="$1"; shift
  local start; start=$(date +%s)
  "$@"
  local secs=$(( $(date +%s) - start ))
  echo "    [timing] ${name}: ${secs}s"
  [[ -n "${TIMING_LOG:-}" ]] && echo "${name} ${secs}" >> "$TIMING_LOG"
  return 0
}

occ() { docker compose exec -T -u www-data app php occ "$@"; }

# mariadb client inside the db container, authenticated from the mounted
# secret. MYSQL_PWD keeps the password off the process list.
db_sql() {
  docker compose exec -T db sh -c \
    'MYSQL_PWD="$(cat /run/secrets/db_password)" exec mariadb -N -u"$MARIADB_USER" "$MARIADB_DATABASE"'
}

db_dump() {
  docker compose exec -T db sh -c \
    'MYSQL_PWD="$(cat /run/secrets/db_password)" exec mariadb-dump --single-transaction --default-character-set=utf8mb4 -u"$MARIADB_USER" "$MARIADB_DATABASE"'
}

# chown to the container's www-data (33). Root does it directly; an
# unprivileged docker-group user (lab) does it in a throwaway container.
# Never used on native paths: on the SELinux host a bind mount with :z would
# relabel them and break the native install that rollback depends on.
own_www_data() {
  local path="$1"
  if [[ "$(id -u)" == 0 ]]; then
    chown -R 33:33 "$path"
  else
    docker run --rm --label homelab.app="${HOMELAB_APP:-onevoice}" --label homelab.component=helper --network none --user 0 --entrypoint "" \
      -v "$path:/target" "$IMAGE" chown -R 33:33 /target
  fi
}

TABLE_COUNTS_SQL="SELECT 'oc_filecache', COUNT(*) FROM oc_filecache
UNION ALL SELECT 'oc_storages', COUNT(*) FROM oc_storages
UNION ALL SELECT 'oc_share', COUNT(*) FROM oc_share
UNION ALL SELECT 'oc_users', COUNT(*) FROM oc_users
UNION ALL SELECT 'oc_external_mounts', COUNT(*) FROM oc_external_mounts
UNION ALL SELECT 'oc_appconfig', COUNT(*) FROM oc_appconfig
UNION ALL SELECT 'oc_jobs', COUNT(*) FROM oc_jobs;"
