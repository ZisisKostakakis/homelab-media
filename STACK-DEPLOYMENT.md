# Homelab Media Stack Deployment Guide

The media automation stack has been separated into **three independent Docker Compose stacks** for better flexibility and control.

## Stack Overview

### 1. **Torrent Stack** (`docker-compose-torrent.yml`)
VPN-protected download and automation services:
- Gluetun (VPN gateway)
- qBittorrent (torrent client)
- Sonarr (TV automation)
- Radarr (movie automation)
- Prowlarr (indexer manager)
- Bazarr (subtitles)
- FlareSolverr (Cloudflare bypass)
- Unpackerr (archive extraction)
- Recyclarr (quality profiles)

**Ports:** 8080, 8989, 7878, 9696, 6767, 8191

### 2. **Plex Stack** (`docker-compose-plex.yml`)
Media server only:
- Plex Media Server

**Port:** 32400 (plus additional Plex ports via host network)

### 3. **Services Stack** (`docker-compose-services.yml`)
User-facing services without VPN:
- Overseerr (request system)
- Maintainerr (media cleanup)
- Pulse (Docker monitoring)

**Ports:** 5055, 6246, 7655

## Managing the Stacks

### Start All Stacks
```bash
# Start torrent stack
docker compose -f docker-compose-torrent.yml up -d

# Start Plex
docker compose -f docker-compose-plex.yml up -d

# Start user services
docker compose -f docker-compose-services.yml up -d
```

### Stop Individual Stacks
```bash
# Stop torrent stack (doesn't affect Plex)
docker compose -f docker-compose-torrent.yml down

# Stop Plex (doesn't affect downloads)
docker compose -f docker-compose-plex.yml down

# Stop user services
docker compose -f docker-compose-services.yml down
```

### View Logs
```bash
# Torrent stack logs
docker compose -f docker-compose-torrent.yml logs -f

# Plex logs
docker compose -f docker-compose-plex.yml logs -f

# Services logs
docker compose -f docker-compose-services.yml logs -f

# Specific service
docker compose -f docker-compose-torrent.yml logs -f sonarr
```

### Update Services
```bash
# Update torrent stack
docker compose -f docker-compose-torrent.yml pull
docker compose -f docker-compose-torrent.yml up -d

# Update Plex
docker compose -f docker-compose-plex.yml pull
docker compose -f docker-compose-plex.yml up -d

# Update services
docker compose -f docker-compose-services.yml pull
docker compose -f docker-compose-services.yml up -d
```

### Restart Individual Services
```bash
# Restart a service in torrent stack
docker compose -f docker-compose-torrent.yml restart sonarr

# Restart Plex
docker compose -f docker-compose-plex.yml restart plex

# Restart Overseerr
docker compose -f docker-compose-services.yml restart overseerr
```

## Common Use Cases

### Maintenance on Torrent Stack (Without Affecting Plex)
```bash
# Stop downloads/automation
docker compose -f docker-compose-torrent.yml down

# Plex continues serving media to users
# When ready, restart torrent stack:
docker compose -f docker-compose-torrent.yml up -d
```

### Plex Maintenance (Without Affecting Downloads)
```bash
# Stop Plex
docker compose -f docker-compose-plex.yml down

# Downloads and automation continue working
# When ready, restart Plex:
docker compose -f docker-compose-plex.yml up -d
```

### VPN Changes (Requires Torrent Stack Restart)
```bash
# Edit .env file to change VPN settings
nano .env

# Restart only the torrent stack
docker compose -f docker-compose-torrent.yml down
docker compose -f docker-compose-torrent.yml up -d
```

## Environment Variables

All stacks use the same `.env` file in the repository root:

```bash
# Required variables
WIREGUARD_PRIVATE_KEY=your_key_here
WIREGUARD_ADDRESSES=10.2.0.2/32
SERVER_CITIES=London
FIREWALL_OUTBOUND_SUBNETS=192.168.1.0/24
SONARR_API_KEY=your_api_key
RADARR_API_KEY=your_api_key
PUID=1000
PGID=1000
TZ=Europe/London
TZ_MAINTAINERR=Europe/Belfast

# Optional
PLEX_CLAIM=claim-xxxxxxxxxx
```

## Migration from Single Stack

If you're currently running the old `docker-compose.yml`:

```bash
# Stop the old combined stack
docker compose down

# Start the new separate stacks
docker compose -f docker-compose-torrent.yml up -d
docker compose -f docker-compose-plex.yml up -d
docker compose -f docker-compose-services.yml up -d
```

**Note:** All configuration and data remains in the same locations, so no data migration is needed.

## Troubleshooting

### Check What's Running
```bash
# View all running containers
docker ps

# View specific stack status
docker compose -f docker-compose-torrent.yml ps
docker compose -f docker-compose-plex.yml ps
docker compose -f docker-compose-services.yml ps
```

### VPN Issues
```bash
# Check Gluetun VPN connection
docker compose -f docker-compose-torrent.yml logs gluetun | tail -50

# Verify VPN IP (should not be your home IP)
docker compose -f docker-compose-torrent.yml exec gluetun wget -qO- ifconfig.me
```

### Service Communication
- **Torrent stack services** communicate via `localhost` (shared network namespace)
- **Overseerr/Maintainerr** connect to Plex via host IP (e.g., `192.168.1.86:32400`)
- **Overseerr** connects to Sonarr/Radarr via host IP (e.g., `192.168.1.86:8989`)

## Service URLs

Once all stacks are running:

- **Plex:** `http://<server-ip>:32400/web`
- **Overseerr:** `http://<server-ip>:5055`
- **Maintainerr:** `http://<server-ip>:6246`
- **Pulse:** `http://<server-ip>:7655`
- **Sonarr:** `http://<server-ip>:8989`
- **Radarr:** `http://<server-ip>:7878`
- **qBittorrent:** `http://<server-ip>:8080`
- **Prowlarr:** `http://<server-ip>:9696`
- **Bazarr:** `http://<server-ip>:6767`
