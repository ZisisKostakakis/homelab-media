# VPN Security & Anonymity Report
**Generated:** 2025-12-12
**Stack:** Homelab Media (Gluetun + ProtonVPN)

---

## ✅ SECURITY STATUS: PROTECTED

Your VPN setup is **properly configured** and **protecting your privacy**.

---

## 📊 Test Results Summary

| Test | Status | Details |
|------|--------|---------|
| **VPN Connection** | ✅ PASS | Connected to ProtonVPN London |
| **IP Leak Protection** | ✅ PASS | Real IP hidden, VPN IP exposed |
| **DNS Leak Protection** | ✅ PASS | Using Cloudflare DNS (1.1.1.1) |
| **Kill Switch** | ✅ PASS | Firewall active, default DROP policy |
| **Port Forwarding** | ✅ PASS | Port 34696 forwarded |
| **Service Isolation** | ✅ PASS | All download services behind VPN |

---

## 🌍 IP Address Information

### Your Real IP (Hidden)
```
IP Address:  31.48.129.129
Location:    Belfast, Northern Ireland, GB
ISP:         British Telecommunications PLC (BT)
Hostname:    host31-48-129-129.range31-48.btcentralplus.com
```
☝️ **This IP is NOT visible to trackers or external services.**

### VPN IP (Public-Facing)
```
IP Address:  79.127.146.9
Location:    London, England, GB
ISP:         Datacamp Limited (ProtonVPN)
Hostname:    unn-79-127-146-9.datapacket.com
Server:      ProtonVPN - London
```
☝️ **This is what the internet sees when you torrent.**

---

## 🔒 Security Features Verified

### 1. Kill Switch (Firewall)
- **Status**: ✅ ENABLED
- **Policy**: DROP by default (blocks all non-VPN traffic)
- **Configuration**:
  ```
  FIREWALL=on
  FIREWALL_OUTBOUND_SUBNETS=192.168.1.0/24,172.19.0.0/16
  ```
- **Protection**: If VPN disconnects, all torrent traffic is **automatically blocked**

### 2. DNS Leak Protection
- **Status**: ✅ NO LEAKS DETECTED
- **DNS Server**: 1.1.1.1 (Cloudflare)
- **Your ISP's DNS**: NOT USED
- **Verification**: All DNS queries go through VPN tunnel

### 3. Network Isolation
- **VPN Tunnel**: `tun0` (10.2.0.2)
- **Services Protected**:
  - qBittorrent ✅
  - Sonarr ✅
  - Radarr ✅
  - Prowlarr ✅
  - Bazarr ✅
  - FlareSolverr ✅
  - Unpackerr ✅
  - Recyclarr ✅
  - Cross-Seed ✅

