#!/bin/bash

# analyze-docker-logs.sh - Analyze Docker Compose logs for errors and warnings
#
# Quick examples:
#   ./analyze-docker-logs.sh --since 2h
#   ./analyze-docker-logs.sh --service sonarr --grep "timeout" --context 2
#   ./analyze-docker-logs.sh --level error --summary-only
#   ./analyze-docker-logs.sh --json --since 1d --output /tmp/log-report.ndjson

set -euo pipefail

# Default time period
TIME_PERIOD="24h"
OUTPUT_JSON=false
OUTPUT_FILE=""
SERVICE_FILTER=""
GREP_PATTERN=""
LEVEL_FILTER=""      # error | warn | info
CONTEXT_LINES=0       # grep -C N around matches when GREP_PATTERN is set
TAIL_LIMIT=5          # number of recent-error lines to show (warnings = max(3, half))
NO_COLOR=false
SUMMARY_ONLY=false

# Docker Compose projects to analyze (project-name:compose-file)
declare -A COMPOSE_PROJECTS=(
    ["homelab-torrent"]="docker-compose-torrent.yml"
    ["homelab-plex"]="docker-compose-plex.yml"
    ["homelab-services"]="docker-compose-services.yml"
    ["homelab-music"]="docker-compose-music.yml"
)

# --- Categorisation table -------------------------------------------------
# Add a new bucket by appending CATEGORY_NAMES and the matching regex below.
# Each regex is grep -E compatible; case-insensitive matching is applied.
CATEGORY_NAMES=(auth network database disk permissions)
declare -A CATEGORY_REGEX=(
    [auth]="\b(auth(entication|orization)?|login|credential|forbidden|unauthorized|invalid token|bad api key)\b"
    [network]="\b(connection (refused|reset|timed? ?out)|no route to host|network (unreachable|error)|dial (tcp|udp)|dns (lookup|resolution)|timeout)\b"
    [database]="\b(sql|sqlite|postgres|database|migration|deadlock|constraint)\b"
    [disk]="\b(no space left|disk full|i/o error|read.only file system)\b"
    [permissions]="\b(permission denied|EACCES|operation not permitted|chown:|chmod:|cannot create directory)\b"
)
# -------------------------------------------------------------------------

usage() {
    cat <<EOF
analyze-docker-logs.sh — search & categorise homelab container logs

Usage: $0 [flags]

Time window:
  --since DUR        Time period (1h, 30m, 24h, 2d). Default: 24h
  --hours N          Alias: --since Nh
  --minutes N        Alias: --since Nm

Filtering:
  --service NAME     Only analyse containers whose name contains NAME
  --grep PATTERN     Extended regex; only lines matching PATTERN are kept
  --context N        Show N lines of context around --grep matches (default 0)
  --level LEVEL      Restrict counts/samples to one level: error | warn | info

Output:
  --json             Newline-delimited JSON, one object per container + summary
  --output FILE      Write output to FILE instead of stdout
  --summary-only     Suppress recent-error/warning samples (good for cron)
  --tail N           Cap recent-error samples at N lines (default 5)
  --no-color         Suppress ANSI colour escapes

Categories (counted automatically):
  ${CATEGORY_NAMES[*]}

Examples:
  $0 --service sonarr --grep "timeout" --since 2h --summary-only
  $0 --level error --tail 10
  $0 --json --since 1d > /tmp/log-report.ndjson
EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --since)        TIME_PERIOD="$2"; shift 2 ;;
        --hours)        TIME_PERIOD="${2}h"; shift 2 ;;
        --minutes)      TIME_PERIOD="${2}m"; shift 2 ;;
        --json)         OUTPUT_JSON=true; shift ;;
        --output)       OUTPUT_FILE="$2"; shift 2 ;;
        --service)      SERVICE_FILTER="$2"; shift 2 ;;
        --grep)         GREP_PATTERN="$2"; shift 2 ;;
        --context)      CONTEXT_LINES="$2"; shift 2 ;;
        --level)        LEVEL_FILTER="$2"; shift 2 ;;
        --tail)         TAIL_LIMIT="$2"; shift 2 ;;
        --no-color)     NO_COLOR=true; shift ;;
        --summary-only) SUMMARY_ONLY=true; shift ;;
        -h|--help)      usage; exit 0 ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

