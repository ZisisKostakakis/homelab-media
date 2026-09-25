#!/bin/bash
# Cron Job: verify the newest off-host S3 backup can actually be restored
#
# A backup nobody has restored is a hope, not a backup. This downloads the
# newest archive from the rclone crypt remote into a throwaway directory and
# checks that it would be usable in a disaster:
#   1. the newest archive is recent (not older than MAX_AGE_DAYS)
#   2. the tarball is intact and extracts
#   3. every file matches checksums.sha256 recorded at backup time
#   4. core services (REQUIRED_SERVICES) each have at least one database
#   5. every SQLite database passes PRAGMA quick_check (if sqlite3 is installed)
# Nothing is written outside the temp directory, which is always removed.
#
# Two modes:
#   (default)   Run the verification now.
#   --install   Self-register this job's cron entry, then exit.
#               Re-running is safe — the entry is replaced, not duplicated.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# --- CONFIGURABLE ---
CRON_SCHEDULE="0 10 * * 0"       # Sundays 10:00 — 2 hours after backup-to-s3
CRON_TIMEZONE="Europe/London"
LOG_FILE="/var/log/homelab/verify-backup.log"
MAX_AGE_DAYS="${MAX_AGE_DAYS:-8}" # weekly backups + a day of slack
REQUIRED_SERVICES="${REQUIRED_SERVICES:-sonarr radarr prowlarr}"
# --------------------

CRON_TAG="# homelab:verify-backup"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# .env is a docker-compose env_file, not shell — read single keys only.
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

RCLONE_REMOTE="${RCLONE_REMOTE:-$(env_get RCLONE_REMOTE)}"; RCLONE_REMOTE="${RCLONE_REMOTE:-s3-dr-crypt}"
S3_BACKUP_PREFIX="${S3_BACKUP_PREFIX:-$(env_get S3_BACKUP_PREFIX)}"
NTFY_URL="${NTFY_URL:-https://ntfy.sh}"
NTFY_TOPIC="${BACKUP_NTFY_TOPIC:-$(env_get BACKUP_NTFY_TOPIC)}"

if [ -n "$S3_BACKUP_PREFIX" ]; then
    REMOTE_SRC="${RCLONE_REMOTE}:${S3_BACKUP_PREFIX}"
else
    REMOTE_SRC="${RCLONE_REMOTE}:"
fi

MODE="run"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --install) MODE="install"; shift ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

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

fail() {
    echo -e "${RED}FAIL: $1${NC}" >&2
    notify "Backup verification FAILED" "5" "x,rotating_light" "$1 ($(hostname))"
    exit 1
}

# "2026-09-20_08-00-00.tar.gz" -> epoch seconds (GNU date, BSD date fallback)
archive_epoch() {
    local stamp="${1%.tar.gz}"
    local when="${stamp%_*} ${stamp#*_}"
    when="${when:0:11}${when:11:2}:${when:14:2}:${when:17:2}"
    date -d "$when" +%s 2>/dev/null || date -j -f "%Y-%m-%d %H:%M:%S" "$when" +%s
}

if [ "$MODE" = "install" ]; then
    CURRENT_CRON=$(crontab -l 2>/dev/null || true)
    FILTERED=$(echo "$CURRENT_CRON" | grep -v "$CRON_TAG" || true)
    NEW_LINE="${CRON_SCHEDULE} cd ${REPO_DIR} && bash scripts/cron-jobs/verify-backup.sh >> ${LOG_FILE} 2>&1 ${CRON_TAG}"
    if echo "$FILTERED" | grep -q '^CRON_TZ='; then
        printf '%s\n%s\n' "$FILTERED" "$NEW_LINE" | crontab -
    else
        printf '%s\n%s\n%s\n' "$FILTERED" "CRON_TZ=${CRON_TIMEZONE}" "$NEW_LINE" | crontab -
    fi
    echo -e "${GREEN}Installed cron entry:${NC}"
    echo "  $NEW_LINE"
    exit 0
fi

echo -e "${GREEN}=== Backup restore verification ===${NC}"
echo "Started: $(date)"
echo "Remote:  ${REMOTE_SRC}"

command -v rclone >/dev/null 2>&1 || fail "rclone not installed"

