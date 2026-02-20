# Architecture Diagrams

## 1. Main System Overview

All services, stacks, networks, and their connections at a glance.

```mermaid
graph TB
    subgraph INTERNET["☁️ Internet"]
        TRACKERS["Torrent Trackers"]
        INDEXERS["Indexers (Nyaa, etc.)"]
        PROV["Proton VPN\n(WireGuard)"]
        NTFY["ntfy.sh\n(Push Notifications)"]
    end

    subgraph HOST["🖥️ Host Machine (homelab server)"]
        subgraph TORRENT_STACK["📦 Torrent Stack  (homelab-torrent)"]
            subgraph VPN_NS["🔒 Gluetun VPN Namespace"]
                GLUETUN["Gluetun\n(WireGuard gateway)\n:8080/:8989/:7878\n/:9696/:6767/:8191/:2468"]
                QB["qBittorrent\n:8080"]
                SONARR["Sonarr\n:8989"]
                RADARR["Radarr\n:7878"]
                PROWLARR["Prowlarr\n:9696"]
                BAZARR["Bazarr\n:6767"]
                FLARE["FlareSolverr\n:8191"]
                UNPACKERR["Unpackerr"]
                RECYCLARR["Recyclarr"]
                CROSSSEED["cross-seed\n:2468"]
            end
        end

        subgraph PLEX_STACK["📺 Plex Stack  (homelab-plex)"]
            PLEX["Plex\n(host network)\n:32400"]
            SUGGESTARR["SuggestArr\n:5000"]
            KITANA["Kitana\n:31337"]
            TAUTULLI["Tautulli\n:8787"]
        end

        subgraph SERVICES_STACK["⚙️ Services Stack  (homelab-services)"]
            SEERR["Seerr\n:5055"]
            MAINTAINERR["Maintainerr\n:6246"]
            FILEBROWSER["Filebrowser\n:8181"]
            AUTOHEAL["Autoheal\n(watchdog)"]
            GLUETUN_MON["gluetun-monitor\n(cascade restarter)"]
            WUD["What's Up Docker\n:3000"]
            WUD_WEBHOOK["wud-webhook\n:8182"]
            PORTAINER["Portainer\n:9443"]
            BESZEL["Beszel\n:8090"]
        end

        subgraph SHARED_NET["🌐 homelab_media_network (bridge)"]
        end

        subgraph STORAGE["💾 Storage"]
            MEDIA["/mnt/media\n(movies, tv, downloads)"]
            CONFIGS["/var/lib/homelab-media-configs\n(all app configs)"]
        end

        DOCKER_SOCK["/var/run/docker.sock"]
    end

    %% Internet connections
    GLUETUN <-->|"WireGuard tunnel"| PROV
    QB -->|"all torrent traffic\nvia VPN"| TRACKERS
    PROWLARR -->|"all indexer traffic\nvia VPN"| INDEXERS
    GLUETUN_MON -->|"push alerts"| NTFY
    WUD -->|"push alerts"| NTFY

    %% VPN namespace internal (localhost)
    GLUETUN --- QB & SONARR & RADARR & PROWLARR & BAZARR & FLARE & UNPACKERR & RECYCLARR & CROSSSEED

    %% Automation connections (localhost within VPN namespace)
    PROWLARR -->|"RSS/search"| SONARR & RADARR
    FLARE -->|"CF bypass"| PROWLARR
    SONARR & RADARR -->|"grab torrents"| QB
    UNPACKERR -->|"poll API"| SONARR & RADARR
    RECYCLARR -->|"sync profiles"| SONARR & RADARR
    CROSSSEED -->|"match torrents"| QB

    %% Cross-stack connections
    SEERR -->|"requests"| SONARR & RADARR
    SONARR & RADARR -->|"notify on import"| BAZARR
    PLEX -->|"library"| MEDIA
    SUGGESTARR -->|"recommendations"| SEERR
    TAUTULLI -->|"play stats"| PLEX
    KITANA -->|"plugin mgmt"| PLEX
    MAINTAINERR -->|"cleanup rules"| PLEX & SEERR

    %% Self-healing & monitoring
    AUTOHEAL -->|"restart unhealthy\ncontainers"| DOCKER_SOCK
    GLUETUN_MON -->|"watch events"| DOCKER_SOCK
    WUD -->|"detect image updates"| DOCKER_SOCK
    WUD -->|"POST webhook"| WUD_WEBHOOK
    WUD_WEBHOOK -->|"docker pull + recreate"| DOCKER_SOCK

    %% Storage
    QB & SONARR & RADARR & BAZARR & UNPACKERR --> MEDIA
    PLEX --> MEDIA
    SERVICES_STACK -.-> CONFIGS

    %% Network membership
    TORRENT_STACK -.-> SHARED_NET
    PLEX_STACK -.-> SHARED_NET
    SERVICES_STACK -.-> SHARED_NET
```

