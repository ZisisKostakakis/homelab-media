#!/bin/sh
# WUD Update Handler - Receives webhook from WUD and triggers stack-manage.sh
# This script processes container update notifications from What's Up Docker
# and automatically updates the affected service using stack-manage.sh

set -e

LOG_DIR="/var/lib/homelab-media-configs/wud-updates"
LOG_FILE="$LOG_DIR/update-handler.log"

# Create log directory if it doesn't exist
mkdir -p "$LOG_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Map container names to stack and service names
get_stack_and_service() {
    local container_name=$1

    case $container_name in
        # Services stack
        overseerr)
            echo "services overseerr"
            ;;
        maintainerr)
            echo "services maintainerr"
            ;;
        filebrowser)
            echo "services filebrowser"
            ;;
        autoheal)
            echo "services autoheal"
            ;;
        gluetun-monitor)
            echo "services gluetun-monitor"
            ;;
        wud|whatsupdocker)
            echo "services whatsupdocker"
            ;;
        portainer)
            echo "services portainer"
            ;;

        # Torrent stack
        gluetun)
            echo "torrent gluetun"
            ;;
        qbittorrent)
            echo "torrent qbittorrent"
            ;;
        sonarr)
            echo "torrent sonarr"
            ;;
        radarr)
            echo "torrent radarr"
            ;;
        bazarr)
            echo "torrent bazarr"
            ;;
        prowlarr)
            echo "torrent prowlarr"
            ;;
        flaresolverr)
            echo "torrent flaresolverr"
            ;;
        unpackerr)
            echo "torrent unpackerr"
            ;;
        recyclarr)
            echo "torrent recyclarr"
            ;;

        # Plex stack
        plex)
            echo "plex plex"
            ;;
        suggestarr)
            echo "plex suggestarr"
            ;;

        *)
            log "ERROR: Unknown container name: $container_name"
            return 1
            ;;
    esac
}

# Update a single service
update_service() {
    local container_name=$1
    local image=$2
    local new_version=$3

    log "Processing update for container: $container_name (Image: $image, New version: $new_version)"

    # Get stack and service mapping
    local stack_service=$(get_stack_and_service "$container_name")
    if [ $? -ne 0 ]; then
        log "Skipping unknown container: $container_name"
        return 1
    fi

    local stack=$(echo "$stack_service" | awk '{print $1}')
    local service=$(echo "$stack_service" | awk '{print $2}')

    log "Mapped to stack: $stack, service: $service"

    # Navigate to homelab directory and run stack-manage.sh
    HOMELAB_DIR="/homelab"
    if [ ! -d "$HOMELAB_DIR" ]; then
        HOMELAB_DIR="/root/Github/homelab-media"
    fi

    if [ ! -f "$HOMELAB_DIR/stack-manage.sh" ]; then
        log "ERROR: Could not find stack-manage.sh in $HOMELAB_DIR"
        return 1
    fi

    # Run stack-manage.sh from the homelab directory
    log "Running: cd $HOMELAB_DIR && ./stack-manage.sh $stack update $service"
    if (cd "$HOMELAB_DIR" && ./stack-manage.sh "$stack" update "$service") >> "$LOG_FILE" 2>&1; then
        log "Successfully updated $container_name"

        # Send success notification
        curl -H "Title: Container Updated" \
             -H "Priority: 3" \
             -H "Tags: white_check_mark,docker" \
             -d "Successfully updated $container_name from $image to $new_version" \
             https://ntfy.sh/blaze-homelab-wud-docker-updates 2>/dev/null || true

        return 0
    else
        log "ERROR: Failed to update $container_name"

        # Send failure notification
        curl -H "Title: Update Failed" \
             -H "Priority: 4" \
             -H "Tags: x,warning" \
             -d "Failed to update $container_name. Check logs at $LOG_FILE" \
             https://ntfy.sh/blaze-homelab-wud-docker-updates 2>/dev/null || true

        return 1
    fi
}

# Main execution
main() {
    log "========== WUD Update Handler Started =========="

    # Read JSON from stdin (WUD sends container info via webhook)
    # Example input: {"container":"overseerr","image":"lscr.io/linuxserver/overseerr","tag":"latest"}

    if [ -t 0 ]; then
        # Running interactively - expect command line arguments
        if [ $# -lt 1 ]; then
            log "Usage: $0 <container_name> [image] [new_version]"
            exit 1
        fi

        update_service "$1" "${2:-unknown}" "${3:-unknown}"
    else
        # Running from webhook - read JSON from stdin
        input=$(cat)
        log "Received webhook data: $input"

        # Parse JSON (simple extraction - handle various field names)
        container=$(echo "$input" | grep -o '"container" *: *"[^"]*"' | sed 's/.*"container" *: *"\([^"]*\)".*/\1/')

        # Try to extract image
        image=$(echo "$input" | grep -o '"image" *: *"[^"]*"' | sed 's/.*"image" *: *"\([^"]*\)".*/\1/')
        if [ -z "$image" ]; then
            image="unknown"
        fi

        # Try to extract tag
        tag=$(echo "$input" | grep -o '"tag" *: *"[^"]*"' | sed 's/.*"tag" *: *"\([^"]*\)".*/\1/')
        if [ -z "$tag" ]; then
            tag="unknown"
        fi

        if [ -n "$container" ] && [ "$container" != "" ]; then
            update_service "$container" "$image" "$tag"
        else
            log "ERROR: Could not parse container name from webhook data"
            exit 1
        fi
    fi

    log "========== WUD Update Handler Completed =========="
}

main "$@"
