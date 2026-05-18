#!/usr/bin/env bash
# =============================================================================
# picframe · list_wifi.sh
# =============================================================================
# Show the WiFi networks NetworkManager has saved on this Pi, with the
# currently-connected one marked. Useful before shipping a frame to verify
# the destination SSID is pre-loaded (paired with add_wifi.sh).
#
# Usage (on the Pi):
#   ~/picframe/scripts/ops/list_wifi.sh                # names + flags only
#   ~/picframe/scripts/ops/list_wifi.sh -s             # also reveal passwords
#   ~/picframe/scripts/ops/list_wifi.sh --show-passwords
#
# Notes:
#   - Reading PSKs needs root (the .nmconnection files are mode 0600). With
#     -s the script calls `sudo nmcli -s`, which will prompt for your sudo
#     password once.
#   - Only wifi-type connections are listed. Ethernet/bridge/loopback are
#     filtered out.
#   - "ACTIVE" marks the profile NM is currently using on a wifi device.
#
# Exit codes:
#   0  listed successfully
#   1  preflight failed (no nmcli) or unknown argument
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
fail() { printf '\n%s✗ %s%s\n\n' "$RED" "$*" "$RESET" >&2; exit 1; }

# --- args --------------------------------------------------------------------
SHOW_PASSWORDS=0
case "${1:-}" in
    ""|"--no-passwords") ;;
    "-s"|"--show-passwords") SHOW_PASSWORDS=1 ;;
    "-h"|"--help")
        sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    *) fail "Unknown argument: $1 (try --help)" ;;
esac

# --- preflight ---------------------------------------------------------------
command -v nmcli >/dev/null 2>&1 \
    || fail "nmcli not found — this script must run on a NetworkManager-managed host (the Pi)."

printf '\n%s%spicframe · wifi profiles%s\n\n' "$BOLD" "$CYAN" "$RESET"

# Currently-active wifi connection NAME (empty if none).
# `-t` terminator-separated, `-f NAME,TYPE,DEVICE` for active connections.
ACTIVE_WIFI=$(nmcli -t -f NAME,TYPE connection show --active \
    | awk -F: '$2=="802-11-wireless"{print $1; exit}')

# All saved wifi profiles, with autoconnect flag.
# Fields: NAME, TYPE, AUTOCONNECT
PROFILES=$(nmcli -t -f NAME,TYPE,AUTOCONNECT connection show \
    | awk -F: '$2=="802-11-wireless"{print $1"|"$3}')

if [ -z "$PROFILES" ]; then
    info "No wifi profiles configured."
    printf '\n  %sUse add_wifi.sh to save one.%s\n\n' "$DIM" "$RESET"
    exit 0
fi

# --- header ------------------------------------------------------------------
if [ "$SHOW_PASSWORDS" -eq 1 ]; then
    printf '  %-28s %-10s %-10s %s\n' "SSID" "AUTOCONNECT" "ACTIVE" "PASSWORD"
    printf '  %s%-28s %-10s %-10s %s%s\n' "$DIM" \
        "----" "-----------" "------" "--------" "$RESET"
else
    printf '  %-28s %-10s %s\n' "SSID" "AUTOCONNECT" "ACTIVE"
    printf '  %s%-28s %-10s %s%s\n' "$DIM" \
        "----" "-----------" "------" "$RESET"
fi

# --- rows --------------------------------------------------------------------
# Pad value FIRST, then wrap with color — otherwise the escape sequence
# bytes count toward %-Ns width and alignment breaks.
#
# Show real SSID (802-11-wireless.ssid) instead of the NM profile NAME.
# Profile names diverge from SSIDs when netplan renders them, e.g.
# SSID `R2D2` -> profile `netplan-wlan0-R2D2`. When they differ, append
# a dim "(profile: ...)" hint so the origin is still visible.
while IFS='|' read -r NAME AUTOCONNECT; do
    [ -z "$NAME" ] && continue

    SSID=$(nmcli -g 802-11-wireless.ssid connection show "$NAME" 2>/dev/null || true)
    [ -z "$SSID" ] && SSID="$NAME"

    if [ "$SSID" != "$NAME" ]; then
        PROFILE_HINT="${DIM}(profile: ${NAME})${RESET}"
    else
        PROFILE_HINT=""
    fi

    if [ "$NAME" = "$ACTIVE_WIFI" ]; then
        ACTIVE_VAL="yes"; ACTIVE_COLOR="$GREEN"
    else
        ACTIVE_VAL="no";  ACTIVE_COLOR="$DIM"
    fi

    if [ "$AUTOCONNECT" = "yes" ]; then
        AC_VAL="yes"; AC_COLOR="$GREEN"
    else
        AC_VAL="no";  AC_COLOR="$YELLOW"
    fi

    AC_CELL=$(printf '%-11s' "$AC_VAL")
    ACTIVE_CELL=$(printf '%-10s' "$ACTIVE_VAL")
    SSID_CELL=$(printf '%-28s' "$SSID")

    if [ "$SHOW_PASSWORDS" -eq 1 ]; then
        # `-s` asks nmcli to include secrets (PSK). Needs root.
        # `-g` extracts a single field with no labels/colons.
        PSK=$(sudo nmcli -s -g 802-11-wireless-security.psk connection show "$NAME" 2>/dev/null || true)
        if [ -z "$PSK" ]; then
            PSK_OUT="${DIM}(none/open)${RESET}"
        else
            PSK_OUT="$PSK"
        fi
        printf '  %s %s%s%s %s%s%s %-20s %s\n' \
            "$SSID_CELL" \
            "$AC_COLOR" "$AC_CELL" "$RESET" \
            "$ACTIVE_COLOR" "$ACTIVE_CELL" "$RESET" \
            "$PSK_OUT" \
            "$PROFILE_HINT"
    else
        printf '  %s %s%s%s %s%s%s %s\n' \
            "$SSID_CELL" \
            "$AC_COLOR" "$AC_CELL" "$RESET" \
            "$ACTIVE_COLOR" "$ACTIVE_CELL" "$RESET" \
            "$PROFILE_HINT"
    fi
done <<< "$PROFILES"

if [ "$SHOW_PASSWORDS" -eq 0 ]; then
    printf '\n  %sRe-run with -s to reveal passwords (sudo required).%s\n\n' "$DIM" "$RESET"
else
    printf '\n'
fi
