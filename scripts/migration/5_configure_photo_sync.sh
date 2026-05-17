#!/bin/bash
set -e

# === ARGUMENT: INSTANCE NAME (e.g., home, batanovs, cherednychoks) ===
INSTANCE="$1"
if [[ -z "$INSTANCE" ]]; then
  echo "❌ Usage: $0 <instance>"
  echo "   Example: $0 home"
  echo "   Example: $0 batanovs"
  echo "   Example: $0 cherednychoks"
  exit 1
fi

# === LOAD ENV ===
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! source "$SCRIPT_DIR/env_loader.sh"; then
    exit 1
fi

# === CONSTANTS / PATHS ===
RUN_USER="$PICFRAME_USER"
RUN_HOME="/home/${RUN_USER}"
SCRIPT_PATH="${RUN_HOME}/Documents/Scripts/photo-frame/sync_photos_from_nasik.sh"
RCLONE_CONFIG="${RUN_HOME}/.config/rclone/rclone.conf"

SYSTEMD_TEMPLATE_NAME="photo-sync@.service"
SYSTEMD_TEMPLATE_PATH="/etc/systemd/system/${SYSTEMD_TEMPLATE_NAME}"
SYSTEMD_BASE_NAME="photo-sync.service"                     # convenience unit → defaults to 'home'
SYSTEMD_BASE_PATH="/etc/systemd/system/${SYSTEMD_BASE_NAME}"

# === SMB / rclone remote from env ===
SERVER_IP="$SMB_HOST"
SHARE_NAME="$SMB_PICFRAMES_SHARE"
username="$SMB_CRED_USER"
raw_password="$SMB_CRED_PASS"
remote_name="nasikphotos"

# === OBSCURE PASSWORD ===
obscured_pass="$(rclone obscure "$raw_password")"

# === CREATE / UPDATE RCLONE CONFIG ENTRY ===
mkdir -p "$(dirname "$RCLONE_CONFIG")"

if grep -q "^\[$remote_name\]" "$RCLONE_CONFIG" 2>/dev/null; then
  echo "🔁 Updating existing rclone config for [$remote_name]"
  sed -i "/^\[$remote_name\]/,/^$/d" "$RCLONE_CONFIG"
else
  echo "🆕 Creating rclone config for [$remote_name]"
fi

cat >> "$RCLONE_CONFIG" <<EOF

[$remote_name]
type = smb
server = $SERVER_IP
host = $SERVER_IP
share = $SHARE_NAME
username = $username
user = $username
pass = $obscured_pass
EOF

chmod 600 "$RCLONE_CONFIG"
chown "$RUN_USER":"$RUN_USER" "$RCLONE_CONFIG" || true
echo "✅ rclone config updated for [$remote_name] at $RCLONE_CONFIG"

# === CREATE SYSTEMD TEMPLATE SERVICE (photo-sync@.service) ===
echo "🛠️ Writing $SYSTEMD_TEMPLATE_PATH"
sudo tee "$SYSTEMD_TEMPLATE_PATH" > /dev/null <<EOF
[Unit]
Description=Sync and Resize Photos (%i)
After=network-online.target

[Service]
Type=oneshot
User=${RUN_USER}
Environment="HOME=${RUN_HOME}"
Environment="RCLONE_CONFIG=${RCLONE_CONFIG}"
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/bin"
WorkingDirectory=${RUN_HOME}
ExecStart=${SCRIPT_PATH} %i

[Install]
WantedBy=multi-user.target
EOF

# === CREATE CONVENIENCE NON-TEMPLATE (photo-sync.service → defaults to 'home') ===
echo "🛠️ Writing $SYSTEMD_BASE_PATH (defaults to 'home')"
sudo tee "$SYSTEMD_BASE_PATH" > /dev/null <<EOF
[Unit]
Description=Sync and Resize Photos (default: home)
After=network-online.target

[Service]
Type=oneshot
User=${RUN_USER}
Environment="HOME=${RUN_HOME}"
Environment="RCLONE_CONFIG=${RCLONE_CONFIG}"
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/bin"
WorkingDirectory=${RUN_HOME}
ExecStart=${SCRIPT_PATH} home

[Install]
WantedBy=multi-user.target
EOF

echo "✅ Systemd units created:"
echo "   - $SYSTEMD_TEMPLATE_PATH"
echo "   - $SYSTEMD_BASE_PATH"

# === RELOAD SYSTEMD ===
echo "🔄 Reloading systemd..."
sudo systemctl daemon-reload

