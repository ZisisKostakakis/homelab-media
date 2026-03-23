#!/bin/bash
# Cron Job: Update All Docker Stacks
# Self-registers its own cron entry. Run this script to install/update the job.
# Re-running is safe — existing entry is replaced, not duplicated.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

CRON_SCHEDULE="0 4 * * *"
LOG_FILE="/var/log/homelab/update-all-stacks.log"
CRON_TAG="# homelab:update-all-stacks"

echo "=== Registering cron job: update-all-stacks ==="

CURRENT_CRON=$(crontab -l 2>/dev/null || true)
FILTERED=$(echo "$CURRENT_CRON" | grep -v "$CRON_TAG")

NEW_LINE="${CRON_SCHEDULE} cd ${REPO_DIR} && ./stack-manage.sh all update >> ${LOG_FILE} 2>&1 ${CRON_TAG}"

printf '%s\n%s\n' "$FILTERED" "$NEW_LINE" | crontab -

echo "Installed: $NEW_LINE"
echo "Verify with: crontab -l"
