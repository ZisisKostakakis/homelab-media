# Logging Stack (Loki + Promtail + Grafana) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a fifth Docker Compose stack that centralizes all container logs via Promtail → Loki, exposes them in Grafana, and fires ntfy alerts on error spikes through Alertmanager.

**Architecture:** A standalone `docker-compose-logging.yml` runs loki, promtail, grafana, alertmanager, and a stdlib-only `ntfy-bridge` container on the existing external `homelab_media_network`. Promtail discovers containers via the Docker socket (read-only) and pushes to Loki (90-day filesystem retention). Loki's ruler evaluates LogQL error-rate rules and routes alerts through Alertmanager → ntfy-bridge → ntfy. Config lives in the repo under `config/logging/` (mounted `:ro`); state lives under `/var/lib/homelab-media-configs/`.

**Tech Stack:** Docker Compose, Grafana Loki (monolithic mode), Promtail, Grafana, Prometheus Alertmanager, Python 3 stdlib (`http.server`, `urllib`), pytest for tests.

---

## Reference Facts (verified against codebase)

- External network: `homelab_media_network` (declared `external: true` in every compose file).
- Config state convention: host bind mounts under `/var/lib/homelab-media-configs/<service>`.
- Env conventions in compose: `${TZ}`, `${PUID}`, `${PGID}`; ntfy topic var is `${WUD_NTFY_TOPIC}`.
- `stack-manage.sh`: `manage_stack` is generic on `docker-compose-${stack}.yml` + project `homelab-${stack}`. To add a stack you edit three spots: the `case $STACK in services|torrent|plex|music)` allowlist (line ~249), the `for s in services torrent plex music` loop (line ~243), and `show_usage` (line ~49).
- Nightly cron (`scripts/cron-jobs/update-all-stacks.sh`) runs `stack-manage.sh all update`. Adding `logging` to the `all` loop automatically includes it in cron — NO cron file edit needed.
- `scripts/healthcheck.sh` scans all `docker-compose-*.yml`, so the new stack is covered automatically once the file exists.
- No `tests/` dir exists and pytest is not yet a dependency — Task 1 adds it.
- `ntfy-bridge.py` must be stdlib-only (`http.server` + `urllib.request`), mirroring `scripts/wud-webhook-server.py`, because it runs inside a bare `python:3-alpine` container from a read-only mount with no pip install step.

---

## Task 1: Add pytest dev dependency and test scaffold

**Files:**
- Modify: `pyproject.toml`
- Create: `tests/__init__.py` (empty)
- Create: `tests/conftest.py`

- [ ] **Step 1: Add pytest as a dev dependency**

Run:
```bash
uv add --dev pytest
```
Expected: `pyproject.toml` gains a `[dependency-groups]` / `dev` entry with `pytest`, `uv.lock` updated.

- [ ] **Step 2: Create the tests package**

Create empty file `tests/__init__.py`:
```python
```

Create `tests/conftest.py` so `scripts/` is importable in tests:
```python
import sys
from pathlib import Path

# Make scripts/ importable as top-level modules in tests
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))
```

- [ ] **Step 3: Verify pytest runs (no tests yet)**

Run: `uv run pytest -q`
Expected: exits 0 with "no tests ran" (or collected 0 items). Non-zero only if pytest itself is broken.

- [ ] **Step 4: Commit**

```bash
git add pyproject.toml uv.lock tests/__init__.py tests/conftest.py
git commit -m "test: add pytest dev dependency and tests scaffold"
```

---

## Task 2: ntfy-bridge — health endpoint (TDD)

The bridge is an HTTP server. Build it endpoint-by-endpoint. `ntfy-bridge.py` is
designed so the request-handling logic is importable and testable without binding
a socket: parsing + formatting live in pure functions, and the handler is tested
via those functions plus a lightweight fake.

**Files:**
- Create: `scripts/ntfy-bridge.py`
- Create: `tests/test_ntfy_bridge.py`

- [ ] **Step 1: Write the failing test for severity→priority mapping**

Create `tests/test_ntfy_bridge.py`:
```python
import ntfy_bridge


def test_severity_to_priority_critical():
    assert ntfy_bridge.severity_to_priority("critical") == 5


def test_severity_to_priority_warning():
    assert ntfy_bridge.severity_to_priority("warning") == 3


def test_severity_to_priority_unknown_defaults_to_default():
    assert ntfy_bridge.severity_to_priority("bogus") == 3


def test_severity_to_priority_missing_defaults_to_default():
    assert ntfy_bridge.severity_to_priority(None) == 3
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/test_ntfy_bridge.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'ntfy_bridge'`.

