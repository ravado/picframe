#!/usr/bin/env python3
"""Inspect Picframe cache entries for a date range and verify files on disk.

This script mirrors Picframe's date filtering behavior:
- It filters on `meta.exif_datetime`
- If EXIF DateTimeOriginal was missing when the cache was built, Picframe stored
  the file modification time instead

The script reports:
- how many cached rows match the range
- which matched files currently exist or are missing on disk
- duplicate timestamps that may indicate only one photo truly falls in range

Example:
    python3 check_date_range_files.py \
      --db ~/picframe_data/data/pictureframe.db3 \
      --date-from 2016/04/08 \
      --date-to 2016/04/09
"""

from __future__ import annotations

import argparse
import datetime as dt
import os
import sqlite3
import sys
from collections import Counter


def parse_date(value: str) -> int:
    normalized = value.strip().replace("-", "/").replace(".", "/")
    try:
        parsed = dt.datetime.strptime(normalized, "%Y/%m/%d")
    except ValueError as exc:
        raise argparse.ArgumentTypeError(
            f"Invalid date '{value}'. Use YYYY/MM/DD."
        ) from exc
    return int(parsed.timestamp())


def format_ts(value: float | int | None) -> str:
    if not value:
        return "0"
    return dt.datetime.fromtimestamp(float(value)).strftime("%Y-%m-%d %H:%M:%S")


def expand(path: str) -> str:
    return os.path.abspath(os.path.expanduser(path))


def load_rows(db_path: str, date_from_ts: int, date_to_ts: int) -> list[sqlite3.Row]:
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    try:
        sql = """
            SELECT
                file.file_id,
                folder.name || "/" || file.basename || "." || file.extension AS fname,
                file.last_modified,
                file.displayed_count,
                meta.exif_datetime,
                meta.make,
                meta.model,
                meta.title,
                meta.caption,
                meta.tags
            FROM file
            INNER JOIN folder ON folder.folder_id = file.folder_id
            LEFT JOIN meta ON meta.file_id = file.file_id
            WHERE folder.missing = 0
              AND meta.exif_datetime > ?
              AND meta.exif_datetime < ?
            ORDER BY meta.exif_datetime ASC, fname ASC
        """
        return conn.execute(sql, (date_from_ts, date_to_ts)).fetchall()
    finally:
        conn.close()


def find_same_basename_elsewhere(search_root: str, missing_path: str) -> list[str]:
    basename = os.path.basename(missing_path)
    matches: list[str] = []
    for root, dirs, files in os.walk(search_root):
        dirs[:] = [d for d in dirs if not d.startswith(".")]
        for file_name in files:
            if file_name == basename:
                matches.append(os.path.join(root, file_name))
    return matches


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", required=True, help="Path to pictureframe.db3")
    parser.add_argument("--date-from", required=True, type=parse_date, help="Inclusive lower day boundary in YYYY/MM/DD")
    parser.add_argument("--date-to", required=True, type=parse_date, help="Exclusive upper day boundary in YYYY/MM/DD")
    parser.add_argument(
        "--search-root",
        help="Optional root folder to search for same basenames when cached paths are missing",
    )
    parser.add_argument(
        "--show-all",
        action="store_true",
        help="Print every matched row, not just summary and missing files",
    )
    args = parser.parse_args()

    db_path = expand(args.db)
    if not os.path.exists(db_path):
        print(f"Database not found: {db_path}", file=sys.stderr)
        return 2

    search_root = expand(args.search_root) if args.search_root else None
    if search_root and not os.path.isdir(search_root):
        print(f"Search root is not a directory: {search_root}", file=sys.stderr)
        return 2

    rows = load_rows(db_path, args.date_from, args.date_to)
    total = len(rows)
    existing = [row for row in rows if os.path.exists(row["fname"])]
    missing = [row for row in rows if not os.path.exists(row["fname"])]

    print(f"DB: {db_path}")
    print(f"Date range: {format_ts(args.date_from)} <= exif_datetime < {format_ts(args.date_to)}")
    print(f"Matched rows: {total}")
    print(f"Existing files: {len(existing)}")
    print(f"Missing files: {len(missing)}")

    if rows:
        timestamps = Counter(int(float(row["exif_datetime"] or 0)) for row in rows)
        duplicate_timestamps = [(ts, count) for ts, count in timestamps.items() if count > 1]
        if duplicate_timestamps:
            print("Duplicate exif timestamps:")
            for ts, count in sorted(duplicate_timestamps):
                print(f"  {format_ts(ts)} : {count} files")

    if args.show_all and rows:
        print("\nMatched rows:")
        for row in rows:
            state = "OK" if os.path.exists(row["fname"]) else "MISSING"
            print(
                f"  [{state}] file_id={row['file_id']} "
                f"exif={format_ts(row['exif_datetime'])} "
                f"mtime={format_ts(row['last_modified'])} "
                f"shown={row['displayed_count']} "
                f"path={row['fname']}"
            )

    if missing:
        print("\nMissing files:")
        for row in missing:
            print(
                f"  file_id={row['file_id']} "
                f"exif={format_ts(row['exif_datetime'])} "
                f"mtime={format_ts(row['last_modified'])} "
                f"path={row['fname']}"
            )
            if search_root:
                matches = find_same_basename_elsewhere(search_root, row["fname"])
                for match in matches[:10]:
                    print(f"    candidate={match}")
                if len(matches) > 10:
                    print(f"    ... {len(matches) - 10} more candidates")

    if not rows:
        print("\nNo cached photos matched this date range.")
        print("That usually means either:")
        print("  - the cache has very few files with EXIF date in that range")
        print("  - those photos had no EXIF date, so Picframe used file mtime instead")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
