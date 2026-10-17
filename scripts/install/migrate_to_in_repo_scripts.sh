#!/bin/bash
set -euo pipefail

# Migrate an already-deployed picframe from the old layout
# (ravado/usefull-scripts cloned to ~/Documents/Scripts/) to the new
# layout where ops scripts live inside the picframe fork itself at
# ~/picframe/scripts/.
#
# What it does:
#   1. Pulls the latest picframe (as the frame user) so ~/picframe/scripts/ exists.
#   2. Backs up each photo-sync systemd unit to <unit>.bak.<timestamp>.
#   3. Rewrites the photo-sync systemd units to point at the new path.
#   4. Reloads systemd and verifies the units parse.
#   5. Scans root + frame-user crontabs for stale references and offers cleanup.
#   6. Offers to delete the old ~/Documents/Scripts/ clone — refuses while any
#      crontab still references it.
#
# Safe to run more than once: each step is idempotent.
#
# Flags:
#   --yes, -y     Don't prompt; accept all destructive offers
#
# Env overrides:
#   PICFRAME_USER    (default: ivan)
#   REPO_PATH        (default: /home/$PICFRAME_USER/picframe)
#   OLD_SCRIPTS_DIR  (default: /home/$PICFRAME_USER/Documents/Scripts)
#
# Usage:
#   ~/picframe/scripts/install/migrate_to_in_repo_scripts.sh
#   ~/picframe/scripts/install/migrate_to_in_repo_scripts.sh --yes   # non-interactive

PICFRAME_USER="${PICFRAME_USER:-ivan}"
RUN_HOME="/home/$PICFRAME_USER"
REPO_PATH="${REPO_PATH:-$RUN_HOME/picframe}"
OLD_SCRIPTS_DIR="${OLD_SCRIPTS_DIR:-$RUN_HOME/Documents/Scripts}"

OLD_SYNC_PATH="$OLD_SCRIPTS_DIR/photo-frame/sync_photos_from_nasik.sh"
NEW_SYNC_PATH="$REPO_PATH/scripts/runtime/sync_photos_from_nasik.sh"

# Crontab patterns considered stale by this migration. Each is an extended
# regex applied per-line. Hits are listed and (with confirmation) stripped.
#   - Documents/[Ss]cripts: old ops-script clone, any owning user (some frames
#     still have lines referencing the legacy /home/ivan.cherednychok/... user).
#   - monitor_control\.sh:  display on/off helper. Dead on Wayland (uses
#     vcgencmd + xset dpms); display scheduling is handled by the
#     curl http://localhost:9000/?display_is_on=... cron lines instead.
#   - sync_and_resize_photos: legacy sync chain superseded by sync_photos_from_nasik.sh.
STALE_CRON_REGEX='Documents/[Ss]cripts|monitor_control\.sh|sync_and_resize_photos'

UNIT_TEMPLATE="/etc/systemd/system/photo-sync@.service"
UNIT_BASE="/etc/systemd/system/photo-sync.service"

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
BACKUPS=()
ASSUME_YES=0

for arg in "$@"; do
  case "$arg" in
    -y|--yes) ASSUME_YES=1 ;;
    -h|--help)
      sed -n '3,30p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "Unknown flag: $arg" >&2; exit 2 ;;
  esac
done

# Run a command as the picframe user. If we're already that user, run inline —
# avoids touching .git ownership when invoked via sudo / as root.
as_picframe() {
  if [ "$(id -un)" = "$PICFRAME_USER" ]; then
    "$@"
  else
    sudo -u "$PICFRAME_USER" "$@"
  fi
}

