#!/bin/bash
# Safety net for the display on/off schedule across reboots.
#
# The daytime schedule is driven by per-boundary cron lines that call
# picframe's HTTP API directly:
#   curl http://localhost:9000/?display_is_on=true|false
# Those fire only at the boundaries, so a power-outage reboot in the middle
# of the off window would leave the screen blazing until the next boundary.
#
# This script is meant to be invoked from cron at @reboot. It looks at the
# per-frame schedule below, decides whether the display should currently be
# on or off, waits for picframe's HTTP server to come up, then issues the
# matching curl call. Picframe's display_power=2 mode handles the actual
# wlr-randr invocation on Wayland (see viewer_display.py:211-218).
#
# Usage:
#   monitor_safety_on_boot.sh <home|batanovs|cherednychoks>
#
# Expected cron line:
#   @reboot /home/ivan/picframe/scripts/ops/monitor_safety_on_boot.sh home \
#       >> /home/ivan/picframe_data/cron_log.txt 2>&1

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <home|batanovs|cherednychoks>"
  exit 1
fi

frame=$(echo "$1" | tr '[:upper:]' '[:lower:]')

# Per-frame on/off schedule. Keep in sync with the daytime cron lines for
# each frame's user crontab.
if [[ $frame == "home" ]]; then
    TURN_ON_TIME="07:00"
    TURN_OFF_TIME="21:00"
elif [[ $frame == "batanovs" ]]; then
    TURN_ON_TIME="07:00"
    TURN_OFF_TIME="23:00"
elif [[ $frame == "cherednychoks" ]]; then
    TURN_ON_TIME="05:00"
    TURN_OFF_TIME="23:00"
else
    echo "Unknown photoframe '$frame'"
    exit 1
fi

PICFRAME_URL="${PICFRAME_URL:-http://localhost:9000}"
WAIT_TIMEOUT_SECONDS=60
WAIT_INTERVAL_SECONDS=2

validate_hhmm() {
  [[ "$1" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]
}
if ! validate_hhmm "$TURN_ON_TIME" || ! validate_hhmm "$TURN_OFF_TIME"; then
  echo "Invalid time format. Use HH:MM (00–23:59)."; exit 1
fi

convert_to_minutes() {
    IFS=: read -r hour minute <<< "$1"
    echo $((10#$hour * 60 + 10#$minute))
}

TURN_OFF_MINUTES=$(convert_to_minutes "$TURN_OFF_TIME")
TURN_ON_MINUTES=$(convert_to_minutes "$TURN_ON_TIME")
CURRENT_TIME=$(date +"%H:%M")
CURRENT_MINUTES=$(convert_to_minutes "$CURRENT_TIME")

is_active_now=false
if (( TURN_ON_MINUTES < TURN_OFF_MINUTES )); then
  (( CURRENT_MINUTES >= TURN_ON_MINUTES && CURRENT_MINUTES < TURN_OFF_MINUTES )) && is_active_now=true
else
  (( CURRENT_MINUTES >= TURN_ON_MINUTES || CURRENT_MINUTES < TURN_OFF_MINUTES )) && is_active_now=true
fi

ts() { date '+%Y-%m-%d %H:%M:%S'; }

if $is_active_now; then
  desired_state="true"
  desired_label="ON"
else
  desired_state="false"
  desired_label="OFF"
fi

echo "$(ts) ⏰ Frame '$frame' at $CURRENT_TIME — window $TURN_ON_TIME..$TURN_OFF_TIME, desired display = $desired_label"

# Wait for picframe's HTTP server to come up. @reboot fires before user
# services are necessarily ready, so we poll until either the server answers
# or the timeout elapses.
echo "$(ts) ⏳ Waiting up to ${WAIT_TIMEOUT_SECONDS}s for picframe HTTP at $PICFRAME_URL ..."
deadline=$(( $(date +%s) + WAIT_TIMEOUT_SECONDS ))
while true; do
  if curl -fsS --max-time 2 -o /dev/null "$PICFRAME_URL/"; then
    echo "$(ts) ✅ picframe HTTP is up"
    break
  fi
  if (( $(date +%s) >= deadline )); then
    echo "$(ts) ❌ picframe HTTP did not respond within ${WAIT_TIMEOUT_SECONDS}s — giving up"
    exit 1
  fi
  sleep "$WAIT_INTERVAL_SECONDS"
done

echo "$(ts) 🖥️  Setting display $desired_label"
if curl -fsS --max-time 5 -o /dev/null "$PICFRAME_URL/?display_is_on=$desired_state"; then
  echo "$(ts) ✅ Display set to $desired_label"
else
  echo "$(ts) ❌ HTTP call to set display $desired_label failed"
  exit 1
fi
