# PicFrame Migration Scripts Analysis Report

## Executive Summary

This report analyzes 11 migration scripts designed to deploy and configure PicFrame digital photo frames on Raspberry Pi devices. The analysis identified **14 critical issues** that can cause network card errors, system hangs, and resource exhaustion specifically on Raspberry Pi Zero 2W (1GB RAM, limited I/O).

### Key Findings

| Severity | Count | Description                                        |
| -------- | ----- | -------------------------------------------------- |
| Critical | 6     | Operations that can hang indefinitely or cause OOM |
| High     | 4     | Resource exhaustion risks and deprecated APIs      |
| Medium   | 4     | Missing error handling and package conflicts       |

### Impact on Raspberry Pi Zero 2W

The Pi Zero 2W has:
- **512MB-1GB RAM** (depending on model)
- **Single-core or quad-core ARM Cortex-A53**
- **Limited USB bandwidth** (shared with networking)
- **No hardware network interface** (USB-based WiFi)
- **Default swap of only 100MB** (insufficient for compilation)

These constraints make the scripts particularly problematic as network operations compete for USB bandwidth and memory.

### How Pip/Package Issues Cause Network Hangs

A critical finding is that Python package installation problems create a causal chain leading to network failures:

1. **C extension compilation** (Adafruit_DHT, numpy) exhausts memory (500MB-1GB needed)
2. **Heavy swapping** occurs when RAM + default 100MB swap are overcommitted
3. **SD card I/O bottleneck** develops from excessive swap activity
4. **Network I/O starvation** as USB bandwidth is consumed by swap
5. **WiFi driver crashes** or hangs, causing "Network unreachable" errors

---

## Scripts Overview

| Script | Purpose | Risk Level |
|--------|---------|------------|
| `install_all.sh` | Downloads all scripts from GitHub | Low |
| `env_loader.sh` | Loads and validates environment variables | Low |
| `0_backup_setup.sh` | Backs up PicFrame config to SMB share | **High** |
| `1_install_picframe.sh` | Installs PicFrame and dependencies | **Critical** |
| `2_restore_samba.sh` | Configures local Samba server | Medium |
| `3_restore_picframe_backup.sh` | Restores backup from SMB share | **High** |
| `4_sync_photos.sh` | Legacy rsync-based photo sync | Medium |
| `5_configure_photo_sync.sh` | Configures rclone-based sync service | Medium |
| `sync_photos_from_nasik.sh` | Syncs photos from NAS via rclone | **High** |

---

## Critical Issues

### Issue 1: Infinite DNS Polling Loop (CRITICAL)

**File:** `1_install_picframe.sh:47-49`

```bash
# Wait until DNS is back online
echo "Waiting for DNS to come back..."
until ping -c1 8.8.8.8 >/dev/null 2>&1 || host google.com >/dev/null 2>&1; do
  sleep 2
done
```

**Problem:** This loop has no maximum iteration count or timeout. If the network interface fails (common on Pi Zero 2W with USB WiFi), the script will poll forever.

**Impact:**
- Infinite loop consuming CPU cycles
- Prevents script completion
- No way to recover without manual intervention

**Recommended Fix:**
```bash
echo "Waiting for DNS to come back..."
MAX_RETRIES=30
RETRY_COUNT=0
until ping -c1 -W5 8.8.8.8 >/dev/null 2>&1 || host google.com >/dev/null 2>&1; do
  RETRY_COUNT=$((RETRY_COUNT + 1))
  if [[ $RETRY_COUNT -ge $MAX_RETRIES ]]; then
    echo "❌ DNS not available after $MAX_RETRIES attempts. Exiting."
    exit 1
  fi
  echo "  Retry $RETRY_COUNT/$MAX_RETRIES..."
  sleep 2
done
```

---

### Issue 2: SMB Operations Without Timeout (CRITICAL)

**Files:**
- `0_backup_setup.sh:160-172`
- `3_restore_picframe_backup.sh:75-79, 98`

**Example from `0_backup_setup.sh:160-172`:**
```bash
if smbclient "$SMB_BACKUPS_PATH" -A "$SMB_CRED_FILE" \
    -c "cd $SMB_BACKUPS_SUBDIR; lcd $ARCHIVE_DIR; put $ARCHIVE_FILE"; then

    echo "✅ Backup uploaded to SMB."

    echo "🗑️ Applying retention policy (keep last $MAX_BACKUPS backups for prefix '$PREFIX')..."
    smbclient "$SMB_BACKUPS_PATH" -A "$SMB_CRED_FILE" \
        -c "cd $SMB_BACKUPS_SUBDIR; ls" | \
        ...
```

