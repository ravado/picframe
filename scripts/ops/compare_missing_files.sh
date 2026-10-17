#!/bin/bash

dir1="/home/ivan.cherednychok/Pictures/PhotoFrame"
dir2="/home/ivan.cherednychok/Pictures/PhotoFrameOriginal"

# List filenames in dir1 and dir2
files_dir1=($(find "$dir1" -type f -exec basename {} \;))
files_dir2=($(find "$dir2" -type f -exec basename {} \;))

# Compare and find missing files in dir2
missing_files=()
for file1 in "${files_dir1[@]}"; do
  found=false
  for file2 in "${files_dir2[@]}"; do
    if [ "$file1" == "$file2" ]; then
      found=true
      break
    fi
  done
  if [ "$found" == false ]; then
    missing_files+=("$file1")
  fi
done

# Print missing files
echo "Missing files in $dir2:"
for missing_file in "${missing_files[@]}"; do
  echo "$missing_file"
done