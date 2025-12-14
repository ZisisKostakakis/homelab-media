# Portainer Stack Import Guide

This guide shows how to import your existing Docker Compose stacks into Portainer for full management control.

---

## 🎯 Goal

Convert your CLI-managed stacks into Portainer-managed stacks so you can:
- ✅ Update containers from Portainer UI
- ✅ Edit stack configurations easily
- ✅ View logs and stats in one place
- ✅ Restart/stop/start services from the web interface

---

## ⚠️ Important: Prepare Your Environment Variables

**CRITICAL**: Portainer stacks need access to your `.env` file variables. You have two options:

### Option A: Use Portainer's Environment Variables (Recommended)
You'll manually add environment variables in Portainer's UI when creating each stack.

### Option B: Host the .env file in Git (Less Secure)
⚠️ **NOT RECOMMENDED** - Your `.env` contains secrets (API keys, VPN credentials)

**We'll use Option A** in this guide.

---

## 📋 Environment Variables You'll Need

Copy these values from your `.env` file - you'll paste them into Portainer:

```bash
# View your current env values (SAVE THESE - you'll need them!)
cat /root/Github/homelab-media/.env
```

**Key variables:**
- `WIREGUARD_PRIVATE_KEY`
- `WIREGUARD_ADDRESSES`
- `SERVER_CITIES`
- `FIREWALL_OUTBOUND_SUBNETS`
- `SONARR_API_KEY`
- `RADARR_API_KEY`
- `PLEX_CLAIM`
- `PUID=1000`
- `PGID=1000`
- `TZ=Europe/London`
- `TZ_MAINTAINERR=Europe/Belfast`

---

## 🔄 Import Process Overview

1. Stop existing CLI stacks
2. Create stacks in Portainer (one at a time)
3. Configure environment variables
4. Deploy stacks from Portainer

---

## 📝 Step-by-Step Instructions

### Step 0: Backup Current Setup

```bash
# Backup your current config
./backup-config.sh

# Save your environment variables
cp .env .env.backup
```

### Step 1: Stop Existing Stacks

```bash
cd /root/Github/homelab-media

# Stop all stacks (doesn't remove volumes/data)
./stack-manage.sh all down
```

**Verify they're stopped:**
```bash
docker compose ls
# Should show: No stacks running
```

---

### Step 2: Import Stack 1 - homelab-services

1. **Login to Portainer**: `https://<your-server-ip>:9443`

2. **Navigate to Stacks**:
   - Click **Stacks** in the left sidebar
   - Click **+ Add stack**

3. **Configure Stack**:
   - **Name**: `homelab-services` (exactly this name!)
   - **Build method**: Choose **Repository**

4. **Repository Configuration**:
   ```
   Repository URL: https://github.com/ZisisKostakakis/homelab-media
   Repository reference: refs/heads/main
   Compose path: docker-compose-services.yml
   ```

5. **Environment Variables**:
   Click **+ Add environment variable** and add these:
   ```
   PUID=1000
   PGID=1000
   TZ=Europe/London
   TZ_MAINTAINERR=Europe/Belfast
   ```

6. **Deploy the stack**:
   - ✅ Enable "Re-pull image" (optional)
   - Click **Deploy the stack**

7. **Wait for deployment** (2-3 minutes)

---

### Step 3: Import Stack 2 - homelab-torrent

1. **Add new stack**:
   - Click **Stacks** → **+ Add stack**

2. **Configure Stack**:
   - **Name**: `homelab-torrent`
   - **Build method**: **Repository**

3. **Repository Configuration**:
   ```
   Repository URL: https://github.com/ZisisKostakakis/homelab-media
   Repository reference: refs/heads/main
   Compose path: docker-compose-torrent.yml
   ```

4. **Environment Variables** (⚠️ IMPORTANT - Add ALL of these):
   ```
   PUID=1000
   PGID=1000
   TZ=Europe/London
   WIREGUARD_PRIVATE_KEY=<your key from .env>
   WIREGUARD_ADDRESSES=10.2.0.2/32
   SERVER_CITIES=London
   FIREWALL_OUTBOUND_SUBNETS=192.168.1.0/24
   SONARR_API_KEY=<your key from .env>
   RADARR_API_KEY=<your key from .env>
   ```

5. **Deploy the stack**

6. **Verify VPN is working**:
   ```bash
   # Check VPN IP (should be ProtonVPN IP, not your real IP)
   docker exec gluetun wget -qO- https://ipinfo.io/ip
   ```

---

### Step 4: Import Stack 3 - homelab-plex

1. **Add new stack**:
   - **Name**: `homelab-plex`
   - **Build method**: **Repository**

2. **Repository Configuration**:
   ```
   Repository URL: https://github.com/ZisisKostakakis/homelab-media
   Repository reference: refs/heads/main
   Compose path: docker-compose-plex.yml
   ```

3. **Environment Variables**:
   ```
   PUID=1000
   PGID=1000
   TZ=Europe/London
   PLEX_CLAIM=<get new claim token from https://www.plex.tv/claim/>
   ```

   ⚠️ **Note**: Plex claim tokens expire after 4 minutes. Get a fresh one right before deploying.

4. **Deploy the stack**

---

## ✅ Verification

After importing all three stacks:

