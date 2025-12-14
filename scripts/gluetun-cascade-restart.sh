#!/bin/sh
# Gluetun Cascade Restart Monitor
# Automatically restarts VPN-dependent services when Gluetun restarts

set -e

# Configuration file path
CONFIG_FILE="/config/cascade-restart.conf"

# State tracking
LAST_RESTART_TIME=0
PREVIOUS_GLUETUN_NS=""
FAILURE_COUNT=0
RESTART_TIMESTAMPS=""

#############################################
# Configuration Loading
#############################################

load_configuration() {
    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck source=/dev/null
        . "$CONFIG_FILE"
        log_event "INFO" "Configuration loaded from $CONFIG_FILE"
    else
        log_event "WARN" "Configuration file not found, using defaults"
    fi

    # Set defaults if not configured
    GLUETUN_HEALTHY_TIMEOUT=${GLUETUN_HEALTHY_TIMEOUT:-300}
    STACK_DOWN_DELAY=${STACK_DOWN_DELAY:-5}
    DEBOUNCE_COOLDOWN=${DEBOUNCE_COOLDOWN:-30}
    MAX_RETRY_ATTEMPTS=${MAX_RETRY_ATTEMPTS:-3}
    RETRY_BACKOFF_BASE=${RETRY_BACKOFF_BASE:-5}
    NTFY_ENABLED=${NTFY_ENABLED:-true}
    NTFY_URL=${NTFY_URL:-"https://ntfy.sh"}
    NTFY_TOPIC=${NTFY_TOPIC:-"blaze-homelab-gluetun-cascade"}
    NTFY_PRIORITY=${NTFY_PRIORITY:-4}
    LOG_FILE=${LOG_FILE:-"/config/restart-history.log"}
    VERBOSE_LOGGING=${VERBOSE_LOGGING:-true}
}

#############################################
# Logging Functions
#############################################

log_event() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    local log_line="[$timestamp] [$level] $message"

    # Always output to stdout for Docker logs
    echo "$log_line"

    # Log to file if LOG_FILE is set
    if [ -n "$LOG_FILE" ]; then
        echo "$log_line" >> "$LOG_FILE" 2>/dev/null || true
        # Rotate log if needed (every 10MB)
        rotate_log_if_needed
    fi
}

rotate_log_if_needed() {
    if [ -f "$LOG_FILE" ]; then
        local size_kb
        size_kb=$(du -k "$LOG_FILE" | cut -f1)
        local size_mb=$((size_kb / 1024))

        if [ "$size_mb" -gt 10 ]; then
            local backup_file="${LOG_FILE}.$(date +%Y%m%d-%H%M%S)"
            mv "$LOG_FILE" "$backup_file"
            gzip "$backup_file" &
            log_event "INFO" "Log rotated to $backup_file.gz"

            # Keep only last 5 rotated logs
            find "$(dirname "$LOG_FILE")" -name "$(basename "$LOG_FILE").*.gz" -type f | sort -r | tail -n +6 | xargs rm -f 2>/dev/null || true
        fi
    fi
}

#############################################
# Container Health Functions
#############################################

wait_for_gluetun_healthy() {
    local timeout="$GLUETUN_HEALTHY_TIMEOUT"
    local elapsed=0
    local check_interval=5

    log_event "INFO" "Waiting for Gluetun to become healthy (timeout: ${timeout}s)..."

    while [ $elapsed -lt "$timeout" ]; do
        local health_status
        health_status=$(docker inspect gluetun --format '{{.State.Health.Status}}' 2>/dev/null || echo "unknown")

        if [ "$health_status" = "healthy" ]; then
            log_event "INFO" "Gluetun is healthy after ${elapsed}s"
            return 0
        fi

        if [ "$VERBOSE_LOGGING" = "true" ]; then
            log_event "DEBUG" "Gluetun health: $health_status (${elapsed}s elapsed)"
        fi

        sleep $check_interval
        elapsed=$((elapsed + check_interval))
    done

    log_event "ERROR" "Gluetun failed to become healthy within ${timeout}s"
    return 1
}

get_container_network_namespace() {
    local container="$1"
    docker inspect "$container" --format '{{.NetworkSettings.SandboxKey}}' 2>/dev/null || echo "unknown"
}

get_container_start_time() {
    local container="$1"
    docker inspect "$container" --format '{{.State.StartedAt}}' 2>/dev/null || echo "unknown"
}

verify_all_healthy() {
    local unhealthy_services=""
    local services="gluetun qbittorrent sonarr radarr prowlarr bazarr flaresolverr"

    log_event "INFO" "Verifying all services are healthy..."

    for service in $services; do
        local health
        health=$(docker inspect "$service" --format '{{.State.Health.Status}}' 2>/dev/null || echo "no-healthcheck")

        if [ "$health" = "no-healthcheck" ]; then
            # Check if running instead
            local running
            running=$(docker inspect "$service" --format '{{.State.Running}}' 2>/dev/null || echo "false")
            if [ "$running" != "true" ]; then
                unhealthy_services="$unhealthy_services $service"
            fi
        elif [ "$health" != "healthy" ]; then
            unhealthy_services="$unhealthy_services $service"
        fi
    done

    if [ -n "$unhealthy_services" ]; then
        log_event "WARN" "Unhealthy services:$unhealthy_services"
        return 1
    else
        log_event "INFO" "All services are healthy"
        return 0
    fi
}

