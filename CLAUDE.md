# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a homelab media automation stack using Docker Compose to orchestrate a complete media acquisition, management, and streaming pipeline. All torrent-related services run through a VPN (Gluetun) for security, while user-facing services like Overseerr remain directly accessible.

## Architecture

### Network Topology

The stack uses a **shared network namespace pattern** via Gluetun:

- **VPN Layer (Gluetun)**: Acts as the network gateway for all download/automation services
  - Provides WireGuard VPN connection to Proton VPN
  - All services using `network_mode: "service:gluetun"` share its network stack
  - Port forwarding enabled for optimal torrent performance
  - Kill switch via `FIREWALL=on` ensures no traffic leaks outside VPN

- **Services Behind VPN** (using `network_mode: "service:gluetun"`):
  - qBittorrent (torrent client)
  - Sonarr (TV show automation)
  - Radarr (movie automation)
  - Bazarr (subtitle downloader)
  - Prowlarr (indexer manager)
  - FlareSolverr (Cloudflare bypass)
  - Unpackerr (archive extractor)
  - Recyclarr (quality profile manager)

- **Services on Host Network**:
  - Overseerr (user-facing request system) - port 5055
  - Maintainerr (media cleanup automation) - port 6246

### Critical Networking Details

When services share the Gluetun network namespace:
- They communicate via `localhost` (e.g., Unpackerr connects to `http://localhost:8989` for Sonarr)
- All ports are exposed through the Gluetun container's `ports:` section
- Services cannot have their own `ports:` mappings when using `network_mode: "service:gluetun"`
- The `FIREWALL_OUTBOUND_SUBNETS` setting must include your local subnet (e.g., `192.168.1.0/24`) for local network access

### Key Components

1. **Gluetun** - VPN container providing network isolation
2. **qBittorrent** - Torrent downloader
3. **Sonarr/Radarr** - PVR automation for TV/movies
4. **Prowlarr** - Centralized indexer management
5. **Bazarr** - Automated subtitle downloading
6. **FlareSolverr** - Cloudflare CAPTCHA solver for indexers
7. **Unpackerr** - Automatically extracts RAR archives from scene releases
8. **Recyclarr** - Syncs TRaSH Guides quality profiles
9. **Overseerr** - User-friendly request interface
10. **Maintainerr** - Automated media cleanup based on rules

## Common Commands

### Container Management

```bash
# Start all services
docker compose up -d

# Stop all services
docker compose down

# View logs for a specific service
docker compose logs -f <service_name>

# Restart a service
docker compose restart <service_name>

# Pull latest images
docker compose pull

# View running containers
docker compose ps
```

### Bootstrap Stack

```bash
# Initial setup (creates directories, pulls images, starts containers)
./homelab-media-bootstrap.sh
```

### Backup Configurations

```bash
# Backup all service configurations (API keys, settings, databases)
./backup-config.sh
```

This creates timestamped backups in `/home/blaze/Github/homelab-media/config-backups/` containing:
- Service configurations (XML, JSON, database files)
- Docker Compose file
- Environment variables
- Excludes logs, media files, and cache

## Data Layout

### Mount Structure

All services use `/mnt/media` as the base data directory:

```
/mnt/media/
├── config/           # Application configurations
│   ├── gluetun/
│   ├── qbittorrent/
│   ├── sonarr/
│   ├── radarr/
│   ├── bazarr/
│   ├── prowlarr/
│   ├── recyclarr/
│   ├── overseerr/
│   └── plex/
├── downloads/        # qBittorrent download directory
├── tv/              # Final TV show library
└── movies/          # Final movie library
```

### Volume Bindings

- Most services mount `/mnt/media:/data` for consistent path access
- Config directories are individually mounted to `/mnt/media/config/<service>`
- Maintainerr uses relative path `./maintainerr:/opt/data` in the repo

## Service Access URLs

When running, services are accessible at:

- **Overseerr**: `http://<server-ip>:5055` - Request interface
- **Maintainerr**: `http://<server-ip>:6246` - Media cleanup management
- **qBittorrent**: `http://<server-ip>:8080` - Torrent client
- **Sonarr**: `http://<server-ip>:8989` - TV automation
- **Radarr**: `http://<server-ip>:7878` - Movie automation
- **Prowlarr**: `http://<server-ip>:9696` - Indexer manager
- **Bazarr**: `http://<server-ip>:6767` - Subtitle downloader
- **FlareSolverr**: `http://<server-ip>:8191` - Cloudflare proxy

## Configuration Notes

### API Keys and Secrets

API keys are currently hardcoded in `docker-compose.yml`:
- Sonarr API key: Used by Unpackerr and Recyclarr
- Radarr API key: Used by Unpackerr and Recyclarr
- VPN credentials: WireGuard private key in Gluetun config

**Security**: The `.env` file exists but is not currently used. Consider migrating sensitive values to `.env` and using variable substitution in `docker-compose.yml`.

### Environment Defaults

All services use:
- `PUID=1000` / `PGID=1000` for file permissions
- `TZ=Europe/London` (or `Europe/Belfast` for Maintainerr)

### VPN Configuration

Gluetun is configured for Proton VPN with:
- WireGuard protocol
- London server location
- Port forwarding enabled
- Firewall kill switch
- Local network access via `FIREWALL_OUTBOUND_SUBNETS`

## Troubleshooting

### VPN Connection Issues

If services cannot access the internet:
1. Check Gluetun logs: `docker compose logs gluetun`
2. Verify VPN credentials are valid
3. Ensure `FIREWALL_OUTBOUND_SUBNETS` includes your local network

### Services Cannot Communicate

If Sonarr/Radarr cannot reach qBittorrent or other services:
1. Verify they're all using `network_mode: "service:gluetun"`
2. Use `localhost` instead of container names for URLs
3. Check that ports are exposed in Gluetun's `ports:` section

### Archive Extraction Not Working

If Unpackerr isn't extracting RAR files:
1. Verify API keys match Sonarr/Radarr
2. Check Unpackerr logs: `docker compose logs unpackerr`
3. Ensure paths are correctly mapped (`/mnt/media:/data`)

### Cloudflare-Protected Indexers Failing

If indexers like Nyaa.si fail in Prowlarr:
1. Ensure FlareSolverr is running
2. In Prowlarr, add FlareSolverr proxy: `http://localhost:8191`
3. Tag the indexer with the FlareSolverr proxy

## File Modification Guidelines

### Editing docker-compose.yml

When modifying services:
- **Never** add `ports:` to services using `network_mode: "service:gluetun"`
- **Always** add new port mappings to the Gluetun service
- **Use** `localhost` for inter-service communication within the VPN network
- **Maintain** consistent PUID/PGID across services

### Adding New Services

To add a new service to the stack:

1. If it needs VPN protection:
   ```yaml
   new-service:
     image: example/image
     network_mode: "service:gluetun"
     depends_on:
       - gluetun
     volumes:
       - /mnt/media:/data
   ```
   Add port mappings to Gluetun's `ports:` section

2. If it needs direct network access:
   ```yaml
   new-service:
     image: example/image
     ports:
       - "9999:9999"
     volumes:
       - /mnt/media/config/new-service:/config
   ```

### Security Considerations

- Do not commit `.env` with real credentials
- Rotate API keys if the repository is made public
- WireGuard private key should be moved to `.env`
- Consider using Docker secrets for production deployments
