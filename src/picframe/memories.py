"""On This Day memories: photos taken on today's month and day in earlier years."""
import random


def sql_condition(today):
    """SQL expression matching photos taken on today's month and day in an earlier year.

    exif_datetime is stored as a local time epoch (see ImageCache), so it is
    converted back with the 'localtime' modifier. ImageCache falls back to the
    file's modification time when there is no usable EXIF date, so the date must
    also match the photo's DateTimeOriginal tag in the exif table. This leaves out
    files without a real EXIF date, and videos.
    """
    return ("(exif_datetime > 0"
            " AND strftime('%m-%d', exif_datetime, 'unixepoch', 'localtime') = '{:02d}-{:02d}'"
            " AND strftime('%Y', exif_datetime, 'unixepoch', 'localtime') < '{:04d}'"
            " AND EXISTS (SELECT 1 FROM exif WHERE exif.file_id = all_data.file_id"
            " AND substr(COALESCE(json_extract(exif.json, '$.\"EXIF DateTimeOriginal\"'),"
            " json_extract(exif.json, '$.\"Image DateTimeOriginal\"')), 1, 10)"
            " = strftime('%Y:%m:%d', all_data.exif_datetime, 'unixepoch', 'localtime')))"
            ).format(today.month, today.day, today.year)


def years_ago_text(years, text_one, text_other):
    return (text_one if years == 1 else text_other).format(years)


class Memories:
    """Today's memories, handed out one at a time without repeats.

    Each year gets one turn per round, in random order, so a year with many
    photos on this day does not crowd out a year with only a few. Within a
    year the photos come out in random order. Once every photo has been
    handed out, next() returns None for the rest of the day.
    """

    def __init__(self, rows, today, rng=None):
        # rows is an iterable of (file_id, year) for photos not yet shown today
        self.today = today
        self.__rng = rng if rng is not None else random.Random()
        self.__by_year = {}
        for file_id, year in rows:
            self.__by_year.setdefault(int(year), []).append(file_id)
        for file_ids in self.__by_year.values():
            self.__rng.shuffle(file_ids)
        self.__round = []

    def __len__(self):
        return sum(len(file_ids) for file_ids in self.__by_year.values())

    def next(self):
        """Return (file_id, years_ago), or None when all of today's memories have been shown."""
        self.__round = [year for year in self.__round if self.__by_year[year]]
        if not self.__round:
            self.__round = [year for year, file_ids in self.__by_year.items() if file_ids]
            if not self.__round:
                return None
            self.__rng.shuffle(self.__round)
        year = self.__round.pop()
        return self.__by_year[year].pop(), self.today.year - year
