#!/usr/bin/env python3
"""
Cross-Seed Filter Sync Script

Synchronizes cross-seed's blockList with Radarr/Sonarr to prevent searching
for torrents of deleted media while keeping them seeding in qBittorrent.

Author: Generated for homelab-media stack
Date: 2025-12-15
"""

import os
import requests
import re
import logging
import sys
from typing import Set, Dict, List
from datetime import datetime
from dotenv import load_dotenv

load_dotenv()

# Configuration
RADARR_URL = "http://localhost:7878"
RADARR_API_KEY = os.environ["RADARR_API_KEY"]

SONARR_URL = "http://localhost:8989"
SONARR_API_KEY = os.environ["SONARR_API_KEY"]

QBITTORRENT_URL = "http://localhost:8080"
QBITTORRENT_USERNAME = "admin"
QBITTORRENT_PASSWORD = os.environ["QBITTORRENT_PASSWORD"]

CROSS_SEED_CONFIG_PATH = "/var/lib/homelab-media-configs/cross-seed/config.js"
CROSS_SEED_CONTAINER_NAME = "cross-seed"

# Logging setup
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler('/var/log/cross-seed-filter.log'),
        logging.StreamHandler(sys.stdout)
    ]
)
logger = logging.getLogger(__name__)


class APIError(Exception):
    """Custom exception for API errors"""
    pass


def get_radarr_managed_hashes() -> Set[str]:
    """
    Get info hashes of all torrents for movies currently in Radarr.

    Returns:
        Set of lowercase info hashes for active movies
    """
    try:
        # Get all movies
        movies_response = requests.get(
            f"{RADARR_URL}/api/v3/movie",
            headers={"X-Api-Key": RADARR_API_KEY},
            timeout=30
        )
        movies_response.raise_for_status()
        movies = movies_response.json()
        logger.info(f"Found {len(movies)} movies in Radarr")

        # Get download history to find info hashes
        history_response = requests.get(
            f"{RADARR_URL}/api/v3/history",
            params={"pageSize": 10000, "sortKey": "date", "sortDirection": "descending"},
            headers={"X-Api-Key": RADARR_API_KEY},
            timeout=30
        )
        history_response.raise_for_status()
        history_data = history_response.json()

        # Extract info hashes from history records
        managed_hashes = set()
        for record in history_data.get("records", []):
            # Look for download events with downloadId (info hash)
            if record.get("eventType") in ["grabbed", "downloadFolderImported", "downloadImported"]:
                download_id = record.get("downloadId", "").lower()
                if download_id and len(download_id) == 40:  # SHA-1 hash length
                    managed_hashes.add(download_id)

        logger.info(f"Found {len(managed_hashes)} Radarr torrent hashes")
        return managed_hashes

    except requests.exceptions.RequestException as e:
        logger.error(f"Error querying Radarr API: {e}")
        raise APIError(f"Radarr API error: {e}")


def get_sonarr_managed_hashes() -> Set[str]:
    """
    Get info hashes of all torrents for series currently in Sonarr.

    Returns:
        Set of lowercase info hashes for active series
    """
    try:
        # Get all series
        series_response = requests.get(
            f"{SONARR_URL}/api/v3/series",
            headers={"X-Api-Key": SONARR_API_KEY},
            timeout=30
        )
        series_response.raise_for_status()
        series = series_response.json()
        logger.info(f"Found {len(series)} series in Sonarr")

        # Get download history
        history_response = requests.get(
            f"{SONARR_URL}/api/v3/history",
            params={"pageSize": 10000, "sortKey": "date", "sortDirection": "descending"},
            headers={"X-Api-Key": SONARR_API_KEY},
            timeout=30
        )
        history_response.raise_for_status()
        history_data = history_response.json()

        # Extract info hashes
        managed_hashes = set()
        for record in history_data.get("records", []):
            if record.get("eventType") in ["grabbed", "downloadFolderImported", "downloadImported"]:
                download_id = record.get("downloadId", "").lower()
                if download_id and len(download_id) == 40:
                    managed_hashes.add(download_id)

        logger.info(f"Found {len(managed_hashes)} Sonarr torrent hashes")
        return managed_hashes

    except requests.exceptions.RequestException as e:
        logger.error(f"Error querying Sonarr API: {e}")
        raise APIError(f"Sonarr API error: {e}")


def get_qbittorrent_torrents() -> Dict[str, Dict]:
    """
    Get all torrents from qBittorrent.

    Returns:
        Dictionary mapping info hash to torrent metadata
    """
    try:
        # Login to qBittorrent
        session = requests.Session()
        login_response = session.post(
            f"{QBITTORRENT_URL}/api/v2/auth/login",
            data={"username": QBITTORRENT_USERNAME, "password": QBITTORRENT_PASSWORD},
            timeout=10
        )

        if login_response.text != "Ok.":
            raise APIError("qBittorrent login failed")

        # Get all torrents
        torrents_response = session.get(
            f"{QBITTORRENT_URL}/api/v2/torrents/info",
            timeout=30
        )
        torrents_response.raise_for_status()
        torrents = torrents_response.json()

        # Build dictionary
        torrent_dict = {}
        for torrent in torrents:
            torrent_dict[torrent["hash"].lower()] = {
                "name": torrent["name"],
                "category": torrent.get("category", ""),
                "state": torrent.get("state", ""),
                "ratio": torrent.get("ratio", 0)
            }

        logger.info(f"Found {len(torrent_dict)} torrents in qBittorrent")
        return torrent_dict

    except requests.exceptions.RequestException as e:
        logger.error(f"Error querying qBittorrent API: {e}")
        raise APIError(f"qBittorrent API error: {e}")


