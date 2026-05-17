#!/bin/bash

# Use this wrapper to make logs appear in logs journal

/usr/bin/systemd-cat -t picframe-backup /home/ivan.cherednychok/Documents/Scripts/PhotoFrame/sync_and_resize_photos.sh "$@"