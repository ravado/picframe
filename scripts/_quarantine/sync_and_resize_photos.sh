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

# --- capitalize for path segment (Home, Batanovs, Cherednychoks) ---
PHOTOS_SUBDIR="$(tr '[:lower:]' '[:upper:]' <<< "${choice:0:1}")${choice:1}"

echo -e "Sync & resize for '${PHOTOS_SUBDIR}'...\n"

# rclone (Google Photos example — deprecated as of 2025)
# rclone sync -v "googlephotos:shared-album/Photo Frame: ${PHOTOS_SUBDIR}" "$HOME/Pictures/PhotoFrameOriginal" --ignore-case-sync

# rclone from NAS/SMB share
rclone sync -v "nasikphotos:/Photo-Frames/${PHOTOS_SUBDIR}/Resized" "$HOME/Pictures/PhotoFrame" \
  --ignore-case-sync \
  --copy-links \
  --create-empty-src-dirs \
  --exclude "Thumbs.db" \
  --exclude ".DS_Store" \
  --transfers=4 \
  --checkers=8

# Process images
# /home/ivan.cherednychok/Documents/Scripts/PhotoFrame/resize_new_photos.sh
# /home/ivan.cherednychok/Documents/Scripts/PhotoFrame/remove_missing_photos.sh