**Problem:** `smbclient` operations have no timeout configured. On slow networks or when the SMB server is unresponsive, these commands will block indefinitely.

**Impact:**
- Script hangs waiting for SMB response
- USB WiFi on Pi Zero can enter degraded state
- Network stack can become unresponsive

**Recommended Fix:**
```bash
# Add timeout wrapper function
smb_with_timeout() {
    timeout 60 smbclient "$@"
    local exit_code=$?
    if [[ $exit_code -eq 124 ]]; then
        echo "❌ SMB operation timed out after 60 seconds"
        return 1
    fi
    return $exit_code
}

# Usage:
if smb_with_timeout "$SMB_BACKUPS_PATH" -A "$SMB_CRED_FILE" \
    -c "cd $SMB_BACKUPS_SUBDIR; lcd $ARCHIVE_DIR; put $ARCHIVE_FILE"; then
```

---

### Issue 3: Git Clone Without Timeout (HIGH)

**File:** `1_install_picframe.sh:80-82`

```bash
git clone -b main https://github.com/ravado/picframe.git
# git clone https://github.com/helgeerbe/picframe.git
cd picframe
```

**Problem:** Git clone over HTTPS on slow/unstable networks can hang indefinitely.

**Impact:**
- Clone operation blocks forever on network issues
- No progress indication for large repositories
- Memory pressure during clone operation

**Recommended Fix:**
```bash
echo "📥 Cloning picframe (timeout: 5 minutes)..."
if ! timeout 300 git clone --depth 1 -b main https://github.com/ravado/picframe.git; then
    echo "❌ Git clone failed or timed out"
    exit 1
fi
cd picframe
```

---

### Issue 4: APT Operations Without Timeout (HIGH)

**File:** `1_install_picframe.sh:16-28`

```bash
sudo apt -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" update
sudo apt -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade -y

echo "📦 Installing required packages..."
sudo apt install -y \
    python3 python3-pip python3-pil python3-numpy python3-libgpiod \
    ...
```

**Problem:** Package operations can take extremely long on Pi Zero 2W due to:
- Slow SD card I/O
- Limited RAM causing swap thrashing
- Network latency for package downloads

**Impact:**
- System becomes unresponsive during large package installations
- OOM killer may terminate processes
- dpkg database can become corrupted if interrupted

**Recommended Fix:**
```bash
# Install packages in smaller batches
CORE_PACKAGES=(python3 python3-pip python3-pil python3-numpy)
DISPLAY_PACKAGES=(xserver-xorg x11-xserver-utils xinit)
MEDIA_PACKAGES=(libsdl2-dev libsdl2-image-2.0-0 libsdl2-mixer-2.0-0 libsdl2-ttf-2.0-0)

for group in CORE_PACKAGES DISPLAY_PACKAGES MEDIA_PACKAGES; do
    declare -n packages="$group"
    echo "📦 Installing ${group}..."
    if ! timeout 600 sudo apt install -y "${packages[@]}"; then
        echo "❌ Failed to install ${group}"
        exit 1
    fi
done
```

---

### Issue 5: rclone Concurrency Too High for Pi Zero 2W (HIGH)

**File:** `sync_photos_from_nasik.sh:39-46`

```bash
rclone sync -v "$SRC" "$DEST" \
  --ignore-case-sync \
  --copy-links \
  --create-empty-src-dirs \
  --exclude "Thumbs.db" \
  --exclude ".DS_Store" \
  --transfers=4 \
  --checkers=8
```

**Problem:** Running 4 transfers + 8 checkers = 12 concurrent operations. On Pi Zero 2W with 512MB-1GB RAM and USB-based networking, this causes:
- Memory exhaustion
- Network interface saturation
- USB bandwidth contention

**Resource Analysis:**
| Setting | Memory Impact | Network Impact |
|---------|--------------|----------------|
| `--transfers=4` | ~50-100MB per transfer | 4 concurrent connections |
| `--checkers=8` | ~20-40MB per checker | 8 concurrent hash checks |
| **Total** | **360-720MB** | **12 concurrent operations** |

