# Progress Bar Feature Plan

## Context
Add a visual progress bar showing how much time remains before the next photo appears.
Rendered as a thin horizontal bar at the top or bottom edge of the screen. The bar fills
left-to-right from 0% (new photo just appeared) to 100% (next photo about to load).
Height, color, and position are configurable.

---

## Files to Modify

| File | Change |
|------|--------|
| `picframe/src/picframe/model.py` | Add 4 keys to `DEFAULT_CONFIG['viewer']` |
| `picframe/src/picframe/config/configuration_example.yaml` | Document the 4 new keys in `viewer:` section |
| `picframe/src/picframe/viewer_display.py` | Init vars, new `__make_solid_bar` helper, new `__draw_progress_bar`, call-site in `slideshow_is_running` |

---

## Config Keys (add to DEFAULT_CONFIG viewer + configuration_example.yaml)

```python
'show_progress_bar':    False,
'progress_bar_height':  8,                    # pixels tall
'progress_bar_color':   [255, 255, 255, 200], # RGBA
'progress_bar_position':'B',                  # 'T' top / 'B' bottom
```

No background track — just a single bar growing left-to-right from 0 to full screen width.

---

## viewer_display.py Changes

### 1. `__init__` — read config & init state (after sensors block, same comment style)

```python
# [ivan] progress bar configs
self.__show_progress_bar    = config['show_progress_bar']
self.__progress_bar_height  = config['progress_bar_height']
self.__progress_bar_color   = config['progress_bar_color']
self.__progress_bar_position= config['progress_bar_position']
self.__progress_bar_tex     = None  # 1x1 color texture, created once on first draw
self.__progress_bar_fill    = None  # sprite rebuilt when progress crosses 0.5% step
self.__prev_progress        = -1.0
```

### 2. `slideshow_start` — no setup needed (bar sprite is created lazily in `__draw_progress_bar`)

### 3. New private helper `__make_solid_bar(w, h, x)` (place near `__draw_overlay`)

Creates a pi3d.Sprite from a cached 1×1 RGBA texture (same texture pattern as text_bkg in `slideshow_start`).
The texture is created once on first call and reused — only the sprite geometry changes per rebuild.

```python
def __make_solid_bar(self, w, h, x):
    if self.__progress_bar_tex is None:
        r, g, b, a = self.__progress_bar_color
        tex_arr = np.zeros((1, 1, 4), dtype=np.uint8)
        tex_arr[0, 0] = [r, g, b, a]
        self.__progress_bar_tex = pi3d.Texture(tex_arr, blend=True, mipmap=False, free_after_load=True)
    bar_y = (self.__display.height - h) // 2
    if self.__progress_bar_position == "B":
        bar_y *= -1
    sprite = pi3d.Sprite(w=w, h=h, x=x, y=bar_y, z=3.9)
    sprite.set_draw_details(self.__flat_shader, [self.__progress_bar_tex])
    return sprite
```

Z=3.9 renders in front of text_bkg (z=4.0) and overlay (z=4.1), behind clock/sensors (z=0.1).
Lower z = closer to camera in pi3d's 2D mode. Main image is at z=5.0 (furthest back).

### 4. New private method `__draw_progress_bar(time_delay)` (place after `__draw_overlay`)

```python
def __draw_progress_bar(self, time_delay):
    if self.__next_tm == 0.0:
        return
    tm = time.time()
    progress = max(0.0, min(1.0, 1.0 - (self.__next_tm - tm) / time_delay)) if time_delay > 0 else 0.0
    quantized = round(progress * 200) / 200.0  # 0.5% steps — avoids VBO rebuild every frame at 20fps

    if quantized != self.__prev_progress:
        bar_w = max(1, int(self.__display.width * quantized))
        x = bar_w // 2 - self.__display.width // 2   # keep left edge flush to screen left
        self.__progress_bar_fill = self.__make_solid_bar(
            w=bar_w, h=self.__progress_bar_height, x=x)
        self.__prev_progress = quantized

    if self.__progress_bar_fill:
        self.__progress_bar_fill.draw()
```

### 5. Call-site in `slideshow_is_running` (after `__draw_overlay`, line ~885)

```python
self.__slide.draw()
self.__draw_overlay()
if self.__show_progress_bar:          # NEW
    self.__draw_progress_bar(time_delay)
if self.clock_is_on:
    self.__draw_clock()
```

---

## Key Reused Patterns

- **1×1 numpy texture → pi3d.Sprite** — same as `text_bkg` in `slideshow_start` (line 719-724)
- **Cached texture** — color texture created once, reused across all ~200 sprite rebuilds per image
- **Lazy rebuild on 0.5% step** — same guard pattern as `__draw_clock` (rebuild only when value changes)
- **Z-depth layering** — z=3.9 renders in front of overlays, behind clock/sensors/text
- **`self.__next_tm` timing** — already maintained in `slideshow_is_running` (set at line 814)
- **Config comment style** — `# [ivan]` prefix block, matching sensors block in `__init__`
- **No background track** — single growing bar only

---

## Verification

1. Set `show_progress_bar: True` in `configuration.yaml`
2. Run `python -m picframe.start`
3. Observe a thin bar at top/bottom growing left-to-right over `time_delay` seconds
4. Try `progress_bar_height: 20`, `progress_bar_position: "T"`, custom RGBA colors — verify each
5. Confirm bar is absent when `show_progress_bar: False` (default)