- [ ] **Step 3: Create ntfy-bridge.py with the mapping and importable module name**

Note: the file is `scripts/ntfy-bridge.py` but Python import names cannot contain
`-`. The container runs it by path (`python3 /scripts/ntfy-bridge.py`), so the
hyphen is fine at runtime. For tests, `conftest.py` puts `scripts/` on the path;
import via the underscore alias created here. Create the file with an underscore
symlink-free approach: name the module file `ntfy_bridge.py` and have the runtime
entrypoint import it.

Create `scripts/ntfy_bridge.py` (underscore — the importable module):
```python
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/test_ntfy_bridge.py -v`
Expected: 4 passed.

- [ ] **Step 5: Commit**

```bash
git add scripts/ntfy_bridge.py tests/test_ntfy_bridge.py
git commit -m "feat(logging): add ntfy-bridge severity mapping"
```

---

## Task 3: ntfy-bridge — format Alertmanager payload (TDD)

**Files:**
- Modify: `scripts/ntfy_bridge.py`
- Modify: `tests/test_ntfy_bridge.py`

- [ ] **Step 1: Write the failing test for payload formatting**

Append to `tests/test_ntfy_bridge.py`:
```python
def _sample_alert(status="firing", severity="warning", container="sonarr"):
    return {
        "status": status,
        "alerts": [
            {
                "status": status,
                "labels": {
                    "alertname": "HighErrorRate",
                    "severity": severity,
                    "container_name": container,
                },
                "annotations": {
                    "summary": "High error rate",
                    "description": f"{container} is erroring",
                },
            }
        ],
    }


def test_format_messages_produces_one_message_per_alert():
    msgs = ntfy_bridge.format_messages(_sample_alert())
    assert len(msgs) == 1


def test_format_message_title_includes_container_and_alertname():
    msg = ntfy_bridge.format_messages(_sample_alert(container="radarr"))[0]
    assert "radarr" in msg["title"]
    assert "HighErrorRate" in msg["title"]


def test_format_message_priority_from_severity():
    msg = ntfy_bridge.format_messages(_sample_alert(severity="critical"))[0]
    assert msg["priority"] == 5


def test_format_message_body_includes_description():
    msg = ntfy_bridge.format_messages(_sample_alert(container="bazarr"))[0]
    assert "bazarr is erroring" in msg["body"]


def test_format_messages_empty_when_no_alerts():
    assert ntfy_bridge.format_messages({"alerts": []}) == []


def test_format_messages_handles_missing_alerts_key():
    assert ntfy_bridge.format_messages({}) == []
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/test_ntfy_bridge.py -v`
Expected: FAIL — `AttributeError: module 'ntfy_bridge' has no attribute 'format_messages'`.

- [ ] **Step 3: Implement format_messages**

Add to `scripts/ntfy_bridge.py` (after `severity_to_priority`):
```python
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/test_ntfy_bridge.py -v`
Expected: all tests pass (10 total).

- [ ] **Step 5: Commit**

```bash
git add scripts/ntfy_bridge.py tests/test_ntfy_bridge.py
git commit -m "feat(logging): format Alertmanager payloads for ntfy"
```

---

## Task 4: ntfy-bridge — send to ntfy (TDD, mocked network)

**Files:**
- Modify: `scripts/ntfy_bridge.py`
- Modify: `tests/test_ntfy_bridge.py`

- [ ] **Step 1: Write the failing test for send_to_ntfy**

