#!/bin/bash
# Cron Job: report host OS patch state (does NOT install anything)
#
# Package installation is handled by Debian's own unattended-upgrades, not by
# this script. unattended-upgrades applies security updates silently and has no
# way to tell you anything — so this job is the reporting half of that pair:
#
#   * Reboot required?  unattended-upgrades / update-notifier-common drop
#                       /var/run/reboot-required when a patched package (kernel,
#                       libc, systemd, ...) can only take effect after a restart.
#                       Nothing reboots this box automatically — a media server
#                       mid-stream should never vanish — so the reboot decision
#                       stays yours. This is the nudge that tells you one is due.
#
#   * Held-back packages?  The Docker packages (docker-ce, containerd.io, ...) are
#                       blacklisted in unattended-upgrades, because upgrading them
#                       restarts the Docker daemon and bounces every container.
#                       That must happen in a window you chose, not at 06:10 on a
#                       Tuesday. This job tells you when Docker updates are waiting
#                       so you can apply them deliberately.
#
# Notifies via ntfy only when there is something to act on, so a healthy box stays
# silent and the alert keeps its meaning.
#
# Modes:
#   (default)      Check now and notify if action is needed.
#   --install      Self-register this job's daily cron entry, then exit.
#                  Re-running is safe — the entry is replaced, not duplicated.
#                  Only ever touches lines tagged with its unique CRON_TAG.
#
# Other flags:
#   --notify-always  Send the ntfy ping even when nothing needs doing. Useful to
#                    prove the notification path works end to end.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# --- CONFIGURABLE (cron self-registration) ---
CRON_SCHEDULE="0 9 * * *"        # Daily 09:00 — a waking hour, so a reboot nudge gets seen
CRON_TIMEZONE="Europe/London"    # Anchors the schedule to UK local time (BST/GMT)
LOG_FILE="/var/log/homelab/os-update-check.log"
# ---------------------------------------------

# Unique tag used as the deduplication key for this job's cron entry
CRON_TAG="# homelab:os-update-check"

# Packages deliberately held back from unattended-upgrades. Keep in sync with
# Unattended-Upgrade::Package-Blacklist in config/host/apt/52homelab-unattended-upgrades
# (kernel packages excluded here — those are covered by the reboot-required check instead).
HELD_PACKAGES=(
    docker-ce
    docker-ce-cli
    docker-ce-rootless-extras
    docker-compose-plugin
    docker-buildx-plugin
    docker-model-plugin
    containerd.io
)

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# --- Read specific settings from .env (non-fatal if absent) ---
# .env is a docker-compose env_file (literal KEY=VALUE, values may contain
# unquoted spaces). It is NOT valid shell, so we must never `source` it. Pull
# only the keys we need, first match wins, strip inline quotes.
env_get() {
    local key="$1" file="${REPO_DIR}/.env"
    [ -f "$file" ] || return 0
    local line
    line=$(grep -E "^${key}=" "$file" | head -1) || return 0
    line="${line#*=}"
    line="${line%\"}"; line="${line#\"}"
    line="${line%\'}"; line="${line#\'}"
    printf '%s' "$line"
}

# --- Settings (real env wins, then .env, then default) ---
NTFY_URL="${NTFY_URL:-https://ntfy.sh}"
NTFY_TOPIC="${MAINTENANCE_NTFY_TOPIC:-$(env_get MAINTENANCE_NTFY_TOPIC)}"   # empty = notifications off
# Fall back to the backup topic if a dedicated maintenance topic isn't set.
[ -z "$NTFY_TOPIC" ] && NTFY_TOPIC="${BACKUP_NTFY_TOPIC:-$(env_get BACKUP_NTFY_TOPIC)}"

# --- Parse arguments ---
MODE="run"
NOTIFY_ALWAYS=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --install)        MODE="install"; shift ;;
        --notify-always)  NOTIFY_ALWAYS=true; shift ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

# --- ntfy notification helper ---
notify() {
    local title="$1" priority="$2" tags="$3" message="$4"
    [ -z "$NTFY_TOPIC" ] && return 0
    curl -sS \
        -H "Title: ${title}" \
        -H "Priority: ${priority}" \
        -H "Tags: ${tags}" \
        -d "${message}" \
        "${NTFY_URL}/${NTFY_TOPIC}" >/dev/null 2>&1 || true
}

