# Implementation Plan: Backward Compatibility for Custom Hardware Features

## Context

This picframe fork has custom hardware features (DHT22/BME280 sensors, GPIO clap detection, touch buttons) that are **not backward compatible** with upstream helgeerbe/picframe. The custom code has critical issues:

1. **Missing config defaults**: 8 sensor keys and entire `gpio` section missing from `DEFAULT_CONFIG` → `KeyError` crashes
2. **Unsafe imports**: Hardware libraries (`gpiod`, `board`, `busio`, `adafruit_*`) imported at module level → `ImportError` on non-Pi systems
3. **Unconditional integration**: Sensors and GPIO assumed to exist without guards → `AttributeError` crashes

**Goal**: Make all custom features opt-in with safe defaults so the fork can run cleanly without custom config (upstream-compatible) and allow future upstream merges with minimal conflict.

**Reference**: Full analysis in `.claude/plans/backward-compatibility-plan.md` (11 original steps)

## Critical Files to Modify

1. `/Users/ivan.cherednychok/Projects/picframe-custom/picframe/src/picframe/model.py` - Add sensor/GPIO defaults to DEFAULT_CONFIG
2. `/Users/ivan.cherednychok/Projects/picframe-custom/picframe/src/picframe/viewer_display.py` - Guard sensor creation
3. `/Users/ivan.cherednychok/Projects/picframe-custom/picframe/src/picframe/controller.py` - Guard sensor access
4. `/Users/ivan.cherednychok/Projects/picframe-custom/picframe/src/picframe/interface_mqtt.py` - Guard sensor MQTT
5. `/Users/ivan.cherednychok/Projects/picframe-custom/picframe/src/picframe/start.py` - Conditional GPIO import
6. `/Users/ivan.cherednychok/Projects/picframe-custom/picframe/src/picframe/get_sensors_data.py` - Lazy imports
7. `/Users/ivan.cherednychok/Projects/picframe-custom/picframe/src/picframe/gpio_actions.py` - Lazy imports, config-driven pins
8. `/Users/ivan.cherednychok/Projects/picframe-custom/picframe/src/picframe/config/configuration_example.yaml` - Add gpio section
9. `/Users/ivan.cherednychok/Projects/picframe-custom/picframe/pyproject.toml` - Optional hardware deps
10. `/Users/ivan.cherednychok/Projects/picframe-custom/picframe/picframe_data/launch.sh` - Remove hardcoded path

## Implementation Order (4 Phases)

### PHASE 1: Foundation (No Runtime Impact)

These changes are pure metadata/resources with no code execution impact. Can be done in parallel.

#### 1.1 Add optional hardware dependencies to pyproject.toml

**File**: `picframe/pyproject.toml`

Add after the `[project]` dependencies section:

```toml
[project.optional-dependencies]
sensors = [
    "adafruit-circuitpython-dht",
    "adafruit-circuitpython-bme280",
]
gpio = [
    "gpiod",
]
hardware = [
    "picframe[sensors]",
    "picframe[gpio]",
]
```

Users install with: `pip install picframe[hardware]`

#### 1.2 Clean up launch.sh hardcoded path

**File**: `picframe/picframe_data/launch.sh`

Replace hardcoded `/home/ivan.cherednychok/picframe/...` with relative or `$HOME`-based path.

#### 1.3 Bundle Font Awesome font in package source

**Files**: Copy from runtime to source

```bash
cp picframe/picframe_data/data/fonts/Font\ Awesome\ 6\ Free-Solid-900.otf \
   picframe/src/picframe/data/fonts/
```

This ensures `picframe -i` copies the icon font needed for sensor display.

**TEST CHECKPOINT 1**: Verify font exists in `src/picframe/data/fonts/`

---

### PHASE 2: Config System (Critical Foundation)

Config defaults MUST be added before any code tries to access them. Sequential order required.

#### 2.1 Add missing defaults to DEFAULT_CONFIG

**File**: `picframe/src/picframe/model.py`

**Location**: Line 54 (after `clock_hgt_offset_pct`, before `menu_text_sz`)

Add to `DEFAULT_CONFIG['viewer']` dict:

```python
        'show_sensors': False,
        'sensors_justify': 'L',
        'sensors_text_sz': 20,
        'sensors_opacity': 1.0,
        'sensors_update_rate_in_seconds': 60,
        'outside_sensor_pin': 17,
        'inside_sensor_address': 0x76,
        'font_icon_file': '~/picframe_data/data/fonts/Font Awesome 6 Free-Solid-900.otf',
```

**Location**: Line 116 (after `peripherals` section, before closing `}`)

Add new `gpio` section to `DEFAULT_CONFIG`:

