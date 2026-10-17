# Memories Feature Implementation Plan

## Overview

Add a "Memories" feature that displays photos taken on the same day but from previous years, creating a nostalgic "On This Day" experience similar to Apple Photos, Google Photos, and Facebook.

## Visual Presentation

Two display styles will be implemented:

### Style 1: "Time Capsule" Banner Overlay (Default)

A semi-transparent banner at the top of the screen when showing a memory photo.

```
┌──────────────────────────────────────────────────┐
│  ✨ 5 Years Ago Today • January 31, 2021        │ ← Gradient banner
├──────────────────────────────────────────────────┤
│                                                  │
│                                                  │
│              [Photo Content]                     │
│                                                  │
│                                                  │
│                                                  │
└──────────────────────────────────────────────────┘
```

### Style 2: "Years Counter" Icon

A subtle icon in the corner showing years since the photo was taken.

```
┌──────────────────────────────────────────────────┐
│                                           ┌───┐  │
│                                           │ 5 │  │ ← Circle with years
│                                           │yrs│  │
│              [Photo Content]              └───┘  │
│                                                  │
│                                                  │
│                    📸 Jan 31, 2019 • Beach Trip  │
└──────────────────────────────────────────────────┘
```

---

## Configuration Options

Add to `DEFAULT_CONFIG` in `model.py` under `'model'` section:

```python
'model': {
    # ... existing options ...
    'memories_enabled': False,            # Enable memories mode
    'memories_min_years': 1,              # Minimum years back to look
    'memories_day_tolerance': 0,          # Allow +/- days (0 = exact day only)
    'memories_mode': 'mixed',             # 'exclusive' | 'mixed'
    'memories_mix_ratio': 5,              # In mixed mode: show 1 memory every N photos
}
```

Add to `DEFAULT_CONFIG` under `'viewer'` section:

```python
'viewer': {
    # ... existing options ...
    'memories_display_style': 'banner',   # 'banner' | 'icon' | 'both'
    'memories_banner_position': 'T',      # 'T' (top) | 'B' (bottom)
    'memories_text_sz': 40,               # Font size for memories text
    'memories_opacity': 1.0,              # Opacity of memories overlay
}
```

---

## Files to Modify

### 1. `picframe/src/picframe/model.py`

#### Changes:

**A. Add configuration defaults (lines ~59-88):**

```python
'model': {
    # ... existing ...
    'memories_enabled': False,
    'memories_min_years': 1,
    'memories_day_tolerance': 0,
    'memories_mode': 'mixed',
    'memories_mix_ratio': 5,
}
```

```python
'viewer': {
    # ... existing ...
    'memories_display_style': 'banner',
    'memories_banner_position': 'T',
    'memories_text_sz': 40,
    'memories_opacity': 1.0,
}
```

**B. Add Pic class attribute (around line 120-148):**

```python
class Pic:
    def __init__(self, fname, last_modified, file_id, orientation=1, exif_datetime=0,
                 # ... existing params ...
                 caption=None, tags=None, is_memory=False, years_ago=0):
        # ... existing assignments ...
        self.is_memory = is_memory
        self.years_ago = years_ago
```

**C. Add memories property and WHERE clause logic (after line ~315):**

```python
@property
def memories_enabled(self):
    return self.__config['model']['memories_enabled']

@memories_enabled.setter
def memories_enabled(self, val: bool):
    self.__config['model']['memories_enabled'] = val
    self.__update_memories_where_clause()
    self.__reload_files = True

@property
def memories_mode(self):
    return self.__config['model']['memories_mode']

@memories_mode.setter
def memories_mode(self, val: str):
    if val in ('exclusive', 'mixed'):
        self.__config['model']['memories_mode'] = val
        self.__update_memories_where_clause()
        self.__reload_files = True

def __update_memories_where_clause(self):
    """Build SQL WHERE clause for memories filtering."""
    if not self.__config['model']['memories_enabled']:
        self.set_where_clause('memories')  # Remove clause
        return

    min_years = self.__config['model']['memories_min_years']
    tolerance = self.__config['model']['memories_day_tolerance']

    # SQLite date math for "same day, different year"
    if tolerance == 0:
        # Exact day match
        clause = """(
            strftime('%m-%d', datetime(exif_datetime, 'unixepoch', 'localtime'))
            = strftime('%m-%d', 'now', 'localtime')
            AND CAST(strftime('%Y', 'now', 'localtime') AS INTEGER)
                - CAST(strftime('%Y', datetime(exif_datetime, 'unixepoch', 'localtime')) AS INTEGER)
                >= {min_years}
        )""".format(min_years=min_years)
    else:
        # With day tolerance (+/- days)
        clause = """(
            CAST(julianday('now', 'localtime') AS INTEGER) % 365
            BETWEEN (CAST(julianday(datetime(exif_datetime, 'unixepoch', 'localtime')) AS INTEGER) % 365 - {tolerance})
            AND (CAST(julianday(datetime(exif_datetime, 'unixepoch', 'localtime')) AS INTEGER) % 365 + {tolerance})
            AND CAST(strftime('%Y', 'now', 'localtime') AS INTEGER)
                - CAST(strftime('%Y', datetime(exif_datetime, 'unixepoch', 'localtime')) AS INTEGER)
                >= {min_years}
        )""".format(min_years=min_years, tolerance=tolerance)

    if self.__config['model']['memories_mode'] == 'exclusive':
        self.set_where_clause('memories', clause)
```

