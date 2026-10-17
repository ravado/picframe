#!/bin/bash
#
# fix_photo_sync_sudoers.sh
#
# Make `sudo /bin/systemctl start photo-sync@<instance>` work from cron
# without a password prompt. Installs /etc/sudoers.d/photo-sync with a
# NOPASSWD rule, validated by `visudo -cf` before being put in place.
#
# Use on any already-deployed photo frame to fix the silent-cron-failure
# caused by `sudo` asking for a password in a non-interactive cron context.
#
# Usage:
#   sudo ./fix_photo_sync_sudoers.sh                 # uses $SUDO_USER
#   sudo ./fix_photo_sync_sudoers.sh <username>      # override target user
#
# Idempotent: safe to re-run.

set -euo pipefail

SUDOERS_FILE="/etc/sudoers.d/photo-sync"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "❌ Must be run as root. Try: sudo $0 $*"
  exit 1
fi

TARGET_USER="${1:-${SUDO_USER:-}}"
if [[ -z "$TARGET_USER" ]]; then
  echo "❌ Could not determine target user."
  echo "   Pass it explicitly:  sudo $0 <username>"
  exit 1
fi

if ! id -u "$TARGET_USER" >/dev/null 2>&1; then
  echo "❌ User '$TARGET_USER' does not exist on this system."
  exit 1
fi

echo "🔧 Granting passwordless 'systemctl start photo-sync@*' to: $TARGET_USER"

TMP_FILE="$(mktemp)"
trap 'rm -f "$TMP_FILE"' EXIT

cat > "$TMP_FILE" <<EOF
# /etc/sudoers.d/photo-sync
# Allows photo-sync@<instance>.service to be started from cron without a
# password. Installed by fix_photo_sync_sudoers.sh.
${TARGET_USER} ALL=(root) NOPASSWD: /bin/systemctl start photo-sync@*, /bin/systemctl start photo-sync.service, /bin/systemctl start photo-sync
EOF

if ! visudo -cf "$TMP_FILE" >/dev/null; then
  echo "❌ sudoers syntax check failed; not installing."
  exit 1
fi

if sudo -n -l -U "$TARGET_USER" 2>/dev/null | grep -qE '\(ALL\)\s*NOPASSWD:\s*ALL'; then
  echo "ℹ️  Note: $TARGET_USER already has broad 'NOPASSWD: ALL' (likely from RPi Imager / cloud-init)."
  echo "    The targeted rule below is redundant on this frame, but installing it anyway"
  echo "    as a safety net for the day you tighten the broad rule."
fi

install -m 0440 -o root -g root "$TMP_FILE" "$SUDOERS_FILE"
echo "✅ Installed $SUDOERS_FILE"

echo
echo "📋 Current photo-sync cron entries for $TARGET_USER:"
CRON_OUT="$(crontab -u "$TARGET_USER" -l 2>/dev/null || true)"
if [[ -z "$CRON_OUT" ]] || ! echo "$CRON_OUT" | grep -n 'photo-sync'; then
  echo "   (none found — add one with: crontab -e -u $TARGET_USER)"
fi

echo
echo "🧪 Verify NOPASSWD works (run as $TARGET_USER, no password should be asked):"
echo "   sudo -n /bin/systemctl start photo-sync@<instance>"
echo "   journalctl -u photo-sync@<instance>.service -n 20 --no-pager"
