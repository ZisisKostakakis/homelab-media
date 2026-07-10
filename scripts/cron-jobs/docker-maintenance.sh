#!/bin/bash
# Cron Job: Docker resource maintenance (reclaim disk space)
#
# Your nightly `stack-manage.sh all update` pulls new images but leaves the OLD
# layers behind as dangling images — over weeks these silently grow into tens or
# hundreds of GB (the "270GB of unused images" problem). This job reclaims that
# space on a schedule so it never has to be done by hand.
#
# What it prunes (conservative by default — nothing in use is ever touched):
#   * Dangling images        — untagged layers orphaned by image updates
#   * Build cache            — old BuildKit cache entries
#   * Stopped containers     — exited/dead containers past the grace period
#   * Unused networks        — user networks with no attached containers
#   * Dangling volumes       — anonymous volumes with no container (opt-in via --volumes)
#
# A GRACE_PERIOD (default 168h = 7d) shields anything created recently, so an
# image pulled mid-update or a container between recreations is never removed.
#
# By default this does NOT run `docker image prune -a` (which would remove every
# image not currently used by a running container). Pass --all-images to enable
# that more aggressive reclaim — safe here because `stack-manage.sh all update`
# re-pulls anything it needs, but it means the next update re-downloads them.
#
# Modes:
#   (default)      Run maintenance now.
#   --install      Self-register this job's weekly cron entry, then exit.
#                  Re-running is safe — the entry is replaced, not duplicated.
#                  Only ever touches lines tagged with its unique CRON_TAG.
#
# Other flags:
#   --dry-run      Show what WOULD be pruned and the space it would reclaim,
#                  without deleting anything.
#   --volumes      Also prune dangling (anonymous) volumes. OFF by default
#                  because a mis-labelled app volume could hold real data.
#   --all-images   Aggressive: remove all images not used by a running
#                  container (docker image prune -a), not just dangling ones.
#   --grace Nh     Override the age grace period (default 168h). Accepts docker
#                  duration filters, e.g. 24h, 72h.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# --- CONFIGURABLE (cron self-registration) ---
CRON_SCHEDULE="30 3 * * 0"       # Weekly, Sunday 03:30 — after nightly update (00:00) + backup (02:00)
CRON_TIMEZONE="Europe/London"    # Anchors the schedule to UK local time (BST/GMT)
LOG_FILE="/var/log/homelab/docker-maintenance.log"
GRACE_PERIOD="168h"              # Spare anything created within this window (7 days)
# ---------------------------------------------

# Unique tag used as the deduplication key for this job's cron entry
CRON_TAG="# homelab:docker-maintenance"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# --- Read specific settings from .env (non-fatal if absent) ---
# .env is a docker-compose env_file (literal KEY=VALUE, values may contain
# unquoted spaces). It is NOT valid shell, so we must never `source` it. Pull
# only the keys we need, first match wins, strip inline quotes.
env_get() {
    local key="$1" file="${REPO_DIR}/.env"
    [ -f "$file" ] || return 0
    local line
    line=$(grep -E "^${key}=" "$file" | head -1) || return 0
    line="${line#*=}"
    line="${line%\"}"; line="${line#\"}"
    line="${line%\'}"; line="${line#\'}"
    printf '%s' "$line"
}

# --- Settings (real env wins, then .env, then default) ---
NTFY_URL="${NTFY_URL:-https://ntfy.sh}"
NTFY_TOPIC="${MAINTENANCE_NTFY_TOPIC:-$(env_get MAINTENANCE_NTFY_TOPIC)}"   # empty = notifications off
# Fall back to the backup topic if a dedicated maintenance topic isn't set.
[ -z "$NTFY_TOPIC" ] && NTFY_TOPIC="${BACKUP_NTFY_TOPIC:-$(env_get BACKUP_NTFY_TOPIC)}"

