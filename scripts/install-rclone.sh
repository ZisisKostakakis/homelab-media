#!/bin/bash
# Install rclone
# Idempotent installer for rclone using the official static binary.
# Safe to re-run — skips install if the requested version (or newer) is present.
# Required by the S3 disaster-recovery backup scripts (backup-to-s3.sh, restore-from-s3.sh).

set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}=== Install rclone ===${NC}"

if command -v rclone >/dev/null 2>&1; then
    CURRENT_VERSION=$(rclone version 2>/dev/null | head -1)
    echo -e "${YELLOW}rclone already installed: ${CURRENT_VERSION}${NC}"
    echo -e "${YELLOW}To upgrade, run: sudo rclone selfupdate${NC}"
    exit 0
fi

echo "rclone not found — installing via official installer..."

if ! command -v curl >/dev/null 2>&1; then
    echo -e "${RED}Error: curl is required but not installed.${NC}" >&2
    exit 1
fi

# Official install script — verifies checksum of the downloaded static binary
if [ "$(id -u)" -eq 0 ]; then
    curl -fsSL https://rclone.org/install.sh | bash
else
    curl -fsSL https://rclone.org/install.sh | sudo bash
fi

echo ""
echo -e "${GREEN}rclone installed:${NC}"
rclone version | head -1

echo ""
echo -e "${YELLOW}Next: configure the S3 remotes (s3-dr + s3-dr-crypt) with 'rclone config'.${NC}"
echo -e "${YELLOW}See the Disaster Recovery section of README.md for the exact walkthrough.${NC}"
