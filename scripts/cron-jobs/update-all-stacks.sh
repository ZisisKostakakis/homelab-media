#!/bin/bash
# Cron Job: Update All Docker Stacks

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

LOG_FILE="/var/log/homelab/update-all-stacks.log"

echo "[$(date)] Starting stack update" >> "$LOG_FILE"
cd "$REPO_DIR"
./stack-manage.sh all update >> "$LOG_FILE" 2>&1
echo "[$(date)] Done" >> "$LOG_FILE"
