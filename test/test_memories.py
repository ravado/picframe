import os
import random
import sqlite3
import time
from datetime import date, datetime

import pytest

from picframe import memories, model


def local_epoch(*args):
    return time.mktime(datetime(*args).timetuple())


# --- helpers ---

def test_years_ago_text():
    assert memories.years_ago_text(1, "{} year ago", "{} years ago") == "1 year ago"
    assert memories.years_ago_text(3, "{} year ago", "{} years ago") == "3 years ago"


def test_sql_condition_matches_same_day_in_earlier_years_only():
    db = sqlite3.connect(":memory:")
    db.execute("CREATE TABLE all_data (file_id INTEGER, exif_datetime REAL)")
    rows = [
        (1, local_epoch(2023, 10, 15, 0, 0, 1)),   # same day, 3 years ago (just after midnight)
        (2, local_epoch(2019, 10, 15, 23, 59, 0)),  # same day, 7 years ago (just before midnight)
        (3, local_epoch(2023, 10, 14, 12, 0)),     # day before
        (4, local_epoch(2023, 10, 16, 12, 0)),     # day after
        (5, local_epoch(2026, 10, 15, 9, 0)),      # today, this year
        (6, 0),                                    # no date
        (7, None),                                 # no meta row
    ]
    db.executemany("INSERT INTO all_data VALUES (?, ?)", rows)
    sql = "SELECT file_id FROM all_data WHERE " + memories.sql_condition(date(2026, 10, 15))
    assert sorted(r[0] for r in db.execute(sql)) == [1, 2]


def test_memories_each_year_gets_a_turn_and_nothing_repeats():
    rows = [(i, 2023) for i in range(10)] + [(100, 2022), (200, 2019), (201, 2019)]
    m = memories.Memories(rows, date(2026, 10, 15), random.Random(1))
    assert len(m) == 13
    first_round = [m.next() for _ in range(3)]
    assert sorted(years for _, years in first_round) == [3, 4, 7]
    seen = [file_id for file_id, _ in first_round]
    while True:
        item = m.next()
        if item is None:
            break
        seen.append(item[0])
    assert sorted(seen) == sorted(file_id for file_id, _ in rows)
    assert m.next() is None  # stays exhausted for the rest of the day


def test_memories_empty():
    assert memories.Memories([], date(2026, 10, 15)).next() is None


# --- Model integration with a fake image cache ---

class FakeImageCache:
    EXIF_TO_FIELD = {}

    def __init__(self, pic_dir, regular, memory_rows):
        self.pic_dir = pic_dir
        self.regular = regular  # file_ids returned by query_cache (incl. memories, as the db would)
        self.memory_rows = memory_rows  # (file_id, year, last_displayed)
        self.memory_where = None

    def query_cache(self, where_clause, sort_clause):
        return [(f,) for f in self.regular]

    def get_memory_candidates(self, where_clause):
        self.memory_where = where_clause
        return list(self.memory_rows)

    def get_column_names(self):
        return ["fname"]

    def get_file_info(self, file_id):
        return {"fname": os.path.join(self.pic_dir, "{}.jpg".format(file_id)),
                "last_modified": 0, "file_id": file_id, "exif_datetime": 1}

    def stop(self):
        pass


@pytest.fixture
def make_model(tmp_path, monkeypatch):
    def factory(regular, memory_rows, enabled=True, every=2):
        pic_dir = tmp_path / "pics"
        pic_dir.mkdir(exist_ok=True)
        for f in regular + [r[0] for r in memory_rows]:
            (pic_dir / "{}.jpg".format(f)).write_bytes(b"")
        cache = FakeImageCache(str(pic_dir), regular, memory_rows)
        monkeypatch.setattr(model.image_cache, "ImageCache", lambda *args, **kwargs: cache)
        config = tmp_path / "config.yaml"
        config.write_text(
            "viewer: {}\n"
            "mqtt: {}\nhttp: {}\nperipherals: {}\n"
            "model:\n"
            "  pic_dir: '%s'\n  db_file: '%s'\n  shuffle: False\n  recent_n: 0\n"
            "  memories: %s\n  memories_every: %d\n"
            % (pic_dir, tmp_path / "db.db3", enabled, every))
        return model.Model(str(config)), cache
    return factory


def next_shown(m, n):
    shown = []
    for _ in range(n):
        pic = m.get_next_file()[0]
        shown.append((pic.file_id, pic.years_ago))
    return shown


def test_model_mixes_in_memories_once_and_keeps_them_out_of_regular(make_model):
    m, cache = make_model([1, 10, 2, 3, 11], [(10, "2023", 0), (11, "2019", 0)])
    shown = next_shown(m, 8)
    memory_slides = [s for s in shown if s[1] is not None]
    assert sorted(memory_slides) == [(10, 3), (11, 7)]
    assert shown[1][1] is not None and shown[3][1] is not None  # every 2nd slide while memories last
    regular = [f for f, years in shown if years is None]
    assert regular == [1, 2, 3, 1, 2, 3]  # memories never come round in the regular slideshow
    assert memories.sql_condition(date.today()) in cache.memory_where


def test_model_skips_memories_already_shown_today(make_model):
    shown_earlier = time.time()
    m, _ = make_model([1, 2, 10, 11], [(10, "2023", shown_earlier), (11, "2019", 0)])
    shown = next_shown(m, 6)
    assert [s for s in shown if s[1] is not None] == [(11, 7)]
    assert 10 not in [f for f, _ in shown]  # already shown today, so not repeated anywhere


def test_model_back_from_memory_shows_previous_image(make_model):
    m, _ = make_model([1, 2, 3], [(10, "2023", 0)])
    assert next_shown(m, 2) == [(1, None), (10, 3)]
    m.set_next_file_to_previous_file()
    assert next_shown(m, 1) == [(1, None)]


def test_model_back_steps_over_memory_in_regular_list(make_model):
    m, _ = make_model([1, 10, 2, 3], [(10, "2023", 0)], every=10)
    assert next_shown(m, 2) == [(1, None), (2, None)]
    m.set_next_file_to_previous_file()
    assert next_shown(m, 1) == [(1, None)]


def test_model_back_with_only_memories_does_not_crash(make_model):
    m, _ = make_model([], [(10, "2023", 0)], every=1)
    assert next_shown(m, 1) == [(10, 3)]
    m.set_next_file_to_previous_file()


def test_model_keeps_portrait_partner_of_memory(make_model):
    m, cache = make_model([1, 2], [(10, "2023", 0)], every=10)
    cache.regular = None
    cache.query_cache = lambda where, sort: [(1,), (10, 2)]
    shown = [tuple(p.file_id for p in m.get_next_file() if p is not None) for _ in range(2)]
    assert shown == [(1,), (2,)]


def test_model_memories_off(make_model):
    m, cache = make_model([1, 10, 2], [(10, "2023", 0)], enabled=False)
    assert next_shown(m, 3) == [(1, None), (10, None), (2, None)]
    assert cache.memory_where is None