```python
    'gpio': {
        'use_gpio': False,
        'clap_sensor_pin': 4,
        'prev_touch_sensor_pin': 20,
        'next_touch_sensor_pin': 21,
        'clap_delay': 0.7,
    },
```

**Location**: Line 163 (config loading loop)

Update to include `'gpio'`:

```python
for section in ['viewer', 'model', 'mqtt', 'http', 'peripherals', 'gpio']:
```

**Location**: After line 237 (after `get_peripherals_config()` method)

Add new method following the existing pattern:

```python
def get_gpio_config(self):
    return self.__config['gpio']
```

#### 2.2 Update configuration_example.yaml

**File**: `picframe/src/picframe/config/configuration_example.yaml`

**Change 1**: Line 53 - Set default to False
```yaml
show_sensors: False  # was True
```

**Change 2**: After line 59 (in viewer section), add:
```yaml
  font_icon_file: "~/picframe_data/data/fonts/Font Awesome 6 Free-Solid-900.otf"
```

**Change 3**: After `peripherals` section, add new `gpio` section:
```yaml
gpio:
  use_gpio: False                       # default=False. Set True to enable GPIO controls
  clap_sensor_pin: 4                    # GPIO pin for clap detection sensor
  prev_touch_sensor_pin: 20             # GPIO pin for previous photo button
  next_touch_sensor_pin: 21             # GPIO pin for next photo button
  clap_delay: 0.7                       # seconds between claps for multi-clap detection
```

**TEST CHECKPOINT 2**:
- Verify DEFAULT_CONFIG has all 8 sensor keys
- Verify `gpio` section exists in DEFAULT_CONFIG
- Verify `Model` class has `get_gpio_config()` method
- Test: `python -c "from picframe.model import DEFAULT_CONFIG; assert 'show_sensors' in DEFAULT_CONFIG['viewer']; assert 'gpio' in DEFAULT_CONFIG; print('OK')"`

---

### PHASE 3: Make Imports Safe (Bottom-Up)

Make hardware modules importable on any system. Can be done in parallel.

#### 3.1 Make get_sensors_data.py import-safe

**File**: `picframe/src/picframe/get_sensors_data.py`

**Change 1**: Remove module-level imports (lines 6-9)
- Delete: `import board`
- Delete: `import busio`
- Delete: `from picframe import dht_compat as Adafruit_DHT`
- Delete: `from adafruit_bme280 import basic as adafruit_bme280`

**Change 2**: Move imports inside `get_inside_sensor_data()` method (around line 60)

```python
def get_inside_sensor_data(self):
    if not self.show_sensors:
        return self._default_sensor_data()
    try:
        import board
        import busio
        from adafruit_bme280 import basic as adafruit_bme280

        i2c = busio.I2C(board.SCL, board.SDA)
        bme280 = adafruit_bme280.Adafruit_BME280_I2C(i2c, address=self.inside_sensor_address)
        # ... rest of method
    except Exception as e:
        self.__logger.debug("BME280 sensor unavailable: %s", e)
        return self._default_sensor_data()
```

**Change 3**: Move imports inside `get_outside_sensor_data()` method (around line 80)

```python
def get_outside_sensor_data(self):
    if not self.show_sensors:
        return self._default_sensor_data()
    try:
        from picframe import dht_compat as Adafruit_DHT

        humidity, temperature = Adafruit_DHT.read_retry(Adafruit_DHT.DHT22, self.outside_sensor_pin)
        # ... rest of method
    except Exception as e:
        self.__logger.debug("DHT22 sensor unavailable: %s", e)
        return self._default_sensor_data()
```

#### 3.2 Make gpio_actions.py import-safe and config-driven

**File**: `picframe/src/picframe/gpio_actions.py`

**Change 1**: Remove module-level import (line 3)
- Delete: `import gpiod`

**Change 2**: Update `__init__` to accept config and move import inside

```python
def __init__(self, frame_controller, config=None):
    self.__controller = frame_controller
    self.__logger = logging.getLogger("gpio_actions.GpioController")

    # Get pin config with fallback defaults
    if config is None:
        config = {}
    self.clap_sensor_pin = config.get('clap_sensor_pin', 4)
    self.prev_touch_sensor_pin = config.get('prev_touch_sensor_pin', 20)
    self.next_touch_sensor_pin = config.get('next_touch_sensor_pin', 21)
    self.clap_delay = config.get('clap_delay', 0.7)

    try:
        import gpiod
        self.__chip = gpiod.Chip("gpiochip0")
        # Use self.clap_sensor_pin instead of hardcoded 4, etc.
        self.__clap_line = self.__chip.get_line(self.clap_sensor_pin)
        # ... rest of init
    except Exception as e:
        self.__logger.warning("GPIO unavailable: %s", e)
        return
```

