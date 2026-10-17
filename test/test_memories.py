import json
import os
import random
import shutil
import sqlite3
import time
from datetime import date, datetime
from types import SimpleNamespace

import pytest
from PIL.TiffImagePlugin import IFDRational

from picframe import get_image_meta, image_cache, memories, model


def local_epoch(*args):
    return time.mktime(datetime(*args).timetuple())


# --- helpers ---

def test_years_ago_text():
    assert memories.years_ago_text(1, "{} year ago", "{} years ago") == "1 year ago"
    assert memories.years_ago_text(3, "{} year ago", "{} years ago") == "3 years ago"


def test_sql_condition_matches_same_day_in_earlier_years_only():
    db = sqlite3.connect(":memory:")
    db.execute("CREATE TABLE all_data (file_id INTEGER, exif_datetime REAL)")
    db.execute("CREATE TABLE exif (file_id INTEGER PRIMARY KEY, json TEXT)")

    def exif(dt):
        return json.dumps({"EXIF DateTimeOriginal": dt})

    rows = [
        # file_id, exif_datetime, exif json (None = no exif row yet)
        (1, local_epoch(2023, 10, 15, 0, 0, 1), exif("2023:10:15 00:00:01")),    # 3 years ago, just after midnight
        (2, local_epoch(2019, 10, 15, 23, 59, 0), exif("2019:10:15 23:59:00")),  # 7 years ago, just before midnight
        (3, local_epoch(2023, 10, 14, 12, 0), exif("2023:10:14 12:00:00")),      # day before
        (4, local_epoch(2023, 10, 16, 12, 0), exif("2023:10:16 12:00:00")),      # day after
        (5, local_epoch(2026, 10, 15, 9, 0), exif("2026:10:15 09:00:00")),       # today, this year
        (6, 0, None),                                                           # no date
        (7, None, None),                                                        # no meta row
        (8, local_epoch(2022, 10, 15, 12, 0), "{}"),                            # date from file mtime, no EXIF
        (9, local_epoch(2022, 10, 15, 12, 0), exif("0000:00:00 00:00:00")),      # bogus tag, mtime used instead
        (10, local_epoch(2022, 10, 15, 12, 0), None),                           # not backfilled yet
        (11, local_epoch(2021, 10, 15, 8, 0),
         json.dumps({"Image DateTimeOriginal": "2021:10:15 08:00:00.123"})),    # tag in IFD0, with subseconds
    ]
    db.executemany("INSERT INTO all_data VALUES (?, ?)", [r[:2] for r in rows])
    db.executemany("INSERT INTO exif VALUES (?, ?)", [(r[0], r[2]) for r in rows if r[2] is not None])
    sql = "SELECT file_id FROM all_data WHERE " + memories.sql_condition(date(2026, 10, 15))
    assert sorted(r[0] for r in db.execute(sql)) == [1, 2, 11]


def test_tags_to_json_keeps_plain_values_and_drops_binary_and_oversized():
    tags = {
        "EXIF DateTimeOriginal": "2023:10:15 14:32:07\x00",
        "Image Make": "Apple",
        "EXIF ISOSpeedRatings": 50,
        "EXIF FNumber": IFDRational(8, 5),
        "GPS GPSLatitude": (IFDRational(50, 1), IFDRational(27, 1), IFDRational(1234, 100)),
        "EXIF MakerNote": b"\x00\x01" * 5000,
        "EXIF ExposureBiasValue": IFDRational(0, 0),  # NaN
        "EXIF UserComment": "x" * 1000,
        "IPTC Keywords": ["beach", "family"],
    }
    stored = json.loads(get_image_meta.tags_to_json(tags))
    assert stored == {
        "EXIF DateTimeOriginal": "2023:10:15 14:32:07",
        "Image Make": "Apple",
        "EXIF ISOSpeedRatings": 50,
        "EXIF FNumber": 1.6,
        "GPS GPSLatitude": [50.0, 27.0, 12.34],
        "IPTC Keywords": ["beach", "family"],
    }


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


# --- exif table in a real ImageCache db ---

IMAGES = os.path.join(os.path.dirname(__file__), "images")


def wait_for(fn, timeout=30):
    end = time.time() + timeout
    while time.time() < end:
        if fn():
            return
        time.sleep(0.1)
    raise AssertionError("timed out")


def exif_rows(db_file):
    db = sqlite3.connect(db_file)
    try:
        return dict(db.execute("SELECT basename, exif.json FROM file JOIN exif USING (file_id)").fetchall())
    finally:
        db.close()


