#!/bin/bash
# =============================================================================
# picframe · update.sh
# =============================================================================
# In-place update for a deployed picframe Raspberry Pi.
#
# Performs three steps:
#   1. git pull --ff-only       on the currently checked-out branch
#   2. pip install -e .         inside the picframe venv, so any new
#                                dependencies declared in pyproject.toml
#                                (e.g. jinja2 added in May 2026) are
#                                installed automatically
#   3. systemctl --user restart on the picframe.service unit (which runs
#                                labwc, which auto-starts picframe via
#                                ~/.config/labwc/autostart)
#
# Why this script exists:
#   A plain `git pull` does NOT install new Python dependencies. After we
#   added jinja2 to pyproject.toml, existing frames crashed on startup with
#   ModuleNotFoundError until `pip install -e .` was re-run inside the venv.
#   This script makes that the default flow.
#
# Usage (run as the frame's regular user, NOT root):
#   ssh ivan@frame
#   ~/picframe/scripts/update.sh
#
# Overridable environment variables (defaults match 2_install_picframe.sh):
#   VENV_PATH     virtualenv root              (default: $HOME/.venv_picframe)
#   REPO_PATH     picframe git checkout        (default: $HOME/picframe)
#   SERVICE_NAME  systemd --user unit to bump  (default: picframe.service)
#
# Exit codes:
#   0  success
#   1  preflight failed (missing repo / venv) or pip install failed
#
# Safe to re-run; idempotent when there are no upstream changes.
# =============================================================================

set -euo pipefail

VENV_PATH="${VENV_PATH:-$HOME/.venv_picframe}"
REPO_PATH="${REPO_PATH:-$HOME/picframe}"
SERVICE_NAME="${SERVICE_NAME:-picframe.service}"

# --- pretty output -----------------------------------------------------------
# Colors and box-drawing characters are only emitted when stdout is a TTY,
# so output stays clean when piped to a log file or captured by systemd.
if [ -t 1 ]; then
    BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
    CYAN=$'\033[38;5;39m'; GREEN=$'\033[38;5;42m'
    YELLOW=$'\033[38;5;214m'; RED=$'\033[38;5;203m'
    MAGENTA=$'\033[38;5;177m'; GREY=$'\033[38;5;245m'
else
    BOLD=""; DIM=""; RESET=""; CYAN=""; GREEN=""; YELLOW=""; RED=""; MAGENTA=""; GREY=""
fi

RULE="────────────────────────────────────────────────────────"
STEP=0
TOTAL=3

banner() {
    printf '\n%s%s╭%s╮%s\n'   "$BOLD" "$MAGENTA" "$RULE" "$RESET"
    printf '%s%s│%s  %-52s %s│%s\n' "$BOLD" "$MAGENTA" "$RESET" "$1" "$MAGENTA" "$RESET"
    printf '%s%s╰%s╯%s\n\n' "$BOLD" "$MAGENTA" "$RULE" "$RESET"
}

step() {
    STEP=$((STEP + 1))
    printf '\n%s%s▸ [%d/%d] %s%s\n' "$BOLD" "$CYAN" "$STEP" "$TOTAL" "$1" "$RESET"
    printf '%s%s%s%s\n' "$DIM" "$GREY" "$RULE" "$RESET"
}

info() { printf '  %s•%s %s\n' "$CYAN"   "$RESET" "$*"; }
ok()   { printf '  %s✓%s %s\n' "$GREEN"  "$RESET" "$*"; }
warn() { printf '  %s!%s %s\n' "$YELLOW" "$RESET" "$*"; }
fail() { printf '\n%s✗ %s%s\n\n' "$RED" "$*" "$RESET" >&2; exit 1; }

# --- preflight ---------------------------------------------------------------
# Bail early with a clear message if the frame layout is unexpected, rather
# than producing a confusing failure midway through git/pip.
banner "picframe · update"

[ -d "$REPO_PATH/.git" ] || fail "Repo not found at $REPO_PATH"
[ -x "$VENV_PATH/bin/pip" ] || fail "Venv not found at $VENV_PATH"

printf '  %srepo%s    %s\n' "$DIM" "$RESET" "$REPO_PATH"
printf '  %svenv%s    %s\n' "$DIM" "$RESET" "$VENV_PATH"
printf '  %sservice%s %s\n' "$DIM" "$RESET" "$SERVICE_NAME"

cd "$REPO_PATH"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
BEFORE_SHA="$(git rev-parse --short HEAD)"

# --- 1. git pull -------------------------------------------------------------
# --ff-only refuses to merge if local commits exist that would require a real
# merge. Frames should never have local edits; if they do, the user can
# resolve manually rather than have this script create a merge commit.
step "Pulling latest on '$BRANCH'"
PULL_OUTPUT="$(git pull --ff-only 2>&1)"
printf '%s\n' "$PULL_OUTPUT" | sed "s/^/    ${GREY}│${RESET} /"
AFTER_SHA="$(git rev-parse --short HEAD)"
if [ "$BEFORE_SHA" = "$AFTER_SHA" ]; then
    ok "Already up to date ($AFTER_SHA)"
    CHANGED_COMMITS=0
else
    CHANGED_COMMITS="$(git rev-list --count "$BEFORE_SHA".."$AFTER_SHA")"
    ok "Updated $BEFORE_SHA → $AFTER_SHA ($CHANGED_COMMITS new commit(s))"
fi

# --- 2. pip install ----------------------------------------------------------
# Editable install re-reads pyproject.toml and pulls in any newly declared
# dependencies. Output is captured to a temp file and only shown on failure
# so the success path stays tidy; on success we surface just the
# "Successfully installed ..." line, which is the bit users actually care
# about.
step "Reinstalling picframe (editable)"
info "Syncing dependencies from pyproject.toml..."
PIP_LOG="$(mktemp)"
if "$VENV_PATH/bin/pip" install -e . > "$PIP_LOG" 2>&1; then
    NEW_PKGS="$(grep -E '^Successfully installed' "$PIP_LOG" | sed 's/^Successfully installed //' || true)"
    if [ -n "$NEW_PKGS" ]; then
        ok "Installed/updated: $NEW_PKGS"
    else
        ok "Dependencies already satisfied"
    fi
    rm -f "$PIP_LOG"
else
    cat "$PIP_LOG" >&2
    rm -f "$PIP_LOG"
    fail "pip install failed"
fi

# --- 3. restart service ------------------------------------------------------
# picframe.service is a *user* unit (see 2_install_picframe.sh step 6) that
# launches labwc; labwc in turn starts picframe via its autostart file. So
# restarting this unit fully relaunches the slideshow with the new code.
step "Restarting $SERVICE_NAME"
if systemctl --user list-unit-files "$SERVICE_NAME" >/dev/null 2>&1; then
    systemctl --user restart "$SERVICE_NAME"
    sleep 1
    STATE="$(systemctl --user is-active "$SERVICE_NAME" 2>/dev/null || echo unknown)"
    case "$STATE" in
        active)  ok "Service is ${GREEN}active${RESET}" ;;
        *)       warn "Service state: $STATE" ;;
    esac
else
    warn "$SERVICE_NAME not found under user systemd — skipping restart"
fi

# --- summary -----------------------------------------------------------------
printf '\n%s%s%s%s\n' "$DIM" "$GREY" "$RULE" "$RESET"
printf '%s%s✓ picframe updated%s  %s%s → %s%s\n\n' \
    "$BOLD" "$GREEN" "$RESET" "$DIM" "$BEFORE_SHA" "$AFTER_SHA" "$RESET"
