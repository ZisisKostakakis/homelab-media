#!/bin/bash

# Homelab Media Configuration Backup Script
# Backs up configuration files (API keys, indexers, connections) without media data

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_BASE_DIR="${BACKUP_BASE_DIR:-$SCRIPT_DIR/config-backups}"
BACKUP_DATE=$(date +"%Y-%m-%d_%H-%M-%S")
BACKUP_DIR="$BACKUP_BASE_DIR/$BACKUP_DATE"
CONFIG_SOURCE="${CONFIG_SOURCE:-/var/lib/homelab-media-configs}"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Homelab Media Configuration Backup ===${NC}"
echo "Backup destination: $BACKUP_DIR"
echo ""

# Create backup directory
mkdir -p "$BACKUP_DIR"

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
    mkdir -p "$dest"

    # Copy configuration files
    # Include: .xml, .db, .json, .yml, .yaml, .conf, .ini
    # Exclude: logs.db, logs directory, cache, MediaCover (poster images)
    rsync -av \
        --include='*/' \
        --include='*.xml' \
        --include='*.db' \
        --include='*.json' \
        --include='*.yml' \
        --include='*.yaml' \
        --include='*.conf' \
        --include='*.ini' \
        --exclude='logs.db' \
        --exclude='logs/' \
        --exclude='Logs/' \
        --exclude='logs/*' \
        --exclude='cache/' \
        --exclude='Cache/' \
        --exclude='MediaCover/' \
        --exclude='Backups/' \
        --exclude='*.log' \
        --exclude='*-shm' \
        --exclude='*-wal' \
        --exclude='**/logs/' \
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
backup_service "readarr"           # Book automation, download client config
backup_service "bazarr"            # Subtitle downloader config
backup_service "seerr"             # Request system config
backup_service "maintainerr"       # Media cleanup rules
backup_service "qbittorrent"       # Torrent client settings (excluding torrents)
backup_service "recyclarr"         # Quality profile configs
backup_service "plex"              # Plex server preferences
backup_service "tautulli"          # Play history database
backup_service "gluetun"           # VPN configuration
backup_service "navidrome"         # Music server config and database
backup_service "kavita"            # Ebook/comics reader config
backup_service "suwayomi"          # Manga reader config

# Backup docker-compose and environment files
echo ""
echo -e "${GREEN}Backing up Docker configuration...${NC}"
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
- Suwayomi: Manga reader config
- Docker: docker-compose files and environment file

What is NOT included:
- Media files (movies, TV shows, music, books)
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

# Calculate backup size
BACKUP_SIZE=$(du -sh "$BACKUP_DIR" | cut -f1)

echo ""
echo -e "${GREEN}=== Backup Complete ===${NC}"
echo -e "Location: $BACKUP_DIR"
echo -e "Size: $BACKUP_SIZE"
echo ""
echo -e "${YELLOW}Backup contents:${NC}"
ls -lh "$BACKUP_DIR"
echo ""

# Keep only the last 5 backups
echo -e "${YELLOW}Cleaning old backups (keeping last 5)...${NC}"
cd "$BACKUP_BASE_DIR"
ls -t | tail -n +6 | xargs -r rm -rf
echo -e "${GREEN}Old backups cleaned.${NC}"
echo ""

echo -e "${GREEN}Backup successful!${NC}"
echo "To restore from this backup, copy contents from:"
echo "  $BACKUP_DIR"
echo "to:"
echo "  /mnt/media/config/"
