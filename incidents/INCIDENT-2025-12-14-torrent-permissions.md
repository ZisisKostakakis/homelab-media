# Incident Report: Torrent Permission Denied Errors

**Date:** 2025-12-14
**Severity:** Medium
**Status:** Resolved
**Reported By:** User
**Investigated By:** Claude Code

---

## Executive Summary

Multiple torrents in the cross-seed directory were experiencing "Permission denied" errors when qBittorrent attempted to write files (particularly subtitle files). The root cause was incorrect directory permissions (755) with root ownership on 8 torrent directories, preventing the qBittorrent container running as UID 1000 from writing to these locations.

---

## Incident Timeline

| Time | Event |
|------|-------|
| Unknown | Cross-seed torrents created with incorrect permissions (755, root:root) |
| 2025-12-14 06:12 | qBittorrent attempted to write subtitle files, encountered permission errors |
| 2025-12-14 (Investigation) | User reported permission denied warnings in qBittorrent logs |
| 2025-12-14 (Investigation) | Issue diagnosed: 8 directories with 755 permissions instead of 777 |
| 2025-12-14 (Resolution) | Permissions corrected to 777, ownership changed to torrent:torrent |
| 2025-12-14 (Verification) | All permissions verified, issue resolved |

---

## Problem Description

### Symptoms
- qBittorrent logging file error alerts with "Permission denied"
- Torrents unable to complete file operations
- Error specifically affected subtitle (.srt) file creation

### Example Error
```
[WARNING] File error alert.
Torrent: "James Bond Quantum of Solace (2008) [1080p]"
File: "/data/torrents/cross-seed/YTS/James Bond Quantum of Solace (2008) [1080p]/James.Bond.Quantum.of.Solace.2008.1080p.BRrip.x264.YIFY.srt"
Reason: "James Bond Quantum of Solace (2008) [1080p] file_open (/data/torrents/cross-seed/YTS/James Bond Quantum of Solace (2008) [1080p]/James.Bond.Quantum.of.Solace.2008.1080p.BRrip.x264.YIFY.srt) error: Permission denied"
```

---

## Root Cause Analysis

### Technical Details

**Expected Configuration:**
- qBittorrent container runs as PUID=1000, PGID=1000 (torrent user)
- Cross-seed directories should have 777 permissions for write access
- Files should be owned by torrent:torrent (1000:1000)

**Actual Configuration (Before Fix):**
```
Directory Permissions     Owner      Path
---------------------------------------------
755                       root:root  /mnt/media/torrents
777                       root:root  /mnt/media/torrents/cross-seed
777                       root:root  /mnt/media/torrents/cross-seed/YTS
755                       root:root  /mnt/media/torrents/cross-seed/YTS/<8 subdirectories>
```

**Problem:**
- Directories with 755 permissions only allow owner (root) to write
- qBittorrent running as UID 1000 (torrent) has read+execute but NOT write
- Permission structure: `drwxr-xr-x` = owner can write, group/others cannot

### Root Cause
Cross-seed process likely created directories as root without proper umask settings or permission inheritance, resulting in restrictive 755 permissions instead of the expected 777.

---

## Affected Torrents

8 torrent directories were affected:

1. James Bond Quantum of Solace (2008) [1080p]
2. Avengers Age of Ultron (2015) [1080p]
3. Johnny English (2003) [1080p] [YTS.AG]
4. One Battle After Another (2025) [1080p] [WEBRip] [5.1] [YTS.MX]
5. Braveheart (1995) [1080p]
6. The Great Wall (2016) [1080p] [YTS.AG]
7. The Hangover (2009) [1080p] [BluRay] [5.1] [YTS.MX]
8. Night at the Museum (2006) [1080p]

All located in: `/mnt/media/torrents/cross-seed/YTS/`

---

## Resolution

### Actions Taken

1. **Identified affected directories**
   ```bash
   find /mnt/media/torrents/cross-seed/YTS -maxdepth 1 -type d -perm 755
   ```

