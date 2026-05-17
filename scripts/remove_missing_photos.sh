#!/bin/bash

# This should keep OUTPUT_DIR in sync with WATCH_DIR

WATCH_DIR="/home/ivan.cherednychok/Pictures/PhotoFrameOriginal"
OUTPUT_DIR="/home/ivan.cherednychok/Pictures/PhotoFrame"
TIMESTAMP_FILE_TO_IGNORE="_lastSyncedTimestamp"

echo -e "[$(date '+%d-%m-%Y %H:%M:%S')] Initializing removing missing photos script...\n"

# Create an associative array for the file names in WATCH_DIR
declare -A watch_files
for file in "$WATCH_DIR"/*; do
    filename=$(basename "$file")
    name_without_extension="${filename%.*}"
    watch_files["$name_without_extension"]=1
done

# Compare file names in OUTPUT_DIR with the associative array and remove missing files
for file in "$OUTPUT_DIR"/*; do
    filename=$(basename "$file")
    name_without_extension="${filename%.*}"
    
    if [ -z "${watch_files["$name_without_extension"]}" ] && [ "$name_without_extension" != "${TIMESTAMP_FILE_TO_IGNORE}" ]; then
        echo "Removing $file"
        rm "$file"
    fi
done

echo -e "[$(date '+%d-%m-%Y %H:%M:%S')] Done. All missing photos have been removed.\n"
