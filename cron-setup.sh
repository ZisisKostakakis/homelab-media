#!/bin/bash
# Cron setup - creates shared log dir

LOG_DIR="/var/log/homelab"

if [ ! -d "$LOG_DIR" ]; then
    mkdir -p "$LOG_DIR"
    echo "Created $LOG_DIR"
else
    echo "Already exists: $LOG_DIR"
fi

echo "Done."
