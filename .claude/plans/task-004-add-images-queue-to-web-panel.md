# Task 004: Add Images Queue To Web Panel

## Context

The current HTTP panel shows the active image preview and a set of control cards, but it does not expose the slideshow queue that the model already keeps in memory.

This fork now builds a full playlist ahead of playback in `Model.__file_list`, which makes it possible to expose a queue preview in the web UI without changing slideshow semantics.

The user wants two improvements:

- a visible queue of upcoming images in the HTTP panel
- clickable queue entries that jump playback directly to the selected slot

The user also wants small image previews in the queue to make it easier to identify photos. Because the target device can be low-power hardware such as Raspberry Pi Zero class systems, the implementation must stay lightweight and must not block initial page load on thumbnail generation.

---

## Goals

Add a queue panel to the HTTP UI that:

- shows the current slot and a short preview of upcoming slots
- allows clicking a queue item to jump directly to that slot
- shows small thumbnail previews for queue items
- loads quickly even on slow hardware
- preserves the current slideshow lifecycle and weighted shuffle behavior
- fits the existing HTTP server routing and auth flow

---

## Non-Goals

This task must **not**:

- redesign slideshow ordering logic
- rebuild or reorder the queue when the user clicks a queued item
- add drag-and-drop queue editing
- add a full gallery browser of the entire library
- generate thumbnails for the full playlist up front
- add a frontend framework or heavy client-side state layer

The queue click behavior may simply skip over intermediate entries.

---

## Desired User Experience

When the user opens the web panel:

- the main page should render quickly
- a queue card should appear under or near the main image preview
- the queue card should show a compact list of the next few slots
- each slot should display:
  - slot number
  - filename or short label
  - a small image preview
  - a `pair` indicator when the slot contains a portrait pair
- clicking a slot should make that slot the next item shown

The user should not have to wait for thumbnail generation before the page itself becomes usable.

---

## Implementation Strategy

## Files To Modify

| File | Change |
|------|--------|
| `src/picframe/model.py` | Add read-only queue snapshot helpers and a slot-jump method |
| `src/picframe/controller.py` | Expose queue snapshot and jump-to-slot actions to the HTTP layer |
| `src/picframe/interface_http.py` | Add queue JSON endpoint and thumbnail endpoint; keep initial page render cheap |
| `src/picframe/html/index.html` | Add queue card and queue markup placeholders |
| `src/picframe/html/pf_functions.js` | Fetch queue data separately, render queue list, trigger jump requests, refresh thumbnails lazily |
| `src/picframe/html/style.css` | Add lightweight queue card styles |
| `test/` | Add focused tests for queue snapshot shape, jump behavior, and thumbnail endpoint behavior where practical |

---

## Detailed Design

### 1. Keep queue ownership in `Model`

The queue already exists in memory as `self.__file_list`.

Add model-level helpers that expose queue data without leaking internal mutation details:

- `get_queue_snapshot(limit=...)`
- `set_next_file_index(index)` or equivalent slot-jump method

The snapshot should be read-only and derived from the current playlist state.

Recommended snapshot contents:

- `displayed_index`
- `next_index`
- `total_slots`
- `current_slot`
- `upcoming_slots`

Pointer semantics must be explicit:

- `self.__file_index` points to the next slot to be read by `get_next_file()`
- the currently displayed slot is therefore `self.__file_index - 1`
- snapshot code must not report `self.__file_index` as the currently displayed slot

Recommended rules:

- `displayed_index` should be `None` before anything has been shown
- `next_index` should be the slot that will be consumed by the next navigation event

Each slot should preserve playlist semantics:

- single image slot -> one file id
- portrait pair slot -> two file ids

To support the web panel, the snapshot should include lightweight labels such as:

- `slot_index`
- `file_ids`
- `is_pair`
- `primary_fname`
- `secondary_fname` when relevant

Avoid embedding image bytes or expensive metadata in this snapshot.

Do not use `get_number_of_files()` for queue totals. That method counts files across tuple members and is wrong for queue slot counts when portrait pairs are enabled. Use `len(self.__file_list)` semantics for `total_slots`.

### 2. Implement simple jump-to-slot behavior

Jump behavior should stay intentionally small.

When the user clicks a queue item:

- set the model’s next slot pointer to that queue index
- trigger the same immediate navigation path used by `next()`

This means intermediate queue entries are skipped. That is acceptable and explicitly desired for this task.

Important constraint:

- jump by playlist slot index, not by `file_id`

This preserves correct behavior for portrait-pair slots.

Reload edge case:

- if `self.__reload_files` is already true when a jump is requested, the next `get_next_file()` call will rebuild the playlist and reset the pointer
- v1 should handle this explicitly rather than silently losing the jump target

