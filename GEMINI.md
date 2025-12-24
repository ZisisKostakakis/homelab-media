# GEMINI.md: Homelab Media Automation Stack

This document provides a comprehensive overview of the Homelab Media Automation Stack project, intended to be used as a context for AI-driven development and maintenance.

## Project Overview

This is a non-code project that defines a comprehensive media automation stack using Docker. The goal is to create a secure, automated system for downloading, managing, and serving media content.

The stack is composed of several services, each containerized using Docker and managed with Docker Compose. The services are split into three logical stacks:

*   **`services`**: User-facing and management services that do not require a VPN connection.
*   **`torrent`**: The core download and automation services, all of which are routed through a VPN for security.
*   **`plex`**: The Plex media server for serving content.

The project is designed to be highly automated, with features like automatic archive extraction, quality profile syncing, and Cloudflare bypass for indexers.

## Key Technologies

*   **Containerization**: Docker and Docker Compose
*   **VPN**: Gluetun (with Proton VPN)
*   **Downloaders**: qBittorrent
*   **Automation**: Sonarr, Radarr, Bazarr
*   **Indexer Management**: Prowlarr
*   **Media Server**: Plex
*   **Utilities**: Unpackerr, Recyclarr, FlareSolverr, Overseerr, Maintainerr, What's Up Docker (WUD)

## Building and Running

The project is managed with a helper script `stack-manage.sh` and a bootstrap script `homelab-media-bootstrap.sh`.

### Initial Setup

1.  **Install Docker**: Run the `install-docker.sh` script to install Docker and Docker Compose.
2.  **Configure Environment**: Copy the `.env.example` file to `.env` and fill in the required environment variables. This includes settings for `PUID`, `PGID`, `TZ`, VPN credentials, and API keys.
3.  **Bootstrap the Stack**: Run the `homelab-media-bootstrap.sh` script to create the necessary directories, pull the Docker images, and start all the services.

### Managing the Stack

The `stack-manage.sh` script is used to manage the individual stacks (`services`, `torrent`, `plex`) or all stacks at once.

**Usage:**

```bash
./stack-manage.sh <stack> <action> [service]
```

**Stacks:**

*   `services`: User-facing services (Overseerr, Maintainerr, WUD, etc.)
*   `torrent`: VPN and download automation (Gluetun, qBit, *arr)
*   `plex`: Media server (Plex, SuggestArr)
*   `all`: All stacks

**Actions:**

*   `start`: Start the stack/service
*   `stop`: Stop the stack/service
*   `restart`: Restart the stack/service
*   `down`: Stop and remove containers
*   `pull`: Pull latest images
*   `update`: Pull images and recreate containers
*   `logs`: Show logs (last 50 lines)
*   `status`: Show container status

**Examples:**

*   `./stack-manage.sh services restart`: Restart the entire services stack.
*   `./stack-manage.sh torrent logs qbittorrent`: View logs for qBittorrent.
*   `./stack-manage.sh all update`: Update all stacks.

## Development Conventions

*   **Modular Stacks**: The services are split into logical stacks based on their function and networking requirements.
*   **Environment Variables**: All configuration is done through environment variables, with a template provided in `.env.example`.
*   **Backup**: The `backup-config.sh` script is provided to back up the configurations of the services.
*   **Portainer Integration**: The project can be imported into Portainer using the `portainer-env-template.txt` and the instructions in `PORTAINER-IMPORT-GUIDE.md`.
*   **Automated Updates**: The `whatsupdocker` (WUD) service is configured to automatically update containers via a webhook.
*   **Healthchecks**: Most services have healthchecks defined in the Docker Compose files to ensure they are running correctly.
*   **Security**: All torrent traffic is routed through a VPN with a kill switch, and the services are separated into different networks.
