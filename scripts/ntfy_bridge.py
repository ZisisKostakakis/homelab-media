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


def format_messages(payload):
    """Turn an Alertmanager webhook payload into a list of ntfy message dicts.

    Each dict has keys: title, body, priority. Malformed input yields [].
    """
    if not isinstance(payload, dict):
        return []
    alerts = payload.get("alerts") or []
    messages = []
    for alert in alerts:
        labels = alert.get("labels", {}) if isinstance(alert, dict) else {}
        annotations = alert.get("annotations", {}) if isinstance(alert, dict) else {}
        container = labels.get("container_name", "unknown")
        alertname = labels.get("alertname", "alert")
        status = alert.get("status", "firing")
        priority = severity_to_priority(labels.get("severity"))
        prefix = "RESOLVED" if status == "resolved" else "FIRING"
        title = f"[{prefix}] {alertname} - {container}"
        body_parts = [
            annotations.get("summary", ""),
            annotations.get("description", ""),
        ]
        body = "\n".join(p for p in body_parts if p) or "(no details)"
        messages.append({"title": title, "body": body, "priority": priority})
    return messages