# Normalise day-style durations (docker logs --since accepts only h/m/s).
# 2d -> 48h, 1d -> 24h, etc.
if [[ "$TIME_PERIOD" =~ ^([0-9]+)d$ ]]; then
    TIME_PERIOD="$(( ${BASH_REMATCH[1]} * 24 ))h"
fi

if ! [[ "$TIME_PERIOD" =~ ^[0-9]+[hms]$ ]]; then
    echo "Error: Invalid time period '$TIME_PERIOD'. Use 30m, 2h, 1d, 90s, etc." >&2
    exit 1
fi

if [ -n "$LEVEL_FILTER" ] && ! [[ "$LEVEL_FILTER" =~ ^(error|warn|info)$ ]]; then
    echo "Error: --level must be one of: error, warn, info" >&2
    exit 1
fi

if ! [[ "$CONTEXT_LINES" =~ ^[0-9]+$ ]]; then
    echo "Error: --context expects a non-negative integer" >&2
    exit 1
fi
if ! [[ "$TAIL_LIMIT" =~ ^[0-9]+$ ]] || [ "$TAIL_LIMIT" -lt 1 ]; then
    echo "Error: --tail expects a positive integer" >&2
    exit 1
fi

# Redirect all output to file when --output is specified
if [ -n "$OUTPUT_FILE" ]; then
    exec > "$OUTPUT_FILE"
    echo "Output written to: $OUTPUT_FILE" >&2
fi

# Colour helpers honour --no-color
if [ "$NO_COLOR" = true ] || [ -n "$OUTPUT_FILE" ]; then
    C_RESET=""; C_BOLD=""; C_DIM=""
else
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
fi

# Patterns used to identify error and warning lines. Anchored to avoid
# matching JSON keys like "error_code" or noisy phrases like "failed to
# find optional dependency".
ERROR_REGEX="(^|[[:space:]|\[])(\berror\b|fatal|critical|exception)([[:space:]|\]|:]|$)"
WARN_REGEX="(^|[[:space:]|\[])warn(ing)?([[:space:]|\]|:]|$)"
INFO_REGEX="(^|[[:space:]|\[])info(rmation)?([[:space:]|\]|:]|$)"
ERROR_NOISE_REGEX="optional.dependency|error_code.*:[[:space:]]*0"

if [ "$OUTPUT_JSON" = false ]; then
    echo "=================================================="
    echo "Docker Compose Log Analysis"
    echo "Time Period:    Last $TIME_PERIOD"
    [ -n "$SERVICE_FILTER" ] && echo "Service filter: $SERVICE_FILTER"
    [ -n "$GREP_PATTERN" ]   && echo "Grep pattern:   $GREP_PATTERN (context=$CONTEXT_LINES)"
    [ -n "$LEVEL_FILTER" ]   && echo "Level filter:   $LEVEL_FILTER"
    [ "$SUMMARY_ONLY" = true ] && echo "Mode:           summary-only"
    echo "Projects:       ${!COMPOSE_PROJECTS[@]}"
    echo "=================================================="
    echo ""
fi

# Get all running containers with their project labels
ALL_CONTAINERS=$(docker ps --format '{{.Names}}\t{{.Label "com.docker.compose.project"}}')

if [ -z "$ALL_CONTAINERS" ]; then
    echo "Error: No running containers found" >&2
    exit 1
fi

# Build list of services per project, newline-delimited to handle names safely.
# Apply --service filter here so downstream loops only see matching containers.
declare -A SERVICES_BY_PROJECT

while IFS=$'\t' read -r container_name project; do
    if [ -n "$project" ] && [ -n "${COMPOSE_PROJECTS[$project]:-}" ]; then
        if [ -n "$SERVICE_FILTER" ] && [[ "$container_name" != *"$SERVICE_FILTER"* ]]; then
            continue
        fi
        if [ -z "${SERVICES_BY_PROJECT[$project]:-}" ]; then
            SERVICES_BY_PROJECT[$project]="$container_name"
        else
            SERVICES_BY_PROJECT[$project]="${SERVICES_BY_PROJECT[$project]}"$'\n'"$container_name"
        fi
    fi
done <<< "$ALL_CONTAINERS"