**D. Add memory detection in get_next_file() (around line 410-440):**

After creating the Pic object, calculate if it's a memory:

```python
# Inside get_next_file(), after pic1 = Pic(**pic_row):
if pic1 and pic1.exif_datetime > 0:
    pic1 = self.__check_if_memory(pic1)

def __check_if_memory(self, pic):
    """Check if photo qualifies as a memory and set attributes."""
    import datetime

    photo_date = datetime.datetime.fromtimestamp(pic.exif_datetime)
    today = datetime.datetime.now()

    # Same month and day, different year
    if (photo_date.month == today.month and
        photo_date.day == today.day and
        photo_date.year < today.year):

        years_ago = today.year - photo_date.year
        min_years = self.__config['model'].get('memories_min_years', 1)

        if years_ago >= min_years:
            pic.is_memory = True
            pic.years_ago = years_ago

    return pic
```

---

### 2. `picframe/src/picframe/controller.py`

#### Changes:

**A. Add memories properties (after line ~285):**

```python
@property
def memories_enabled(self):
    return self.__model.memories_enabled

@memories_enabled.setter
def memories_enabled(self, val: bool):
    self.__model.memories_enabled = val
    if self.__viewer.is_video_playing():
        self.__viewer.stop_video()
    else:
        self.__next_tm = 0
    if self.__mqtt_config['use_mqtt']:
        self.publish_state()

@property
def memories_mode(self):
    return self.__model.memories_mode

@memories_mode.setter
def memories_mode(self, val: str):
    self.__model.memories_mode = val
    if self.__viewer.is_video_playing():
        self.__viewer.stop_video()
    else:
        self.__next_tm = 0
```

---

### 3. `picframe/src/picframe/viewer_display.py`

#### Changes:

**A. Add configuration reading in __init__ (around line 117-126):**

```python
# Memories overlay configs
self.__memories_display_style = config.get('memories_display_style', 'banner')
self.__memories_banner_position = config.get('memories_banner_position', 'T')
self.__memories_text_sz = config.get('memories_text_sz', 40)
self.__memories_opacity = config.get('memories_opacity', 1.0)
self.__memories_overlay = None
self.__memories_icon_overlay = None
self.__current_memory_years = 0
```

**B. Add memories banner drawing method (after __draw_clock around line 501):**

```python
def __draw_memories_banner(self, years_ago: int):
    """Draw the memories banner overlay at top or bottom of screen."""

    # Only rebuild if years changed
    if years_ago != self.__current_memory_years or self.__memories_overlay is None:
        self.__current_memory_years = years_ago

        # Build the banner text
        if years_ago == 1:
            banner_text = "1 Year Ago Today"
        else:
            banner_text = f"{years_ago} Years Ago Today"

        width = self.__display.width - 100
        opacity = int(255 * float(self.__memories_opacity) * self.get_brightness())

        self.__memories_overlay = pi3d.FixedString(
            self.__font_file,
            banner_text,
            font_size=self.__memories_text_sz,
            shader=self.__flat_shader,
            width=width,
            shadow_radius=3,
            justify="C",
            color=(255, 255, 255, opacity)
        )

        self.__memories_overlay.sprite.set_alpha(self.get_brightness())

        # Position at top or bottom
        hgt_offset = int(self.__display.height * 3 / 100)  # 3% from edge
        y = (self.__display.height - self.__memories_overlay.sprite.height
             - hgt_offset) // 2

        if self.__memories_banner_position == "B":
            y *= -1

        self.__memories_overlay.sprite.position(0, y, 0.1)

    if self.__memories_overlay:
        self.__memories_overlay.sprite.draw()
```

**C. Add memories icon drawing method:**

