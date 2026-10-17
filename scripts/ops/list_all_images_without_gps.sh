#!/bin/bash

# specify the directory to search for images
DIR="/home/ivan.cherednychok/Pictures/PhotoFrameOriginal"

# flag to check if any image was found without GPS data
no_gps_flag=0

# find images without GPS data, ignoring hidden files
find "$DIR" -type f \( -iname "*.jpg" -o -iname "*.jpeg" \) -not -path '*/\.*' | while read -r image; do
    gps_info=$(exiftool -gpslatitude -gpslongitude -s -s -s "$image")

    if [ -z "$gps_info" ]; then
        echo "No GPS data in image: $image"
        no_gps_flag=1
    fi
done

# check the flag after the loop
if [ $no_gps_flag -eq 0 ]; then
    echo "No photos without GPS found"
fi
