#!/bin/bash
#
# nextcloud-settings.sh: OneVoice-specific Nextcloud system settings that
# live only in config.php (backed up nightly) and so aren't set by
# anything else in this repo. Idempotent: safe to re-run after a restore or
# on a fresh install.
#
#   preview_concurrency_new=1 / preview_concurrency_all=4 (#111)
#     A video preview first tries the first 5 MB of the file; for an mp4 whose
#     index sits at the end, that fails and Nextcloud copies the WHOLE file to
#     the container's /tmp (28.7 GB for the largest one on the B2 mount).
#     Several of those in parallel filled the disk on 2026-10-07. One new
#     preview at a time keeps previews working while capping the worst case at
#     a single copy. Cached previews are unaffected (_all bounds those).
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

occ config:system:set preview_concurrency_new --value=1 --type=integer
occ config:system:set preview_concurrency_all --value=4 --type=integer
