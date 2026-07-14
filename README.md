# Homelab Media Stack

![Stacks](https://img.shields.io/badge/stacks-5-blue)
![Services](https://img.shields.io/badge/services-35%2B-green)
![VPN](https://img.shields.io/badge/VPN-ProtonVPN%20WireGuard-purple)
![License](https://img.shields.io/badge/license-personal-lightgrey)

A fully automated, self-healing homelab media stack built on Docker Compose. Handles everything from media requests to downloading, extracting, renaming, subtitle fetching, quality management, streaming, and music — with zero manual intervention after initial setup.

All download traffic routes through a WireGuard VPN with a firewall kill switch. A custom cascade-restart monitor automatically recovers all dependent services when the VPN restarts. Container images are updated nightly by a cron sweep. Plex playback automatically pauses all torrents to prioritise streaming bandwidth.

---

## Table of Contents

- [Architecture](#architecture)
- [Stack Breakdown](#stack-breakdown)
- [Automation Pipelines](#automation-pipelines)
- [Self-Healing Infrastructure](#self-healing-infrastructure)
- [Network Design and VPN Security](#network-design-and-vpn-security)
- [Data Layout](#data-layout)
- [Service Reference](#service-reference)
- [Getting Started](#getting-started)
- [Operations Reference](#operations-reference)
- [Troubleshooting](#troubleshooting)
- [Security Considerations](#security-considerations)

---

## Architecture

The stack is split into four independent Docker Compose projects that share a common bridge network (`homelab_media_network`). This allows each stack to be updated, restarted, or debugged independently without affecting the others.

```mermaid
graph TB
    subgraph TORRENT["📦 Torrent Stack"]
        GL["Gluetun (VPN)"]
        QB["qBittorrent"]
        ARR["Sonarr · Radarr · Lidarr · Bazarr\nProwlarr · FlareSolverr\nUnpackerr · Recyclarr · cross-seed"]
        GL --- QB & ARR
    end

    subgraph PLEX["📺 Plex Stack"]
        PX["Plex (host network)"]
        PS["SuggestArr · Kitana · Tautulli"]
    end

    subgraph SERVICES["⚙️ Services Stack"]
        SR["Seerr · Maintainerr\nFilebrowser · Picard"]
        SH["Autoheal · gluetun-monitor"]
        OPS["Portainer · Beszel"]
    end

    subgraph MUSIC["🎵 Music Stack"]
        NAV["Navidrome"]
        AM["AudioMuse (flask + worker)"]
        DB["Redis · Postgres"]
        NAV --- AM
        DB --- AM
    end

    SR -->|"requests"| ARR
    PX -->|"library"| QB
    SH -->|"monitors + heals"| TORRENT
    AM -->|"AI analysis"| NAV
```

See [ARCHITECTURE.md](./ARCHITECTURE.md) for the detailed diagrams including sequence diagrams for the request pipeline and VPN auto-healing.

---

## Stack Breakdown

### Torrent Stack (`docker-compose-torrent.yml`)

Most services in this stack run inside the Gluetun VPN network namespace. They communicate with each other via `localhost` and are completely isolated from the internet without VPN. Cleanuparr and Whisper run on the bridge network instead — Cleanuparr orchestrates the download clients through Gluetun's published ports, and Whisper serves Bazarr.

| Service | Image | Port | Role |
|---------|-------|------|------|
| **Gluetun** | `qmcgaw/gluetun` | exposes all | WireGuard VPN gateway + firewall kill switch |
| **qBittorrent** | `linuxserver/qbittorrent` | 8080 | Torrent client |
| **Sonarr** | `homelab-sonarr` (custom) | 8989 | TV show PVR automation |
| **Radarr** | `linuxserver/radarr` | 7878 | Movie PVR automation |
| **Lidarr** | `linuxserver/lidarr` | 8686 | Music/artist PVR automation |
| **Prowlarr** | `linuxserver/prowlarr` | 9696 | Centralized indexer manager |
| **Bazarr** | `linuxserver/bazarr` | 6767 | Automated subtitle downloader |
| **FlareSolverr** | `flaresolverr/flaresolverr` | 8191 | Cloudflare CAPTCHA bypass proxy |
| **Unpackerr** | `golift/unpackerr` | — | RAR/ZIP archive extractor |
| **Recyclarr** | `recyclarr/recyclarr` | — | TRaSH Guides quality profile sync |
| **Cleanuparr** | `cleanuparr/cleanuparr` | 11011 | Blocks malicious files, cleans stalled/orphaned downloads (bridge network) |
| **Whisper ASR** | `onerahmet/openai-whisper-asr-webservice` | 9000 | AI subtitle generation backend for Bazarr (bridge network) |

### Plex Stack (`docker-compose-plex.yml`)

| Service | Image | Port | Role |
|---------|-------|------|------|
| **Plex** | `linuxserver/plex` | 32400 (host) | Media server with hardware transcoding |
| **SuggestArr** | `ciuse99/suggestarr` | 5000 | AI-powered media recommendations → Seerr |
| **Kitana** | `pannal/kitana` | 31337 | Plex plugin manager web UI |
| **Tautulli** | `linuxserver/tautulli` | 8787 | Plex play history, statistics, and automation scripts |
| **plex-trakt-sync** | `taxel/plextraktsync` | host | Sync watched status to Trakt.tv (manual profile) |

### Services Stack (`docker-compose-services.yml`)

| Service | Image | Port | Role |
|---------|-------|------|------|
| **Seerr** | `seerr-team/seerr` | 5055 | User-facing media request interface |
| **Maintainerr** | `maintainerr/maintainerr` | 6246 | Automated media cleanup rules |
| **Filebrowser** | `filebrowser/filebrowser` | 8181 | Web-based file manager for `/mnt/media` |
| **Picard** | `jlesage/musicbrainz-picard` | 5800 | MusicBrainz Picard music tagger (web UI) |
| **Autoheal** | `willfarrell/autoheal` | — | Restarts any container failing its healthcheck |
| **gluetun-monitor** | `alpine` (custom script) | — | Cascade restarts torrent stack when Gluetun restarts |
| **Portainer** | `portainer/portainer-ce` | 9443 | Docker management UI |
| **Beszel** | `henrygd/beszel` | 8090 | System monitoring dashboard |

### Music Stack (`docker-compose-music.yml`)

| Service | Image | Port | Role |
|---------|-------|------|------|
| **Navidrome** | `deluan/navidrome` | 4533 | Self-hosted music streaming server |
| **AudioMuse (flask)** | `neptunehub/audiomuse-ai` | 8000 | AI music analysis web API |
| **AudioMuse (worker)** | `neptunehub/audiomuse-ai` | — | Background AI analysis worker |
| **audiomuse-redis** | `redis:7-alpine` | — | Task queue for AudioMuse workers |
| **audiomuse-postgres** | `postgres:15-alpine` | — | Persistent database for AudioMuse |

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

---

## Automation Pipelines

### 1. Media Request Pipeline

User submits a request in Seerr → Seerr forwards to Sonarr/Radarr/Lidarr via API → *arr searches all indexers via Prowlarr (with FlareSolverr for Cloudflare-protected indexers) → best torrent is grabbed based on quality profile scoring → qBittorrent downloads over VPN → on completion, Unpackerr extracts any RAR archives → *arr renames and hardlinks the file to the library → Bazarr fetches subtitles → Plex library refreshes → media appears in Plex.

See the [Media Request Flow diagram](./ARCHITECTURE.md#2-media-request-flow) for the full sequence.

### 2. Subtitle Pipeline (Bazarr)

Bazarr monitors Sonarr and Radarr for newly imported media and automatically searches configured subtitle providers. Subtitles are downloaded and associated with the media file without any user action. When no provider has a match, the Whisper AI provider (`whisper-asr`, reached via the host IP because container DNS does not resolve inside the VPN namespace) transcribes or translates the audio track to generate subtitles locally.

### 3. Quality Management Pipeline (Recyclarr)

Recyclarr syncs quality profiles from [TRaSH Guides](https://trash-guides.info/) to Sonarr and Radarr on container start and on a schedule. This keeps custom formats, release group scoring, and quality cutoffs up to date with community recommendations without manual configuration.

### 4. VPN Auto-Healing Pipeline (gluetun-monitor)

When Gluetun restarts (due to an update, crash, or VPN reconnect), all services sharing its network namespace lose connectivity. The `gluetun-monitor` container watches Docker events for Gluetun restart signals, waits for Gluetun to become healthy, then stops and recreates all VPN-dependent services so they rejoin the new network namespace. Rate limiting prevents restart loops (max 5 restarts per hour). Push notifications via ntfy.sh report success or failure.

See the [VPN Auto-Healing diagram](./ARCHITECTURE.md#3-vpn-auto-healing-flow) for the full sequence.

### 5. Container Update Pipeline (nightly cron)

A daily cron job runs `bash stack-manage.sh all update` at midnight UK time (`CRON_TZ=Europe/London`, so the schedule survives BST/GMT transitions without an edit), pulling the latest images and recreating any changed containers across all stacks.

### 6. Media Cleanup Pipeline (Maintainerr)

Maintainerr applies configurable rules to remove media from Plex (and optionally from Seerr and the filesystem) based on criteria like: not watched in N days, added more than N months ago, or below a watch count threshold. This keeps the library from growing indefinitely without manual curation.

### 7. Plex Playback → Bandwidth Management (plex-qbit-manager)

`scripts/plex-qbit-manager.py` is called by Tautulli on every Plex playback event. When any stream starts, it pauses all active qBittorrent torrents. When all streams end, it resumes them. A file-based counter with locking ensures multiple concurrent streams are tracked correctly — torrents remain paused until the last stream stops.

Tautulli mounts the scripts directory read-only and injects qBittorrent credentials as environment variables, so no credentials are hardcoded in the script.

---

## Self-Healing Infrastructure

Three independent layers ensure the stack recovers from failures automatically:

### Layer 1: Docker Healthchecks

Every service defines a `healthcheck` in its Compose configuration. Docker marks containers `healthy`, `unhealthy`, or `starting`. Services with `depends_on: condition: service_healthy` (like qBittorrent depending on Gluetun) will not start until their dependency is healthy.

| Service | Healthcheck endpoint |
|---------|---------------------|
| Gluetun | `/gluetun-entrypoint healthcheck` |
| qBittorrent | `GET /api/v2/app/version` |
| Sonarr / Radarr / Lidarr | `GET /ping` |
| Prowlarr | `GET /ping` |
| Bazarr | `GET /api/system/status` |
| FlareSolverr | `GET /health` |
| Seerr | `GET /api/v1/status` |

### Layer 2: Autoheal

The `willfarrell/autoheal` container monitors all containers (label: `all`) every 10 seconds. If any container is in an `unhealthy` state, Autoheal automatically restarts it. This handles transient failures that healthchecks detect but the container cannot self-recover from.

### Layer 3: gluetun-monitor (Cascade Restart)

This is the most critical self-healing layer. Gluetun creates a new network namespace every time it restarts. Containers sharing that namespace (via `network_mode: service:gluetun`) become orphaned — they can no longer reach the internet or each other through the old namespace.

`gluetun-cascade-restart.sh` solves this by:
1. Watching Docker events for Gluetun `start`/`restart` events
2. Confirming a real restart by comparing network namespace SandboxKeys (not just health status changes)
3. Applying debounce (30s cooldown) and rate limiting (5 restarts/hour max)
4. Waiting up to 300s for Gluetun to become healthy
5. Stopping and removing all VPN-dependent services (qBittorrent, Sonarr, Radarr, Lidarr, Prowlarr, Bazarr, FlareSolverr, Unpackerr, Recyclarr, cross-seed)
6. Recreating them all via `docker compose up -d` (with up to 3 retries with exponential backoff)
7. Sending ntfy.sh notifications at each stage

---

## Network Design and VPN Security

### Three Network Zones

```
┌─────────────────────────────────────────────┐
│  Gluetun VPN Namespace                       │
│  (network_mode: service:gluetun)             │
│  All traffic exits via WireGuard tun0        │
│  Public IP = Proton VPN London server        │
│  qBit · Sonarr · Radarr · Lidarr · etc.     │
└─────────────────────────────────────────────┘
         │ ports exposed through Gluetun
         ▼
┌─────────────────────────────────────────────┐
│  homelab_media_network (bridge)              │
│  172.18.0.0/16                               │
│  Seerr · Maintainerr · Plex stack           │
│  Autoheal · gluetun-monitor                 │
└─────────────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────────┐
│  Host network (Plex only)                    │
│  Direct access to host network interfaces    │
│  Required for Plex DLNA and GDM discovery    │
└─────────────────────────────────────────────┘
```

### Gluetun Firewall Rules

| Setting | Value | Purpose |
|---------|-------|---------|
| `FIREWALL=on` | enabled | Kill switch — blocks all non-VPN traffic if tunnel drops |
| `FIREWALL_OUTBOUND_SUBNETS` | `192.168.1.0/24,172.18.0.0/16` | Allow LAN + bridge traffic to bypass VPN |
| `VPN_PORT_FORWARDING=on` | enabled | Proton assigns a port for inbound torrent connections |
| `VPN_PORT_FORWARDING_UP_COMMAND` | `wget` to qBit API | Automatically updates qBittorrent's listening port when VPN assigns one |
| `VPN_PORT_FORWARDING_DOWN_COMMAND` | `wget` to qBit API | Resets port to `0`/`lo` on VPN disconnect |
| `WIREGUARD_MTU=1280` | conservative | Prevents fragmentation over the tunnel |
| `DNS_ADDRESS=1.1.1.1` | Cloudflare | Prevents DNS leaks through system resolver |

### Why Services Use `localhost` for Internal Communication

When containers share Gluetun's network namespace via `network_mode: service:gluetun`, they all share the same network stack — the same interfaces, the same IP addresses, the same `localhost`. Container DNS names do not resolve between them. All internal service URLs use `localhost`:

```
Unpackerr → Sonarr:  http://localhost:8989
Recyclarr → Radarr:  http://localhost:7878
cross-seed → qBit:   http://localhost:8080
```

---

## Data Layout

### Storage Structure

```
/mnt/media/
├── downloads/              # qBittorrent active downloads + seeding
│   ├── complete/           # Finished downloads (hardlinked to library)
│   └── incomplete/         # In-progress downloads
├── tv/                     # Final TV show library (Plex source)
│   └── Show Name/
│       └── Season 01/
│           └── Episode.mkv
├── movies/                 # Final movie library (Plex source)
│   └── Movie Name (Year)/
│       └── Movie.mkv
├── music/                  # Music library (Navidrome source, read-only mount)
│   └── Artist/
│       └── Album/
│           └── Track.flac
└── transcode/              # Plex temporary transcode buffer
```

### Hardlink Strategy

Sonarr and Radarr use **hardlinks** (not copies) when importing from `downloads/` to the library. The file exists at two filesystem paths but occupies disk space only once. This means:
- qBittorrent continues seeding the original file path
- The library path is clean and Plex-organised
- No extra disk space consumed
- Deletion in one location does not affect the other

This works because all services mount `/mnt/media` as `/data`, keeping downloads and library on the same filesystem.

### Config Storage

All application configs are stored outside the repo at `/var/lib/homelab-media-configs/` to keep them separate from the codebase:

```
/var/lib/homelab-media-configs/
├── gluetun/            # VPN config + state
├── qbittorrent/        # Settings + torrent metadata (BT_backup/)
├── sonarr/             # Database, config.xml
├── radarr/             # Database, config.xml
├── lidarr/             # Database, config.xml
├── prowlarr/           # Database, indexer configs
├── bazarr/             # Database, subtitle configs
├── seerr/              # Settings + user database
├── plex/               # Plex metadata + preferences
├── tautulli/           # Play history database
├── gluetun-monitor/    # Restart log + config overrides
├── navidrome/          # Navidrome database and config
├── audiomuse-postgres/ # AudioMuse PostgreSQL data
└── audiomuse-redis/    # AudioMuse Redis data
```

---

## Service Reference

| Service | URL | Stack | Network | Notes |
|---------|-----|-------|---------|-------|
| Seerr | `:5055` | services | bridge | Media request UI |
| Maintainerr | `:6246` | services | bridge | Media cleanup rules |
| Filebrowser | `:8181` | services | bridge | Web file manager |
| Picard | `:5800` | services | bridge | Music tagger web UI |
| Portainer | `:9443` | services | host | Docker management |
| Beszel | `:8090` | services | bridge | System monitoring |
| qBittorrent | `:8080` | torrent | VPN | Torrent client |
| Sonarr | `:8989` | torrent | VPN | TV automation |
| Radarr | `:7878` | torrent | VPN | Movie automation |
| Lidarr | `:8686` | torrent | VPN | Music automation |
| Prowlarr | `:9696` | torrent | VPN | Indexer manager |
| Bazarr | `:6767` | torrent | VPN | Subtitle downloader |
| FlareSolverr | `:8191` | torrent | VPN | CF bypass |
| Cleanuparr | `:11011` | torrent | bridge | Download hygiene + malware blocker |
| Whisper ASR | `:9000` | torrent | bridge | AI subtitles for Bazarr |
| Readarr | `:8282` | torrent | VPN | Book automation |
| Plex | `:32400` | plex | host | Media server |
| SuggestArr | `:5000` | plex | bridge | Recommendations |
| Kitana | `:31337` | plex | bridge | Plugin manager |
| Tautulli | `:8787` | plex | bridge | Play stats + automation |
| Navidrome | `:4533` | music | bridge | Music streaming |
| AudioMuse | `:8000` | music | bridge | AI music analysis UI |

---

## Getting Started

### Prerequisites

- Docker and Docker Compose v2
- `/mnt/media` mounted (external drive or NAS)
- Proton VPN account with WireGuard config (port forwarding required)
- `.env` file with required variables (see below)

### Environment Variables

Copy `.env.example` to `.env` and populate:

```env
# User/Group for file permissions
PUID=1000
PGID=1000

# Timezones
TZ=Europe/London
TZ_MAINTAINERR=Europe/Belfast

# VPN
WIREGUARD_PRIVATE_KEY=your_wireguard_private_key
WIREGUARD_ADDRESSES=10.2.0.2/32
SERVER_CITIES=London
FIREWALL_OUTBOUND_SUBNETS=192.168.1.0/24

# API Keys (obtain from each service's Settings > General after first start)
SONARR_API_KEY=your_sonarr_api_key
RADARR_API_KEY=your_radarr_api_key
CROSS_SEED_API_KEY=your_cross_seed_api_key
QBITTORRENT_PASSWORD=your_qbittorrent_password

# Plex
PLEX_CLAIM=claim-xxxxxxxxxxxxxxxxxxxx

# Monitoring
GLUETUN_NTFY_TOPIC=your_ntfy_topic
BESZEL_AGENT_KEY=your_beszel_ssh_public_key

# AudioMuse AI Music Analysis
AUDIOMUSE_NAVIDROME_USER=your_navidrome_username
AUDIOMUSE_NAVIDROME_PASSWORD=your_navidrome_password
AUDIOMUSE_AI_MODEL_PROVIDER=openai        # openai | gemini | mistral
AUDIOMUSE_OPENAI_API_KEY=your_openai_key
AUDIOMUSE_POSTGRES_USER=audiomuse
AUDIOMUSE_POSTGRES_PASSWORD=your_db_password
AUDIOMUSE_POSTGRES_DB=audiomuse

# Optional port overrides
SUGGESTARR_PORT=5000
KITANA_PORT=31337
TAUTULLI_PORT=8787
LOG_LEVEL=info
```

### First-Time Setup Order

Start services in this order to avoid dependency failures:

```bash
# 1. Start the services stack first (creates the shared network)
./stack-manage.sh services start

# 2. Start the torrent stack (Gluetun must come up healthy before *arr services)
./stack-manage.sh torrent start

# 3. Start the Plex stack
./stack-manage.sh plex start

# 4. Start the music stack
./stack-manage.sh music start
```

### First-Time Configuration Order

After all containers are running, configure in this order:

1. **Prowlarr** (`:9696`) — Add indexers. Add FlareSolverr proxy (`http://localhost:8191`) and tag it on Cloudflare-protected indexers.
2. **Sonarr** (`:8989`) — Add qBittorrent download client (`http://localhost:8080`). Connect Prowlarr.
3. **Radarr** (`:7878`) — Same as Sonarr.
4. **Lidarr** (`:8686`) — Same as Sonarr/Radarr. For music downloads.
5. **Bazarr** (`:6767`) — Connect Sonarr and Radarr. Add subtitle providers.
6. **Recyclarr** — API keys are read from `.env` automatically. Run once to apply: `./stack-manage.sh torrent restart recyclarr`
7. **Seerr** (`:5055`) — Connect to Plex, then connect Sonarr and Radarr.
8. **Maintainerr** (`:6246`) — Connect Plex and Seerr, then define cleanup rules.
9. **Tautulli** (`:8787`) — Configure notification agent to call `/scripts/plex-qbit-manager.py` on playback start/stop events (pauses torrents during Plex streams).

---

## Operations Reference

### stack-manage.sh

The primary operations tool. Wraps `docker compose` commands for each stack:

```bash
./stack-manage.sh <stack> <action> [service]

# Stacks: services | torrent | plex | music | all
# Actions: start | stop | restart | down | pull | update | logs | status | health
```

**Common operations:**

```bash
# View live logs for a service
./stack-manage.sh torrent logs sonarr

# Restart a single service (force-recreate, picks up .env changes)
./stack-manage.sh torrent restart radarr

# Update all services in a stack (pull + recreate)
./stack-manage.sh torrent update

# Update all stacks
./stack-manage.sh all update

# Check health status across all stacks
./stack-manage.sh torrent health
./stack-manage.sh services health

# Bring down a stack completely
./stack-manage.sh torrent down
```

### Cron Jobs

```bash
# Install the crontab environment preamble (run once on a new host)
./cron-setup.sh

# Register the daily stack update job (self-registers, safe to re-run)
./scripts/cron-jobs/update-all-stacks.sh

# Register the daily S3 disaster-recovery backup job (self-registers, safe to re-run)
./scripts/cron-jobs/backup-to-s3.sh --install
```

The daily update job runs at midnight UK time (`CRON_TZ=Europe/London`) and calls `bash stack-manage.sh all update`. The S3 backup job runs at 02:00 UK time — two hours later, so containers have fully settled after the update before their configs are archived.

### backup-config.sh

Creates a timestamped backup of all service configurations:

```bash
./backup-config.sh
# Output: config-backups/config-backup-YYYY-MM-DD_HH-MM-SS.tar.gz
```

Includes: all service configs, docker-compose files, `.env`. Excludes: media files, logs, and cache. Retains the 5 most recent backups automatically.

### Disaster Recovery — off-host S3 backups

`backup-config.sh` only writes to the local disk. For true disaster recovery (VM loss, disk failure), config archives are also pushed **off-host** to AWS S3, **client-side encrypted** via an rclone `crypt` remote — so the `.env` (VPN keys, API tokens) and every other config is unreadable in the bucket even if the bucket leaks.

**Components:**

| Script | Purpose |
|---|---|
| `scripts/install-rclone.sh` | Idempotent rclone installer (official static binary). |
| `scripts/cron-jobs/backup-to-s3.sh` | Builds a fresh archive, uploads it encrypted to S3. `--install` self-registers the daily cron job; `--dry-run` previews without uploading. |
| `scripts/restore-from-s3.sh` | Lists / downloads / decrypts / verifies a remote archive and prints the rehydration runbook. `--list`, `--archive NAME`, `--dry-run`. |

**Setup (one-time, per host):**

```bash
# 1. Install rclone
./scripts/install-rclone.sh

# 2. Configure TWO rclone remotes with `rclone config`:
#
#    s3-dr        (type: s3, provider: AWS)
#      region              = eu-west-2
#      location_constraint = eu-west-2
#      access_key_id       = <IAM user key>      # entered interactively
#      secret_access_key   = <IAM user secret>   # never stored in the repo
#      server_side_encryption / sse_kms_key_id = (leave empty)
#      storage_class       = (Default — S3 lifecycle handles tiering)
#      no_check_bucket     = true                # REQUIRED: scoped IAM has no CreateBucket
#
#    s3-dr-crypt  (type: crypt)
#      remote                    = s3-dr:your-dr-bucket/torrent-vm
#      filename_encryption       = standard
#      directory_name_encryption = true
#      password + salt           = <your choice — store OFF the VM>

# 3. Verify the crypt round-trip
echo test > /tmp/t.txt && rclone copy /tmp/t.txt s3-dr-crypt: \
  && rclone cat s3-dr-crypt:t.txt \
  && rclone ls s3-dr:your-dr-bucket/torrent-vm   # filename should be obfuscated
rclone delete s3-dr-crypt:t.txt && rm /tmp/t.txt

# 4. Register the daily backup cron job
./scripts/cron-jobs/backup-to-s3.sh --install
```

> **If uploads fail with `AccessDenied ... s3:CreateBucket`**, the base remote is missing `no_check_bucket = true`. Fix with:
> `rclone config update s3-dr no_check_bucket true`
> (This is expected with a least-privilege IAM policy that grants no bucket-level create.)

**AWS setup:** bucket `your-dr-bucket` (region `eu-west-2`, Block Public Access ON, versioning ON, default SSE-S3). A least-privilege IAM policy scoped to the `torrent-vm/` prefix:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "ListBucket", "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetBucketLocation"],
      "Resource": "arn:aws:s3:::your-dr-bucket" },
    { "Sid": "ObjectRW", "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:GetObject"],
      "Resource": "arn:aws:s3:::your-dr-bucket/torrent-vm/*" }
  ]
}
```

Remote **retention is owned by an S3 lifecycle rule**, not the host. The *intended* design is append-only: `s3:DeleteObject` is **not** in the policy above, so a compromised VM key cannot delete recovery points. A lifecycle rule on the `torrent-vm/` prefix transitions old archives to cheaper storage and expires noncurrent versions.

> **Tip:** verify your live IAM policy is actually append-only — a policy that still grants `s3:DeleteObject` lets a compromised host key wipe your backups. Test with a throwaway object: upload it, attempt `rclone delete`, and confirm the delete is denied.

> ⚠️ **The crypt password is your single point of failure.** Store it (and the salt) in a password manager **off the VM**. Lose it and the S3 backups are permanently unrecoverable — that is inherent to client-side encryption.

**Restore (rebuilding the torrent VM from scratch):**

```bash
./scripts/install-rclone.sh          # then re-create the two remotes as above
./scripts/restore-from-s3.sh --list  # see what's available
./scripts/restore-from-s3.sh         # download + decrypt + verify newest, then follow the printed steps
```

The restore script stops at the extracted config and prints the manual `stack-manage.sh all down` → copy into `/var/lib/homelab-media-configs/` → restore compose + `.env` → `stack-manage.sh all start` sequence, so you stay in control of the final overwrite.

### analyze-docker-logs.sh

Scans logs across all stacks for errors and warnings:

```bash
./analyze-docker-logs.sh --since 24h
# Reports error/warning counts per container with recent samples

./analyze-docker-logs.sh --service sonarr --grep "timeout" --context 2
# Search a single container with grep context

./analyze-docker-logs.sh --level error --summary-only --json
# Cron/dashboard-friendly output: errors only, counts only, NDJSON
```

Categories tracked: `auth`, `network`, `database`, `disk`, `permissions`. See `--help` for the full flag list.

### scripts/healthcheck.sh

Verifies every service defined in any `docker-compose-*.yml` is currently running. Exits non-zero on missing services — wire into cron + paging.

```bash
./scripts/healthcheck.sh           # human-readable
./scripts/healthcheck.sh --json    # single-line JSON for dashboards
```

### scripts/disk-report.sh

Reports disk usage of monitored mounts (defaults: `/mnt/media`, `/var/lib/homelab-media-configs`, `/var/lib/docker`) and exits non-zero past a configurable threshold.

```bash
./scripts/disk-report.sh --threshold 85
```

### Useful Docker Commands

```bash
# Check Gluetun VPN is working (should show VPN IP, not home IP)
docker exec gluetun wget -qO- https://ipinfo.io/ip

# View cascade restart monitor logs
docker logs -f gluetun-monitor

# Manually trigger a cascade restart (e.g. after Gluetun update)
docker restart gluetun

# Check which port Proton forwarded (for qBittorrent)
docker exec gluetun cat /tmp/gluetun/forwarded_port

# Check active Plex stream count (plex-qbit-manager state)
docker exec tautulli cat /config/logs/plex-qbit-sessions.count

# Query logs from the CLI (if logcli installed) or use Grafana Explore
docker logs -f promtail        # confirm Promtail is scraping
docker logs -f loki            # confirm Loki ingest/ruler
curl -s http://localhost:3100/ready   # Loki readiness
```

---

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| All torrent services show unhealthy | Gluetun VPN not connected | `docker logs gluetun` — check credentials and server availability |
| Sonarr/Radarr can't reach qBittorrent | Network namespace stale after Gluetun restart | Wait for gluetun-monitor to cascade restart, or manually: `./stack-manage.sh torrent restart` |
| Indexers returning no results | Cloudflare blocking | Verify FlareSolverr is healthy: `docker logs flaresolverr`. Check proxy tag in Prowlarr |
| RAR archives not extracted | Unpackerr not polling | Check `docker logs unpackerr`. Verify API keys in `.env` match Sonarr/Radarr |
| Wrong quality profiles | Recyclarr out of sync | `./stack-manage.sh torrent restart recyclarr` — view logs to see sync result |
| qBittorrent seeding stuck at 0 connections | VPN port not forwarded | Check `docker logs gluetun` for port forwarding messages. Proton requires port forwarding to be enabled on the server |
| Plex can't find media | Hardlink path mismatch | Verify Sonarr/Radarr root folders are `/data/tv` and `/data/movies`. qBit must also use `/data/downloads` |
| gluetun-monitor in restart loop | Gluetun instability | Monitor pauses for 1 hour after 5 restarts/hour. Check `docker logs gluetun-monitor` and ntfy for the loop detection alert |
| Seerr not showing Plex content | Plex not connected | Re-authenticate Plex in Seerr settings. Plex token may have expired |
| Torrents not resuming after Plex stops | Stream counter mismatch | Check `/config/logs/plex-qbit-sessions.count` in the Tautulli container. Reset to `0` if stuck |

---

## Security Considerations

- **VPN kill switch** (`FIREWALL=on`) ensures no torrent traffic leaks if the VPN drops. All download services are completely offline without VPN connectivity.
- **`.env` file** contains WireGuard private key and API keys. Never commit `.env` to a public repository. The `.gitignore` excludes it by default.
- **API keys** are passed via environment variables from `.env`. They are not embedded in the compose files.
- **Docker socket access** is granted to Autoheal, gluetun-monitor, and Portainer. These are mounted read-only where possible (`gluetun-monitor` mounts `:ro`). Be aware that Docker socket access is effectively root on the host.
- **Tautulli scripts** — the scripts directory is mounted read-only into Tautulli. Credentials are injected via environment variables, not hardcoded.
- **Rotation** — if this repo is ever made public, rotate all API keys and the WireGuard private key immediately.
