#!/bin/bash
set -e

# --- Homelab Media Stack Bootstrap Script ---
# This script will:
# - Set up config directories
# - Pull latest images for all modular stacks (skippable with --skip-pull)
# - Bring up all containers (services, torrent, plex, music, books)
# - Wait for each stack to be healthy before starting the next
# - Display access URLs
#
# Usage: ./homelab-media-bootstrap.sh [--skip-pull]
#   --skip-pull: Skip image pulls (useful when images are already up to date)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_BASE="/var/lib/homelab-media-configs"
DATA_BASE="/mnt/media"
SKIP_PULL=false

for arg in "$@"; do
    case $arg in
        --skip-pull) SKIP_PULL=true ;;
        *) echo "Unknown argument: $arg"; echo "Usage: $0 [--skip-pull]"; exit 1 ;;
    esac
done

# Wait until all containers in a compose project are running (not restarting/exited).
# Returns 0 when healthy, 1 on timeout.
wait_for_stack() {
    local stack=$1
    local project_name="homelab-${stack}"
    local compose_file="${SCRIPT_DIR}/docker-compose-${stack}.yml"
    local timeout=${2:-120}
    local elapsed=0

    echo "  Waiting for $project_name to be ready (timeout: ${timeout}s)..."
    while [ $elapsed -lt $timeout ]; do
        local not_running
        not_running=$(docker compose -p "$project_name" -f "$compose_file" ps --format json 2>/dev/null \
            | grep -c '"State":"restarting"\|"State":"exited"\|"State":"created"' || true)
        local total
        total=$(docker compose -p "$project_name" -f "$compose_file" ps --format json 2>/dev/null \
            | grep -c '"State":' || true)

        if [ "$total" -gt 0 ] && [ "$not_running" -eq 0 ]; then
            echo "  $project_name is ready."
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done

    echo "  Warning: $project_name did not fully start within ${timeout}s — continuing anyway"
    return 0
}

# Create necessary config directories
mkdir -p \
    "$CONFIG_BASE/gluetun" \
    "$CONFIG_BASE/qbittorrent" \
    "$CONFIG_BASE/sonarr" \
    "$CONFIG_BASE/radarr" \
    "$CONFIG_BASE/lidarr" \
    "$CONFIG_BASE/readarr" \
    "$CONFIG_BASE/bazarr" \
    "$CONFIG_BASE/prowlarr" \
    "$CONFIG_BASE/recyclarr" \
    "$CONFIG_BASE/seerr" \
    "$CONFIG_BASE/maintainerr" \
    "$CONFIG_BASE/plex" \
    "$CONFIG_BASE/tautulli" \
    "$CONFIG_BASE/filebrowser" \
    "$CONFIG_BASE/picard" \
    "$CONFIG_BASE/beszel" \
    "$CONFIG_BASE/gluetun-monitor" \
    "$CONFIG_BASE/wud-updates" \
    "$CONFIG_BASE/navidrome" \
    "$CONFIG_BASE/audiomuse-postgres" \
    "$CONFIG_BASE/audiomuse-redis" \
    "$CONFIG_BASE/kavita" \
    "$CONFIG_BASE/suwayomi" \
    "$CONFIG_BASE/rreading-glasses-postgres"

mkdir -p \
    "$DATA_BASE/downloads" \
    "$DATA_BASE/tv" \
    "$DATA_BASE/movies" \
    "$DATA_BASE/music" \
    "$DATA_BASE/books" \
    "$DATA_BASE/transcode" \
    "$DATA_BASE/anime/tv" \
    "$DATA_BASE/anime/movies"

# Pull docker images for all stacks
if [ "$SKIP_PULL" = true ]; then
    echo "Skipping image pulls (--skip-pull passed)."
else
    echo "Pulling images for services stack..."
    "$SCRIPT_DIR/stack-manage.sh" services pull

    echo "Pulling images for torrent stack..."
    "$SCRIPT_DIR/stack-manage.sh" torrent pull

    echo "Pulling images for plex stack..."
    "$SCRIPT_DIR/stack-manage.sh" plex pull

    echo "Pulling images for music stack..."
    "$SCRIPT_DIR/stack-manage.sh" music pull

    echo "Pulling images for books stack..."
    "$SCRIPT_DIR/stack-manage.sh" books pull
fi

# Start all containers in order (services first to create media_network)
echo "Starting services stack (Seerr, Maintainerr, WUD, Beszel, Portainer)..."
"$SCRIPT_DIR/stack-manage.sh" services start
wait_for_stack services 120

echo "Starting torrent stack (VPN + downloaders)..."
"$SCRIPT_DIR/stack-manage.sh" torrent start
wait_for_stack torrent 180

echo "Starting plex stack..."
"$SCRIPT_DIR/stack-manage.sh" plex start
wait_for_stack plex 120

echo "Starting music stack..."
"$SCRIPT_DIR/stack-manage.sh" music start
wait_for_stack music 90

echo "Starting books stack..."
"$SCRIPT_DIR/stack-manage.sh" books start
wait_for_stack books 90

echo ""
echo "--- Homelab Media Stack is launching! ---"
echo "User-Facing Services:"
echo "  Seerr:        http://<your-ip>:5055"
echo "  Plex:         http://<your-ip>:32400/web"
echo "  Maintainerr:  http://<your-ip>:6246"
echo "  Beszel:       http://<your-ip>:8090"
echo "  Portainer:    https://<your-ip>:9443"
echo ""
echo "Automation Services (via VPN):"
echo "  Sonarr:       http://<your-ip>:8989"
echo "  Radarr:       http://<your-ip>:7878"
echo "  Lidarr:       http://<your-ip>:8686"
echo "  Readarr:      http://<your-ip>:8282"
echo "  Bazarr:       http://<your-ip>:6767"
echo "  Prowlarr:     http://<your-ip>:9696"
echo "  qBittorrent:  http://<your-ip>:8080"
echo "  FlareSolverr: http://<your-ip>:8191"
echo ""
echo "Music:"
echo "  Navidrome:    http://<your-ip>:4533"
echo "  AudioMuse:    http://<your-ip>:8000"
echo ""
echo "Books:"
echo "  Kavita:       http://<your-ip>:5001"
echo "  Suwayomi:     http://<your-ip>:4567"
echo ""
echo "Check container logs for VPN/proxy errors. Ensure your VPN credentials and API keys are correctly set in .env file. Ready to roll!"
