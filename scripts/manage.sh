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
  CYAN=$'\033[38;5;39m'; GREEN=$'\033[38;5;42m'
  YELLOW=$'\033[38;5;214m'; RED=$'\033[38;5;203m'
else
  BOLD=""; DIM=""; RESET=""; CYAN=""; GREEN=""; YELLOW=""; RED=""
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
  ${BOLD}sync-photos${RESET} [instance]   Run photo sync now (streams rclone output)
                          instance: ${ALLOWED_INSTANCES[*]}
                          If omitted, auto-detect from this frame's crontab.
  ${BOLD}list-wifi${RESET} [-s]           List saved WiFi profiles (-s reveals passwords)
  ${BOLD}add-wifi${RESET}                 Save a new WiFi profile (interactive)
  ${BOLD}update-web-ui${RESET} [--force|--check]
                          Sync repo's src/picframe/html/ into the runtime
                          html folder. --check reports drift only.
  ${BOLD}completion${RESET} <bash|fish>          Print shell completion script
  ${BOLD}install-completion${RESET} [bash|fish]   Install completion into your rc / fish dir
                                  (auto-detects shell from \$SHELL if omitted)
  ${BOLD}help${RESET}                            Show this message

Examples:
  $(basename "$0") sync-photos
  $(basename "$0") sync-photos batanovs
  $(basename "$0") list-wifi -s
  $(basename "$0") add-wifi
  $(basename "$0") update-web-ui
  $(basename "$0") update-web-ui --check
  $(basename "$0") install-completion
EOF
}

is_allowed_instance() {
  local candidate="$1"
  [[ " ${ALLOWED_INSTANCES[*]} " == *" ${candidate} "* ]]
}

# Detection sources, in order of trust:
#   1. hostname — substring match against ALLOWED_INSTANCES
#   2. crontab line written by install/5_configure_photo_sync.sh
# Each prints just the instance name on success; sets DETECTED_VIA for the caller.
DETECTED_VIA=""

detect_from_hostname() {
  local host
  host="$(hostname 2>/dev/null | tr '[:upper:]' '[:lower:]')" || return 1
  [[ -z "$host" ]] && return 1
  local inst
  for inst in "${ALLOWED_INSTANCES[@]}"; do
    if [[ "$host" == *"$inst"* ]]; then
      DETECTED_VIA="hostname '$host'"
      echo "$inst"
      return 0
    fi
  done
  return 1
}

detect_from_crontab() {
  local line
  line="$(crontab -l 2>/dev/null | grep -E 'photo-sync@[a-z]+' | head -n1 || true)"
  [[ -z "$line" ]] && return 1
  local found
  found="$(echo "$line" | sed -E 's/.*photo-sync@([a-z]+).*/\1/')"
  is_allowed_instance "$found" || return 1
  DETECTED_VIA="crontab"
  echo "$found"
}

detect_instance() {
  detect_from_hostname || detect_from_crontab
}

cmd_sync_photos() {
  local instance="${1:-}"
  local detected=""
  detected="$(detect_instance || true)"

  # Always report what auto-detect saw — useful for verifying detection
  # signals on a real frame, even when an explicit arg agrees.
  if [[ -n "$detected" ]]; then
    info "Auto-detect: ${BOLD}${detected}${RESET} (via ${DETECTED_VIA})"
  else
    info "Auto-detect: ${DIM}no signal${RESET} (hostname=$(hostname 2>/dev/null || echo '?'), no photo-sync@ in crontab)"
  fi

  if [[ -z "$instance" ]]; then
    if [[ -n "$detected" ]]; then
      instance="$detected"
    else
      die "could not auto-detect instance. Pass one explicitly: ${ALLOWED_INSTANCES[*]}"
    fi
  else
    instance="$(echo "$instance" | tr '[:upper:]' '[:lower:]')"
    is_allowed_instance "$instance" \
      || die "unknown instance '${instance}'. Allowed: ${ALLOWED_INSTANCES[*]}"

    if [[ -n "$detected" && "$detected" != "$instance" ]]; then
      printf '\n  %s⚠ Frame mismatch%s\n' "$YELLOW" "$RESET"
      printf '    This frame appears to be %s%s%s (via %s)\n' \
        "$BOLD" "$detected" "$RESET" "$DETECTED_VIA"
      printf '    You asked to sync   %s%s%s\n\n' \
        "$BOLD" "$instance" "$RESET"
      printf '    Proceeding will replace %s~/Pictures/PhotoFrame%s with the %s%s%s photo set.\n' \
        "$DIM" "$RESET" "$BOLD" "$instance" "$RESET"
      printf '    Continue? [y/N] '
      local reply=""
      read -r reply </dev/tty || reply=""
      [[ "$reply" == "y" || "$reply" == "Y" ]] || die "aborted"
    else
      info "Using instance: ${BOLD}${instance}${RESET}"
    fi
  fi

  local script="${SCRIPT_DIR}/runtime/sync_photos_from_nasik.sh"
  [[ -x "$script" ]] || die "missing or not executable: ${script}"

  heading "Syncing photos · ${instance}"
  hint "(equivalent to: sudo systemctl start photo-sync@${instance})"
  echo
  exec "$script" "$instance"
}

cmd_completion() {
  local shell="${1:-}"
  case "$shell" in
    bash) print_bash_completion ;;
    fish) print_fish_completion ;;
    "")   die "specify a shell: bash | fish" ;;
    *)    die "unsupported shell '${shell}'. Supported: bash | fish" ;;
  esac
}

