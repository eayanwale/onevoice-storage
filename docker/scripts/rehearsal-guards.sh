#!/bin/bash
#
# rehearsal-guards.sh: make a NON-production copy safe to run. Rehearsal
# only; this never runs on production.
#
# A restored copy is production's twin: it holds the B2 external-storage
# credentials, every member's email, the mobile push registrations and any
# webhooks. Started as-is, its background jobs would act on all of them.
#
#   sql     (db running, app NOT yet started)
#           - every external mount gets readonly=true
#           - every member email is dropped except KEEP_EMAIL_USER's, so
#             nothing is even attempted to real addresses (and nothing bounces
#             off SES, which hurts its sending reputation)
#           - mobile push registrations and webhooks are cleared
#   config  (app running, still in maintenance)
#           - has_internet_connection=false: no app store, lookup server or
#             push-proxy calls. SMTP and the B2 mount are unaffected.
#           - trusted_domains / overwrite.cli.url point at the lab URL
#   verify  print what the guards changed
#
# Env: KEEP_EMAIL_USER (default admin), LAB_URL (default http://localhost:8080)
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

[[ "${HOMELAB_APP:-}" == *rehearsal* ]] \
  || die "HOMELAB_APP=${HOMELAB_APP:-} does not look like a rehearsal; refusing to run guards here"

KEEP_EMAIL_USER="${KEEP_EMAIL_USER:-admin}"
LAB_URL="${LAB_URL:-http://localhost:8080}"
LAB_HOSTPORT="${LAB_URL#*://}"

table_exists() {
  [[ "$(echo "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=DATABASE() AND table_name='$1';" | db_sql)" == 1 ]]
}

guard_sql() {
  log "SQL guards"
  {
    echo "DELETE FROM oc_external_options WHERE \`key\`='readonly';"
    echo "INSERT INTO oc_external_options (mount_id, \`key\`, value) SELECT mount_id, 'readonly', 'true' FROM oc_external_mounts;"
    echo "DELETE FROM oc_preferences WHERE appid='settings' AND configkey='email' AND userid <> '${KEEP_EMAIL_USER}';"
  } | db_sql
  table_exists oc_notifications_pushhash && echo "DELETE FROM oc_notifications_pushhash;" | db_sql
  table_exists oc_webhook_listeners && echo "DELETE FROM oc_webhook_listeners;" | db_sql
  guard_verify
}

guard_config() {
  log "Config guards"
  occ config:system:set has_internet_connection --value=false --type=boolean
  occ config:system:set trusted_domains 10 --value="$LAB_HOSTPORT"
  occ config:system:set overwrite.cli.url --value="$LAB_URL"
  if [[ "$LAB_URL" == http://* ]]; then occ config:system:delete overwriteprotocol; fi
}

guard_verify() {
  log "Guard state"
  echo "SELECT CONCAT('    readonly mounts: ', COUNT(*)) FROM oc_external_options WHERE \`key\`='readonly' AND value='true';
SELECT CONCAT('    external mounts:  ', COUNT(*)) FROM oc_external_mounts;
SELECT CONCAT('    users with email: ', COUNT(*), ' (', IFNULL(GROUP_CONCAT(userid),''), ')') FROM oc_preferences WHERE appid='settings' AND configkey='email';" | db_sql
  table_exists oc_notifications_pushhash && echo "SELECT CONCAT('    push registrations: ', COUNT(*)) FROM oc_notifications_pushhash;" | db_sql
  table_exists oc_webhook_listeners && echo "SELECT CONCAT('    webhooks: ', COUNT(*)) FROM oc_webhook_listeners;" | db_sql
  return 0
}

case "${1:-}" in
  sql) guard_sql ;;
  config) guard_config ;;
  verify) guard_verify ;;
  *) die "usage: $0 sql|config|verify" ;;
esac
