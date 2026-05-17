#!/bin/bash
set -euo pipefail

# Usage: ./sync_and_resize_photos.sh <home|batanovs|cherednychoks>
if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <home|batanovs|cherednychoks>"
  exit 1
fi

# --- normalize + validate ---
choice=$(echo "$1" | tr '[:upper:]' '[:lower:]')
allowed=(home batanovs cherednychoks)
if [[ ! " ${allowed[*]} " =~ " ${choice} " ]]; then
  echo "Error: unknown location '${choice}'. Allowed: ${allowed[*]}"
  exit 1
fi

# --- Capitalize for path segment (Home, Batanovs, Cherednychoks) ---
PHOTOS_SUBDIR="$(tr '[:lower:]' '[:upper:]' <<< "${choice:0:1}")${choice:1}"

# --- rclone remote name ---
remote_name="nasikphotos"

echo -e "🔄 Sync for '${PHOTOS_SUBDIR}' from ${remote_name}...\n"

# Ensure destination exists
DEST="$HOME/Pictures/PhotoFrame"
mkdir -p "$DEST"

# Optional: show which rclone config is used (if set by systemd)
if [[ -n "${RCLONE_CONFIG:-}" && -f "$RCLONE_CONFIG" ]]; then
  echo "ℹ️ Using rclone config: $RCLONE_CONFIG"
fi

# --- rclone from NAS/SMB share (Resized already produced elsewhere) ---
# Source example: nasikphotos:/Photo-Frames/Home
SRC="${remote_name}:/Photo-Frames/${PHOTOS_SUBDIR}"

rclone sync -v "$SRC" "$DEST" \
  --ignore-case-sync \
  --stats-one-line \
  --copy-links \
  --create-empty-src-dirs \
  --exclude "Thumbs.db" \
  --exclude ".DS_Store" \
  --transfers=4 \
  --checkers=8

echo -e "\n✅ Sync complete for '${PHOTOS_SUBDIR}' → $DEST"