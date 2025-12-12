#!/bin/bash
# Stack Management Helper Script
# Manage individual stacks (services, torrent, plex) separately

set -e

STACK=$1
ACTION=$2

show_usage() {
    echo "Usage: $0 <stack> <action>"
    echo ""
    echo "Stacks:"
    echo "  services  - User-facing services (Overseerr, Maintainerr, WUD, etc.)"
    echo "  torrent   - VPN and download automation (Gluetun, qBit, *arr)"
    echo "  plex      - Media server (Plex, SuggestArr)"
    echo "  all       - All stacks"
    echo ""
    echo "Actions:"
    echo "  start     - Start the stack"
    echo "  stop      - Stop the stack"
    echo "  restart   - Restart the stack"
    echo "  down      - Stop and remove containers"
    echo "  pull      - Pull latest images"
    echo "  update    - Pull images and recreate containers"
    echo "  logs      - Show logs (last 50 lines)"
    echo "  status    - Show container status"
    echo ""
    echo "Examples:"
    echo "  $0 services restart"
    echo "  $0 torrent logs"
    echo "  $0 all update"
}

manage_stack() {
    local stack=$1
    local action=$2
    local compose_file="docker-compose-${stack}.yml"
    local project_name="homelab-${stack}"

    if [ ! -f "$compose_file" ]; then
        echo "Error: $compose_file not found"
        return 1
    fi

    echo "=== Managing $project_name ==="

    case $action in
        start)
            docker compose -p "$project_name" -f "$compose_file" up -d
            ;;
        stop)
            docker compose -p "$project_name" -f "$compose_file" stop
            ;;
        restart)
            docker compose -p "$project_name" -f "$compose_file" restart
            ;;
        down)
            docker compose -p "$project_name" -f "$compose_file" down
            ;;
        pull)
            docker compose -p "$project_name" -f "$compose_file" pull
            ;;
        update)
            docker compose -p "$project_name" -f "$compose_file" pull
            docker compose -p "$project_name" -f "$compose_file" up -d
            ;;
        logs)
            docker compose -p "$project_name" -f "$compose_file" logs --tail=50
            ;;
        status)
            docker compose -p "$project_name" -f "$compose_file" ps
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
    for s in services torrent plex; do
        manage_stack "$s" "$ACTION"
        echo ""
    done
else
    case $STACK in
        services|torrent|plex)
            manage_stack "$STACK" "$ACTION"
            ;;
        *)
            echo "Error: Unknown stack '$STACK'"
            show_usage
            exit 1
            ;;
    esac
fi
