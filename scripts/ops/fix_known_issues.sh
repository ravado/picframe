#!/usr/bin/env bash
# =============================================================================
# picframe · fix_known_issues.sh
# =============================================================================
# Idempotent migration for frames installed before the 2026-05-17 incident.
# Brings an existing frame up to the hardened defaults that fresh installs
# now get from scripts/install/2_install_picframe.sh.
#
# What it fixes:
#
#   1. picframe.service — adds ExecStartPre socket cleanup + paced restart
#      limits. Without this, a labwc SIGSEGV leaves a stale Wayland socket
#      at /run/user/<UID>/wayland-0; subsequent restarts mistake themselves
#      for nested Wayland clients and exit 1, and systemd's default burst
#      limit (5 starts in 10s) gives up. See:
#      docs/incident-2026-05-17-labwc-segfault.md
#
#   2. NetworkManager wifi.powersave — writes a global conf.d override so
#      every wifi connection (current and any added later via add_wifi.sh)
#      inherits powersave=off. wlan0 otherwise self-disconnects every ~60s.
#
#   3. systemd-coredump — ensures the package is installed so the next
#      labwc segfault produces a stack trace in /var/lib/systemd/coredump/.
#      Without a dump we cannot diagnose the segfault itself, only its
#      aftermath.
#
# Idempotent: re-running is safe. Each fix is skipped if already applied.
# No restarts or reboots are triggered. The script prints what changed and
# whether a reboot is recommended.
#
# Usage (run on the Pi itself, as the frame's regular user — same user that
# owns the picframe service, typically `ivan`):
#
#   ssh ivan@frame
#   ~/picframe/scripts/ops/fix_known_issues.sh
#
# Exit codes:
#   0  all fixes applied or already in place
#   1  preflight failed or a fix could not be applied
# =============================================================================

set -euo pipefail

# --- pretty output -----------------------------------------------------------
if [ -t 1 ]; then
    BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
    CYAN=$'\033[38;5;39m'; GREEN=$'\033[38;5;42m'
    YELLOW=$'\033[38;5;214m'; RED=$'\033[38;5;203m'
else
    BOLD=""; DIM=""; RESET=""; CYAN=""; GREEN=""; YELLOW=""; RED=""
fi

info() { printf '  %s•%s %s\n'  "$CYAN"   "$RESET" "$*"; }
ok()   { printf '  %s✓%s %s\n'  "$GREEN"  "$RESET" "$*"; }
skip() { printf '  %s=%s %s\n'  "$DIM"    "$RESET" "$*"; }
warn() { printf '  %s!%s %s\n'  "$YELLOW" "$RESET" "$*"; }
fail() { printf '\n%s✗ %s%s\n\n' "$RED" "$*" "$RESET" >&2; exit 1; }

section() { printf '\n%s%s%s\n' "$BOLD" "$*" "$RESET"; }

printf '\n%s%spicframe · fix known issues%s\n' "$BOLD" "$CYAN" "$RESET"

# --- preflight ---------------------------------------------------------------
[ "$(id -u)" -ne 0 ] \
    || fail "Run this as the frame's regular user (e.g. 'ivan'), not as root. The script uses sudo internally."

command -v systemctl >/dev/null 2>&1 \
    || fail "systemctl not found — this script targets systemd hosts (the Pi)."

command -v sudo >/dev/null 2>&1 \
    || fail "sudo not found."

# Track whether we changed anything that affects a running daemon.
REBOOT_RECOMMENDED=0

# =============================================================================
# Fix 1 · harden picframe.service
# =============================================================================
section "1. picframe.service"

SERVICE_FILE="$HOME/.config/systemd/user/picframe.service"

if [ ! -f "$SERVICE_FILE" ]; then
    warn "No service unit at $SERVICE_FILE — skipping (is this a picframe host?)."
elif grep -q '^ExecStartPre=' "$SERVICE_FILE" && grep -q '^RestartSec=' "$SERVICE_FILE"; then
    skip "Already hardened (has ExecStartPre + RestartSec)."
else
    info "Rewriting $SERVICE_FILE with hardened version."
    # Back up the original once. Repeat runs do not overwrite the backup.
    if [ ! -f "$SERVICE_FILE.bak-pre-fix" ]; then
        cp "$SERVICE_FILE" "$SERVICE_FILE.bak-pre-fix"
        info "Backed up original to $SERVICE_FILE.bak-pre-fix"
    fi
    cat > "$SERVICE_FILE" <<'EOL'
[Unit]
Description=PictureFrame on Pi

[Service]
# Wipe any stale Wayland socket left behind by a crashed labwc.
# %t expands to XDG_RUNTIME_DIR (/run/user/<UID>) for user units.
ExecStartPre=/bin/rm -f %t/wayland-0 %t/wayland-0.lock
ExecStart=/usr/bin/labwc
Restart=always
RestartSec=5
StartLimitIntervalSec=60
StartLimitBurst=3

