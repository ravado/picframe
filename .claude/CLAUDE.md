# Picframe Custom Fork

Custom fork of [helgeerbe/picframe](https://github.com/helgeerbe/picframe) via [ravado/picframe](https://github.com/ravado/picframe).
Raspberry Pi-based digital picture frame with pi3d rendering, MQTT/Home Assistant integration, and HTTP config UI.

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
