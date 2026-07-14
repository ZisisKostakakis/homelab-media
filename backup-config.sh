#!/bin/bash

# Homelab Media Configuration Backup Script
# Backs up configuration files (API keys, indexers, connections) without media data
# Usage: ./backup-config.sh [--dry-run]
#   --dry-run: List what would be backed up without writing any files

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_BASE_DIR="${BACKUP_BASE_DIR:-$SCRIPT_DIR/config-backups}"
BACKUP_DATE=$(date +"%Y-%m-%d_%H-%M-%S")
BACKUP_DIR="$BACKUP_BASE_DIR/$BACKUP_DATE"
CONFIG_SOURCE="${CONFIG_SOURCE:-/var/lib/homelab-media-configs}"
# Number of recent backups to keep (override with BACKUP_RETAIN env var)
BACKUP_RETAIN="${BACKUP_RETAIN:-5}"
# Maximum total size of all backups before oldest are pruned (0 = no limit)
BACKUP_MAX_SIZE_MB="${BACKUP_MAX_SIZE_MB:-0}"
DRY_RUN=false
LIST_ONLY=false

usage() {
    cat <<EOF
Usage: $0 [--dry-run] [--keep N] [--list]
  --dry-run   Show what would happen without writing or deleting anything
  --keep N    Keep only the last N backup archives (overrides BACKUP_RETAIN env)
  --list      List existing backups and exit
EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run) DRY_RUN=true; shift ;;
        --keep)
            if ! [[ "${2:-}" =~ ^[0-9]+$ ]] || [ "${2}" -lt 1 ]; then
                echo "Error: --keep expects a positive integer" >&2
                exit 1
            fi
            BACKUP_RETAIN="$2"
            shift 2
            ;;
        --list) LIST_ONLY=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1"; usage; exit 1 ;;
    esac
done

if [ "$LIST_ONLY" = true ]; then
    if [ ! -d "$BACKUP_BASE_DIR" ]; then
        echo "No backups found (directory $BACKUP_BASE_DIR does not exist)"
        exit 0
    fi
    echo "Existing backups in $BACKUP_BASE_DIR:"
    ls -lh "$BACKUP_BASE_DIR"/*.tar.gz 2>/dev/null || echo "  (none)"
    exit 0
fi

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Homelab Media Configuration Backup ===${NC}"
[ "$DRY_RUN" = true ] && echo -e "${YELLOW}DRY RUN — no files will be written${NC}"
echo "Backup destination: $BACKUP_DIR"
echo ""

# Create backup directory (skipped in dry-run)
[ "$DRY_RUN" = false ] && mkdir -p "$BACKUP_DIR"

# Function to backup service configs (excluding logs and large databases)
backup_service() {
    local service=$1
    local source="$CONFIG_SOURCE/$service"
    local dest="$BACKUP_DIR/$service"

    if [ ! -d "$source" ]; then
        echo -e "${YELLOW}Skipping $service (directory not found)${NC}"
        return
    fi

    echo -e "${GREEN}Backing up $service...${NC}"

    if [ "$DRY_RUN" = true ]; then
        local file_count
        file_count=$(find "$source" -type f \( -name '*.xml' -o -name '*.db' -o -name '*.json' -o -name '*.yml' -o -name '*.yaml' -o -name '*.conf' -o -name '*.ini' \) \
            ! -name 'logs.db' ! -path '*/logs/*' ! -path '*/Logs/*' ! -path '*/cache/*' ! -path '*/Cache/*' ! -path '*/MediaCover/*' ! -path '*/Backups/*' \
            ! -name '*.log' ! -name '*-shm' ! -name '*-wal' 2>/dev/null | wc -l)
        echo -e "  [dry-run] Would back up $file_count file(s) from $source"
        return
    fi

    mkdir -p "$dest"

    # Copy configuration files
    # Include: .xml, .db, .json, .yml, .yaml, .conf, .ini
    # Exclude: logs.db, logs directory, cache, MediaCover (poster images), Plex Library
    #
    # Directory excludes MUST precede --include='*/' — rsync evaluates filter
    # rules in order, so a directory exclude listed after the recurse-into-all
    # include never gets a chance to fire (rsync already descended via the
    # earlier rule). A trailing --exclude='*' closes the list so only the
    # extensions above are ever copied, instead of "anything not excluded".
    rsync -av \
        --exclude='logs/' \
        --exclude='Logs/' \
        --exclude='cache/' \
        --exclude='Cache/' \
        --exclude='MediaCover/' \
        --exclude='Backups/' \
        --exclude='Library/' \
        --include='*/' \
        --include='*.xml' \
        --include='*.db' \
        --include='*.json' \
        --include='*.yml' \
        --include='*.yaml' \
        --include='*.conf' \
        --include='*.ini' \
        --exclude='logs.db' \
        --exclude='*.log' \
        --exclude='*-shm' \
        --exclude='*-wal' \
        --exclude='*' \
        "$source/" "$dest/" > /dev/null 2>&1

    echo -e "  → Backed up to $dest"
}

