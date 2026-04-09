#!/bin/bash

# analyze-docker-logs.sh - Analyze Docker Compose logs for errors and warnings
# Usage: ./analyze-docker-logs.sh [--since TIME]
#   --since: Time period to analyze (e.g., 1h, 30m, 24h, 2d)

set -euo pipefail

# Default time period
TIME_PERIOD="24h"

# Docker Compose projects to analyze (project-name:compose-file)
declare -A COMPOSE_PROJECTS=(
    ["homelab-torrent"]="docker-compose-torrent.yml"
    ["homelab-plex"]="docker-compose-plex.yml"
    ["homelab-services"]="docker-compose-services.yml"
    ["homelab-music"]="docker-compose-music.yml"
    ["homelab-books"]="docker-compose-books.yml"
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
            echo "  --since: Time period to analyze (e.g., 1h, 30m, 24h, 48h)"
            echo "  Default: 24h"
            echo "  Note: Use hours (h), minutes (m), or seconds (s) only — 'd' is not supported"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use -h for help"
            exit 1
            ;;
    esac
done

# Validate TIME_PERIOD — docker logs --since only supports h, m, s suffixes (not d)
if ! [[ "$TIME_PERIOD" =~ ^[0-9]+[hms]$ ]]; then
    echo "Error: Invalid time period '$TIME_PERIOD'"
    echo "Use a number followed by h (hours), m (minutes), or s (seconds). E.g., 48h, 30m"
    exit 1
fi

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

# Build list of services per project, newline-delimited to handle names safely
declare -A SERVICES_BY_PROJECT

while IFS=$'\t' read -r container_name project; do
    if [ -n "$project" ] && [ -n "${COMPOSE_PROJECTS[$project]:-}" ]; then
        if [ -z "${SERVICES_BY_PROJECT[$project]:-}" ]; then
            SERVICES_BY_PROJECT[$project]="$container_name"
        else
            SERVICES_BY_PROJECT[$project]="${SERVICES_BY_PROJECT[$project]}"$'\n'"$container_name"
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
    while IFS= read -r service; do
        echo "    - $service"
    done <<< "${SERVICES_BY_PROJECT[$project]}"
done
echo ""
echo "=================================================="
echo ""

# Accumulated totals — populated by analyze_container, used in summary
TOTAL_ERRORS=0
TOTAL_WARNINGS=0

# Function to analyze logs for a container
analyze_container() {
    # Run with errexit disabled — we handle errors explicitly inside
    set +e
    local container=$1
    local project=$2
    echo "=== $container [$project] ==="

    # Get logs for the time period — capture stderr too (docker logs writes to stderr)
    local logs
    logs=$(docker logs --since="$TIME_PERIOD" "$container" 2>&1)
    local fetch_status=$?
    if [ $fetch_status -ne 0 ]; then
        echo "  Warning: failed to fetch logs for $container"
        echo ""
        set -e
        return
    fi

    if [ -z "$logs" ]; then
        # Check if container has any logs at all
        local any_logs
        any_logs=$(docker logs --tail 1 "$container" 2>&1) || true
        if [ -z "$any_logs" ]; then
            echo "  No logs found (container has never logged)"
        else
            local last_log
            local timestamp
            last_log=$(docker logs --timestamps --tail 1 "$container" 2>&1 | head -1) || true
            timestamp=$(echo "$last_log" | cut -d' ' -f1)
            echo "  No logs in last $TIME_PERIOD (last log: $timestamp)"
        fi
        echo ""
        return
    fi

    # Strip ANSI color codes before pattern matching
    local clean_logs
    clean_logs=$(echo "$logs" | sed 's/\x1b\[[0-9;]*m//g')

    # Count total log lines
    local log_line_count
    log_line_count=$(echo "$logs" | wc -l)

    # Error/warning patterns — anchored to avoid matching JSON keys like "error_code" or
    # noisy phrases like "failed to find optional dependency"
    local error_count warn_count
    error_count=$(echo "$clean_logs" | grep -iE "(^|[[:space:]|\[])(\berror\b|fatal|critical|exception)([[:space:]|\]|:]|$)" | grep -viE "optional.dependency|error_code.*:[[:space:]]*0" | wc -l)
    warn_count=$(echo "$clean_logs" | grep -iE "(^|[[:space:]|\[])warn(ing)?([[:space:]|\]|:]|$)" | wc -l)

    # Also count bare "failed" lines separately (high noise risk — only show, don't inflate totals)
    local failed_count
    failed_count=$(echo "$clean_logs" | grep -iE "\bfailed\b" | grep -viE "optional.dependency" | wc -l)

    echo "  Total log lines: $log_line_count"
    echo "  Errors: $error_count"
    echo "  Warnings: $warn_count"
    [ "$failed_count" -gt 0 ] && echo "  'Failed' mentions: $failed_count (may include non-critical)"

    # Show recent errors
    if [ "$error_count" -gt 0 ]; then
        echo ""
        echo "  Recent errors:"
        echo "$clean_logs" | grep -iE "(^|[[:space:]|\[])(\berror\b|fatal|critical|exception)([[:space:]|\]|:]|$)" | grep -viE "optional.dependency|error_code.*:[[:space:]]*0" | tail -5 | sed 's/^/    /'
    fi

    # Show recent warnings
    if [ "$warn_count" -gt 0 ]; then
        echo ""
        echo "  Recent warnings:"
        echo "$clean_logs" | grep -iE "(^|[[:space:]|\[])warn(ing)?([[:space:]|\]|:]|$)" | tail -3 | sed 's/^/    /'
    fi

    # Show sample of recent logs if no errors or warnings
    if [ "$error_count" -eq 0 ] && [ "$warn_count" -eq 0 ] && [ "$log_line_count" -gt 0 ]; then
        echo ""
        echo "  Recent activity (last 3 lines):"
        echo "$logs" | tail -3 | sed 's/^/    /'
    fi

    echo ""

    # Accumulate totals (uses global vars — bash functions share parent scope)
    TOTAL_ERRORS=$((TOTAL_ERRORS + error_count))
    TOTAL_WARNINGS=$((TOTAL_WARNINGS + warn_count))
    set -e
}

# Analyze each container — pass project name for context in output
for project in "${!SERVICES_BY_PROJECT[@]}"; do
    while IFS= read -r container; do
        analyze_container "$container" "$project"
    done <<< "${SERVICES_BY_PROJECT[$project]}"
done

echo "=================================================="
echo "Summary"
echo "=================================================="
echo "Total Errors: $TOTAL_ERRORS"
echo "Total Warnings: $TOTAL_WARNINGS"
echo ""

if [ "$TOTAL_ERRORS" -eq 0 ] && [ "$TOTAL_WARNINGS" -eq 0 ]; then
    echo "✓ No issues detected in the last $TIME_PERIOD"
else
    echo "⚠ Issues detected - review logs above"
fi