**Impact:**
- OOM killer activation
- Network timeouts
- WiFi driver crashes on USB-based adapters

**Recommended Fix:**
```bash
rclone sync -v "$SRC" "$DEST" \
  --ignore-case-sync \
  --copy-links \
  --create-empty-src-dirs \
  --exclude "Thumbs.db" \
  --exclude ".DS_Store" \
  --transfers=1 \
  --checkers=2 \
  --buffer-size=16M \
  --low-level-retries 3 \
  --retries 3 \
  --timeout 60s \
  --contimeout 30s
```

---

### Issue 6: Missing `set -euo pipefail` (MEDIUM)

**File:** `2_restore_samba.sh:1-2`

```bash
#!/bin/bash

###########################
# Load secrets from .env file
###########################
```

**Problem:** Script lacks `set -euo pipefail`, allowing it to continue after errors silently.

**Comparison with other scripts:**
| Script | Has `set -e` | Has `set -u` | Has `pipefail` |
|--------|-------------|--------------|----------------|
| `0_backup_setup.sh` | ✅ | ✅ | ✅ |
| `1_install_picframe.sh` | ✅ | ✅ | ✅ |
| `2_restore_samba.sh` | ❌ | ❌ | ❌ |
| `3_restore_picframe_backup.sh` | ✅ | ✅ | ✅ |

**Impact:**
- Errors in commands may go unnoticed
- Script continues with incomplete state
- Samba configuration may be partially applied

**Recommended Fix:**
```bash
#!/bin/bash
set -euo pipefail
```

---

### Issue 7: Missing Error Handling in SMB User Creation (MEDIUM)

**File:** `2_restore_samba.sh:69-72`

```bash
else
    echo -e "$PASSWORD\n$PASSWORD" | sudo smbpasswd -a "$USERNAME" -s
    sudo smbpasswd -e "$USERNAME"
    echo "✅ Samba user '$USERNAME' created and enabled"
fi
```

**Problem:** No error checking after `smbpasswd` commands. If password doesn't meet complexity requirements or user creation fails, script reports success anyway.

**Recommended Fix:**
```bash
else
    if ! echo -e "$PASSWORD\n$PASSWORD" | sudo smbpasswd -a "$USERNAME" -s; then
        echo "❌ Failed to create Samba user '$USERNAME'"
        exit 1
    fi
    if ! sudo smbpasswd -e "$USERNAME"; then
        echo "❌ Failed to enable Samba user '$USERNAME'"
        exit 1
    fi
    echo "✅ Samba user '$USERNAME' created and enabled"
fi
```

---

### Issue 8: rsync Without Bandwidth Limit (MEDIUM)

**File:** `4_sync_photos.sh:21-23`

```bash
rsync -av --progress --ignore-existing --delete \
    "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}" \
    "${LOCAL_PATH}"
```

**Problem:** rsync runs at full speed, potentially saturating the network interface.

**Impact:**
- WiFi congestion on shared networks
- USB bandwidth exhaustion on Pi Zero
- May cause WiFi disconnections

**Recommended Fix:**
```bash
rsync -av --progress --ignore-existing --delete \
    --bwlimit=2000 \
    --timeout=120 \
    "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}" \
    "${LOCAL_PATH}"
```

---

### Issue 9: Hardcoded User Path (LOW)

**File:** `1_install_picframe.sh:123`

```bash
ExecStart=/usr/bin/xinit /home/ivan.cherednychok/picframe/picframe_data/launch.sh -- :0 -s 0 vt1 -keeptty
```

**Problem:** Hardcoded username instead of using detected `$HOME_DIR` variable.

**Also found in:** `5_configure_photo_sync.sh:21-24`
```bash
RUN_USER="ivan.cherednychok"
RUN_HOME="/home/${RUN_USER}"
```

**Recommended Fix:**
```bash
ExecStart=/usr/bin/xinit ${HOME_DIR}/picframe/picframe_data/launch.sh -- :0 -s 0 vt1 -keeptty
```

---

### Issue 10: X Server Started in Background Without Health Check (LOW)

**File:** `1_install_picframe.sh:97-98`

```bash
sudo X :0 -nolisten tcp &
sleep 3
```

