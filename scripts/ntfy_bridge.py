#!/usr/bin/env python3
"""
ntfy-bridge - Receives Alertmanager webhook POSTs and forwards them to ntfy.

Runs inside a bare python:3-alpine container from a read-only mount, so it uses
only the standard library (http.server + urllib).
"""

from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import logging
import os
import urllib.request

HOST = "0.0.0.0"
PORT = 8183
NTFY_TOPIC = os.environ.get("LOGGING_NTFY_TOPIC", "")
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
    alerts = payload.get("alerts")
    if not isinstance(alerts, list):
        return []
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


def send_to_ntfy(message, topic=NTFY_TOPIC, base_url=NTFY_BASE_URL):
    """POST a single message dict to ntfy. No-ops if topic is empty.

    Network failures are logged and swallowed so the alert queue never wedges.
    """
    if not topic:
        logging.warning("No ntfy topic configured; dropping alert: %s", message.get("title"))
        return
    url = f"{base_url.rstrip('/')}/{topic}"
    req = urllib.request.Request(
        url,
        data=message["body"].encode("utf-8"),
        method="POST",
        headers={
            "Title": message["title"],
            "Priority": str(message["priority"]),
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=10):
            logging.info("Sent ntfy alert: %s", message["title"])
    except Exception as e:  # noqa: BLE001 - deliberately swallow all
        logging.error("Failed to send ntfy alert %s: %s", message.get("title"), e)


def handle_alert_body(raw_body):
    """Parse raw Alertmanager POST bytes and dispatch ntfy messages.

    Always returns (200, ...) on parseable-or-not input so Alertmanager's queue
    is never blocked; errors are logged.
    """
    if not raw_body:
        return 200, b'{"status": "empty"}'
    try:
        payload = json.loads(raw_body.decode("utf-8"))
    except (json.JSONDecodeError, UnicodeDecodeError) as e:
        logging.error("Invalid alert JSON: %s", e)
        return 200, b'{"status": "ignored-invalid-json"}'
    for message in format_messages(payload):
        send_to_ntfy(message)
    return 200, b'{"status": "ok"}'


class AlertHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        logging.info("%s - %s", self.address_string(), fmt % args)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) if length else b""
        status, body = handle_alert_body(raw)
        self.send_response(status)
        self.send_header("Content-type", "application/json")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/health":
            self.send_response(200)
            self.send_header("Content-type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"status": "healthy"}')
        else:
            self.send_response(200)
            self.send_header("Content-type", "text/plain")
            self.end_headers()
            self.wfile.write(b"ntfy-bridge - POST Alertmanager webhooks to /")


def run():
    server = HTTPServer((HOST, PORT), AlertHandler)
    logging.info("Starting ntfy-bridge on %s:%s (topic=%s)", HOST, PORT, NTFY_TOPIC or "<unset>")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        logging.info("Shutting down ntfy-bridge")
        server.shutdown()


if __name__ == "__main__":
    run()