**Change 3**: Update all hardcoded pin references (lines 12-14) to use `self.clap_sensor_pin`, etc.

**TEST CHECKPOINT 3**:
- Test on macOS: `python -c "from picframe import get_sensors_data; print('OK')"`
- Test on macOS: `python -c "from picframe import gpio_actions; print('OK')"`
- Both should succeed (no ImportError)

---

### PHASE 4: Integration Layers (Bottom-Up)

Guard all integration points where sensor/GPIO features are used. Sequential order required.

#### 4.1 Guard sensor integration in viewer_display.py

**File**: `picframe/src/picframe/viewer_display.py`

**Change 1**: Remove duplicate imports (lines 5-6, keep lines 10-13)
- Delete line 5: `from PIL import Image, ImageFilter, ImageFile`
- Delete line 6: `import numpy as np`
- Keep lines 10-13 (same imports)

**Change 2**: Remove module-level import (line 7)
- Delete: `from picframe import mat_image, get_image_meta, get_sensors_data`
- Replace with: `from picframe import mat_image, get_image_meta`

**Change 3**: Guard SensorData instantiation in `__init__` (around line 125)

```python
# Only create SensorData if sensors enabled
if self.__show_sensors:
    try:
        from picframe import get_sensors_data
        self.__sensors_data = get_sensors_data.SensorData(config)
    except ImportError as e:
        self.__logger.warning("Sensor libraries not available, disabling sensors: %s", e)
        self.__show_sensors = False
        self.__sensors_data = None
else:
    self.__sensors_data = None
```

**Change 4**: Update `get_sensors_data()` method to handle None (around line 129)

```python
def get_sensors_data(self):
    return self.__sensors_data  # Can be None
```

**Change 5**: Fix outside_pressure bug (line 541)

Change:
```python
outside_pressure = inside_sensors.get('pressure', '-');
```
To:
```python
outside_pressure = outside_sensors.get('pressure', '-');
```

**TEST CHECKPOINT 4**:
- Verify ViewerDisplay can be instantiated with `show_sensors: False`
- Verify no duplicate imports remain

#### 4.2 Guard sensor integration in controller.py

**File**: `picframe/src/picframe/controller.py`

**Change 1**: Guard sensor subscription in `start()` method (line 379)

```python
# Subscribe to sensors updates only if available
sensors = self.__viewer.get_sensors_data()
if sensors is not None:
    sensors.subscribe_to_sensors_updates(self.handle_temperature_update)
```

**Change 2**: Guard sensor getter methods (around lines 408-415)

```python
def get_sensors_data(self):
    return self.__viewer.get_sensors_data()

def get_inside_sensors_data(self):
    sensors = self.__viewer.get_sensors_data()
    if sensors is not None:
        return sensors.get_last_inside_sensor_data()
    return {"is_online": False, "temperature": None, "humidity": None, "pressure": None}

def get_outside_sensors_data(self):
    sensors = self.__viewer.get_sensors_data()
    if sensors is not None:
        return sensors.get_last_outside_sensor_data()
    return {"is_online": False, "temperature": None, "humidity": None, "pressure": None}
```

**TEST CHECKPOINT 5**:
- Verify Controller doesn't crash if `viewer.get_sensors_data()` returns None
- Test sensor getter methods return safe defaults

#### 4.3 Guard MQTT sensor discovery and publishing

**File**: `picframe/src/picframe/interface_mqtt.py`

**Change 1**: Guard sensor MQTT discovery (around lines 219-224)

Wrap the 6 `__setup_sensor()` calls:

```python
# Only setup sensor MQTT entities if sensors available
if self.__controller.get_sensors_data() is not None:
    self.__setup_sensor(client, "inside_temperature", "mdi:thermometer", available_topic,
                        entity_category="diagnostic", unit_of_measurement="°C")
    self.__setup_sensor(client, "inside_humidity", "mdi:water-percent", available_topic,
                        entity_category="diagnostic", unit_of_measurement="%")
    self.__setup_sensor(client, "inside_pressure", "mdi:cloud", available_topic,
                        entity_category="diagnostic", unit_of_measurement="mmHg")
    self.__setup_sensor(client, "outside_temperature", "mdi:thermometer", available_topic,
                        entity_category="diagnostic", unit_of_measurement="°C")
    self.__setup_sensor(client, "outside_humidity", "mdi:water-percent", available_topic,
                        entity_category="diagnostic", unit_of_measurement="%")
    self.__setup_sensor(client, "outside_pressure", "mdi:cloud", available_topic,
                        entity_category="diagnostic", unit_of_measurement="mmHg")
```