Append to `tests/test_ntfy_bridge.py`:
```python
from unittest import mock


def test_send_to_ntfy_posts_to_topic_url():
    msg = {"title": "T", "body": "B", "priority": 4}
    with mock.patch.object(ntfy_bridge.urllib.request, "urlopen") as m:
        m.return_value.__enter__ = lambda s: s
        m.return_value.__exit__ = lambda *a: False
        ntfy_bridge.send_to_ntfy(msg, topic="mytopic", base_url="https://ntfy.sh")
    req = m.call_args[0][0]
    assert req.full_url == "https://ntfy.sh/mytopic"
    assert req.data == b"B"
    assert req.get_header("Title") == "T"
    assert req.get_header("Priority") == "4"


def test_send_to_ntfy_no_topic_is_noop():
    msg = {"title": "T", "body": "B", "priority": 3}
    with mock.patch.object(ntfy_bridge.urllib.request, "urlopen") as m:
        ntfy_bridge.send_to_ntfy(msg, topic="", base_url="https://ntfy.sh")
    m.assert_not_called()


def test_send_to_ntfy_swallows_network_errors():
    msg = {"title": "T", "body": "B", "priority": 3}
    with mock.patch.object(
        ntfy_bridge.urllib.request, "urlopen", side_effect=OSError("boom")
    ):
        # Must not raise
        ntfy_bridge.send_to_ntfy(msg, topic="t", base_url="https://ntfy.sh")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/test_ntfy_bridge.py -v`
Expected: FAIL — `AttributeError: module 'ntfy_bridge' has no attribute 'send_to_ntfy'`.

- [ ] **Step 3: Implement send_to_ntfy**

Add to `scripts/ntfy_bridge.py`:
```python
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest tests/test_ntfy_bridge.py -v`
Expected: all pass (13 total).

- [ ] **Step 5: Commit**

```bash
git add scripts/ntfy_bridge.py tests/test_ntfy_bridge.py
git commit -m "feat(logging): send bridge messages to ntfy"
```

---

## Task 5: ntfy-bridge — HTTP server (handler + entrypoint)

**Files:**
- Modify: `scripts/ntfy_bridge.py`
- Modify: `tests/test_ntfy_bridge.py`
- Create: `scripts/ntfy-bridge.py` (thin runtime entrypoint)

- [ ] **Step 1: Write the failing test for handle_alert_body**

`handle_alert_body` is a pure function taking raw request bytes and returning
`(status_code, response_bytes)`, calling `send_to_ntfy` for each message. This
lets us test the request path without a socket.

Append to `tests/test_ntfy_bridge.py`:
```python
def test_handle_alert_body_valid_returns_200_and_sends():
    body = json.dumps(_sample_alert()).encode("utf-8")
    with mock.patch.object(ntfy_bridge, "send_to_ntfy") as send:
        status, _ = ntfy_bridge.handle_alert_body(body)
    assert status == 200
    assert send.call_count == 1


def test_handle_alert_body_malformed_json_returns_200_and_no_send():
    with mock.patch.object(ntfy_bridge, "send_to_ntfy") as send:
        status, _ = ntfy_bridge.handle_alert_body(b"not json")
    # Return 200 so Alertmanager does not wedge its queue
    assert status == 200
    send.assert_not_called()


def test_handle_alert_body_empty_returns_200():
    with mock.patch.object(ntfy_bridge, "send_to_ntfy") as send:
        status, _ = ntfy_bridge.handle_alert_body(b"")
    assert status == 200
    send.assert_not_called()
```

