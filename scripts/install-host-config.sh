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
#       The patch POLICY: security-only, Docker packages and kernels blacklisted,
#       never auto-reboot. Nothing applies it on a timer any more, but it still
#       governs a manual `unattended-upgrade` run — see below.
#
#   apt/20auto-upgrades -> /etc/apt/apt.conf.d/
#       Sets Unattended-Upgrade "0" — automatic patching is OFF.
#
#   docker/daemon.json -> /etc/docker/
#       live-restore: containers keep running across a Docker DAEMON restart, so
#       upgrading docker-ce does not drop the media stack. Plus json-file log
#       rotation (10m x 3) — note this only applies to containers created AFTER
#       the daemon picks it up, not to already-running ones.
#
# AUTOMATIC HOST PATCHING IS DISABLED — a standing operator decision, not a
# temporary measure. Patching this host and rebooting it are one action, and that
# action needs a human who can reach the machine if it does not come back. Kernel
# and Docker updates only take effect on a reboot, and the operator is periodically
# away for weeks with no access to the box. An unattended upgrade landing during one
# of those stretches is a change nobody can verify, on a host nobody can recover,
# for the length of the absence. Deferring to a hands-on window trades a patch delay
# for the ability to fix what breaks.
#
# Enforced in two places, because 20auto-upgrades alone is not sufficient:
#   * Unattended-Upgrade "0" in apt/20auto-upgrades stops apt.systemd.daily.
#   * This script masks apt-daily-upgrade.timer, the unit that actually installs.
# Masking rather than disabling is deliberate: the unit ships in
# /usr/lib/systemd/system/, so an apt upgrade of the systemd/apt packages can
# silently re-enable a merely-disabled timer. The mask symlink to /dev/null survives.
#
# Consequence: Debian security updates are NOT applied to this host automatically.
# Patch manually, when you can reach the machine:
#     sudo unattended-upgrade --dry-run    # preview under the 52homelab policy
#     sudo apt-get update && sudo apt-get upgrade
#     sudo reboot                          # if /var/run/reboot-required exists
#
# apt-daily.timer is intentionally left running — it only refreshes the index and
# downloads, installing nothing, and keeps os-update-check.sh's report accurate.
# That ntfy nudge is now the only thing telling you patches are pending.
#
# To re-enable: set Unattended-Upgrade "1" in config/host/apt/20auto-upgrades, then
#     sudo systemctl unmask --now apt-daily-upgrade.timer
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

# --- Disable automatic patching (see header) ---
# 20auto-upgrades already sets Unattended-Upgrade "0", but apt.systemd.daily is not
# the only thing that can trigger an install run. Masking the timer is the belt to
# that braces, and unlike `disable` it cannot be undone by a package upgrade.
# apt-daily.timer is deliberately NOT touched — index refresh only, installs nothing.
if [ "$(systemctl is-enabled apt-daily-upgrade.timer 2>/dev/null)" = "masked" ]; then
    echo -e "  ${GREEN}=${NC} apt-daily-upgrade.timer (already masked)"
elif [ "$DRY_RUN" = true ]; then
    echo -e "  ${YELLOW}~${NC} apt-daily-upgrade.timer (would stop + mask)"
else
    systemctl stop apt-daily-upgrade.timer 2>/dev/null || true
    systemctl mask apt-daily-upgrade.timer >/dev/null 2>&1
    echo -e "  ${GREEN}+${NC} apt-daily-upgrade.timer (stopped + masked)"
fi

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
echo "  Auto-patching   : $(apt-config dump 2>/dev/null | grep -oP 'APT::Periodic::Unattended-Upgrade "\K[^"]+' || echo 'unset') (0 = off)"
echo "  Upgrade timer   : $(systemctl is-enabled apt-daily-upgrade.timer 2>/dev/null || echo 'unknown')"
echo "  Index timer     : $(systemctl is-enabled apt-daily.timer 2>/dev/null || echo 'unknown') (refresh only, installs nothing)"
echo "  Auto-reboot     : $(apt-config dump 2>/dev/null | grep -oP 'Unattended-Upgrade::Automatic-Reboot "\K[^"]+' || echo 'unset')"
echo
echo -e "${YELLOW}Automatic security patching is OFF — this host does not patch itself.${NC}"
echo "  Patch manually : sudo apt-get update && sudo apt-get upgrade"
echo "  Preview policy : sudo unattended-upgrade --dry-run"
echo "  Re-enable      : set Unattended-Upgrade \"1\" in config/host/apt/20auto-upgrades,"
echo "                   then sudo systemctl unmask --now apt-daily-upgrade.timer"
echo
echo -e "${GREEN}Done.${NC} Pending updates are still reported by scripts/cron-jobs/os-update-check.sh"
echo "Register that daily check with: scripts/cron-jobs/os-update-check.sh --install"