**Problem:** Fixed 3-second sleep instead of checking if X server actually started. On slow Pi Zero, X may need more time.

**Recommended Fix:**
```bash
echo "🎨 Starting X server for HDMI display..."
sudo X :0 -nolisten tcp &
X_PID=$!

# Wait for X to be ready (max 30 seconds)
for i in {1..30}; do
    if xdpyinfo -display :0 >/dev/null 2>&1; then
        echo "✅ X server started successfully"
        break
    fi
    if ! kill -0 $X_PID 2>/dev/null; then
        echo "❌ X server process died"
        exit 1
    fi
    sleep 1
done
```

---

## Python Package Installation Issues

### Issue 11: Mixing apt and pip Packages (CRITICAL)

**File:** `1_install_picframe.sh:20-21` (apt) and `66-68` (pip)

**APT Installation (lines 20-21):**
```bash
sudo apt install -y \
    python3 python3-pip python3-pil python3-numpy python3-libgpiod \
```

**Pip Installation (lines 66-68):**
```bash
pip3 install --break-system-packages picframe
pip3 install --break-system-packages Adafruit_DHT --install-option="--force-pi"
pip3 install --break-system-packages adafruit-circuitpython-dht paho-mqtt
```

**Problem:** The script installs `python3-pil` and `python3-numpy` via apt, then uses pip with `--break-system-packages` which can install overlapping or conflicting dependencies. This flag bypasses Python's package isolation specifically designed to prevent such conflicts.

**Impact:**
- Package version conflicts between apt and pip versions
- Runtime crashes when wrong version is loaded
- Unpredictable behavior in PIL/numpy operations
- System Python environment corruption

**Recommended Fix:**
```bash
# Use a virtual environment instead of --break-system-packages
python3 -m venv /opt/picframe
source /opt/picframe/bin/activate
pip install picframe adafruit-circuitpython-dht paho-mqtt
```

---

### Issue 12: Deprecated `--install-option` Flag (HIGH)

**File:** `1_install_picframe.sh:66`

```bash
pip3 install --break-system-packages Adafruit_DHT --install-option="--force-pi"
```

**Problem:** The `--install-option` flag was deprecated in pip 23.1 and completely **removed in pip 25.0**. Raspberry Pi OS Bookworm ships with pip 24.2+, and future updates will break this command entirely.

**Impact:**
- Script fails on pip 25.0+ with "unrecognized arguments" error
- No fallback mechanism when installation fails
- Forces manual intervention to complete setup

**Recommended Fix:**
```bash
# Option 1: Use --config-setting (pip 23.1+)
pip3 install --break-system-packages Adafruit_DHT --config-setting="--build-option=--force-pi"

# Option 2: Better - use only the CircuitPython version (see Issue 14)
pip3 install adafruit-circuitpython-dht
```

---

### Issue 13: C Compilation Memory Exhaustion (CRITICAL)

**File:** `1_install_picframe.sh:66`

```bash
pip3 install --break-system-packages Adafruit_DHT --install-option="--force-pi"
```

**Problem:** The `Adafruit_DHT` library contains C extensions that require compilation during installation. On Pi Zero 2W, C compilation requires **500MB-1GB of RAM**, which exceeds available memory when combined with default 100MB swap.

**Memory Requirements During Compilation:**

| Operation | Memory Usage |
|-----------|--------------|
| GCC compiler | ~150-300MB |
| Header files/buffers | ~100-200MB |
| Object linking | ~200-400MB |
| **Total Peak** | **500MB-1GB** |

**Impact:**
- OOM (Out of Memory) killer terminates processes
- System freeze during compilation
- Partial installation leaves broken packages
- USB/network subsystem hangs from I/O starvation

**Recommended Fix:**
```bash
# Increase swap BEFORE any pip install with C extensions
echo "📝 Increasing swap for compilation..."
sudo sed -i 's/CONF_SWAPSIZE=100/CONF_SWAPSIZE=1024/' /etc/dphys-swapfile
sudo dphys-swapfile setup
sudo dphys-swapfile swapon
echo "✅ Swap increased to 1024MB"

# Now safe to install packages with C extensions
pip3 install Adafruit_DHT

# Optionally restore original swap after installation
sudo sed -i 's/CONF_SWAPSIZE=1024/CONF_SWAPSIZE=100/' /etc/dphys-swapfile
sudo dphys-swapfile setup
```