**Change 2**: Guard sensor state publishing (around lines 801-808)

```python
# Only publish sensor data if sensors available
sensors = self.__controller.get_sensors_data()
if sensors is not None:
    inside_sensors = self.__controller.get_inside_sensors_data()
    outside_sensors = self.__controller.get_outside_sensors_data()
    sensor_state_payload["inside_temperature"] = inside_sensors.get("temperature", None)
    sensor_state_payload["inside_humidity"] = inside_sensors.get("humidity", None)
    sensor_state_payload["inside_pressure"] = inside_sensors.get("pressure", None)
    sensor_state_payload["outside_temperature"] = outside_sensors.get("temperature", None)
    sensor_state_payload["outside_humidity"] = outside_sensors.get("humidity", None)
    sensor_state_payload["outside_pressure"] = outside_sensors.get("pressure", None)
```

**TEST CHECKPOINT 6**:
- Verify MQTT connects and publishes state without sensor keys when `show_sensors: False`
- Verify MQTT doesn't create sensor entities when sensors disabled

#### 4.4 Make start.py GPIO import conditional

**File**: `picframe/src/picframe/start.py`

**Change 1**: Remove gpio_actions from module-level import (line 8)

Change:
```python
from picframe import model, viewer_display, controller, gpio_actions, __version__
```
To:
```python
from picframe import model, viewer_display, controller, __version__
```

**Change 2**: Make GPIO initialization conditional (around line 136)

Replace:
```python
gpio_controller = gpio_actions.GpioController(c)
```
With:
```python
# Only initialize GPIO if enabled in config
gpio_config = m.get_gpio_config()
if gpio_config.get('use_gpio', False):
    try:
        from picframe import gpio_actions
        gpio_controller = gpio_actions.GpioController(c, gpio_config)
        logger.info("GPIO controller initialized")
    except ImportError as e:
        logger.warning("GPIO unavailable (gpiod not installed): %s", e)
    except Exception as e:
        logger.warning("GPIO initialization failed: %s", e)
```

**TEST CHECKPOINT 7 (FULL SMOKE TEST)**:

1. **No-sensor startup test**: Create minimal config without sensor/gpio sections
   ```bash
   cd picframe
   # Edit picframe_data/config/configuration.yaml to remove sensor/gpio keys
   python -m picframe.start
   # Should start without errors
   ```

2. **Import test on macOS**: Verify no import crashes
   ```bash
   python -c "import picframe; print(picframe.__version__)"
   ```

3. **Init test**: Verify `picframe -i` includes all resources
   ```bash
   picframe -i /tmp/test_picframe
   # Check Font Awesome font exists: /tmp/test_picframe/picframe_data/data/fonts/Font\ Awesome\ 6\ Free-Solid-900.otf
   # Check configuration.yaml has gpio section
   ```

4. **MQTT test**: With `use_mqtt: True` and `show_sensors: False`
   - Verify MQTT connects
   - Verify state payload has no sensor keys
   - Verify no sensor entities created in Home Assistant

5. **With-sensor test** (on Pi or with mocks): Set `show_sensors: True`
   - Verify sensor overlay appears
   - Verify MQTT publishes sensor data
   - Verify sensor entities in Home Assistant

---

## Reusable Patterns Found

- **Config getter pattern**: See `get_viewer_config()` at line 215 - return `self.__config['section']`
- **Lazy import pattern**: Import inside try/except in methods, not at module level
- **Default sensor data**: `SensorData._default_sensor_data()` returns `{"is_online": False, "temperature": "0.0", "humidity": "0", "pressure": "0"}`
- **Config merge pattern**: Line 164 uses `{**DEFAULT_CONFIG[section], **conf[section]}`

## Verification Summary

After all changes, the fork should:
1. ✅ Run cleanly on macOS without `ImportError`
2. ✅ Run on Pi without custom config sections (sensors/GPIO disabled by default)
3. ✅ Support sensor/GPIO features when explicitly enabled in config
4. ✅ Be installable with `pip install picframe[hardware]` for full features
5. ✅ Generate complete configs via `picframe -i` with Font Awesome font included
6. ✅ Maintain MQTT/Home Assistant compatibility in both modes (with/without sensors)

## Dependencies

**Critical sequential order**:
- Phase 2 MUST complete before Phase 4 (config defaults before usage)
- Within Phase 4: 4.1 → 4.2 → 4.3 → 4.4 (bottom-up integration)

**Can be parallel**:
- All of Phase 1
- Phase 3 (3.1 and 3.2)
