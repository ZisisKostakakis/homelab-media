#!/bin/bash

# disk-report.sh — report disk usage of homelab volumes and exit non-zero if
# any monitored mount exceeds --threshold percent full. Designed to pair with
# the `disk` category in analyze-docker-logs.sh.
#
# Usage: ./scripts/disk-report.sh [--threshold N] [--json]
#   --threshold N  Percent (1-100) above which the script exits non-zero. Default 90.
#   --json         Emit one JSON object per monitored mount.

set -euo pipefail

THRESHOLD=90
JSON=false

# Mount points to monitor. Override with HOMELAB_DISK_MOUNTS env var
# (space-separated list) to track additional paths.
DEFAULT_MOUNTS=(/mnt/media /var/lib/homelab-media-configs /var/lib/docker)
MOUNTS=(${HOMELAB_DISK_MOUNTS:-${DEFAULT_MOUNTS[@]}})

while [[ $# -gt 0 ]]; do
    case $1 in
        --threshold) THRESHOLD="$2"; shift 2 ;;
        --json)      JSON=true; shift ;;
        -h|--help)
            sed -n '3,11p' "$0"
            exit 0
            ;;
        *) echo "Unknown arg: $1" >&2; exit 2 ;;
    esac
done

if ! [[ "$THRESHOLD" =~ ^[0-9]+$ ]] || [ "$THRESHOLD" -lt 1 ] || [ "$THRESHOLD" -gt 100 ]; then
    echo "Error: --threshold must be an integer between 1 and 100" >&2
    exit 2
fi

OVERS=0
FIRST_JSON=true

for m in "${MOUNTS[@]}"; do
    if [ ! -e "$m" ]; then
        if [ "$JSON" = false ]; then
            echo "skip  $m  (does not exist)"
        fi
        continue
    fi

    # df -P forces POSIX output (single line per mount, predictable columns)
    read -r used_pct used_h total_h <<< "$(df -P -h "$m" | awk 'NR==2 { gsub("%","",$5); print $5, $3, $2 }')"

    if [ "$JSON" = true ]; then
        [ "$FIRST_JSON" = true ] && FIRST_JSON=false
        printf '{"mount":"%s","used_pct":%s,"used":"%s","total":"%s","threshold":%s,"over":%s}\n' \
            "$m" "$used_pct" "$used_h" "$total_h" "$THRESHOLD" \
            "$([ "$used_pct" -ge "$THRESHOLD" ] && echo true || echo false)"
    else
        marker="  "
        if [ "$used_pct" -ge "$THRESHOLD" ]; then marker="!!"; fi
        printf '%s %-40s %3s%%  %6s / %6s\n' "$marker" "$m" "$used_pct" "$used_h" "$total_h"
    fi

    if [ "$used_pct" -ge "$THRESHOLD" ]; then
        OVERS=$((OVERS + 1))
    fi
done

if [ "$JSON" = false ]; then
    echo ""
    if [ "$OVERS" -eq 0 ]; then
        echo "OK: all mounts under ${THRESHOLD}%"
    else
        echo "FAIL: ${OVERS} mount(s) at or above ${THRESHOLD}%"
    fi
fi

[ "$OVERS" -eq 0 ]
