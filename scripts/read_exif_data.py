#!python

# [ivan] This is a sample for getting image exif data using the same lib picture frame uses
# Use this to debug if resized/modified photo can provide an exif

import exifread
from exifread import exif_log

exif_log.setup_logger(True, True)

path_name = '/Users/ivan.cherednychok/Projects/usefull-scripts/PictureFrame/20220814_193905-1.jpg'
f = open(path_name, 'rb')
tags = exifread.process_file(f, debug=True)
print(tags)