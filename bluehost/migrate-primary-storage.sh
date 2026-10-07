#!/bin/bash
#
# STATUS (2026-10-07, #116): PAUSED, and NOT runnable as-is. This was written
# for the native install, which was decommissioned on 2026-10-07 (#111): it
# uses the host `mysql` client and reads /var/www/nextcloud/data. Production
# now runs in Docker (docker/compose.yml). Adapt it first: query via
# `docker compose exec db`, read files from /srv/onevoice/nextcloud/data, and
# make the objectstore flip in the container's config.php.
#
# migrate-primary-storage.sh — one-time migration of Nextcloud's local-disk
# primary storage to Backblaze B2 (issue #83's storage-off-local-disk
# followup). NOT installed or run automatically by provision.sh — this is a
# manually-invoked, one-time operational script, kept here for auditability.
#
# Maps every real file in oc_filecache (home::* storages, plus the local::
# appdata storage) to its disk-verified content and uploads it to S3_BUCKET
# under the exact key Nextcloud's own S3 ObjectStore expects: urn:oid:<fileid>.
# Does NOT touch the amazon::external::* migration mount (external storage,
# addressed by path, already correct as-is) and does NOT delete or modify
# anything on local disk — local data stays exactly as-is regardless of mode.
#
# Usage:
#   ./migrate-primary-storage.sh verify   # dry run: every file must be
#                                         # readable and size-consistent with
#                                         # the database. Uploads nothing.
#   ./migrate-primary-storage.sh upload   # uploads every file (PARALLEL
#                                         # concurrent workers, default 8),
#                                         # then re-reads each one back from
#                                         # the bucket to verify it landed
#                                         # intact.
#
# upload is parallelized because a serial put+head round trip per file over
# ~5900 files (mostly small) ran at under 1 file/sec in testing — nearly 3
# hours for what is otherwise a same-datacenter transfer. Each row is
# independent (keyed by its own fileid), so there is no ordering requirement
# forcing serial execution.
#
# A clean "upload" run is a PREREQUISITE for flipping the live objectstore
# config, not the same action — that flip is a deliberate separate step
# (occ config:system:set objectstore ...) done during a maintenance window
# after this script's summary shows zero missing/mismatched/failed files.
set -euo pipefail

ENV_FILE="${ENV_FILE:-/etc/onevoice/onevoice.env}"
# shellcheck disable=SC1090
source "$ENV_FILE"

export NC_PATH="${NEXTCLOUD_PATH:-/var/www/nextcloud}"
export DATA_DIR="${NEXTCLOUD_DATA_DIR:-${NC_PATH}/data}"
MODE="${1:-}"
PARALLEL="${PARALLEL:-8}"

if [[ "$MODE" != "verify" && "$MODE" != "upload" ]]; then
  echo "Usage: $0 {verify|upload}" >&2
  exit 1
fi

for v in S3_BUCKET S3_REGION S3_ACCESS_KEY S3_SECRET_KEY S3_HOSTNAME DB_HOST DB_NAME DB_USER DB_PASSWORD; do
  if [ -z "${!v:-}" ]; then
    echo "FATAL: $v is not set in $ENV_FILE" >&2
    exit 1
  fi
done

if ! command -v aws >/dev/null 2>&1; then
  echo "FATAL: aws CLI not found. Install with: dnf install -y awscli2" >&2
  exit 1
fi

export AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY"
export AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY"
export S3_ENDPOINT="https://${S3_HOSTNAME}"
export S3_REGION S3_BUCKET MODE

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# One row in, one status line out. Run standalone per worker (not sourced),
# so a single file's failure under `set -e` can't take down the batch.
cat > "${WORKDIR}/process_row.sh" <<'WORKER'
#!/bin/bash
line="$1"
IFS=$'\t' read -r storage_id fileid rel_path size <<< "$line"

case "$storage_id" in
  home::*)   local_path="${DATA_DIR}/${storage_id#home::}/${rel_path}" ;;
  local::*)  local_path="${storage_id#local::}${rel_path}" ;;
  *)         local_path="" ;;
esac

