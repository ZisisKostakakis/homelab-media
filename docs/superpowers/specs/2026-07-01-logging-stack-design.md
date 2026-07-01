# Centralized Logging Stack — Loki + Promtail + Grafana

**Date:** 2026-07-01
**Status:** Approved design, pending implementation plan

## Goal

Add centralized, queryable logging to the homelab media stack so container logs
across all stacks (torrent, plex, services, music) are collected, retained for 90
days, explorable through a web UI, and trigger notifications on error spikes —
without depending on the ad-hoc `analyze-docker-logs.sh` workflow.

Tailscale (VM-level, out of project scope) already gates network access to the
host, so services are exposed on host ports and reached over Tailscale like the
existing Portainer/Beszel/WUD UIs.

## Architecture

A new **`docker-compose-logging.yml`** as a fifth independent Compose stack,
parallel to the existing four and managed by `stack-manage.sh`. Kept separate
(not folded into `docker-compose-services.yml`) so it can be updated/restarted in
isolation, matching the existing one-stack-per-concern structure.

All containers join the existing external bridge network `homelab_media_network`.

| Container | Image | Host Port | Role |
|-----------|-------|-----------|------|
| `loki` | `grafana/loki:latest` | 3100 | Log store + ruler (alert evaluation) |
| `promtail` | `grafana/promtail:latest` | — | Docker service-discovery collector, pushes to Loki |
| `grafana` | `grafana/grafana:latest` | 3001 | Query UI + provisioned dashboards |
| `alertmanager` | `prom/alertmanager:latest` | 9093 | Alert grouping/dedup/silencing → ntfy |
| `ntfy-bridge` | `python:3-alpine` (runs a script) | — | Translates Alertmanager webhook → ntfy POST |

### Data Flow

```
Promtail (Docker socket :ro, SD)
   └─ discovers all containers, attaches labels
      └─ push → Loki :3100
                   ├─ Grafana queries Loki (Explore + dashboards)
                   └─ Loki ruler evaluates LogQL error-rate rules
                         └─ fires → Alertmanager
                                       └─ webhook → ntfy-bridge
                                                       └─ POST → ntfy topic
```

`ntfy-bridge` exists because Alertmanager's native webhook payload is not ntfy's
format. It is a small stdlib-only `http.server` script mirroring the existing
`scripts/wud-webhook-server.py` pattern (no third-party deps required at runtime
beyond urllib).

### Notes on component choices

- **Promtail** is in Grafana's LTS/maintenance track (Alloy is the successor) but
  remains fully supported and is the simplest Docker-log collector. Acceptable
  for a homelab; migration to Alloy is a possible future follow-up.
- **Loki** runs in single-binary (`monolithic`) mode with `filesystem` storage —
  no object storage needed at this scale.

## File & Storage Layout

Config lives in the repo (mounted read-only into containers). State lives under
the existing `/var/lib/homelab-media-configs/` convention.

```
homelab-media/
  docker-compose-logging.yml
  config/logging/
    loki-config.yml               # monolithic, filesystem, compactor, ruler
    loki-rules/
      alerts.yml                  # LogQL error-rate + silence rules
    promtail-config.yml           # Docker SD + relabeling
    alertmanager.yml              # route → ntfy-bridge webhook receiver
    grafana/
      provisioning/
        datasources/loki.yml      # auto-provision Loki datasource
        dashboards/dashboards.yml # dashboard provider config
      dashboards/
        container-logs.json       # per-container log volume + error panels
  scripts/
    ntfy-bridge.py                # Alertmanager webhook → ntfy
```

State volumes (host bind mounts, matching convention):

- `/var/lib/homelab-media-configs/loki` — chunks, index, compactor, ruler WAL
- `/var/lib/homelab-media-configs/grafana` — Grafana DB/state
- `/var/lib/homelab-media-configs/promtail` — `positions.yaml` (resume offsets)
- `/var/lib/homelab-media-configs/alertmanager` — silences/nflog state

### Component configuration

**Loki (`loki-config.yml`):**
- `monolithic` / single-binary target, `filesystem` object store.
- `compactor` with `retention_enabled: true`, `retention_period: 2160h` (90 days),
  `delete_request_store: filesystem`.
- `ruler` enabled: `storage.type: local`, rule dir → `loki-rules/`,
  `alertmanager_url` → `http://alertmanager:9093`.
- `/ready` used for healthcheck.

**Promtail (`promtail-config.yml`):**
- `docker_sd_configs` against `unix:///var/run/docker.sock` (mounted `:ro`).
- Relabel rules promote to Loki labels: `container_name`,
  `project` (compose project), `stack`, and a static `job="docker"`.
- `positions.yaml` on the promtail volume so restarts resume without re-ingesting.

**Grafana:**
- Provisioned Loki datasource (`datasources/loki.yml`, `url: http://loki:3100`).
- Provisioned dashboard `container-logs.json`: log volume per container, error-line
  rate, and a live-tail/Explore link.
