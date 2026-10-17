# Incident: picframe down — labwc SIGSEGV + stale Wayland socket

**Date:** 2026-05-17  
**Host:** `photoframe-batanovs` (`ivan@10.0.0.91`)  
**Duration of outage:** ~42 minutes (15:57 EEST onward, still down at time of writing)  
**Service:** `picframe.service` (user-level systemd, `/home/ivan/.config/systemd/user/picframe.service`)

---

## Summary

The picframe service went down because:

1. The `labwc` Wayland compositor (PID 1373) crashed with **SIGSEGV** after running for 6h 45m.
2. The crash left a **stale Unix socket** at `/run/user/1000/wayland-0`.
3. Every subsequent restart attempt by systemd failed immediately: new `labwc` instances detected the stale socket, tried to connect as a *nested* Wayland client (instead of starting as a standalone DRM/KMS compositor), and exited with "Could not connect to remote display: Connection refused".
4. After **5 rapid restarts**, systemd hit the restart rate limit and gave up.

---

## Service configuration

```ini
# /home/ivan/.config/systemd/user/picframe.service
[Unit]
Description=PictureFrame on Pi

[Service]
ExecStart=/usr/bin/labwc
Restart=always

[Install]
WantedBy=default.target
```

labwc autostart: `/home/ivan/.config/labwc/autostart`
```
/home/ivan/start_picframe.sh
```

Start script: `/home/ivan/start_picframe.sh`
```bash
source /home/ivan/.venv_picframe/bin/activate
picframe &
```

labwc version: `0.9.2 (+xwayland +nls +rsvg +libsfdo)`

---

## Timeline (all times EEST / UTC+3)

| Time     | Event |
|----------|-------|
| 2026-05-16 10:21 | labwc (PID 1373) started successfully; `/run/user/1000/wayland-0` socket created |
| 2026-05-17 15:50–15:56 | picframe running normally; DHT22 warnings appearing (~every 30s); WiFi cycling every ~60s |
| **15:57:09** | systemd issued `Stopping picframe.service` — trigger unclear |
| **15:57:10** | Xwayland child (PID 1421) inside labwc got `(EE) failed to read Wayland events: Broken pipe` |
| **15:57:17** | `labwc[1373]: X connection to :0 broken (explicit kill or server shutdown)` |
| **15:57:17** | `picframe.service: Main process exited, code=killed, status=11/SEGV` |
| **15:57:18** | systemd restarts service; CPU time consumed: **6h 45m 15.389s** |
| 15:57:19 | Restart attempt 1 — `labwc[16104]`: "Could not connect to remote display: Connection refused" — exits 1 |
| 15:57:20 | Restart attempt 2 — `labwc[16112]`: same error |
| 15:57:20 | Restart attempt 3 — `labwc[16115]`: same error |
| 15:57:21 | Restart attempt 4 — `labwc[16118]`: same error |
| 15:57:21 | Restart attempt 5 — `labwc[16121]`: same error |
| **15:57:22** | `Start request repeated too quickly` — systemd stops retrying |
| 15:57:22 | `picframe.service` enters **failed** state (Result: exit-code) |

---

## Root cause analysis

### Primary failure: labwc SIGSEGV

labwc (PID 1373) was killed by signal 11 (SIGSEGV — segmentation fault). It had been running for ~6h 45m. The exact code path that segfaulted is unknown without a core dump.

The stop sequence observed in the journal:
```
15:57:09  systemd[1254]: Stopping picframe.service - PictureFrame on Pi...
15:57:10  labwc[1421]: (EE) failed to read Wayland events: Broken pipe
15:57:17  labwc[1373]: X connection to :0 broken (explicit kill or server shutdown).
15:57:17  systemd[1254]: picframe.service: Main process exited, code=killed, status=11/SEGV
```

The `Stopping` message at 15:57:09 may have been systemd reacting to an earlier signal, or something else triggered the stop. The segfault itself is the definitive cause.

### Secondary failure: stale socket blocking all restarts

When labwc exits (cleanly or via crash), wlroots leaves the socket file at:
```
/run/user/1000/wayland-0      (Unix domain socket, type srwxrwxr-x)
/run/user/1000/wayland-0.lock (lock file)
```

These are NOT cleaned up on crash. When the next labwc instance starts, wlroots auto-detects backends in priority order. Seeing `wayland-0` present in `XDG_RUNTIME_DIR`, it **tries the Wayland nested backend first**, regardless of whether `WAYLAND_DISPLAY` is set in the environment.