```python
def __draw_memories_icon(self, years_ago: int):
    """Draw the years counter icon in corner."""

    if years_ago != self.__current_memory_years or self.__memories_icon_overlay is None:
        self.__current_memory_years = years_ago

        # Icon text with years
        if years_ago == 1:
            icon_text = "1\nyr"
        else:
            icon_text = f"{years_ago}\nyrs"

        opacity = int(255 * float(self.__memories_opacity) * self.get_brightness())

        self.__memories_icon_overlay = pi3d.FixedString(
            self.__font_file,
            icon_text,
            font_size=int(self.__memories_text_sz * 0.8),
            shader=self.__flat_shader,
            width=100,
            shadow_radius=4,
            justify="C",
            color=(255, 255, 255, opacity)
        )

        self.__memories_icon_overlay.sprite.set_alpha(self.get_brightness())

        # Position in top-right corner (opposite side from clock if present)
        x = (self.__display.width - self.__memories_icon_overlay.sprite.width - 50) // 2
        y = (self.__display.height - self.__memories_icon_overlay.sprite.height - 50) // 2

        # Adjust based on clock position to avoid overlap
        if self.__show_clock and self.__clock_justify == "R":
            x *= -1  # Move to left side

        self.__memories_icon_overlay.sprite.position(x, y, 0.1)

    if self.__memories_icon_overlay:
        self.__memories_icon_overlay.sprite.draw()
```

**D. Add method to show memories overlay:**

```python
def show_memories_overlay(self, pic):
    """Show appropriate memories overlay based on configuration."""
    if pic is None or not getattr(pic, 'is_memory', False):
        self.__memories_overlay = None
        self.__memories_icon_overlay = None
        self.__current_memory_years = 0
        return

    years_ago = getattr(pic, 'years_ago', 0)
    if years_ago == 0:
        return

    style = self.__memories_display_style

    if style in ('banner', 'both'):
        self.__draw_memories_banner(years_ago)

    if style in ('icon', 'both'):
        self.__draw_memories_icon(years_ago)
```

**E. Call memories overlay in slideshow_is_running (around line 876-880):**

After drawing the slide and before drawing text:

```python
self.__slide.draw()
self.__draw_overlay()

# Draw memories overlay if applicable
if pics and pics[0]:
    self.show_memories_overlay(pics[0])

if self.clock_is_on:
    self.__draw_clock()
```

---

### 4. `picframe/src/picframe/interface_mqtt.py`

Add MQTT commands for memories control:

```python
# Add to command handlers
'memories_enabled': lambda val: setattr(controller, 'memories_enabled', val.lower() == 'on'),
'memories_mode': lambda val: setattr(controller, 'memories_mode', val),
```

---

### 5. `picframe/src/picframe/interface_http.py`

Add HTTP endpoints for memories control in the web interface.

---

## Implementation Order

1. **Phase 1: Core Logic**
   - [ ] Add configuration defaults to `model.py`
   - [ ] Add `is_memory` and `years_ago` attributes to `Pic` class
   - [ ] Implement `__check_if_memory()` method
   - [ ] Add memories properties to Model class

2. **Phase 2: Controller Integration**
   - [ ] Add memories properties to Controller
   - [ ] Wire up state publishing for MQTT

3. **Phase 3: Visual Display**
   - [ ] Add memories config reading in ViewerDisplay.__init__
   - [ ] Implement `__draw_memories_banner()` method
   - [ ] Implement `__draw_memories_icon()` method
   - [ ] Implement `show_memories_overlay()` method
   - [ ] Integrate into `slideshow_is_running()`

4. **Phase 4: Interfaces**
   - [ ] Add MQTT commands
   - [ ] Add HTTP API endpoints
   - [ ] Update web interface (optional)

5. **Phase 5: Testing & Polish**
   - [ ] Test with various date configurations
   - [ ] Test banner positioning with clock overlay
   - [ ] Test icon positioning
   - [ ] Verify mixed mode ratio works correctly

---

## Testing Checklist

- [ ] Memories overlay appears for photos from exactly 1 year ago
- [ ] Memories overlay appears for photos from 5+ years ago
- [ ] Banner displays correctly at top position
- [ ] Banner displays correctly at bottom position
- [ ] Icon displays in corner without overlapping clock
- [ ] "Both" style shows banner and icon together
- [ ] Exclusive mode only shows memory photos
- [ ] Mixed mode interspersed memories correctly
- [ ] MQTT commands work for toggling memories
- [ ] Day tolerance setting works correctly
- [ ] Minimum years setting filters correctly

---

## Future Enhancements

- Anniversary highlights (special styling for 5, 10, 25 year milestones)
- Notification sound/chime when memory appears
- Special transition effect for memories
- "Memory slideshow" mode - temporary exclusive mode
- Statistics tracking of memories shown
