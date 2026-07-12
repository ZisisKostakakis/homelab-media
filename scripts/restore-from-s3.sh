#!/bin/bash
# Disaster Recovery: restore a config backup from S3
#
# Downloads an encrypted config archive from the S3 crypt remote, decrypts it
# (transparently, via rclone crypt), verifies its integrity, and extracts it —
# ready to copy into /var/lib/homelab-media-configs/ when rebuilding the VM.
#
# Usage:
#   ./restore-from-s3.sh --list                 List available remote archives
#   ./restore-from-s3.sh                         Restore the newest archive
#   ./restore-from-s3.sh --archive NAME.tar.gz   Restore a specific archive
#   ./restore-from-s3.sh --dry-run               Show what would happen, download nothing
#
# This script does NOT overwrite live config on its own — it stops at the
# extracted directory and prints the manual copy/restart steps, so you stay in
# control of the final rehydration.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# --- Read specific settings from .env (non-fatal if absent) ---
# .env is a docker-compose env_file (literal KEY=VALUE, values may contain
# unquoted spaces), NOT valid shell — never `source` it. Pull only what we need.
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
CONFIG_SOURCE="${CONFIG_SOURCE:-/var/lib/homelab-media-configs}"
RESTORE_DIR="${RESTORE_DIR:-${REPO_DIR}/config-restore}"

if [ -n "$S3_BACKUP_PREFIX" ]; then
    REMOTE_SRC="${RCLONE_REMOTE}:${S3_BACKUP_PREFIX}"
else
    REMOTE_SRC="${RCLONE_REMOTE}:"
fi

# --- Parse arguments ---
LIST_ONLY=false
DRY_RUN=false
ARCHIVE_NAME=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --list) LIST_ONLY=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --archive)
            ARCHIVE_NAME="${2:-}"
            [ -z "$ARCHIVE_NAME" ] && { echo "Error: --archive needs a filename" >&2; exit 1; }
            shift 2
            ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

# --- Preflight ---
if ! command -v rclone >/dev/null 2>&1; then
    echo -e "${RED}Error: rclone not installed. Run scripts/install-rclone.sh first.${NC}" >&2
    exit 1
fi
if ! rclone listremotes 2>/dev/null | grep -qx "${RCLONE_REMOTE}:"; then
    echo -e "${RED}Error: rclone remote '${RCLONE_REMOTE}:' not configured.${NC}" >&2
    echo -e "${RED}Configure it with 'rclone config' (see README Disaster Recovery section).${NC}" >&2
    exit 1
fi

# --- List mode ---
echo -e "${GREEN}=== S3 Disaster-Recovery Restore ===${NC}"
echo "Remote: ${REMOTE_SRC}"
echo ""
echo -e "${GREEN}Available archives (newest last):${NC}"
REMOTE_LIST=$(rclone lsl "$REMOTE_SRC" 2>/dev/null | grep '\.tar\.gz$' | sort -k2 || true)
if [ -z "$REMOTE_LIST" ]; then
    echo -e "${YELLOW}  (none found)${NC}"
    [ "$LIST_ONLY" = true ] && exit 0
    echo -e "${RED}Nothing to restore.${NC}" >&2
    exit 1
fi
echo "$REMOTE_LIST"
echo ""
[ "$LIST_ONLY" = true ] && exit 0

# --- Choose archive ---
if [ -z "$ARCHIVE_NAME" ]; then
    # Newest by filename (timestamps sort lexicographically: YYYY-MM-DD_HH-MM-SS)
    ARCHIVE_NAME=$(rclone lsf "$REMOTE_SRC" 2>/dev/null | grep '\.tar\.gz$' | sort | tail -1)
    echo -e "${YELLOW}No --archive given; selecting newest: ${ARCHIVE_NAME}${NC}"
fi
echo -e "${GREEN}Target archive:${NC} ${ARCHIVE_NAME}"
echo ""

if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}[dry-run] Would download ${REMOTE_SRC}/${ARCHIVE_NAME} → ${RESTORE_DIR}/${NC}"
    echo -e "${YELLOW}[dry-run] Would verify tar integrity + checksums.sha256, then extract.${NC}"
    echo -e "${YELLOW}Dry run complete — nothing downloaded.${NC}"
    exit 0
fi