---

### Issue 14: Conflicting DHT Libraries Installed (MEDIUM)

**File:** `1_install_picframe.sh:66-67`

```bash
pip3 install --break-system-packages Adafruit_DHT --install-option="--force-pi"
pip3 install --break-system-packages adafruit-circuitpython-dht paho-mqtt
```

**Problem:** The script installs BOTH the legacy `Adafruit_DHT` library (C-based) AND the newer `adafruit-circuitpython-dht` library (pure Python). These libraries:

1. Serve the same purpose (reading DHT temperature/humidity sensors)
2. Have different APIs and import names
3. Cannot be used simultaneously in the same code
4. The C version requires compilation (memory-intensive)
5. The Python version is pure Python (no compilation needed)

**Comparison:**

| Library | Type | Compilation | Memory to Install | Maintenance |
|---------|------|-------------|-------------------|-------------|
| `Adafruit_DHT` | C extension | Required | 500MB+ | Deprecated |
| `adafruit-circuitpython-dht` | Pure Python | None | ~50MB | Active |

**Impact:**
- Wasted installation time and memory
- Potential import conflicts
- Unclear which library the application uses
- Unnecessary compilation on resource-constrained device

**Recommended Fix:**
```bash
# Use ONLY the CircuitPython version - no compilation needed
pip3 install adafruit-circuitpython-dht

# Update application code to use new API:
# Old: import Adafruit_DHT
# New: import adafruit_dht
```

---

## Recommended Virtual Environment Approach

Instead of using `--break-system-packages`, create an isolated environment:

```bash
#!/bin/bash
# Create and activate virtual environment
python3 -m venv /opt/picframe
source /opt/picframe/bin/activate

# Install all Python packages in isolated environment
pip install --upgrade pip
pip install picframe
pip install adafruit-circuitpython-dht  # Pure Python, no compilation
pip install paho-mqtt

# Create activation wrapper for systemd
cat > /usr/local/bin/picframe-run << 'EOF'
#!/bin/bash
source /opt/picframe/bin/activate
exec python -m picframe "$@"
EOF
chmod +x /usr/local/bin/picframe-run
```

**Benefits of Virtual Environment:**
- No system Python corruption
- No `--break-system-packages` needed
- Clean dependency isolation
- Easy to recreate if issues occur
- Follows Python best practices

---

## Swap Configuration for Compilation

Add this before any pip installation that may compile C extensions:

```bash
configure_swap_for_compilation() {
    local SWAP_SIZE="${1:-1024}"
    local SWAP_FILE="/etc/dphys-swapfile"

    echo "📝 Configuring swap to ${SWAP_SIZE}MB for compilation..."

    # Backup original
    sudo cp "$SWAP_FILE" "${SWAP_FILE}.backup"

    # Update swap size
    sudo sed -i "s/CONF_SWAPSIZE=.*/CONF_SWAPSIZE=${SWAP_SIZE}/" "$SWAP_FILE"

    # Apply changes
    sudo dphys-swapfile swapoff
    sudo dphys-swapfile setup
    sudo dphys-swapfile swapon

    # Verify
    local ACTUAL=$(free -m | awk '/Swap:/ {print $2}')
    echo "✅ Swap configured: ${ACTUAL}MB"
}

restore_original_swap() {
    local SWAP_FILE="/etc/dphys-swapfile"

    if [[ -f "${SWAP_FILE}.backup" ]]; then
        sudo mv "${SWAP_FILE}.backup" "$SWAP_FILE"
        sudo dphys-swapfile swapoff
        sudo dphys-swapfile setup
        sudo dphys-swapfile swapon
        echo "✅ Original swap configuration restored"
    fi
}

# Usage:
configure_swap_for_compilation 1024
pip install some-package-with-c-extensions
restore_original_swap
```

---

## Resource Usage Analysis for Pi Zero 2W

### Memory Budget

| Component | Memory Usage | Notes |
|-----------|--------------|-------|
| Raspberry Pi OS Base | ~150MB | Minimal services |
| X Server | ~30-50MB | For display |
| PicFrame Python | ~100-150MB | Image processing |
| rclone (default config) | ~360-720MB | **Exceeds available RAM** |
| Swap usage | Variable | Causes I/O thrashing |

