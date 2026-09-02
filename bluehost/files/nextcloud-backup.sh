#!/bin/bash
#
# nextcloud-backup.sh — nightly restic backup to a dedicated Backblaze B2
# bucket (issue #80's storage-off-local-disk followup).
#
# Backs up:
#   - NEXTCLOUD_DATA_DIR (all real user files)
#   - a mysqldump of the Nextcloud database
#   - config/config.php
#
# Deliberately a SEPARATE bucket from both the primary storage bucket and the
# existing "OneVoice Storage" migration mount — a backup living next to what
# it protects defeats the point.
set -euo pipefail

NC_PATH="${NEXTCLOUD_PATH:-/var/www/nextcloud}"
DATA_DIR="${NEXTCLOUD_DATA_DIR:-${NC_PATH}/data}"
DB_HOST="${DB_HOST:-127.0.0.1}"
DB_NAME="${DB_NAME:-nextcloud}"
DB_USER="${DB_USER:-nextcloud}"

KEEP_DAILY="${BACKUP_KEEP_DAILY:-7}"
KEEP_WEEKLY="${BACKUP_KEEP_WEEKLY:-4}"
KEEP_MONTHLY="${BACKUP_KEEP_MONTHLY:-6}"

for v in BACKUP_B2_BUCKET BACKUP_B2_KEY_ID BACKUP_B2_APPLICATION_KEY BACKUP_RESTIC_PASSWORD DB_PASSWORD; do
  if [ -z "${!v:-}" ]; then
    echo "FATAL: $v is not set in the environment file. Aborting backup." >&2
    exit 1
  fi
done

export RESTIC_REPOSITORY="b2:${BACKUP_B2_BUCKET}:nextcloud"
export B2_ACCOUNT_ID="$BACKUP_B2_KEY_ID"
export B2_ACCOUNT_KEY="$BACKUP_B2_APPLICATION_KEY"
export RESTIC_PASSWORD="$BACKUP_RESTIC_PASSWORD"

WORKDIR=$(mktemp -d)
MAINTENANCE_ON=0
cleanup() {
  if [ "$MAINTENANCE_ON" = "1" ]; then
    sudo -u nginx php "${NC_PATH}/occ" maintenance:mode --off || true
  fi
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

if ! restic snapshots >/dev/null 2>&1; then
  echo "==> No existing repository found at ${RESTIC_REPOSITORY}, initializing"
  restic init
fi

echo "==> Enabling maintenance mode for a consistent DB dump"
sudo -u nginx php "${NC_PATH}/occ" maintenance:mode --on
MAINTENANCE_ON=1

echo "==> Dumping database"
mysqldump --single-transaction -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASSWORD" "$DB_NAME" \
  > "${WORKDIR}/nextcloud-db.sql"

echo "==> Disabling maintenance mode"
sudo -u nginx php "${NC_PATH}/occ" maintenance:mode --off
MAINTENANCE_ON=0

echo "==> Running restic backup"
restic backup \
  "$DATA_DIR" \
  "${NC_PATH}/config/config.php" \
  "${WORKDIR}/nextcloud-db.sql" \
  --tag nextcloud-nightly

echo "==> Applying retention (daily=${KEEP_DAILY} weekly=${KEEP_WEEKLY} monthly=${KEEP_MONTHLY})"
restic forget --keep-daily "$KEEP_DAILY" --keep-weekly "$KEEP_WEEKLY" --keep-monthly "$KEEP_MONTHLY" --prune

echo "==> Done"