def test_image_cache_stores_exif_json_and_backfills_old_db(tmp_path):
    pic_dir = tmp_path / "pics"
    pic_dir.mkdir()
    shutil.copy(os.path.join(IMAGES, "AlleExif.JPG"), pic_dir / "AlleExif.JPG")
    shutil.copy(os.path.join(IMAGES, "noimage.jpg"), pic_dir / "noimage.jpg")
    db_file = str(tmp_path / "db.db3")

    # new db: every scanned file gets an exif row
    cache = image_cache.ImageCache(str(pic_dir), False, db_file, None, 0.1)
    try:
        wait_for(lambda: len(exif_rows(db_file)) == 2)
    finally:
        cache.stop()
    rows = exif_rows(db_file)
    assert json.loads(rows["AlleExif"])["EXIF DateTimeOriginal"].startswith("20")
    assert "EXIF DateTimeOriginal" not in json.loads(rows["noimage"])

    # turn it back into a v3 db with play stats, as on an existing frame
    db = sqlite3.connect(db_file)
    db.execute("DROP TRIGGER Clean_Exif_Trigger")
    db.execute("DROP TABLE exif")
    db.execute("UPDATE db_info SET schema_version = 3")
    db.execute("UPDATE file SET displayed_count = 5, last_displayed = 123")
    ids_before = dict(db.execute("SELECT basename, file_id FROM file").fetchall())
    db.commit()
    db.close()

    # upgrade: rows are filled in by the background backfill, ids and stats are kept
    cache = image_cache.ImageCache(str(pic_dir), False, db_file, None, 0.1)
    try:
        wait_for(lambda: len(exif_rows(db_file)) == 2)
    finally:
        cache.stop()
    db = sqlite3.connect(db_file)
    assert db.execute("SELECT schema_version FROM db_info").fetchone()[0] == 4
    assert dict(db.execute("SELECT basename, file_id FROM file").fetchall()) == ids_before
    assert db.execute("SELECT DISTINCT displayed_count, last_displayed FROM file").fetchall() == [(5, 123)]
    db.close()
    assert exif_rows(db_file) == rows


def test_backfill_skips_missing_files_and_retries_them_later(tmp_path):
    pic_dir = tmp_path / "pics"
    pic_dir.mkdir()
    shutil.copy(os.path.join(IMAGES, "AlleExif.JPG"), pic_dir / "AlleExif.JPG")
    shutil.copy(os.path.join(IMAGES, "test3.HEIC"), pic_dir / "test3.HEIC")
    db_file = str(tmp_path / "db.db3")
    cache = image_cache.ImageCache(str(pic_dir), False, db_file, None, 0.1)
    try:
        wait_for(lambda: len(exif_rows(db_file)) == 2)
    finally:
        cache.stop()
    db = sqlite3.connect(db_file)
    db.execute("DELETE FROM exif")  # as if upgraded from v3
    db.commit()
    db.close()

    # the HEIC is unavailable (e.g. share not mounted) during the first backfill: no row is written for it
    os.rename(pic_dir / "test3.HEIC", tmp_path / "test3.HEIC")
    cache = image_cache.ImageCache(str(pic_dir), False, db_file, None, 0.1)
    try:
        wait_for(lambda: cache._ImageCache__exif_backfill_done)
    finally:
        cache.stop()
    assert list(exif_rows(db_file)) == ["AlleExif"]

    # once it is back (same mtime, so not seen as a changed file) it is filled in
    os.rename(tmp_path / "test3.HEIC", pic_dir / "test3.HEIC")
    cache = image_cache.ImageCache(str(pic_dir), False, db_file, None, 0.1)
    try:
        wait_for(lambda: len(exif_rows(db_file)) == 2)
    finally:
        cache.stop()
    assert json.loads(exif_rows(db_file)["test3"])["EXIF DateTimeOriginal"].startswith("20")