def calculate_blocklist(all_torrents: Dict[str, Dict], managed_hashes: Set[str]) -> List[str]:
    """
    Calculate which torrents should be blocked from cross-seed searches.

    Args:
        all_torrents: All torrents from qBittorrent
        managed_hashes: Combined set of Radarr + Sonarr managed hashes

    Returns:
        List of info hashes to block (formatted as "infoHash:...")
    """
    blocklist = []

    for hash, metadata in all_torrents.items():
        # Skip cross-seed's own injected torrents
        if metadata["category"] == "cross-seed-link":
            continue

        # Block if not managed by Radarr or Sonarr
        if hash not in managed_hashes:
            blocklist.append(f"infoHash:{hash}")
            logger.debug(f"Blocking: {metadata['name'][:60]} (category: {metadata['category']})")

    logger.info(f"Calculated {len(blocklist)} torrents to block")
    return blocklist


def update_config_js(blocklist: List[str]) -> bool:
    """
    Update cross-seed config.js with new blockList.

    Args:
        blocklist: List of info hash strings to block

    Returns:
        True if successful, False otherwise
    """
    try:
        # Read current config
        with open(CROSS_SEED_CONFIG_PATH, 'r') as f:
            config_content = f.read()

        # Format blocklist as JavaScript array
        if blocklist:
            blocklist_str = "[\n        " + ",\n        ".join(f'"{item}"' for item in blocklist) + "\n    ]"
        else:
            blocklist_str = "[]"

        # Replace blockList array using regex
        # Match: blockList: [...],
        pattern = r'blockList:\s*\[[^\]]*\]'
        replacement = f'blockList: {blocklist_str}'

        new_content = re.sub(pattern, replacement, config_content, count=1)

        if new_content == config_content:
            logger.warning("blockList pattern not found in config.js - config may not be updated")
            return False

        # Write back
        with open(CROSS_SEED_CONFIG_PATH, 'w') as f:
            f.write(new_content)

        logger.info(f"Updated config.js with {len(blocklist)} blocked hashes")
        return True

    except Exception as e:
        logger.error(f"Error updating config.js: {e}")
        return False


def restart_cross_seed() -> bool:
    """
    Restart the cross-seed Docker container to apply config changes.

    Returns:
        True if successful, False otherwise
    """
    try:
        import subprocess
        result = subprocess.run(
            ["docker", "restart", CROSS_SEED_CONTAINER_NAME],
            capture_output=True,
            text=True,
            timeout=30
        )

        if result.returncode == 0:
            logger.info(f"Successfully restarted {CROSS_SEED_CONTAINER_NAME}")
            return True
        else:
            logger.error(f"Failed to restart container: {result.stderr}")
            return False

    except Exception as e:
        logger.error(f"Error restarting cross-seed: {e}")
        return False


def main():
    """Main execution function"""
    logger.info("=" * 60)
    logger.info("Cross-Seed Filter Sync - Starting")
    logger.info("=" * 60)

    try:
        # Step 1: Get managed torrents from Radarr and Sonarr
        logger.info("Step 1: Querying Radarr and Sonarr...")
        radarr_hashes = get_radarr_managed_hashes()
        sonarr_hashes = get_sonarr_managed_hashes()
        managed_hashes = radarr_hashes | sonarr_hashes
        logger.info(f"Total managed hashes: {len(managed_hashes)}")

        # Step 2: Get all torrents from qBittorrent
        logger.info("Step 2: Querying qBittorrent...")
        all_torrents = get_qbittorrent_torrents()

        # Step 3: Calculate blocklist
        logger.info("Step 3: Calculating blocklist...")
        blocklist = calculate_blocklist(all_torrents, managed_hashes)

        # Step 4: Update config.js
        logger.info("Step 4: Updating cross-seed config...")
        if update_config_js(blocklist):
            logger.info("Config updated successfully")
        else:
            logger.error("Failed to update config")
            sys.exit(1)

        # Step 5: Restart cross-seed
        logger.info("Step 5: Restarting cross-seed container...")
        if restart_cross_seed():
            logger.info("Cross-seed restarted successfully")
        else:
            logger.error("Failed to restart cross-seed")
            sys.exit(1)

        # Summary
        logger.info("=" * 60)
        logger.info("Sync completed successfully!")
        logger.info(f"  - Radarr movies: {len(radarr_hashes)} hashes")
        logger.info(f"  - Sonarr series: {len(sonarr_hashes)} hashes")
        logger.info(f"  - Total qBittorrent torrents: {len(all_torrents)}")
        logger.info(f"  - Torrents blocked: {len(blocklist)}")
        logger.info(f"  - Torrents searchable: {len(all_torrents) - len(blocklist)}")
        logger.info("=" * 60)

    except Exception as e:
        logger.error(f"Fatal error: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
