#!/bin/bash

# analyze-docker-logs.sh - Analyze Docker Compose logs for errors and warnings
# Usage: ./analyze-docker-logs.sh [--since TIME] [--json] [--output FILE]
#   --since:  Time period to analyze (e.g., 1h, 30m, 24h, 2d)
#   --json:   Output results as newline-delimited JSON objects (one per container)
#   --output: Write output to FILE instead of stdout

set -euo pipefail

# Default time period
TIME_PERIOD="24h"
OUTPUT_JSON=false
OUTPUT_FILE=""

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
        --json)
            OUTPUT_JSON=true
            shift
            ;;
        --output)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [--since TIME] [--json] [--output FILE]"
            echo "  --since:  Time period to analyze (e.g., 1h, 30m, 24h, 48h)"
            echo "  --json:   Output newline-delimited JSON (one object per container)"
            echo "  --output: Write output to FILE instead of stdout"
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

# Redirect all output to file when --output is specified
if [ -n "$OUTPUT_FILE" ]; then
    exec > "$OUTPUT_FILE"
    echo "Output written to: $OUTPUT_FILE" >&2
fi

if [ "$OUTPUT_JSON" = false ]; then
    echo "=================================================="
    echo "Docker Compose Log Analysis"
    echo "Time Period: Last $TIME_PERIOD"
    echo "Projects: ${!COMPOSE_PROJECTS[@]}"
    echo "=================================================="
    echo ""
fi

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

if [ "$OUTPUT_JSON" = false ]; then
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
fi

# Accumulated totals — populated by analyze_container, used in summary
TOTAL_ERRORS=0
TOTAL_WARNINGS=0

# Categorize log lines into named buckets for structured output.
# Prints "category:count" pairs, one per line.
categorize_logs() {
    local clean_logs="$1"
    local auth_count network_count db_count disk_count
    auth_count=$(echo "$clean_logs" | grep -ciE "\b(auth(entication|orization)?|login|credential|permission denied|forbidden|unauthorized)\b" || true)
    network_count=$(echo "$clean_logs" | grep -ciE "\b(connection (refused|reset|timed? ?out)|no route to host|network (unreachable|error)|dial (tcp|udp)|dns (lookup|resolution))\b" || true)
    db_count=$(echo "$clean_logs" | grep -ciE "\b(sql|sqlite|postgres|database|migration|deadlock|constraint)\b" || true)
    disk_count=$(echo "$clean_logs" | grep -ciE "\b(no space left|disk full|i/o error|read.only file system|permission denied on )\b" || true)
    echo "auth:$auth_count"
    echo "network:$network_count"
    echo "database:$db_count"
    echo "disk:$disk_count"
}

# Emit a single-line JSON object for --json mode (no external deps, pure bash/printf)
emit_json() {
    local container=$1 project=$2 log_line_count=$3 error_count=$4 warn_count=$5
    local failed_count=$6 auth=$7 network=$8 db=$9 disk=${10}
    local recent_errors="${11}" recent_warnings="${12}"
    # Escape double-quotes and backslashes in sample strings
    recent_errors=$(printf '%s' "$recent_errors" | sed 's/\\/\\\\/g; s/"/\\"/g; s/$/\\n/' | tr -d '\n' | sed 's/\\n$//')
    recent_warnings=$(printf '%s' "$recent_warnings" | sed 's/\\/\\\\/g; s/"/\\"/g; s/$/\\n/' | tr -d '\n' | sed 's/\\n$//')
    printf '{"container":"%s","project":"%s","time_period":"%s","log_lines":%s,"errors":%s,"warnings":%s,"failed_mentions":%s,"categories":{"auth":%s,"network":%s,"database":%s,"disk":%s},"recent_errors":"%s","recent_warnings":"%s"}\n' \
        "$container" "$project" "$TIME_PERIOD" \
        "$log_line_count" "$error_count" "$warn_count" "$failed_count" \
        "$auth" "$network" "$db" "$disk" \
        "$recent_errors" "$recent_warnings"
}