confirm() {
  local prompt="$1"
  [ "$ASSUME_YES" -eq 1 ] && return 0
  [ -t 0 ] || return 1
  local ans
  read -r -p "$prompt [y/N]: " ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

# Detect the photo-sync instance configured on this frame. Looks at the daily
# cron line written by 5_configure_photo_sync.sh first, then falls back to any
# instantiated systemd unit. Echoes empty if nothing is found.
detect_instance() {
  local inst u
  for u in "$PICFRAME_USER" root; do
    inst="$(sudo crontab -u "$u" -l 2>/dev/null \
            | grep -oE 'photo-sync@[A-Za-z0-9_-]+' \
            | head -1 \
            | sed 's/photo-sync@//')"
    [ -n "$inst" ] && { echo "$inst"; return; }
  done
  inst="$(systemctl list-units --all --no-legend 'photo-sync@*' 2>/dev/null \
          | grep -oE 'photo-sync@[A-Za-z0-9_-]+' \
          | head -1 \
          | sed 's/photo-sync@//')"
  [ -n "$inst" ] && echo "$inst" || true
}

echo "=== Migrate frame to in-repo scripts/ ==="
echo "   Frame user:   $PICFRAME_USER"
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

echo "📥 Pulling latest picframe (as $PICFRAME_USER)..."
if ! as_picframe git -C "$REPO_PATH" pull --ff-only; then
  echo "⚠️  git pull failed. Resolve manually then re-run this script."
  exit 1
fi

if [ ! -f "$NEW_SYNC_PATH" ]; then
  echo "❌ $NEW_SYNC_PATH still missing after pull."
  echo "   Has the migration been merged to the branch this frame tracks?"
  exit 1
fi
as_picframe chmod +x "$NEW_SYNC_PATH"
echo "✅ scripts/ available at $REPO_PATH/scripts/"

###########################
# 2) Rewrite systemd units
###########################
changed=0
for unit in "$UNIT_TEMPLATE" "$UNIT_BASE"; do
  [ -f "$unit" ] || continue
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
  echo "🔎 Verifying rewritten units..."
  for unit in "$UNIT_TEMPLATE" "$UNIT_BASE"; do
    [ -f "$unit" ] || continue
    if sudo systemd-analyze verify "$unit" 2>&1; then
      echo "   ✅ $(basename "$unit") parses cleanly"
    else
      echo "   ⚠️  $(basename "$unit") failed verify — review above"
    fi
  done
else
  echo "ℹ️  No systemd units needed rewriting"
fi

###########################
# 3) Sanity: script is executable when units reference it
###########################
for unit in "$UNIT_TEMPLATE" "$UNIT_BASE"; do
  if [ -f "$unit" ] && grep -qF "$NEW_SYNC_PATH" "$unit" && [ ! -x "$NEW_SYNC_PATH" ]; then
    echo "⚠️  $NEW_SYNC_PATH exists but is not executable"
  fi
done

###########################
# 4) Sweep crontabs for stale references
###########################
echo
echo "🕵️  Scanning crontabs for stale references..."
echo "    Patterns: $STALE_CRON_REGEX"

# stale_dir_remains tracks ONLY references to $OLD_SCRIPTS_DIR — that's the
# directory step 5 wants to delete, so any remaining reference to it is a
# blocker for the rm -rf. Other stale matches (monitor_control,
# sync_and_resize_photos) are noise we offer to remove but don't block on.
stale_dir_remains=0
for u in root "$PICFRAME_USER"; do
  cron_content="$(sudo crontab -u "$u" -l 2>/dev/null || true)"
  if ! grep -qE "$STALE_CRON_REGEX" <<<"$cron_content"; then
    continue
  fi

  echo "⚠️  Stale entries in ${u}'s crontab:"
  grep -nE "$STALE_CRON_REGEX" <<<"$cron_content" | sed 's/^/      /'
  echo "    💡 Prefer to rewrite the path instead of deleting?"
  echo "       Skip below and edit manually: sudo crontab -u $u -e"

  if confirm "    Remove these lines from ${u}'s crontab?"; then
    backup_cron="/tmp/crontab-${u}-${TIMESTAMP}.bak"
    printf '%s\n' "$cron_content" > "$backup_cron"
    echo "    💾 Backed up ${u}'s crontab → $backup_cron"
    new_cron="$(grep -vE "$STALE_CRON_REGEX" <<<"$cron_content" || true)"
    printf '%s\n' "$new_cron" | sudo crontab -u "$u" -
    echo "    ✅ Removed stale entries from ${u}'s crontab"
  else
    echo "    👌 Left ${u}'s crontab unchanged — edit later with: sudo crontab -u $u -e"
    # Only the OLD_SCRIPTS_DIR pattern blocks the dir-delete in step 5.
    if grep -qF "$OLD_SCRIPTS_DIR" <<<"$cron_content"; then
      stale_dir_remains=1
    fi
  fi
done
[ "$stale_dir_remains" -eq 0 ] && echo "✅ No remaining crontab references to $OLD_SCRIPTS_DIR"

###########################
# 4.5) Remind about the @reboot monitor-safety line
###########################
NEW_SAFETY_PATH="$REPO_PATH/scripts/ops/monitor_safety_on_boot.sh"
MONITOR_SAFETY_INSTANCE="$(detect_instance || true)"
SAFETY_FRAME_ARG="${MONITOR_SAFETY_INSTANCE:-<home|batanovs|cherednychoks>}"

if [ -x "$NEW_SAFETY_PATH" ]; then
  echo
  echo "🛟 Add this @reboot line to ${PICFRAME_USER}'s crontab as the Wayland-safe"
  echo "   replacement for the old monitor_control.sh safety net:"
  echo
  echo "   @reboot $NEW_SAFETY_PATH $SAFETY_FRAME_ARG >> $RUN_HOME/picframe_data/cron_log.txt 2>&1"
  echo
  echo "   Edit with: sudo crontab -u $PICFRAME_USER -e"
fi

###########################
# 5) Offer to remove old folder
###########################
echo
if [ ! -d "$OLD_SCRIPTS_DIR" ]; then
  echo "ℹ️  $OLD_SCRIPTS_DIR not found — nothing to clean up"
elif [ "$stale_dir_remains" -eq 1 ]; then
  echo "🛑 Refusing to delete $OLD_SCRIPTS_DIR — crontab still references it."
  echo "   Clean the crontab first, then re-run this script."
else
  echo "🗂️  Old folder still present: $OLD_SCRIPTS_DIR"
  echo "    Frames no longer need it — the picframe repo now ships these scripts."
  if confirm "    Delete $OLD_SCRIPTS_DIR now?"; then
    rm -rf "$OLD_SCRIPTS_DIR"
    echo "🗑️  Removed $OLD_SCRIPTS_DIR"
  else
    echo "👌 Left $OLD_SCRIPTS_DIR in place. Delete manually when ready:"
    echo "      rm -rf $OLD_SCRIPTS_DIR"
  fi
fi

echo
echo "=== ✅ Migration complete ==="
echo
if [ "${#BACKUPS[@]}" -gt 0 ]; then
  echo "💾 Unit backups created (delete once the new units are verified):"
  for b in "${BACKUPS[@]}"; do
    echo "   - $b"
  done
  echo
  echo "Roll back any unit with:"
  echo "   sudo cp -a <unit>.bak.${TIMESTAMP} <unit> && sudo systemctl daemon-reload"
  echo
fi
DETECTED_INSTANCE="$(detect_instance || true)"
if [ -n "$DETECTED_INSTANCE" ]; then
  echo "Smoke test the photo-sync unit (detected instance: $DETECTED_INSTANCE):"
  echo "  sudo systemctl start photo-sync@${DETECTED_INSTANCE}"
  echo "  systemctl status photo-sync@${DETECTED_INSTANCE}"
else
  echo "Smoke test the photo-sync unit (couldn't detect instance — pick one):"
  echo "  sudo systemctl start photo-sync@<instance>   # e.g., home, batanovs, cherednychoks"
  echo "  systemctl status photo-sync@<instance>"
fi
