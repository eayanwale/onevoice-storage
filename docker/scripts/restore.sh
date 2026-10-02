#!/bin/bash
#
# restore.sh: rebuild a running instance from a docker-layout restic snapshot
# (tag nextcloud-docker, written by backup.sh).
#
# Usage: restore.sh <snapshot-id|latest> <target-root>
#
# <target-root> must be empty or absent. It becomes ONEVOICE_ROOT for the
# restored instance. To restore next to a running instance (a restore test),
# also export a different COMPOSE_PROJECT_NAME, WEB_BIND and FRONTEND_SUBNET
# first. Exported variables win over .env (see lib.sh).
#
# Repository and credentials: same rules as backup.sh. The DB secret files
# under ${SECRETS_DIR} must already exist (they aren't in the backup).
set -euo pipefail
SNAP="${1:?usage: restore.sh <snapshot|latest> <target-root>}"
TARGET="${2:?usage: restore.sh <snapshot|latest> <target-root>}"
# The snapshot stores paths under the ONEVOICE_ROOT it was taken from.
SOURCE_ROOT="${SOURCE_ROOT:-}"
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
SOURCE_ROOT="${SOURCE_ROOT:-$ONEVOICE_ROOT}"

if [[ -d "$TARGET" && -n "$(ls -A "$TARGET")" ]]; then die "$TARGET is not empty"; fi
mkdir -p "$TARGET"
TARGET="$(cd "$TARGET" && pwd)"
STAGE="$TARGET/.restore-stage"
mkdir -p "$STAGE"

if [[ -z "${RESTIC_REPOSITORY:-}" ]]; then
  ENV_FILE="${ENV_FILE:-/etc/onevoice/onevoice.env}"
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
  export RESTIC_REPOSITORY="b2:${BACKUP_B2_BUCKET}:nextcloud"
  export B2_ACCOUNT_ID="$BACKUP_B2_KEY_ID" B2_ACCOUNT_KEY="$BACKUP_B2_APPLICATION_KEY"
  export RESTIC_PASSWORD="$BACKUP_RESTIC_PASSWORD"
fi

log "Restoring snapshot ${SNAP} into ${STAGE}"
if [[ "$(id -u)" == 0 ]] && command -v restic >/dev/null; then
  timed restore-restic restic restore "$SNAP" --tag nextcloud-docker --target "$STAGE"
else
  repo_mount=()
  [[ "$RESTIC_REPOSITORY" == /* ]] && repo_mount=(-v "$RESTIC_REPOSITORY:$RESTIC_REPOSITORY:ro")
  timed restore-restic docker run --rm --user 0 \
    -e RESTIC_REPOSITORY -e RESTIC_PASSWORD -e B2_ACCOUNT_ID -e B2_ACCOUNT_KEY \
    -e RESTIC_CACHE_DIR=/tmp/restic-cache \
    -v "$STAGE:/stage" "${repo_mount[@]}" "${RESTIC_IMAGE:-restic/restic:0.19.1}" \
    restore "$SNAP" --tag nextcloud-docker --target /stage
fi

SRC="$STAGE$SOURCE_ROOT/nextcloud"
[[ -d "$SRC/data" ]] || die "snapshot has no $SOURCE_ROOT/nextcloud/data (wrong SOURCE_ROOT?)"
DUMP="$(find "$STAGE" -name nextcloud-db.sql -print -quit 2>/dev/null || true)"
[[ -n "$DUMP" ]] || {
  # Under an unprivileged user the stage is root-owned; find through a container.
  DUMP="$STAGE$(docker run --rm --entrypoint "" -v "$STAGE:/s:ro" "$IMAGE" find /s -name nextcloud-db.sql -print -quit | sed 's#^/s##')"
}
[[ -n "$DUMP" ]] || die "no nextcloud-db.sql in the snapshot"

log "Placing state under ${TARGET}"
mkdir -p "$TARGET/nextcloud/html" "$TARGET/mariadb"
if [[ "$(id -u)" == 0 ]]; then
  for d in config custom_apps data; do mv "$SRC/$d" "$TARGET/nextcloud/$d"; done
else
  docker run --rm --network none --user 0 --entrypoint "" -v "$TARGET:/t" "$IMAGE" \
    sh -c "for d in config custom_apps data; do mv /t/.restore-stage${SOURCE_ROOT}/nextcloud/\$d /t/nextcloud/\$d; done"
fi

export ONEVOICE_ROOT="$TARGET"
NC_ROOT="$TARGET/nextcloud"
log "Starting db + valkey and loading the dump"
docker compose up -d --wait db valkey
if [[ "$(id -u)" == 0 ]]; then
  db_sql < "$DUMP"
else
  docker run --rm --entrypoint "" -v "$STAGE:/s:ro" "$IMAGE" cat "/s${DUMP#"$STAGE"}" | db_sql
fi
echo "$TABLE_COUNTS_SQL" | db_sql | sed 's/^/    /'

log "Starting app + web + cron"
docker compose up -d --wait app web cron
occ status
log "Restore complete. Staging copy left at ${STAGE}; remove it once verified."