# === ALLOW PASSWORDLESS `sudo systemctl start photo-sync@*` FOR CRON ===
# Without this, the cron line below silently fails because `sudo` cannot
# prompt for a password in a non-interactive cron context.
SUDOERS_FILE="/etc/sudoers.d/photo-sync"
echo "🔐 Writing $SUDOERS_FILE (NOPASSWD for photo-sync@*)"
SUDOERS_TMP="$(mktemp)"
cat > "$SUDOERS_TMP" <<EOF
# /etc/sudoers.d/photo-sync
# Allows photo-sync@<instance>.service to be started from cron without a
# password. Written by 5_configure_photo_sync.sh.
${RUN_USER} ALL=(root) NOPASSWD: /bin/systemctl start photo-sync@*, /bin/systemctl start photo-sync.service, /bin/systemctl start photo-sync
EOF
if sudo visudo -cf "$SUDOERS_TMP" >/dev/null; then
  if sudo -n -l -U "$RUN_USER" 2>/dev/null | grep -qE '\(ALL\)\s*NOPASSWD:\s*ALL'; then
    echo "ℹ️  Note: $RUN_USER already has broad 'NOPASSWD: ALL' (likely from RPi Imager / cloud-init)."
    echo "    The targeted rule below is redundant on this frame, but installing it anyway"
    echo "    as a safety net for the day you tighten the broad rule."
  fi
  sudo install -m 0440 -o root -g root "$SUDOERS_TMP" "$SUDOERS_FILE"
  echo "✅ Installed $SUDOERS_FILE"
else
  echo "❌ sudoers syntax check failed; aborting"
  rm -f "$SUDOERS_TMP"
  exit 1
fi
rm -f "$SUDOERS_TMP"

echo
echo "▶️ Run manually:"
echo "  sudo systemctl start photo-sync@${INSTANCE}"
echo
echo "▶️ Convenience (defaults to 'home'):"
echo "  sudo systemctl start photo-sync"
echo "  sudo systemctl status photo-sync"

# === ADD/ENSURE CRON JOB FOR THIS INSTANCE (00:00 daily) ===
# `sudo` is required because the user crontab runs as $RUN_USER, and starting
# a system unit needs root. NOPASSWD is granted by /etc/sudoers.d/photo-sync above.
CRON_CMD="0 0 * * * sudo /bin/systemctl start photo-sync@${INSTANCE}"

# Use user's crontab; elevate if needed
if [[ "$(id -un)" == "$RUN_USER" ]]; then
  CRON_READ_CMD=(crontab -l)
  CRON_WRITE_CMD=(crontab -)
else
  CRON_READ_CMD=(sudo crontab -l -u "$RUN_USER")
  CRON_WRITE_CMD=(sudo crontab -u "$RUN_USER" -)
fi

if "${CRON_READ_CMD[@]}" 2>/dev/null | grep -Fqx "$CRON_CMD"; then
  echo "⏰ Cron job already exists for ${RUN_USER}: \"$CRON_CMD\""
else
  echo "⏰ Adding cron job for ${RUN_USER}: \"$CRON_CMD\""
  ( "${CRON_READ_CMD[@]}" 2>/dev/null || true; echo "$CRON_CMD" ) | "${CRON_WRITE_CMD[@]}"
fi

echo
echo "✅ Cron configured for instance '${INSTANCE}' at 00:00 daily."
echo "🕒 Current crontab for $RUN_USER:"
"${CRON_READ_CMD[@]}" || true

# === OPTIONAL: RUN NOW? ===
echo
read -r -p "🚀 Do you want to run the sync now for '${INSTANCE}'? [y/N]: " RUN_NOW
if [[ "$RUN_NOW" =~ ^[Yy]$ ]]; then
  echo "▶️ Starting: sudo systemctl start photo-sync@${INSTANCE}"
  sudo systemctl start "photo-sync@${INSTANCE}"
  echo "ℹ️ Check status with: sudo systemctl status photo-sync@${INSTANCE}"
else
  echo "👌 Okay, not running now. You're all set."
fi

echo
echo -e "\n=== ✅ PHOTO SYNC CONFIGURATION COMPLETE ===\n"
echo "🚀 Next steps:"
echo "1️⃣ 🧹 Remove old Google Photos cron job:"
echo "    crontab -e"
echo "    ❌ Delete line:"
echo "    0 1 * * * /home/ivan.cherednychok/Documents/Scripts/PhotoFrame/sync_and_resize_photos.sh >> /home/ivan.cherednychok/picframe/picframe_data/cron_log.txt 2>&1"
echo
echo "2️⃣ ✅ Daily-sync cron entry already added (00:00) — verify with:"
echo "    crontab -l | grep photo-sync"
echo
echo "3️⃣ 📌 Run a manual sync if needed:"
echo "    sudo systemctl start photo-sync@${INSTANCE}"
echo
echo "4️⃣ 📂 Check synced photos in:"
echo "    ls ~/Pictures/PhotoFrame"