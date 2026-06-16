#!/usr/bin/env python3
"""
ntfy-bridge - Receives Alertmanager webhook POSTs and forwards them to ntfy.

Runs inside a bare python:3-alpine container from a read-only mount, so it uses
only the standard library (http.server + urllib). Mirrors the design of
scripts/wud-webhook-server.py.
"""

from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import logging
import os
import urllib.request

HOST = "0.0.0.0"
PORT = 8183
# ntfy topic: prefer a dedicated logging topic, fall back to the shared WUD topic
NTFY_TOPIC = os.environ.get("LOGGING_NTFY_TOPIC") or os.environ.get("WUD_NTFY_TOPIC", "")
NTFY_BASE_URL = os.environ.get("NTFY_BASE_URL", "https://ntfy.sh")

logging.basicConfig(
    level=logging.INFO,
    format="[%(asctime)s] %(levelname)s: %(message)s",
)

# Alertmanager severity label -> ntfy priority (1=min .. 5=max)
_PRIORITY_MAP = {"critical": 5, "warning": 3, "info": 2}


def severity_to_priority(severity):
    """Map an Alertmanager severity label to an ntfy priority. Defaults to 3."""
    if not severity:
        return 3
    return _PRIORITY_MAP.get(str(severity).lower(), 3)