print_bash_completion() {
  cat <<'EOF'
_picframe_manage_complete() {
  local cur sub
  cur="${COMP_WORDS[COMP_CWORD]}"
  sub="${COMP_WORDS[1]:-}"

  if [ "$COMP_CWORD" -eq 1 ]; then
    COMPREPLY=( $(compgen -W "sync-photos list-wifi add-wifi update-web-ui completion install-completion help" -- "$cur") )
    return
  fi

  case "$sub" in
    sync-photos)
      [ "$COMP_CWORD" -eq 2 ] && \
        COMPREPLY=( $(compgen -W "home batanovs cherednychoks" -- "$cur") )
      ;;
    list-wifi)
      [ "$COMP_CWORD" -eq 2 ] && \
        COMPREPLY=( $(compgen -W "-s --show-passwords" -- "$cur") )
      ;;
    update-web-ui)
      [ "$COMP_CWORD" -eq 2 ] && \
        COMPREPLY=( $(compgen -W "--force --check --help" -- "$cur") )
      ;;
    completion|install-completion)
      [ "$COMP_CWORD" -eq 2 ] && \
        COMPREPLY=( $(compgen -W "bash fish" -- "$cur") )
      ;;
  esac
}
complete -F _picframe_manage_complete manage.sh
complete -F _picframe_manage_complete ./manage.sh
EOF
}

cmd_install_completion() {
  local shell="${1:-}"

  if [[ -z "$shell" ]]; then
    case "${SHELL:-}" in
      */bash) shell=bash ;;
      */fish) shell=fish ;;
      "")     die "could not detect shell from \$SHELL. Pass one explicitly: bash | fish" ;;
      *)      die "unsupported login shell '${SHELL}'. Pass one explicitly: bash | fish" ;;
    esac
    info "Detected shell: ${BOLD}${shell}${RESET}"
  fi

  local script_abs="${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]}")"

  case "$shell" in
    bash) install_bash_completion "$script_abs" ;;
    fish) install_fish_completion "$script_abs" ;;
    *)    die "unsupported shell '${shell}'. Supported: bash | fish" ;;
  esac
}

install_bash_completion() {
  local script_abs="$1"
  local rc="${HOME}/.bashrc"
  local marker="# picframe manage.sh completion"

  if [[ -f "$rc" ]] && grep -Fq "$marker" "$rc"; then
    ok "Already installed in ${rc}"
    hint "Remove the '${marker}' block to uninstall."
    return 0
  fi

  {
    printf '\n%s\n' "$marker"
    printf 'source <("%s" completion bash)\n' "$script_abs"
  } >> "$rc"

  ok "Added completion to ${rc}"
  hint "Open a new shell, or run: source ${rc}"
}

install_fish_completion() {
  local script_abs="$1"
  local dir="${HOME}/.config/fish/completions"
  local file="${dir}/manage.sh.fish"

  mkdir -p "$dir"
  "$script_abs" completion fish > "$file"

  ok "Wrote ${file}"
  hint "Fish auto-loads on next shell. To refresh now: source ${file}"
}

print_fish_completion() {
  cat <<'EOF'
# picframe manage.sh — fish completion
complete -c manage.sh -f
complete -c manage.sh -n '__fish_use_subcommand' -a sync-photos   -d 'Run photo sync now'
complete -c manage.sh -n '__fish_use_subcommand' -a list-wifi     -d 'List saved WiFi profiles'
complete -c manage.sh -n '__fish_use_subcommand' -a add-wifi      -d 'Save a new WiFi profile'
complete -c manage.sh -n '__fish_use_subcommand' -a update-web-ui -d 'Sync src/picframe/html into runtime html folder'
complete -c manage.sh -n '__fish_use_subcommand' -a completion         -d 'Print shell completion'
complete -c manage.sh -n '__fish_use_subcommand' -a install-completion -d 'Install shell completion'
complete -c manage.sh -n '__fish_use_subcommand' -a help               -d 'Show help'
complete -c manage.sh -n '__fish_seen_subcommand_from sync-photos' \
  -a 'home batanovs cherednychoks'
complete -c manage.sh -n '__fish_seen_subcommand_from list-wifi' \
  -a '-s --show-passwords'
complete -c manage.sh -n '__fish_seen_subcommand_from update-web-ui' \
  -a '--force --check --help'
complete -c manage.sh -n '__fish_seen_subcommand_from completion install-completion' \
  -a 'bash fish'
EOF
}

cmd_list_wifi() {
  exec "${SCRIPT_DIR}/ops/list_wifi.sh" "$@"
}

cmd_add_wifi() {
  exec "${SCRIPT_DIR}/ops/add_wifi.sh" "$@"
}

cmd_update_web_ui() {
  exec "${SCRIPT_DIR}/update_web_ui.sh" "$@"
}

main() {
  if [[ $# -lt 1 ]]; then
    usage
    exit 0
  fi

  local cmd="$1"; shift
  case "$cmd" in
    sync-photos)        cmd_sync_photos   "$@" ;;
    list-wifi)          cmd_list_wifi     "$@" ;;
    add-wifi)           cmd_add_wifi      "$@" ;;
    update-web-ui)      cmd_update_web_ui "$@" ;;
    completion)         cmd_completion         "$@" ;;
    install-completion) cmd_install_completion "$@" ;;
    help|-h|--help)     usage ;;
    *) printf '%s✗ Unknown command:%s %s\n\n' "$RED" "$RESET" "$cmd" >&2; usage; exit 1 ;;
  esac
}

main "$@"
