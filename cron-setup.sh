#!/bin/bash
# Cron Environment Setup
# Installs crontab preamble and creates log directory.

set -e

LOG_DIR="/var/log/homelab"

if [ ! -d "$LOG_DIR" ]; then
    mkdir -p "$LOG_DIR"
    echo "Created $LOG_DIR"
else
    echo "Already exists: $LOG_DIR"
fi

PREAMBLE="SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MAILTO=\"\""

CURRENT_CRON=$(crontab -l 2>/dev/null || true)
printf '%s\n\n%s\n' "$PREAMBLE" "$CURRENT_CRON" | crontab -

echo "Crontab preamble installed."
echo "---"
crontab -l
