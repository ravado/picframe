#!/usr/bin/env bash
# =============================================================================
# picframe · add_wifi.sh
# =============================================================================
# Save an additional WiFi network on this Pi so the frame autoconnects to it
# when shipped to a new location (relative's house, holiday cottage, etc.).
#
# Why this script exists:
#   Frames are prepared on the home LAN, then deployed elsewhere. Before
#   shipping we need to pre-load the destination SSID + password so the frame
#   joins the new network the moment it powers on. NetworkManager owns the
#   wifi stack on these Pis, so we drive it via `nmcli` instead of editing
#   the NM-rendered netplan YAML by hand (which races against NM's own
#   writes and loses comments on a PyYAML round-trip).
#
# Usage (run on the Pi itself, as the frame's regular user):
#   ssh ivan@frame
#   ~/picframe/scripts/ops/add_wifi.sh
#
# Behaviour:
#   - Prompts for SSID and password (password is read silently).
#   - Idempotent: re-running with the same SSID updates the password on the
#     existing profile rather than creating a duplicate `MySSID 1`.
#   - Does NOT activate the new profile. The current WiFi connection stays
#     up; NM autoconnects to the new SSID whenever it sees it in range.
#   - Profile is stored at /etc/NetworkManager/system-connections/<SSID>.nmconnection
#     (root-owned, mode 0600 — NM enforces this).
#
# Exit codes:
#   0  profile added or updated
#   1  preflight failed (no nmcli, empty input) or nmcli command failed
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

info() { printf '  %s•%s %s\n' "$CYAN"   "$RESET" "$*"; }
ok()   { printf '  %s✓%s %s\n' "$GREEN"  "$RESET" "$*"; }
warn() { printf '  %s!%s %s\n' "$YELLOW" "$RESET" "$*"; }
fail() { printf '\n%s✗ %s%s\n\n' "$RED" "$*" "$RESET" >&2; exit 1; }

printf '\n%s%spicframe · add wifi%s\n\n' "$BOLD" "$CYAN" "$RESET"

# --- preflight ---------------------------------------------------------------
command -v nmcli >/dev/null 2>&1 \
    || fail "nmcli not found — this script must run on a NetworkManager-managed host (the Pi)."

# --- prompts -----------------------------------------------------------------
read -rp  "SSID:     " SSID
read -rsp "Password: " PASSWORD
echo

[ -n "$SSID" ]     || fail "SSID must not be empty."
[ -n "$PASSWORD" ] || fail "Password must not be empty."

# --- idempotency check -------------------------------------------------------
# Match the connection NAME exactly (con-name == SSID by our convention).
# `-t` gives terminator-separated output, `-f NAME` gives only the name field.
if nmcli -t -f NAME connection show | grep -Fxq "$SSID"; then
    info "Profile '$SSID' already exists — updating password."
    sudo nmcli connection modify "$SSID" \
        wifi-sec.key-mgmt wpa-psk \
        wifi-sec.psk      "$PASSWORD" \
        || fail "nmcli connection modify failed."
    ok "Password updated for '$SSID'."
else
    info "Creating new wifi profile '$SSID'."
    sudo nmcli connection add type wifi \
        con-name          "$SSID" \
        ssid              "$SSID" \
        wifi-sec.key-mgmt wpa-psk \
        wifi-sec.psk      "$PASSWORD" \
        >/dev/null \
        || fail "nmcli connection add failed."
    ok "Profile '$SSID' saved — will autoconnect when in range."
fi

printf '  %s(current WiFi connection is unchanged.)%s\n\n' "$DIM" "$RESET"
