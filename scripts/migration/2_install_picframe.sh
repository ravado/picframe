#!/bin/bash

# PicFrame Developer Mode Installation Script
# Installs picframe fork (https://github.com/ravado/picframe) in developer mode
# Based on community_installation.sh with modifications for development workflow
#
# Prerequisites: Run 1_install_packages.sh before this script

# Configuration variables
INSTALL_USER="ivan"
REPO_URL="https://github.com/ravado/picframe.git"
REPO_BRANCH="develop"
VENV_PATH="/home/$INSTALL_USER/.venv_picframe"
REPO_PATH="/home/$INSTALL_USER/picframe"
DATA_PATH="/home/$INSTALL_USER/picframe_data"

# Path to store progress and log file
PROGRESS_FILE="/home/$INSTALL_USER/install_progress.txt"
LOG_FILE="/home/$INSTALL_USER/install_log.txt"
SERVICE_NAME="install_script_service"

# Function to log messages
log_message() {
    echo "$1" | tee -a "$LOG_FILE"
}

# Function to update progress
update_progress() {
    echo "$1" > "$PROGRESS_FILE"
}

# Function to get the last completed step
get_last_completed_step() {
    if [ -f "$PROGRESS_FILE" ]; then
        cat "$PROGRESS_FILE"
    else
        echo "0"
    fi
}

# Function to add a systemd service to resume the script after reboot
add_systemd_service() {
    local script_path=$(realpath "$0")
    SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME.service"
    sudo tee "$SERVICE_FILE" > /dev/null <<EOL
[Unit]
Description=Resume install script after reboot
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$script_path
Type=oneshot
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
EOL
    sudo systemctl enable $SERVICE_NAME
    log_message "Added systemd service for reboot resume."
}

# Function to remove the systemd service after completion
remove_systemd_service() {
    sudo systemctl disable $SERVICE_NAME
    sudo rm /etc/systemd/system/$SERVICE_NAME.service
    log_message "Removed systemd service after completion."
}

# Function to reboot and resume
reboot_and_resume() {
    add_systemd_service
    update_progress "$1"
    log_message "Rebooting to complete the installation. The script will continue after reboot."
    sudo reboot
    exit 0
}

# Function to check for a working internet connection
check_internet_connection() {
  local max_retries=60
  local attempt=0

  log_message "Checking for an active internet connection..."
  while ! ping -c 1 -W 3 1.1.1.1 &> /dev/null; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge "$max_retries" ]; then
      log_message "❌ ERROR: No internet connection after $max_retries attempts (~5 minutes). Aborting."
      exit 1
    fi
    log_message "No internet connection (attempt $attempt/$max_retries). Retrying in 5 seconds..."
    sleep 5
  done
  log_message "IP connectivity confirmed."

  log_message "Checking DNS resolution..."
  attempt=0
  while ! ping -c 1 -W 3 google.com &> /dev/null; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge "$max_retries" ]; then
      log_message "❌ ERROR: DNS resolution failed after $max_retries attempts. Check /etc/resolv.conf. Aborting."
      exit 1
    fi
    log_message "DNS not resolving (attempt $attempt/$max_retries). Retrying in 5 seconds..."
    sleep 5
  done
  log_message "Internet connection and DNS confirmed."
}

# Ensure the user has passwordless sudo for specific commands
sudoers_entry="$INSTALL_USER ALL=(ALL) NOPASSWD: $VENV_PATH/bin/picframe, $VENV_PATH/bin/pip, /usr/bin/python3, /bin/mkdir"

# Check if the entry already exists in the sudoers file to avoid duplication
if ! sudo grep -qF "$sudoers_entry" /etc/sudoers; then
    echo "$sudoers_entry" | sudo tee -a /etc/sudoers > /dev/null
    echo "Configured passwordless sudo for the '$INSTALL_USER' user."
else
    echo "Passwordless sudo for '$INSTALL_USER' user is already configured."
fi

# Main install script

# Get the last completed step
LAST_COMPLETED_STEP=$(get_last_completed_step)

