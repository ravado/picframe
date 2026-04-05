import random

from picframe import image_cache
from picframe.image_cache import ImageCache, weighted_shuffle_rows


class _DummyCursor:
    def __init__(self, rows):
        self._rows = rows
        self.row_factory = None

    def execute(self, _sql):
        return self

    def fetchall(self):
        return self._rows


class _DummyDb:
    def __init__(self, rows):
        self._rows = rows

    def cursor(self):
        return _DummyCursor(self._rows)


def _make_cache(rows, portrait_pairs):
    cache = ImageCache.__new__(ImageCache)
    cache._ImageCache__db = _DummyDb(rows)
    cache._ImageCache__portrait_pairs = portrait_pairs
    return cache


def test_weighted_shuffle_prefers_lower_display_count():
    rows = [
        {"file_id": 1, "displayed_count": 0, "last_modified": 100.0, "is_portrait": 0},
        {"file_id": 2, "displayed_count": 5, "last_modified": 100.0, "is_portrait": 0},
    ]

    total_position = {1: 0, 2: 0}
    for seed in range(300):
        random.seed(seed)
        ordered_ids = [row["file_id"] for row in weighted_shuffle_rows(rows)]
        for idx, file_id in enumerate(ordered_ids):
            total_position[file_id] += idx

    assert total_position[1] < total_position[2]


def test_weighted_shuffle_prefers_older_photos_when_counts_match():
    rows = [
        {"file_id": 1, "displayed_count": 0, "last_modified": 10.0, "is_portrait": 0},
        {"file_id": 2, "displayed_count": 0, "last_modified": 100.0, "is_portrait": 0},
    ]

    total_position = {1: 0, 2: 0}
    for seed in range(300):
        random.seed(seed)
        ordered_ids = [row["file_id"] for row in weighted_shuffle_rows(rows)]
        for idx, file_id in enumerate(ordered_ids):
            total_position[file_id] += idx

    assert total_position[1] < total_position[2]


def test_weighted_shuffle_keeps_recent_partition_first():
    rows = [
        {"file_id": 1, "displayed_count": 5, "last_modified": 10.0, "is_portrait": 0},
        {"file_id": 2, "displayed_count": 0, "last_modified": 20.0, "is_portrait": 0},
        {"file_id": 3, "displayed_count": 5, "last_modified": 90.0, "is_portrait": 0},
        {"file_id": 4, "displayed_count": 0, "last_modified": 100.0, "is_portrait": 0},
    ]

    random.seed(1)
    ordered_ids = [row["file_id"] for row in weighted_shuffle_rows(rows, recent_cutoff=50.0)]

    assert set(ordered_ids[:2]) == {3, 4}
    assert set(ordered_ids[2:]) == {1, 2}


def test_query_cache_shuffle_returns_single_tuples_without_portrait_pairs(monkeypatch):
    rows = [
        {"file_id": 1, "displayed_count": 0, "last_modified": 10.0, "is_portrait": 0},
        {"file_id": 2, "displayed_count": 2, "last_modified": 20.0, "is_portrait": 0},
        {"file_id": 3, "displayed_count": 1, "last_modified": 30.0, "is_portrait": 0},
    ]

    monkeypatch.setattr(image_cache, "weighted_shuffle_rows", lambda payload_rows, recent_cutoff=None: list(payload_rows))
    cache = _make_cache(rows, portrait_pairs=False)

    playlist = cache.query_cache_shuffle("1=1")

    assert playlist == [(1,), (2,), (3,)]


def test_query_cache_shuffle_pairs_portraits_in_global_order(monkeypatch):
    rows = [
        {"file_id": 11, "displayed_count": 0, "last_modified": 1.0, "is_portrait": 1},
        {"file_id": 12, "displayed_count": 0, "last_modified": 2.0, "is_portrait": 0},
        {"file_id": 13, "displayed_count": 0, "last_modified": 3.0, "is_portrait": 1},
        {"file_id": 14, "displayed_count": 0, "last_modified": 4.0, "is_portrait": 1},
        {"file_id": 15, "displayed_count": 0, "last_modified": 5.0, "is_portrait": 0},
        {"file_id": 16, "displayed_count": 0, "last_modified": 6.0, "is_portrait": 1},
    ]

    monkeypatch.setattr(image_cache, "weighted_shuffle_rows", lambda payload_rows, recent_cutoff=None: list(payload_rows))
    cache = _make_cache(rows, portrait_pairs=True)

    playlist = cache.query_cache_shuffle("1=1")

    expected_playlist = [(11, 13), (12,), (14, 16), (15,)]
    assert playlist == expected_playlist

    portrait_ids = [entry for entry in rows if entry["is_portrait"] == 1]
    portrait_sequence = [row["file_id"] for row in portrait_ids]
    portrait_ids_from_playlist = [
        file_id
        for slot in playlist
        for file_id in slot
        if file_id in portrait_sequence
    ]
    assert portrait_ids_from_playlist == portrait_sequence
