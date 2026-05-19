# picframe / scripts

Operational scripts that ship with the picframe fork. Layout below tells you
who calls what so you can clean up safely.

## Layout

| Folder | What's in it | When it runs |
|---|---|---|
| `runtime/` | Scripts invoked **by cron or systemd on a deployed frame**. Touching anything here can break a live frame. | Automatically, on a schedule |
| `ops/` | Manual maintenance — update, audit, compare, list. Run by you over SSH. | On demand |
| `install/` | Bootstrap, install, restore, migration. The numbered `1_…5_` flow + helpers. | Once per frame |
| `sensors/` | One-shot probe scripts for the various temp/touch sensors. Not wired into autostart on either current frame. | On demand, for hardware bring-up |
| `monitoring/` | Grafana Alloy / log-forwarder installers. | Once per frame |
| `grafana-dashboards/` | Dashboard JSON consumed by an external Grafana server. | Imported by Grafana |
| `photo-normalization/` | Admin scripts to fix photo extensions / dedupe on the NAS. | Manually, by you |
| `_quarantine/` | Verified-dead scripts kept for one more sync cycle before deletion. **Nothing here is invoked by anything.** | Never |

## What's actually live on the frames

```
cron (00:00 daily)
    └── sudo systemctl start photo-sync@<instance>.service
            └── runtime/sync_photos_from_nasik.sh <instance>
                    └── rclone sync nasikphotos:/Photo-Frames/<Instance> → ~/Pictures/PhotoFrame
```

That is the **entire** runtime chain. The display on/off schedule is handled
by `curl http://localhost:9000/?display_is_on=…` cron lines, with
`ops/monitor_safety_on_boot.sh` as an `@reboot` safety net so a power-cut
reboot in the middle of the off window doesn't leave the screen on.

## Script index

