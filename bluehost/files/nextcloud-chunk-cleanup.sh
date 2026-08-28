#!/bin/bash
#
# nextcloud-chunk-cleanup.sh — removes stale WebDAV chunked-upload staging
# directories.
#
# When a chunked upload's final assembly (MOVE) fails — e.g. the destination
# filename contains a character Nextcloud forbids, as happened with Logic Pro
# autosave files containing ":" — the chunks already written to
# data/<user>/uploads/<token>/ are never cleaned up, and a client that keeps
# retrying the same doomed upload keeps adding to them indefinitely. This
# filled the disk to 100% on 2026-08-23 (issue #80). Nextcloud's own
# stale-upload background job never catches this case because each retry
# refreshes the folder's mtime, so it never looks stale to that job.
#
# Deletes any uploads/<token>/ directory whose mtime is older than
# STALE_HOURS — a retrying client just starts the token over from scratch, so
# this is safe to run unconditionally.
set -euo pipefail

DATA_DIR="${NEXTCLOUD_DATA_DIR:-/var/www/nextcloud/data}"
STALE_HOURS="${CHUNK_CLEANUP_STALE_HOURS:-3}"
STALE_MINUTES=$((STALE_HOURS * 60))

find "$DATA_DIR" -mindepth 3 -maxdepth 3 -type d -path '*/uploads/*' -mmin +"$STALE_MINUTES" -print0 |
while IFS= read -r -d '' token_dir; do
  echo "Removing stale chunk upload: $token_dir"
  rm -rf -- "$token_dir"
done