---

## 2. Media Request Flow

End-to-end journey from a user requesting media to it appearing in Plex.

```mermaid
sequenceDiagram
    actor User
    participant Seerr as Seerr<br/>(Request UI :5055)
    participant Sonarr as Sonarr / Radarr<br/>(*arr :8989/:7878)
    participant Prowlarr as Prowlarr<br/>(Indexer :9696)
    participant FlareSolverr as FlareSolverr<br/>(CF bypass :8191)
    participant qBit as qBittorrent<br/>(:8080)
    participant Unpackerr as Unpackerr<br/>(archive extractor)
    participant Bazarr as Bazarr<br/>(subtitles :6767)
    participant Plex as Plex<br/>(:32400)

    User->>Seerr: Request TV show / movie
    Seerr->>Sonarr: Send media request via API
    Sonarr->>Prowlarr: Search all configured indexers
    alt Cloudflare-protected indexer (e.g. Nyaa)
        Prowlarr->>FlareSolverr: Relay request for CAPTCHA bypass
        FlareSolverr-->>Prowlarr: Return solved response
    end
    Prowlarr-->>Sonarr: Return ranked torrent results
    Sonarr->>Sonarr: Apply quality profile scoring<br/>(custom formats, Recyclarr profiles)
    Sonarr->>qBit: Send best torrent + save path
    Note over qBit: All traffic routed through<br/>Gluetun VPN (WireGuard)
    qBit->>qBit: Download torrent
    qBit-->>Sonarr: Notify on completion (webhook)
    alt Release is a RAR archive
        Unpackerr->>Sonarr: Poll API for completed downloads
        Unpackerr->>Unpackerr: Extract RAR → video files
    end
    Sonarr->>Sonarr: Rename + hardlink to /data/tv
    Sonarr->>Bazarr: Trigger subtitle search
    Bazarr->>Bazarr: Download subtitles from providers
    Sonarr-->>Plex: Refresh library (API call)
    Plex->>Plex: Scan & index new media
    Plex-->>User: Media available for playback
```

---

## 3. VPN Auto-Healing Flow

How the system detects and recovers from a Gluetun VPN restart without manual intervention.

```mermaid
sequenceDiagram
    participant Docker as Docker Engine
    participant Monitor as gluetun-monitor<br/>(cascade restarter)
    participant Gluetun as Gluetun<br/>(VPN gateway)
    participant Services as VPN-dependent Services<br/>(qBit, Sonarr, Radarr, etc.)
    participant Ntfy as ntfy.sh<br/>(push notifications)

    Note over Gluetun: Gluetun restarts<br/>(update, crash, or manual)
    Docker->>Monitor: Emit "container start" event for gluetun

    Monitor->>Monitor: Check debounce cooldown (30s)<br/>Check restart rate limit (max 5/hr)
    Monitor->>Monitor: Compare network namespace<br/>(SandboxKey) — confirms real restart

    Monitor->>Gluetun: Poll health status every 5s
    loop Wait for healthy (up to 300s)
        Gluetun-->>Monitor: status = starting / unhealthy
    end
    Gluetun-->>Monitor: status = healthy ✅

    Note over Services: All VPN-dependent containers<br/>have a stale network namespace
    Monitor->>Services: docker stop + docker rm (each service)
    Monitor->>Monitor: Wait 5s for cleanup

    Monitor->>Docker: docker compose up -d<br/>(qBit, Sonarr, Radarr, Prowlarr,<br/>Bazarr, FlareSolverr, Unpackerr,<br/>Recyclarr, cross-seed)
    Docker->>Services: Recreate containers in Gluetun<br/>network namespace

    Monitor->>Monitor: Wait 30s for initialization
    Monitor->>Services: Verify all healthchecks pass

    alt All services healthy
        Monitor->>Ntfy: ✅ "Cascade restart successful in Xs"
    else Some services unhealthy
        Monitor->>Ntfy: ⚠️ "Cascade restart — some services unhealthy"
    end

    alt All 3 retry attempts failed
        Monitor->>Ntfy: 🚨 "Cascade restart FAILED — manual intervention required"
    end

    alt 5+ restarts in past hour detected
        Monitor->>Ntfy: 🚨 "RESTART LOOP DETECTED — pausing 1 hour"
        Monitor->>Monitor: Sleep 3600s
    end
```

---

## 4. Container Auto-Update Flow

How What's Up Docker (WUD) detects, notifies, and automatically applies container image updates.