#############################################
# Stack Restart Functions
#############################################

cascade_restart_torrent_stack() {
    local start_time
    start_time=$(date +%s)

    log_event "INFO" "=== Starting cascade restart of torrent stack ==="

    # List of VPN-dependent services to restart
    local services="qbittorrent sonarr radarr prowlarr bazarr flaresolverr unpackerr recyclarr cross-seed"

    # Stop and remove all VPN-dependent services
    log_event "INFO" "Stopping and removing VPN-dependent services..."
    for service in $services; do
        if [ "$VERBOSE_LOGGING" = "true" ]; then
            log_event "DEBUG" "Stopping $service..."
        fi
        docker stop "$service" 2>&1 >/dev/null || true
        docker rm "$service" 2>&1 >/dev/null || true
    done

    # Wait for cleanup
    log_event "INFO" "Waiting ${STACK_DOWN_DELAY}s for cleanup..."
    sleep "$STACK_DOWN_DELAY"

    # Recreate all services using docker-compose (called from host via exec)
    log_event "INFO" "Recreating VPN-dependent services..."
    if docker run --rm \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v /root/Github/homelab-media:/workdir \
        -w /workdir \
        docker/compose:1.29.2 \
        -p homelab-torrent -f docker-compose-torrent.yml up -d --no-deps qbittorrent sonarr radarr prowlarr bazarr flaresolverr unpackerr recyclarr cross-seed 2>&1 | grep -vE "(Pulling|Downloaded|Network|Volume)" || true; then
        log_event "INFO" "Services recreated successfully"
    else
        log_event "ERROR" "Failed to recreate services"
        return 1
    fi

    # Wait for services to initialize
    log_event "INFO" "Waiting 30s for services to initialize..."
    sleep 30

    # Verify all services are healthy
    if ! verify_all_healthy; then
        log_event "WARN" "Some services are not healthy after restart"
        # Continue anyway, services might still be starting
    fi

    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))

    log_event "INFO" "=== Cascade restart completed in ${duration}s ==="

    return 0
}

#############################################
# Notification Functions
#############################################

send_notification() {
    local title="$1"
    local message="$2"
    local priority="${3:-$NTFY_PRIORITY}"

    if [ "$NTFY_ENABLED" != "true" ]; then
        log_event "DEBUG" "Notifications disabled, skipping: $title"
        return 0
    fi

    log_event "INFO" "Sending notification: $title"

    if ! curl -X POST \
        -H "Title: Gluetun Monitor - $title" \
        -H "Priority: $priority" \
        -H "Tags: vpn,homelab,restart" \
        -d "$message" \
        "${NTFY_URL}/${NTFY_TOPIC}" \
        --silent --show-error --max-time 10 2>&1 | tee -a "$LOG_FILE"; then
        log_event "WARN" "Failed to send notification"
    fi
}

send_success_notification() {
    local duration="$1"

    local msg="✅ Cascade restart successful

Torrent stack restarted in ${duration}s after Gluetun restart.
All VPN-dependent services have rejoined the network namespace.

Services: qbittorrent, sonarr, radarr, prowlarr, bazarr, flaresolverr, unpackerr, recyclarr, cross-seed"

    send_notification "Cascade Restart Success" "$msg" 3
}

send_failure_notification() {
    local error_msg="$1"

    local msg="⚠️ Cascade restart FAILED

Error: $error_msg

The torrent stack may not have restarted correctly after Gluetun restart.
Manual intervention may be required.

Check logs: docker logs gluetun-monitor"

    send_notification "Cascade Restart FAILED" "$msg" 5
}

send_loop_detection_notification() {
    local count="$1"

    local msg="🚨 RESTART LOOP DETECTED

Gluetun has restarted $count times in the past hour.
Monitor has been paused for 1 hour to prevent cascading failures.

Investigate Gluetun immediately:
docker logs gluetun"

    send_notification "RESTART LOOP DETECTED" "$msg" 5
}

#############################################
# Rate Limiting Functions
#############################################

is_restart_allowed() {
    local now
    now=$(date +%s)
    local hour_ago=$((now - 3600))

    # Count restarts in the past hour
    local recent_count=0
    for ts in $RESTART_TIMESTAMPS; do
        if [ "$ts" -gt "$hour_ago" ]; then
            recent_count=$((recent_count + 1))
        fi
    done

    # If more than 5 restarts in past hour, block
    if [ $recent_count -ge 5 ]; then
        log_event "CRITICAL" "Restart loop detected! $recent_count restarts in past hour"
        send_loop_detection_notification "$recent_count"
        log_event "INFO" "Pausing monitor for 1 hour..."
        sleep 3600
        RESTART_TIMESTAMPS=""
        return 1
    fi

    # Add current timestamp
    RESTART_TIMESTAMPS="$RESTART_TIMESTAMPS $now"

    return 0
}