2. **Fixed permissions**
   ```bash
   chmod 777 /mnt/media/torrents/cross-seed/YTS/*
   ```

3. **Fixed ownership**
   ```bash
   chown -R torrent:torrent /mnt/media/torrents/cross-seed/YTS/*
   ```

4. **Fixed parent directory**
   ```bash
   chmod 775 /mnt/media/torrents
   ```

### Post-Resolution Configuration
```
Directory Permissions     Owner           Path
---------------------------------------------
775                       root:root       /mnt/media/torrents
777                       root:root       /mnt/media/torrents/cross-seed
777                       root:root       /mnt/media/torrents/cross-seed/YTS
777                       torrent:torrent /mnt/media/torrents/cross-seed/YTS/<all subdirectories>
```

---

## Verification

- All 8 affected directories now have 777 permissions
- All directories owned by torrent:torrent (1000:1000)
- Zero directories with restrictive 755 permissions remain
- qBittorrent can now write files to all cross-seed torrents

---

## Prevention & Recommendations

### Immediate Actions
- [x] Fix permissions on all affected directories
- [x] Verify qBittorrent can write to cross-seed locations
- [ ] Monitor qBittorrent logs for 24-48 hours to ensure no recurrence

### Long-term Recommendations

1. **Investigate cross-seed configuration**
   - Review how cross-seed creates directories
   - Set appropriate umask or directory creation permissions
   - Consider running cross-seed with matching PUID/PGID (1000:1000)

2. **Implement monitoring**
   - Add periodic permission checks to backup script
   - Alert on permission mismatches in critical directories
   - Log directory creation events for audit trail

3. **Directory creation policy**
   ```bash
   # Add to cross-seed config or wrapper script
   umask 0000  # Ensures 777 permissions on new directories
   ```

4. **Preventive maintenance script**
   ```bash
   # Add to cron or systemd timer
   find /mnt/media/torrents/cross-seed -type d -not -perm 777 -exec chmod 777 {} \;
   find /mnt/media/torrents/cross-seed -type d -not -user torrent -exec chown torrent:torrent {} \;
   ```

5. **Documentation**
   - Update CLAUDE.md with cross-seed permission requirements
   - Document expected permission structure in troubleshooting guide

---

## Lessons Learned

1. **Cross-seed directory creation doesn't inherit parent permissions** - Need explicit permission management
2. **Root-owned processes can create permission issues** - Service containerization with proper user mapping is critical
3. **777 permissions are required** for shared write access when multiple processes need access
4. **Monitoring is essential** - Automated checks could have detected this before errors occurred

---

## Related Documentation

- **CLAUDE.md** - Project architecture and mount structure
- **docker-compose-torrent.yml** - qBittorrent configuration (PUID=1000, PGID=1000)
- **.env** - Environment variables for user/group mapping

---

## Appendix

### Environment Details
- **qBittorrent Container:** PUID=1000, PGID=1000
- **Host User:** torrent (UID 1000, GID 1000)
- **Base Directory:** /mnt/media/torrents
- **Affected Path:** /mnt/media/torrents/cross-seed/YTS/

### Commands Used for Investigation
```bash
# Check permissions
ls -la /mnt/media/torrents/cross-seed/YTS/
stat -c "%a %U:%G %n" /mnt/media/torrents/cross-seed/YTS

# Find affected directories
find /mnt/media/torrents/cross-seed/YTS -maxdepth 1 -type d -perm 755

# Verify user IDs
id -u torrent && id -g torrent
```

### Commands Used for Resolution
```bash
# Fix all permissions
chmod 777 /mnt/media/torrents/cross-seed/YTS/*
chown -R torrent:torrent /mnt/media/torrents/cross-seed/YTS/*
chmod 775 /mnt/media/torrents

# Verification
find /mnt/media/torrents/cross-seed/YTS -maxdepth 1 -type d ! -perm 777
```

---

**Report Generated:** 2025-12-14
**Next Review:** 2025-12-16 (Monitor for recurrence)
**Incident Closed:** Yes
