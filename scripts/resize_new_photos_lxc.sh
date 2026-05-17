#!/bin/bash

# This script should ideally pick all new photos added to the watched folder and
# 1. resize them to a proper size of a photo frame (both width and height of an image should be bigger or eaqual that specified)
# 2. if image width or height is already smaller than specified we need to just copy it over
# 3. for some reason after resizing picframe lib is not reading exif data properly so we need to copy it again
# 4. we want to resize and copy exif data to the image into the same folder first, and then move to output directory


# === choose location from param: home|batanovs|cherednychoks ===
if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <home|batanovs|cherednychoks>"
  exit 1
fi
loc="$(echo "$1" | tr '[:upper:]' '[:lower:]')"
case "$loc" in
  home|batanovs|cherednychoks) ;;
  *) echo "Unknown location '$loc'"; exit 1;;
esac
# Capitalize for directory names: Home, Batanovs, Cherednychoks
LOC_CAP="$(tr '[:lower:]' '[:upper:]' <<< "${loc:0:1}")${loc:1}"

BASE="/mnt/photo-frame"
WATCH_DIR="$BASE/$LOC_CAP/Original"
OUTPUT_DIR="$BASE/$LOC_CAP/Resized"
# (keep timestamp alongside output so each location tracks its own sync)
TIMESTAMP_FILE="$OUTPUT_DIR/_lastSyncedTimestamp"

RESIZE_WIDTH="1280"
RESIZE_HEIGHT="1024"

# Declare global variables so the are update properly inside of loops
# Bad practice but it should not be a problem here
declare -g frame_resize_total_files=0
declare -g frame_resize_total_time=0

echo -e "[$(date '+%d-%m-%Y %H:%M:%S')] Initializing resizing script...\n"

if [ ! -f "$TIMESTAMP_FILE" ]; then
    touch -d '1970-01-01 00:00:00' "$TIMESTAMP_FILE"
fi

LAST_RUN=$(stat -c %Y "$TIMESTAMP_FILE") # Raspbery Pi
# LAST_RUN=$(stat -f %m "$TIMESTAMP_FILE") # Mac OS

file_regex='.*\.\(jpg\|jpeg\|png\|heic\|tif\|tiff\)'
total_files_found=$(
    find "$WATCH_DIR" -type f \
        -iregex "$file_regex" \
        -not -path '*/\.*' \
        -cnewer "$TIMESTAMP_FILE" | wc -l
)