#############################################
# Event Handling Functions
#############################################

handle_gluetun_event() {
    local timestamp="$1"
    local event="$2"

    log_event "INFO" "Gluetun event detected: $event at $timestamp"

    # Check debounce cooldown
    local current_time
    current_time=$(date +%s)
    local time_since_last=$((current_time - LAST_RESTART_TIME))

    if [ $time_since_last -lt "$DEBOUNCE_COOLDOWN" ]; then
        log_event "INFO" "Ignoring event - within cooldown period (${time_since_last}s < ${DEBOUNCE_COOLDOWN}s)"
        return 0
    fi

    # Get current namespace
    local current_ns
    current_ns=$(get_container_network_namespace "gluetun")

    # Get current start time
    local current_start
    current_start=$(get_container_start_time "gluetun")

    # Check if this is a real restart (namespace or start time changed)
    if [ -n "$PREVIOUS_GLUETUN_NS" ] && [ "$current_ns" = "$PREVIOUS_GLUETUN_NS" ]; then
        log_event "INFO" "Namespace unchanged - not a real restart (may be health status change)"
        return 0
    fi

    log_event "WARN" "Gluetun restart confirmed! Namespace: $PREVIOUS_GLUETUN_NS -> $current_ns"

    # Update tracking variables
    LAST_RESTART_TIME=$current_time
    PREVIOUS_GLUETUN_NS=$current_ns

    # Check rate limiting
    if ! is_restart_allowed; then
        return 1
    fi

    # Execute cascade restart
    execute_cascade_restart
}

execute_cascade_restart() {
    local overall_start
    overall_start=$(date +%s)

    log_event "INFO" "Initiating cascade restart sequence..."

    # Wait for Gluetun to become healthy
    if ! wait_for_gluetun_healthy; then
        send_failure_notification "Gluetun failed to become healthy"
        FAILURE_COUNT=$((FAILURE_COUNT + 1))
        return 1
    fi

    # Execute cascade restart with retry
    local attempt=1
    while [ $attempt -le "$MAX_RETRY_ATTEMPTS" ]; do
        log_event "INFO" "Cascade restart attempt $attempt of $MAX_RETRY_ATTEMPTS"

        if cascade_restart_torrent_stack; then
            local overall_end
            overall_end=$(date +%s)
            local total_duration=$((overall_end - overall_start))

            log_event "INFO" "Cascade restart successful (total: ${total_duration}s)"
            send_success_notification "$total_duration"
            FAILURE_COUNT=0
            return 0
        else
            log_event "ERROR" "Cascade restart attempt $attempt failed"

            if [ $attempt -lt "$MAX_RETRY_ATTEMPTS" ]; then
                local backoff=$((RETRY_BACKOFF_BASE * attempt))
                log_event "INFO" "Retrying in ${backoff}s..."
                sleep "$backoff"
            fi
        fi

        attempt=$((attempt + 1))
    done

    # All attempts failed
    log_event "ERROR" "All cascade restart attempts failed"
    send_failure_notification "All $MAX_RETRY_ATTEMPTS restart attempts failed"
    FAILURE_COUNT=$((FAILURE_COUNT + 1))
    return 1
}

#############################################
# Main Event Loop
#############################################

main_event_loop() {
    log_event "INFO" "Starting Docker events monitoring for Gluetun..."
    log_event "INFO" "Monitoring container: gluetun"
    log_event "INFO" "Debounce cooldown: ${DEBOUNCE_COOLDOWN}s"
    log_event "INFO" "Max restarts per hour: 5"

    # Initialize namespace tracking
    PREVIOUS_GLUETUN_NS=$(get_container_network_namespace "gluetun")
    log_event "INFO" "Initial Gluetun namespace: $PREVIOUS_GLUETUN_NS"

    # Main event loop with auto-reconnect
    while true; do
        log_event "INFO" "Connecting to Docker events stream..."

        docker events \
            --filter "container=gluetun" \
            --filter "event=start" \
            --filter "event=restart" 2>&1 | \
        while read -r event_line; do
            # Parse the event line (format: timestamp action container_name...)
            local timestamp
            timestamp=$(echo "$event_line" | awk '{print $1}')
            local event
            event=$(echo "$event_line" | grep -oE "(start|restart)" || echo "unknown")

            if [ "$event" != "unknown" ]; then
                handle_gluetun_event "$timestamp" "$event"
            fi
        done || {
            log_event "ERROR" "Events stream disconnected. Reconnecting in 10s..."
            sleep 10
        }
    done
}

#############################################
# Startup
#############################################

log_event "INFO" "========================================"
log_event "INFO" "Gluetun Cascade Restart Monitor Starting"
log_event "INFO" "========================================"

# Load configuration
load_configuration

log_event "INFO" "Configuration loaded successfully"

# Start main event loop
main_event_loop
