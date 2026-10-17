# Task 003: Add Better Shuffle Logic

## Context

The current shuffle behavior in this fork is no longer pure random.

At the moment, when `model.shuffle` is enabled, the playlist is rebuilt by sorting on:

```sql
displayed_count ASC, RANDOM()
```

This behavior was introduced to stop the slideshow from repeatedly favoring a subset of photos after restarts or partial runs. It improves fairness, but it is still a deterministic bucketed sort:

- all photos with `displayed_count = 0` are shown before any photo with `displayed_count = 1`
- all photos with `displayed_count = 1` are shown before any photo with `displayed_count = 2`
- randomness only exists inside each count bucket

This solves underexposure of some photos, but it does not feel like true random playback. It also does not directly help rediscover older photos, because `displayed_count` measures exposure rather than age.

The goal of this task is to replace the current bucketed shuffle with a **weighted random shuffle** that:

- still favors photos that have been shown less often
- gives older photos a modest boost
- keeps all photos eligible
- remains simple and maintainable
- preserves the existing playlist lifecycle and existing `portrait_pairs` behavior

---

## Current Behavior Summary

### Current playlist lifecycle

The playlist is **not** rebuilt on every photo selection.

It is rebuilt only when the model reloads files, which happens on startup and later on reshuffle/reload conditions already implemented in `Model`.

That means:

- a playlist is generated once
- the slideshow consumes that playlist in order
- `displayed_count` is updated as photos are shown
- the updated counts do **not** change the remaining order inside the already-built playlist
- a new playlist is built only on the next reload

This lifecycle must remain unchanged for this task.

### Current shuffle behavior

Current shuffle behavior lives in `Model.__get_files()` and relies on SQL ordering through `ImageCache.query_cache()`.

When `shuffle=True`:

- the model builds a sort expression using `displayed_count ASC, RANDOM()`
- SQLite returns a fully ordered list of file ids
- that list becomes the current playlist

### Current `recent_n` behavior

`recent_n` is an existing feature that biases more recent files to the front of the shuffled order.

This task must preserve that behavior semantically:

- recent files should still be shown before older files
- but within each recent/older partition, ordering should use the new weighted random logic rather than the old count-bucket sort

### Current `portrait_pairs` behavior

When `portrait_pairs=False`, each playlist entry is a single file id.

When `portrait_pairs=True`, the existing cache logic creates a list where:

- landscape-capable slots remain single items
- portrait items can be paired into `(file_id_1, file_id_2)` tuples

This task must preserve that public behavior. The slideshow should still receive the same shape of playlist output that it expects today.

---

## Problem Statement

The current `displayed_count ASC, RANDOM()` approach has three important drawbacks:

1. It is not genuinely random.
   The slideshow progresses through count buckets in order, which can feel like a soft cycle rather than natural randomness.

2. It does not directly surface older photos.
   A recently imported photo with `displayed_count = 0` outranks an old neglected photo with `displayed_count = 1`, even if the product goal is to rediscover older photos.

3. It becomes awkward around portrait pairing if shuffle behavior is built from multiple independent orderings.
   If portraits are reshuffled separately from the global order, the actual playback order can drift away from the intended weighting policy.

This task should resolve all three while staying small and readable.

---

## Desired End State

### High-level behavior

When `shuffle=True`, the playlist should be built using **weighted random sampling without replacement**.

Every candidate photo stays eligible, but its probability of appearing earlier in the playlist should increase when:

- its `displayed_count` is lower
- its `last_modified` timestamp is older

This must produce a playlist that is:

- random
- biased toward under-shown photos
- modestly biased toward older photos
- still capable of showing frequently shown or recent photos

### Explicit non-goals

This task must **not**:

- add a new config key or mode selector
- add a new HTTP control
- change the schema
- change how `displayed_count` is stored or updated
- rebuild the playlist after every shown photo
- redesign `portrait_pairs`

The only intended user-visible change is the quality of the shuffle behavior when `shuffle=True`.

---

## Implementation Strategy

## Files to Modify