```mermaid
sequenceDiagram
    participant Registry as Container Registry<br/>(ghcr.io, dockerhub, lscr.io)
    participant WUD as What's Up Docker<br/>(:3000)
    participant Ntfy as ntfy.sh<br/>(batch notification)
    participant Webhook as wud-webhook server<br/>(Python :8182)
    participant Handler as wud-update-handler.sh
    participant StackManage as stack-manage.sh
    participant Docker as Docker Engine

    Note over WUD: Daily cron at 06:00
    WUD->>Registry: Check all watched container image tags
    Registry-->>WUD: Return latest digest/tag per image

    WUD->>WUD: Compare with current running tag

    alt Update(s) available
        WUD->>Ntfy: Batch notification:<br/>"N containers have updates available"
        loop For each updated container
            WUD->>Webhook: POST /  with container name, image, new tag
            Webhook->>Webhook: Parse JSON payload<br/>Strip stack prefix from container name
            Webhook->>Handler: Pipe JSON to wud-update-handler.sh (stdin)
            Handler->>Handler: Map container → stack + service name
            Handler->>StackManage: cd /homelab && ./stack-manage.sh <stack> update <service>
            StackManage->>Docker: docker compose pull <service>
            StackManage->>Docker: docker compose up -d --force-recreate <service>
            Docker-->>Handler: Exit code 0 (success) or 1 (failure)
            alt Update succeeded
                Handler->>Ntfy: ✅ "Successfully updated <container>"
            else Update failed
                Handler->>Ntfy: ❌ "Failed to update <container> — check logs"
            end
        end
    end
```

---

## 5. Network Topology

How containers are arranged across three distinct network boundaries.

```mermaid
graph LR
    subgraph HOST["🖥️ Host Network Namespace"]
        PLEX_HOST["Plex\n(network_mode: host)\n:32400"]
        PTS["plex-trakt-sync\n(network_mode: host)\n(manual profile only)"]
    end

    subgraph VPN_NS["🔒 Gluetun VPN Network Namespace\n(shared via network_mode: service:gluetun)"]
        direction TB
        GL["Gluetun\n(WireGuard tun0)\nPublic IP: Proton VPN"]
        QB2["qBittorrent\n@localhost:8080"]
        SN["Sonarr\n@localhost:8989"]
        RD["Radarr\n@localhost:7878"]
        PW["Prowlarr\n@localhost:9696"]
        BZ["Bazarr\n@localhost:6767"]
        FS["FlareSolverr\n@localhost:8191"]
        UN["Unpackerr"]
        RC["Recyclarr"]
        CS["cross-seed\n@localhost:2468"]
        GL --- QB2 & SN & RD & PW & BZ & FS & UN & RC & CS
    end

    subgraph BRIDGE["🌐 homelab_media_network (bridge)\nSubnet: 172.19.0.0/16"]
        direction TB
        SEERR2["Seerr\n:5055"]
        MAINT["Maintainerr\n:6246"]
        FB["Filebrowser\n:8181"]
        AH["Autoheal"]
        GM["gluetun-monitor"]
        WUD2["What's Up Docker\n:3000"]
        WUDWH["wud-webhook\n:8182"]
        PORT["Portainer\n:9443"]
        BSZ["Beszel\n:8090"]
        PLEX2["Plex stack services\n(Suggestarr, Kitana,\nTautulli)"]
    end

    subgraph EXTERNAL["☁️ External"]
        VPN_EP["Proton VPN Endpoint\n(London WireGuard)"]
        LAN["Local Network\n192.168.1.0/24"]
        USERS["Users / Browsers"]
    end

    GL <-->|"WireGuard\nencrypted tunnel"| VPN_EP
    VPN_NS <-->|"Ports exposed via\nGluetun container:\n8080, 8989, 7878,\n9696, 6767, 8191, 2468"| BRIDGE
    BRIDGE <-->|"Bridge NAT"| LAN
    HOST <-->|"Direct host\nnetwork access"| LAN
    USERS -->|"HTTP"| LAN

    style VPN_NS fill:#1a1a2e,color:#e0e0ff,stroke:#6060ff
    style HOST fill:#1a2e1a,color:#e0ffe0,stroke:#60ff60
    style BRIDGE fill:#2e1a1a,color:#ffe0e0,stroke:#ff6060
    style EXTERNAL fill:#2e2e1a,color:#ffffe0,stroke:#ffff60
```

**Key network rules enforced by Gluetun firewall:**

| Rule | Detail |
|------|--------|
| Kill switch | `FIREWALL=on` — no traffic leaves if VPN drops |
| Allowed outbound | `FIREWALL_OUTBOUND_SUBNETS=192.168.1.0/24,172.19.0.0/16` (LAN + bridge) |
| DNS | Cloudflare `1.1.1.1` (DoT disabled for compatibility) |
| Port forwarding | `VPN_PORT_FORWARDING=on` — dynamic port assigned by Proton, pushed to qBit via API |
| MTU | `WIREGUARD_MTU=1280` (conservative for tunnel stability) |
