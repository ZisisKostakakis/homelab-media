# Bazarr Optimization Summary - Greek & English Subtitles

**Date**: 2025-12-22
**Objective**: Optimize Bazarr for high-quality Greek and English subtitle matches with desynchronization prevention

## Changes Implemented

### 1. Quality Threshold Improvements

**Configuration File**: `/mnt/media/config/bazarr/config/config.yaml`

#### Minimum Score Thresholds (Already Optimal)
- **TV Series**: `90` (unchanged - already at TRaSH Guide recommendation)
- **Movies**: `80` (unchanged - was already raised from default 70)
- **Post-processing TV**: `90` (unchanged)
- **Post-processing Movies**: Raised from `70` to `80` ✅

#### Post-Processing Threshold Enforcement (NEW)
- **`use_postprocessing_threshold`**: Changed from `false` to `true` ✅
- **`use_postprocessing_threshold_movie`**: Changed from `false` to `true` ✅

**Impact**: Only subtitles meeting quality thresholds will undergo post-processing, preventing CPU waste on poor-quality subtitles.

### 2. FFsubsync Auto-Synchronization (Already Configured)

**Subsync Thresholds** (Found to be already optimized):
- **TV Series Threshold**: `96` (TRaSH Guide recommendation) ✅
- **Movies Threshold**: `86` (TRaSH Guide recommendation) ✅
- **Threshold Enforcement**: `true` for both TV and movies ✅
- **Max Offset**: `60 seconds`
- **GraphicalSync (gss)**: Enabled

**Current State**: Your Bazarr was already configured with optimal TRaSH Guide sync thresholds! The sync feature will automatically fix subtitle timing issues when scores fall between the minimum download threshold and the sync threshold.

### 3. Greek Provider Research

**Current Providers** (config.yaml, lines 70-74):
- `animetosho` - Anime subtitles
- `podnapisi` - European provider (being throttled occasionally)
- `supersubtitles` - General provider
- `opensubtitlescom` - Primary provider (with account credentials)

**Provider Usage Stats** (from database analysis):
- **OpenSubtitles.com**: 96 TV searches, 122 movie searches (dominant provider)
- **Podnapisi**: 9 movie searches (experiencing rate limiting)
- **Supersubtitles**: 6 TV searches, 3 movie searches
- **Greeksubs**: 5 movie searches (appeared in history but NOT in enabled providers list!)

**Recommendation**: Check Bazarr web UI (Settings → Providers) to verify which Greek-specific providers are available. Common options mentioned in research:
- `greeksubs` (appears in your search history)
- `subscene` (supports Greek)
- `subf2m` (has Greek support)

**Action Required**: Log into Bazarr at `http://[server-ip]:6767` and enable additional Greek providers through the UI.

## Configuration Summary

### Files Modified
1. `/mnt/media/config/bazarr/config/config.yaml` - Primary configuration
2. Backup created at: `/mnt/media/config/bazarr/config/config.yaml.backup-[timestamp]`

### Key Settings

| Setting | Previous Value | New Value | Status |
|---------|---------------|-----------|--------|
| `minimum_score_movie` | 70 | 80 | Already updated |
| `postprocessing_threshold_movie` | 70 | 80 | ✅ Updated |
| `use_postprocessing_threshold` | false | true | ✅ Updated |
| `use_postprocessing_threshold_movie` | false | true | ✅ Updated |
| `subsync_threshold` (TV) | 90 | 96 | Already optimal |
| `subsync_movie_threshold` | 70 | 86 | Already optimal |
| `use_subsync_threshold` | false | true | Already enabled |
| `use_subsync_movie_threshold` | false | true | Already enabled |

## How It Works Now

### Quality-First Download Strategy

1. **Minimum Scores Required**:
   - TV episodes: 90+ points (strict)
   - Movies: 80+ points (high quality)

2. **Scoring Weights** (your current config):
   - **Hash matching**: 359 (TV), 119 (movies) - Ensures exact release match
   - **Title matching**: 180 (TV), 60 (movies) - Correct content
   - **Year**: 90 (TV), 30 (movies)
   - **Release group**: 14 (TV), 13 (movies)
   - Other factors: Resolution, audio codec, source, etc.

3. **Automatic Synchronization**:
   - If subtitle scores **86-95** (movies) or **96-99** (TV): FFsubsync attempts automatic timing correction
   - If subtitle scores **96+** (TV) or **86+** (movies): Used as-is (high confidence)
   - If subtitle scores **below 80** (movies) or **90** (TV): Rejected entirely

### Sync Prevention Strategy

**Hash-Weighted Scoring** (already in your config):
- Your Bazarr heavily prioritizes hash matching (359 points for TV, 119 for movies)
- Hash matching means the subtitle was made for the EXACT same release file
- This is the #1 way to prevent desynchronization
- TRaSH Guides recommend this approach

**FFsubsync Backup**:
- When hash match isn't perfect but subtitle quality is good (86-96 range), FFsubsync extracts audio and analyzes speech patterns
- Automatically adjusts subtitle timing to match dialogue
- CPU-intensive but fixes most timing issues

## Current Statistics

**Library Size**:
- 5 TV series, 75 episodes
- 65 movies

**Subtitle Coverage**:
- **TV**: 72 subtitle files (54 Greek, 6 English, 12 other)
- **Movies**: 89 subtitle files (40 Greek, 20 English, 29 other)

**Language Priority**:
- Greek (el): 75% of TV subtitles, primary language
- English (en): Secondary language
- Both enabled with equal priority in "Main" profile

**Search Volume** (historical):
- Greek TV: 140 searches
- English TV: 20 searches
- Greek Movies: 58 searches
- English Movies: 59 searches

