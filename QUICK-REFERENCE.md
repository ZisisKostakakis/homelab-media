# Quick Reference - Independent Docker Stacks

## Current Stack Setup

Your media infrastructure is now split into **3 independent stacks**:

### 1. Torrent Stack (VPN-Protected)
**File:** `docker-compose-torrent.yml`
```bash
docker compose -f docker-compose-torrent.yml [command]
```
**Services:** Gluetun, qBittorrent, Sonarr, Radarr, Prowlarr, Bazarr, FlareSolverr, Unpackerr, Recyclarr

### 2. Plex Stack (Media Server)
**File:** `docker-compose-plex.yml`
```bash
docker compose -f docker-compose-plex.yml [command]
```
**Services:** Plex Media Server

### 3. Services Stack (No VPN)
**File:** `docker-compose-services.yml`
```bash
docker compose -f docker-compose-services.yml [command]
```
**Services:** Overseerr, Maintainerr, Pulse

## Most Common Commands

### Start All Services
```bash
docker compose -f docker-compose-torrent.yml up -d
docker compose -f docker-compose-plex.yml up -d
docker compose -f docker-compose-services.yml up -d
```

### Stop Downloads (Keep Plex Running)
```bash
docker compose -f docker-compose-torrent.yml down
```

### Restart Plex Only
```bash
docker compose -f docker-compose-plex.yml restart
```

### View Logs
```bash
# Torrent stack
docker compose -f docker-compose-torrent.yml logs -f sonarr

# Plex
docker compose -f docker-compose-plex.yml logs -f

# Services
docker compose -f docker-compose-services.yml logs -f overseerr
```

### Check Status
```bash
docker ps
```

## Access URLs

With server IP **192.168.1.86**:

- Plex: http://192.168.1.86:32400/web
- Overseerr: http://192.168.1.86:5055
- Maintainerr: http://192.168.1.86:6246
- Pulse: http://192.168.1.86:7655
- Sonarr: http://192.168.1.86:8989
- Radarr: http://192.168.1.86:7878
- qBittorrent: http://192.168.1.86:8080
- Prowlarr: http://192.168.1.86:9696
- Bazarr: http://192.168.1.86:6767

## Benefits

✓ **Stop torrents without affecting Plex** - Download maintenance doesn't interrupt streaming
✓ **Independent updates** - Update each stack separately
✓ **Better resource control** - Manage VPN and non-VPN services separately
✓ **Easier troubleshooting** - Isolate issues to specific stacks

## Full Documentation

See `STACK-DEPLOYMENT.md` for complete documentation.
