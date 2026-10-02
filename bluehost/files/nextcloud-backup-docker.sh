#!/bin/bash
# Since 2026-10-02 Nextcloud runs in Docker (#108). Native script kept as
# nextcloud-backup.sh.native for the rollback window.
exec /opt/onevoice-storage/docker/scripts/backup.sh "$@"