# CHANGED: avoid subshell so counters/time persist; read NUL-separated for safety
while IFS= read -r -d '' FULL_PATH; do

    # CHANGED: define before use
    FILENAME=$(basename "$FULL_PATH")
    FILE_EXTENSION="${FILENAME##*.}"

    # CHANGED: preserve original extension case style when converting HEIC/TIF(F) to JPG
    if [[ "${FILE_EXTENSION,,}" =~ ^(heic|tiff|tif)$ ]]; then
        # If original has any uppercase letters -> use JPG, else jpg
        if [[ "$FILE_EXTENSION" =~ [A-Z] ]]; then
            OUTPUT_FILE_EXTENSION="JPG"
        else
            OUTPUT_FILE_EXTENSION="jpg"
        fi
    else
        OUTPUT_FILE_EXTENSION="$FILE_EXTENSION"
    fi
    # /CHANGED

    RESIZED_PATH="$WATCH_DIR/${FILENAME%.*}_resized.$OUTPUT_FILE_EXTENSION"
    OUTPUT_PATH="$OUTPUT_DIR/${FILENAME%.*}.$OUTPUT_FILE_EXTENSION"
    
    # Record the start time
    start_time_one_file=$(date +%s)

    AUTO_ORIENTED_PATH="$WATCH_DIR/${FILENAME%.*}_auto_oriented.$OUTPUT_FILE_EXTENSION"

    # Execute conversion for up to 10 minutes, if more it is probably hung 
    timeout 600 convert "$FULL_PATH" -auto-orient "$AUTO_ORIENTED_PATH"
    
    # Check the exit status of the 'convert' command
    if [ $? -ne 0 ]; then
        echo "ERROR: Failed to auto-orient $FULL_PATH"
        continue  # Skip to the next file
    fi

    IMG_WIDTH=$(identify -format "%w" "$AUTO_ORIENTED_PATH")
    IMG_HEIGHT=$(identify -format "%h" "$AUTO_ORIENTED_PATH")
    
    echo "[$(date '+%d-%m-%Y %H:%M:%S')] #$(($frame_resize_total_files + 1)) of $total_files_found"
    echo "[${FILENAME}] of ${IMG_WIDTH}x${IMG_HEIGHT}"

    if [[ $IMG_WIDTH -gt $RESIZE_WIDTH ]] || [[ $IMG_HEIGHT -gt $RESIZE_HEIGHT ]]; then
        SCALE_WIDTH=$(echo "scale=4; $RESIZE_WIDTH / $IMG_WIDTH" | bc)
        SCALE_HEIGHT=$(echo "scale=4; $RESIZE_HEIGHT / $IMG_HEIGHT" | bc)
        
        if (( $(echo "$SCALE_WIDTH < $SCALE_HEIGHT" | bc -l) )); then
            SCALE_FACTOR=$SCALE_HEIGHT
            echo "Scale factor: Width: ${SCALE_WIDTH}, Height: ${SCALE_HEIGHT} (use this)"
        else
            SCALE_FACTOR=$SCALE_WIDTH
            echo "Scale factor: Width: ${SCALE_WIDTH} (use this), Height: ${SCALE_HEIGHT}"
        fi

        SCALE_FACTOR=$(echo "$SCALE_FACTOR + 0.01" | bc)

        PERCENTAGE=$(echo "scale=2; $SCALE_FACTOR * 100" | bc)

        NEW_WIDTH=$(echo "scale=0; $IMG_WIDTH * $SCALE_FACTOR / 1" | bc)
        NEW_HEIGHT=$(echo "scale=0; $IMG_HEIGHT * $SCALE_FACTOR / 1" | bc)

        echo "Resizing $FULL_PATH to $RESIZED_PATH"
        echo "New dimensions: ${NEW_WIDTH}x${NEW_HEIGHT}"

        # Execute conversion for up to 10 minutes, if more it is probably hung 
        timeout 600 convert "$AUTO_ORIENTED_PATH" -resize "${PERCENTAGE}%" -quality 95 "$RESIZED_PATH"

        # Check the exit status of the 'convert' command
        if [ $? -ne 0 ]; then
            echo "ERROR: Failed to resize file $AUTO_ORIENTED_PATH"
            continue  # Skip to the next file
        fi

        # Increment the total converted files counter
        frame_resize_total_files=$((frame_resize_total_files + 1))

        echo "Accumulated total proccessed images so far: $frame_resize_total_files"

        echo "Resized"

    else
        echo "Copying $FULL_PATH without resizing"
        cp "$AUTO_ORIENTED_PATH" "$RESIZED_PATH"
    fi

    mv "$RESIZED_PATH" "$OUTPUT_PATH"
    echo "Cleaned redundant file ${RESIZED_PATH}"
    
    rm "$AUTO_ORIENTED_PATH"

    # Record the end time
    end_time=$(date +%s)
    
    # Calculate and display the elapsed time in a more human-readable format
    elapsed_time_one_file=$((end_time - start_time_one_file))
    
    # Increment the total time
    frame_resize_total_time=$((frame_resize_total_time + elapsed_time_one_file))

    echo "Accumulated total time so far: $frame_resize_total_time seconds"
    
    if [ "$elapsed_time_one_file" -ge 60 ]; then
        minutes=$((elapsed_time_one_file / 60))
        seconds=$((elapsed_time_one_file % 60))
        echo "Elapsed time: ${minutes}m ${seconds}s"
    else
        echo "Elapsed time: ${elapsed_time_one_file}s"
    fi

    echo 
done < <(find "$WATCH_DIR" -type f \
           -iregex "$file_regex" \
           -not -path '*/\.*' \
           -cnewer "$TIMESTAMP_FILE" \
           -print0)

# Display the total time in a format that includes hours, if necessary
if [ "$frame_resize_total_time" -ge 3600 ]; then
    total_hours=$((frame_resize_total_time / 3600))
    frame_resize_total_time=$((frame_resize_total_time % 3600))
    total_minutes=$((frame_resize_total_time / 60))
    total_seconds=$((frame_resize_total_time % 60))
    echo "Total time: ${total_hours}h ${total_minutes}m ${total_seconds}s"
elif [ "$frame_resize_total_time" -ge 60 ]; then
    total_minutes=$((frame_resize_total_time / 60))
    total_seconds=$((frame_resize_total_time % 60))
    echo "Total time: ${total_minutes}m ${total_seconds}s"
else
    echo "Total time: ${frame_resize_total_time}s"
fi

# Display the total number of converted files
echo "Total converted files: ${frame_resize_total_files}"

echo "SUCCESS: All files have been converted, updating timestamp file..."
touch "$TIMESTAMP_FILE"
echo "Updated"