# Step 0: Pre-flight system checks
if [ "$LAST_COMPLETED_STEP" -lt 0 ]; then
    log_message "Step 0: Running pre-flight checks..."

    # Check if running as root
    if [ "$EUID" -eq 0 ]; then
        log_message "❌ ERROR: Do not run this script as root (use regular user with sudo access)"
        exit 1
    fi

    # Check if target user exists
    if ! id "$INSTALL_USER" &>/dev/null; then
        log_message "❌ ERROR: User '$INSTALL_USER' does not exist on this system"
        log_message "   Create the user first with: sudo adduser $INSTALL_USER"
        exit 1
    fi

    # Check if current user has sudo access
    if ! sudo -n true 2>/dev/null; then
        log_message "⚠️  WARNING: Current user may need to enter sudo password during installation"
    fi

    # Check available disk space (need at least 2GB)
    available_space=$(df /home | tail -1 | awk '{print $4}')
    if [ "$available_space" -lt 2000000 ]; then
        log_message "❌ ERROR: Insufficient disk space (need at least 2GB free in /home)"
        exit 1
    fi

    # Check available memory (warn if less than 512MB)
    available_mem=$(free -m | awk '/^Mem:/{print $2}')
    if [ "$available_mem" -lt 512 ]; then
        log_message "⚠️  WARNING: Low memory detected (${available_mem}MB). Installation may be slow."
        log_message "   Consider increasing swap size: sudo dphys-swapfile swapoff && sudo sed -i 's/CONF_SWAPSIZE=.*/CONF_SWAPSIZE=1024/' /etc/dphys-swapfile && sudo dphys-swapfile setup && sudo dphys-swapfile swapon"
    fi

    # Check internet connectivity
    check_internet_connection

    log_message "✅ Pre-flight checks passed"
    update_progress 0
fi

# Step 1: Update the operating system...
if [ "$LAST_COMPLETED_STEP" -lt 1 ]; then
    check_internet_connection
    log_message "Step 1: Updating operating system..."
    sudo apt-get update && sudo apt upgrade -y
    reboot_and_resume 1
fi

# Step 2: Update raspi-config to boot in console as user...
if [ "$LAST_COMPLETED_STEP" -lt 2 ]; then
    log_message "Step 2: Updating raspi-config..."
    sudo raspi-config nonint do_boot_behaviour B2
    reboot_and_resume 2
fi