if [[ -z "$local_path" || ! -f "$local_path" ]]; then
  echo "MISSING	${fileid}	storage=${storage_id} path=${rel_path}"
  exit 0
fi

actual_size=$(stat -c%s "$local_path")
if [[ "$actual_size" != "$size" ]]; then
  echo "MISMATCH	${fileid}	db=${size} disk=${actual_size} path=${local_path}"
  exit 0
fi

if [[ "$MODE" != "upload" ]]; then
  echo "OK	${fileid}	${actual_size}"
  exit 0
fi

key="urn:oid:${fileid}"
if ! aws s3api put-object \
    --endpoint-url "$S3_ENDPOINT" --region "$S3_REGION" \
    --bucket "$S3_BUCKET" --key "$key" --body "$local_path" >/dev/null 2>&1; then
  echo "UPLOAD_FAIL	${fileid}	path=${local_path}"
  exit 0
fi

remote_size=$(aws s3api head-object \
    --endpoint-url "$S3_ENDPOINT" --region "$S3_REGION" \
    --bucket "$S3_BUCKET" --key "$key" \
    --query 'ContentLength' --output text 2>/dev/null) || remote_size=""
if [[ "$remote_size" != "$actual_size" ]]; then
  echo "VERIFY_FAIL	${fileid}	local=${actual_size} remote=${remote_size:-<none>}"
  exit 0
fi

echo "OK	${fileid}	${actual_size}"
WORKER
chmod +x "${WORKDIR}/process_row.sh"

echo "==> Enumerating filecache rows (home::* + local:: appdata storages)"
mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASSWORD" "$DB_NAME" -sN -e "
  SELECT s.id, f.fileid, f.path, f.size
  FROM oc_filecache f
  JOIN oc_storages s ON f.storage = s.numeric_id
  JOIN oc_mimetypes m ON f.mimetype = m.id
  WHERE m.mimetype != 'httpd/unix-directory'
    AND (s.id LIKE 'home::%' OR s.id LIKE 'local::%')
" > "${WORKDIR}/rows.tsv"

TOTAL_ROWS=$(wc -l < "${WORKDIR}/rows.tsv")
echo "    ${TOTAL_ROWS} rows to process (mode: ${MODE}, parallel: ${PARALLEL})"

xargs -d '\n' -P "$PARALLEL" -I{} "${WORKDIR}/process_row.sh" {} \
  < "${WORKDIR}/rows.tsv" > "${WORKDIR}/results.tsv"

OK=$(grep -c "^OK	"          "${WORKDIR}/results.tsv" || true)
MISSING=$(grep -c "^MISSING	" "${WORKDIR}/results.tsv" || true)
SIZE_MISMATCH=$(grep -c "^MISMATCH	" "${WORKDIR}/results.tsv" || true)
UPLOAD_FAIL=$(grep -c "^UPLOAD_FAIL	" "${WORKDIR}/results.tsv" || true)
VERIFY_FAIL=$(grep -c "^VERIFY_FAIL	" "${WORKDIR}/results.tsv" || true)
TOTAL_BYTES=$(grep "^OK	" "${WORKDIR}/results.tsv" | cut -f3 | awk '{sum+=$1} END{print sum+0}')

echo
echo "==> Details (non-OK rows)"
grep -v "^OK	" "${WORKDIR}/results.tsv" >&2 || true

echo
echo "==> Summary (${MODE})"
echo "    OK:              ${OK} files, ${TOTAL_BYTES} bytes"
echo "    Missing on disk: ${MISSING}"
echo "    Size mismatch:   ${SIZE_MISMATCH}"
if [[ "$MODE" == "upload" ]]; then
  echo "    Upload failed:   ${UPLOAD_FAIL}"
  echo "    Verify failed:   ${VERIFY_FAIL}"
fi

if [[ "$MISSING" -gt 0 || "$SIZE_MISMATCH" -gt 0 || "$UPLOAD_FAIL" -gt 0 || "$VERIFY_FAIL" -gt 0 ]]; then
  echo "FAILED: inconsistencies found above. Do not flip objectstore config." >&2
  exit 1
fi

echo "All rows accounted for and verified clean."
