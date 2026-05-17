#!/bin/bash
#
# list-rclone-dupes.sh
# List files with rclone-style random ID suffix {…} and show total at the end.
#
# Usage:
#   ./list-rclone-dupes.sh /path/to/folder
#

DIR="${1:-.}"

# Collect matches
FILES=$(find "$DIR" -type f -regex '.* {[^}]\+}\.[^.]\+')

if [[ -z "$FILES" ]]; then
    echo "✅ No rclone-style duplicate files found in $DIR"
    exit 0
fi

# Print each file
echo "📂 Files with rclone-style random ID suffixes:"
echo "$FILES"

# Print summary
COUNT=$(echo "$FILES" | wc -l)
echo
echo "📸 Found $COUNT such files in $DIR"