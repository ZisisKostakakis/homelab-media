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

QBITTORRENT_URL = os.getenv("QBITTORRENT_URL", "http://localhost:8080")
QBITTORRENT_USERNAME = os.getenv("QBITTORRENT_USERNAME", "admin")
QBITTORRENT_PASSWORD = os.getenv("QBITTORRENT_PASSWORD", "")
LOG_FILE = os.getenv("PLEX_QBIT_LOG", "/config/logs/plex-qbit-manager.log")
SESSIONS_FILE = os.getenv("PLEX_QBIT_SESSIONS", "/config/logs/plex-qbit-sessions.count")

logger = logging.getLogger(__name__)


def setup_logging() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
        handlers=[logging.FileHandler(LOG_FILE), logging.StreamHandler(sys.stdout)],
    )


def parse_count(raw: str) -> int:
    """Parse the stored stream count; empty or corrupt content counts as 0."""
    try:
        return max(0, int(raw.strip()))
    except ValueError:
        return 0


def next_session_count(count: int, action: str) -> tuple[int, str | None]:
    """Return the new active-stream count and the qBittorrent action to take.

    Torrents are paused on the first stream and resumed only when the last
    stream ends; in between the count changes but nothing is sent.
    """
    if action == "pause":
        count += 1
        return count, "pause" if count == 1 else None
    count = max(0, count - 1)
    return count, "resume" if count == 0 else None


def qbit_session() -> requests.Session:
    session = requests.Session()
    session.headers.update({"Referer": QBITTORRENT_URL})
    resp = session.post(
        f"{QBITTORRENT_URL}/api/v2/auth/login",
        data={"username": QBITTORRENT_USERNAME, "password": QBITTORRENT_PASSWORD},
        timeout=10,
    )
    # qBittorrent 4.x returns 200 with body "Ok."; 5.x returns 204 No Content.
    # Bad credentials return 401/403 or body "Fails."
    if resp.status_code not in (200, 204) or resp.text.strip() == "Fails.":
        raise RuntimeError(f"qBittorrent login failed: {resp.status_code} {resp.text}")
    return session


def post_first_ok(session: requests.Session, endpoints: tuple[str, ...]) -> str:
    """POST hashes=all to each endpoint in turn; return the first that succeeds.

    qBittorrent 4.x uses pause/resume, 5.x renamed them to stop/start and
    returns 404 for the old names, so try both.
    """
    statuses = []
    for endpoint in endpoints:
        r = session.post(
            f"{QBITTORRENT_URL}/api/v2/torrents/{endpoint}", data={"hashes": "all"}, timeout=10
        )
        if r.ok:
            return endpoint
        statuses.append(f"{endpoint}={r.status_code}")
    raise RuntimeError(f"qBittorrent rejected all endpoints: {', '.join(statuses)}")


def pause_all(session: requests.Session) -> None:
    post_first_ok(session, ("pause", "stop"))
    logger.info("Paused all torrents (Plex playback started)")


def resume_all(session: requests.Session) -> None:
    post_first_ok(session, ("resume", "start"))
    logger.info("Resumed all torrents (Plex playback stopped)")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--action", choices=["pause", "resume"], required=True)
    args = parser.parse_args()
    setup_logging()

    try:
        with open(SESSIONS_FILE, "a+") as f:
            fcntl.flock(f, fcntl.LOCK_EX)
            f.seek(0)
            count, todo = next_session_count(parse_count(f.read()), args.action)
            f.seek(0)
            f.truncate()
            f.write(str(count))
            logger.info(f"Active streams: {count}")

            if todo == "pause":
                pause_all(qbit_session())
            elif todo == "resume":
                resume_all(qbit_session())
            elif args.action == "pause":
                logger.info(f"Torrents already paused ({count} active streams)")
            else:
                logger.info(f"Keeping torrents paused ({count} active streams remaining)")

    except Exception as e:
        logger.error(f"Failed to {args.action} torrents: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