# Step 3: Installing picframe in developer mode
if [ "$LAST_COMPLETED_STEP" -lt 3 ]; then
    check_internet_connection
    log_message "Step 3: Installing picframe in developer mode..."

    # Create photo directories
    su - $INSTALL_USER -c "mkdir -p /home/$INSTALL_USER/Pictures/PhotoFrame /home/$INSTALL_USER/Pictures/PhotoFrameDeleted"
    log_message "Directories 'Pictures/PhotoFrame' and 'Pictures/PhotoFrameDeleted' created."

    # Clone the repository
    log_message "Cloning picframe repository from $REPO_URL..."
    if [ ! -d "$REPO_PATH" ]; then
        if ! su - $INSTALL_USER -c "git clone $REPO_URL $REPO_PATH" 2>&1 | tee -a "$LOG_FILE"; then
            log_message "❌ ERROR: Failed to clone repository"
            exit 1
        fi
    else
        log_message "Repository already exists at $REPO_PATH"
    fi

    # Checkout develop branch
    log_message "Checking out $REPO_BRANCH branch..."
    if ! su - $INSTALL_USER -c "cd $REPO_PATH && git checkout $REPO_BRANCH" 2>&1 | tee -a "$LOG_FILE"; then
        log_message "❌ ERROR: Failed to checkout $REPO_BRANCH branch"
        exit 1
    fi

    # Create virtual environment
    log_message "Creating virtual environment for picframe..."
    if ! su - $INSTALL_USER -c "python3 -m venv $VENV_PATH" 2>&1 | tee -a "$LOG_FILE"; then
        log_message "❌ ERROR: Failed to create virtual environment"
        exit 1
    fi

    # Upgrade pip first
    log_message "Upgrading pip in virtual environment..."
    if ! su - $INSTALL_USER -c "$VENV_PATH/bin/pip install --upgrade pip" 2>&1 | tee -a "$LOG_FILE"; then
        log_message "⚠️  WARNING: Failed to upgrade pip (continuing anyway)"
    fi

    # Install paho-mqtt
    log_message "Installing paho-mqtt..."
    if ! su - $INSTALL_USER -c "$VENV_PATH/bin/pip install paho-mqtt" 2>&1 | tee -a "$LOG_FILE"; then
        log_message "❌ ERROR: Failed to install paho-mqtt"
        exit 1
    fi

    # Install hardware sensor dependencies (Adafruit CircuitPython libraries)
    # NOTE: Using CircuitPython versions to avoid C compilation that can OOM on Pi Zero 2W
    log_message "Installing hardware sensor libraries..."
    SENSOR_PACKAGES=(
        "gpiod"
        "adafruit-blinka"
        "adafruit-platformdetect"
        "adafruit-circuitpython-bme280"
        "adafruit-circuitpython-dht"
        "adafruit-circuitpython-bme680"
        "adafruit-circuitpython-ahtx0"
    )

    for package in "${SENSOR_PACKAGES[@]}"; do
        log_message "Installing $package..."
        if ! su - $INSTALL_USER -c "$VENV_PATH/bin/pip install $package" 2>&1 | tee -a "$LOG_FILE"; then
            log_message "⚠️  WARNING: Failed to install $package (continuing anyway)"
            log_message "   Sensor functionality may be limited"
        else
            log_message "✅ $package installed successfully"
        fi
    done

    # Install picframe in developer/editable mode
    log_message "Installing picframe in developer/editable mode..."
    if ! su - $INSTALL_USER -c "cd $REPO_PATH && $VENV_PATH/bin/pip install -e ." 2>&1 | tee -a "$LOG_FILE"; then
        log_message "❌ ERROR: Failed to install picframe"
        exit 1
    fi

    # Verify picframe was installed
    if ! su - $INSTALL_USER -c "$VENV_PATH/bin/picframe --version" &>/dev/null; then
        log_message "⚠️  WARNING: picframe command not found after installation"
    else
        PICFRAME_VERSION=$(su - $INSTALL_USER -c "$VENV_PATH/bin/picframe --version" 2>&1 || echo "unknown")
        log_message "✅ picframe installed successfully (version: $PICFRAME_VERSION)"
    fi

    # Initialize Picframe and confirm default directories
    log_message "Initializing Picframe with default directories..."

    # Create a temporary expect script to handle initialization prompts
    INIT_SCRIPT="/tmp/picframe_init_$$.exp"
    cat > "$INIT_SCRIPT" <<'EOF'
#!/usr/bin/expect -f
set timeout 30
set venv_path [lindex $argv 0]
set install_user [lindex $argv 1]

spawn su - $install_user -c "$venv_path/bin/picframe -i /home/$install_user/"
expect {
    "picture directory*" { send "\r"; exp_continue }
    "Deleted picture directory*" { send "\r"; exp_continue }
    "Enter locale*" { send "\r"; exp_continue }
    "Configuration file*" { send "\r"; exp_continue }
    eof
}

