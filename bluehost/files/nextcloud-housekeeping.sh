#!/bin/bash
#
# nextcloud-housekeeping.sh: weekly disk reclaim on the Bluehost host.
#
# Removes only things nothing needs. It never touches user files, trash,
# versions or previews; Nextcloud's own retention jobs own those.
#   - dangling Docker images left behind by image rebuilds
#   - Docker build cache older than a week
#   - files older than 24 h in the app/cron containers' /tmp: orphans from
#     preview generation or uploads that died mid-way. A video preview copies
#     the whole source file there (28 GB on 2026-10-07), so a crashed one is
#     expensive to leave behind.
#   - journald beyond 300 MB, and dnf's package cache
set -uo pipefail
free_mb() { df --output=avail -BM / | tail -1 | tr -dc '0-9'; }
before=$(free_mb)

docker image prune -f >/dev/null
docker builder prune -f --filter until=168h >/dev/null
for c in onevoice-app-1 onevoice-cron-1; do
  if docker inspect "$c" >/dev/null 2>&1; then
    docker exec "$c" find /tmp -xdev -mindepth 1 -type f -mmin +1440 -delete 2>/dev/null || true
  fi
done
journalctl --vacuum-size=300M >/dev/null 2>&1 || true
dnf clean packages -q >/dev/null 2>&1 || true

after=$(free_mb)
echo "housekeeping: reclaimed $(( after - before )) MiB; root fs now has ${after} MiB free"
