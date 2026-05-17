# Photo Frame — Quick Setup

> Minimal steps to bring a new photoframe online with logging + migration scripts.

---

## 1) Install Alloy (logs & metrics)

One-liner (runs as root; auto-handles sudo if needed):

```bash
sudo apt update && sudo apt install -y curl
```

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/ravado/picframe/refs/heads/main/scripts/monitoring/install_alloy.sh)"
```


## 2) Install/Run migration & helper scripts

Bootstraps resizer/sync/backup helpers and any prerequisites:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/ravado/picframe/refs/heads/main/scripts/migration/install_all.sh)"
```

## Next Steps

1️⃣ **Edit the `backup.env` file**  
Update it to match your SMB and PicFrame configuration.

2️⃣ **Run the scripts manually in the following order as needed:**
```bash
./0_backup_setup.sh <prefix>
./1_install_picframe.sh
./2_restore_samba.sh
./3_restore_picframe_backup.sh <prefix> <latest|filename>
./4_sync_photos.sh
```

### Example:

```bash
./0_backup_setup.sh home
./3_restore_picframe_backup.sh home latest
```

## Links

- [Logs & Monitoring — README](monitoring/README.md)  
- [Migration & Helpers — README](migration/README.md)  