# Capture exit code
catch wait result
exit [lindex $result 3]
EOF
    chmod +x "$INIT_SCRIPT"

    # Run initialization with expect for better control
    INIT_EXIT_CODE=0
    if expect "$INIT_SCRIPT" "$VENV_PATH" "$INSTALL_USER" 2>&1 | tee -a "$LOG_FILE"; then
        log_message "Picframe initialization command completed successfully"
    else
        INIT_EXIT_CODE=$?
        log_message "⚠️  WARNING: Picframe initialization returned exit code $INIT_EXIT_CODE"
    fi

    rm -f "$INIT_SCRIPT"

    # CRITICAL: Verify configuration file was actually created
    CONFIG_FILE="$DATA_PATH/config/configuration.yaml"
    if [ ! -f "$CONFIG_FILE" ]; then
        log_message "❌ ERROR: Configuration file not created at $CONFIG_FILE"
        log_message "   Attempting manual setup from template..."

        # Create all required directories
        su - $INSTALL_USER -c "mkdir -p $DATA_PATH/config"
        su - $INSTALL_USER -c "mkdir -p $DATA_PATH/data"
        su - $INSTALL_USER -c "mkdir -p $DATA_PATH/html"
        su - $INSTALL_USER -c "mkdir -p /home/$INSTALL_USER/Pictures/PhotoFrame"
        su - $INSTALL_USER -c "mkdir -p /home/$INSTALL_USER/Pictures/PhotoFrameDeleted"
        log_message "✅ Created directory structure"

        # Copy data directory (fonts, shaders, etc.)
        if [ -d "$REPO_PATH/src/picframe/data" ]; then
            su - $INSTALL_USER -c "cp -r $REPO_PATH/src/picframe/data/* $DATA_PATH/data/"
            log_message "✅ Copied data directory (fonts, shaders)"
        else
            log_message "⚠️  WARNING: Data directory not found at $REPO_PATH/src/picframe/data"
        fi

        # Copy html directory (web UI)
        if [ -d "$REPO_PATH/src/picframe/html" ]; then
            su - $INSTALL_USER -c "cp -r $REPO_PATH/src/picframe/html/* $DATA_PATH/html/"
            log_message "✅ Copied html directory (web UI)"
        else
            log_message "⚠️  WARNING: HTML directory not found at $REPO_PATH/src/picframe/html"
        fi

        # Copy configuration template
        if [ -f "$REPO_PATH/src/picframe/config/configuration_example.yaml" ]; then
            su - $INSTALL_USER -c "cp $REPO_PATH/src/picframe/config/configuration_example.yaml $CONFIG_FILE"
            log_message "✅ Copied configuration template"

            # Update paths in configuration to match installation
            su - $INSTALL_USER -c "sed -i 's|~/Pictures|/home/$INSTALL_USER/Pictures/PhotoFrame|g' $CONFIG_FILE"
            su - $INSTALL_USER -c "sed -i 's|~/DeletedPictures|/home/$INSTALL_USER/Pictures/PhotoFrameDeleted|g' $CONFIG_FILE"
            su - $INSTALL_USER -c "sed -i 's|~/picframe_data|$DATA_PATH|g' $CONFIG_FILE"
            log_message "✅ Updated configuration paths for user $INSTALL_USER"
        else
            log_message "❌ FATAL: Cannot find configuration template at $REPO_PATH/src/picframe/config/configuration_example.yaml"
            log_message "   Installation cannot continue - picframe will not run without config"
            exit 1
        fi
    else
        log_message "✅ Configuration file verified at $CONFIG_FILE"
    fi

    # Verify all required paths exist
    log_message "Verifying installation integrity..."
    REQUIRED_PATHS=(
        "$CONFIG_FILE"
        "$DATA_PATH/config"
        "$DATA_PATH/data"
        "$DATA_PATH/html"
        "/home/$INSTALL_USER/Pictures/PhotoFrame"
        "/home/$INSTALL_USER/Pictures/PhotoFrameDeleted"
    )

    VERIFICATION_FAILED=0
    for path in "${REQUIRED_PATHS[@]}"; do
        if [ ! -e "$path" ]; then
            log_message "❌ ERROR: Required path missing: $path"
            VERIFICATION_FAILED=1
        fi
    done

    if [ $VERIFICATION_FAILED -eq 1 ]; then
        log_message "❌ FATAL: Installation verification failed - required paths missing"
        log_message "   Manual intervention required"
        exit 1
    fi

    log_message "✅ All required paths verified"
    log_message "✅ Step 3 completed successfully"
    update_progress 3
fi

