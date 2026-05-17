#!/bin/bash
set -euo pipefail

# Load environment variables and validate
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! source "$SCRIPT_DIR/env_loader.sh"; then
    exit 1
fi

echo -e "=== PICFRAME RESTORATION SCRIPT ===\n"

SMB_CRED_FILE="$HOME/.smbcred"
LOCAL_TMP="/tmp/picframe_restore"
PICFRAME_DATA="$HOME/picframe_data"

mkdir -p "$LOCAL_TMP"

###########################
# Parse options
###########################

# Defaults
VERBOSE=0          # --verbose : extra debug/summary output

POSITIONAL=()

# Loop through all args
for arg in "$@"; do
  case "$arg" in
    -v|--verbose)
      # Enable verbose output (extra logging and summary at the end)
      VERBOSE=1
      ;;
    *)
      # Any non-flag is treated as a positional argument
      POSITIONAL+=("$arg")
      ;;
  esac
done

# Put back only the positional args for easy handling
set -- "${POSITIONAL[@]}"

# --- Required arguments ---
# 1: <prefix>        (home / batanovs / cherednychoks)
# 2: <backup file>   (filename.tar.gz OR "latest")
if [ $# -lt 2 ]; then
    echo "❌ Usage: $0 [--verbose] <prefix> <backup_file.tar.gz|latest>"
    echo ""
    echo "Examples:"
    echo "  $0 home latest"
    echo "  $0 --verbose home latest"
    exit 1
fi

PREFIX="$1"
BACKUP_INPUT="$2"
BACKUP_PREFIX="picframe_${PREFIX}_setup_backup_"

###########################
# Fetch from SMB if needed
###########################
if [[ "$BACKUP_INPUT" == "latest" ]]; then
    echo "🔍 Searching SMB ($SMB_BACKUPS_PATH/$SMB_BACKUPS_SUBDIR) for latest backup with prefix: $BACKUP_PREFIX"

    LATEST_FILE=$(smbclient "$SMB_BACKUPS_PATH" -A "$SMB_CRED_FILE" -c "cd $SMB_BACKUPS_SUBDIR; ls" \
                  | awk '{print $1}' \
                  | grep "^${BACKUP_PREFIX}" \
                  | sort -r \
                  | head -n1)

    if [[ -z "$LATEST_FILE" ]]; then
        echo "❌ No backups found for prefix '$PREFIX' on SMB"
        exit 1
    fi

    BACKUP_NAME="$LATEST_FILE"
    echo "✅ Found latest backup on SMB: $BACKUP_NAME"
else
    BACKUP_NAME="$BACKUP_INPUT"
    echo "📦 Using specified backup file: $BACKUP_NAME"
fi

###########################
# Fetch from SMB if not local
###########################
if [ ! -f "$LOCAL_TMP/$BACKUP_NAME" ]; then
    echo "📥 Downloading $BACKUP_NAME from SMB..."
    smbclient "$SMB_BACKUPS_PATH" -A "$SMB_CRED_FILE" -c "cd $SMB_BACKUPS_SUBDIR; lcd $LOCAL_TMP; get $BACKUP_NAME"
    BACKUP_PATH="$LOCAL_TMP/$BACKUP_NAME"
else
    BACKUP_PATH="$LOCAL_TMP/$BACKUP_NAME"
    echo "✅ Using existing local backup: $BACKUP_PATH"
fi

###########################
# Extract backup
###########################
echo "📦 Extracting backup archive..."
sudo tar -xzpf "$BACKUP_PATH" -C "$LOCAL_TMP"

BACKUP_DIR=$(basename "$BACKUP_PATH" .tar.gz)
BACKUP_FULL="$LOCAL_TMP/$BACKUP_DIR"

if [ ! -d "$BACKUP_FULL" ]; then
    echo "❌ Backup directory not found after extraction!"
    exit 1
fi

# Fix ownership of extracted files so current user can read them if needed
sudo chown -R "$USER":"$USER" "$BACKUP_FULL"

echo "🕑 Restoring user crontab..."
if [ -f "$BACKUP_FULL/crontab.txt" ]; then
    crontab "$BACKUP_FULL/crontab.txt"
    echo "✅ Crontab restored from backup"
else
    echo "⚠️ No crontab.txt found in backup, skipping"
fi

echo "🔧 Stripping X11/vcgencmd display commands from crontab (not compatible with Wayland)..."

TMP_CRON_PATCHED="$LOCAL_TMP/patched_crontab.txt"

# Strip lines that use vcgencmd or xset dpms (both are X11/firmware-only, not for Wayland)
STRIPPED_COUNT=$(crontab -l | grep -cE 'vcgencmd|xset dpms' || true)
crontab -l | grep -vE 'vcgencmd|xset dpms' > "$TMP_CRON_PATCHED"

# Reinstall stripped crontab
crontab "$TMP_CRON_PATCHED"
rm "$TMP_CRON_PATCHED"

if [[ "$STRIPPED_COUNT" -gt 0 ]]; then
    echo "⚠️  Removed $STRIPPED_COUNT display on/off cron job(s) that used vcgencmd/xset dpms."
    echo "   These are not compatible with Wayland. Reconfigure display scheduling manually"
    echo "   using wlr-randr or a Wayland-compatible method after setup is complete."
else
    echo "✅ No X11/vcgencmd display entries found in crontab"
fi

###########################
# Restore files
###########################
echo "📂 Creating necessary directories..."
mkdir -p ~/.config ~/Pictures/PhotoFrame ~/Pictures/PhotoFrameDeleted

echo "🖼️ Restoring PicFrame data..."
if [ -d "$BACKUP_FULL/picframe_data" ]; then
    mkdir -p "$PICFRAME_DATA"
    cp -a "$BACKUP_FULL/picframe_data/." "$PICFRAME_DATA/"
    echo "✅ picframe_data merged into $PICFRAME_DATA (existing files overwritten, others kept)"
else
    echo "⚠️ No picframe_data found in backup"
fi

echo ""
echo "⚠️  ─────────────────────────────────────────────────────────────────"
echo "⚠️  MANUAL STEP REQUIRED: configuration.yaml was NOT applied."
echo "⚠️  The backed-up config references old X11 paths and the old user."
echo "⚠️  Review and adapt it before use:"
echo ""
echo "     diff $BACKUP_FULL/picframe_data/config/configuration.yaml \\"
echo "          ~/picframe_data/config/configuration.yaml"
echo ""
echo "     # Then copy when ready:"
echo "     cp $BACKUP_FULL/picframe_data/config/configuration.yaml \\"
echo "        ~/picframe_data/config/configuration.yaml"
echo ""
echo "⚠️  picframe.service was also NOT restored — the installer creates"
echo "⚠️  the correct Wayland/user service. The archived one is X11-only."
echo "⚠️  ─────────────────────────────────────────────────────────────────"
echo ""

echo "🔑 Restoring SSH keys..."
if [ -f "$BACKUP_FULL/ssh/id_ed25519" ]; then
    mkdir -p ~/.ssh
    cp -v "$BACKUP_FULL/ssh/id_ed25519"* ~/.ssh/
    chmod 600 ~/.ssh/id_ed25519
    chmod 644 ~/.ssh/id_ed25519.pub 2>/dev/null || true
fi

echo "🛠️ Restoring git configuration..."
if [ -f "$BACKUP_FULL/git_config/user.name" ]; then
    GIT_NAME=$(cat "$BACKUP_FULL/git_config/user.name")
    git config --global user.name "$GIT_NAME"
    [ $VERBOSE -eq 1 ] && echo "   → git user.name set to $GIT_NAME"
fi
if [ -f "$BACKUP_FULL/git_config/user.email" ]; then
    GIT_EMAIL=$(cat "$BACKUP_FULL/git_config/user.email")
    git config --global user.email "$GIT_EMAIL"
    [ $VERBOSE -eq 1 ] && echo "   → git user.email set to $GIT_EMAIL"
fi

###########################
# Create photo directories
###########################
echo "📁 Ensuring photo directories exist..."
mkdir -p ~/Pictures/PhotoFrame ~/Pictures/PhotoFrameDeleted
echo "✅ Photo directories ~/Pictures/PhotoFrame/ and ~/Pictures/PhotoFrameDeleted/ ready"
ls -lah ~/Pictures

###########################
# Restore WireGuard configs
###########################
echo "🔒 Restoring WireGuard configuration..."
if [ -d "$BACKUP_FULL/wireguard_config" ]; then
    sudo mkdir -p /etc/wireguard
    sudo cp -v "$BACKUP_FULL/wireguard_config/"* /etc/wireguard/
    sudo chmod 600 /etc/wireguard/*.conf /etc/wireguard/privatekey 2>/dev/null || true
    echo "✅ WireGuard configuration restored"
    echo "   → Restart WireGuard after network setup: sudo systemctl restart wg-quick@wg0"
else
    echo "⚠️ No WireGuard configuration found in backup"
fi

###########################
# Verbose details
###########################
if [ $VERBOSE -eq 1 ]; then
    echo ""
    echo "📋 Verbose summary:"
    echo "   Backup used: $BACKUP_PATH"
    echo "   Restored PicFrame config to: ~/picframe_data/"
    echo "   Restored SSH keys to: ~/.ssh/"
    echo "   Restored WireGuard config to: /etc/wireguard/"
    echo "   Restored Samba config to: /etc/samba/"
fi

###########################
# Cleanup
###########################
echo "🧹 Cleaning up temporary files..."
rm -rf "$BACKUP_FULL"

echo -e "\n=== ✅ RESTORATION COMPLETE ===\n"
echo "🚀 Next steps:"
echo "1️⃣  ⚠️  Manually review and apply configuration.yaml (paths + user changed from X11 install)"
echo "      diff <backup>/picframe_data/config/configuration.yaml ~/picframe_data/config/configuration.yaml"
echo "2️⃣  Configure photo sync service: ./5_configure_photo_sync.sh <prefix>"
echo "3️⃣  🔒 Enable WireGuard: sudo systemctl enable wg-quick@wg0"
echo "4️⃣  🔄 Restart the Pi: sudo reboot now"