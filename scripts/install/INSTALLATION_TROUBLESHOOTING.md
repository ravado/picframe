# PicFrame Installation Troubleshooting

## Quick Diagnostics

### Check Installation Progress
```bash
cat ~/install_progress.txt
```
Should show `9` when fully complete.

### Check Installation Log
```bash
less ~/install_log.txt
# Or search for errors:
grep -i "error\|failed" ~/install_log.txt
```

### Verify Config Exists
```bash
ls -la ~/picframe_data/config/configuration.yaml
```

### Test PicFrame Binary
```bash
~/venv_picframe/bin/picframe --version
```

## Common Issues

### Issue 1: Config File Missing

**Symptom**: `FileNotFoundError: configuration.yaml`

**Fix**:
```bash
# Manual initialization
cd ~
~/venv_picframe/bin/picframe -i ~/
# Press Enter 3 times to accept defaults

# If that fails, copy from template:
mkdir -p ~/picframe_data/config
cp ~/picframe/src/picframe/data/configuration.yaml ~/picframe_data/config/
```

### Issue 2: Installation Stuck at Step X

**Check current step**:
```bash
cat ~/install_progress.txt
```

**Resume from current step**:
```bash
sudo ./2_install_picframe.sh <username>
```

The script automatically resumes from the last completed step.

### Issue 3: Virtual Environment Broken

**Symptom**: `command not found: picframe`

**Fix**:
```bash
# Recreate venv
rm -rf ~/venv_picframe
python3 -m venv ~/venv_picframe

# Reinstall all dependencies
cd ~/picframe
~/venv_picframe/bin/pip install --upgrade pip
~/venv_picframe/bin/pip install paho-mqtt

# Install hardware sensor libraries
~/venv_picframe/bin/pip install gpiod adafruit-blinka adafruit-platformdetect
~/venv_picframe/bin/pip install adafruit-circuitpython-bme280 adafruit-circuitpython-dht
~/venv_picframe/bin/pip install adafruit-circuitpython-bme680 adafruit-circuitpython-ahtx0

# Install picframe in developer mode
~/venv_picframe/bin/pip install -e .
```

### Issue 4: Sensor Import Errors

**Symptom**: `ModuleNotFoundError: No module named 'adafruit_dht'` or similar

**Fix**:
```bash
# Install missing sensor packages
~/venv_picframe/bin/pip install gpiod adafruit-blinka adafruit-platformdetect
~/venv_picframe/bin/pip install adafruit-circuitpython-bme280 adafruit-circuitpython-dht
~/venv_picframe/bin/pip install adafruit-circuitpython-bme680 adafruit-circuitpython-ahtx0

# Verify imports work
~/venv_picframe/bin/python3 -c "import board; import adafruit_dht; print('✅ Sensor packages OK')"
```

### Issue 5: Permission Errors

**Fix**:
```bash
# Fix ownership
sudo chown -R $USER:$USER ~/picframe ~/picframe_data ~/venv_picframe

# Fix permissions
chmod -R u+rwX ~/picframe ~/picframe_data ~/venv_picframe
```

## Manual Verification Steps

After installation, verify everything works:

```bash
# 1. Check picframe binary
~/venv_picframe/bin/picframe --version

# 2. Verify config file
cat ~/picframe_data/config/configuration.yaml

# 3. Check directories
ls -la ~/Pictures ~/DeletedPictures ~/picframe_data

# 4. Test systemd service
systemctl --user status picframe

# 5. Try running picframe manually (Ctrl+C to stop)
~/venv_picframe/bin/picframe
```

## Reset and Start Over

If all else fails:

```bash
# Clean up
rm -rf ~/picframe ~/picframe_data ~/venv_picframe ~/Pictures ~/DeletedPictures
rm ~/install_progress.txt ~/install_log.txt
sudo systemctl disable install_script_service 2>/dev/null
sudo rm /etc/systemd/system/install_script_service.service 2>/dev/null

# Start fresh
sudo ./2_install_picframe.sh <username>
```
