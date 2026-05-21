# How the Photo Shuffle Works

## The short version (plain language)

When `shuffle` is on, picframe builds a fresh playlist and tries to make it
feel **genuinely random**, while also being **fair** about which photos you
see.

It does this by giving every photo a "weight":

- Photos you've **rarely seen** get a higher weight.
- Photos that are **older** get a small extra nudge.
- Photos that are **recent** are still shown before older ones (the existing
  "recent first" rule didn't change).
- Photos shown **very recently** (in the last couple of days) get a sharply
  reduced weight — a "cooldown" — so the same photo doesn't keep popping up
  across back-to-back playlists.

Then it shuffles using those weights. Heavier photos are more likely to land
near the front of the playlist, but every photo could in theory show up
anywhere — so it actually looks random, not like a fixed queue.

A few things worth knowing:

- The playlist is built **once** per reload (startup, reshuffle, filter
  change). It does **not** rebuild after every photo, so the order you see
  in one playlist run is the order it was decided up front.
- Portrait photos are shuffled together with everything else using the same
  rules. The only special treatment portraits get is at display time: two
  portraits are stitched into one screen so the landscape display isn't
  half-empty.
- There are no new settings to configure. Turning `shuffle` on or off works
  exactly like before — only the *quality* of the shuffle changed.

### What changed and why

Before, shuffle sorted photos strictly by "least-seen first," then randomly
inside each tier. That was fair, but it felt like a cycle: every never-seen
photo played before any seen-once photo, etc. The new version replaces that
hard ordering with a weighted random pick, so the bias toward under-shown
photos is still there but the result looks and feels random.

---

## The detailed version (engineering)

### Files involved

| File | Role |
|------|------|
| `src/picframe/model.py` | Decides which path to take (`shuffle` on vs off) and assembles the where-clause and `recent_cutoff` |
| `src/picframe/image_cache.py` | Houses the new weighted shuffle helpers and the shuffle-specific cache query |
| `src/picframe/config/configuration_example.yaml` | Documents the new `shuffle` behavior |
| `test/test_weighted_shuffle.py` | Unit + integration tests for the new logic |
| `.claude/plans/task-003-add-better-shuffle-logic.md` | The original design doc |

### Entry point: `Model.__get_files()`

Defined in `src/picframe/model.py:603`. This is the only place a playlist
gets built. It is called on reload — startup, `reshuffle_num` threshold,
subdir change, filter change.

```python
recent_n = self.get_model_config()["recent_n"]
recent_cutoff = None
if recent_n > 0:
    recent_cutoff = time.time() - 3600 * 24 * recent_n

if self.shuffle:
    file_list = self.__image_cache.query_cache_shuffle(where_clause, recent_cutoff=recent_cutoff)
else:
    # …unchanged SQL ORDER BY path…
    file_list = self.__image_cache.query_cache(where_clause, sort_clause)
```

- `recent_n` is a config key in the `model` section (days). When > 0, photos
  with `last_modified >= now - recent_n*86400` form the "recent" partition.
- `shuffle=False` still goes through the original `query_cache()` SQL path
  unchanged.

### Cache query: `ImageCache.query_cache_shuffle()`

Defined in `src/picframe/image_cache.py:208`. Pulls just the columns the
weighting needs:

```sql
SELECT file_id, displayed_count, last_modified, last_displayed, is_portrait
FROM all_data WHERE {where_clause}
```

Then hands the raw rows to `weighted_shuffle_rows()`. No `ORDER BY` is used
for shuffle — ordering is computed in Python.

`last_displayed` was exposed in the `all_data` view via DB schema v5
(migration in `image_cache.py:__update_schema`). Older deployed frames
auto-migrate on next startup; no manual step needed.

### Recent partitioning: `weighted_shuffle_rows()`

`src/picframe/image_cache.py:51`. Splits rows by `recent_cutoff`:

```python
if recent_cutoff is None:
    return _weighted_shuffle_partition(list(rows))

# split rows into "recent" and "older" using last_modified vs recent_cutoff
return _weighted_shuffle_partition(recent_rows) + _weighted_shuffle_partition(older_rows)
```

The recent partition is shuffled internally, the older partition is shuffled
internally, then the two are **concatenated** — recent always comes first.
This preserves the existing `recent_n` contract.

### The weighted shuffle itself: `_weighted_shuffle_partition()`

`src/picframe/image_cache.py:19`. Per-row weights and an exponential-race
priority assignment.

Constants at the top of `image_cache.py`:

```python
SHUFFLE_COUNT_ALPHA      = 1.5   # how hard low displayed_count is favored
SHUFFLE_AGE_BONUS        = 0.3   # max age boost (within a partition)
SHUFFLE_COOLDOWN_HOURS   = 48    # how long after a photo is shown until it can recover full weight
```

Per-row math:

```python
count_weight = 1.0 / (displayed_count + 1) ** 1.5
age_position = (newest_in_partition - last_modified) / age_span   # 0..1
age_weight   = 1.0 + 0.3 * age_position

# Cooldown: full weight (1.0) for never-shown photos; otherwise ramps from 0
# at last_displayed to 1.0 after SHUFFLE_COOLDOWN_HOURS.
if last_displayed <= 0:
    cooldown = 1.0
else:
    cooldown = min(1.0, (now - last_displayed) / (SHUFFLE_COOLDOWN_HOURS * 3600))

total_weight = max(count_weight * age_weight * cooldown, 1e-9)
priority     = -log(max(random(), 1e-12)) / total_weight
```

The `1e-9` floor on `total_weight` exists so that a just-shown photo with
cooldown ≈ 0 can still in principle be picked if it is the only candidate,
without causing a divide-by-zero in `priority`.

Then `rows.sort(key=priority)` ascending. This is mathematically equivalent
to weighted sampling without replacement — every row could end up anywhere,
but higher-weight rows tend to land earlier.

Effective weight examples (count axis, ignoring age and cooldown):

| `displayed_count` | `count_weight` |
|-------------------|----------------|
| 0 | 1.00 |
| 1 | 0.354 |
| 3 | 0.125 |
| 10 | 0.027 |

So a never-shown photo is roughly **3× more likely** to appear early than a
once-shown photo, and **~37× more likely** than a photo shown 10 times.
Count clearly dominates; age only adds up to 30% on top of that, and only
relative to the oldest photo *within the same partition*.

Cooldown examples (cooldown axis, with `SHUFFLE_COOLDOWN_HOURS = 48`):

| time since last shown | `cooldown` |
|-----------------------|------------|
| never (`last_displayed == 0`) | 1.00 |
| 1 minute  | ~0.0003 |
| 1 hour    | ~0.021 |
| 12 hours  | 0.25 |
| 24 hours  | 0.50 |
| 48 hours+ | 1.00 |

Cooldown multiplies the weight, so a photo shown an hour ago is ~50×
less likely to appear early than its own normal weight would suggest. The
ramp is linear over `SHUFFLE_COOLDOWN_HOURS` so the effect fades smoothly.

Why age is partition-normalized: if age were normalized globally, the oldest
photo in the "recent" partition would still be 11 months old vs. 5-year-old
photos in the "older" partition, and would get almost no boost. Normalizing
inside each partition means the oldest photo within each group always gets
the full bonus — which is what the `recent_n` design intends.

### Portrait pairs

`portrait_pairs` is a display concern, not a shuffle concern. The shuffle
treats portraits and landscapes identically; pairing happens only after the
order is decided.

`src/picframe/image_cache.py:218`:

```python
if not self.__portrait_pairs:
    return [(row["file_id"],) for row in ordered_rows]

portrait_rows = [row for row in ordered_rows if row["is_portrait"] == 1]
full_list  = [(-1,) if row["is_portrait"] == 1 else (row["file_id"],) for row in ordered_rows]
pair_list  = [(row["file_id"],) for row in portrait_rows]
```

The walk that follows pops portraits off `pair_list` (which is already in
the global shuffle order — it is a *filter* of `ordered_rows`, not a second
shuffle) and packs them two at a time into portrait slots, using
`skip_portrait_slot` to consume the second `-1` placeholder.

The single critical invariant: **portraits are never reshuffled.** They are
extracted from the global weighted order and consumed in that same order,
so a frequently-shown portrait can't sneak ahead of a never-shown one.

The actual visual stitching of two portraits into one landscape frame
happens later in `viewer_display.py:292` (`__create_image_pair`). That's
purely a render-time concern and unrelated to ordering.

### Playlist lifecycle (unchanged)

For reference, what was deliberately **not** changed:

- Playlist is built once per reload, not per photo.
- `displayed_count` and `last_displayed` are still updated in
  `get_file_info()` (`image_cache.py:259`) each time a photo is shown.
- Updated counts do not reorder the already-built playlist — they only
  affect the **next** rebuild.
- `reshuffle_num` (model config) still controls how many full passes
  through the playlist trigger a rebuild.
- `shuffle=False` path is byte-for-byte the same as before.

### Tunable constants

If a frame's library skews heavily in one direction, the three constants
at the top of `image_cache.py` are the only knobs:

- `SHUFFLE_COUNT_ALPHA = 1.5` — raise to favor under-shown photos harder,
  lower to flatten toward uniform random.
- `SHUFFLE_AGE_BONUS = 0.3` — raise to surface old photos more aggressively
  (capped because age is meant to be a nudge, not the dominant signal).
- `SHUFFLE_COOLDOWN_HOURS = 48` — raise to keep recently-shown photos out
  of rotation longer, lower to recycle faster.

These are intentionally **not** exposed in `configuration.yaml` per the
task plan — no new user-facing tuning knobs in v1.

### Tests

`test/test_weighted_shuffle.py` covers:

- Lower `displayed_count` shows up earlier on average.
- Older photos are favored modestly when counts are equal.
- A recently-shown photo (cooldown ≈ 0) is pushed to the back relative to
  an otherwise-identical photo with no recent display.
- High-count photos remain eligible (no filtering).
- Recent partition stays ahead of older partition under `recent_n`.
- `query_cache_shuffle()` returns correct tuple shapes for both
  `portrait_pairs=True` and `=False`.
- Portrait ordering matches the single global weighted order (the test that
  fails if a second portrait-only shuffle is ever reintroduced).

### Related history

- `df6a09d` — original "least-seen first" SQL fairness fix (the bucketed
  behavior this task replaced).
- `da0498a` — subquery workaround so `displayed_count` could be referenced
  in `ORDER BY` (dead for shuffle mode now, still relevant for non-shuffle).
- `179a5ae` — the rewrite this document describes.