Recommended v1 behavior:

- reject the jump request with a small status payload such as `{"ok": false, "reason": "reload_pending"}`
- frontend should then refresh queue state and let the user try again after reload completes

### 3. Expose queue state through the controller

The HTTP server should not inspect model internals directly beyond the controller boundary.

Add controller methods such as:

- `get_queue_snapshot(limit=8)` or similar
- `jump_to_queue_index(index)`

`jump_to_queue_index()` should:

- validate or delegate validation of the target index
- set the next slot pointer
- force immediate transition in the same way manual navigation does

Important controller detail:

- the controller method must mirror the relevant parts of `next()`
- specifically it must set `self.__next_tm = 0` and `self.__force_navigate = True`

Changing only the model pointer is not enough.

### 4. Add dedicated HTTP endpoints

Do not overload the generic `/?all` response with queue and thumbnail payloads.

Important routing constraint:

- the current `do_GET()` implementation only distinguishes between requests with and without `?`
- path-only endpoints such as `/api/queue` will not work unless `do_GET()` is explicitly extended before the existing static-file branch

Two valid implementation options:

1. Extend `do_GET()` with explicit path-prefix routing before static file serving.
2. Use query-string style endpoints that fit the current architecture, for example:
   - `/?queue_snapshot=1`
   - `/?queue_jump=5`
   - `/?queue_thumb=5`

Recommended default for minimal change:

- keep query-style queue endpoints because they fit the existing server structure with less routing churn

Queue operations should still remain logically separate from the generic setter polling path.

All new queue and thumbnail routes must remain inside the existing `do_AUTHHEAD()` protection flow.

Recommended behavior:

- queue JSON endpoint returns only small structured metadata
- thumbnail endpoint returns a small JPEG image for one slot
- jump endpoint triggers the slot jump and returns a small success or failure JSON payload

### 5. Keep page load non-blocking

This is the most important performance rule.

The initial HTML render must not synchronously generate queue thumbnails.

Instead:

- render the page shell immediately
- fetch queue metadata separately
- request thumbnails as independent image URLs

That way:

- the page becomes interactive immediately
- slow thumbnail generation affects only individual queue images
- the queue text can appear before the thumbnails finish loading

### 6. Thumbnail generation strategy

Thumbnail generation must be conservative and cache-friendly.

Recommended behavior:

- generate thumbnails on demand per queue slot
- resize server-side to a small JPEG, for example around `96x72` or `128x96`
- use the first image in a portrait pair as the thumbnail source in v1
- apply EXIF-aware transpose before resizing so rotated images do not appear sideways
- if generation fails, return a placeholder or an empty response that the UI can tolerate

Implementation notes:

- reuse the existing `heif_to_image()` helper for HEIC/HEIF sources
- for standard image types, open via Pillow and then run `ImageOps.exif_transpose()`

Do not:

- precompute thumbnails for the whole playlist
- decode many queue images during page render
- build a large thumbnail grid

### 7. Thumbnail caching

Use a simple cache keyed by source identity, not by queue index alone.

Recommended cache key inputs:

- source file path
- source file modification time
- requested thumbnail size

Acceptable implementations:

- small in-memory cache
- cache files in a lightweight temporary directory

The cache does not need to be sophisticated. It only needs to avoid regenerating the same small preview repeatedly during normal use.

Memory constraint:

- the cache must be bounded
- v1 should use a small cap, for example around 20 to 30 thumbnails, with simple LRU-style eviction

### 8. Frontend rendering

The queue UI should stay small and readable.

Recommended queue card structure:

- queue summary row
  - current item label
  - slot counter such as `14 / 286`
- list of next 6 to 8 slots
- each row contains
  - small thumbnail box
  - filename
  - optional sublabel for second file in a pair
  - `pair` badge when needed
  - click target for jumping

Avoid:

- masonry layouts
- infinite scrolling
- client-side reordering
- thumbnail animations

The queue list should refresh:

- on initial page load
- after `next`, `back`, or jump actions
- on a slow timer, for example 30 to 60 seconds

Concrete JS integration rule:

- add a dedicated `refreshQueue()` function in `pf_functions.js`
- call it after successful `next`, `back`, and queue jump actions
- keep preview-image refresh and queue refresh as two explicit steps in the existing action flow

Do not rely on the jump endpoint to return a full updated queue payload unless there is a clear reason to do so.

### 9. Data volume constraints

The queue endpoint should return only a small window of the playlist.

Recommended default:

- current slot
- next 8 slots

Optional fields:

- `remaining_slots`
- `total_slots`

Do not return the entire playlist by default, especially for large libraries.

Filename lookup note:

- `self.__file_list` stores file ids, not filenames
- resolving display labels will require bounded lookups for the visible queue window
- that cost is acceptable for a small window such as 6 to 8 slots, but should not be expanded to the full playlist by default

If a larger queue view is desired later, add pagination in a future task.

### 10. Pair-slot representation

Portrait-pair slots should remain visible as one queue entry because that matches slideshow behavior.

For queue display:

- the row represents one playlist slot
- show one thumbnail based on the first file in the pair
- add a `pair` badge
- optionally show both filenames in stacked text

Do not split a pair into two separate clickable queue rows.

---

## Suggested UI Layout

Lightweight target structure:

```text
+----------------------------------------------------------------------------------+
| PicFrame                                                           [ ON / OFF ] |
+----------------------------------------------------------------------------------+
|                                                                                  |
|                         main image preview with nav controls                      |
|                                                                                  |
+----------------------------------------------------------------------------------+
| Queue                                                            slot 14 / 286   |
| [img] 15. park_walk_104.heic                                        [jump]       |
| [img] 16. family_trip_008.jpg                                       [jump]       |
| [img] 17. kids_011 + kids_012                                [pair] [jump]       |
| [img] 18. kitchen_042.jpg                                          [jump]       |
| [img] 19. garden_019.jpg                                           [jump]       |
| [img] 20. album_201 + album_202                             [pair] [jump]       |
+----------------------------------------------------------------------------------+
| display controls                    | text overlays                              |
| filters                             | actions                                    |
+----------------------------------------------------------------------------------+
```

The queue card should sit close to the main preview because it is part of playback navigation, not secondary configuration.

In the current HTML structure, insert the queue card between:

- `<section class="frame-wrapper">`
- and `<div id="controls">`

Do not bury the queue inside `#controls`.

### 11. Thread safety

The HTTP server runs in its own thread, while slideshow playback and playlist reloads happen elsewhere.

That means queue reads are concurrent with:

- `get_next_file()`
- playlist rebuilds
- deletion and reload flows

The implementation must take a stable snapshot before serializing queue state.

Acceptable approaches:

- protect queue reads and writes with a small lock around playlist state
- or copy the relevant window of `self.__file_list` under a lock, then perform slower filename lookups after releasing it

The goal is not perfect transactional semantics. The goal is to avoid reading half-updated playlist state or racing against a full playlist replacement.

---

## Test Coverage

### Model / Controller tests

Add focused tests for:

1. queue snapshot shape for single-image slots
2. queue snapshot shape for portrait-pair slots
3. jump-to-slot sets the next position correctly
4. invalid jump indices are clamped or rejected safely

### HTTP tests

Add targeted tests where practical for:

1. queue endpoint returns compact JSON
2. thumbnail endpoint returns image bytes or a safe fallback
3. jump endpoint triggers queue movement without rebuilding the queue unexpectedly
4. new queue endpoints remain under the existing auth guard

### Frontend behavior checks

At minimum, verify manually that:

1. page renders before thumbnails finish loading
2. queue list updates after navigation
3. clicking a queue row jumps to that slot
4. portrait pair rows remain single queue entries

---

## Manual Verification

Verify using a mixed library that includes:

- normal landscape images
- portrait pairs
- HEIC or other slower-to-decode formats when available
- a reasonably large library so queue and caching behavior are noticeable

Expected results:

1. the HTTP page opens quickly even on slower hardware
2. queue text appears before thumbnails if thumbnail generation is slow
3. thumbnails populate progressively
4. clicking a queued slot skips ahead correctly
5. current slot and queue preview stay in sync after `next`, `back`, and jump
6. repeated visits do not regenerate every thumbnail unnecessarily
7. queued jumps fail cleanly when a playlist reload is already pending

---

## Acceptance Criteria

This task is complete when all of the following are true:

- the web panel shows a queue preview of upcoming playlist slots
- queue entries are clickable and can jump playback to the selected slot
- portrait-pair slots remain one queue row
- queue thumbnails are shown for the visible queue window
- initial page render does not block on thumbnail generation
- thumbnail generation is done on demand and is cached
- the queue endpoint returns only a small window of playlist state
- the implementation remains lightweight enough for low-power Raspberry Pi devices

---

## Implementation Notes For The Assignee

- Prefer a queue preview window of 6 to 8 visible items in v1.
- Use separate requests for metadata and thumbnails; do not render thumbs inline into the initial HTML.
- Keep queue rendering text-first so the UI remains useful even if thumbnails fail.
- Treat click-to-jump as “set next slot and advance”, not queue reordering.
- Be conservative with thumbnail size and generation cost.
- Favor simple bounded caching over clever caching.
- Keep the HTTP layer thin; business logic belongs in model/controller.