# Backup each service
echo -e "${GREEN}Backing up service configurations...${NC}"
echo ""

backup_service "prowlarr"          # Indexers, connections
backup_service "sonarr"            # TV show automation, download client config
backup_service "radarr"            # Movie automation, download client config
backup_service "lidarr"            # Music automation, download client config
backup_service "bazarr"            # Subtitle downloader config
backup_service "seerr"             # Request system config
backup_service "maintainerr"       # Media cleanup rules
backup_service "qbittorrent"       # Torrent client settings (excluding torrents)
backup_service "recyclarr"         # Quality profile configs
backup_service "plex"              # Plex server preferences
backup_service "tautulli"          # Play history database
backup_service "gluetun"           # VPN configuration
backup_service "navidrome"         # Music server config and database

# Backup docker-compose and environment files
echo ""
echo -e "${GREEN}Backing up Docker configuration...${NC}"

if [ "$DRY_RUN" = true ]; then
    compose_count=$(ls "$SCRIPT_DIR"/docker-compose-*.yml 2>/dev/null | wc -l)
    echo -e "  [dry-run] Would back up $compose_count compose file(s)"
    [ -f "$SCRIPT_DIR/.env" ] && echo -e "  [dry-run] Would back up .env"
    echo ""
    echo -e "${YELLOW}Dry run complete — no files were written.${NC}"
    exit 0
fi

mkdir -p "$BACKUP_DIR/docker"

for compose_file in "$SCRIPT_DIR"/docker-compose-*.yml; do
    fname="$(basename "$compose_file")"
    cp "$compose_file" "$BACKUP_DIR/docker/"
    echo -e "  → $fname"
done

if [ -f "$SCRIPT_DIR/.env" ]; then
    cp "$SCRIPT_DIR/.env" "$BACKUP_DIR/docker/"
    echo -e "  → .env"
fi

# Create a backup summary
cat > "$BACKUP_DIR/README.txt" << EOF
Homelab Media Configuration Backup
===================================
Created: $(date)
Hostname: $(hostname)

This backup contains:
- Prowlarr: Indexer configurations and API keys
- Sonarr: Series settings, download clients, quality profiles
- Radarr: Movie settings, download clients, quality profiles
- Lidarr: Music automation settings
- Readarr: Book automation settings
- Bazarr: Subtitle provider settings
- Seerr: Request system configuration
- Maintainerr: Media cleanup rules
- qBittorrent: Download client settings (no actual torrents)
- Recyclarr: Quality profile automation
- Plex: Server preferences and settings
- Tautulli: Play history database
- Gluetun: VPN configuration
- Navidrome: Music server config and database
- Kavita: Ebook/comics reader config
- Docker: docker-compose files and environment file

What is NOT included:
- Media files (movies, TV shows, music)
- Active torrents and their data
- Log files
- Database logs and temporary files
- Media artwork and posters

Restore instructions:
1. Stop all containers: ./stack-manage.sh all down
2. Copy backed up configs to /var/lib/homelab-media-configs/
3. Restore docker-compose files and .env if needed
4. Start containers: ./stack-manage.sh all start
EOF

