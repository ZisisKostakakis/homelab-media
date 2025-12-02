#!/bin/bash

# Homelab Media Configuration Backup Script
# Backs up configuration files (API keys, indexers, connections) without media data

# Configuration
BACKUP_BASE_DIR="/home/blaze/Github/homelab-media/config-backups"
BACKUP_DATE=$(date +"%Y-%m-%d_%H-%M-%S")
BACKUP_DIR="$BACKUP_BASE_DIR/$BACKUP_DATE"
CONFIG_SOURCE="/mnt/media/config"

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

backup_service "prowlarr"      # Indexers, connections
backup_service "sonarr"        # TV show automation, download client config
backup_service "radarr"        # Movie automation, download client config
backup_service "bazarr"        # Subtitle downloader config
backup_service "overseerr"     # Request system config
backup_service "qbittorrent"   # Torrent client settings (excluding torrents)
backup_service "recyclarr"     # Quality profile configs
backup_service "plex"          # Plex server preferences
backup_service "gluetun"       # VPN configuration

# Backup docker-compose and environment files
echo ""
echo -e "${GREEN}Backing up Docker configuration...${NC}"
mkdir -p "$BACKUP_DIR/docker"

if [ -f "/home/blaze/Github/homelab-media/docker-compose.yml" ]; then
    cp "/home/blaze/Github/homelab-media/docker-compose.yml" "$BACKUP_DIR/docker/"
    echo -e "  → docker-compose.yml"
fi

if [ -f "/home/blaze/Github/homelab-media/.env" ]; then
    cp "/home/blaze/Github/homelab-media/.env" "$BACKUP_DIR/docker/"
    echo -e "  → .env"
fi

if [ -d "/home/blaze/Github/homelab-media/maintainerr" ]; then
    cp -r "/home/blaze/Github/homelab-media/maintainerr" "$BACKUP_DIR/docker/"
    echo -e "  → maintainerr config"
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
- Bazarr: Subtitle provider settings
- Overseerr: Request system configuration
- qBittorrent: Download client settings (no actual torrents)
- Recyclarr: Quality profile automation
- Plex: Server preferences and settings
- Gluetun: VPN configuration
- Docker: docker-compose.yml and environment files

What is NOT included:
- Media files (movies, TV shows)
- Active torrents and their data
- Log files
- Database logs and temporary files
- Media artwork and posters

Restore instructions:
1. Stop all containers: docker compose down
2. Copy backed up configs to /mnt/media/config/
3. Restore docker-compose.yml if needed
4. Start containers: docker compose up -d
EOF

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