[Install]
WantedBy=default.target
EOL
    systemctl --user daemon-reload
    # Clear any lingering failed state so the unit can start cleanly next boot.
    systemctl --user reset-failed picframe.service 2>/dev/null || true
    ok "picframe.service hardened and daemon reloaded."
    REBOOT_RECOMMENDED=1
fi

# =============================================================================
# Fix 2 · NetworkManager wifi.powersave
# =============================================================================
section "2. NetworkManager wifi.powersave"

NM_FILE="/etc/NetworkManager/conf.d/wifi-powersave-off.conf"

if ! command -v nmcli >/dev/null 2>&1; then
    warn "nmcli not found — this host is not NetworkManager-managed. Skipping."
elif [ -f "$NM_FILE" ] && grep -q 'wifi.powersave[[:space:]]*=[[:space:]]*2' "$NM_FILE"; then
    skip "Already disabled via $NM_FILE."
else
    info "Writing $NM_FILE."
    sudo mkdir -p /etc/NetworkManager/conf.d
    sudo tee "$NM_FILE" > /dev/null <<'EOL'
# Managed by picframe fix_known_issues.sh. Disables wifi powersave globally
# so all NM connections (current and future) inherit powersave=off.
# NM enum: 2 = disabled, 3 = enabled.
[connection]
wifi.powersave = 2
EOL
    # Reload NM config so the new default is read. The currently-active
    # connection keeps its old powersave setting until it is reactivated
    # (or the host reboots), which is why we flag a reboot below.
    sudo nmcli general reload >/dev/null 2>&1 \
        || warn "nmcli general reload failed — change will apply on next NM start."
    ok "Wifi powersave globally disabled."
    REBOOT_RECOMMENDED=1
fi

# =============================================================================
# Fix 3 · systemd-coredump
# =============================================================================
section "3. systemd-coredump"

if command -v coredumpctl >/dev/null 2>&1; then
    skip "systemd-coredump already installed."
else
    info "Installing systemd-coredump (so the next labwc segfault leaves a stack trace)."
    if sudo apt-get install -y systemd-coredump >/dev/null; then
        ok "systemd-coredump installed. Inspect future crashes with: coredumpctl info labwc"
    else
        warn "apt-get install systemd-coredump failed — skipping. Install manually later if desired."
    fi
fi

# =============================================================================
# Fix 4 · locale
# =============================================================================
# Bookworm images often ship with /etc/locale.gen having every locale commented
# out and /etc/default/locale empty. Combined with macOS SSH clients that
# forward LC_CTYPE=UTF-8 (bare "UTF-8" is not a valid locale name), this
# produces "setlocale: cannot change locale" warnings on every login and from
# perl/apt postinst scripts.
#
# Fix: generate en_GB.UTF-8 and set it as the system default. Setting LC_ALL
# (not just LANG) makes it the top-priority value, so the SSH-forwarded
# LC_CTYPE=UTF-8 is overridden and the warnings stop.
section "4. locale"

LOCALE_TARGET="en_GB.UTF-8"
# locale -a normalizes to "en_GB.utf8" (no dot/dash, lower-case) — check for that.
LOCALE_TARGET_NORMALIZED="en_GB.utf8"

if locale -a 2>/dev/null | grep -qx "$LOCALE_TARGET_NORMALIZED" \
    && grep -q "^LC_ALL=$LOCALE_TARGET" /etc/default/locale 2>/dev/null; then
    skip "$LOCALE_TARGET already generated and set as LC_ALL."
else
    info "Generating $LOCALE_TARGET and setting it as system default."
    # Uncomment the locale in /etc/locale.gen if it's there but commented.
    if grep -qE "^# *$LOCALE_TARGET UTF-8" /etc/locale.gen; then
        sudo sed -i "s/^# *$LOCALE_TARGET UTF-8/$LOCALE_TARGET UTF-8/" /etc/locale.gen
    elif ! grep -qE "^$LOCALE_TARGET UTF-8" /etc/locale.gen; then
        # Not present at all — append it.
        echo "$LOCALE_TARGET UTF-8" | sudo tee -a /etc/locale.gen > /dev/null
    fi
    sudo locale-gen "$LOCALE_TARGET" >/dev/null
    # LC_ALL outranks every LC_* — including the LC_CTYPE=UTF-8 that macOS
    # ssh clients forward — so login warnings stop without touching sshd.
    sudo update-locale LANG="$LOCALE_TARGET" LC_ALL="$LOCALE_TARGET"
    ok "$LOCALE_TARGET generated. New SSH sessions will be clean."
fi

# =============================================================================
# Summary
# =============================================================================
section "Summary"

if [ "$REBOOT_RECOMMENDED" -eq 1 ]; then
    printf '  %sA reboot is recommended%s so the new service unit takes over and\n' "$YELLOW" "$RESET"
    printf '  the currently-active wifi connection picks up powersave=off.\n\n'
    printf '    %ssudo reboot%s\n\n' "$BOLD" "$RESET"
else
    printf '  %sAll fixes already in place — no reboot needed.%s\n\n' "$GREEN" "$RESET"
fi
