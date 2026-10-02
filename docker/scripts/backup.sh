#!/bin/bash
#
# backup.sh: nightly backup of the compose deployment. After cutover it
# replaces /usr/local/sbin/nextcloud-backup.sh, keeping the same restic repo,
# B2 bucket and retention. Snapshots are tagged `nextcloud-docker`, so they're
# never confused with the native layout's `nextcloud-nightly` ones.
#
# Contents: config/, custom_apps/, data/ under ${ONEVOICE_ROOT}/nextcloud, a
# consistent mariadb-dump (taken in maintenance mode) and docker/.env. The
# code tree (html/) is not backed up because it's reproducible from the image.
# The DB secret files are not backed up because they're regenerated from the
# out-of-band onevoice.env.
#
# Repository and credentials: if RESTIC_REPOSITORY is already set (the lab
# uses a local throwaway repo), it is used as-is. Otherwise they come from
# $ENV_FILE exactly as the native script does.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

KEEP_DAILY="${BACKUP_KEEP_DAILY:-7}"
KEEP_WEEKLY="${BACKUP_KEEP_WEEKLY:-4}"
KEEP_MONTHLY="${BACKUP_KEEP_MONTHLY:-6}"

if [[ -z "${RESTIC_REPOSITORY:-}" ]]; then
  ENV_FILE="${ENV_FILE:-/etc/onevoice/onevoice.env}"
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
  for v in BACKUP_B2_BUCKET BACKUP_B2_KEY_ID BACKUP_B2_APPLICATION_KEY BACKUP_RESTIC_PASSWORD; do
    [[ -n "${!v:-}" ]] || die "$v is not set in $ENV_FILE"
  done
  export RESTIC_REPOSITORY="b2:${BACKUP_B2_BUCKET}:nextcloud"
  export B2_ACCOUNT_ID="$BACKUP_B2_KEY_ID" B2_ACCOUNT_KEY="$BACKUP_B2_APPLICATION_KEY"
  export RESTIC_PASSWORD="$BACKUP_RESTIC_PASSWORD"
fi

WORKDIR="$(mktemp -d)"
chmod 0700 "$WORKDIR"
MAINTENANCE_ON=0
cleanup() {
  [[ "$MAINTENANCE_ON" == 1 ]] && occ maintenance:mode --off || true
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

# Host restic as root (production, where it reads the bind mounts directly).
# Otherwise (lab: an unprivileged docker-group user who can't read uid 33's
# 0770 data dir) run the official restic image with the same paths mounted
# read-only at the same locations, so snapshot paths match production's.
restic_run() {
  if [[ "$(id -u)" == 0 ]] && command -v restic >/dev/null; then
    restic "$@"
  else
    local repo_mount=()
    [[ "$RESTIC_REPOSITORY" == /* ]] && repo_mount=(-v "$RESTIC_REPOSITORY:$RESTIC_REPOSITORY")
    docker run --rm -i --user 0 \
      --label homelab.app="${HOMELAB_APP:-onevoice}" --label homelab.component=restic \
      -e RESTIC_REPOSITORY -e RESTIC_PASSWORD -e B2_ACCOUNT_ID -e B2_ACCOUNT_KEY \
      -e RESTIC_CACHE_DIR=/tmp/restic-cache \
      -v "$NC_ROOT:$NC_ROOT:ro" -v "$WORKDIR:$WORKDIR:ro" -v "$DOCKER_DIR/.env:$DOCKER_DIR/.env:ro" \
      "${repo_mount[@]}" "${RESTIC_IMAGE:-restic/restic:0.19.1}" "$@"
  fi
}

if ! restic_run cat config >/dev/null 2>&1; then
  log "No repository at ${RESTIC_REPOSITORY}, initializing"
  restic_run init
fi

log "Maintenance mode on for a consistent dump"
occ maintenance:mode --on
MAINTENANCE_ON=1
timed backup-dump eval 'db_dump > "$WORKDIR/nextcloud-db.sql"'
occ maintenance:mode --off
MAINTENANCE_ON=0
[[ -s "$WORKDIR/nextcloud-db.sql" ]] || die "database dump is empty"

log "restic backup"
timed backup-restic restic_run backup --tag nextcloud-docker \
  "$NC_ROOT/config" "$NC_ROOT/custom_apps" "$NC_ROOT/data" \
  "$WORKDIR/nextcloud-db.sql" "$DOCKER_DIR/.env"

log "Retention (docker-layout snapshots: daily=${KEEP_DAILY} weekly=${KEEP_WEEKLY} monthly=${KEEP_MONTHLY})"
# --group-by host,tags, NOT the default host,paths: the dump lives in a fresh
# mktemp dir every night, so grouping by paths puts each snapshot in a group
# of one and retention never removes anything. The native script has exactly
# that bug (36 snapshots kept on 2026-10-02 against a 7/4/6 policy).
restic_run forget --tag nextcloud-docker --group-by host,tags \
  --keep-daily "$KEEP_DAILY" --keep-weekly "$KEEP_WEEKLY" --keep-monthly "$KEEP_MONTHLY" --prune
restic_run snapshots --latest 1 --tag nextcloud-docker
log "Done"
