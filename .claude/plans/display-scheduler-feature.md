# In-app display on/off scheduler with web UI

## Context

Today, the display on/off schedule is driven by external crontab lines hitting picframe's HTTP API:

```cron
00 21 * * 0-4 curl "http://localhost:9000/?display_is_on=false"
00 07 * * 1-5 curl "http://localhost:9000/?display_is_on=true"
...
@reboot ~/picframe/scripts/ops/monitor_safety_on_boot.sh home >> ...
```

This works but spreads the schedule across three places (user crontab + bash safety script with hardcoded per-frame times). Editing the schedule means SSH-ing in and using `crontab -e`. Each new frame needs its own crontab restoration. And the @reboot safety net is a workaround for a problem the app should own anyway.

Goal: fold the schedule into picframe itself so the app owns its own display state across reboots. Add a settings page in the web UI so the schedule can be edited from a browser. Retire the cron lines once the in-app scheduler is proven.

## Approach

Add a small scheduler module that hooks into the existing controller main loop, checks the wall clock at most once per minute, and drives `controller.display_is_on` according to a persisted schedule. Expose the schedule via the existing HTTP interface and add a new web UI block to edit it.

### Architecture

```
configuration.yaml  --(defaults)--> Scheduler ──hooked into Controller.loop()──> controller.display_is_on
       │                                ▲                                              │
       │                                │                                              │
schedule.json  ──(persisted edits)──────┘                                              ▼
       ▲                                                                       viewer.display_is_on
       │                                                                               │
       └──── interface_http.py /?schedule=...  ◀── pf_functions.js ◀── new UI block ──┘
```

### New module: `src/picframe/display_scheduler.py`

Hook into the controller's existing main loop instead of running a separate thread. The loop already ticks at pi3d's render rate (~20 fps) and keeps running while the display is "off" (`paused=true` halts slide advance but pi3d keeps rendering).

- `class DisplayScheduler` with config dict in ctor. No thread, no lifecycle methods.
- Public method `maybe_tick(now=None)` called once per `Controller.loop()` iteration (see "Controller wiring" below). Internal `__last_tick_ts` guards against re-evaluating more than once per minute — most calls return immediately.
- Decides the desired transition by detecting a *boundary cross*: did the previous-tick "should be on?" answer differ from the current one? If yes, fire the transition. This naturally implements the "boundary-only" semantics (no continuous reconciliation).
- If `enabled=false` → always no-op.
- Exposes `get_state()` returning `{enabled, today_on, today_off, next_transition_at, next_transition_to}` for the UI and MQTT.
- Loads/saves the schedule via a `ScheduleStore` helper (see below).
- Holds a reference to the `Controller` (or a callback) so it can flip `display_is_on`.

### Persistence

Two layers:

1. **`configuration.yaml`** — new `scheduler` section with the *default* schedule. Shipped in `configuration_example.yaml` so fresh installs get a sane default. Read-only by the app.
2. **`picframe_data/schedule.json`** — *overrides* written by the web UI. Lives next to the DB. If present, it wins over the YAML default. If absent, the YAML default is used.

This avoids YAML mutation (which would lose comments and risk corrupting the rest of the config) while still giving the user a single editable schedule via the UI. Pattern is novel for picframe — current UI is in-memory only — but it's narrow: only one file, only the scheduler touches it.

### Schedule shape

Full per-day grid — each of the seven days has its own `on`/`off` pair:

```yaml
scheduler:
  enabled: true
  days:
    mon: { on: "07:00", off: "21:00" }
    tue: { on: "07:00", off: "21:00" }
    wed: { on: "07:00", off: "21:00" }
    thu: { on: "07:00", off: "21:00" }
    fri: { on: "07:00", off: "21:00" }
    sat: { on: "08:00", off: "23:00" }
    sun: { on: "08:00", off: "23:00" }
```

Day keys: `mon, tue, wed, thu, fri, sat, sun`. Times are local time, 24h `HH:MM`. Overnight windows (on > off) supported with the same wraparound logic the bash script used. A day with `on == off` is treated as "always off" for that day; an explicit "always on" can be encoded as `on: "00:00", off: "23:59"` (or simpler: a future per-day `enabled` flag, but skip that for v1).

`enabled: false` at the top level short-circuits everything — `maybe_tick()` returns immediately.

### Controller wiring (`src/picframe/controller.py`)

- Add `self.__scheduler = DisplayScheduler(model.get_scheduler_config(), self)` in `Controller.__init__`.
- Add a single `self.__scheduler.maybe_tick()` call inside `Controller.loop()` (the existing main loop at `controller.py:317-358`). Placement: alongside `check_input()`, near the end of each iteration. No `start`/`stop` plumbing needed.
- Existing `display_is_on` setter at `controller.py:183-188` already handles MQTT publish; scheduler calls into the same setter so HA stays in sync.

### Model wiring (`src/picframe/model.py`)

- Add `scheduler` block to `DEFAULT_CONFIG`.
- Add `get_scheduler_config()` returning the merged dict (defaults ∪ YAML).
- Add `get_schedule_overrides_path()` returning `<picframe_data>/schedule.json`.

### Manual override semantics

When the user toggles `display_is_on` manually (via HA switch, web UI, or HTTP), the schedule should yield until its next boundary. Approach:

- Scheduler tracks the previous-tick "should be on?" answer. It only fires a transition when *that answer changes* — i.e. when wall-clock time crosses a configured on/off boundary.
- This means: at 14:30 you tap "off" in HA — screen turns off and stays off until tomorrow 07:00, when the scheduler's next ON boundary triggers a transition.
- Simpler and more humane than "every minute, force desired state". Matches how the bash safety net works too (one-shot at reboot, not continuous).
- Boot behaviour: on the very first `maybe_tick()` call after picframe starts, there is no "previous answer". Treat that as a boundary cross and apply the current desired state once. This gives us the same boot resilience the @reboot safety script provided, for free.

