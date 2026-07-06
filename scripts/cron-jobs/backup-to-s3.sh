#!/bin/bash
# Cron Job: Off-host S3 disaster-recovery backup
#
# Produces a fresh config archive via backup-config.sh, then uploads the newest
# archive to AWS S3 through an rclone crypt remote (client-side encrypted).
# Retention of the REMOTE copies is owned by the S3 lifecycle rule, not this
# script — so a compromised host key cannot delete recovery points.
#
# Two modes:
#   (default)   Run a backup + upload now.
#   --install   Self-register this job's cron entry, then exit.
#               Re-running is safe — the entry is replaced, not duplicated.
#               Only ever touches lines tagged with its unique CRON_TAG.
#
# Other flags:
#   --dry-run   Build the archive and show the intended upload without
#               transferring anything to S3.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# --- CONFIGURABLE (cron self-registration) ---
CRON_SCHEDULE="30 0 * * *"       # Daily 00:30 — 30 min after the update-all-stacks job
CRON_TIMEZONE="Europe/London"    # Anchors the schedule to UK local time (BST/GMT)
LOG_FILE="/var/log/homelab/backup-to-s3.log"
# ---------------------------------------------

# Unique tag used as the deduplication key for this job's cron entry
CRON_TAG="# homelab:backup-to-s3"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# --- Read specific settings from .env (non-fatal if absent) ---
# NOTE: .env is a docker-compose env_file (literal KEY=VALUE, values may contain
# unquoted spaces like "Bearer <jwt>"). It is NOT valid shell, so we must never
# `source` it. Pull only the keys we need, first match wins, strip inline quotes.
env_get() {
    local key="$1" file="${REPO_DIR}/.env"
    [ -f "$file" ] || return 0
    local line
    line=$(grep -E "^${key}=" "$file" | head -1) || return 0
    line="${line#*=}"
    # strip surrounding single/double quotes if present
    line="${line%\"}"; line="${line#\"}"
    line="${line%\'}"; line="${line#\'}"
    printf '%s' "$line"
}

# --- Settings (real env wins, then .env, then default) ---
RCLONE_REMOTE="${RCLONE_REMOTE:-$(env_get RCLONE_REMOTE)}"; RCLONE_REMOTE="${RCLONE_REMOTE:-s3-dr-crypt}"
S3_BACKUP_PREFIX="${S3_BACKUP_PREFIX:-$(env_get S3_BACKUP_PREFIX)}"   # optional sub-path
NTFY_URL="${NTFY_URL:-https://ntfy.sh}"
NTFY_TOPIC="${BACKUP_NTFY_TOPIC:-$(env_get BACKUP_NTFY_TOPIC)}"       # empty = notifications off
BACKUP_BASE_DIR="${BACKUP_BASE_DIR:-${REPO_DIR}/config-backups}"

# Assemble the remote destination (crypt remote, optional prefix)
if [ -n "$S3_BACKUP_PREFIX" ]; then
    REMOTE_DEST="${RCLONE_REMOTE}:${S3_BACKUP_PREFIX}"
else
    REMOTE_DEST="${RCLONE_REMOTE}:"
fi

# --- Parse arguments ---
MODE="run"
DRY_RUN=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --install) MODE="install"; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
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
# INSTALL MODE — self-register cron entry (mirrors update-all-stacks.sh)
# =====================================================================
if [ "$MODE" = "install" ]; then
    echo -e "${GREEN}=== Registering cron job: backup-to-s3 ===${NC}"

    CURRENT_CRON=$(crontab -l 2>/dev/null || true)

    # Remove any existing entry for this job. Leave CRON_TZ alone — the
    # update-all-stacks job manages it and both jobs share Europe/London.
    FILTERED=$(echo "$CURRENT_CRON" | grep -v "$CRON_TAG" || true)

    NEW_LINE="${CRON_SCHEDULE} cd ${REPO_DIR} && bash scripts/cron-jobs/backup-to-s3.sh >> ${LOG_FILE} 2>&1 ${CRON_TAG}"
    TZ_LINE="CRON_TZ=${CRON_TIMEZONE}"

    # Ensure a CRON_TZ line exists exactly once, ahead of the job line.
    if echo "$FILTERED" | grep -q '^CRON_TZ='; then
        printf '%s\n%s\n' "$FILTERED" "$NEW_LINE" | crontab -
    else
        printf '%s\n%s\n%s\n' "$FILTERED" "$TZ_LINE" "$NEW_LINE" | crontab -
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
# RUN MODE — build archive + upload to S3
# =====================================================================
echo -e "${GREEN}=== S3 Disaster-Recovery Backup ===${NC}"
[ "$DRY_RUN" = true ] && echo -e "${YELLOW}DRY RUN — nothing will be uploaded${NC}"
echo "Started: $(date)"
echo "Remote:  ${REMOTE_DEST}"
echo ""

