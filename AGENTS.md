# Picframe Custom Fork

Custom fork of [helgeerbe/picframe](https://github.com/helgeerbe/picframe) via [ravado/picframe](https://github.com/ravado/picframe).
Raspberry Pi-based digital picture frame with pi3d rendering, MQTT/Home Assistant integration, and HTTP config UI.

---

**Project:** Picframe Custom Fork
**Goal:** Run a Pi-based digital photo frame with Home Assistant / MQTT integration and on-screen sensor overlays.
**Audience:** Personal / single maintainer (Ivan) plus a small fleet of deployed frames on his network. Not a public product.

## Stack

Use these. Don't suggest alternatives unless I ask.

- **Language:** Python ≥ 3.7 (real targets: 3.11–3.13 on Raspberry Pi OS, dev on macOS)
- **Framework:** none — long-running CLI/daemon (`picframe.start:main`)
- **Rendering:** pi3d ≥ 2.54 (OpenGL ES on the Pi)
- **Package manager:** pip + `pyproject.toml` (editable install in `~/.venv_picframe` on frames)
- **Config:** YAML (`picframe_data/config/configuration.yaml`) merged over `DEFAULT_CONFIG` in `model.py`
- **Storage:** SQLite (file DB under `picframe_data/data/`) — no ORM
- **Integrations:** MQTT via `paho-mqtt` ≥ 2.1 (Home Assistant auto-discovery); HTTP config UI via stdlib + Jinja2
- **Hardware libs (optional extras):** `gpiod` (`[gpio]`), `adafruit-circuitpython-dht` + `adafruit-circuitpython-bme280` (`[sensors]`), grouped as `[hardware]`
- **Testing:** none configured — `test/` directory is minimal; verify changes by running on a frame or with the fake GPIO controller
- **Deploy target:** Raspberry Pi (Linux/ARM) running labwc; managed via `systemctl --user picframe.service`
- **Log shipping:** fluent-bit (journal → Loki/Grafana). Not Alloy.

## Permanent constraints

Things that must always hold in this repo. Flag conflicts before proceeding.

- **Non-Pi systems must not crash on import.** All hardware libs (`gpiod`, `board`, `busio`, `adafruit_*`) are imported lazily inside try/except, never at module top level.
- **All hardware features must degrade silently** when libs or hardware are unavailable — never raise into the main loop.
- **Every config key has a default** in `DEFAULT_CONFIG` (`model.py`). New keys without defaults break frames that haven't updated `configuration.yaml`.
- **Config access goes through `model.get_*_config()`** — components receive a dict, never reach into `Model` for raw config.
- **No new runtime dependencies without asking.** If a dep is hardware-only, it goes in `[project.optional-dependencies]`, not the base list.
- **Touching `pyproject.toml` means deployed frames need `scripts/ops/update.sh`**, not just `git pull`. Call this out in the summary when it happens.
- **Operational scripts live under `scripts/`** and are indexed by `scripts/README.md`. Read that file before adding/moving/deleting anything there.
- **Plans and task docs live in `.claude/plans/`** — not scattered in the repo root.

## Avoid

- Module-level imports of hardware libraries (`gpiod`, `board`, `busio`, `adafruit_*`) — always lazy.
- Adding new runtime dependencies without asking, or putting hardware-only deps in the base `dependencies` list.
- Refactors, renames, or reformatting outside the file(s) the current task touches.
- **Modifying upstream-inherited files unless necessary** — preserve merge-ability with `helgeerbe/picframe`. Custom features live in clearly-marked `[CUSTOM]` files; prefer extending those over editing upstream code.
- Mocking the database in tests; running migrations, force-pushing, or anything irreversible without explicit confirmation in the current message.
- Adding feature flags, abstractions, or "future-proofing" beyond what the task requires.

## Memory

- **`MEMORY.md`** (repo root): read at session start. Append entries for significant decisions — what was decided, why, what was rejected.
- **`ERRORS.md`** (repo root): check before proposing approaches to similar problems. Append entries when a fix uncovers a non-obvious failure mode worth remembering.
- Both files are git-tracked; keep entries terse (a few lines each, dated).

---

## Repository Layout

```
picframe/                          # Git repo root (branch: develop)
  src/picframe/                    # Python package source (installed as `picframe`)
    start.py                       # Entry point — CLI, init (`picframe -i`), main loop
    model.py                       # Config loading, DB, file management. DEFAULT_CONFIG dict has all defaults
    viewer_display.py              # pi3d rendering, text/clock/sensor overlays
    controller.py                  # Orchestrates Model + Viewer + MQTT + HTTP + Peripherals
    interface_mqtt.py              # MQTT client, Home Assistant auto-discovery, state publishing
    interface_http.py              # HTTP config server
    get_sensors_data.py            # [CUSTOM] DHT22 + BME280 sensor monitoring (background thread)
    gpio_actions.py                # [CUSTOM] Clap detection + touch buttons via gpiod
    dht_compat.py                  # [CUSTOM] Adapter: new adafruit_dht API -> old Adafruit_DHT API
    geo_reverse.py                 # [CUSTOM] OpenStreetMap Nominatim reverse geocoding
    gpio_fake_frame_controller.py  # [CUSTOM] Mock GPIO for dev/testing
    config/configuration_example.yaml  # Config template (copied during `picframe -i`)
    data/                          # Bundled resources (fonts, shaders, images) — copied during init
    html/                          # Web UI files — copied during init
  picframe_data/                   # Runtime data directory (deployed instance)
    config/configuration.yaml      # Active config (gitignored, user creates from example)
    data/                          # Fonts, shaders, DB, etc.
    html/                          # Served by HTTP interface
  pyproject.toml                   # Package config, dependencies, entry point: picframe.start:main
  .gitignore                       # Ignores configuration.yaml, DB, logs, IDE, Python artifacts
```

## Architecture (MVC + Peripherals)

```
start.py  ->  Model (config, DB, files)
          ->  ViewerDisplay (pi3d rendering)
          ->  Controller (orchestrates all)
                -> InterfaceMQTT (HA discovery, state pub/sub)
                -> InterfaceHTTP (web config UI)
                -> InterfacePeripherals (keyboard/touch/mouse input)
          ->  GpioController [optional] (clap sensor, touch buttons)
          ->  SensorData [optional] (DHT22 outside, BME280 inside)
```

## Config System

- **Sections:** `viewer`, `model`, `mqtt`, `http`, `peripherals`, `gpio`
- **Defaults:** `DEFAULT_CONFIG` dict in `model.py` — all keys must exist here
- **Loading:** `model.py:163` merges YAML over defaults: `{**DEFAULT_CONFIG[section], **conf[section]}`
- **Access:** `model.get_viewer_config()`, `get_model_config()`, `get_mqtt_config()`, etc.
- **Init flow:** `picframe -i <dest>` copies `src/picframe/{data,config,html}/` -> `<dest>/picframe_data/`
  then generates `configuration.yaml` from example with user-prompted path substitutions

## Custom Additions (vs upstream)

### Sensor Monitoring (`get_sensors_data.py`)
- `SensorData` class reads DHT22 (outside, GPIO pin) and BME280 (inside, I2C address)
- Background daemon thread polls at configurable rate (default 60s)
- Observer pattern: subscribers notified on data change (hash-based dedup)
- Config keys in `viewer` section: `show_sensors`, `sensors_justify`, `sensors_text_sz`, `sensors_opacity`, `sensors_update_rate_in_seconds`, `outside_sensor_pin`, `inside_sensor_address`
- Hardware libs: `board`, `busio`, `adafruit_dht` (via `dht_compat.py`), `adafruit_bme280`

### GPIO Control (`gpio_actions.py`)
- `GpioController` uses `gpiod` library for Raspberry Pi GPIO
- Clap detection (GPIO 4) with single/double clap discrimination (700ms delay)
- Touch buttons: previous (GPIO 20), next (GPIO 21) — currently commented out
- Config section: `gpio` with `use_gpio`, pin numbers, `clap_delay`

### Sensor Display Overlay (`viewer_display.py`)
- `__draw_sensors()` renders temperature/humidity/pressure with Font Awesome icons
- Icon font: `Font Awesome 6 Free-Solid-900.otf` (glyphs: `\uf015` house, `\ue587` tree)
- Config key: `font_icon_file` for icon font path

### MQTT Sensor Publishing (`interface_mqtt.py`)
- 6 HA sensors: `inside_temperature`, `inside_humidity`, `inside_pressure`, `outside_*`
- Published in `sensor_state_payload` alongside standard picframe state

### Geo Reverse Lookup (`geo_reverse.py`)
- `GeoReverse` class using OpenStreetMap Nominatim API
- Converts GPS coords to addresses with configurable zoom and key_list

### Weighted Shuffle (`image_cache.py`)
- Replaces upstream's `displayed_count ASC, RANDOM()` bucketed sort with weighted random sampling without replacement
- Favors under-shown photos (count) and modestly older photos (age); preserves `recent_n` and `portrait_pairs`
- Tunables: `SHUFFLE_COUNT_ALPHA`, `SHUFFLE_AGE_BONUS` (module constants, not config)
- See [`docs/shuffle-behavior.md`](docs/shuffle-behavior.md) for full design & math

## Key Patterns

- **Config injection:** All components accept config dict from `model.get_*_config()` methods
- **Lazy hardware imports:** Hardware libs (`gpiod`, `board`, `busio`, `adafruit_*`) should be imported inside try/except, not at module level — non-Pi systems must not crash
- **Graceful fallback:** All hardware features must degrade silently if libs/hardware unavailable
- **Daemon threads:** `SensorData.fetch_sensor_data()` and `GpioController.__event_loop()` run as daemon threads with stop signals
- **Observer pattern:** `SensorData` notifies subscribers via `subscribe_to_sensors_updates(callback)`

## Known Issues / Compatibility Gaps

See `.claude/plans/backward-compatibility-plan.md` for the full remediation plan.

Key issues:
- Several custom features lack proper defaults in `DEFAULT_CONFIG` causing `KeyError` without custom YAML
- Hardware imports at module level cause `ImportError` on non-Pi systems
- `gpio_actions` imported unconditionally in `start.py`
- Icon font not bundled in `src/picframe/data/fonts/` (missing from `picframe -i` flow)
- Hardware deps not in `pyproject.toml` (should be optional extras)

## Planning & Task Management

**All implementation plans and task documentation should be kept in `.claude/plans/` directory.**

Current plans:
- `backward-compatibility-plan.md` — Remediation for upstream compatibility gaps
- `memories-feature.md` — Feature implementation plan
- `task-001.md` — Specific task documentation

When creating new plans or tasks, add them to this folder with descriptive names following the pattern:
- Feature plans: `feature-name-plan.md`
- Task tracking: `task-NNN.md` (numbered sequentially)
- Architecture decisions: `adr-NNN-topic.md`

## Development

- **Remote:** `git@github.com:ravado/picframe.git`
- **Branch:** `develop`
- **Python:** >=3.7 (targets 3.11-3.13)
- **Target platform:** Raspberry Pi (Linux/ARM), development on macOS
- **Entry point:** `picframe` CLI or `python -m picframe.start`
- **No test framework configured** — `test/` directory exists but minimal

## Operational Scripts

All shipped scripts live under `scripts/` and are catalogued in
[`scripts/README.md`](scripts/README.md) — that file is the authoritative
index of what each script does and where it's invoked from. Layout:

- `scripts/runtime/` — invoked by cron/systemd on a deployed frame
- `scripts/ops/` — manual maintenance (update, audit, compare)
- `scripts/install/` — numbered `1_…5_` install flow + helpers
- `scripts/sensors/` — one-shot hardware probes
- `scripts/monitoring/` — log/metric forwarder installers (Alloy / Fluent Bit)
- `scripts/photo-normalization/` — NAS + DB extension/dedupe admin
- `scripts/_quarantine/` — verified-dead, awaiting deletion

Read `scripts/README.md` before adding, moving, or deleting anything in
that tree — the runtime chain (cron → `photo-sync@.service` →
`runtime/sync_photos_from_nasik.sh` → rclone) is documented there.

## Updating a Deployed Frame

Initial install is handled by `scripts/install/2_install_picframe.sh`
in this repo. For ongoing updates to an already-installed frame, use the
in-repo helper:

```bash
ssh ivan@<frame>
~/picframe/scripts/ops/update.sh
```

`scripts/ops/update.sh` does three things in order:

1. `git pull --ff-only` on the currently checked-out branch.
2. `pip install -e .` inside `~/.venv_picframe` so any **new dependencies**
   added to `pyproject.toml` are installed. This is the key step — a plain
   `git pull` will not pick up new deps and the frame will crash on startup
   (e.g. `ModuleNotFoundError: No module named 'jinja2'`).
3. `systemctl --user restart picframe.service` to relaunch labwc, which
   re-spawns picframe via its autostart file.

Overridable via env vars: `VENV_PATH`, `REPO_PATH`, `SERVICE_NAME`. Defaults
match the layout produced by `install/2_install_picframe.sh` (user `ivan`,
`~/.venv_picframe`, `~/picframe`).

**Rule of thumb:** whenever a change touches `pyproject.toml`, frames must be
updated via this script (or an equivalent `pip install -e .`), not just
`git pull`.


## Applied fixes flow

Every fix we do for the scripts or picframe code should consider that some picframe are already deployed so it may require upgrade script created and updated in current installation/migration scripts to include the fix in new deployments. Also notable fixes needs to be loged in docs

## Running git commands

The repo root is one level down from the working directory
(`picframe-custom/picframe/`). `cd` into the repo first, then run plain git
commands (`git status`, `git diff`, `git log`, …) rather than the
`git -C <path> …` form. The user's `~/.claude/settings.json` auto-approves
read-only git subcommands by name (`git status:*`, `git diff:*`, etc.), but
those rules are prefix-only and do not match the `-C` form, so using `-C`
re-triggers a permission prompt on every call. One `cd` per session
eliminates that friction.