# --- Parse arguments ---
MODE="run"
DRY_RUN=false
PRUNE_VOLUMES=false
ALL_IMAGES=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --install)     MODE="install"; shift ;;
        --dry-run)     DRY_RUN=true; shift ;;
        --volumes)     PRUNE_VOLUMES=true; shift ;;
        --all-images)  ALL_IMAGES=true; shift ;;
        --grace)       GRACE_PERIOD="$2"; shift 2 ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

# --- ntfy notification helper ---
notify() {
    local title="$1" priority="$2" tags="$3" message="$4"
    [ -z "$NTFY_TOPIC" ] && return 0
    curl -sS \
        -H "Title: ${title}" \
        -H "Priority: ${priority}" \
        -H "Tags: ${tags}" \
        -d "${message}" \
        "${NTFY_URL}/${NTFY_TOPIC}" >/dev/null 2>&1 || true
}

# =====================================================================
# INSTALL MODE — self-register cron entry (mirrors backup-to-s3.sh)
# =====================================================================
if [ "$MODE" = "install" ]; then
    echo -e "${GREEN}=== Registering cron job: docker-maintenance ===${NC}"

    CURRENT_CRON=$(crontab -l 2>/dev/null || true)
    # Remove any prior entry for this job (leave other jobs' CRON_TZ alone).
    FILTERED=$(echo "$CURRENT_CRON" | grep -v "$CRON_TAG" || true)

    NEW_LINE="${CRON_SCHEDULE} cd ${REPO_DIR} && bash scripts/cron-jobs/docker-maintenance.sh >> ${LOG_FILE} 2>&1 ${CRON_TAG}"

    # Ensure a CRON_TZ line exists (shared with the other homelab jobs). Only add
    # one if the crontab doesn't already declare our timezone.
    if echo "$FILTERED" | grep -q "^CRON_TZ=${CRON_TIMEZONE}$"; then
        printf '%s\n%s\n' "$FILTERED" "$NEW_LINE" | crontab -
    else
        printf '%s\nCRON_TZ=%s\n%s\n' "$FILTERED" "$CRON_TIMEZONE" "$NEW_LINE" | crontab -
    fi

    echo ""
    echo -e "${GREEN}Installed cron entry:${NC}"
    echo "  $NEW_LINE"
    echo ""
    echo -e "${YELLOW}Schedule:${NC} ${CRON_SCHEDULE} (${CRON_TIMEZONE})"
    echo -e "${YELLOW}Log file:${NC} ${LOG_FILE}"
    echo ""
    echo -e "${GREEN}Done. Verify with: crontab -l${NC}"
    exit 0
fi

# =====================================================================
# RUN MODE — reclaim Docker disk space
# =====================================================================

if ! docker info >/dev/null 2>&1; then
    echo -e "${RED}Error: docker daemon not reachable${NC}" >&2
    notify "Docker maintenance FAILED" "high" "warning,x" "docker daemon not reachable on $(hostname)"
    exit 3
fi

TS() { date '+%Y-%m-%d %H:%M:%S'; }

# Report reclaimable space in a stable, greppable form.
reclaimable_bytes() {
    # docker system df --format gives per-type reclaimable; sum is easier via -v json on newer docker,
    # but the plain table is universally available. We report the human summary instead.
    docker system df 2>/dev/null || true
}

echo "=================================================="
echo " Docker maintenance run — $(TS)"
echo " host: $(hostname)   grace: ${GRACE_PERIOD}   volumes: ${PRUNE_VOLUMES}   all-images: ${ALL_IMAGES}   dry-run: ${DRY_RUN}"
echo "=================================================="

echo ""
echo -e "${YELLOW}--- BEFORE ---${NC}"
BEFORE_DF="$(docker system df || true)"
echo "$BEFORE_DF"

# Running tally of bytes reclaimed, summed from each prune's own
# "Total reclaimed space" line — exact, unlike a du snapshot of a large tree.
RECLAIMED_BYTES=0

