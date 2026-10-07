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
#
#   Preview Generator app (#113): pre-generates previews in the background.
#     Only the sizes the web UI actually requests are made. Measured from the
#     nginx log on 2026-10-07, 97% of preview requests are the Files grid
#     (x=y=1024, a=1, mode=cover); the rest are the 64/256 square list
#     thumbnails. An empty value means "skip this size" (unset would mean
#     "all defaults").
#     job_disabled=true: the app's own background job would run inside the
#     CRON container, a separate SysV IPC namespace that does not share
#     preview_concurrency_new with the web. The host timers
#     nextcloud-preview-{generate,pregenerate} run the same commands in the
#     APP container instead.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

occ config:system:set preview_concurrency_new --value=1 --type=integer
occ config:system:set preview_concurrency_all --value=4 --type=integer

occ app:install previewgenerator 2>/dev/null || occ app:enable previewgenerator
occ config:app:set previewgenerator squareSizes           --value="64 256"
occ config:app:set previewgenerator coverWidthHeightSizes --value="1024"
occ config:app:set previewgenerator fillWidthHeightSizes  --value=""
occ config:app:set previewgenerator widthSizes            --value=""
occ config:app:set previewgenerator heightSizes           --value=""
occ config:app:set previewgenerator job_disabled          --value=true --type=boolean
