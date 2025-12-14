#!/usr/bin/env python3
"""
WUD Webhook Server - Receives HTTP webhooks from What's Up Docker
Listens for POST requests containing container update information
and triggers the update handler script
"""

from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import subprocess
import logging
import os
from datetime import datetime

# Configuration
HOST = '0.0.0.0'
PORT = 8182
LOG_DIR = '/var/lib/homelab-media-configs/wud-updates'
LOG_FILE = os.path.join(LOG_DIR, 'webhook-server.log')
HANDLER_SCRIPT = '/scripts/wud-update-handler.sh'

# Create log directory
os.makedirs(LOG_DIR, exist_ok=True)

# Setup logging
logging.basicConfig(
    level=logging.INFO,
    format='[%(asctime)s] %(levelname)s: %(message)s',
    handlers=[
        logging.FileHandler(LOG_FILE),
        logging.StreamHandler()
    ]
)

class WebhookHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        """Override to use our logging instead of stderr"""
        logging.info(f"{self.address_string()} - {format % args}")

    def do_POST(self):
        """Handle POST requests from WUD"""
        try:
            # Read request body
            content_length = int(self.headers.get('Content-Length', 0))
            body = self.rfile.read(content_length).decode('utf-8')

            logging.info(f"Received webhook: {body}")

            # Parse JSON
            try:
                data = json.loads(body)
            except json.JSONDecodeError as e:
                logging.error(f"Invalid JSON: {e}")
                self.send_response(400)
                self.end_headers()
                self.wfile.write(b'{"error": "Invalid JSON"}')
                return

            # Extract container information - handle various WUD webhook formats
            container = data.get('name') or data.get('container') or data.get('displayName')

            # Handle image field (can be string or object)
            image_field = data.get('image', {})
            if isinstance(image_field, dict):
                image = image_field.get('name') or image_field.get('registry', {}).get('name')
            else:
                image = image_field

            # Handle tag/result field
            result = data.get('result', {})
            if isinstance(result, dict):
                result_tag = result.get('tag')
            else:
                result_tag = data.get('tag')

            if not container:
                logging.error(f"No container name in webhook data: {data}")
                self.send_response(400)
                self.end_headers()
                self.wfile.write(b'{"error": "Missing container name"}')
                return

            # Remove container prefix if present (e.g., "homelab-services-overseerr" -> "overseerr")
            # or project prefix "homelab-torrent-" etc
            container_clean = container
            for prefix in ['homelab-services-', 'homelab-torrent-', 'homelab-plex-']:
                if container_clean.startswith(prefix):
                    container_clean = container_clean[len(prefix):]
                    break

            logging.info(f"Processing update for: {container_clean} (original: {container})")

            # Trigger update handler script
            try:
                # Prepare JSON for the handler script
                handler_input = json.dumps({
                    'container': container_clean,
                    'image': image or 'unknown',
                    'tag': result_tag or 'unknown'
                })

                # Run the handler script
                result = subprocess.run(
                    [HANDLER_SCRIPT],
                    input=handler_input.encode('utf-8'),
                    capture_output=True,
                    timeout=300  # 5 minute timeout
                )

                if result.returncode == 0:
                    logging.info(f"Successfully triggered update for {container_clean}")
                    self.send_response(200)
                    self.end_headers()
                    self.wfile.write(b'{"status": "success"}')
                else:
                    logging.error(f"Update handler failed: {result.stderr.decode()}")
                    self.send_response(500)
                    self.end_headers()
                    self.wfile.write(b'{"error": "Update handler failed"}')

            except subprocess.TimeoutExpired:
                logging.error(f"Update handler timed out for {container_clean}")
                self.send_response(500)
                self.end_headers()
                self.wfile.write(b'{"error": "Update handler timed out"}')

            except Exception as e:
                logging.error(f"Failed to execute update handler: {e}")
                self.send_response(500)
                self.end_headers()
                self.wfile.write(b'{"error": "Failed to execute update handler"}')

        except Exception as e:
            logging.error(f"Error handling webhook: {e}")
            self.send_response(500)
            self.end_headers()
            self.wfile.write(b'{"error": "Internal server error"}')

    def do_GET(self):
        """Handle GET requests - health check"""
        if self.path == '/health':
            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(b'{"status": "healthy"}')
        else:
            self.send_response(200)
            self.send_header('Content-type', 'text/plain')
            self.end_headers()
            self.wfile.write(b'WUD Webhook Server - Use POST to trigger updates')


def run_server():
    """Start the webhook server"""
    server = HTTPServer((HOST, PORT), WebhookHandler)
    logging.info(f"Starting WUD webhook server on {HOST}:{PORT}")
    logging.info(f"Logs: {LOG_FILE}")
    logging.info(f"Handler script: {HANDLER_SCRIPT}")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        logging.info("Shutting down webhook server")
        server.shutdown()


if __name__ == '__main__':
    run_server()
