#!/bin/bash
set -euo pipefail

REPO_URL="https://raw.githubusercontent.com/ravado/picframe/main/scripts/migration"

# Always work in current dir for curl|bash
SCRIPT_DIR="$(pwd)"

# Files to download
FILES=(env_loader.sh 0_backup_setup.sh 1_install_packages.sh 2_install_picframe.sh 3_restore_samba.sh 4_restore_picframe_backup.sh 5_configure_photo_sync.sh fix_photo_sync_sudoers.sh backup.env.example)

echo "📥 Downloading required scripts..."
for file in "${FILES[@]}"; do
    echo "   → $file"
    curl -fsSL "$REPO_URL/$file" -o "$SCRIPT_DIR/$file"
    chmod +x "$SCRIPT_DIR/$file" 2>/dev/null || true
done
echo "✅ All scripts downloaded."

# Copy backup.env.example to backup.env if not present
if [ ! -f "$SCRIPT_DIR/backup.env" ]; then
    echo "⚠️ No backup.env found, creating from example..."
    cp "$SCRIPT_DIR/backup.env.example" "$SCRIPT_DIR/backup.env"
    chmod 600 "$SCRIPT_DIR/backup.env"
    echo "✅ backup.env created from example. Please edit it to match your environment."
fi

echo ""
echo "✅ Installation complete."
echo ""
echo "👉 Next steps:"
echo "1️⃣  Edit 'backup.env' to match your SMB credentials and PicFrame user."
echo "2️⃣  Run the scripts in order:"
echo "    ./1_install_packages.sh"
echo "    ./2_install_picframe.sh"
echo "    ./3_restore_samba.sh"
echo "    ./4_restore_picframe_backup.sh <prefix> <latest|filename>"
echo "    ./5_configure_photo_sync.sh <prefix>"
echo ""
echo "ℹ️ Example (home frame):"
echo "    ./4_restore_picframe_backup.sh home latest"
echo "    ./5_configure_photo_sync.sh home"