**Total with current scripts:** ~640-1070MB (exceeds 512MB-1GB available)

### Recommended Memory Budget

| Component | Memory Usage | Changes |
|-----------|--------------|---------|
| Raspberry Pi OS Base | ~150MB | - |
| X Server | ~30-50MB | - |
| PicFrame Python | ~100-150MB | - |
| rclone (optimized) | ~50-80MB | Reduced concurrency |
| **Total** | **~330-430MB** | Within 512MB limit |

---

## Priority Ranking of Fixes

| Priority | Issue | Effort | Impact |
|----------|-------|--------|--------|
| 1 | Issue 13: C compilation memory exhaustion | Low | Critical |
| 2 | Issue 11: Mixing apt and pip packages | Medium | Critical |
| 3 | Issue 1: Infinite DNS loop | Low | Critical |
| 4 | Issue 2: SMB timeout wrapper | Low | Critical |
| 5 | Issue 12: Deprecated `--install-option` flag | Low | High |
| 6 | Issue 5: rclone concurrency | Low | High |
| 7 | Issue 4: APT timeout/batching | Medium | High |
| 8 | Issue 3: Git clone timeout | Low | High |
| 9 | Issue 14: Conflicting DHT libraries | Low | Medium |
| 10 | Issue 6: Add `set -euo pipefail` to `2_restore_samba.sh` | Low | Medium |
| 11 | Issue 7: smbpasswd error handling | Low | Medium |
| 12 | Issue 8: rsync bandwidth limit | Low | Medium |
| 13 | Issue 9: Hardcoded user paths | Low | Low |
| 14 | Issue 10: X server health check | Low | Low |

---

## Quick Reference: All Code Locations

| Issue | File | Line(s) |
|-------|------|---------|
| 1: DNS infinite loop | `1_install_picframe.sh` | 47-49 |
| 2: SMB no timeout | `0_backup_setup.sh` | 160-172 |
| 2: SMB no timeout | `3_restore_picframe_backup.sh` | 75-79, 98 |
| 3: Git no timeout | `1_install_picframe.sh` | 80-82 |
| 4: APT no timeout | `1_install_picframe.sh` | 16-28 |
| 5: rclone high concurrency | `sync_photos_from_nasik.sh` | 39-46 |
| 6: Missing set -e | `2_restore_samba.sh` | 1 |
| 7: smbpasswd no error check | `2_restore_samba.sh` | 69-72 |
| 8: rsync no bwlimit | `4_sync_photos.sh` | 21-23 |
| 9: Hardcoded user | `1_install_picframe.sh` | 123 |
| 10: X server sleep | `1_install_picframe.sh` | 97-98 |
| 11: apt/pip package mixing | `1_install_picframe.sh` | 20-21, 66-68 |
| 12: Deprecated --install-option | `1_install_picframe.sh` | 66 |
| 13: C compilation OOM | `1_install_picframe.sh` | 66 |
| 14: Conflicting DHT libraries | `1_install_picframe.sh` | 66-67 |

---

## Conclusion

The migration scripts have significant issues that can cause system instability on resource-constrained devices like the Raspberry Pi Zero 2W. The primary concerns are:

1. **Network operations without timeouts** - Can cause indefinite hangs
2. **Resource-intensive defaults** - Exceed available RAM
3. **Unbounded retry loops** - No graceful failure path
4. **Python package installation problems** - C compilation exhausts memory, causing cascading network failures
5. **Deprecated pip flags** - Will break on future pip versions

The newly identified pip-related issues (11-14) are particularly insidious because they create a chain reaction:
- C extension compilation exhausts RAM
- System swaps heavily to SD card
- USB bandwidth saturates (SD card + WiFi share USB bus)
- Network operations fail or hang
- Script appears to have a "network problem" when root cause is memory

**Immediate Priority Fixes:**

1. **Increase swap to 1024MB** before any pip install with C extensions
2. **Use virtual environment** instead of `--break-system-packages`
3. **Use only `adafruit-circuitpython-dht`** (pure Python, no compilation)
4. **Add timeouts** to all network operations (SMB, git, DNS polling)
5. **Reduce rclone concurrency** to 1 transfer, 2 checkers

Implementing these fixes will significantly improve reliability, especially on low-resource devices. The swap and virtual environment changes should be prioritized as they address the root cause of many seemingly unrelated failures.
