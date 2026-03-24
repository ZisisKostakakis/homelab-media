#!/bin/bash
# Cron Environment Setup
# Installs the crontab environment preamble (SHELL, PATH, MAILTO).
# Safe to re-run — existing preamble lines are replaced, not duplicated.
# Does not touch any job entries.

set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

LOG_DIR="/var/log/homelab"

echo -e "${GREEN}=== Homelab Cron Environment Setup ===${NC}"

# Create shared log directory for cron jobs
if [ ! -d "$LOG_DIR" ]; then
    echo "Creating log directory: $LOG_DIR"
    mkdir -p "$LOG_DIR"
    echo -e "${GREEN}Created $LOG_DIR${NC}"
else
    echo -e "${YELLOW}Log directory already exists: $LOG_DIR${NC}"
fi

# Read current crontab (empty string if none exists)
CURRENT_CRON=$(crontab -l 2>/dev/null || true)

# Strip any existing preamble lines (handles re-runs and value changes)
FILTERED=$(echo "$CURRENT_CRON" | grep -v -E '^(SHELL|PATH|MAILTO)=')

# Canonical preamble block
PREAMBLE="SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MAILTO=\"\""

# Rebuild crontab: preamble at top, then existing job lines
if [ -n "$FILTERED" ]; then
    printf '%s\n\n%s\n' "$PREAMBLE" "$FILTERED" | crontab -
else
    printf '%s\n' "$PREAMBLE" | crontab -
fi

echo ""
echo -e "${GREEN}Crontab environment preamble installed:${NC}"
echo "  SHELL=/bin/bash"
echo "  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
echo "  MAILTO=\"\""
echo ""
echo -e "${GREEN}Done. Run individual cron-jobs scripts to register jobs.${NC}"
echo "Current crontab:"
echo "---"
crontab -l
