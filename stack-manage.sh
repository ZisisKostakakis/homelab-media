#!/bin/bash
# Stack Management Helper Script
# Manage individual stacks (services, torrent, plex) separately

set -e

STACK=$1
ACTION=$2
SERVICE=$3

show_usage() {
    echo "Usage: $0 <stack> <action> [service]"
    echo ""
    echo "Stacks:"
    echo "  services  - User-facing services (Overseerr, Maintainerr, WUD, etc.)"
    echo "  torrent   - VPN and download automation (Gluetun, qBit, *arr)"
    echo "  plex      - Media server (Plex, SuggestArr)"
    echo "  all       - All stacks"
    echo ""
    echo "Actions:"
    echo "  start     - Start the stack/service"
    echo "  stop      - Stop the stack/service"
    echo "  restart   - Restart the stack/service"
    echo "  down      - Stop and remove containers"
    echo "  pull      - Pull latest images"
    echo "  update    - Pull images and recreate containers"
    echo "  logs      - Show logs (last 50 lines)"
    echo "  status    - Show container status"
    echo ""
    echo "Service (optional):"
    echo "  Specify a service name to manage individual services within a stack"
    echo "  If omitted, the entire stack will be managed"
    echo ""
    echo "Examples:"
    echo "  $0 services restart              # Restart entire services stack"
    echo "  $0 torrent logs qbittorrent      # View logs for just qBittorrent"
    echo "  $0 torrent restart sonarr        # Restart only Sonarr"
    echo "  $0 all update                    # Update all stacks"
}

manage_stack() {
    local stack=$1
    local action=$2
    local service=$3
    local compose_file="docker-compose-${stack}.yml"
    local project_name="homelab-${stack}"

    if [ ! -f "$compose_file" ]; then
        echo "Error: $compose_file not found"
        return 1
    fi

    if [ -n "$service" ]; then
        echo "=== Managing $service in $project_name ==="
    else
        echo "=== Managing $project_name ==="
    fi

    case $action in
        start)
            docker compose -p "$project_name" -f "$compose_file" up -d $service
            ;;
        stop)
            docker compose -p "$project_name" -f "$compose_file" stop $service
            ;;
        restart)
            docker compose -p "$project_name" -f "$compose_file" restart $service
            ;;
        down)
            if [ -n "$service" ]; then
                docker compose -p "$project_name" -f "$compose_file" rm -s -f $service
            else
                docker compose -p "$project_name" -f "$compose_file" down
            fi
            ;;
        pull)
            docker compose -p "$project_name" -f "$compose_file" pull $service
            ;;
        update)
            docker compose -p "$project_name" -f "$compose_file" pull $service
            docker compose -p "$project_name" -f "$compose_file" up -d $service
            ;;
        logs)
            if [ -n "$service" ]; then
                docker compose -p "$project_name" -f "$compose_file" logs --tail=50 $service
            else
                docker compose -p "$project_name" -f "$compose_file" logs --tail=50
            fi
            ;;
        status)
            docker compose -p "$project_name" -f "$compose_file" ps $service
            ;;
        *)
            echo "Error: Unknown action '$action'"
            show_usage
            return 1
            ;;
    esac
}

# Main logic
if [ -z "$STACK" ] || [ -z "$ACTION" ]; then
    show_usage
    exit 1
fi

if [ "$STACK" = "all" ]; then
    if [ -n "$SERVICE" ]; then
        echo "Error: Cannot specify a service when using 'all' stacks"
        show_usage
        exit 1
    fi
    for s in services torrent plex; do
        manage_stack "$s" "$ACTION" "$SERVICE"
        echo ""
    done
else
    case $STACK in
        services|torrent|plex)
            manage_stack "$STACK" "$ACTION" "$SERVICE"
            ;;
        *)
            echo "Error: Unknown stack '$STACK'"
            show_usage
            exit 1
            ;;
    esac
fi