# Step 4: Configure Mosquitto for anonymous access and open listener
if [ "$LAST_COMPLETED_STEP" -lt 4 ]; then
    log_message "Step 4: Configuring Mosquitto for anonymous access and listener..."

    # Edit the Mosquitto configuration file
    log_message "Editing /etc/mosquitto/mosquitto.conf to allow anonymous access and open listener..."
    echo "allow_anonymous true" | sudo tee -a /etc/mosquitto/mosquitto.conf > /dev/null
    echo "listener 1883 0.0.0.0" | sudo tee -a /etc/mosquitto/mosquitto.conf > /dev/null

    # Restart the Mosquitto service to apply changes
    sudo systemctl restart mosquitto
    log_message "Mosquitto configuration updated and service restarted."

    # Mark step as completed
    update_progress 4
    log_message "Mosquitto configuration completed."
fi

# Step 5: Create autostart script for Picframe
if [ "$LAST_COMPLETED_STEP" -lt 5 ]; then
    log_message "Step 5: Creating autostart script for Picframe as user '$INSTALL_USER'..."

    # Create autostart script for Picframe
    AUTOSTART_SCRIPT="/home/$INSTALL_USER/start_picframe.sh"
    su - $INSTALL_USER -c "cat > $AUTOSTART_SCRIPT" <<EOL
#!/bin/bash
source $VENV_PATH/bin/activate  # Activate Python virtual environment
picframe &  # Start Picframe in the background
EOL

    # Make the autostart script executable
    su - $INSTALL_USER -c "chmod +x $AUTOSTART_SCRIPT"
    log_message "Autostart script created and made executable: $AUTOSTART_SCRIPT."

    # Mark step as completed
    update_progress 5
    log_message "Directory setup and autostart script creation completed."
fi

# Step 6: Configure autostart for Picframe using labwc and set up systemd service
if [ "$LAST_COMPLETED_STEP" -lt 6 ]; then
    log_message "Step 6: Configuring autostart for Picframe with labwc and setting up systemd service as user '$INSTALL_USER'..."

    # Create labwc autostart directory and configuration file
    su - $INSTALL_USER -c "mkdir -p /home/$INSTALL_USER/.config/labwc"
    AUTOSTART_FILE="/home/$INSTALL_USER/.config/labwc/autostart"
    su - $INSTALL_USER -c "cat > $AUTOSTART_FILE" <<EOL
/home/$INSTALL_USER/start_picframe.sh
EOL
    log_message "Created labwc autostart configuration: $AUTOSTART_FILE"

    # Create labwc rc.xml for window decorations
    RC_XML_FILE="/home/$INSTALL_USER/.config/labwc/rc.xml"
    su - $INSTALL_USER -c "cat > $RC_XML_FILE" <<'EOL'
<windowRules>
    <windowRule identifier="*" serverDecoration="no" />
</windowRules>
EOL
    log_message "Created labwc rc.xml configuration for window decoration: $RC_XML_FILE"

    # Create systemd user service to start labwc on boot
    su - $INSTALL_USER -c "mkdir -p /home/$INSTALL_USER/.config/systemd/user"
    SYSTEMD_SERVICE_FILE="/home/$INSTALL_USER/.config/systemd/user/picframe.service"
    su - $INSTALL_USER -c "cat > $SYSTEMD_SERVICE_FILE" <<'EOL'
[Unit]
Description=PictureFrame on Pi

[Service]
ExecStart=/usr/bin/labwc
Restart=always

[Install]
WantedBy=default.target
EOL
    log_message "Created systemd service for Picframe: $SYSTEMD_SERVICE_FILE"

    # Enable the user systemd service for autostart
    su - $INSTALL_USER -c "systemctl --user enable picframe.service"
    log_message "Enabled systemd user service for Picframe autostart."

    # Mark step as completed and reboot to apply changes
    log_message "Autostart configuration for Picframe completed. Rebooting to apply changes."
    reboot_and_resume 6
fi

