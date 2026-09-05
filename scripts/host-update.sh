#!/bin/bash
# Manual full-system update: host OS packages, then (after a reboot) the container stacks.
#
# This box does NOT patch itself — see config/host/apt/20auto-upgrades. Patching and
# rebooting are one deliberate action taken by a human who can reach the machine, so
# this script is the manual replacement for unattended-upgrades, not a cron job. It
# deliberately does not self-register anything.
#
# It runs in two phases because a reboot cannot be spanned by a single process:
#
#   Phase 1 (default)   sudo ./scripts/host-update.sh
#       apt-get update, then dist-upgrade. dist-upgrade rather than upgrade because
#       the kernel arrives via the linux-image-amd64 metapackage pulling in a NEW
#       package name, which plain `upgrade` refuses to do — the kernel would silently
#       never install. Reports whether a reboot is required and stops there.
#
#   (you reboot yourself)
#
#   Phase 2             ./scripts/host-update.sh --stacks
#       stack-manage.sh all update, then the summary and health checks.
#
# Why the reboot is yours to run: this is a media server. Nothing here decides on its
# own to drop an in-flight stream, and nothing reboots a box whose owner might be
# somewhere without access to it if it fails to come back up.
#
# Docker packages are upgraded by phase 1 along with everything else. That restarts
# dockerd and bounces containers — which is exactly why it belongs in a supervised
# window and is blacklisted from the unattended policy. The reboot in between means
# containers come up clean regardless, and phase 2 then recreates them on new images.
#
# Modes:
#   (default)      Phase 1: host packages. Does not reboot, does not touch containers.
#   --stacks       Phase 2: containers only. Skips all apt work. Run after the reboot.
#   --all          Both phases in one go, WITHOUT rebooting in between. Only correct
#                  when phase 1 reports no reboot is required; refuses otherwise
#                  unless --force is given.
#
# Other flags:
#   --dry-run      Show what would be upgraded / recreated. Changes nothing.
#   --yes          Non-interactive: skip the confirmation prompt before upgrading.
#   --force        Allow --all to continue even when a reboot is pending.
#
# Usage: sudo ./scripts/host-update.sh [--stacks|--all] [--dry-run] [--yes] [--force]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- Parse arguments ---
PHASE="host"
DRY_RUN=false
ASSUME_YES=false
FORCE=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --stacks)   PHASE="stacks"; shift ;;
        --all)      PHASE="all"; shift ;;
        --dry-run)  DRY_RUN=true; shift ;;
        --yes|-y)   ASSUME_YES=true; shift ;;
        --force)    FORCE=true; shift ;;
        -h|--help)
            # tail -n +2 drops the shebang, which is not part of the help text.
            tail -n +2 "$0" | grep '^#' | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

step() { echo; echo -e "${BLUE}=== $* ===${NC}"; }

# Phase 1 needs root for apt. Phase 2 only needs docker access, and running the
# stack as root would create root-owned files in bind-mounted config dirs.
if [ "$PHASE" != "stacks" ] && [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}Phase 1 needs root for apt. Re-run with sudo.${NC}" >&2
    exit 1
fi

reboot_pending() { [ -f /var/run/reboot-required ]; }

