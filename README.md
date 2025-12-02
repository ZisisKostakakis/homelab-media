# Homelab Media Automation Stack

A comprehensive implementation plan for a modern 2025-era homelab media automation system with VPN protection, automated downloads, and quality management.

## Overview

This stack provides a bulletproof solution for automated media downloading and management, featuring encrypted connections, Cloudflare bypass, automatic archive extraction, and community-standard quality profiles.

## Architecture

### Core Components

1. **VPN Layer**: Proton VPN with WireGuard and port forwarding
2. **Container Network**: Gluetun for VPN connectivity and kill switch
3. **Downloader**: qBittorrent (routed via Gluetun)
4. **Automation**: Sonarr, Radarr, and Bazarr (routed via Gluetun)
5. **Management**: Prowlarr with FlareSolverr (routed via Gluetun)
6. **Utilities**: Unpackerr (archive extraction) and Recyclarr (quality profiles)
7. **Media Server**: Plex Server (host network mode) + MPV (client-side for anime)

## Key Features

### 1. Unpackerr - Automated Archive Extraction

**Purpose**: Automatically extract RAR archives from scene releases and anime torrents.

**Why it's needed**: Many high-quality releases come as RAR archives, which Sonarr/Radarr cannot process natively. Unpackerr integrates directly with Sonarr's API to intelligently extract files and clean up after import.

**Docker Configuration**:
```yaml
unpackerr:
  image: golift/unpackerr
  container_name: unpackerr
  environment:
    - PUID=1000
    - PGID=1000
    - TZ=Europe/London
    - UN_SONARR_0_URL=http://sonarr:8989
    - UN_SONARR_0_API_KEY=YOUR_SONARR_API_KEY
    - UN_RADARR_0_URL=http://radarr:7878
    - UN_RADARR_0_API_KEY=YOUR_RADARR_API_KEY
  volumes:
    - /mnt/media/downloads:/downloads
  restart: unless-stopped
```

### 2. Recyclarr - Quality Profile Automation

**Purpose**: Automatically sync TRaSH Guides quality profiles to Sonarr/Radarr.

**Why it's needed**: Manual configuration of quality profiles is tedious. Recyclarr applies industry-standard profiles (e.g., "best 4K anime profile") with a single YAML configuration, auto-creating all custom formats and scoring logic.

### 3. FlareSolverr - Cloudflare Bypass

**Purpose**: Bypass Cloudflare CAPTCHA challenges on indexers like Nyaa.si.

**Why it's needed**: Many indexers use Cloudflare protection, which breaks Prowlarr's search capabilities. FlareSolverr acts as a proxy to solve CAPTCHAs automatically.

**Docker Configuration**:
```yaml
flaresolverr:
  image: flaresolverr/flaresolverr:latest
  container_name: flaresolverr
  environment:
    - LOG_LEVEL=info
    - TZ=Europe/London
  ports:
    - "8191:8191"
  restart: unless-stopped
```

**Integration**: In Prowlarr settings, add FlareSolverr as a proxy with tag `flaresolverr`, then apply that tag to your Nyaa indexer.

## Implementation Checklist

- [ ] Set up Proton VPN with WireGuard and enable port forwarding
- [ ] Deploy Gluetun container with kill switch enabled
- [ ] Configure qBittorrent through Gluetun network
- [ ] Set up Sonarr, Radarr, and Bazarr through Gluetun
- [ ] Deploy Prowlarr through Gluetun and integrate indexers
- [ ] Add FlareSolverr and configure Prowlarr proxy settings
- [ ] Deploy Unpackerr and configure API keys
- [ ] Set up Recyclarr with TRaSH Guides profiles
- [ ] Install and configure Plex Server on host network
- [ ] Configure MPV for client-side anime playback with Anime4K shaders

## Benefits

- **Security**: All torrent traffic routed through VPN with kill switch protection
- **Automation**: Zero-touch media acquisition and organization
- **Quality**: Community-standard quality profiles automatically maintained
- **Reliability**: Cloudflare bypass ensures consistent indexer access
- **Efficiency**: Automatic archive extraction eliminates manual intervention

## References

- [Unpackerr Documentation](https://docs.ultra.cc/applications/unpackerr)
- [Recyclarr TRaSH Guide Automation](https://drfrankenstein.co.uk/recyclarr-trash-guide-automation-microguide/)
- [FlareSolverr Setup Guide](https://trash-guides.info/Prowlarr/prowlarr-setup-flaresolverr/)
- [FlareSolverr GitHub](https://github.com/FlareSolverr/FlareSolverr)

## License

This is a personal homelab configuration. Adapt as needed for your own setup.
