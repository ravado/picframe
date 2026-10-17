# Analysis of Custom Additions to picframe Fork

## Context

This is a fork of [helgeerbe/picframe](https://github.com/helgeerbe/picframe) — a Raspberry Pi digital picture frame with MQTT/Home Assistant integration. The `develop` branch has ~16 custom commits adding hardware sensor monitoring, GPIO controls, and related integrations.

---

## Custom Additions Inventory

### 1. Sensor Monitoring (`get_sensors_data.py` + `dht_compat.py`)
- **DHT22** (outdoor temp/humidity) via GPIO pin
- **BME280** (indoor temp/humidity/pressure) via I2C
- Background thread polls sensors at configurable intervals
- Observer pattern notifies subscribers on data change (hash-based dedup)
- `dht_compat.py` is an adapter layer mimicking the legacy `Adafruit_DHT` API over the new `adafruit_dht` library

### 2. GPIO Hardware Controls (`gpio_actions.py`)
- Touch buttons (prev/next) via `gpiod`
- Clap detection (single = next, double = prev) with timer-based debouncing
- Graceful fallback when GPIO unavailable

### 3. Geo Reverse Lookup (`geo_reverse.py`)
- OpenStreetMap Nominatim reverse geocoding
- Configurable address key priorities and locale

### 4. Controller Enhancements (`controller.py`)
- Sensor data accessor methods proxied through viewer
- `connect_mqtt()` with exponential backoff retry (unused — see issues below)
- Sensor update subscription wired in `start()`

### 5. Integration in `start.py`
- `GpioController` instantiated directly alongside MVC components

### 6. Deployment (`launch.sh`, `run_start.py`)
- Shell wrapper with hardcoded user path

---

## Quality Assessment

### What's Good

| Aspect | Details |
|--------|---------|
| **Observer pattern in sensors** | Clean subscriber notification with hash-based change detection — avoids unnecessary MQTT publishes |
| **Graceful degradation** | Both GPIO and sensor code catch exceptions and continue running without the hardware |
| **Configuration-driven** | Sensor pins, I2C address, update rate are all configurable via YAML, following the upstream pattern |
| **Thread safety** | Daemon threads with proper `stop()` + `join()` lifecycle |
| **Adapter pattern** | `dht_compat.py` cleanly wraps the new Adafruit library behind the old API |

### Issues Found

| Issue | Severity | File | Details |
|-------|----------|------|---------|
| **Dead code: `connect_mqtt()`** | Medium | `controller.py:381-406` | This method with retry logic is never called anywhere. `start()` initializes MQTT directly without retries. Likely leftover from a refactor. |
| **Hardcoded GPIO pins** | Medium | `gpio_actions.py:12-14` | Pins 20, 21, 4 are hardcoded, unlike sensors which read from config. Inconsistent with the rest of the codebase. |
| **Hardcoded chip name** | Low | `gpio_actions.py:23` | `"gpiochip0"` is hardcoded. Different Pi models may use different chip names. |
| **`print()` instead of logger** | Low | `gpio_actions.py:41,58,62,69` | Clap detection uses `print()` while the rest uses `logging`. |
| **Emoji in log messages** | Low | `gpio_actions.py:28,84,95` | `⚠️` in warning messages can cause encoding issues on some terminals. |
| **I2C bus recreated every read** | Medium | `get_sensors_data.py:67-69` | `busio.I2C()` and `Adafruit_BME280_I2C()` are instantiated on every poll cycle instead of once. This can leak file descriptors or cause bus contention. |
| **No thread lock on sensor data** | Low | `get_sensors_data.py:57-58` | `inside_sensor_data` and `outside_sensor_data` are written from the background thread and read from the main thread without a lock. Dict assignment is atomic in CPython but this is an implementation detail, not a guarantee. |
| **Touch buttons commented out** | Low | `gpio_actions.py:25` | `__init_touch_buttons()` is commented out — dead code path |
| **Multiple event loops possible** | Medium | `gpio_actions.py:82,93` | Both `__init_touch_buttons` and `__init_clapper` start a new `__event_loop` thread. If both are enabled, two threads poll the same `__lines` dict concurrently without synchronization. |
| **Sensor data coupled to viewer** | Medium | `controller.py:379,408-415` | Controller accesses sensors via `self.__viewer.get_sensors_data()` — the viewer shouldn't own sensor data. This creates an indirect dependency path: Controller → Viewer → SensorData. |
| **`launch.sh` hardcoded path** | Low | `launch.sh` | `/home/ivan.cherednychok/picframe` is hardcoded, not portable |
| **`__del__` for cleanup** | Low | `gpio_actions.py:108` | `__del__` is unreliable in Python — may never be called, or called during interpreter shutdown when `gpiod` module is already torn down |
| **Unused `gpio_controller` variable** | Low | `start.py:136` | `gpio_controller` is assigned but never referenced again — relies on side-effects in constructor |
| **`for/else` bug** | Medium | `controller.py:404-406` | The `else` clause on the `for` loop runs when the loop completes without `break`, but the condition check inside doesn't match this intent — it will log "Max retries" even on success if `keep_looping` becomes False |

---

## Modularity Improvements

### Problem: Sensor data is owned by the Viewer

Currently: `start.py` → `ViewerDisplay(config)` → creates `SensorData` internally → Controller accesses it via `viewer.get_sensors_data()`.

Sensors are a **data concern**, not a display concern. The viewer should receive data to render, not own the data source.

**Proposed fix:** Create `SensorData` in `start.py` and inject it into both Controller and Viewer:
```
s = SensorData(viewer_config)  # or a dedicated sensors_config
v = ViewerDisplay(viewer_config, sensor_data=s)
c = Controller(m, v, sensor_data=s)
```

### Problem: GPIO controller is not configurable

Pins are hardcoded, modes (touch/clap) can't be toggled, and the controller isn't integrated with the existing peripherals system.

**Proposed fix:**
- Move GPIO pin numbers and mode selection into `configuration.yaml` under a `gpio` section
- Consider integrating with `interface_peripherals.py` which already handles input devices, rather than being a separate parallel system

### Problem: No abstraction for sensor types

Adding a new sensor (e.g., a light sensor, air quality) requires modifying `SensorData` directly.

**Proposed fix:** Define a simple sensor interface/protocol:
```python
class Sensor:
    def read(self) -> dict: ...
    def is_available(self) -> bool: ...
```
Then `SensorData` becomes a registry that manages multiple `Sensor` instances. Each sensor type (DHT22, BME280, future sensors) is a separate class.

### Problem: Dead/unused code

- `connect_mqtt()` is never called
- Touch button init is commented out
- `gpio_fake_frame_controller.py` exists but isn't wired into tests

**Proposed fix:** Remove dead code or wire it in properly.

---

## Recommended Refactoring Steps

1. **Extract SensorData ownership** from ViewerDisplay → inject from `start.py`
2. **Make GPIO configurable** — pins, modes, enable/disable in YAML config
3. **Fix I2C bus lifecycle** — create once in `__init__`, reuse across reads
4. **Replace `print()` with `logger`** in gpio_actions.py
5. **Add thread lock** for sensor data reads/writes
6. **Remove dead code** — `connect_mqtt()`, commented-out touch init, or properly integrate them
7. **Introduce sensor abstraction** if you plan to add more sensor types
8. **Fix the `for/else` bug** in `connect_mqtt()` (or delete it)
9. **Integrate GPIO with peripherals** — align with upstream's `interface_peripherals.py` pattern

---

## Verification

After refactoring:
- Run existing tests: `pytest picframe/test/`
- Test sensor display with `show_sensors: True` and `show_sensors: False`
- Test GPIO fallback by running on a non-Pi machine (should log warning and continue)
- Test MQTT publishing of sensor data via `mosquitto_sub`
- Verify no regressions in slideshow loop timing
