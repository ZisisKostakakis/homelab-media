#!/bin/bash

# book-ingest.sh — copy ebook/audiobook files from a finished download into the
# Calibre-Web Automated ingest folder, so CWA converts and imports them.
#
# Runs inside the qBittorrent container as an "on torrent finished" hook, so all
# paths below are container paths (/data == /mnt/media on the host). Also usable
# by hand to sweep a directory.
#
# Files are COPIED, never moved: qBittorrent must keep seeding the original.
# CWA deletes whatever lands in the ingest folder once it has imported it, so
# moving would silently destroy the seeding copy.
#
# Usage (manual sweep):  ./scripts/book-ingest.sh --path /data/downloads/complete/SomeBook
#   --path P     Directory or file to scan (required)
#   --name N     Torrent name, for logging only
#   --category C Torrent category. When set, must match --only-category or the
#                script exits without doing anything. This is what keeps the
#                qBittorrent hook from sweeping movie and TV downloads.
#   --only-category C  Category to act on. Default "books".
#   --ingest D   Ingest directory. Default /data/books/ingest
#   --dry-run    Report what would be copied, copy nothing
#
# qBittorrent hook (Settings > Downloads > Run external program on finish):
#   /config/scripts/book-ingest.sh --path "%F" --name "%N" --category "%L"

set -uo pipefail

INGEST_DIR="${BOOK_INGEST_DIR:-/data/books/ingest}"
LOG_FILE="${BOOK_INGEST_LOG:-/config/book-ingest.log}"
SRC=""
NAME=""
CATEGORY=""
ONLY_CATEGORY="${BOOK_INGEST_CATEGORY:-books}"
DRY_RUN=false

# Formats CWA can ingest and convert. Audiobook containers (m4b/mp3) are routed
# to the Audiobookshelf library instead — CWA cannot do anything with them.
EBOOK_EXT="epub mobi azw3 azw pdf cbz cbr fb2 djvu lit prc rtf txt"
AUDIO_EXT="m4b m4a mp3 flac ogg opus"
AUDIOBOOK_DIR="${BOOK_AUDIOBOOK_DIR:-/data/books/audiobooks}"

while [[ $# -gt 0 ]]; do
    case $1 in
        --path)    SRC="${2:-}"; shift 2 ;;
        --name)    NAME="${2:-}"; shift 2 ;;
        --category)      CATEGORY="${2:-}"; shift 2 ;;
        --only-category) ONLY_CATEGORY="${2:-}"; shift 2 ;;
        --ingest)  INGEST_DIR="${2:-}"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        -h|--help) sed -n '3,20p' "$0"; exit 0 ;;
        *) echo "Unknown arg: $1" >&2; exit 2 ;;
    esac
done

log() {
    local line="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$line"
    # Best-effort file logging; a read-only or missing log dir must not break the
    # hook. The redirect itself can fail, so guard the whole thing in a subshell
    # with stderr silenced rather than only redirecting echo's own stderr.
    [ -n "$LOG_FILE" ] && ( echo "$line" >> "$LOG_FILE" ) 2>/dev/null
    return 0
}

# Set by copy_matching. A global rather than stdout, so log lines are free to
# go to stdout without being captured as the return value.
COPIED=0
SKIPPED=0

if [ -z "$SRC" ]; then
    echo "Error: --path is required" >&2
    exit 2
fi

# The qBittorrent hook is global — it runs for every finished torrent. Ignore
# anything that is not in the books category. An empty --category means the
# script was invoked by hand, so proceed.
if [ -n "$CATEGORY" ] && [ -n "$ONLY_CATEGORY" ] && [ "$CATEGORY" != "$ONLY_CATEGORY" ]; then
    exit 0
fi
if [ ! -e "$SRC" ]; then
    log "ERROR: path not found: $SRC"
    exit 1
fi

# Build a find expression as an ARRAY in FIND_EXPR.
# Must not go through an unquoted command substitution: the shell would split
# on whitespace and then glob-expand the `*.ext` patterns against the current
# directory, silently corrupting the expression whenever a pattern happens to
# match a local file.
FIND_EXPR=()
build_expr() {
    FIND_EXPR=()
    local ext first=true
    for ext in $1; do
        if $first; then first=false; else FIND_EXPR+=(-o); fi
        FIND_EXPR+=(-iname "*.${ext}")
    done
}

copy_matching() {
    local label=$1 exts=$2 dest=$3
    COPIED=0
    SKIPPED=0

    if [ ! -d "$dest" ]; then
        if $DRY_RUN; then
            log "[dry-run] would create $dest"
        else
            mkdir -p "$dest" || { log "ERROR: cannot create $dest"; return 1; }
        fi
    fi

    build_expr "$exts"

    # -print0 so filenames with spaces/quotes survive; book releases are full of them.
    while IFS= read -r -d '' f; do
        local base
        base=$(basename "$f")
        local target="$dest/$base"

        # Never clobber a file already waiting to be ingested.
        if [ -e "$target" ]; then
            log "  skip (already in $label): $base"
            SKIPPED=$((SKIPPED + 1))
            continue
        fi

        if $DRY_RUN; then
            log "  [dry-run] would copy to $label: $base"
        else
            # Copy to a temp name first, then rename. CWA's watcher fires on
            # filename appearance, so a partially-copied file could otherwise be
            # picked up mid-write and fail to convert.
            local tmp="$dest/.incoming-$$-$base"
            if cp "$f" "$tmp" 2>/dev/null && mv "$tmp" "$target" 2>/dev/null; then
                chown 1000:1000 "$target" 2>/dev/null || true
                log "  -> $label: $base"
            else
                rm -f "$tmp" 2>/dev/null
                log "  ERROR copying: $base"
                continue
            fi
        fi
        COPIED=$((COPIED + 1))
    done < <(find "$SRC" -type f \( "${FIND_EXPR[@]}" \) -print0)
}

log "=== book-ingest: ${NAME:-$(basename "$SRC")} ==="
log "  source: $SRC"

copy_matching "ingest" "$EBOOK_EXT" "$INGEST_DIR"
ebooks=$COPIED
skipped=$SKIPPED
copy_matching "audiobooks" "$AUDIO_EXT" "$AUDIOBOOK_DIR"
audio=$COPIED
skipped=$((skipped + SKIPPED))

if [ "${ebooks:-0}" -eq 0 ] && [ "${audio:-0}" -eq 0 ]; then
    if [ "${skipped:-0}" -gt 0 ]; then
        log "  nothing new: $skipped file(s) already ingested"
    else
        log "  no book files found — nothing to do"
    fi
else
    log "  done: $ebooks ebook(s) -> ingest, $audio audio file(s) -> audiobooks"
fi