verify_backup() {
    if [ ! -d "$BACKUP_DIR" ]; then
        echo -e "${RED}Verification FAILED: backup directory not found.${NC}"
        return 1
    fi
    local subdir_count
    subdir_count=$(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l)
    if [ "$subdir_count" -lt 1 ]; then
        echo -e "${RED}Verification FAILED: backup directory contains no subdirectories.${NC}"
        return 1
    fi
    echo -e "${GREEN}Verification PASSED: backup contains $subdir_count service director$([ "$subdir_count" -eq 1 ] && echo 'y' || echo 'ies').${NC}"
}

verify_backup

# Generate SHA256 checksums for all backed-up files
echo ""
echo -e "${GREEN}Generating checksums...${NC}"
find "$BACKUP_DIR" -type f | sort | xargs sha256sum > "$BACKUP_DIR/checksums.sha256"
echo -e "  → checksums.sha256 ($(wc -l < "$BACKUP_DIR/checksums.sha256") files)"

# Compress the backup directory into a tar.gz archive
echo ""
echo -e "${GREEN}Compressing backup...${NC}"
ARCHIVE_PATH="${BACKUP_BASE_DIR}/${BACKUP_DATE}.tar.gz"
tar -czf "$ARCHIVE_PATH" -C "$BACKUP_BASE_DIR" "$BACKUP_DATE"
ARCHIVE_SIZE=$(du -sh "$ARCHIVE_PATH" | cut -f1)
echo -e "  → $(basename "$ARCHIVE_PATH") ($ARCHIVE_SIZE)"

# Remove the uncompressed directory now that we have the archive
rm -rf "$BACKUP_DIR"

# Verify archive integrity
if ! tar -tzf "$ARCHIVE_PATH" > /dev/null 2>&1; then
    echo -e "${RED}Archive integrity check FAILED: $ARCHIVE_PATH may be corrupt.${NC}"
    exit 1
fi
echo -e "${GREEN}Archive integrity check PASSED.${NC}"

# Calculate backup size
BACKUP_SIZE="$ARCHIVE_SIZE"

echo ""
echo -e "${GREEN}=== Backup Complete ===${NC}"
echo -e "Location: $ARCHIVE_PATH"
echo -e "Size: $BACKUP_SIZE"
echo ""
echo -e "${YELLOW}Backup archives:${NC}"
ls -lh "$BACKUP_BASE_DIR"/*.tar.gz 2>/dev/null || echo "  (none)"
echo ""

# Keep only the last N backups (controlled by BACKUP_RETAIN)
echo -e "${YELLOW}Cleaning old backups (keeping last $BACKUP_RETAIN)...${NC}"
ls -t "$BACKUP_BASE_DIR"/*.tar.gz 2>/dev/null | tail -n +$((BACKUP_RETAIN + 1)) | xargs -r rm -f
echo -e "${GREEN}Old backups cleaned.${NC}"

# Enforce total size cap if configured
if [ "$BACKUP_MAX_SIZE_MB" -gt 0 ]; then
    while true; do
        local total_mb
        total_mb=$(du -sm "$BACKUP_BASE_DIR" 2>/dev/null | cut -f1)
        if [ "$total_mb" -le "$BACKUP_MAX_SIZE_MB" ]; then
            break
        fi
        oldest=$(ls -t "$BACKUP_BASE_DIR"/*.tar.gz 2>/dev/null | tail -1)
        if [ -z "$oldest" ]; then
            break
        fi
        echo -e "${YELLOW}  Size cap exceeded (${total_mb}MB > ${BACKUP_MAX_SIZE_MB}MB), removing: $(basename "$oldest")${NC}"
        rm -f "$oldest"
    done
fi

echo ""
echo -e "${GREEN}Backup successful!${NC}"
echo "To restore from this backup:"
echo "  tar -xzf $ARCHIVE_PATH -C $BACKUP_BASE_DIR"
echo "  cp -r ${BACKUP_BASE_DIR}/${BACKUP_DATE}/. /var/lib/homelab-media-configs/"