def test_backfill_gets_past_missing_files_with_photos_in_subfolders(tmp_path, monkeypatch):
    # the root holds only subfolders, so it is reported as modified on every scan
    monkeypatch.setattr(image_cache.ImageCache, "EXIF_BACKFILL_BATCH", 2)
    year_dir = tmp_path / "pics" / "2020"
    year_dir.mkdir(parents=True)
    for name in ("a", "b", "c", "d"):
        shutil.copy(os.path.join(IMAGES, "AlleExif.JPG"), year_dir / (name + ".jpg"))
    db_file = str(tmp_path / "db.db3")
    cache = image_cache.ImageCache(str(tmp_path / "pics"), False, db_file, None, 0.05)
    try:
        wait_for(lambda: len(exif_rows(db_file)) == 4)
    finally:
        cache.stop()
    db = sqlite3.connect(db_file)
    db.execute("DELETE FROM exif")  # as if upgraded from v3
    names = [r[0] for r in db.execute("SELECT basename FROM file ORDER BY file_id")]
    db.commit()
    db.close()
    for name in names[:3]:  # the lowest ids are gone from disk, more than a batch
        os.remove(year_dir / (name + ".jpg"))

    cache = image_cache.ImageCache(str(tmp_path / "pics"), False, db_file, None, 0.05)
    try:
        wait_for(lambda: list(exif_rows(db_file)) == [names[3]], timeout=10)
    finally:
        cache.stop()


def test_insert_failure_releases_db_lock(tmp_path):
    pic_dir = tmp_path / "pics"
    pic_dir.mkdir()
    shutil.copy(os.path.join(IMAGES, "AlleExif.JPG"), pic_dir / "a.jpg")
    db_file = str(tmp_path / "db.db3")
    cache = image_cache.ImageCache(str(pic_dir), False, db_file, None, 0.05)
    try:
        wait_for(lambda: len(exif_rows(db_file)) == 1)
        cache.pause_looping(True)
        time.sleep(0.2)
        cache._ImageCache__db.execute("DROP TABLE exif")  # any sqlite error inside the insert
        with pytest.raises(sqlite3.Error):
            cache._ImageCache__insert_file(str(pic_dir / "a.jpg"))
        lock = cache._ImageCache__db_write_lock
        released = lock.acquire(timeout=1)
        lock.release()  # either way, so stop() below can finish instead of hanging the test run
        assert released, "db write lock left held, the next write would hang"
    finally:
        cache.pause_looping(False)
        cache.stop()


def test_changed_file_keeps_file_id_and_one_exif_row(tmp_path):
    pic_dir = tmp_path / "pics"
    pic_dir.mkdir()
    photo = pic_dir / "a.jpg"
    shutil.copy(os.path.join(IMAGES, "AlleExif.JPG"), photo)
    db_file = str(tmp_path / "db.db3")
    cache = image_cache.ImageCache(str(pic_dir), False, db_file, None, 0.05)
    try:
        wait_for(lambda: len(exif_rows(db_file)) == 1)
        for i in range(1, 4):  # the file is edited three times
            t = time.time() + 10 * i
            os.utime(photo, (t, t))
            os.utime(pic_dir, (t, t))
            wait_for(lambda: sqlite3.connect(db_file).execute("SELECT last_modified FROM file").fetchone()[0] == t)
    finally:
        cache.stop()
    db = sqlite3.connect(db_file)
    assert db.execute("SELECT file_id FROM file").fetchall() == [(1,)]
    assert db.execute("SELECT count(*) FROM exif").fetchone()[0] == 1
    assert db.execute("SELECT count(*) FROM meta").fetchone()[0] == 1
    db.close()


def test_backfill_retries_file_after_read_error(tmp_path, monkeypatch):
    monkeypatch.setattr(image_cache.ImageCache, "EXIF_BACKFILL_RETRY", 0.3)
    pic_dir = tmp_path / "pics"
    pic_dir.mkdir()
    photo = str(pic_dir / "a.jpg")
    shutil.copy(os.path.join(IMAGES, "AlleExif.JPG"), photo)
    db_file = str(tmp_path / "db.db3")
    cache = image_cache.ImageCache(str(pic_dir), False, db_file, None, 0.05)
    try:
        wait_for(lambda: len(exif_rows(db_file)) == 1)
    finally:
        cache.stop()
    db = sqlite3.connect(db_file)
    db.execute("DELETE FROM exif")  # as if upgraded from v3
    db.commit()
    db.close()

    real_getmtime = os.path.getmtime
    failures = []

    def getmtime_failing_once(path):
        if path == photo and not failures:
            failures.append(path)
            raise OSError("I/O error")
        return real_getmtime(path)
    monkeypatch.setattr(image_cache.os.path, "getmtime", getmtime_failing_once)
    cache = image_cache.ImageCache(str(pic_dir), False, db_file, None, 0.05)
    try:
        wait_for(lambda: len(exif_rows(db_file)) == 1)  # filled in by the retry pass
    finally:
        cache.stop()
    assert failures == [photo]