## Monitoring Instructions

### Immediate Verification (Next 24-48 Hours)

1. **Check Bazarr Logs**:
   ```bash
   ./stack-manage.sh torrent logs bazarr | tail -100
   ```

2. **Monitor Subsync Activity**:
   ```bash
   cat /mnt/media/config/bazarr/log/ffsubsync.log
   ```

3. **Check Provider Throttling**:
   ```bash
   cat /mnt/media/config/bazarr/config/throttled_providers.dat
   ```

4. **Review Subtitle Quality**:
   - Access Bazarr UI: `http://[server-ip]:6767`
   - Navigate to History tab
   - Check score columns for recent downloads

5. **Test Playback**:
   - Play a few Greek and English titles
   - Verify subtitle synchronization quality
   - Check for timing issues

### Long-Term Monitoring

**Weekly Checks**:
- Review Bazarr History for failed searches
- Monitor provider throttling (especially Podnapisi)
- Check subtitle upgrade activity

**Performance Monitoring**:
- Watch for CPU spikes (FFsubsync audio extraction)
- Monitor disk usage (subtitle cache growth)
- Check network bandwidth (provider API calls)

**Quality Assessment**:
- Track subtitle match scores in History
- Note any persistent sync issues
- Identify content with poor subtitle availability

## Troubleshooting Guide

### If Too Few Subtitles Are Downloaded

**Symptom**: Missing subtitles for many titles
**Solution**: Lower minimum scores by 5 points (85 for TV, 75 for movies)

### If Subsync Is Too CPU-Intensive

**Symptom**: High CPU usage, slow system performance
**Solution**:
- Disable subsync: Set `use_subsync: false`
- OR raise thresholds to 98 (TV) and 88 (movies)

### If Greek Providers Are Throttled

**Symptom**: "Provider throttled" messages in logs
**Solution**:
- Add more Greek providers through web UI
- Stagger search timing (increase `wanted_search_frequency`)

### If Sync Issues Persist

**Symptom**: Subtitles still out of sync despite FFsubsync
**Solution**:
1. Enable subsync debug: Set `subsync.debug: true`
2. Review `/mnt/media/config/bazarr/log/ffsubsync.log`
3. Report issues to FFsubsync GitHub with debug logs

## Provider Recommendations

### To Add Greek Providers (Web UI Required)

1. Access Bazarr: `http://[server-ip]:6767`
2. Navigate to **Settings → Providers**
3. Click **"+ Add Provider"** button
4. Search for and enable:
   - **greeksubs** (if available - was in your search history)
   - **subscene** (supports Greek)
   - **subf2m** (has Greek support)
5. Configure credentials if required
6. Set provider priority order:
   1. opensubtitlescom (keep as #1)
   2. greeksubs (Greek-specific)
   3. subscene or subf2m
   4. podnapisi
   5. supersubtitles
   6. animetosho (lowest priority)

## Expected Outcomes

### Quality Improvements
✅ Higher match quality (80+ movie threshold enforced)
✅ Fewer sync issues (TRaSH Guide thresholds active)
✅ Better Greek coverage (when additional providers added)
✅ Automatic sync fixing (FFsubsync for scores 86-96)

### Performance Considerations
⚠️ CPU spikes during subtitle synchronization (FFsubsync audio extraction)
⚠️ Increased network usage (more providers = more API calls)
✅ Minimal storage impact (a few MB per subtitle file)

### Coverage Trade-offs
⚠️ Slightly fewer downloads (stricter 80 vs 70 threshold for movies)
✅ Much better quality for downloads that succeed
✅ Greek availability should offset reduction (when providers added)

## Rollback Instructions

If issues arise, restore the backup:

```bash
# Stop Bazarr
./stack-manage.sh torrent stop bazarr

# Restore backup (replace timestamp with your backup)
cp /mnt/media/config/bazarr/config/config.yaml.backup-[timestamp] \
   /mnt/media/config/bazarr/config/config.yaml

# Start Bazarr
./stack-manage.sh torrent start bazarr
```

## References

### TRaSH Guides
- [Bazarr Suggested Scoring](https://trash-guides.info/Bazarr/Bazarr-suggested-scoring/)

### Official Documentation
- [Bazarr Wiki - Settings](https://wiki.bazarr.media/Additional-Configuration/Settings/)
- [Bazarr Wiki - Performance Tuning](https://wiki.bazarr.media/Additional-Configuration/Performance-Tuning/)
- [Bazarr Setup Guide](https://wiki.bazarr.media/Getting-Started/Setup-Guide/)

### Provider Information
- [Bazarr Subtitle Providers Guide](https://www.rapidseedbox.com/blog/subtitle-downloads-with-bazarr)
- [Bazarr Provider List](https://yams.media/config/bazarr/)

### FFsubsync
- [FFsubsync GitHub](https://github.com/smacke/ffsubsync)

## Next Steps

1. ✅ Configuration optimized with TRaSH Guide settings
2. ✅ Post-processing threshold enforcement enabled
3. ✅ FFsubsync thresholds verified (already optimal)
4. ⏳ **ACTION REQUIRED**: Add Greek providers via web UI
5. ⏳ **Monitor for 24-48 hours** to verify improvements
6. ⏳ **Fine-tune if needed** based on monitoring results

## Notes

- Your Bazarr configuration was already quite good! The subsync thresholds were at TRaSH Guide recommendations.
- Main changes were enabling post-processing threshold enforcement and clarifying Greek provider options.
- The hash-weighted scoring you already have is excellent for preventing desync.
- Adding Greek-specific providers will be the biggest improvement for Greek subtitle coverage.
- Podnapisi is being throttled occasionally - this is normal and will be less impactful once more providers are added.
