import threading

from picframe.controller import Controller
from picframe.model import Model


class _ImageCacheStub:
    def __init__(self, rows):
        self._rows = rows

    def get_file_info_readonly(self, file_id):
        return self._rows[file_id]


class _ModelStub:
    def __init__(self, result):
        self.result = result
        self.jump_calls = []

    def get_queue_snapshot(self, limit=8):
        return {"limit": limit, **self.result}

    def get_queue_thumb_source(self, index):
        return f"/tmp/{index}.jpg"

    def set_next_file_index(self, index):
        self.jump_calls.append(index)
        return True, "ok"


class _ViewerStub:
    def __init__(self, playing=False):
        self.playing = playing
        self.reset_calls = 0
        self.stop_calls = 0

    def is_video_playing(self):
        return self.playing

    def stop_video(self):
        self.stop_calls += 1

    def reset_name_tm(self, *args, **kwargs):
        self.reset_calls += 1


def _make_model(file_list, rows, file_index, reload_pending=False, has_current=True):
    model = Model.__new__(Model)
    model._Model__file_list = file_list
    model._Model__number_of_files = len(file_list)
    model._Model__file_index = file_index
    model._Model__reload_files = reload_pending
    model._Model__current_pics = (object(), None) if has_current else (None, None)
    model._Model__file_list_lock = threading.Lock()
    model._Model__image_cache = _ImageCacheStub(rows)
    return model


def test_queue_snapshot_uses_slot_count_and_pair_labels():
    rows = {
        1: {"fname": "/photos/one.jpg", "last_modified": 11},
        2: {"fname": "/photos/two.jpg", "last_modified": 22},
        3: {"fname": "/photos/three.jpg", "last_modified": 33},
    }
    model = _make_model([(1,), (2, 3)], rows, file_index=1)

    snapshot = model.get_queue_snapshot(limit=4)

    assert snapshot["total_slots"] == 2
    assert snapshot["displayed_index"] == 0
    assert snapshot["next_index"] == 1
    assert snapshot["current_slot"]["primary_label"] == "one.jpg"
    assert snapshot["upcoming_slots"][0]["is_pair"] is True
    assert snapshot["upcoming_slots"][0]["secondary_label"] == "three.jpg"


def test_set_next_file_index_rejects_pending_reload():
    model = _make_model([(1,), (2,)], {1: {"fname": "/photos/one.jpg", "last_modified": 11},
                                       2: {"fname": "/photos/two.jpg", "last_modified": 22}},
                        file_index=1, reload_pending=True)

    success, reason = model.set_next_file_index(0)

    assert success is False
    assert reason == "reload_pending"


def test_controller_jump_forces_immediate_navigation():
    controller = Controller.__new__(Controller)
    controller._Controller__model = _ModelStub({"ok": True})
    controller._Controller__viewer = _ViewerStub(playing=False)
    controller._Controller__next_tm = 15
    controller._Controller__force_navigate = False

    result = controller.jump_to_queue_index("4")

    assert result == {"ok": True, "reason": "ok"}
    assert controller._Controller__model.jump_calls == ["4"]
    assert controller._Controller__next_tm == 0
    assert controller._Controller__force_navigate is True
    assert controller._Controller__viewer.reset_calls == 1
