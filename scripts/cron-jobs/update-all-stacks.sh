#!/bin/bash
# Daily cron job: update all Docker stacks
# Run manually to trigger an update, or add to crontab:
# 0 4 * * * /root/Github/homelab-media/scripts/cron-jobs/update-all-stacks.sh

set -e

LOG_FILE="/var/log/homelab/update-all-stacks.log"
REPO="/root/Github/homelab-media"

echo "[$(date)] Starting stack update" >> "$LOG_FILE"
cd "$REPO"
./stack-manage.sh all update >> "$LOG_FILE" 2>&1
echo "[$(date)] Done" >> "$LOG_FILE"
