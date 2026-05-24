#!/bin/bash
set -euo pipefail

BACKUP_URL="https://raw.githubusercontent.com/ravado/picframe/refs/heads/develop/scripts/install/0_backup_setup.sh"
BACKUP_SCRIPT_PATH="/usr/local/bin/backup_setup.sh"

read -rp "Prefix (home/batanovs/cherednychoks): " prefix
prefix=$(echo "$prefix" | tr '[:upper:]' '[:lower:]')
[[ -n "$prefix" ]] || { echo "❌ Prefix is required"; exit 1; }

echo "Select backup frequency:"
select frequency in hourly daily weekly monthly; do
  case "$frequency" in
    hourly|daily|weekly|monthly) break ;;
    *) echo "Invalid choice, select 1-4." ;;
  esac
done

# 1) Install the actual backup script
sudo mkdir -p "$(dirname "$BACKUP_SCRIPT_PATH")"
sudo curl -fsSL "$BACKUP_URL" -o "$BACKUP_SCRIPT_PATH"
sudo chmod +x "$BACKUP_SCRIPT_PATH"

# 2) Create cron wrapper that logs output to journal
CRON_DIR="/etc/cron.$frequency"
WRAPPER="$CRON_DIR/picframe_backup"
sudo mkdir -p "$CRON_DIR"

sudo bash -c "cat > '$WRAPPER' <<EOF
#!/bin/bash
PATH=/usr/sbin:/usr/bin:/sbin:/bin
exec /usr/bin/systemd-cat -t picframe-backup \"$BACKUP_SCRIPT_PATH\" \"$prefix\"
EOF"
sudo chmod +x "$WRAPPER"

echo
echo "✅ Backup script installed at: $BACKUP_SCRIPT_PATH"
echo "✅ Cron wrapper created at:    $WRAPPER"
echo "   Runs: $frequency"
echo
echo "View logs with:  journalctl -t picframe-backup"
echo "Test run:        sudo $BACKUP_SCRIPT_PATH $prefix | systemd-cat -t picframe-backup"