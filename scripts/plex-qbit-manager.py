#!/usr/bin/env python3
"""
Tautulli notification script: pause/resume qBittorrent on Plex playback events.

Usage (called by Tautulli):
  python3 plex-qbit-manager.py --action pause    # on Playback Start / Resume
  python3 plex-qbit-manager.py --action resume   # on Playback Stop / Pause

Tracks active session count so torrents stay paused while any stream is active.
"""

import argparse
import fcntl
import logging
import os
import sys
import requests

QBITTORRENT_URL      = os.getenv("QBITTORRENT_URL", "http://localhost:8080")
QBITTORRENT_USERNAME = os.getenv("QBITTORRENT_USERNAME", "admin")
QBITTORRENT_PASSWORD = os.getenv("QBITTORRENT_PASSWORD", "")
LOG_FILE             = os.getenv("PLEX_QBIT_LOG", "/config/logs/plex-qbit-manager.log")
SESSIONS_FILE        = os.getenv("PLEX_QBIT_SESSIONS", "/config/logs/plex-qbit-sessions.count")

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    handlers=[logging.FileHandler(LOG_FILE), logging.StreamHandler(sys.stdout)],
)
logger = logging.getLogger(__name__)


def qbit_session() -> requests.Session:
    session = requests.Session()
    resp = session.post(
        f"{QBITTORRENT_URL}/api/v2/auth/login",
        data={"username": QBITTORRENT_USERNAME, "password": QBITTORRENT_PASSWORD},
        timeout=10,
    )
    if resp.text != "Ok.":
        raise RuntimeError(f"qBittorrent login failed: {resp.text}")
    return session


def pause_all(session: requests.Session) -> None:
    # /pause works on qBittorrent 4.x; /stop on 5.x — try both, ignore 404
    for endpoint in ("pause", "stop"):
        r = session.post(f"{QBITTORRENT_URL}/api/v2/torrents/{endpoint}",
                         data={"hashes": "all"}, timeout=10)
        if r.ok:
            break
    logger.info("Paused all torrents (Plex playback started)")


def resume_all(session: requests.Session) -> None:
    for endpoint in ("resume", "start"):
        r = session.post(f"{QBITTORRENT_URL}/api/v2/torrents/{endpoint}",
                         data={"hashes": "all"}, timeout=10)
        if r.ok:
            break
    logger.info("Resumed all torrents (Plex playback stopped)")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--action", choices=["pause", "resume"], required=True)
    args = parser.parse_args()

    try:
        with open(SESSIONS_FILE, "a+") as f:
            fcntl.flock(f, fcntl.LOCK_EX)
            f.seek(0)
            data = f.read().strip()
            count = int(data) if data else 0

            if args.action == "pause":
                count += 1
                f.seek(0); f.truncate(); f.write(str(count))
                logger.info(f"Active streams: {count}")
                if count == 1:
                    pause_all(qbit_session())
                else:
                    logger.info(f"Torrents already paused ({count} active streams)")
            else:
                count = max(0, count - 1)
                f.seek(0); f.truncate(); f.write(str(count))
                logger.info(f"Active streams: {count}")
                if count == 0:
                    resume_all(qbit_session())
                else:
                    logger.info(f"Keeping torrents paused ({count} active streams remaining)")

    except Exception as e:
        logger.error(f"Failed to {args.action} torrents: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