### HTTP API (`src/picframe/interface_http.py`)

Two new endpoints, both routed through the existing `do_GET` handler (raw `http.server` + Jinja2, no Flask):

- `GET /?schedule_state` → JSON with the full effective schedule + computed next-transition info (sourced from `DisplayScheduler.get_state()`).
- `GET /?schedule_update=<urlencoded JSON>` → atomically replaces the override JSON file and asks the scheduler to reload. (POST would be cleaner, but `do_POST` currently just delegates to `do_GET`; sticking with GET keeps the change minimal. Body limit isn't a concern — the schedule is tiny.)

The schedule itself isn't a controller property; both endpoints are special-cased before the generic setter dispatch around `interface_http.py:275-301`.

### Web UI (`src/picframe/html/`)

Add a new "Schedule" block in `index.html`, rendered alongside the existing CONTROL_GROUPS from `interface_http.py:97-129`. Since the schedule's shape doesn't fit the generic `{id, type, fn}` control-group pattern, this gets its own hand-rolled Jinja block + JS:

- Enable toggle (reuses the existing toggle styling).
- A 7-row grid (mon–sun) with two `<input type="time">` per row (on, off). Days are always all visible — no add/remove rows.
- Read-only "Next transition" status line, refreshed every 30s via fetch.
- Save button that POSTs the assembled JSON to `/?schedule_update=...`.
- Optional convenience: a "copy weekday → weekend" or "fill all from row 1" button to ease editing seven nearly-identical rows. Skip for v1 if it complicates the UI.

JS lives in `pf_functions.js` alongside the existing `toggle()` helpers.

### MQTT / Home Assistant (`src/picframe/interface_mqtt.py`)

Three new HA entities (mirroring the `inside_temperature` sensor pattern around `publish_state` at the end of the file):

- `schedule_enabled` — HA switch, calls `?schedule_enabled=true|false`.
- `next_transition_at` — HA sensor with `device_class: timestamp`.
- `next_transition_to` — HA sensor showing `on` or `off`.

This way HA sees the schedule and can react to it (e.g. dashboard tile showing "Off in 2h 14m").

### Cron retirement

Once the in-app scheduler is verified on each frame:

1. Remove the four daytime `display_is_on=…` cron lines.
2. Remove the `@reboot monitor_safety_on_boot.sh` line.
3. Optionally delete `picframe/scripts/ops/monitor_safety_on_boot.sh` (or leave it as a fallback for cases where picframe is down for maintenance — the script's been written for that exact contingency).

Mention this in `picframe/scripts/README.md` so future-you knows the cron is intentional dead weight, not a missing piece.

### Files to modify

- **Create** `src/picframe/display_scheduler.py` — new module, ~150 lines.
- **Modify** `src/picframe/model.py` — add `scheduler` to `DEFAULT_CONFIG`, add `get_scheduler_config()` and `get_schedule_overrides_path()`.
- **Modify** `src/picframe/controller.py` — instantiate scheduler in `__init__`; call `maybe_tick()` inside `loop()`.
- **Modify** `src/picframe/interface_http.py` — add two endpoint branches in `do_GET` before the generic setter dispatch.
- **Modify** `src/picframe/interface_mqtt.py` — add three HA entities + state publish.
- **Modify** `src/picframe/config/configuration_example.yaml` — add commented-out `scheduler:` block.
- **Modify** `src/picframe/html/index.html` — add Schedule block.
- **Modify** `src/picframe/html/pf_functions.js` — add fetch + form-state helpers.
- **Modify** `src/picframe/html/style.css` — minor styling for the per-day table.
- **Modify** `scripts/README.md` — note that the cron lines are obsolete once this lands.

### Reused patterns

- Main loop hook point: `Controller.loop()` at `controller.py:317-358` (insert `maybe_tick()` alongside the existing `check_input()` call).
- Config injection: `model.get_*_config()` methods around `model.py:163` (merge YAML over `DEFAULT_CONFIG`).
- Setter wiring with MQTT publish side-effect: `controller.py:183-188`.
- HTTP endpoint dispatch + JSON response: `interface_http.py:252-301` (existing `queue_snapshot`, `all` branches).
- HA discovery + state publish: `interface_mqtt.py:733-821`.
- Web UI control rendering: `interface_http.py:97-129` (`CONTROL_GROUPS`) and how `index.html` iterates them.

## Verification

1. **Unit-level (dev machine):**
   - Stand up `DisplayScheduler` with a fake controller (records calls to `display_is_on`).
   - Time-travel by injecting `now()` and assert: state flips only at boundaries, manual override sticks until next boundary, `enabled=false` is a no-op, overnight windows behave right.
2. **End-to-end (real frame):**
   - Set schedule to `on: now+1min, off: now+2min`. Wait 3 minutes, watch journal for transitions, eyeball the screen.
   - Edit via web UI: change off-time, hit save, confirm `schedule.json` updates and the next-transition status reflects it without a restart.
   - Reboot the frame in the off-window: confirm screen comes up dark within ~60s of picframe starting (no cron involved).
   - Toggle from HA in the on-window: screen turns off, stays off until next morning on-time.
3. **MQTT/HA:**
   - Confirm `schedule_enabled` switch appears in HA auto-discovery.
   - Confirm `next_transition_at` sensor shows a sane future timestamp.
4. **Cron retirement:**
   - On one frame, comment out the cron lines for a week. Confirm no regression.
   - Then propagate to the other two frames.