| Path | Purpose | Invoked by |
|---|---|---|
| `runtime/sync_photos_from_nasik.sh` | rclone sync NAS → `~/Pictures/PhotoFrame` | `photo-sync@.service` + `photo-sync.service` (daily cron) |
| `ops/update.sh` | `git pull` + `pip install -e .` + restart `picframe.service` | manual on each frame |
| `ops/monitor_safety_on_boot.sh` | `@reboot` safety net: figure out desired display state from per-frame schedule, wait for picframe HTTP, then `curl …?display_is_on=…` | `@reboot` cron line on each frame |
| `update_web_ui.sh` | sync redesigned web UI from `src/picframe/html/` → runtime `~/picframe_data/html/` (diff first, `--force`/`--check` flags) | manual, after web UI changes |
| `ops/check_date_range_files.py` | list/find photos in a date window | manual |
| `ops/compare_missing_files.sh` | diff two photo directories | manual |
| `ops/calculate_photo_hash.sh` | hash a photo for dedupe checks | manual |
| `ops/list_all_images_without_gps.sh` | list photos missing GPS EXIF | manual |
| `ops/sync_original_photos_from_local_to_nas.sh` | push local originals → NAS share | manual |
| `install/0_backup_setup.sh` | archive frame config + upload to SMB | manual; or cron via `configure_periodic_backups.sh` |
| `install/1_install_packages.sh` | apt install system deps | `install_all.sh` step 1 / manual |
| `install/2_install_picframe.sh` | clone fork, build venv, write systemd unit | `install_all.sh` step 2 / manual |
| `install/3_restore_samba.sh` | configure Samba server + client creds | `install_all.sh` step 3 / manual |
| `install/4_restore_picframe_backup.sh` | restore SSH, WireGuard, crontab, `picframe_data` from SMB | `install_all.sh` step 4 / manual |
| `install/5_configure_photo_sync.sh` | write `photo-sync@.service` + daily cron + sudoers | `install_all.sh` step 5 / manual |
| `install/env_loader.sh` | sourced env-var loader/validator (`backup.env`) | sourced by `3_restore_samba.sh`, `4_restore_picframe_backup.sh`, `5_configure_photo_sync.sh` |
| `install/install_all.sh` | curl-download all install scripts into cwd | one-liner bootstrap from `install/README.md` |
| `install/fix_photo_sync_sudoers.sh` | install `/etc/sudoers.d/photo-sync` on already-deployed frames | manual (one-shot remediator) |
| `install/configure_periodic_backups.sh` | install `/etc/cron.<freq>/picframe_backup` wrapper for `0_backup_setup.sh` | manual |
| `install/migrate_to_in_repo_scripts.sh` | rewrite a live frame from old `~/Documents/Scripts/` → in-repo `runtime/` | manual, once per frame |
| `install/_legacy/community_installation.sh` | original upstream community installer | nothing (kept for reference) |
| `sensors/read_am2031a_sensor.py` | one-shot read of AM2031A temp/humidity | manual hardware bring-up |
| `sensors/read_dht11_sensor.py` | one-shot read of DHT11 | manual |
| `sensors/read_dht22_sensor.py` | one-shot read of DHT22 | manual |
| `sensors/read_i2c_bme280_sensor.py` | one-shot read of BME280 over I²C | manual |
| `sensors/read_ttp223_touch_sensor.py` | TTP223 capacitive touch read | manual |
| `monitoring/install_alloy.sh` | apt-installs Grafana Alloy, fetches `default_config.alloy`, substitutes `${LOKI_URL}`/`${PROMETHEUS_URL}` (prompts for host), enables `alloy.service` | manual (current forwarder) |
| `monitoring/install_fluentbit_and_node_exporter.sh` | lightweight alternative to Alloy (~20MB vs ~250MB RAM): apt-installs Fluent Bit (journal → Loki with Lua label enrichment) + downloads node_exporter v1.8.2 binary; writes both systemd units | manual |
| `monitoring/reconfigure_to_promptail_and_node_exporter.sh` | older variant: downloads Promtail v3.2.0 + node_exporter v1.8.2 release tarballs and writes systemd units. **Hardcodes `loghub.lan:3100` as Loki target** — superseded by the two installers above | manual (legacy) |
| `photo-normalization/normalize_photo_extensions.sh` | lowercases file extensions in a directory tree (`.JPG` → `.jpg`); `--dry-run` supported, skips name collisions, logs to `rename.log` | manual, run on NAS share |
| `photo-normalization/normalize_photo_extensions_in_db.sh` | same lowercasing applied to picframe's SQLite DB (`file.extension` column): backs up `.bak.<ts>`, dedupes rows (keeps `MIN(file_id)`), then `UPDATE`. `--dry-run` prints counts + sample rows | manual, against `picframe_data/data/pictureframe.db3` |
| `photo-normalization/list_rclone_dupes.sh` | read-only: finds files matching rclone's duplicate suffix pattern `... {hash}.<ext>` and prints them with a total count | manual |
| `_quarantine/*` | verified dead — see [Why `_quarantine/`](#why-_quarantine) | nothing |

## Common tasks

- **Fresh install** → `install/README.md`
- **Migrate an existing frame to this layout** → `install/migrate_to_in_repo_scripts.sh`
- **Update an existing frame** → `ops/update.sh` (run as `ivan` on the Pi)
- **Sync redesigned web UI after a pull** → `update_web_ui.sh`
- **Add a new sync remote** → `install/5_configure_photo_sync.sh <instance>`

## Service control

picframe runs as a **user** systemd unit (`~/.config/systemd/user/picframe.service`),
so no `sudo`. Run these as `ivan` on the Pi:

```bash
systemctl --user restart picframe          # restart after a code change
systemctl --user status  picframe          # check if running + last lines of log
systemctl --user stop    picframe
systemctl --user start   picframe
journalctl   --user -u   picframe -f       # tail live logs
journalctl   --user -u   picframe --since today
```

For the full update flow (git pull + pip install + restart) use `ops/update.sh`
instead — it does all three steps in order.

## Why `_quarantine/`

Each script in there was found dead by audit:

- `sync_and_resize_photos.sh`, `sync_and_resize_photos_wrapper.sh` — internal
  calls to resize helpers are commented out; rclone path uses a `/Resized/`
  subdir that doesn't match what frames sync.
- `resize_new_photos.sh`, `resize_new_photos_lxc.sh`, `remove_missing_photos.sh`
  — hardcode `/home/ivan.cherednychok/...`; that user does not exist on
  current frames (they run as `ivan`).
- `prepare_ubuntu_vm_for_picframe.sh` — VM-only.
- `clapper_app.py`, `multiclapper.py`, `mqtt_open_next_photo.py`,
  `read_all_photos_from_google_photos.py`, `get_exif_data_from_photo.py`,
  `read_exif_data.py` — experiments, never wired into autostart.
- `PhotoFrameAliases.txt` — SSH aliases for an old user/IP set
  (`ivan.cherednychok` @ `10.0.0.101/102`, `192.168.91.103`) that doesn't
  match the current fleet.

Delete the folder once the next full sync cycle on both frames confirms no
regression.

## Links

- [Install / migration](install/README.md)
- [Monitoring](monitoring/README.md)