### Check Stacks in Portainer
1. Go to **Stacks** - you should see:
   - ✅ homelab-services (6 containers)
   - ✅ homelab-torrent (10 containers)
   - ✅ homelab-plex (2 containers)

2. Each stack should show **"Running"** status

### Verify Containers
Go to **Containers** - you should see 18 running containers:

**homelab-services:**
- overseerr
- maintainerr
- filebrowser
- wud
- autoheal
- portainer

**homelab-torrent:**
- gluetun
- qbittorrent
- sonarr
- radarr
- prowlarr
- bazarr
- flaresolverr
- unpackerr
- recyclarr
- cross-seed

**homelab-plex:**
- plex
- SuggestArr

### Test VPN Protection
```bash
# Should show ProtonVPN IP (79.127.146.9 or similar)
docker exec gluetun wget -qO- https://ipinfo.io/ip

# Should NOT show your real IP (31.48.129.129)
```

### Test Services
Visit these URLs to verify everything works:
- Overseerr: `http://<your-ip>:5055`
- Plex: `http://<your-ip>:32400/web`
- qBittorrent: `http://<your-ip>:8080`
- Sonarr: `http://<your-ip>:8989`
- Radarr: `http://<your-ip>:7878`

---

## 🎨 Managing Stacks in Portainer

### Update a Stack
1. Go to **Stacks** → Click stack name
2. Click **Editor** tab
3. Make changes or enable **"Re-pull image and redeploy"**
4. Click **Update the stack**

### Update a Single Container
1. Go to **Containers** → Find container
2. Click container name
3. Click **Recreate** or **Duplicate/Edit**
4. Enable **Pull latest image**
5. Click **Deploy the container**

### View Logs
1. Go to **Containers** → Click container name
2. Click **Logs** tab
3. Use search and filtering options

### Restart Services
1. Go to **Containers**
2. Select container(s)
3. Click **Restart** or **Stop/Start**

---

## 🔧 Updating from Git

When you make changes to your compose files:

### Method 1: Update via Portainer UI
1. Push changes to GitHub:
   ```bash
   git add .
   git commit -m "Update configuration"
   git push origin main
   ```

2. In Portainer:
   - Go to **Stacks** → Click stack
   - Click **Pull and redeploy**
   - Portainer pulls latest from Git and updates

### Method 2: Webhook (Advanced)
Set up a webhook to auto-update when you push to Git:
1. In Portainer → Stack → Click **Webhook** icon
2. Copy the webhook URL
3. Add to GitHub repository webhooks
4. Now pushing to Git auto-updates Portainer!

---

## ⚠️ Important Notes

### Environment Variable Security
- ✅ `.env` file is **NOT** in Git (protected by .gitignore)
- ✅ Environment variables are stored in Portainer's database
- ⚠️ Anyone with Portainer access can see environment variables
- 🔒 Use Portainer's RBAC (Role-Based Access Control) in production

### Network Dependencies
- `homelab_media_network` is created by the `homelab-services` stack
- Deploy `homelab-services` **first**, then others
- All three stacks share this network for inter-service communication

### VPN Dependencies
- The `homelab-torrent` stack **must** have correct VPN credentials
- Double-check `WIREGUARD_PRIVATE_KEY` when setting up
- Test VPN immediately after deployment

### Updating Containers
When Portainer shows an update is available:
1. Check WUD at `http://<your-ip>:3000` to see what changed
2. Update via Portainer or CLI:
   ```bash
   # CLI method
   ./stack-manage.sh torrent update

   # Or use Portainer UI
   ```

---

## 🆘 Troubleshooting

### "Network homelab_media_network not found"
- **Cause**: `homelab-services` stack isn't running
- **Fix**: Deploy `homelab-services` stack first

### "Container names conflict"
- **Cause**: Old containers still running
- **Fix**:
  ```bash
  docker ps -a | grep -E "overseerr|sonarr|radarr|plex"
  docker rm -f <container-names>
  ```

### Environment variables not working
- **Cause**: Typo or missing variable
- **Fix**:
  1. Go to Stack → Editor
  2. Click "Environment variables" section
  3. Verify all variables are present and correct

### VPN not connecting
- **Check**:
  ```bash
  docker logs gluetun --tail 50
  ```
- **Common issues**:
  - Wrong `WIREGUARD_PRIVATE_KEY`
  - ProtonVPN account expired
  - Server location unavailable

### "Limited control" message still appears
- **Cause**: Stack was created with `docker compose` CLI, not Portainer
- **Fix**: Delete the stack in Portainer and recreate it using the steps above
  - This gives Portainer full control

---

## 📚 Additional Resources

- **Portainer Documentation**: https://docs.portainer.io/
- **Docker Compose Reference**: https://docs.docker.com/compose/
- **Your GitHub Repo**: https://github.com/ZisisKostakakis/homelab-media

---

## ✅ Success Checklist

After import, verify:
- [ ] All 3 stacks show "Running" in Portainer
- [ ] 18 containers are healthy
- [ ] VPN shows ProtonVPN IP (not your real IP)
- [ ] WUD is accessible at port 3000
- [ ] Overseerr, Plex, Sonarr, Radarr are accessible
- [ ] You can update stacks from Portainer UI
- [ ] You can view logs from Portainer UI
- [ ] No "limited control" warnings

---

**Once imported, you'll have full control over your stacks through Portainer!** 🎉