# Function to analyze logs for a container
analyze_container() {
    # Run with errexit disabled — we handle errors explicitly inside
    set +e
    local container=$1
    local project=$2

    # Get logs for the time period — capture stderr too (docker logs writes to stderr)
    local logs
    logs=$(docker logs --since="$TIME_PERIOD" "$container" 2>&1)
    local fetch_status=$?
    if [ $fetch_status -ne 0 ]; then
        if [ "$OUTPUT_JSON" = false ]; then
            echo "=== $container [$project] ==="
            echo "  Warning: failed to fetch logs for $container"
            echo ""
        fi
        set -e
        return
    fi

    if [ -z "$logs" ]; then
        if [ "$OUTPUT_JSON" = false ]; then
            echo "=== $container [$project] ==="
            local any_logs
            any_logs=$(docker logs --tail 1 "$container" 2>&1) || true
            if [ -z "$any_logs" ]; then
                echo "  No logs found (container has never logged)"
            else
                local last_log timestamp
                last_log=$(docker logs --timestamps --tail 1 "$container" 2>&1 | head -1) || true
                timestamp=$(echo "$last_log" | cut -d' ' -f1)
                echo "  No logs in last $TIME_PERIOD (last log: $timestamp)"
            fi
            echo ""
        fi
        set -e
        return
    fi

    # Strip ANSI color codes before pattern matching
    local clean_logs
    clean_logs=$(echo "$logs" | sed 's/\x1b\[[0-9;]*m//g')

    local log_line_count
    log_line_count=$(echo "$logs" | wc -l)

    # Error/warning patterns — anchored to avoid matching JSON keys like "error_code" or
    # noisy phrases like "failed to find optional dependency"
    local error_count warn_count failed_count
    error_count=$(echo "$clean_logs" | grep -iE "(^|[[:space:]|\[])(\berror\b|fatal|critical|exception)([[:space:]|\]|:]|$)" | grep -viE "optional.dependency|error_code.*:[[:space:]]*0" | wc -l)
    warn_count=$(echo "$clean_logs" | grep -iE "(^|[[:space:]|\[])warn(ing)?([[:space:]|\]|:]|$)" | wc -l)
    failed_count=$(echo "$clean_logs" | grep -iE "\bfailed\b" | grep -viE "optional.dependency" | wc -l)

    # Category counts
    local auth_count=0 network_count=0 db_count=0 disk_count=0
    while IFS=: read -r cat count; do
        case $cat in
            auth)    auth_count=$count ;;
            network) network_count=$count ;;
            database) db_count=$count ;;
            disk)    disk_count=$count ;;
        esac
    done < <(categorize_logs "$clean_logs")

    local recent_errors recent_warnings
    recent_errors=$(echo "$clean_logs" | grep -iE "(^|[[:space:]|\[])(\berror\b|fatal|critical|exception)([[:space:]|\]|:]|$)" | grep -viE "optional.dependency|error_code.*:[[:space:]]*0" | tail -5 || true)
    recent_warnings=$(echo "$clean_logs" | grep -iE "(^|[[:space:]|\[])warn(ing)?([[:space:]|\]|:]|$)" | tail -3 || true)

    if [ "$OUTPUT_JSON" = true ]; then
        emit_json "$container" "$project" "$log_line_count" "$error_count" "$warn_count" \
            "$failed_count" "$auth_count" "$network_count" "$db_count" "$disk_count" \
            "$recent_errors" "$recent_warnings"
    else
        echo "=== $container [$project] ==="
        echo "  Total log lines: $log_line_count"
        echo "  Errors: $error_count"
        echo "  Warnings: $warn_count"
        [ "$failed_count" -gt 0 ] && echo "  'Failed' mentions: $failed_count (may include non-critical)"

        if [ "$auth_count" -gt 0 ] || [ "$network_count" -gt 0 ] || [ "$db_count" -gt 0 ] || [ "$disk_count" -gt 0 ]; then
            echo "  Categories: auth=$auth_count network=$network_count database=$db_count disk=$disk_count"
        fi

        if [ "$error_count" -gt 0 ]; then
            echo ""
            echo "  Recent errors:"
            echo "$recent_errors" | sed 's/^/    /'
        fi

        if [ "$warn_count" -gt 0 ]; then
            echo ""
            echo "  Recent warnings:"
            echo "$recent_warnings" | sed 's/^/    /'
        fi

        if [ "$error_count" -eq 0 ] && [ "$warn_count" -eq 0 ] && [ "$log_line_count" -gt 0 ]; then
            echo ""
            echo "  Recent activity (last 3 lines):"
            echo "$logs" | tail -3 | sed 's/^/    /'
        fi

        echo ""
    fi

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

if [ "$OUTPUT_JSON" = true ]; then
    printf '{"summary":true,"time_period":"%s","total_errors":%d,"total_warnings":%d}\n' \
        "$TIME_PERIOD" "$TOTAL_ERRORS" "$TOTAL_WARNINGS"
else
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
fi