# Preflight: rclone present and the remote is configured
if ! command -v rclone >/dev/null 2>&1; then
    echo -e "${RED}Error: rclone not installed. Run scripts/install-rclone.sh first.${NC}" >&2
    notify "S3 backup FAILED" "5" "x,rotating_light" "rclone not installed on $(hostname)"
    exit 1
fi

if ! rclone listremotes 2>/dev/null | grep -qx "${RCLONE_REMOTE}:"; then
    echo -e "${RED}Error: rclone remote '${RCLONE_REMOTE}:' not configured.${NC}" >&2
    echo -e "${RED}Configure it with 'rclone config' (see README Disaster Recovery section).${NC}" >&2
    notify "S3 backup FAILED" "5" "x,rotating_light" "rclone remote ${RCLONE_REMOTE}: missing on $(hostname)"
    exit 1
fi

# 1) Build a fresh local archive using the existing backup script.
#    backup-config.sh owns WHAT gets archived + local retention (keep-5).
echo -e "${GREEN}Building fresh config archive...${NC}"
if ! bash "${REPO_DIR}/backup-config.sh"; then
    echo -e "${RED}Error: backup-config.sh failed.${NC}" >&2
    notify "S3 backup FAILED" "5" "x,rotating_light" "backup-config.sh failed on $(hostname)"
    exit 1
fi

# 2) Locate the newest archive it produced.
LATEST_ARCHIVE=$(ls -t "${BACKUP_BASE_DIR}"/*.tar.gz 2>/dev/null | head -1 || true)
if [ -z "$LATEST_ARCHIVE" ]; then
    echo -e "${RED}Error: no archive found in ${BACKUP_BASE_DIR}.${NC}" >&2
    notify "S3 backup FAILED" "5" "x,rotating_light" "no archive produced on $(hostname)"
    exit 1
fi
ARCHIVE_NAME="$(basename "$LATEST_ARCHIVE")"
ARCHIVE_SIZE="$(du -sh "$LATEST_ARCHIVE" | cut -f1)"
echo ""
echo -e "${GREEN}Newest archive:${NC} ${ARCHIVE_NAME} (${ARCHIVE_SIZE})"

# 3) Upload through the crypt remote (contents + filename encrypted client-side).
if [ "$DRY_RUN" = true ]; then
    echo ""
    echo -e "${YELLOW}[dry-run] Would upload ${ARCHIVE_NAME} → ${REMOTE_DEST}${NC}"
    rclone copy --dry-run "$LATEST_ARCHIVE" "$REMOTE_DEST" 2>&1 || true
    echo ""
    echo -e "${YELLOW}Dry run complete — nothing uploaded.${NC}"
    exit 0
fi

echo ""
echo -e "${GREEN}Uploading to S3 (encrypted)...${NC}"
if rclone copy --progress "$LATEST_ARCHIVE" "$REMOTE_DEST"; then
    echo -e "${GREEN}Upload OK.${NC}"
else
    echo -e "${RED}Error: rclone upload failed.${NC}" >&2
    notify "S3 backup FAILED" "5" "x,rotating_light" \
        "Upload of ${ARCHIVE_NAME} failed on $(hostname). Check ${LOG_FILE}"
    exit 1
fi

# 4) Verify the object is now present remotely (defensive round-trip).
if rclone lsf "$REMOTE_DEST" 2>/dev/null | grep -qx "$ARCHIVE_NAME"; then
    echo -e "${GREEN}Verified ${ARCHIVE_NAME} present on remote.${NC}"
else
    echo -e "${RED}Warning: uploaded archive not visible in remote listing.${NC}" >&2
    notify "S3 backup WARNING" "4" "warning" \
        "Uploaded ${ARCHIVE_NAME} but it is not visible in ${REMOTE_DEST} on $(hostname)"
    exit 1
fi

# Remote retention is handled by the S3 lifecycle rule (not this script).
echo ""
echo -e "${GREEN}=== S3 Backup Complete ===${NC}"
echo "Archive:  ${ARCHIVE_NAME} (${ARCHIVE_SIZE})"
echo "Remote:   ${REMOTE_DEST}"
echo "Finished: $(date)"
notify "S3 backup OK" "3" "white_check_mark,floppy_disk" \
    "Uploaded ${ARCHIVE_NAME} (${ARCHIVE_SIZE}) to S3 from $(hostname)"
