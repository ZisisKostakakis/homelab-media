#!/bin/bash
# Cron Job: Update All Docker Stacks
# Self-registers its own cron entry. Run this script to install/update the job.
# Re-running is safe — existing entry is replaced, not duplicated.
# Only ever touches lines tagged with its unique CRON_TAG.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# --- CONFIGURABLE ---
CRON_SCHEDULE="0 4 * * *"    # Daily at 4:00 AM — edit this to change the schedule
LOG_FILE="/var/log/homelab/update-all-stacks.log"
# --------------------

# Unique tag used as the deduplication key for this job's cron entry
CRON_TAG="# homelab:update-all-stacks"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== Registering cron job: update-all-stacks ===${NC}"

# Read current crontab (empty string if none exists)
CURRENT_CRON=$(crontab -l 2>/dev/null || true)

# Remove any existing entry for this job
FILTERED=$(echo "$CURRENT_CRON" | grep -v "$CRON_TAG")

# Build the new job line
NEW_LINE="${CRON_SCHEDULE} cd ${REPO_DIR} && ./stack-manage.sh all update >> ${LOG_FILE} 2>&1 ${CRON_TAG}"

# Append and install
printf '%s\n%s\n' "$FILTERED" "$NEW_LINE" | crontab -

echo ""
echo -e "${GREEN}Installed cron entry:${NC}"
echo "  $NEW_LINE"
echo ""
echo -e "${YELLOW}Schedule:${NC} ${CRON_SCHEDULE}"
echo -e "${YELLOW}Log file:${NC} ${LOG_FILE}"
echo ""
echo -e "${GREEN}Done. Verify with: crontab -l${NC}"
