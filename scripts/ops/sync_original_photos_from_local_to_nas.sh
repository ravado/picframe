#!/usr/bin/env bash
set -euo pipefail

# Syncs original photos from local Mac to NAS for a specific photo frame.
#
# Place photos in the matching subfolder before running:
#   ~/Desktop/Photos/Home/
#   ~/Desktop/Photos/Cherednychoks/
#   ~/Desktop/Photos/Batanovs/
#
# Usage: ./sync_original_photos_from_local_to_nas.sh -target {home|batanovs|cherednychoks} [-n]

# --- Configurable paths ---
LOCAL_BASE="${HOME}/Desktop/Photos"
NAS_BASE="/Volumes/Photo-Frames"
LOG_FILE="${HOME}/sync_photos.log"

# --- Defaults ---
TARGET=""
DRY_RUN=0

usage() {
  echo "Usage: $0 -target {home|batanovs|cherednychoks} [-n]"
  echo "  -target   NAS target subfolder (required)"
  echo "  -n        Dry run (show what would happen, no changes)"
  exit 1
}

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    -target)
      TARGET="$2"
      shift 2
      ;;
    -n|--dry-run)
      DRY_RUN=1
      shift
      ;;
    *)
      echo "Unknown option: $1"
      usage
      ;;
  esac
done

if [[ -z "$TARGET" ]]; then
  echo "❌ Error: -target is required"
  usage
fi

# Capitalize first letter for path mapping
case "$TARGET" in
  home)          TARGET_DIR="Home" ;;
  batanovs)      TARGET_DIR="Batanovs" ;;
  cherednychoks) TARGET_DIR="Cherednychoks" ;;
  *)
    echo "❌ Invalid target: $TARGET"
    usage
    ;;
esac

LOCAL_PATH="${LOCAL_BASE}/${TARGET_DIR}"
DEST="${NAS_BASE}/${TARGET_DIR}/Original"

# --- Logging ---
timestamp() { date +"%Y-%m-%d %H:%M:%S"; }
log() { echo "[$(timestamp)] $*" | tee -a "$LOG_FILE"; }

log "📂 Starting photo sync"
log "   From: ${LOCAL_PATH}"
log "   To:   ${DEST}"
[[ $DRY_RUN -eq 1 ]] && log "   Mode: Dry-run" || log "   Mode: Live"

# --- Run rsync ---
RSYNC_OPTS="-avh --delete --itemize-changes --human-readable --progress --stats"
[[ $DRY_RUN -eq 1 ]] && RSYNC_OPTS="$RSYNC_OPTS --dry-run"

START_TS=$(date +%s)

RSYNC_LOG=$(mktemp)
rsync $RSYNC_OPTS "$LOCAL_PATH/" "$DEST/" 2>&1 | tee -a "$LOG_FILE" "$RSYNC_LOG"
RSYNC_OUTPUT=$(cat "$RSYNC_LOG")
rm -f "$RSYNC_LOG"

END_TS=$(date +%s)
DURATION=$((END_TS - START_TS))

# --- Group file changes ---
NEW_FILES=$(echo "$RSYNC_OUTPUT" | grep '^>f+++++++++' || true)
UPDATED_FILES=$(echo "$RSYNC_OUTPUT" | grep '^>f' | grep -v '+++++++++' || true)
DELETED_FILES=$(echo "$RSYNC_OUTPUT" | grep '^\*deleting' || true)

# --- Parse summary stats ---
CREATED=$(echo "$RSYNC_OUTPUT" | grep -E "Number of created files:" | awk '{print $5}')
DELETED=$(echo "$RSYNC_OUTPUT" | grep -E "Number of deleted files:" | awk '{print $5}')
UPDATED=$(echo "$UPDATED_FILES" | wc -l | tr -d ' ')
TOTAL=$(echo "$RSYNC_OUTPUT" | grep -E "Number of files:" | awk '{print $4}')
SIZE=$(echo "$RSYNC_OUTPUT" | grep -E "Total file size:" | sed -E 's/.*: (.*)/\1/')

# --- Print grouped lists ---
if [[ -n "$NEW_FILES" ]]; then
  log "➕ New files:"
  echo "$NEW_FILES" | tee -a "$LOG_FILE"
fi

if [[ -n "$UPDATED_FILES" ]]; then
  log "✏️  Updated files:"
  echo "$UPDATED_FILES" | tee -a "$LOG_FILE"
fi

if [[ -n "$DELETED_FILES" ]]; then
  log "🗑️  Deleted files:"
  echo "$DELETED_FILES" | tee -a "$LOG_FILE"
fi

# --- Final summary ---
log "⏱️ Duration: ${DURATION} seconds"
log "📊 Summary: ${CREATED} new, ${DELETED} deleted, ${UPDATED} updated, total ${TOTAL} files (${SIZE})"
log "✅ Sync finished"