#!/bin/bash
set -euo pipefail

# System package installation for PicFrame on Raspberry Pi
# Run this script before 1_install_picframe_developer_mode.sh

# Function to check for a working internet connection
check_internet_connection() {
    local max_retries=60
    local attempt=0

    echo "🌐 Checking for an active internet connection..."
    while ! ping -c 1 -W 3 1.1.1.1 &> /dev/null; do
        attempt=$((attempt + 1))
        if [ "$attempt" -ge "$max_retries" ]; then
            echo "❌ ERROR: No internet connection after $max_retries attempts (~5 minutes). Aborting."
            exit 1
        fi
        echo "⚠️  No internet connection (attempt $attempt/$max_retries). Retrying in 5 seconds..."
        sleep 5
    done
    echo "✅ IP connectivity confirmed."

    echo "🌐 Checking DNS resolution..."
    attempt=0
    while ! ping -c 1 -W 3 google.com &> /dev/null; do
        attempt=$((attempt + 1))
        if [ "$attempt" -ge "$max_retries" ]; then
            echo "❌ ERROR: DNS resolution failed after $max_retries attempts. Check /etc/resolv.conf. Aborting."
            exit 1
        fi
        echo "⚠️  DNS not resolving (attempt $attempt/$max_retries). Retrying in 5 seconds..."
        sleep 5
    done
    echo "✅ Internet connection and DNS confirmed."
}

check_internet_connection

echo "🔄 Updating system packages..."
sudo apt-get update
sudo apt-get upgrade -y

echo "📦 Installing required packages..."
# NOTE on `openresolv`:
#   Pi OS Trixie uses NetworkManager for WiFi/DHCP. We do NOT swap that.
#   `wg-quick` (WireGuard's tunnel helper) calls `/sbin/resolvconf` to push
#   tunnel DNS into the system resolver when bringing wg0 up. That binary is
#   provided by `openresolv` on Trixie (the older `resolvconf` package is gone).
#   Without it, `wg-quick up wg0` fails at the DNS step and the tunnel either
#   won't come up or won't resolve names through it.
sudo apt-get install -y \
    git \
    libsdl2-dev libsdl2-image-2.0-0 libsdl2-mixer-2.0-0 libsdl2-ttf-2.0-0 \
    xwayland labwc wlr-randr \
    vlc ffmpeg imagemagick \
    wireguard rsync smbclient rclone \
    inotify-tools libgpiod3 bc btop \
    locales openresolv \
    mosquitto mosquitto-clients \
    samba

echo "✅ All packages installed successfully."