# =====================================================================
# PHASE 1 — host packages
# =====================================================================
run_host_phase() {
    step "Refreshing package index"
    apt-get update

    step "Pending upgrades"
    # `apt list --upgradable` writes a harmless "Listing..." header to stderr and
    # pipes into head, so guard the pipeline against set -o pipefail.
    local pending
    pending=$(apt list --upgradable 2>/dev/null | tail -n +2 || true)

    if [ -z "$pending" ]; then
        echo -e "${GREEN}Nothing to upgrade — host is already current.${NC}"
    else
        echo "$pending"
        echo
        echo -e "${YELLOW}$(echo "$pending" | wc -l) package(s) pending.${NC}"

        # Call out the two classes that have consequences beyond a normal upgrade.
        if echo "$pending" | grep -qE '^linux-image'; then
            echo -e "${YELLOW}  ! Kernel update included — takes effect only after a reboot.${NC}"
        fi
        if echo "$pending" | grep -qE '^(docker-ce|containerd\.io|docker-compose-plugin|docker-buildx-plugin)'; then
            echo -e "${YELLOW}  ! Docker/containerd update included — dockerd restarts, containers bounce.${NC}"
        fi
    fi

    if [ "$DRY_RUN" = true ]; then
        step "Dry run — simulating dist-upgrade"
        apt-get -s dist-upgrade
        echo
        echo -e "${YELLOW}Dry run: nothing was changed.${NC}"
        return 0
    fi

    [ -z "$pending" ] && return 0

    if [ "$ASSUME_YES" != true ]; then
        echo
        read -r -p "Proceed with dist-upgrade? [y/N] " reply
        case "$reply" in
            [yY]|[yY][eE][sS]) ;;
            *) echo "Aborted."; exit 0 ;;
        esac
    fi

    step "Upgrading"
    # dist-upgrade: required for the kernel metapackage (see header).
    # confdef/confold match the unattended policy so a modified conffile never
    # blocks on a prompt or silently overwrites local config.
    DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y \
        -o Dpkg::Options::=--force-confdef \
        -o Dpkg::Options::=--force-confold

    step "Removing orphaned packages"
    DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -y
}

# =====================================================================
# PHASE 2 — container stacks
# =====================================================================
run_stacks_phase() {
    step "Updating container stacks"
    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}Would run: ./stack-manage.sh all update${NC}"
        echo -e "${YELLOW}Dry run: nothing was changed.${NC}"
        return 0
    fi

    # stack-manage.sh is the only supported entry point for container operations.
    ( cd "$REPO_DIR" && ./stack-manage.sh all update )

    step "Stack summary"
    ( cd "$REPO_DIR" && ./stack-manage.sh all summary ) || true

    step "Health"
    ( cd "$REPO_DIR" && ./stack-manage.sh all health ) || true
}

# =====================================================================
# Drive the phases
# =====================================================================
case "$PHASE" in
    host)
        run_host_phase
        echo
        if [ "$DRY_RUN" = true ]; then
            :
        elif reboot_pending; then
            echo -e "${YELLOW}REBOOT REQUIRED.${NC}"
            [ -f /var/run/reboot-required.pkgs ] && \
                echo "  Triggered by: $(sort -u /var/run/reboot-required.pkgs | paste -sd', ' -)"
            echo
            echo "  1. sudo reboot"
            echo "  2. uname -r                              # confirm the new kernel is live"
            echo "  3. ./scripts/host-update.sh --stacks     # then update the containers"
        else
            echo -e "${GREEN}No reboot required.${NC}"
            echo "  Continue with: ./scripts/host-update.sh --stacks"
        fi
        ;;
    stacks)
        run_stacks_phase
        echo
        echo -e "${GREEN}Done.${NC}"
        ;;
    all)
        run_host_phase
        if reboot_pending && [ "$DRY_RUN" != true ]; then
            echo
            if [ "$FORCE" != true ]; then
                echo -e "${RED}A reboot is now pending — stopping before the stack update.${NC}"
                echo "The new kernel is not running yet, so recreating containers now means"
                echo "doing it again after the reboot. Reboot first, then:"
                echo "  ./scripts/host-update.sh --stacks"
                echo "(Override with --force if you really want to continue unrebooted.)"
                exit 0
            fi
            echo -e "${YELLOW}Reboot pending, but --force given — continuing.${NC}"
        fi
        run_stacks_phase
        echo
        if reboot_pending && [ "$DRY_RUN" != true ]; then
            echo -e "${YELLOW}Still pending: sudo reboot${NC}"
        else
            echo -e "${GREEN}Done.${NC}"
        fi
        ;;
esac