# --- "N years ago" label in the viewer ---

class FakeSprite:
    def __init__(self, width, height):
        self.width, self.height = width, height
        self.pos = None

    def position(self, x, y, z):
        self.pos = (x, y)

    def set_alpha(self, alpha):
        pass


class FakeFixedString:
    made = []

    def __init__(self, font, text, font_size, justify="C", **kwargs):
        self.text, self.justify = text, justify
        self.sprite = FakeSprite(len(text) * font_size // 2, font_size)
        FakeFixedString.made.append(self)


class FakeDisplay:
    width, height = 1920, 1080


@pytest.fixture
def viewer(monkeypatch):
    try:
        from picframe import viewer_display
    except Exception as e:  # pi3d raises AttributeError, not ImportError, when the GLES library is missing
        pytest.skip("picframe.viewer_display needs pi3d and the GLES library: {}".format(e))
    monkeypatch.setattr(viewer_display.pi3d, "FixedString", FakeFixedString)
    FakeFixedString.made = []

    def factory(**config):
        cfg = dict(model.DEFAULT_CONFIG['viewer'])
        cfg.update(config)
        v = viewer_display.ViewerDisplay(cfg)
        v._ViewerDisplay__display = FakeDisplay()
        v._ViewerDisplay__flat_shader = None
        v._ViewerDisplay__textblocks = [None, None]
        v._ViewerDisplay__slide = SimpleNamespace(unif=[1.0] * 60)  # brightness is unif[55]
        return v
    return factory


def memory_pic(years):
    pic = model.Pic("/pics/2023/a.jpg", 0, 1, exif_datetime=local_epoch(2023, 10, 15, 12, 0))
    pic.years_ago = years
    return pic


def test_memory_label_is_its_own_text_away_from_the_clock(viewer):
    v = viewer(show_text="", show_text_tm=0.0, clock_justify="R")
    label = v._ViewerDisplay__make_memory_label(memory_pic(3))
    assert label.text == "3 years ago" and label.justify == "L"
    x, y = label.sprite.pos
    assert x < 0 and y > 0  # top left
    assert viewer(clock_justify="L")._ViewerDisplay__make_memory_label(memory_pic(1)).justify == "R"
    assert v._ViewerDisplay__make_memory_label(model.Pic("/pics/b.jpg", 0, 2)) is None  # not a memory


def test_memory_label_not_part_of_fading_text(viewer):
    v = viewer(show_text="name")
    v._ViewerDisplay__make_text(memory_pic(3), False)
    assert [f.text for f in FakeFixedString.made] == ["a.jpg"]


# --- "memories today" status for the web page and Home Assistant ---

def test_model_memories_status(make_model):
    m, _ = make_model([1, 2, 3], [(10, "2023", 0), (11, "2019", 0), (12, "2019", time.time())], every=2)
    assert m.memories_status() is None  # not looked up before the first slide
    next_shown(m, 2)  # 1, then a memory
    assert m.memories_status() == (3, 2, 1)  # 12 was already shown today, one more shown now


def test_controller_memories_today_text():
    from unittest.mock import MagicMock
    from picframe.controller import Controller
    m = MagicMock()
    c = Controller(m, MagicMock())
    m.memories = False
    assert c.memories_today == "off"
    m.memories = True
    m.memories_status.return_value = None
    assert c.memories_today == "not checked yet"
    m.memories_status.return_value = (0, 0, 0)
    assert c.memories_today == "none found"
    m.memories_status.return_value = (3, 1, 2)
    assert c.memories_today == "3 found, 1 shown, 2 left"


class FakeHttpController:
    memories_today = "3 found, 1 shown, 2 left"

    @property
    def shuffle(self):
        return True

    @shuffle.setter
    def shuffle(self, val):
        pass


def test_http_sends_memories_today(tmp_path):
    import json as json_module
    import socket
    import urllib.request
    from picframe.interface_http import InterfaceHttp
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
    server = InterfaceHttp(FakeHttpController(), str(tmp_path), str(tmp_path), str(tmp_path / "none.jpg"), port=port)
    try:
        for query in ("all", "memories_today"):
            with urllib.request.urlopen("http://127.0.0.1:{}/?{}".format(port, query), timeout=5) as response:
                assert json_module.loads(response.read())["memories_today"] == "3 found, 1 shown, 2 left"
    finally:
        server.shutdown()
        server.server_close()
