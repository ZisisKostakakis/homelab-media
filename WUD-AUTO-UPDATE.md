# WUD Automatic Container Updates

This document describes the integration between What's Up Docker (WUD) and the stack management system for automatic container updates.

## Overview

The system uses WUD to monitor Docker containers for available updates and automatically triggers updates via webhooks. When WUD detects an available update, it sends a webhook to the `wud-webhook` service, which invokes `stack-manage.sh` to perform the update.

## Components

### 1. What's Up Docker (WUD)
- **Container**: `wud`
- **Port**: 3000
- **Schedule**: Daily at 6 AM (configurable via `WUD_WATCHER_LOCAL_CRON`)
- **Web UI**: http://<server-ip>:3000
- **Credentials**: admin / (see docker-compose-services.yml for password hash)

WUD monitors all containers for updates and can trigger two types of notifications:
- **ntfy notifications**: Batch notification to ntfy.sh/blaze-homelab-wud-docker-updates
- **Webhook triggers**: Individual webhook for each container with updates

### 2. WUD Webhook Server
- **Container**: `wud-webhook`
- **Port**: 8182
- **Script**: `/scripts/wud-webhook-server.py`
- **Health check**: http://<server-ip>:8182/health

A Python HTTP server that receives webhooks from WUD and processes update requests.

### 3. WUD Update Handler
- **Script**: `/scripts/wud-update-handler.sh`
- **Purpose**: Executes stack-manage.sh to perform actual updates
- **Logs**: `/var/lib/homelab-media-configs/wud-updates/`

Maps container names to their stack and service, then calls stack-manage.sh.

## How It Works

1. **Detection**: WUD checks for updates daily at 6 AM
2. **Webhook**: WUD sends HTTP POST to `http://wud-webhook:8182` with container info
3. **Parsing**: Webhook server parses JSON and calls update handler
4. **Mapping**: Handler maps container name to stack/service:
   - `overseerr` → `services overseerr`
   - `qbittorrent` → `torrent qbittorrent`
   - `plex` → `plex plex`
5. **Update**: Handler runs `stack-manage.sh <stack> update <service>`
6. **Notification**: Sends success/failure notification to ntfy.sh

## Container Name Mapping

The update handler uses this mapping:

### Services Stack
- overseerr, maintainerr, filebrowser, autoheal, gluetun-monitor, whatsupdocker, portainer

### Torrent Stack
- gluetun, qbittorrent, sonarr, radarr, bazarr, prowlarr, flaresolverr, unpackerr, recyclarr

### Plex Stack
- plex, suggestarr

## Logs

### Webhook Server Logs
```bash
docker logs wud-webhook
# or
cat /var/lib/homelab-media-configs/wud-updates/webhook-server.log
```

### Update Handler Logs
```bash
docker exec wud-webhook cat /var/lib/homelab-media-configs/wud-updates/update-handler.log
```

## Manual Testing

### Test Webhook Endpoint
```bash
curl http://localhost:8182/health
```

### Test Update for Specific Container
```bash
curl -X POST http://localhost:8182 \
  -H "Content-Type: application/json" \
  -d '{"name":"overseerr","image":{"name":"lscr.io/linuxserver/overseerr"},"result":{"tag":"latest"}}'
```

### Test Handler Script Directly
```bash
docker exec wud-webhook /bin/sh -c 'echo "{\"container\":\"overseerr\",\"image\":\"test\",\"tag\":\"latest\"}" | /scripts/wud-update-handler.sh'
```

## Configuration

### Enable/Disable Auto-Updates

To disable automatic updates, comment out the webhook trigger in `docker-compose-services.yml`:
```yaml
# - WUD_TRIGGER_WEBHOOK_AUTOUPDATE_URL=http://wud-webhook:8182
# - WUD_TRIGGER_WEBHOOK_AUTOUPDATE_METHOD=POST
# - WUD_TRIGGER_WEBHOOK_AUTOUPDATE_MODE=simple
```

You'll still receive ntfy notifications, but updates won't be automatic.

### Exclude Containers from WUD Monitoring

Add a label to any service you want WUD to ignore:
```yaml
labels:
  - "wud.watch=false"
```

Example: filebrowser is excluded because the s6 tag causes false positives.

### Adjust Update Schedule

Change the cron schedule in WUD environment:
```yaml
- WUD_WATCHER_LOCAL_CRON=0 6 * * *  # Daily at 6 AM
```

## Troubleshooting

### Container Updates Fail

1. Check webhook server logs:
   ```bash
   docker logs wud-webhook --tail 50
   ```

2. Check update handler logs:
   ```bash
   docker exec wud-webhook cat /var/lib/homelab-media-configs/wud-updates/update-handler.log
   ```

3. Verify container name mapping:
   ```bash
   # Add container to handler script if it's missing
   vim scripts/wud-update-handler.sh
   ```

### Webhook Not Triggered

1. Verify WUD can reach webhook server:
   ```bash
   docker exec wud curl http://wud-webhook:8182/health
   ```

2. Check WUD logs:
   ```bash
   docker logs wud --tail 100
   ```

### Docker Compose Command Not Found

The wud-webhook container includes docker-cli-compose. If it's missing:
```bash
docker exec wud-webhook docker compose version
```

## ntfy Notifications

Updates trigger notifications to: `https://ntfy.sh/blaze-homelab-wud-docker-updates`

- **Success**: Priority 3, white_check_mark + docker tags
- **Failure**: Priority 4, x + warning tags

Subscribe using the ntfy mobile app or web interface.

## Security Considerations

- The webhook server is exposed on port 8182 (local network only)
- No authentication on webhook endpoint (relies on network security)
- Consider adding webhook secret validation for production use
- Docker socket access required for update operations

## Future Enhancements

Potential improvements:
- Add webhook authentication/secrets
- Support for update windows (only update during specific hours)
- Pre-update health checks
- Automatic rollback on failed health checks
- Update approval workflow (dry-run mode)
