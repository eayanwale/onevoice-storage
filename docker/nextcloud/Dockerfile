# OneVoice Nextcloud image: the official 30.0.0 fpm image plus the two things
# production depends on that it doesn't ship.
#
# Pinned to exactly 30.0.0 because that is what production runs; upgrades are
# a separate, one-step-at-a-time phase (docs/migration/plan.md, "Later phases").
ARG NEXTCLOUD_TAG=30.0.0-fpm
FROM nextcloud:${NEXTCLOUD_TAG}

# ffmpeg: preview_ffmpeg_path=/usr/bin/ffmpeg, the Movie preview provider and
# workflow_media_converter all shell out to it.
# bz2: loaded on the native host; cheap to match.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ffmpeg libbz2-dev; \
    docker-php-ext-install -j"$(nproc)" bz2; \
    apt-get purge -y --auto-remove libbz2-dev; \
    apt-get install -y --no-install-recommends libbz2-1.0; \
    rm -rf /var/lib/apt/lists/*

# #76: retry a transient upstream 5xx when reading an S3 object. The fopen()
# in S3ObjectTrait::readObject bypasses the AWS SDK's own retry middleware, so
# a single B2 blip was a hard read failure. Both the B2 external mount
# (files_external AmazonS3) and any future S3 primary storage go through it.
# https://github.com/eayanwale/onevoice-storage/issues/76
#
# The file is replaced whole, so guard against replacing anything other than
# the exact upstream 30.0.0 file. When a version bump trips this, check whether
# upstream now retries on its own; drop the patch if so, re-derive it if not.
ARG S3_TRAIT_UPSTREAM_SHA256=cd7742bb571719fbecdf4526bcf3be459ab8f3176cf95fed38e28e7e373dfff4
COPY patches/S3ObjectTrait.php /tmp/S3ObjectTrait.php
RUN set -eu; \
    f=/usr/src/nextcloud/lib/private/Files/ObjectStore/S3ObjectTrait.php; \
    echo "${S3_TRAIT_UPSTREAM_SHA256}  $f" | sha256sum -c - \
      || { echo "S3ObjectTrait.php is not the expected upstream file - re-check the #76 patch" >&2; exit 1; }; \
    php -l /tmp/S3ObjectTrait.php; \
    install -o root -g root -m 0644 /tmp/S3ObjectTrait.php "$f"; \
    rm /tmp/S3ObjectTrait.php

COPY php/zz-onevoice.ini /usr/local/etc/php/conf.d/zz-onevoice.ini
COPY php/zz-onevoice-fpm.conf /usr/local/etc/php-fpm.d/zz-onevoice-fpm.conf