# =====================================================================
# INSTALL MODE — self-register cron entry (mirrors docker-maintenance.sh)
# =====================================================================
if [ "$MODE" = "install" ]; then
    mkdir -p "$(dirname "$LOG_FILE")"

    entry="${CRON_SCHEDULE} cd ${REPO_DIR} && bash scripts/cron-jobs/$(basename "$0") >> ${LOG_FILE} 2>&1 ${CRON_TAG}"

    # Rebuild the crontab without this job's previous entry, then append the
    # current one. Keyed on CRON_TAG so other homelab jobs are never touched.
    existing=$(crontab -l 2>/dev/null || true)
    updated=$(printf '%s\n' "$existing" | grep -vF "$CRON_TAG" || true)

    # Preserve the CRON_TZ header if the crontab already has one; add if not.
    if ! printf '%s\n' "$updated" | grep -q "^CRON_TZ="; then
        updated=$(printf 'CRON_TZ=%s\n%s\n' "$CRON_TIMEZONE" "$updated")
    fi

    printf '%s\n%s\n' "$updated" "$entry" | grep -v '^$' | crontab -

    echo -e "${GREEN}✓ Installed cron entry:${NC}"
    echo "  ${entry}"
    exit 0
fi

# =====================================================================
# RUN MODE
# =====================================================================
echo "=== OS update check: $(date '+%Y-%m-%d %H:%M:%S %Z') ==="

REBOOT_REQUIRED=false
REBOOT_PKGS=""
if [ -f /var/run/reboot-required ]; then
    REBOOT_REQUIRED=true
    # update-notifier-common records which packages asked for the reboot.
    [ -f /var/run/reboot-required.pkgs ] && REBOOT_PKGS=$(sort -u /var/run/reboot-required.pkgs | paste -sd', ' -)
fi

# Which of the deliberately-held packages have an upgrade waiting?
# `apt list --upgradable` needs a fresh index; apt-daily.timer already refreshes
# it, so read the cached state rather than hammering the mirrors from cron.
HELD_WAITING=""
upgradable=$(apt list --upgradable 2>/dev/null | grep -v '^Listing' || true)
for pkg in "${HELD_PACKAGES[@]}"; do
    if printf '%s\n' "$upgradable" | grep -q "^${pkg}/"; then
        HELD_WAITING="${HELD_WAITING}${HELD_WAITING:+, }${pkg}"
    fi
done

TOTAL_UPGRADABLE=$(printf '%s\n' "$upgradable" | grep -c . || true)

echo "  Reboot required : ${REBOOT_REQUIRED}${REBOOT_PKGS:+ (${REBOOT_PKGS})}"
echo "  Docker updates  : ${HELD_WAITING:-none}"
echo "  Upgradable total: ${TOTAL_UPGRADABLE}"

# --- Build the notification, only if there is something to act on ---
lines=""
priority="default"
tags="package"

if [ "$REBOOT_REQUIRED" = true ]; then
    lines="${lines}Reboot required to finish applying security updates."
    [ -n "$REBOOT_PKGS" ] && lines="${lines}
Packages: ${REBOOT_PKGS}"
    lines="${lines}

Containers restart themselves on boot (restart: unless-stopped), and the
gluetun-routed stack cannot start before the VPN, so a reboot is safe to do
whenever streaming is quiet.
"
    priority="high"
    tags="warning,package"
fi

if [ -n "$HELD_WAITING" ]; then
    lines="${lines}${lines:+
}Docker updates held back: ${HELD_WAITING}

These are excluded from automatic patching because upgrading them restarts the
Docker daemon. live-restore keeps containers running across that restart, but
apply them deliberately:
  sudo apt-get install --only-upgrade ${HELD_WAITING//, / }
"
fi

if [ -z "$lines" ]; then
    echo -e "${GREEN}✓ Nothing to act on — no reboot pending, no held-back updates.${NC}"
    if [ "$NOTIFY_ALWAYS" = true ]; then
        notify "Homelab OS: all clear" "low" "white_check_mark" \
            "No reboot pending. No held-back Docker updates. ${TOTAL_UPGRADABLE} non-security package(s) upgradable."
    fi
    exit 0
fi

echo -e "${YELLOW}! Action needed — sending ntfy notification.${NC}"
notify "Homelab OS: action needed" "$priority" "$tags" "$lines"
