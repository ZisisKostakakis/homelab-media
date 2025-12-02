#!/bin/bash
set -e

# --- Homelab Media Stack Bootstrap Script ---
# This script will:
# - Set up config directories
# - Pull latest images
# - Bring up containers
# - Display access URLs

CONFIG_BASE="/mnt/media/config"
DATA_BASE="/mnt/media"

# Create necessary config directories
mkdir -p "$CONFIG_BASE/gluetun" \
         "$CONFIG_BASE/qbittorrent" \
         "$CONFIG_BASE/sonarr" \
         "$CONFIG_BASE/radarr" \
         "$CONFIG_BASE/bazarr" \
         "$CONFIG_BASE/prowlarr" \
         "$CONFIG_BASE/recyclarr" \
         "$CONFIG_BASE/overseerr" \
         "$CONFIG_BASE/plex"
mkdir -p "$DATA_BASE/downloads" "$DATA_BASE/tv" "$DATA_BASE/movies"

# Pull docker images for all services
docker compose pull

# Start all containers
docker compose up -d

echo "\n--- Homelab Media Stack is launching! ---"
echo "Plex:         http://<your-ip>:32400/web"
echo "Overseerr:    http://<your-ip>:5055"
echo "Sonarr:       http://<your-ip>:8989"
echo "Radarr:       http://<your-ip>:7878"
echo "Bazarr:       http://<your-ip>:6767"
echo "Prowlarr:     http://<your-ip>:9696"
echo "qBittorrent:  http://<your-ip>:8080"
echo "FlareSolverr: http://<your-ip>:8191"
echo "\nCheck container logs for VPN/proxy errors. Ensure your VPN credentials and API keys are correctly set in docker-compose.yml. Ready to roll!"