| File | Change |
|------|--------|
| `src/picframe/model.py` | Route the shuffle path away from SQL `ORDER BY` and into a dedicated weighted-shuffle query path |
| `src/picframe/image_cache.py` | Add the weighted shuffle helper logic and a cache query method that returns playlist entries in the new weighted order |
| `src/picframe/config/configuration_example.yaml` | Update the `shuffle` comment to describe the new behavior |
| `test/` | Add targeted tests for the weighted shuffle helper and the portrait-pair consistency behavior |

---

## Detailed Design

### 1. Keep the current playlist lifecycle

Do not change when the playlist is rebuilt.

The new algorithm must still run only when the playlist is reloaded:

- on startup
- when reshuffle conditions are met
- when existing config/filter/file-reload behavior triggers a reload

The output of the new logic should still be assigned into `self.__file_list`, and the rest of the model should continue to consume that list exactly as it does now.

### 2. Move shuffle ordering out of SQL `ORDER BY`

The existing SQL ordering is too limited for this feature because:

- weighted shuffle is easier to express correctly in Python
- keeping portrait-pair behavior consistent is easier if one in-memory order becomes the single source of truth

Therefore:

- keep `ImageCache.query_cache()` unchanged for non-shuffle mode
- add a separate shuffle path in `ImageCache`, for example `query_cache_shuffle(...)`
- in `Model.__get_files()`, call the new shuffle method only when `self.shuffle` is true

Non-shuffle behavior must remain unchanged.

### 3. Candidate data required for weighted shuffle

The weighted shuffle path must fetch enough data from `all_data` to compute ordering in memory.

At minimum, each candidate row needs:

- `file_id`
- `displayed_count`
- `last_modified`
- `is_portrait`

No schema change is required because these fields already exist in the current DB/view setup.

### 4. Weighting rules

Use fixed internal coefficients in v1. Do not add configuration.

Recommended formulas:

```text
count_weight = 1 / (displayed_count + 1) ^ 1.5
```

This keeps never-shown photos strongly favored while still leaving higher-count photos eligible.

Age should be a bounded secondary signal:

```text
age_weight = 1.0 + age_bonus
```

Where:

- `age_bonus` is normalized within the current partition only
- `age_bonus` stays in a narrow range, for example `0.0` to `0.3`
- the oldest photo in the partition gets the highest bonus
- the newest photo gets little or no bonus

Final effective weight:

```text
total_weight = count_weight * age_weight
```

The age signal must remain weaker than the count signal. This task is about improved shuffle fairness, not about forcing a strict oldest-first slideshow.

### 5. Weighted random ordering method

Build a random permutation without replacement using the weights above.

The recommended implementation is:

- compute one random priority value per row from its weight
- sort by that priority
- return rows in that sorted order

This provides:

- randomness
- a full playlist order
- no repeated selection within one playlist
- simple implementation with no repeated database queries

Any mathematically equivalent weighted-without-replacement approach is acceptable, but the code should stay small and readable.

### 6. Preserve `recent_n` semantics

The current meaning of `recent_n` must be kept.

Implementation rule:

- split the candidate rows into two partitions using the existing recent cutoff
- partition A: recent rows
- partition B: older rows
- run the weighted shuffle independently inside each partition
- concatenate the results as:

```text
recent partition first + older partition second
```

This preserves the current “recent first” behavior while improving the randomness inside each partition.

### 7. Preserve `portrait_pairs` while keeping shuffle logic consistent

This is the most important design constraint.

The implementation must not compute one weighted order for all photos and then independently reshuffle portrait photos a second time. Doing so breaks consistency, because portrait photos would no longer be shown according to the same global weighted priorities as landscape photos.

The correct rule is:

- compute **one** weighted order across the full candidate set exactly once
- use that order as the single source of truth
- if `portrait_pairs=False`, convert it directly into single-item playlist tuples
- if `portrait_pairs=True`, reuse the existing portrait-slot packing behavior, but derive it from the already ordered rows

Concretely:

1. Build `ordered_rows = weighted_shuffle_rows(all_rows, recent_cutoff=...)`
2. Derive the landscape/portrait slot layout from `ordered_rows`
3. Build the portrait fill list by extracting portrait rows from `ordered_rows` in the same order they already appear
4. Reuse the current pairing loop to produce the final playlist tuples

This guarantees:

- portraits and landscapes compete in the same global weighted shuffle
- portraits are paired in an order consistent with the single global shuffle
- existing playlist shape remains unchanged

### 8. Readability constraints

Keep the implementation intentionally modest.

Preferred structure:

- one small helper to read nullable row values safely, if needed
- one helper to weighted-shuffle a single partition
- one helper to apply recent partitioning
- one `ImageCache` method that returns final playlist tuples for shuffle mode

Avoid:

- introducing strategy classes
- adding config tuning parameters
- duplicating the portrait-pair packing algorithm in multiple places
- large abstractions that are harder to understand than the current code

Target outcome: another engineer should be able to read the shuffle path in one pass and understand it.

---

## Public / Behavioral Contract

After this task:

- `shuffle=False` continues to use the existing non-random SQL sort path
- `shuffle=True` means:
  - random playlist order
  - less-shown photos are favored
  - older photos are modestly favored
  - recent photos still appear before older ones when `recent_n > 0`
- `portrait_pairs` continues to work exactly as a consumer-facing feature
- no config migration is required

Update the config comment for `shuffle` so the documented behavior matches the code.

---

## Suggested Test Coverage

### Unit-level shuffle tests

Add tests around the pure weighted-shuffle helper(s).

Required scenarios:

1. Lower `displayed_count` is favored over higher `displayed_count`
2. Older photos are favored modestly when `displayed_count` is equal
3. High-count photos remain eligible and are not filtered out
4. Recent partition stays ahead of older partition when `recent_n` logic is applied

These tests should validate statistical tendency, not exact ordering from a single run.

### Production-path tests

Add at least one test that covers the real shuffle playlist-construction path rather than only the pure helper.

Required scenarios:

1. `query_cache_shuffle()` returns single-item tuples when `portrait_pairs=False`
2. `query_cache_shuffle()` returns valid tuple shapes when `portrait_pairs=True`
3. Portrait ordering remains consistent with the single global weighted order

The third test is critical. It should fail if portraits are independently reshuffled a second time.

### Regression checks

Add a simple regression test or inspection point for:

- non-shuffle path unchanged
- no schema change required
- existing `displayed_count` update flow unchanged

---

## Manual Verification

After implementation, perform a manual sanity check against a realistic mixed library.

Construct or inspect a set that includes:

- never-shown recent photos
- never-shown old photos
- frequently shown recent photos
- frequently shown old photos
- enough portrait photos to trigger `portrait_pairs`

Manual expectations:

1. Shuffle still looks random rather than grouped by exact count buckets
2. Never-shown photos appear more often near the front, but not in a rigid “all zero-count first” block
3. Older photos get a noticeable but modest boost
4. Frequently shown photos still appear sometimes
5. Portrait pairing still produces valid slideshow entries
6. Rebuilding the playlist creates a different order while preserving the same bias profile

---

## Acceptance Criteria

This task is complete when all of the following are true:

- shuffle mode no longer relies on `displayed_count ASC, RANDOM()`
- shuffle mode uses weighted random ordering based on `displayed_count` and `last_modified`
- `recent_n` semantics are preserved
- `portrait_pairs` behavior is preserved
- portrait ordering is derived from one single global weighted order, not from a second portrait-only reshuffle
- non-shuffle mode is unchanged
- config/example documentation reflects the new meaning of `shuffle`
- tests cover both the pure weighting logic and the real playlist-construction path

---

## Implementation Notes for the Assignee

- Keep this as a behavioral refactor, not a feature expansion.
- Prefer the smallest number of new helpers that still make the algorithm clear.
- Do not add user-facing tuning knobs unless explicitly requested later.
- Be careful not to accidentally change the semantics of `recent_n`.
- Be careful not to introduce a second independent portrait shuffle.
- If a helper is hard to test because of import-time runtime dependencies, extract only the minimum pure logic needed for isolated tests.

