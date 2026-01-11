#!/bin/bash

# analyze-docker-logs.sh - Analyze Docker Compose logs for errors and warnings
# Usage: ./analyze-docker-logs.sh [--since TIME]
#   --since: Time period to analyze (e.g., 1h, 30m, 24h, 2d)

set -euo pipefail

# Default time period
TIME_PERIOD="1h"

# Docker Compose projects to analyze (project-name:compose-file)
declare -A COMPOSE_PROJECTS=(
    ["homelab-torrent"]="docker-compose-torrent.yml"
    ["homelab-plex"]="docker-compose-plex.yml"
    ["homelab-services"]="docker-compose-services.yml"
)

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --since)
            TIME_PERIOD="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [--since TIME]"
            echo "  --since: Time period to analyze (e.g., 1h, 30m, 24h, 2d)"
            echo "  Default: 1h"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use -h for help"
            exit 1
            ;;
    esac
done

echo "=================================================="
echo "Docker Compose Log Analysis"
echo "Time Period: Last $TIME_PERIOD"
echo "Projects: ${!COMPOSE_PROJECTS[@]}"
echo "=================================================="
echo ""

# Get all running containers with their project labels
ALL_CONTAINERS=$(docker ps --format '{{.Names}}\t{{.Label "com.docker.compose.project"}}')

if [ -z "$ALL_CONTAINERS" ]; then
    echo "Error: No running containers found"
    exit 1
fi

# Build list of services per project
declare -A SERVICES_BY_PROJECT

while IFS=$'\t' read -r container_name project; do
    if [ -n "$project" ] && [ -n "${COMPOSE_PROJECTS[$project]:-}" ]; then
        if [ -z "${SERVICES_BY_PROJECT[$project]:-}" ]; then
            SERVICES_BY_PROJECT[$project]="$container_name"
        else
            SERVICES_BY_PROJECT[$project]="${SERVICES_BY_PROJECT[$project]} $container_name"
        fi
    fi
done <<< "$ALL_CONTAINERS"

if [ ${#SERVICES_BY_PROJECT[@]} -eq 0 ]; then
    echo "Error: No services found in tracked projects"
    exit 1
fi

echo "Analyzing logs for services:"
for project in "${!SERVICES_BY_PROJECT[@]}"; do
    echo "  [$project]:"
    for service in ${SERVICES_BY_PROJECT[$project]}; do
        echo "    - $service"
    done
done
echo ""
echo "=================================================="
echo ""

# Function to analyze logs for a container
analyze_container() {
    local container=$1
    echo "=== $container ==="

    # Get logs for the time period using docker logs
    LOGS=$(docker logs --since="$TIME_PERIOD" "$container" 2>&1 || echo "")

    if [ -z "$LOGS" ]; then
        echo "  No logs found"
        echo ""
        return
    fi

    # Count errors using ripgrep
    ERROR_COUNT=$(echo "$LOGS" | rg -i "error|fatal|critical|exception|failed" -c 2>/dev/null || echo "0")
    WARN_COUNT=$(echo "$LOGS" | rg -i "warn|warning" -c 2>/dev/null || echo "0")

    echo "  Errors: $ERROR_COUNT"
    echo "  Warnings: $WARN_COUNT"

    # Show recent errors
    if [ "$ERROR_COUNT" -gt 0 ]; then
        echo ""
        echo "  Recent errors:"
        echo "$LOGS" | rg -i "error|fatal|critical|exception|failed" | tail -5 | sed 's/^/    /'
    fi

    # Show recent warnings
    if [ "$WARN_COUNT" -gt 0 ]; then
        echo ""
        echo "  Recent warnings:"
        echo "$LOGS" | rg -i "warn|warning" | tail -3 | sed 's/^/    /'
    fi

    echo ""
}

# Analyze each container
for project in "${!SERVICES_BY_PROJECT[@]}"; do
    for container in ${SERVICES_BY_PROJECT[$project]}; do
        analyze_container "$container"
    done
done

echo "=================================================="
echo "Summary"
echo "=================================================="

# Overall statistics
TOTAL_ERRORS=0
TOTAL_WARNINGS=0

for project in "${!SERVICES_BY_PROJECT[@]}"; do
    for container in ${SERVICES_BY_PROJECT[$project]}; do
        LOGS=$(docker logs --since="$TIME_PERIOD" "$container" 2>&1 || echo "")
        if [ -n "$LOGS" ]; then
            ERRORS=$(echo "$LOGS" | rg -i "error|fatal|critical|exception|failed" -c 2>/dev/null || echo "0")
            WARNINGS=$(echo "$LOGS" | rg -i "warn|warning" -c 2>/dev/null || echo "0")
            TOTAL_ERRORS=$((TOTAL_ERRORS + ERRORS))
            TOTAL_WARNINGS=$((TOTAL_WARNINGS + WARNINGS))
        fi
    done
done

echo "Total Errors: $TOTAL_ERRORS"
echo "Total Warnings: $TOTAL_WARNINGS"
echo ""

if [ "$TOTAL_ERRORS" -eq 0 ] && [ "$TOTAL_WARNINGS" -eq 0 ]; then
    echo "✓ No issues detected in the last $TIME_PERIOD"
else
    echo "⚠ Issues detected - review logs above"
fi
