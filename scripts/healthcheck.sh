#!/bin/bash

# healthcheck.sh — verify every expected homelab service is running.
#
# Walks each docker-compose-*.yml in the repo root, extracts the service list,
# and compares it against currently running containers. Exits non-zero if any
# expected service is missing — suitable for cron + paging.
#
# Usage: ./scripts/healthcheck.sh [--quiet] [--json]
#   --quiet  Only print on failure
#   --json   Single-line JSON status object

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

QUIET=false
JSON=false
for arg in "$@"; do
    case $arg in
        --quiet) QUIET=true ;;
        --json)  JSON=true ;;
        -h|--help)
            sed -n '3,12p' "$0"
            exit 0
            ;;
        *) echo "Unknown arg: $arg" >&2; exit 2 ;;
    esac
done

if ! docker info >/dev/null 2>&1; then
    echo "Error: docker daemon not reachable" >&2
    exit 3
fi

# Collect the set of currently running container names once, for efficient lookup.
RUNNING=$(docker ps --format '{{.Names}}' | sort -u)

MISSING=()
EXPECTED_TOTAL=0

for compose in "$REPO_DIR"/docker-compose-*.yml; do
    [ -f "$compose" ] || continue
    stack=$(basename "$compose" .yml | sed 's/^docker-compose-//')

    # Parse services block: extract service name and container_name (if set).
    # Outputs "service_name<TAB>container_name" lines; container_name falls
    # back to service_name when the key is absent. Stops at the next
    # top-level YAML key so volumes/networks are not included.
    service_map=$(awk '
        /^services:/ { in_services=1; next }
        in_services && /^[a-zA-Z]/ { in_services=0 }
        in_services && /^  [a-zA-Z0-9_-]+:/ {
            if (cur_svc != "" && !cur_has_profile) print cur_svc "\t" (cur_cname != "" ? cur_cname : cur_svc)
            cur_svc = $0; gsub(/^  |:.*$/, "", cur_svc)
            cur_cname = ""; cur_has_profile = 0
            next
        }
        in_services && cur_svc != "" && /^    container_name:/ {
            cur_cname = $0; gsub(/^    container_name: */, "", cur_cname)
            next
        }
        in_services && cur_svc != "" && /^    profiles:/ { cur_has_profile = 1; next }
        END { if (cur_svc != "" && !cur_has_profile) print cur_svc "\t" (cur_cname != "" ? cur_cname : cur_svc) }
    ' "$compose")

    while IFS=$'\t' read -r svc cname; do
        [ -z "$svc" ] && continue
        EXPECTED_TOTAL=$((EXPECTED_TOTAL + 1))
        if ! echo "$RUNNING" | grep -qx "$cname"; then
            MISSING+=("$stack/$svc")
        fi
    done <<< "$service_map"
done

MISSING_COUNT=${#MISSING[@]}

if [ "$JSON" = true ]; then
    missing_csv=$(IFS=,; echo "${MISSING[*]:-}")
    printf '{"expected":%d,"missing":%d,"missing_services":"%s","ok":%s}\n' \
        "$EXPECTED_TOTAL" "$MISSING_COUNT" "$missing_csv" \
        "$([ $MISSING_COUNT -eq 0 ] && echo true || echo false)"
elif [ $MISSING_COUNT -eq 0 ]; then
    [ "$QUIET" = false ] && echo "OK: all $EXPECTED_TOTAL expected services are running"
else
    echo "FAIL: ${MISSING_COUNT}/${EXPECTED_TOTAL} services not running:"
    printf '  - %s\n' "${MISSING[@]}"
fi

[ $MISSING_COUNT -eq 0 ]
