#!/bin/bash
set -euo pipefail

# --- defaults (override with flags) ---
SMB_BACKUPS_PATH="//192.168.91.198/Backups" # e.g. //SERVER/SHARE
SMB_BACKUPS_SUBDIR="PhotoFrames"           # remote subfolder on the share
SMB_CRED_FILE="$HOME/.smbcred"             # file with: username=... / password=...
MAX_BACKUPS=30

# Require prefix parameter
if [[ $# -lt 1 ]]; then
    echo "❌ Usage: $0 <prefix>"
    echo "Example: $0 home"
    echo "Example: $0 cherednychoks"
    echo "Example: $0 batanovs"
    exit 1
fi
PREFIX="$1"

PICFRAME_DATA_DIR="$HOME/picframe/picframe_data"

# Timestamped backup paths with prefix
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
LOCAL_BACKUP_BASE="$HOME/Backups"
mkdir -p "$LOCAL_BACKUP_BASE"

# Put everything inside ~/Backups
BACKUP_DIR="$LOCAL_BACKUP_BASE/picframe_${PREFIX}_setup_backup_${TIMESTAMP}"
BACKUP_ARCHIVE="$LOCAL_BACKUP_BASE/picframe_${PREFIX}_setup_backup_${TIMESTAMP}.tar.gz"

echo "📂 Creating backup directory: $BACKUP_DIR"
mkdir -p "$BACKUP_DIR/ssh" "$BACKUP_DIR/git_config"
echo "✅ Backup directory structure created."

# Save current user's crontab
crontab -l > "$BACKUP_DIR/crontab.txt" 2>/dev/null || echo "# No crontab for user" > "$BACKUP_DIR/crontab.txt"
echo "✅ Crontab saved to $BACKUP_DIR/crontab.txt"

# Backup PicFrame systemd service
echo "⚙️ Backing up PicFrame systemd service..."
if [ -f /etc/systemd/system/picframe.service ]; then
    sudo cp /etc/systemd/system/picframe.service "$BACKUP_DIR/"
    echo "✅ picframe.service backed up"
else
    echo "⚠️ picframe.service not found in /etc/systemd/system/"
fi

# Backup SSH keys
echo "🔑 Backing up SSH keys..."
if cp ~/.ssh/id_ed25519 "$BACKUP_DIR/ssh/" 2>/dev/null; then
    echo "✅ Private SSH key saved to $BACKUP_DIR/ssh/id_ed25519"
else
    echo "⚠️ Warning: Private SSH key not found, skipping."
fi

if cp ~/.ssh/id_ed25519.pub "$BACKUP_DIR/ssh/" 2>/dev/null; then
    echo "✅ Public SSH key saved to $BACKUP_DIR/ssh/id_ed25519.pub"
else
    echo "⚠️ Warning: Public SSH key not found, skipping."
fi

# Backup git configuration
echo "🛠️ Backing up git configuration..."
git config --global user.name > "$BACKUP_DIR/git_config/user.name"
git config --global user.email > "$BACKUP_DIR/git_config/user.email"
echo "✅ Git config saved to $BACKUP_DIR/git_config/"

# Backup entire PicFrame data directory
echo "🖼️ Backing up entire PicFrame data directory..."
if [ -d "$PICFRAME_DATA_DIR" ]; then
    cp -r "$PICFRAME_DATA_DIR" "$BACKUP_DIR/"
    echo "✅ Full picframe_data directory backed up to $BACKUP_DIR/"
elif [ -d "$HOME/.config/picframe" ]; then
    cp -r "$HOME/.config/picframe" "$BACKUP_DIR/"
    echo "✅ Full ~/.config/picframe directory backed up to $BACKUP_DIR/"
else
    echo "⚠️ Warning: No PicFrame data directory found"
fi

# Save current Scripts repo branch info
echo "📜 Saving Scripts repository branch info..."
if [ -d ~/Documents/Scripts ]; then
    git -C ~/Documents/Scripts branch | grep "^\*" | cut -d' ' -f2 > "$BACKUP_DIR/git_config/scripts_branch"
    echo "✅ Scripts repo branch saved to $BACKUP_DIR/git_config/scripts_branch"
else
    echo "photoframe-home" > "$BACKUP_DIR/git_config/scripts_branch"
    echo "⚠️ Scripts repo not found, default branch name 'photoframe-home' saved."
fi

# Create info file
echo "ℹ️ Creating restore info file..."
cat > "$BACKUP_DIR/restore_info.txt" << 'RESTORE_INFO'
PicFrame Setup Backup

Contents:
- ssh/: SSH keys for GitHub access
- git_config/: Git user configuration and Scripts repo branch
- photo_structure/: Empty photo directories structure
- picframe_data/: PicFrame data and configurations
- picframe.service: Systemd service if present

To restore: ./restore_setup.sh [backup_directory]
To sync photos after restore: Use rsync from old machine
RESTORE_INFO
echo "✅ restore_info.txt created."

# Backup WireGuard configuration
echo "🔒 Backing up WireGuard configuration..."
mkdir -p "$BACKUP_DIR/wireguard_config"

if sudo test -d /etc/wireguard; then
    sudo cp -vr /etc/wireguard/. "$BACKUP_DIR/wireguard_config/"
    echo "✅ WireGuard configs and keys backed up"
else
    echo "⚠️ /etc/wireguard not found"
fi
ls -lah "$BACKUP_DIR/wireguard_config"

# Backup Samba configuration
echo "📂 Backing up SMB configuration..."
mkdir -p "$BACKUP_DIR/smb_config"
if [ -f /etc/samba/smb.conf ]; then
    sudo cp /etc/samba/smb.conf "$BACKUP_DIR/smb_config/"
    echo "✅ smb.conf backed up"
else
    echo "⚠️ SMB configuration not found"
fi

# Export full Samba tdbsam database
if command -v pdbedit >/dev/null 2>&1; then
    echo "📦 Exporting Samba tdb database..."
    sudo pdbedit -e tdbsam:"$BACKUP_DIR/smb_config/samba-export.tdb" && \
        echo "✅ Samba tdb database exported" || \
        echo "⚠️ Samba tdb export failed"
fi

if command -v pdbedit >/dev/null 2>&1; then
    sudo pdbedit -e smbpasswd:"$BACKUP_DIR/smb_config/backup_users.txt" && \
        echo "✅ Samba user database exported" || \
        echo "⚠️ SMB users backup failed"
else
    echo "⚠️ pdbedit not installed, skipping Samba users backup"
fi

# Compress backup
echo "📦 Compressing backup into ${BACKUP_ARCHIVE}..."
sudo tar -czpf "$BACKUP_ARCHIVE" -C "$BACKUP_DIR/.." "$(basename "$BACKUP_DIR")"
rm -rf "$BACKUP_DIR"
echo "✅ Backup archive created in $LOCAL_BACKUP_BASE: ${BACKUP_ARCHIVE}"

###########################
# SMB Upload and Retention
###########################
if [ -f "$SMB_CRED_FILE" ]; then
    echo "🌐 Uploading backup to SMB share $SMB_BACKUPS_PATH..."

    ARCHIVE_DIR="$(dirname "$BACKUP_ARCHIVE")"
    ARCHIVE_FILE="$(basename "$BACKUP_ARCHIVE")"

    if smbclient "$SMB_BACKUPS_PATH" -A "$SMB_CRED_FILE" \
        -c "cd $SMB_BACKUPS_SUBDIR; lcd $ARCHIVE_DIR; put $ARCHIVE_FILE"; then
        
        echo "✅ Backup uploaded to SMB."

        echo "🗑️ Applying retention policy (keep last $MAX_BACKUPS backups for prefix '$PREFIX')..."
        smbclient "$SMB_BACKUPS_PATH" -A "$SMB_CRED_FILE" \
            -c "cd $SMB_BACKUPS_SUBDIR; ls" | \
            awk '{print $1}' | grep "^picframe_${PREFIX}_setup_backup_.*\.tar\.gz$" | sort -r | \
            tail -n +$((MAX_BACKUPS+1)) | while read -r OLD_FILE; do
                echo "🗑️ Removing old backup on SMB: $OLD_FILE"
                smbclient "$SMB_BACKUPS_PATH" -A "$SMB_CRED_FILE" \
                    -c "cd $SMB_BACKUPS_SUBDIR; del $OLD_FILE"
            done

        # Remove local archive after successful upload
        rm -f "$BACKUP_ARCHIVE"
        echo "✅ Local archive removed from $LOCAL_BACKUP_BASE after SMB upload."
    else
        echo "❌ Failed to upload backup to SMB. Local copy kept in $LOCAL_BACKUP_BASE."
    fi
else
    echo "⚠️ SMB credentials file $SMB_CRED_FILE not found. Backup kept locally in $LOCAL_BACKUP_BASE."
fi

echo "✅ Backup process completed."