#!/bin/bash
# Cron Environment Setup
# Installs the crontab environment preamble (SHELL, PATH, MAILTO).
# Safe to re-run — existing preamble lines are replaced, not duplicated.

set -e

LOG_DIR="/var/log/homelab"

if [ ! -d "$LOG_DIR" ]; then
    mkdir -p "$LOG_DIR"
    echo "Created $LOG_DIR"
else
    echo "Already exists: $LOG_DIR"
fi

CURRENT_CRON=$(crontab -l 2>/dev/null || true)

# Strip existing preamble to avoid duplicates on re-run
FILTERED=$(echo "$CURRENT_CRON" | grep -v -E '^(SHELL|PATH|MAILTO)=')

PREAMBLE="SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MAILTO=\"\""

if [ -n "$FILTERED" ]; then
    printf '%s\n\n%s\n' "$PREAMBLE" "$FILTERED" | crontab -
else
    printf '%s\n' "$PREAMBLE" | crontab -
fi

echo "Crontab preamble installed."
echo "---"
crontab -l
