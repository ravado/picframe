#!/bin/bash
set -euo pipefail

# Migrate an already-deployed picframe from the old layout
# (ravado/usefull-scripts cloned to ~/Documents/Scripts/) to the new
# layout where ops scripts live inside the picframe fork itself at
# ~/picframe/scripts/.
#
# What it does:
#   1. Pulls the latest picframe so ~/picframe/scripts/ exists.
#   2. Backs up each photo-sync systemd unit to <unit>.bak.<timestamp>.
#   3. Rewrites the photo-sync systemd units to point at the new path.
#   4. Reloads systemd.
#   5. Offers to delete the old ~/Documents/Scripts/ clone (y/N prompt).
#
# Safe to run more than once: each step is idempotent. Every run that
# actually rewrites a unit produces a fresh timestamped .bak alongside it.
#
# Usage:
#   ~/picframe/scripts/migrate_to_in_repo_scripts.sh

REPO_PATH="${REPO_PATH:-$HOME/picframe}"
OLD_SCRIPTS_DIR="${OLD_SCRIPTS_DIR:-$HOME/Documents/Scripts}"

OLD_SYNC_PATH="$OLD_SCRIPTS_DIR/photo-frame/sync_photos_from_nasik.sh"
NEW_SYNC_PATH="$REPO_PATH/scripts/sync_photos_from_nasik.sh"

UNIT_TEMPLATE="/etc/systemd/system/photo-sync@.service"
UNIT_BASE="/etc/systemd/system/photo-sync.service"

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
BACKUPS=()

echo "=== Migrate frame to in-repo scripts/ ==="
echo "   Repo:         $REPO_PATH"
echo "   Old location: $OLD_SCRIPTS_DIR"
echo "   New sync:     $NEW_SYNC_PATH"
echo

###########################
# 1) Pull latest picframe
###########################
if [ ! -d "$REPO_PATH/.git" ]; then
  echo "❌ $REPO_PATH is not a git checkout. Aborting."
  exit 1
fi

echo "📥 Pulling latest picframe..."
if ! git -C "$REPO_PATH" pull --ff-only; then
  echo "⚠️  git pull failed. Resolve manually then re-run this script."
  exit 1
fi

if [ ! -f "$NEW_SYNC_PATH" ]; then
  echo "❌ $NEW_SYNC_PATH still missing after pull."
  echo "   Has the migration been merged to the branch this frame tracks?"
  exit 1
fi
chmod +x "$NEW_SYNC_PATH"
echo "✅ scripts/ available at $REPO_PATH/scripts/"

###########################
# 2) Rewrite systemd units
###########################
changed=0
for unit in "$UNIT_TEMPLATE" "$UNIT_BASE"; do
  if [ ! -f "$unit" ]; then
    continue
  fi
  if grep -qF "$OLD_SYNC_PATH" "$unit"; then
    backup="${unit}.bak.${TIMESTAMP}"
    echo "💾 Backing up $unit → $backup"
    sudo cp -a "$unit" "$backup"
    BACKUPS+=("$backup")
    echo "🛠️  Rewriting $unit"
    sudo sed -i "s|$OLD_SYNC_PATH|$NEW_SYNC_PATH|g" "$unit"
    changed=1
  elif grep -qF "$NEW_SYNC_PATH" "$unit"; then
    echo "✅ Already migrated: $unit"
  else
    echo "ℹ️  $unit references neither old nor new path — leaving as-is"
  fi
done

if [ "$changed" -eq 1 ]; then
  echo "🔄 Reloading systemd..."
  sudo systemctl daemon-reload
  echo "✅ systemd daemon-reload done"
else
  echo "ℹ️  No systemd units needed rewriting"
fi

###########################
# 3) Verify the rewritten unit can find the script
###########################
for unit in "$UNIT_TEMPLATE" "$UNIT_BASE"; do
  if [ -f "$unit" ] && grep -qF "$NEW_SYNC_PATH" "$unit"; then
    if [ ! -x "$NEW_SYNC_PATH" ]; then
      echo "⚠️  $NEW_SYNC_PATH exists but is not executable"
    fi
  fi
done

###########################
# 4) Offer to remove old folder
###########################
echo
if [ -d "$OLD_SCRIPTS_DIR" ]; then
  echo "🗂️  Old folder still present: $OLD_SCRIPTS_DIR"
  echo "    Frames no longer need it — the picframe repo now ships these scripts."
  read -r -p "    Delete $OLD_SCRIPTS_DIR now? [y/N]: " REPLY
  if [[ "$REPLY" =~ ^[Yy]$ ]]; then
    rm -rf "$OLD_SCRIPTS_DIR"
    echo "🗑️  Removed $OLD_SCRIPTS_DIR"
  else
    echo "👌 Left $OLD_SCRIPTS_DIR in place. Delete manually when ready:"
    echo "      rm -rf $OLD_SCRIPTS_DIR"
  fi
else
  echo "ℹ️  $OLD_SCRIPTS_DIR not found — nothing to clean up"
fi

echo
echo "=== ✅ Migration complete ==="
echo
if [ "${#BACKUPS[@]}" -gt 0 ]; then
  echo "💾 Backups created (delete once the new units are verified):"
  for b in "${BACKUPS[@]}"; do
    echo "   - $b"
  done
  echo
  echo "Roll back any unit with:"
  echo "   sudo cp -a <unit>.bak.${TIMESTAMP} <unit> && sudo systemctl daemon-reload"
  echo
fi
echo "Smoke test the photo-sync unit:"
echo "  sudo systemctl start photo-sync@home"
echo "  systemctl status photo-sync@home"