- Admin login enabled; password from `${GRAFANA_ADMIN_PASSWORD}` (`.env`).
- `/api/health` used for healthcheck.

**Alertmanager (`alertmanager.yml`):**
- Single route → `ntfy-bridge` webhook receiver (`http://ntfy-bridge:PORT/alert`).
- `group_by: [container_name]`, `repeat_interval: 4h` to reduce nagging.
- `/-/healthy` used for healthcheck.

## Alerting Rules (`loki-rules/alerts.yml`)

LogQL rules over Promtail labels:

- **HighErrorRate** (active):
  ```
  sum by (container_name) (
    rate({job="docker"} |~ "(?i)\\b(error|fatal|panic)\\b" [5m])
  ) > 0.2
  ```
  `for: 10m`. Warns when a container sustains > ~1 error line / 5s. Threshold is
  tunable and documented as such.

- **ContainerLogSilence** (included, commented by default):
  Alerts when a normally-logging container emits nothing for 15m — catches wedged
  services a healthcheck might miss. Left commented so the stack starts minimal;
  user can enable after observing baseline log behavior.

Rules attach `severity` and `container_name` labels. Alertmanager groups by
`container_name`; the ntfy message names the offending container.

## ntfy-bridge

Small script modeled on `scripts/wud-webhook-server.py`:

- stdlib `http.server`; endpoints `/alert` (POST, Alertmanager webhook) and
  `/health` (GET).
- Parses Alertmanager webhook JSON; maps `severity` → ntfy priority
  (e.g. `critical`→5, `warning`→3); formats title (container name + alertname)
  and body (summary/description + value).
- POSTs to `https://ntfy.sh/${LOGGING_NTFY_TOPIC}` (defaults to reuse
  `WUD_NTFY_TOPIC` if `LOGGING_NTFY_TOPIC` unset).
- On any downstream failure: log it and still return HTTP 200 to Alertmanager so
  the alert queue does not wedge. Network calls wrapped in try/except like the
  existing webhook server.

## Error Handling & Resilience

- All containers `restart: unless-stopped`.
- Healthchecks: loki `/ready`, grafana `/api/health`, alertmanager `/-/healthy`,
  ntfy-bridge `/health`. (Promtail has no standard HTTP health endpoint by default;
  rely on restart policy, or add `/ready` if server listener enabled.)
- Promtail `positions.yaml` persisted → resumes cleanly after restart.
- Loki compactor enforces 90-day retention so disk cannot grow unbounded; the
  existing `scripts/disk-report.sh` already watches the configs mount.
- ntfy-bridge failures never block Alertmanager (returns 200, logs error).

## Integration Points

- **`stack-manage.sh`**: add `logging` as a recognized stack name so
  `./stack-manage.sh logging up|down|restart|logs|...` works. Follow existing
  stack-name → compose-file mapping.
- **`healthcheck.sh`**: no change needed — it scans all `docker-compose-*.yml`,
  so the new stack is covered automatically. Verify this during implementation.
- **Cron nightly updater** (`scripts/cron-jobs/update-all-stacks.sh`): confirm the
  new stack is included in the nightly update loop (or explicitly document if
  intentionally excluded).
- **`.env.example`**: add `GRAFANA_ADMIN_PASSWORD` and `LOGGING_NTFY_TOPIC`
  (documented, placeholder values only).
- **WUD**: new images are watched automatically; no `wud.watch=false` needed
  unless a tag causes false positives.

## Testing

Per project convention (`pytest`, `uv`):

- **Unit tests for `ntfy-bridge.py`:**
  - Valid Alertmanager payload → correct ntfy POST (mock urllib/requests):
    title/body/priority correct.
  - Malformed/empty payload → returns 200 and logs error, no crash.
  - `severity` → priority mapping table.
  - `/health` returns 200.
- **Compose validation:** `docker compose -f docker-compose-logging.yml config`
  parses cleanly (candidate for future CI lint).
- **Manual smoke test (documented in README):**
  1. Bring up stack; confirm Grafana Explore / `logcli` returns log lines.
  2. Emit an error log from a test container; confirm alert fires end-to-end
     (Loki ruler → Alertmanager → ntfy-bridge → ntfy notification received).

## Documentation

- New README stack section (config layout, ports, query examples, smoke test).
- ARCHITECTURE.md: add the logging stack to the diagrams / component list.
- `.env.example`: new documented variables.

## Out of Scope

- Metrics (Prometheus/Grafana dashboards for CPU/mem/bandwidth) — logs only.
- Migration from Promtail to Grafana Alloy — possible future follow-up.
- Reverse proxy / SSO in front of Grafana — relies on Tailscale for now.
- Long-term object storage (S3/B2) for Loki — filesystem is sufficient at scale.
