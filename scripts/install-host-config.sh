#!/bin/bash
# Install host-level configuration (host OS patching + Docker daemon).
#
# Everything else in this repo configures *containers*. These two files configure
# the *host underneath them*, so they live outside docker-compose and outside
# /var/lib/homelab-media-configs. Without this script they would exist only on the
# live box and a rebuilt VM would silently come back without them — which is why
# config/host/ is the source of truth and this script deploys it.
#
# What it installs:
#
#   apt/52homelab-unattended-upgrades -> /etc/apt/apt.conf.d/
#       Security-only automatic patching via Debian's unattended-upgrades.
#       Docker packages and kernels are blacklisted (upgrading Docker restarts the
#       daemon and bounces every container; a kernel does nothing until a reboot).
#       Never auto-reboots.
#
#   apt/20auto-upgrades -> /etc/apt/apt.conf.d/
#       Arms the apt-daily / apt-daily-upgrade systemd timers that actually run it.
#
#   docker/daemon.json -> /etc/docker/
#       live-restore: containers keep running across a Docker DAEMON restart, so
#       upgrading docker-ce does not drop the media stack. Plus json-file log
#       rotation (10m x 3) — note this only applies to containers created AFTER
#       the daemon picks it up, not to already-running ones.
#
# Reporting is handled separately by scripts/cron-jobs/os-update-check.sh, which
# self-registers its own cron entry (run it with --install).
#
# Safe to re-run: files are overwritten with the repo's copy and the daemon is
# reloaded only if its config actually changed.
#
# Usage: sudo ./scripts/install-host-config.sh [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SRC="${REPO_DIR}/config/host"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

DRY_RUN=false
[ "${1:-}" = "--dry-run" ] && DRY_RUN=true
[ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] && { grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}Must run as root (writes to /etc).${NC}" >&2
    exit 1
fi

# install_file SRC DEST -> echoes "changed" if the destination differs
install_file() {
    local src="$1" dest="$2"
    if [ -f "$dest" ] && cmp -s "$src" "$dest"; then
        echo -e "  ${GREEN}=${NC} ${dest} (already current)"
        return 1
    fi
    if [ "$DRY_RUN" = true ]; then
        echo -e "  ${YELLOW}~${NC} ${dest} (would install)"
        return 1
    fi
    install -D -m 0644 "$src" "$dest"
    echo -e "  ${GREEN}+${NC} ${dest} (installed)"
    return 0
}

echo "=== Host config ==="

# --- apt / unattended-upgrades ---
# The policy is inert unless the package is present; install it rather than
# assuming a fresh VM has it. apt-config-auto-update is what creates
# /var/run/reboot-required, which os-update-check.sh reports on.
if ! dpkg -s unattended-upgrades >/dev/null 2>&1; then
    if [ "$DRY_RUN" = true ]; then
        echo -e "  ${YELLOW}~${NC} would install: unattended-upgrades apt-config-auto-update"
    else
        echo "  Installing unattended-upgrades..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
            unattended-upgrades apt-config-auto-update >/dev/null
        echo -e "  ${GREEN}+${NC} unattended-upgrades installed"
    fi
fi

install_file "${SRC}/apt/52homelab-unattended-upgrades" /etc/apt/apt.conf.d/52homelab-unattended-upgrades || true
install_file "${SRC}/apt/20auto-upgrades"               /etc/apt/apt.conf.d/20auto-upgrades || true

# --- Docker daemon ---
DOCKER_CHANGED=false
install_file "${SRC}/docker/daemon.json" /etc/docker/daemon.json && DOCKER_CHANGED=true

if [ "$DOCKER_CHANGED" = true ]; then
    # A malformed daemon.json prevents dockerd from starting. Validate BEFORE
    # signalling the daemon, so a typo can never take the whole stack down.
    if ! python3 -m json.tool /etc/docker/daemon.json >/dev/null 2>&1; then
        echo -e "${RED}daemon.json is not valid JSON — not touching the daemon.${NC}" >&2
        exit 1
    fi
    # reload (SIGHUP), never restart: restarting dockerd would bounce containers,
    # which is the exact outcome live-restore exists to prevent.
    echo "  Reloading dockerd (SIGHUP — containers keep running)..."
    systemctl reload docker
fi

if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}Dry run — nothing was changed.${NC}"
    exit 0
fi

echo
echo "=== Verify ==="
echo "  Live restore    : $(docker info --format '{{.LiveRestoreEnabled}}' 2>/dev/null || echo 'unknown')"
echo "  Auto-reboot     : $(apt-config dump 2>/dev/null | grep -oP 'Unattended-Upgrade::Automatic-Reboot "\K[^"]+' || echo 'unset')"
echo "  Security origins:"
apt-config dump 2>/dev/null | grep -oP 'Origins-Pattern:: "\K[^"]+' | sed 's/^/    /'
echo
echo -e "${GREEN}Done.${NC} Dry-run the patch policy with: unattended-upgrade --dry-run"
echo "Register the daily patch-state check with: scripts/cron-jobs/os-update-check.sh --install"
