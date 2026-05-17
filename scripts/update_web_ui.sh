#!/bin/bash
# =============================================================================
# picframe · update_web_ui.sh
# =============================================================================
# Sync the redesigned web UI from the repo into the runtime html folder
# served by interface_http.py.
#
# Why this script exists:
#   picframe is installed in editable mode (`pip install -e .`), so Python
#   changes in src/ are picked up automatically — but the HTTP server reads
#   static files from `http.path` in configuration.yaml (default
#   ~/picframe_data/html), which is populated only once by `picframe -i`.
#   Updates to src/picframe/html/ therefore never reach an already-initialised
#   frame until the files are copied across by hand. This script does that
#   copy.
#
# Usage (run as the frame's regular user, NOT root):
#   ~/picframe/scripts/update_web_ui.sh           # copy if files differ
#   ~/picframe/scripts/update_web_ui.sh --force   # copy unconditionally
#   ~/picframe/scripts/update_web_ui.sh --check   # report drift, no copy
#
# Overridable environment variables:
#   REPO_PATH   picframe git checkout   (default: $HOME/picframe)
#   HTML_DEST   runtime html folder     (default: read from configuration.yaml,
#                                        falling back to $HOME/picframe_data/html)
#   CONFIG_FILE configuration.yaml path (default: $HOME/picframe_data/config/configuration.yaml)
#
# Source is always $REPO_PATH/src/picframe/html — that is the folder
# `picframe -i` copies from, so it is the canonical web UI.
#
# Exit codes:
#   0  in sync, or copy succeeded
#   1  preflight failed
#   2  --check mode and files are out of sync
# =============================================================================

set -euo pipefail

REPO_PATH="${REPO_PATH:-$HOME/picframe}"
CONFIG_FILE="${CONFIG_FILE:-$HOME/picframe_data/config/configuration.yaml}"

MODE="sync"
for arg in "$@"; do
    case "$arg" in
        --force) MODE="force" ;;
        --check) MODE="check" ;;
        -h|--help)
            sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "unknown argument: $arg" >&2; exit 1 ;;
    esac
done

# --- pretty output -----------------------------------------------------------
if [ -t 1 ]; then
    BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
    CYAN=$'\033[38;5;39m'; GREEN=$'\033[38;5;42m'
    YELLOW=$'\033[38;5;214m'; RED=$'\033[38;5;203m'
    MAGENTA=$'\033[38;5;177m'; GREY=$'\033[38;5;245m'
else
    BOLD=""; DIM=""; RESET=""; CYAN=""; GREEN=""; YELLOW=""; RED=""; MAGENTA=""; GREY=""
fi

RULE="────────────────────────────────────────────────────────"

banner() {
    printf '\n%s%s╭%s╮%s\n'   "$BOLD" "$MAGENTA" "$RULE" "$RESET"
    printf '%s%s│%s  %-52s %s│%s\n' "$BOLD" "$MAGENTA" "$RESET" "$1" "$MAGENTA" "$RESET"
    printf '%s%s╰%s╯%s\n\n' "$BOLD" "$MAGENTA" "$RULE" "$RESET"
}

info() { printf '  %s•%s %s\n' "$CYAN"   "$RESET" "$*"; }
ok()   { printf '  %s✓%s %s\n' "$GREEN"  "$RESET" "$*"; }
warn() { printf '  %s!%s %s\n' "$YELLOW" "$RESET" "$*"; }
fail() { printf '\n%s✗ %s%s\n\n' "$RED" "$*" "$RESET" >&2; exit 1; }

banner "picframe · update web UI"

# --- resolve paths -----------------------------------------------------------
HTML_SRC="$REPO_PATH/src/picframe/html"
[ -d "$HTML_SRC" ] || fail "Source not found: $HTML_SRC"

# Resolve destination: explicit env wins; otherwise parse `path:` under the
# `http:` section of configuration.yaml; otherwise fall back to the default.
if [ -z "${HTML_DEST:-}" ]; then
    if [ -f "$CONFIG_FILE" ]; then
        # awk: stay inside the http: block, grab the value of `path:`.
        # Tilde gets expanded after extraction.
        HTML_DEST="$(awk '
            /^[a-zA-Z_]+:/ { in_http = ($1 == "http:") }
            in_http && $1 == "path:" {
                sub(/^[^:]+:[[:space:]]*/, "")
                gsub(/^["'\'']|["'\'']$/, "")
                sub(/[[:space:]]*#.*$/, "")
                print; exit
            }
        ' "$CONFIG_FILE")"
        HTML_DEST="${HTML_DEST/#\~/$HOME}"
    fi
    HTML_DEST="${HTML_DEST:-$HOME/picframe_data/html}"
fi

printf '  %ssource%s %s\n' "$DIM" "$RESET" "$HTML_SRC"
printf '  %sdest%s   %s\n' "$DIM" "$RESET" "$HTML_DEST"
printf '  %smode%s   %s\n\n' "$DIM" "$RESET" "$MODE"

[ -d "$HTML_DEST" ] || fail "Destination not found: $HTML_DEST (run \`picframe -i\` first)"

# --- diff --------------------------------------------------------------------
# `diff -rq` returns 0 when identical, 1 when different. Anything else is an
# error (missing files, permission denied) — let `set -e` catch it via the
# explicit check below.
set +e
DIFF_OUTPUT="$(diff -rq "$HTML_SRC" "$HTML_DEST" 2>&1)"
DIFF_RC=$?
set -e

if [ $DIFF_RC -eq 0 ]; then
    if [ "$MODE" = "force" ]; then
        info "Files identical, but --force was given — copying anyway"
    else
        ok "Web UI already up to date"
        exit 0
    fi
elif [ $DIFF_RC -eq 1 ]; then
    printf '%s\n' "$DIFF_OUTPUT" | sed "s/^/    ${GREY}│${RESET} /"
    if [ "$MODE" = "check" ]; then
        warn "Drift detected — re-run without --check to copy"
        exit 2
    fi
else
    printf '%s\n' "$DIFF_OUTPUT" >&2
    fail "diff failed (rc=$DIFF_RC)"
fi

# --- copy --------------------------------------------------------------------
# Copy file-by-file rather than `cp -r src/. dest/` so that stale files in
# the destination (e.g. removed assets) are also pruned.
info "Syncing files..."
if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete "$HTML_SRC"/ "$HTML_DEST"/
else
    # Fallback for minimal systems without rsync: nuke and re-copy.
    find "$HTML_DEST" -mindepth 1 -delete
    cp -a "$HTML_SRC"/. "$HTML_DEST"/
fi

ok "Web UI synced"
info "Reload the page in your browser to see the changes (no service restart needed)."
