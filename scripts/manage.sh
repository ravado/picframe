#!/usr/bin/env bash
# manage.sh — single entry point for picframe operational scripts.
#
# Thin dispatcher: each subcommand delegates to an existing script or systemd
# unit. Add new subcommands by adding a `cmd_<name>()` function and listing it
# in usage() and the case in main().
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ALLOWED_INSTANCES=(home batanovs cherednychoks)

# --- pretty output (no-op when not a TTY) ------------------------------------
if [ -t 1 ]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
  CYAN=$'\033[38;5;39m'; GREEN=$'\033[38;5;42m'; RED=$'\033[38;5;203m'
else
  BOLD=""; DIM=""; RESET=""; CYAN=""; GREEN=""; RED=""
fi

heading() { printf '\n%s%s%s\n\n' "$BOLD$CYAN" "$*" "$RESET"; }
info()    { printf '  %s•%s %s\n'  "$CYAN"     "$RESET" "$*"; }
ok()      { printf '  %s✓%s %s\n'  "$GREEN"    "$RESET" "$*"; }
hint()    { printf '  %s%s%s\n'    "$DIM"      "$*"     "$RESET"; }
die()     { printf '\n%s✗ %s%s\n\n' "$RED" "$*" "$RESET" >&2; exit 1; }

usage() {
  cat <<EOF
${BOLD}${CYAN}picframe · manage${RESET}

Usage: $(basename "$0") <command> [args]

Commands:
  ${BOLD}sync-photos${RESET} [instance]   Trigger photo sync now via systemd
                          instance: ${ALLOWED_INSTANCES[*]}
                          If omitted, auto-detect from this frame's crontab.
  ${BOLD}list-wifi${RESET} [-s]           List saved WiFi profiles (-s reveals passwords)
  ${BOLD}add-wifi${RESET}                 Save a new WiFi profile (interactive)
  ${BOLD}help${RESET}                     Show this message

Examples:
  $(basename "$0") sync-photos
  $(basename "$0") sync-photos batanovs
  $(basename "$0") list-wifi -s
  $(basename "$0") add-wifi
EOF
}

is_allowed_instance() {
  local candidate="$1"
  [[ " ${ALLOWED_INSTANCES[*]} " == *" ${candidate} "* ]]
}

# Detect which instance this frame is configured for by reading the cron line
# written by install/5_configure_photo_sync.sh:
#   0 0 * * * sudo /bin/systemctl start photo-sync@<instance>
detect_instance() {
  local line
  line="$(crontab -l 2>/dev/null | grep -E 'photo-sync@[a-z]+' | head -n1 || true)"
  [[ -z "$line" ]] && return 1
  local found
  found="$(echo "$line" | sed -E 's/.*photo-sync@([a-z]+).*/\1/')"
  is_allowed_instance "$found" || return 1
  echo "$found"
}

cmd_sync_photos() {
  local instance="${1:-}"

  if [[ -z "$instance" ]]; then
    if instance="$(detect_instance)"; then
      info "Detected instance from crontab: ${BOLD}${instance}${RESET}"
    else
      die "could not auto-detect instance. Pass one explicitly: ${ALLOWED_INSTANCES[*]}"
    fi
  else
    instance="$(echo "$instance" | tr '[:upper:]' '[:lower:]')"
    is_allowed_instance "$instance" \
      || die "unknown instance '${instance}'. Allowed: ${ALLOWED_INSTANCES[*]}"
    info "Using instance: ${BOLD}${instance}${RESET}"
  fi

  local unit="photo-sync@${instance}.service"
  heading "Starting ${unit}"
  sudo systemctl start "${unit}"
  ok "Started"
  hint "Tail logs with: journalctl -u ${unit} -f"
  echo
}

cmd_list_wifi() {
  exec "${SCRIPT_DIR}/ops/list_wifi.sh" "$@"
}

cmd_add_wifi() {
  exec "${SCRIPT_DIR}/ops/add_wifi.sh" "$@"
}

main() {
  if [[ $# -lt 1 ]]; then
    usage
    exit 0
  fi

  local cmd="$1"; shift
  case "$cmd" in
    sync-photos)        cmd_sync_photos "$@" ;;
    list-wifi)          cmd_list_wifi   "$@" ;;
    add-wifi)           cmd_add_wifi    "$@" ;;
    help|-h|--help)     usage ;;
    *) printf '%s✗ Unknown command:%s %s\n\n' "$RED" "$RESET" "$cmd" >&2; usage; exit 1 ;;
  esac
}

main "$@"