Verified: the systemd user environment has `WAYLAND_DISPLAY=` (empty), yet labwc still selects the Wayland backend because the socket file exists.

Exact error from each restart attempt:
```
[INFO]  [backend/wayland/backend.c:587] Creating wayland backend
[ERROR] [backend/wayland/backend.c:608] Could not connect to remote display: Connection refused
[ERROR] [../src/server.c:469] unable to create backend
```

The stale socket file had no owner (`fuser` returned nothing). Created 2026-05-16 10:21:32, last accessed 2026-05-17 10:21:50.

---

## Additional observations

### DHT22 sensor failures (ongoing, pre-existing)
Every ~30 seconds, picframe logs:
```
WARNING:dht_compat:All retries failed reading DHT22 on pin 17. Last error: DHT sensor not found, check wiring
```
This is unrelated to the crash but indicates the DHT22 sensor on GPIO 17 is either disconnected, wired incorrectly, or has a hardware fault.

### WiFi instability (ongoing)
`wlan0` was disconnecting and reconnecting every ~60 seconds throughout the observation window:
```
wpa_supplicant: CTRL-EVENT-DISCONNECTED bssid=2c:c8:1b:e1:3f:e8 reason=3 locally_generated=1
```
`reason=3 locally_generated=1` means the **Pi itself** is initiating the disconnection — typically caused by WiFi power management (`iwconfig wlan0 power management`). Each cycle takes ~1 second and reconnects successfully with the same IP (`192.168.91.71`), so it has not caused a service outage on its own. However, repeated MQTT connection drops are a likely side effect.

---

## Fix procedure

To restore the service after this type of failure:

```bash
# 1. Remove stale Wayland socket files
rm /run/user/1000/wayland-0
rm /run/user/1000/wayland-0.lock

# 2. Clear systemd's failed state so it will restart
systemctl --user reset-failed picframe

# 3. Start the service
systemctl --user start picframe

# 4. Verify
systemctl --user status picframe
```

---

## Recommended permanent fixes

### 1. Clean up stale socket before starting (immediate, low-risk)

Add `ExecStartPre` to the service unit to remove stale socket files before each labwc launch:

```ini
[Service]
ExecStartPre=/bin/rm -f /run/user/1000/wayland-0 /run/user/1000/wayland-0.lock
ExecStart=/usr/bin/labwc
Restart=always
RestartSec=5
StartLimitIntervalSec=60
StartLimitBurst=3
```

`RestartSec=5` and the burst limit prevent the "too quick" failure that stops all retries.

### 2. Investigate and fix the labwc segfault (important)

Enable core dumps to capture the next crash:

```bash
# On the Pi:
ulimit -c unlimited
# Or persistently via /etc/security/limits.conf or systemd coredump config
```

Check `/etc/systemd/coredump.conf` and `coredumpctl list` after the next crash. The segfault may be a known labwc 0.9.2 bug or a memory issue in a wlroots backend.

Alternatively, check for a newer labwc release that fixes stability issues.

### 3. Fix WiFi power management

```bash
# Disable WiFi power saving (survives reboot via NetworkManager config)
sudo nmcli connection modify "R2D2" 802-11-wireless.powersave 2
# or add to /etc/NetworkManager/conf.d/wifi-powersave-off.conf:
# [connection]
# wifi.powersave = 2
```

### 4. Add a systemd watchdog or health check

Since picframe has an HTTP interface, a watchdog that restarts the service on HTTP timeout would catch hangs that don't produce a segfault.

---

## Files and paths reference

| Path | Purpose |
|------|---------|
| `/home/ivan/.config/systemd/user/picframe.service` | systemd user unit |
| `/home/ivan/.config/labwc/autostart` | labwc autostart (launches picframe) |
| `/home/ivan/.config/labwc/environment` | labwc env vars (XKB layout, etc.) |
| `/home/ivan/.config/labwc/rc.xml` | labwc window manager config |
| `/home/ivan/start_picframe.sh` | shell wrapper activating venv and running `picframe` |
| `/home/ivan/.venv_picframe/` | Python venv with picframe installed (editable) |
| `/home/ivan/picframe/src/picframe/` | picframe source |
| `/run/user/1000/wayland-0` | Wayland compositor socket (created by labwc, must be absent at startup) |
| `/run/log/journal/68b3694a280342abba80a1d8a7a1af1a/` | System journal location on this host |
