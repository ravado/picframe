#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <path-to-file-or-directory>" >&2
  exit 1
fi

PATH_IN="$1"

have_convert=1
if ! command -v convert >/dev/null 2>&1; then
  have_convert=0
  echo "NOTE: ImageMagick 'convert' not found; Pixel ID will be 'NA'." >&2
fi

# Hash functions
exact_hash() {
  # SHA-256 of raw bytes
  shasum -a 256 -- "$1" | awk '{print $1}'
}

pixel_hash() {
  # Hash of rendered pixels in a canonical form; returns "NA" on failure
  [[ $have_convert -eq 1 ]] || { echo "NA"; return; }
  local out
  # Convert to canonical PNG stream; clamp huge images to <=4096px on long edge
  out=$(convert "$1" -auto-orient -colorspace sRGB -strip -alpha off -resize '4096x4096>' PNG:- 2>/dev/null | shasum -a 256 | awk '{print $1}' || true)
  if [[ -z "${out:-}" ]]; then
    echo "NA"
  else
    echo "$out"
  fi
}

process_file() {
  local f="$1"
  local sha exact pixel
  exact=$(exact_hash "$f")
  pixel=$(pixel_hash "$f")
  # TSV: path<TAB>sha256_bytes<TAB>pixel_sha256
  printf "%s\t%s\t%s\n" "$f" "$exact" "$pixel"
}

echo -e "path\tsha256_bytes\tpixel_sha256"

if [[ -f "$PATH_IN" ]]; then
  process_file "$PATH_IN"
elif [[ -d "$PATH_IN" ]]; then
  # NUL-safe walk
  while IFS= read -r -d '' f; do
    process_file "$f"
  done < <(find "$PATH_IN" -type f -print0)
else
  echo "ERROR: '$PATH_IN' is neither a file nor a directory." >&2
  exit 2
fi