# --- Download (decrypts transparently through the crypt remote) ---
mkdir -p "$RESTORE_DIR"
echo -e "${GREEN}Downloading + decrypting...${NC}"
rclone copy --progress "${REMOTE_SRC}/${ARCHIVE_NAME}" "$RESTORE_DIR/"
LOCAL_ARCHIVE="${RESTORE_DIR}/${ARCHIVE_NAME}"
if [ ! -f "$LOCAL_ARCHIVE" ]; then
    echo -e "${RED}Error: download did not produce ${LOCAL_ARCHIVE}.${NC}" >&2
    exit 1
fi

# --- Verify archive integrity ---
echo ""
echo -e "${GREEN}Verifying archive integrity...${NC}"
if ! tar -tzf "$LOCAL_ARCHIVE" >/dev/null 2>&1; then
    echo -e "${RED}Integrity check FAILED: ${ARCHIVE_NAME} may be corrupt.${NC}" >&2
    exit 1
fi
echo -e "${GREEN}  tar archive OK.${NC}"

# --- Extract ---
echo ""
echo -e "${GREEN}Extracting...${NC}"
EXTRACT_ROOT="${RESTORE_DIR}/extracted"
mkdir -p "$EXTRACT_ROOT"
tar -xzf "$LOCAL_ARCHIVE" -C "$EXTRACT_ROOT"
EXTRACTED_DIR=$(find "$EXTRACT_ROOT" -mindepth 1 -maxdepth 1 -type d | head -1)
echo -e "${GREEN}  → ${EXTRACTED_DIR}${NC}"

# --- Verify checksums if present ---
if [ -f "${EXTRACTED_DIR}/checksums.sha256" ]; then
    echo ""
    echo -e "${GREEN}Verifying SHA256 checksums...${NC}"
    # checksums.sha256 records backup-time absolute paths ending in
    # .../<TIMESTAMP>/<relpath>. Rewrite that leading prefix to the extracted
    # dir so the paths resolve here, then verify actual file contents.
    TS_NAME="$(basename "$EXTRACTED_DIR")"
    REMAPPED="${RESTORE_DIR}/checksums.remapped.sha256"
    # Replace everything up to and including "/<TS_NAME>/" with the extracted dir.
    sed -E "s#^([0-9a-f]+  ).*/${TS_NAME}/#\1${EXTRACTED_DIR}/#" \
        "${EXTRACTED_DIR}/checksums.sha256" > "$REMAPPED"
    # The checksum manifest lists itself (recorded as 0 bytes at manifest time) —
    # drop that self-reference so it doesn't cause a spurious mismatch.
    grep -v "/checksums.sha256\$" "$REMAPPED" > "${REMAPPED}.tmp" && mv "${REMAPPED}.tmp" "$REMAPPED"
    if sha256sum -c "$REMAPPED" >/dev/null 2>&1; then
        echo -e "${GREEN}  Checksums OK ($(wc -l < "$REMAPPED") files verified).${NC}"
    else
        FAILED=$(sha256sum -c "$REMAPPED" 2>/dev/null | grep -c ': FAILED' || true)
        echo -e "${RED}  WARNING: ${FAILED} file(s) failed checksum verification.${NC}"
        echo -e "${YELLOW}  The tar integrity check passed, so this is unexpected — inspect before restoring.${NC}"
    fi
    rm -f "$REMAPPED"
fi

# --- Print manual restore runbook ---
echo ""
echo -e "${GREEN}=== Download + decrypt complete ===${NC}"
cat <<EOF
Extracted config is at:
  ${EXTRACTED_DIR}

To rehydrate the VM (manual, so you stay in control):

  1. Stop all containers:
       cd ${REPO_DIR} && ./stack-manage.sh all down

  2. Restore service configs into ${CONFIG_SOURCE}:
       sudo cp -a ${EXTRACTED_DIR}/. ${CONFIG_SOURCE}/
     (Review ownership/UIDs afterwards — see homelab-media-bootstrap.sh.)

  3. Restore docker-compose files and .env if rebuilding from scratch:
       cp ${EXTRACTED_DIR}/docker/docker-compose-*.yml ${REPO_DIR}/
       cp ${EXTRACTED_DIR}/docker/.env ${REPO_DIR}/.env

  4. Start containers:
       ./stack-manage.sh all start

EOF