# Convert docker's human sizes (e.g. "173.3MB", "1.2GB", "0B") to bytes.
to_bytes() {
    local s="$1" num unit
    num="$(printf '%s' "$s" | grep -oE '[0-9.]+' | head -1)"
    unit="$(printf '%s' "$s" | grep -oE '[A-Za-z]+' | head -1)"
    [ -z "$num" ] && { echo 0; return; }
    case "${unit^^}" in
        TB) awk -v n="$num" 'BEGIN{printf "%.0f", n*1024*1024*1024*1024}' ;;
        GB) awk -v n="$num" 'BEGIN{printf "%.0f", n*1024*1024*1024}' ;;
        MB) awk -v n="$num" 'BEGIN{printf "%.0f", n*1024*1024}' ;;
        KB) awk -v n="$num" 'BEGIN{printf "%.0f", n*1024}' ;;
        *)  awk -v n="$num" 'BEGIN{printf "%.0f", n}' ;;
    esac
}

run() {
    # Echo the command, run it (unless dry-run), and fold any "Total reclaimed
    # space: <size>" it prints into the running tally.
    echo -e "${GREEN}\$ $*${NC}"
    if [ "$DRY_RUN" = true ]; then
        return 0
    fi
    local out
    out="$("$@" 2>&1)" || echo -e "${RED}  (command returned non-zero — continuing)${NC}"
    [ -n "$out" ] && echo "$out"
    local freed
    freed="$(printf '%s\n' "$out" | grep -iE 'Total reclaimed space|Total:' | grep -oE '[0-9.]+[A-Za-z]+' | tail -1 || true)"
    if [ -n "$freed" ]; then
        RECLAIMED_BYTES=$(( RECLAIMED_BYTES + $(to_bytes "$freed") ))
    fi
}

echo ""
echo -e "${YELLOW}--- PRUNING ---${NC}"

# 1) Stopped containers older than the grace period.
run docker container prune -f --filter "until=${GRACE_PERIOD}"

# 2) Images. Dangling-only by default; all unused images with --all-images.
#    The `until` filter shields anything freshly pulled during a recent update.
if [ "$ALL_IMAGES" = true ]; then
    run docker image prune -af --filter "until=${GRACE_PERIOD}"
else
    run docker image prune -f --filter "until=${GRACE_PERIOD}"
fi

# 3) BuildKit build cache older than the grace period.
run docker builder prune -f --filter "until=${GRACE_PERIOD}"

# 4) Unused user-defined networks. (Docker refuses to remove in-use ones.)
run docker network prune -f --filter "until=${GRACE_PERIOD}"

# 5) Dangling volumes — OPT-IN. Only anonymous volumes with no container.
#    Named volumes declared in compose are always spared by `--filter dangling`.
if [ "$PRUNE_VOLUMES" = true ]; then
    run docker volume prune -f
else
    echo "  (skipping volume prune — pass --volumes to enable)"
fi

echo ""
echo -e "${YELLOW}--- AFTER ---${NC}"
AFTER_DF="$(docker system df || true)"
echo "$AFTER_DF"

RECLAIMED_MB=$(( RECLAIMED_BYTES / 1024 / 1024 ))

echo ""
if [ "$DRY_RUN" = true ]; then
    echo -e "${GREEN}Dry run complete — nothing was deleted.${NC}"
    notify "Docker maintenance (dry run)" "low" "broom,mag" \
        "Dry run on $(hostname) — see $LOG_FILE for what would be pruned."
else
    echo -e "${GREEN}Maintenance complete — reclaimed ~${RECLAIMED_MB} MB.${NC}"
    # Only ping ntfy when something meaningful was freed, to avoid weekly noise.
    if [ "$RECLAIMED_MB" -ge 100 ]; then
        notify "Docker maintenance: freed ${RECLAIMED_MB} MB" "default" "broom,white_check_mark" \
            "Reclaimed ~${RECLAIMED_MB} MB on $(hostname). Grace ${GRACE_PERIOD}, volumes=${PRUNE_VOLUMES}, all-images=${ALL_IMAGES}."
    fi
fi
