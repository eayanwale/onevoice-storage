#!/bin/bash
set -uo pipefail

NC_PATH="/var/www/nextcloud"
REPO="eayanwale/onevoice-storage"
REPO_URL="https://github.com/${REPO}.git"
SNS_TOPIC_ARN="arn:aws:sns:us-east-1:622247620719:onevoice-prod-ops-alerts"
SNS_REGION="us-east-1"
LABEL="maintenance"
DATE=$(date -u +%Y-%m-%d)
MONTH_YEAR=$(date -u +"%B %Y")

TEST_MODE=0
if [ "${1:-}" = "--test" ]; then
  TEST_MODE=1
fi

if [ "$TEST_MODE" = "1" ]; then
  BRANCH="maintenance/test-${DATE}-$(date -u +%H%M%S)"
  TITLE="[TEST] Nextcloud maintenance checklist - ${MONTH_YEAR}"
  SECTION_TITLE="## ${MONTH_YEAR} Nextcloud maintenance (TEST RUN, ${DATE})"
  SUBJECT_PREFIX="[TEST] "
else
  BRANCH="maintenance/${DATE}"
  TITLE="Nextcloud maintenance checklist - ${MONTH_YEAR}"
  SECTION_TITLE="## ${MONTH_YEAR} Nextcloud maintenance (automated check, ${DATE})"
  SUBJECT_PREFIX=""
fi

WORKDIR=$(mktemp -d)
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

notify() {
  local subject="$1"
  local message="$2"
  aws sns publish --region "$SNS_REGION" --topic-arn "$SNS_TOPIC_ARN" \
    --subject "${SUBJECT_PREFIX}${subject}" --message "$message" >/dev/null
}

fail() {
  local step="$1"
  echo "FAILED: $step"
  notify "Nextcloud maintenance automation FAILED" "Step failed: ${step}. Host $(hostname), $(date -u +%Y-%m-%dT%H:%M:%SZ). Check the box directly - no PR was opened this run."
  exit 1
}

echo "==> Gathering findings"

CORE_VERSION=$(sudo -u nginx php "$NC_PATH/occ" status 2>&1 | grep -oP 'versionstring: \K.*' || echo "unknown")
UPDATE_CHECK=$(sudo -u nginx php "$NC_PATH/occ" update:check 2>&1)

DISK=$(df -h / | tail -1)
DISK_PCT=$(echo "$DISK" | awk '{print $5}')
DISK_AVAIL=$(echo "$DISK" | awk '{print $4}')

MEM_LINE=$(free -h | awk '/^Mem:/')
MEM_AVAIL=$(echo "$MEM_LINE" | awk '{print $7}')
MEM_TOTAL=$(echo "$MEM_LINE" | awk '{print $2}')

DNF_UPDATES=$(sudo dnf check-update 2>&1 | grep -E '^\S+\.(x86_64|noarch)' | wc -l || echo "0")

RUNNING_KERNEL=$(uname -r)
LATEST_INSTALLED_KERNEL=$(rpm -q kernel | sed 's/^kernel-//' | sort -V | tail -1)
if [ "$RUNNING_KERNEL" = "$LATEST_INSTALLED_KERNEL" ]; then
  REBOOT_LINE="No reboot needed (running kernel matches latest installed: ${RUNNING_KERNEL})"
else
  REBOOT_LINE="Reboot recommended: running ${RUNNING_KERNEL}, latest installed is ${LATEST_INSTALLED_KERNEL}"
fi

CRON_USER=$(crontab -l 2>&1)
CRON_ROOT=$(sudo crontab -l 2>&1)
if echo "$CRON_USER $CRON_ROOT" | grep -qi 'no crontab'; then
  BACKUP_CRON_LINE="No cron-based backup job found (user or root crontab)"
else
  BACKUP_CRON_LINE="Cron entries present - review manually: user=[$CRON_USER] root=[$CRON_ROOT]"
fi

EXITED_CONTAINERS=$(sudo docker ps -a --filter "status=exited" --format '{{.Names}} ({{.Image}})' 2>&1)

echo "==> Building checklist section"

cat > "$WORKDIR/section.md" <<EOF
${SECTION_TITLE}

- [ ] Verify EC2 public IP is still current (dynamic, not elastic) - check via \`aws ec2 describe-instances --profile onevoice\`
- [ ] Update Nextcloud core: currently ${CORE_VERSION}. ${UPDATE_CHECK}
- [ ] Check Nextcloud app updates in Admin > Apps > Updates (not reliably listable via occ CLI)
- [ ] OS packages: ${DNF_UPDATES} package(s) with updates available per \`dnf check-update\`
- [ ] Kernel/reboot: ${REBOOT_LINE}
- [ ] Disk usage: ${DISK_PCT} used, ${DISK_AVAIL} available on /
- [ ] Memory: ${MEM_AVAIL} available of ${MEM_TOTAL}
- [ ] Backups: ${BACKUP_CRON_LINE}
$(if [ -n "$EXITED_CONTAINERS" ]; then echo "- [ ] Investigate exited Docker container(s): ${EXITED_CONTAINERS}"; fi)

_Generated automatically by nextcloud-maintenance-check.sh on $(hostname) at $(date -u +%Y-%m-%dT%H:%M:%SZ)._
EOF

echo "==> Ensuring label exists"
gh label list --repo "$REPO" --json name --jq '.[].name' | grep -qx "$LABEL" || \
  gh label create "$LABEL" --repo "$REPO" --color 0E8A16 --description "Nextcloud server maintenance checklist"

echo "==> Creating tracking issue"
ISSUE_URL=$(gh issue create \
  --repo "$REPO" \
  --title "$TITLE" \
  --body "$(cat "$WORKDIR/section.md")" \
  --label "$LABEL") || fail "gh issue create"
ISSUE_NUM=$(basename "$ISSUE_URL")
echo "==> Issue: $ISSUE_URL"

echo "==> Cloning repo"
git clone --quiet --depth 1 -b dev "$REPO_URL" "$WORKDIR/repo" || fail "git clone"
cd "$WORKDIR/repo"
git checkout -b "$BRANCH"

mkdir -p systems
touch systems/maintenance.md
{ echo; cat "$WORKDIR/section.md"; } >> systems/maintenance.md

git config user.name "Nextcloud Maintenance Bot"
git config user.email "maintenance-bot@onevoice.local"
git add systems/maintenance.md
git commit --quiet -m "Add ${MONTH_YEAR} Nextcloud maintenance checklist (automated)"

echo "==> Pushing branch"
git push --quiet origin "$BRANCH" || fail "git push"

echo "==> Opening PR"
PR_URL=$(gh pr create \
  --repo "$REPO" \
  --base dev \
  --head "$BRANCH" \
  --title "$TITLE" \
  --body "Closes #${ISSUE_NUM}

Automated monthly Nextcloud maintenance check. Review findings below and complete the checklist in \`systems/maintenance.md\` as maintenance is performed." \
  --assignee eayanwale \
  --label "$LABEL") || fail "gh pr create"

echo "==> Notifying via SNS"
notify "Nextcloud maintenance checklist ready" "${TITLE} is ready: PR ${PR_URL} (tracking issue ${ISSUE_URL})"

echo "==> Done: ${PR_URL}"