if [ ${#SERVICES_BY_PROJECT[@]} -eq 0 ]; then
    if [ -n "$SERVICE_FILTER" ]; then
        echo "Error: No services match --service '$SERVICE_FILTER'" >&2
    else
        echo "Error: No services found in tracked projects" >&2
    fi
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

# Categorise log lines into named buckets. Prints "category:count" per line,
# driven by the CATEGORY_NAMES / CATEGORY_REGEX table at the top of the file.
categorize_logs() {
    local clean_logs="$1"
    local cat regex count
    for cat in "${CATEGORY_NAMES[@]}"; do
        regex="${CATEGORY_REGEX[$cat]}"
        count=$(echo "$clean_logs" | grep -ciE "$regex" || true)
        echo "${cat}:${count}"
    done
}

# Single chokepoint for "does this line match the active filters?". Centralising
# the logic makes it easy to add new filter dimensions without rewriting callers.
# Returns 0 on match, 1 otherwise.
match_line() {
    local line="$1" level="${2:-}"
    if [ -n "$GREP_PATTERN" ] && ! echo "$line" | grep -qE "$GREP_PATTERN"; then
        return 1
    fi
    if [ -n "$LEVEL_FILTER" ] && [ -n "$level" ] && [ "$level" != "$LEVEL_FILTER" ]; then
        return 1
    fi
    return 0
}

# Apply --grep / --level filters across a multi-line blob. When --grep is set
# with --context > 0, surrounding lines are kept via grep -C.
apply_grep_filter() {
    local blob="$1"
    if [ -n "$GREP_PATTERN" ]; then
        blob=$(echo "$blob" | grep -E -C "$CONTEXT_LINES" "$GREP_PATTERN" || true)
    fi
    printf '%s' "$blob"
}

# Emit a single-line JSON object for --json mode (no external deps, pure bash/printf).
# JSON shape is extended over the original — existing keys remain stable.
emit_json() {
    local container=$1 project=$2 log_line_count=$3 error_count=$4 warn_count=$5
    local failed_count=$6 categories_json=$7
    local recent_errors="${8}" recent_warnings="${9}"
    # Escape double-quotes and backslashes in sample strings
    recent_errors=$(printf '%s' "$recent_errors" | sed 's/\\/\\\\/g; s/"/\\"/g; s/$/\\n/' | tr -d '\n' | sed 's/\\n$//')
    recent_warnings=$(printf '%s' "$recent_warnings" | sed 's/\\/\\\\/g; s/"/\\"/g; s/$/\\n/' | tr -d '\n' | sed 's/\\n$//')
    printf '{"container":"%s","project":"%s","time_period":"%s","log_lines":%s,"errors":%s,"warnings":%s,"failed_mentions":%s,"categories":%s,"recent_errors":"%s","recent_warnings":"%s","filters":{"service":"%s","grep":"%s","level":"%s"}}\n' \
        "$container" "$project" "$TIME_PERIOD" \
        "$log_line_count" "$error_count" "$warn_count" "$failed_count" \
        "$categories_json" \
        "$recent_errors" "$recent_warnings" \
        "$SERVICE_FILTER" "$GREP_PATTERN" "$LEVEL_FILTER"
}

# Build the categories sub-object as JSON for embedding in emit_json.
build_categories_json() {
    local first=1 cat count out="{"
    while IFS=: read -r cat count; do
        [ $first -eq 1 ] && first=0 || out+=","
        out+="\"${cat}\":${count}"
    done < <(echo "$1")
    out+="}"
    printf '%s' "$out"
}

# Analyse one container's logs and emit either human-readable or JSON output.
analyze_container() {
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

    # Apply --grep filter early so all downstream counts respect it.
    local filtered
    filtered=$(apply_grep_filter "$clean_logs")
    if [ -z "$filtered" ] && [ -n "$GREP_PATTERN" ]; then
        if [ "$OUTPUT_JSON" = false ] && [ "$SUMMARY_ONLY" = false ]; then
            echo "=== $container [$project] ==="
            echo "  No lines matched --grep '$GREP_PATTERN'"
            echo ""
        fi
        set -e
        return
    fi
    clean_logs="$filtered"

    local log_line_count
    log_line_count=$(echo "$logs" | wc -l)

    local error_count warn_count failed_count
    error_count=$(echo "$clean_logs" | grep -iE "$ERROR_REGEX" | grep -viE "$ERROR_NOISE_REGEX" | wc -l)
    warn_count=$(echo "$clean_logs" | grep -iE "$WARN_REGEX" | wc -l)
    failed_count=$(echo "$clean_logs" | grep -iE "\bfailed\b" | grep -viE "optional.dependency" | wc -l)

    # When --level restricts the view, zero out counts that don't belong to it
    # so the summary reflects what the user actually asked for.
    if [ -n "$LEVEL_FILTER" ]; then
        case "$LEVEL_FILTER" in
            error) warn_count=0 ;;
            warn)  error_count=0 ;;
            info)  error_count=0; warn_count=0 ;;
        esac
    fi

    # Category counts (driven by table at top of file)
    local categories_kv
    categories_kv=$(categorize_logs "$clean_logs")

    local recent_errors recent_warnings
    local warn_tail=$(( TAIL_LIMIT / 2 ))
    [ $warn_tail -lt 3 ] && warn_tail=3
    recent_errors=$(echo "$clean_logs" | grep -iE "$ERROR_REGEX" | grep -viE "$ERROR_NOISE_REGEX" | tail -"$TAIL_LIMIT" || true)
    recent_warnings=$(echo "$clean_logs" | grep -iE "$WARN_REGEX" | tail -"$warn_tail" || true)
    if [ "$LEVEL_FILTER" = "warn" ]; then recent_errors=""; fi
    if [ "$LEVEL_FILTER" = "error" ]; then recent_warnings=""; fi
    if [ "$LEVEL_FILTER" = "info" ]; then recent_errors=""; recent_warnings=""; fi

    if [ "$OUTPUT_JSON" = true ]; then
        local cats_json
        cats_json=$(build_categories_json "$categories_kv")
        emit_json "$container" "$project" "$log_line_count" "$error_count" "$warn_count" \
            "$failed_count" "$cats_json" \
            "$recent_errors" "$recent_warnings"
    else
        echo "${C_BOLD}=== $container [$project] ===${C_RESET}"
        echo "  Total log lines: $log_line_count"
        echo "  Errors: $error_count"
        echo "  Warnings: $warn_count"
        [ "$failed_count" -gt 0 ] && echo "  'Failed' mentions: $failed_count (may include non-critical)"

        # Compact category line; only print buckets with non-zero counts
        local cat_summary="" cat count
        while IFS=: read -r cat count; do
            [ "$count" -gt 0 ] && cat_summary+="${cat}=${count} "
        done <<< "$categories_kv"
        [ -n "$cat_summary" ] && echo "  Categories: ${cat_summary% }"

        if [ "$SUMMARY_ONLY" = false ]; then
            if [ "$error_count" -gt 0 ]; then
                echo ""
                echo "  ${C_BOLD}Recent errors:${C_RESET}"
                echo "$recent_errors" | sed 's/^/    /'
            fi

            if [ "$warn_count" -gt 0 ]; then
                echo ""
                echo "  ${C_BOLD}Recent warnings:${C_RESET}"
                echo "$recent_warnings" | sed 's/^/    /'
            fi

            if [ "$error_count" -eq 0 ] && [ "$warn_count" -eq 0 ] && [ "$log_line_count" -gt 0 ] && [ -z "$LEVEL_FILTER" ] && [ -z "$GREP_PATTERN" ]; then
                echo ""
                echo "  ${C_DIM}Recent activity (last 3 lines):${C_RESET}"
                echo "$logs" | tail -3 | sed 's/^/    /'
            fi
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
    printf '{"summary":true,"time_period":"%s","total_errors":%d,"total_warnings":%d,"filters":{"service":"%s","grep":"%s","level":"%s","summary_only":%s}}\n' \
        "$TIME_PERIOD" "$TOTAL_ERRORS" "$TOTAL_WARNINGS" \
        "$SERVICE_FILTER" "$GREP_PATTERN" "$LEVEL_FILTER" "$SUMMARY_ONLY"
else
    echo "=================================================="
    echo "Summary"
    echo "=================================================="
    echo "Total Errors: $TOTAL_ERRORS"
    echo "Total Warnings: $TOTAL_WARNINGS"
    echo ""

    if [ "$TOTAL_ERRORS" -eq 0 ] && [ "$TOTAL_WARNINGS" -eq 0 ]; then
        echo "No issues detected in the last $TIME_PERIOD"
    else
        echo "Issues detected - review logs above"
    fi
fi
