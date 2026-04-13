#!/bin/bash
# Stack Management Helper Script
# Manage individual stacks (services, torrent, plex) separately

set -e

STACK=$1
ACTION=$2
SERVICE=$3

# Optional: set NO_COLOR=1 or pass --no-color to suppress colored output
NO_COLOR="${NO_COLOR:-0}"
if [ "${1:-}" = "--no-color" ]; then
    NO_COLOR=1
    shift
    STACK=$1
    ACTION=$2
    SERVICE=$3
fi

log_info()  { [ "$NO_COLOR" = "1" ] && echo "[INFO]  $*" || echo -e "\033[0;32m[INFO]\033[0m  $*"; }
log_warn()  { [ "$NO_COLOR" = "1" ] && echo "[WARN]  $*" || echo -e "\033[1;33m[WARN]\033[0m  $*"; }
log_error() { [ "$NO_COLOR" = "1" ] && echo "[ERROR] $*" || echo -e "\033[0;31m[ERROR]\033[0m $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Pre-flight: verify docker daemon is reachable before attempting any operation
preflight_checks() {
    if ! docker info > /dev/null 2>&1; then
        log_error "Docker daemon is not running or not accessible"
        echo "  Start Docker: sudo systemctl start docker"
        exit 1
    fi

    local env_file="${SCRIPT_DIR}/.env"
    if [ ! -f "$env_file" ]; then
        log_warn ".env file not found at $env_file"
        echo "  Copy .env.example to .env and fill in your credentials"
    fi
}

show_usage() {
    echo "Usage: $0 <stack> <action> [service]"
    echo ""
    echo "Stacks:"
    echo "  services  - User-facing services (Seerr, Maintainerr, WUD, etc.)"
    echo "  torrent   - VPN and download automation (Gluetun, qBit, *arr, Lidarr)"
    echo "  plex      - Media server (Plex, SuggestArr)"
    echo "  music     - Music stack (Navidrome, AudioMuse)"
    echo "  books     - Books stack (Kavita, Suwayomi, rreading-glasses)"
    echo "  all       - All stacks"
    echo ""
    echo "Actions:"
    echo "  start     - Start the stack/service"
    echo "  stop      - Stop the stack/service"
    echo "  restart   - Restart the stack/service (recreates containers, picks up .env changes)"
    echo "  down      - Stop and remove containers"
    echo "  pull      - Pull latest images"
    echo "  update    - Pull images and recreate containers"
    echo "  logs      - Show logs (last 50 lines)"
    echo "  status    - Show container status"
    echo "  health    - Show running homelab container health summary"
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

# Run a docker compose command with one automatic retry on transient failure
run_with_retry() {
    if "$@"; then
        return 0
    fi
    log_warn "Command failed (attempt 1), retrying in 5s..."
    sleep 5
    if "$@"; then
        return 0
    fi
    log_error "Command failed after 2 attempts: $*"
    return 1
}

TORRENT_GLUETUN_DEPENDENTS="qbittorrent sonarr radarr readarr prowlarr bazarr flaresolverr lidarr unpackerr recyclarr"

# For the torrent stack, restart gluetun first and wait for it to be healthy
# before recreating dependents, to avoid a race condition where dependents
# lose their network namespace and fail to come back up.
torrent_safe_recreate() {
    local compose_file=$1
    local project_name=$2
    local pull=$3  # "true" to pull images first

    if [ "$pull" = "true" ]; then
        echo "Building local images..."
        docker compose -p "$project_name" -f "$compose_file" build
        echo "Pulling latest images..."
        docker compose -p "$project_name" -f "$compose_file" pull --ignore-buildable
    fi

    echo "Recreating gluetun..."
    docker compose -p "$project_name" -f "$compose_file" up -d --force-recreate gluetun

    echo "Waiting for gluetun to be healthy..."
    local elapsed=0
    local timeout=120
    while [ $elapsed -lt $timeout ]; do
        local health
        health=$(docker inspect gluetun --format '{{.State.Health.Status}}' 2>/dev/null || echo "unknown")
        if [ "$health" = "healthy" ]; then
            echo "Gluetun is healthy. Recreating dependents..."
            # Remove stale containers (including hash-named ones) for each dependent service
            for svc in $TORRENT_GLUETUN_DEPENDENTS; do
                docker ps -a --format "{{.ID}}" --filter "label=com.docker.compose.project=$project_name" --filter "label=com.docker.compose.service=$svc" | xargs -r docker rm -f 2>/dev/null || true
            done
            docker compose -p "$project_name" -f "$compose_file" up -d $TORRENT_GLUETUN_DEPENDENTS
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done

    echo "Error: gluetun did not become healthy within ${timeout}s"
    return 1
}

manage_stack() {
    local stack=$1
    local action=$2
    local service=$3
    local compose_file="${SCRIPT_DIR}/docker-compose-${stack}.yml"
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
            run_with_retry docker compose -p "$project_name" -f "$compose_file" up -d $service
            ;;
        stop)
            docker compose -p "$project_name" -f "$compose_file" stop $service
            ;;
        restart)
            if [ "$stack" = "torrent" ] && [ -z "$service" ]; then
                torrent_safe_recreate "$compose_file" "$project_name" "false"
            else
                run_with_retry docker compose -p "$project_name" -f "$compose_file" up -d --force-recreate $service
            fi
            ;;
        down)
            if [ -n "$service" ]; then
                docker compose -p "$project_name" -f "$compose_file" rm -s -f $service
            else
                docker compose -p "$project_name" -f "$compose_file" down
            fi
            ;;
        pull)
            run_with_retry docker compose -p "$project_name" -f "$compose_file" pull $service
            ;;
        update)
            if [ "$stack" = "torrent" ] && [ -z "$service" ]; then
                torrent_safe_recreate "$compose_file" "$project_name" "true"
            else
                run_with_retry docker compose -p "$project_name" -f "$compose_file" pull $service
                run_with_retry docker compose -p "$project_name" -f "$compose_file" up -d --force-recreate $service
            fi
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
        health)
            echo "=== Container health for $project_name ==="
            docker ps --format "table {{.Names}}\t{{.Status}}" | grep "^${project_name}-" || echo "(no ${project_name} containers running)"
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

preflight_checks

if [ "$STACK" = "all" ]; then
    if [ -n "$SERVICE" ]; then
        echo "Error: Cannot specify a service when using 'all' stacks"
        show_usage
        exit 1
    fi
    for s in services torrent plex music books; do
        manage_stack "$s" "$ACTION" "$SERVICE" || echo "Warning: $s stack returned an error"
        echo ""
    done
else
    case $STACK in
        services|torrent|plex|music|books)
            manage_stack "$STACK" "$ACTION" "$SERVICE"
            ;;
        *)
            echo "Error: Unknown stack '$STACK'"
            show_usage
            exit 1
            ;;
    esac
fi