Need `import json` at top of the test file — add it if not present.

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest tests/test_ntfy_bridge.py -v`
Expected: FAIL — no attribute `handle_alert_body`.

- [ ] **Step 3: Implement handle_alert_body + HTTP server + run()**

Add to `scripts/ntfy_bridge.py`:
```python
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
```

- [ ] **Step 4: Create the hyphenated runtime entrypoint**

The compose command will invoke `python3 /scripts/ntfy-bridge.py`. Create
`scripts/ntfy-bridge.py` as a thin shim that imports and runs the module:
```python
#!/usr/bin/env python3
"""Runtime entrypoint. Imports the testable ntfy_bridge module and runs it."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ntfy_bridge  # noqa: E402

if __name__ == "__main__":
    ntfy_bridge.run()
```

- [ ] **Step 5: Run full test file to verify pass**

Run: `uv run pytest tests/test_ntfy_bridge.py -v`
Expected: all pass (16 total).

- [ ] **Step 6: Commit**

```bash
git add scripts/ntfy_bridge.py scripts/ntfy-bridge.py tests/test_ntfy_bridge.py
git commit -m "feat(logging): add ntfy-bridge HTTP server and entrypoint"
```

---

## Task 6: Loki configuration

**Files:**
- Create: `config/logging/loki-config.yml`
- Create: `config/logging/loki-rules/homelab/alerts.yml`

- [ ] **Step 1: Write the Loki config (monolithic, filesystem, 90d retention, ruler)**

Create `config/logging/loki-config.yml`:
```yaml
auth_enabled: false

server:
  http_listen_port: 3100
  log_level: info

common:
  instance_addr: 127.0.0.1
  path_prefix: /loki
  storage:
    filesystem:
      chunks_directory: /loki/chunks
      rules_directory: /loki/rules
  replication_factor: 1
  ring:
    kvstore:
      store: inmemory

schema_config:
  configs:
    - from: 2020-10-24
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h

limits_config:
  retention_period: 2160h  # 90 days
  reject_old_samples: true
  reject_old_samples_max_age: 168h

compactor:
  working_directory: /loki/compactor
  retention_enabled: true
  delete_request_store: filesystem

ruler:
  storage:
    type: local
    local:
      directory: /loki/rules
  rule_path: /loki/rules-tmp
  alertmanager_url: http://alertmanager:9093
  enable_api: true
  enable_alertmanager_v2: true

analytics:
  reporting_enabled: false
```

- [ ] **Step 2: Write the alert rules**

Loki's local ruler expects rules under `<rules_directory>/<tenant>/`. With
`auth_enabled: false` the tenant is `fake`. The rules file is bind-mounted into
`/loki/rules/fake/`. Create `config/logging/loki-rules/homelab/alerts.yml`:
```yaml
groups:
  - name: homelab-container-errors
    rules:
      - alert: HighErrorRate
        expr: |
          sum by (container_name) (
            rate({job="docker"} |~ "(?i)\\b(error|fatal|panic)\\b" [5m])
          ) > 0.2
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "High error rate in {{ $labels.container_name }}"
          description: "{{ $labels.container_name }} is logging errors at {{ printf \"%.2f\" $value }}/s over 5m."

      # ContainerLogSilence: enable after observing baseline log behavior.
      # - alert: ContainerLogSilence
      #   expr: |
      #     sum by (container_name) (count_over_time({job="docker"}[15m])) == 0
      #   for: 15m
      #   labels:
      #     severity: warning
      #   annotations:
      #     summary: "{{ $labels.container_name }} has stopped logging"
      #     description: "No log lines from {{ $labels.container_name }} for 15m."
```

- [ ] **Step 3: Validate YAML parses**

Run: `uv run python -c "import yaml,sys; [yaml.safe_load(open(f)) for f in ['config/logging/loki-config.yml','config/logging/loki-rules/homelab/alerts.yml']]; print('ok')"`
Expected: `ok`. (If PyYAML missing, run `uv run --with pyyaml python -c ...` instead.)

- [ ] **Step 4: Commit**

```bash
git add config/logging/loki-config.yml config/logging/loki-rules/homelab/alerts.yml
git commit -m "feat(logging): add Loki config with 90d retention and error-rate rules"
```

---

## Task 7: Promtail configuration

**Files:**
- Create: `config/logging/promtail-config.yml`

- [ ] **Step 1: Write the Promtail config (Docker SD + relabeling)**

Create `config/logging/promtail-config.yml`:
```yaml
server:
  http_listen_port: 9080
  log_level: info

positions:
  filename: /promtail/positions.yaml

clients:
  - url: http://loki:3100/loki/api/v1/push

scrape_configs:
  - job_name: docker
    docker_sd_configs:
      - host: unix:///var/run/docker.sock
        refresh_interval: 15s
    relabel_configs:
      # container name (strip leading slash Docker adds)
      - source_labels: ['__meta_docker_container_name']
        regex: '/(.*)'
        target_label: 'container_name'
      # compose project (e.g. homelab-torrent)
      - source_labels: ['__meta_docker_container_label_com_docker_compose_project']
        target_label: 'project'
      # compose service name
      - source_labels: ['__meta_docker_container_label_com_docker_compose_service']
        target_label: 'service'
      # static job label used by alert rules
      - target_label: 'job'
        replacement: 'docker'
```

- [ ] **Step 2: Validate YAML parses**

Run: `uv run --with pyyaml python -c "import yaml; yaml.safe_load(open('config/logging/promtail-config.yml')); print('ok')"`
Expected: `ok`.

- [ ] **Step 3: Commit**

```bash
git add config/logging/promtail-config.yml
git commit -m "feat(logging): add Promtail Docker service-discovery config"
```

---

## Task 8: Alertmanager configuration

**Files:**
- Create: `config/logging/alertmanager.yml`

- [ ] **Step 1: Write the Alertmanager config (route → ntfy-bridge webhook)**

ntfy-bridge listens on port 8183 (from Task 2). Alertmanager posts to its root.
Create `config/logging/alertmanager.yml`:
```yaml
route:
  receiver: ntfy-bridge
  group_by: ['container_name']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h

receivers:
  - name: ntfy-bridge
    webhook_configs:
      - url: http://ntfy-bridge:8183/
        send_resolved: true
```

- [ ] **Step 2: Validate YAML parses**

Run: `uv run --with pyyaml python -c "import yaml; yaml.safe_load(open('config/logging/alertmanager.yml')); print('ok')"`
Expected: `ok`.

- [ ] **Step 3: Commit**

```bash
git add config/logging/alertmanager.yml
git commit -m "feat(logging): add Alertmanager route to ntfy-bridge"
```

---

## Task 9: Grafana provisioning

**Files:**
- Create: `config/logging/grafana/provisioning/datasources/loki.yml`
- Create: `config/logging/grafana/provisioning/dashboards/dashboards.yml`
- Create: `config/logging/grafana/dashboards/container-logs.json`

- [ ] **Step 1: Write the datasource provisioning**

Create `config/logging/grafana/provisioning/datasources/loki.yml`:
```yaml
apiVersion: 1

datasources:
  - name: Loki
    type: loki
    access: proxy
    url: http://loki:3100
    isDefault: true
    editable: false
```

- [ ] **Step 2: Write the dashboard provider config**

Create `config/logging/grafana/provisioning/dashboards/dashboards.yml`:
```yaml
apiVersion: 1

providers:
  - name: homelab
    orgId: 1
    folder: Homelab
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    options:
      path: /var/lib/grafana/dashboards
```

- [ ] **Step 3: Write the starter dashboard**

Create `config/logging/grafana/dashboards/container-logs.json`:
```json
{
  "annotations": { "list": [] },
  "editable": true,
  "panels": [
    {
      "type": "timeseries",
      "title": "Log volume per container",
      "datasource": { "type": "loki", "uid": "loki" },
      "gridPos": { "h": 9, "w": 24, "x": 0, "y": 0 },
      "targets": [
        {
          "expr": "sum by (container_name) (rate({job=\"docker\"}[5m]))",
          "refId": "A"
        }
      ]
    },
    {
      "type": "timeseries",
      "title": "Error-line rate per container",
      "datasource": { "type": "loki", "uid": "loki" },
      "gridPos": { "h": 9, "w": 24, "x": 0, "y": 9 },
      "targets": [
        {
          "expr": "sum by (container_name) (rate({job=\"docker\"} |~ \"(?i)\\\\b(error|fatal|panic)\\\\b\" [5m]))",
          "refId": "A"
        }
      ]
    },
    {
      "type": "logs",
      "title": "Live tail (all containers)",
      "datasource": { "type": "loki", "uid": "loki" },
      "gridPos": { "h": 12, "w": 24, "x": 0, "y": 18 },
      "targets": [
        { "expr": "{job=\"docker\"}", "refId": "A" }
      ]
    }
  ],
  "schemaVersion": 39,
  "title": "Homelab Container Logs",
  "uid": "homelab-container-logs",
  "version": 1
}
```

Note: the Loki datasource `uid` defaults to a generated value; the panels
reference `"uid": "loki"`. To make this stable, add `uid: loki` to the datasource
provisioning. Update `config/logging/grafana/provisioning/datasources/loki.yml`
to add `uid: loki` under the datasource entry.

- [ ] **Step 4: Add the stable uid to the datasource**

Edit `config/logging/grafana/provisioning/datasources/loki.yml` — add `uid: loki`:
```yaml
apiVersion: 1

datasources:
  - name: Loki
    type: loki
    uid: loki
    access: proxy
    url: http://loki:3100
    isDefault: true
    editable: false
```

- [ ] **Step 5: Validate JSON + YAML parse**

Run:
```bash
uv run python -c "import json; json.load(open('config/logging/grafana/dashboards/container-logs.json')); print('json ok')"
uv run --with pyyaml python -c "import yaml; yaml.safe_load(open('config/logging/grafana/provisioning/datasources/loki.yml')); yaml.safe_load(open('config/logging/grafana/provisioning/dashboards/dashboards.yml')); print('yaml ok')"
```
Expected: `json ok` then `yaml ok`.

- [ ] **Step 6: Commit**

```bash
git add config/logging/grafana
git commit -m "feat(logging): add Grafana datasource, dashboard provider, and dashboard"
```

---

## Task 10: docker-compose-logging.yml

**Files:**
- Create: `docker-compose-logging.yml`

- [ ] **Step 1: Write the compose file**

Create `docker-compose-logging.yml`:
```yaml
# Logging Stack
# Centralized log collection and alerting.
# Promtail (Docker SD) -> Loki (90d filesystem retention) -> Grafana (UI)
# Loki ruler -> Alertmanager -> ntfy-bridge -> ntfy

services:
  loki:
    image: grafana/loki:latest
    container_name: loki
    restart: unless-stopped
    command: -config.file=/etc/loki/loki-config.yml
    ports:
      - 3100:3100
    volumes:
      - ./config/logging/loki-config.yml:/etc/loki/loki-config.yml:ro
      - ./config/logging/loki-rules/homelab:/loki/rules/fake:ro
      - /var/lib/homelab-media-configs/loki:/loki
    environment:
      - TZ=${TZ}
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:3100/ready"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s
    networks:
      - media_network

  promtail:
    image: grafana/promtail:latest
    container_name: promtail
    restart: unless-stopped
    command: -config.file=/etc/promtail/promtail-config.yml
    volumes:
      - ./config/logging/promtail-config.yml:/etc/promtail/promtail-config.yml:ro
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - /var/lib/homelab-media-configs/promtail:/promtail
    environment:
      - TZ=${TZ}
    depends_on:
      - loki
    networks:
      - media_network

  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    restart: unless-stopped
    ports:
      - 3001:3000
    volumes:
      - ./config/logging/grafana/provisioning:/etc/grafana/provisioning:ro
      - ./config/logging/grafana/dashboards:/var/lib/grafana/dashboards:ro
      - /var/lib/homelab-media-configs/grafana:/var/lib/grafana
    environment:
      - TZ=${TZ}
      - GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD}
      - GF_USERS_ALLOW_SIGN_UP=false
    healthcheck:
      test: ["CMD-SHELL", "wget --no-verbose --tries=1 --spider http://localhost:3000/api/health || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s
    depends_on:
      - loki
    networks:
      - media_network

  alertmanager:
    image: prom/alertmanager:latest
    container_name: alertmanager
    restart: unless-stopped
    command: --config.file=/etc/alertmanager/alertmanager.yml
    ports:
      - 9093:9093
    volumes:
      - ./config/logging/alertmanager.yml:/etc/alertmanager/alertmanager.yml:ro
      - /var/lib/homelab-media-configs/alertmanager:/alertmanager
    environment:
      - TZ=${TZ}
    healthcheck:
      test: ["CMD-SHELL", "wget --no-verbose --tries=1 --spider http://localhost:9093/-/healthy || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s
    networks:
      - media_network

  ntfy-bridge:
    image: python:3-alpine
    container_name: ntfy-bridge
    restart: unless-stopped
    command: python3 /scripts/ntfy-bridge.py
    volumes:
      - ./scripts:/scripts:ro
    environment:
      - TZ=${TZ}
      - LOGGING_NTFY_TOPIC=${LOGGING_NTFY_TOPIC:-${WUD_NTFY_TOPIC}}
      - WUD_NTFY_TOPIC=${WUD_NTFY_TOPIC}
    healthcheck:
      test: ["CMD-SHELL", "wget --no-verbose --tries=1 --spider http://localhost:8183/health || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 15s
    networks:
      - media_network

networks:
  media_network:
    name: homelab_media_network
    external: true
```

- [ ] **Step 2: Validate compose file parses**

Run: `docker compose -f docker-compose-logging.yml config >/dev/null && echo "compose ok"`
Expected: `compose ok`. (Requires a `.env` with `TZ`, `GRAFANA_ADMIN_PASSWORD`, `WUD_NTFY_TOPIC` present; if validating without them, prefix with those vars inline, e.g. `TZ=UTC GRAFANA_ADMIN_PASSWORD=x WUD_NTFY_TOPIC=t docker compose -f docker-compose-logging.yml config >/dev/null`.)

- [ ] **Step 3: Commit**

```bash
git add docker-compose-logging.yml
git commit -m "feat(logging): add logging stack compose file"
```

---

## Task 11: Wire into stack-manage.sh

**Files:**
- Modify: `stack-manage.sh` (three locations)

- [ ] **Step 1: Add `logging` to show_usage stack list**

In `stack-manage.sh`, find (around line 49):
```
    echo "  music     - Music stack (Navidrome, AudioMuse)"
```
Add immediately after it:
```
    echo "  logging   - Centralized logs (Loki, Promtail, Grafana, Alertmanager)"
```

- [ ] **Step 2: Add `logging` to the `all` loop**

Find (around line 243):
```
    for s in services torrent plex music; do
```
Replace with:
```
    for s in services torrent plex music logging; do
```

- [ ] **Step 3: Add `logging` to the STACK case allowlist**

Find (around line 249):
```
        services|torrent|plex|music)
```
Replace with:
```
        services|torrent|plex|music|logging)
```

- [ ] **Step 4: Verify the script still parses and recognizes the stack**

Run: `bash -n stack-manage.sh && echo "syntax ok"`
Expected: `syntax ok`.

Run: `bash stack-manage.sh logging 2>&1 | head -3` (no action → prints usage, which now lists `logging`). Alternatively confirm usage contains it:
`bash stack-manage.sh 2>&1 | grep -q "logging" && echo "usage lists logging"`
Expected: `usage lists logging`.

- [ ] **Step 5: Commit**

```bash
git add stack-manage.sh
git commit -m "feat(logging): register logging stack in stack-manage.sh"
```

---

## Task 12: Environment variable documentation

**Files:**
- Modify: `.env.example`

- [ ] **Step 1: Append logging-stack variables**

`.env.example` is permission-restricted from direct read in some sessions; append
via the editor. Add a documented section (place near the WUD/ntfy section if one
exists, else at end):
```bash
# --- Logging Stack (Loki + Grafana + Alertmanager) ---
# Grafana admin password (username is 'admin'). Reach Grafana at :3001 over Tailscale.
GRAFANA_ADMIN_PASSWORD=changeme
# ntfy topic for log-based alerts. If unset, falls back to WUD_NTFY_TOPIC.
LOGGING_NTFY_TOPIC=
```

- [ ] **Step 2: Verify the lines are present**

Run: `grep -q GRAFANA_ADMIN_PASSWORD .env.example && grep -q LOGGING_NTFY_TOPIC .env.example && echo "env vars documented"`
Expected: `env vars documented`. (If `.env.example` read is blocked, the grep still works since it only reports match/no-match.)

- [ ] **Step 3: Commit**

```bash
git add .env.example
git commit -m "docs(logging): document Grafana and ntfy env vars"
```

---

## Task 13: README + ARCHITECTURE documentation

**Files:**
- Modify: `README.md`
- Modify: `ARCHITECTURE.md`

- [ ] **Step 1: Add a Logging Stack section to README**

In `README.md`, add a new stack subsection under "Stack Breakdown" (after the Music Stack table). Insert:
```markdown
### Logging Stack (`docker-compose-logging.yml`)

Centralized log collection, exploration, and error alerting. Promtail discovers
every container via the Docker socket and ships logs to Loki (90-day filesystem
retention). Grafana provides the query UI and dashboards. Loki's ruler evaluates
error-rate rules and routes alerts through Alertmanager to ntfy.

| Service | Image | Port | Role |
|---------|-------|------|------|
| **Loki** | `grafana/loki` | 3100 | Log store + alert ruler |
| **Promtail** | `grafana/promtail` | — | Docker service-discovery log collector |
| **Grafana** | `grafana/grafana` | 3001 | Log query UI + dashboards |
| **Alertmanager** | `prom/alertmanager` | 9093 | Alert grouping/dedup → ntfy |
| **ntfy-bridge** | `python:3-alpine` (custom) | — | Alertmanager webhook → ntfy translator |

Access Grafana at `:3001` (login `admin` / `GRAFANA_ADMIN_PASSWORD`) over Tailscale.

**Smoke test:**
1. `./stack-manage.sh logging start`
2. Open Grafana → Explore → run `{job="docker"}` — log lines should appear.
3. Trigger an error to verify alerting end-to-end:
   `docker run --rm --name test-logger alpine sh -c 'for i in $(seq 1 200); do echo "ERROR test $i"; done'`
   Within ~15m the HighErrorRate rule fires → Alertmanager → ntfy notification.
```

- [ ] **Step 2: Add Grafana/Loki to the "Useful Docker Commands" area of README**

Append to the useful-commands block:
```markdown
# Query logs from the CLI (if logcli installed) or use Grafana Explore
docker logs -f promtail        # confirm Promtail is scraping
docker logs -f loki            # confirm Loki ingest/ruler
curl -s http://localhost:3100/ready   # Loki readiness
```

- [ ] **Step 3: Update ARCHITECTURE.md**

In `ARCHITECTURE.md`, add the logging stack to the main component diagram/list. Add a subgraph entry alongside the existing stacks:
```
    subgraph LOGGING["🪵 Logging Stack"]
        LK["Loki"]
        PT["Promtail"]
        GF["Grafana"]
        AM["Alertmanager"]
        NB["ntfy-bridge"]
        PT --> LK --> GF
        LK --> AM --> NB
    end
```
And add a data-flow edge note: `PT -->|"scrapes all containers"| LK`.

- [ ] **Step 4: Update the stacks/services badges in README (optional but consistent)**

The top of `README.md` has `![Stacks](...stacks-4-blue)`. Update `4` → `5`:
Find `stacks-4-blue` and replace with `stacks-5-blue`. Bump the services badge count to reflect the 5 new services if desired (`30%2B` → `35%2B`).

- [ ] **Step 5: Commit**

```bash
git add README.md ARCHITECTURE.md
git commit -m "docs(logging): document logging stack in README and ARCHITECTURE"
```

---

## Task 14: Full verification pass

**Files:** none (verification only)

- [ ] **Step 1: Run the full test suite**

Run: `uv run pytest -q`
Expected: all tests pass (16 in `test_ntfy_bridge.py`), exit 0.

- [ ] **Step 2: Validate the compose file once more**

Run: `TZ=UTC GRAFANA_ADMIN_PASSWORD=x WUD_NTFY_TOPIC=t docker compose -f docker-compose-logging.yml config >/dev/null && echo "compose ok"`
Expected: `compose ok`.

- [ ] **Step 3: Shell syntax check on modified script**

Run: `bash -n stack-manage.sh && echo "ok"`
Expected: `ok`.

- [ ] **Step 4: Confirm healthcheck.sh sees the new stack (dry read, no docker needed)**

Run: `grep -l "services:" docker-compose-logging.yml && echo "healthcheck will scan it"`
Expected: prints the filename then the message. (`healthcheck.sh` globs `docker-compose-*.yml`, so no code change is required — this just confirms the file matches the glob and has a `services:` block.)

- [ ] **Step 5: Final commit if any doc/verification tweaks were needed**

```bash
git add -A
git commit -m "chore(logging): verification pass" || echo "nothing to commit"
```

---

## Self-Review Notes (author)

- **Spec coverage:** architecture/placement (Task 10), file+storage layout (Tasks 6–10), Loki 90d retention + ruler (Task 6), Promtail Docker SD + relabel labels `container_name/project/service/job` (Task 7), Grafana provisioning + dashboard + login (Task 9, Task 10 env), Alertmanager → ntfy-bridge (Task 8), ntfy-bridge behavior incl. 200-on-error and severity map (Tasks 2–5), HighErrorRate active + ContainerLogSilence commented (Task 6), stack-manage integration (Task 11), nightly cron auto-inclusion via `all` loop (covered by Task 11 Step 2 — documented in Reference Facts, no separate cron edit), healthcheck auto-coverage (Task 14 Step 4), env vars (Task 12), tests (Tasks 1–5), docs (Task 13). All spec sections mapped.
- **Naming consistency:** module `ntfy_bridge` with functions `severity_to_priority`, `format_messages`, `send_to_ntfy`, `handle_alert_body`, `run`; ntfy-bridge port 8183 consistent across Task 5 server, Task 8 Alertmanager webhook URL, and Task 10 compose healthcheck. Loki ruler tenant dir `/loki/rules/fake` matches `auth_enabled: false`.
- **No placeholders:** every code/config step contains full content.
```