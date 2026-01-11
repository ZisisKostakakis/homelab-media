#!/bin/bash
set -e

# --- Homelab Media Stack Bootstrap Script ---
# This script will:
# - Set up config directories
# - Pull latest images for modular stacks
# - Bring up containers (torrent, plex, services)
# - Display access URLs

CONFIG_BASE="/var/lib/homelab-media-configs"
DATA_BASE="/mnt/media"

# Create necessary config directories
mkdir -p "$CONFIG_BASE/gluetun" \
         "$CONFIG_BASE/qbittorrent" \
         "$CONFIG_BASE/cross-seed" \
         "$CONFIG_BASE/sonarr" \
         "$CONFIG_BASE/radarr" \
         "$CONFIG_BASE/bazarr" \
         "$CONFIG_BASE/prowlarr" \
         "$CONFIG_BASE/recyclarr" \
         "$CONFIG_BASE/overseerr" \
         "$CONFIG_BASE/maintainerr" \
         "$CONFIG_BASE/plex"
mkdir -p "$DATA_BASE/downloads" "$DATA_BASE/tv" "$DATA_BASE/movies" "$DATA_BASE/transcode" "$DATA_BASE/anime/tv" "$DATA_BASE/anime/movies"

# Pull docker images for all modular stacks
echo "Pulling images for services stack..."
docker compose -p homelab-services -f docker-compose-services.yml pull

echo "Pulling images for torrent stack..."
docker compose -p homelab-torrent -f docker-compose-torrent.yml pull

echo "Pulling images for plex stack..."
docker compose -p homelab-plex -f docker-compose-plex.yml pull

# Start all containers in order (services first to create media_network)
echo "Starting services stack (Overseerr, Maintainerr, Pulse)..."
docker compose -p homelab-services -f docker-compose-services.yml up -d

echo "Starting torrent stack (VPN + downloaders)..."
docker compose -p homelab-torrent -f docker-compose-torrent.yml up -d

echo "Starting plex stack..."
docker compose -p homelab-plex -f docker-compose-plex.yml up -d

echo ""
echo "--- Homelab Media Stack is launching! ---"
echo "User-Facing Services:"
echo "  Overseerr:    http://<your-ip>:5055"
echo "  Plex:         http://<your-ip>:32400/web"
echo "  Maintainerr:  http://<your-ip>:6246"
echo "  Pulse:        http://<your-ip>:7655"
echo ""
echo "Automation Services (via VPN):"
echo "  Sonarr:       http://<your-ip>:8989"
echo "  Radarr:       http://<your-ip>:7878"
echo "  Bazarr:       http://<your-ip>:6767"
echo "  Prowlarr:     http://<your-ip>:9696"
echo "  qBittorrent:  http://<your-ip>:8080"
echo "  Cross-Seed:   http://<your-ip>:2468"
echo "  FlareSolverr: http://<your-ip>:8191"
echo ""
echo "Check container logs for VPN/proxy errors. Ensure your VPN credentials and API keys are correctly set in .env file. Ready to roll!"