ARCHIVE_NAME=$(rclone lsf "$REMOTE_SRC" 2>/dev/null | grep '\.tar\.gz$' | sort | tail -1 || true)
[ -n "$ARCHIVE_NAME" ] || fail "no archives found in ${REMOTE_SRC}"
echo "Newest:  ${ARCHIVE_NAME}"

# 1) Freshness
if ! archive_ts=$(archive_epoch "$ARCHIVE_NAME"); then
    fail "cannot parse a date from archive name ${ARCHIVE_NAME}"
fi
age_days=$(( ($(date +%s) - archive_ts) / 86400 ))
if [ "$age_days" -gt "$MAX_AGE_DAYS" ]; then
    fail "newest backup ${ARCHIVE_NAME} is ${age_days} days old (max ${MAX_AGE_DAYS})"
fi

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/verify-backup.XXXXXX")
trap 'rm -rf "$WORK_DIR"' EXIT

rclone copy "${REMOTE_SRC}/${ARCHIVE_NAME}" "$WORK_DIR/" >/dev/null 2>&1 \
    || fail "download of ${ARCHIVE_NAME} failed"

# 2) Archive integrity + extraction
tar -tzf "$WORK_DIR/$ARCHIVE_NAME" >/dev/null 2>&1 || fail "${ARCHIVE_NAME} is not a valid tar.gz"
mkdir -p "$WORK_DIR/x"
tar -xzf "$WORK_DIR/$ARCHIVE_NAME" -C "$WORK_DIR/x" || fail "extracting ${ARCHIVE_NAME} failed"
EXTRACTED=$(find "$WORK_DIR/x" -mindepth 1 -maxdepth 1 -type d | head -1)
[ -n "$EXTRACTED" ] || fail "${ARCHIVE_NAME} contains no backup directory"

# 3) Checksums (paths are absolute from backup time; remap like restore-from-s3.sh)
MANIFEST="$EXTRACTED/checksums.sha256"
[ -f "$MANIFEST" ] || fail "checksums.sha256 missing from ${ARCHIVE_NAME}"
TS_NAME="$(basename "$EXTRACTED")"
sed -E "s#^([0-9a-f]+  ).*/${TS_NAME}/#\1${EXTRACTED}/#" "$MANIFEST" \
    | grep -v "/checksums.sha256\$" > "$WORK_DIR/remapped.sha256"
file_count=$(wc -l < "$WORK_DIR/remapped.sha256" | tr -d ' ')
if ! sha256sum -c "$WORK_DIR/remapped.sha256" >/dev/null 2>&1; then
    bad=$(sha256sum -c "$WORK_DIR/remapped.sha256" 2>/dev/null | grep -c ': FAILED' || true)
    fail "${bad} of ${file_count} files in ${ARCHIVE_NAME} fail checksum verification"
fi

# 4) Core services present
for svc in $REQUIRED_SERVICES; do
    if ! find "$EXTRACTED/$svc" -name '*.db' -type f 2>/dev/null | grep -q .; then
        fail "${ARCHIVE_NAME} has no database for ${svc}"
    fi
done

# 5) SQLite integrity
db_checked=0
if command -v sqlite3 >/dev/null 2>&1; then
    while IFS= read -r -d '' db; do
        # Only real SQLite files; some *.db are other formats (e.g. checkrr's bbolt)
        head -c 15 "$db" | grep -q '^SQLite format 3' || continue
        result=$(sqlite3 "file:${db}?immutable=1" 'PRAGMA quick_check;' 2>&1 || true)
        [ "$result" = "ok" ] || fail "SQLite check failed for ${db#"$EXTRACTED"/}: ${result}"
        db_checked=$((db_checked + 1))
    done < <(find "$EXTRACTED" -name '*.db' -type f -print0)
else
    echo -e "${YELLOW}sqlite3 not installed — skipping database integrity checks${NC}"
fi

echo -e "${GREEN}OK: ${ARCHIVE_NAME} (${age_days}d old, ${file_count} files, ${db_checked} SQLite DBs checked)${NC}"
notify "Backup verification OK" "2" "white_check_mark" \
    "${ARCHIVE_NAME}: ${file_count} files verified, ${db_checked} DBs checked ($(hostname))"