# Step 7: Post-installation verification
if [ "$LAST_COMPLETED_STEP" -ge 6 ] && [ "$LAST_COMPLETED_STEP" -lt 7 ]; then
    log_message "Step 7: Running post-installation verification..."

    # Verify picframe binary exists and is executable
    if [ ! -x "$VENV_PATH/bin/picframe" ]; then
        log_message "❌ ERROR: picframe binary not found or not executable"
        exit 1
    fi

    # Verify configuration file exists
    CONFIG_FILE="$DATA_PATH/config/configuration.yaml"
    if [ ! -f "$CONFIG_FILE" ]; then
        log_message "❌ ERROR: Configuration file missing at $CONFIG_FILE"
        exit 1
    fi

    # Verify systemd service exists
    SYSTEMD_SERVICE_FILE="/home/$INSTALL_USER/.config/systemd/user/picframe.service"
    if [ ! -f "$SYSTEMD_SERVICE_FILE" ]; then
        log_message "❌ ERROR: Systemd service file missing"
        exit 1
    fi

    # Verify directories exist and are writable
    for dir in "/home/$INSTALL_USER/Pictures/PhotoFrame" "/home/$INSTALL_USER/Pictures/PhotoFrameDeleted" "$DATA_PATH"; do
        if [ ! -d "$dir" ]; then
            log_message "❌ ERROR: Required directory missing: $dir"
            exit 1
        fi
        if [ ! -w "$dir" ]; then
            log_message "❌ ERROR: Directory not writable: $dir"
            exit 1
        fi
    done

    # Test picframe config validation (don't actually start it)
    log_message "Testing picframe configuration..."
    if su - $INSTALL_USER -c "$VENV_PATH/bin/python3 -c 'import yaml; yaml.safe_load(open(\"$CONFIG_FILE\"))'" 2>&1 | tee -a "$LOG_FILE"; then
        log_message "✅ Configuration file is valid YAML"
    else
        log_message "⚠️  WARNING: Configuration file may have YAML syntax errors"
    fi

    # Verify critical Python packages are importable
    log_message "Verifying Python package installations..."
    CRITICAL_PACKAGES=("picframe" "paho.mqtt.client" "yaml")
    SENSOR_PACKAGES=("board" "adafruit_dht" "adafruit_bme280" "adafruit_bme680" "adafruit_ahtx0")

    for package in "${CRITICAL_PACKAGES[@]}"; do
        package_import=$(echo "$package" | sed 's/\..*//') # Get first part for import
        if su - $INSTALL_USER -c "$VENV_PATH/bin/python3 -c 'import $package_import'" 2>/dev/null; then
            log_message "✅ $package is importable"
        else
            log_message "❌ ERROR: $package cannot be imported"
            exit 1
        fi
    done

    # Sensor packages are optional (warn but don't fail)
    for package in "${SENSOR_PACKAGES[@]}"; do
        if su - $INSTALL_USER -c "$VENV_PATH/bin/python3 -c 'import $package'" 2>/dev/null; then
            log_message "✅ $package is importable"
        else
            log_message "⚠️  WARNING: $package cannot be imported (sensor features may not work)"
        fi
    done

    log_message "✅ Post-installation verification completed"
    log_message ""
    log_message "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_message "📦 Installation Summary:"
    log_message "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_message "User:              $INSTALL_USER"
    log_message "Virtual Env:       $VENV_PATH"
    log_message "Repository:        $REPO_PATH (branch: $REPO_BRANCH)"
    log_message "Data Directory:    $DATA_PATH"
    log_message "Config File:       $CONFIG_FILE"
    log_message "Pictures:          /home/$INSTALL_USER/Pictures/PhotoFrame"
    log_message "Deleted Pictures:  /home/$INSTALL_USER/Pictures/PhotoFrameDeleted"
    log_message "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_message ""
    log_message "✅ All checks passed! PicFrame is ready to use."
    log_message ""
    log_message "Next steps:"
    log_message "1. Add photos to /home/$INSTALL_USER/Pictures/PhotoFrame/"
    log_message "2. Edit config: nano $CONFIG_FILE"
    log_message "3. Start picframe: systemctl --user start picframe"
    log_message "4. Check status: systemctl --user status picframe"
    log_message ""

    update_progress 7
fi

# Final step: Remove the systemd service only if all steps are completed
if [ "$LAST_COMPLETED_STEP" -ge 7 ]; then
    remove_systemd_service
    log_message "Installation complete! System will reboot in 10 seconds..."
    sleep 10
    sudo reboot
fi