- **Services NOT on VPN** (by design):
  - Overseerr ⚠️ (user-facing, doesn't need VPN)
  - Plex ⚠️ (media server, doesn't need VPN)
  - Maintainerr ⚠️ (management, doesn't need VPN)

### 4. Port Forwarding
- **Status**: ✅ ACTIVE
- **Forwarded Port**: 34696
- **Purpose**: Improves torrent connectivity and seeding
- **Security**: Port is only open through VPN tunnel

---

## 🛡️ Firewall Rules

### INPUT Chain
```
Policy: DROP (default deny)
Allowed:
  - Localhost traffic
  - Established/related connections
  - Docker network (172.18.0.0/16)
  - VPN tunnel (tun0) on port 34696
```

### OUTPUT Chain
```
Policy: DROP (default deny)
Allowed:
  - Localhost traffic
  - Established/related connections
  - Local network (192.168.1.0/24)
  - Docker networks (172.18.0.0/16, 172.19.0.0/16)
  - WireGuard to VPN server (79.127.146.1:51820)
  - All traffic via VPN tunnel (tun0)
```

---

## 🧪 Leak Test Results

### Multiple IP Check Services
| Service | Detected IP | Status |
|---------|-------------|--------|
| ipify.org | 79.127.146.9 | ✅ VPN IP |
| ifconfig.me | 79.127.146.9 | ✅ VPN IP |
| icanhazip.com | 79.127.146.9 | ✅ VPN IP |
| ipinfo.io | 79.127.146.9 | ✅ VPN IP |

**Result**: No IP leaks detected ✅

### DNS Resolution Test
```
DNS Server:  1.1.1.1 (Cloudflare, not BT ISP)
Test Query:  google.com
Result:      Resolved via Cloudflare DNS
```

**Result**: No DNS leaks detected ✅

---

## ⚠️ Important Notes

### What This Setup Protects
- ✅ Your **real IP address** is hidden from torrent trackers
- ✅ Your **ISP cannot see** what you're torrenting (only that you're using a VPN)
- ✅ **DNS queries** are encrypted and not visible to your ISP
- ✅ If VPN fails, torrent traffic **automatically stops** (kill switch)
- ✅ All automation services (Sonarr, Radarr, etc.) use the VPN

### What This Setup Does NOT Protect
- ⚠️ **Content of torrents**: Your ISP may still see encrypted VPN traffic volume
- ⚠️ **Account-based tracking**: If you login to trackers, they can still track your account
- ⚠️ **Legal responsibility**: VPN provides privacy, not legal immunity
- ⚠️ **Services outside Gluetun**: Overseerr, Plex, Maintainerr use your real IP (this is intentional)

### Recommendations
1. ✅ **Keep your VPN subscription active** - ProtonVPN connection required
2. ✅ **Monitor Gluetun logs** for connection issues: `docker logs gluetun`
3. ✅ **Check VPN status regularly**: Visit http://localhost:8000 (Gluetun control panel)
4. ✅ **Use private/semi-private trackers** for better privacy
5. ⚠️ **Don't disable the kill switch** - it's your safety net

---

## 🔍 How to Verify VPN is Working (Anytime)

### Quick Check
```bash
# Check if VPN is connected
docker exec gluetun wget -qO- https://ipinfo.io/ip

# Should show: 79.127.146.9 (or another ProtonVPN IP)
# Should NOT show: 31.48.129.129 (your real IP)
```

### Detailed Check
```bash
# View Gluetun logs
docker logs gluetun --tail 50

# Check firewall status
docker exec gluetun iptables -L -n | head -20

# Verify forwarded port
docker exec gluetun cat /tmp/gluetun/forwarded_port
```

### DNS Leak Test
```bash
# Check DNS server
docker exec sonarr cat /etc/resolv.conf | grep nameserver

# Should show: nameserver 1.1.1.1
# Should NOT show: Your ISP's DNS
```

---

## 📈 Performance Notes

- **VPN Connection**: WireGuard (faster than OpenVPN)
- **Server Location**: London (close to Belfast, minimal latency)
- **MTU Setting**: 1280 (optimized to prevent packet drops)
- **Keepalive**: 25 seconds (maintains connection stability)

---

## 🚨 Troubleshooting

### If VPN Disconnects
1. Check Gluetun logs: `docker logs gluetun --tail 100`
2. Verify ProtonVPN account is active
3. Check WireGuard credentials in `.env` file
4. Restart Gluetun: `./stack-manage.sh torrent restart`

### If Torrents Stop Working
1. Verify VPN is connected (check IP)
2. Check forwarded port: `docker exec gluetun cat /tmp/gluetun/forwarded_port`
3. Ensure qBittorrent is using the forwarded port
4. Check firewall rules allow the port

### If Services Can't Access Local Network
- Verify `FIREWALL_OUTBOUND_SUBNETS=192.168.1.0/24` matches your local subnet
- Check Gluetun environment variables: `docker inspect gluetun`

---

## ✅ Conclusion

Your homelab media stack is **securely configured** with proper VPN protection:

- **Privacy**: ✅ Real IP hidden from torrent swarms
- **Anonymity**: ✅ ISP cannot see torrent activity
- **Safety**: ✅ Kill switch prevents leaks if VPN fails
- **Performance**: ✅ Port forwarding active for optimal speeds

**Your setup is production-ready and secure.** 🎉

---

*Report generated by automated security audit*
*Last verified: 2025-12-12 08:56 GMT*
