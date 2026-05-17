#!/bin/bash
# Used to make photo frame more reliable when powers goes off and on at night. 
# We don't want this to make the frame working at not desired times

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <home|batanovs|cherednychoks>"
  exit 1
fi

frame=$(echo "$1" | tr '[:upper:]' '[:lower:]')

# Set your 'turn off' and 'turn on' times in "HH:MM" format (don't forget to sync with crontab)
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

# after TURN_ON_TIME / TURN_OFF_TIME are set
validate_hhmm() {
  [[ "$1" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]
}
if ! validate_hhmm "$TURN_ON_TIME" || ! validate_hhmm "$TURN_OFF_TIME"; then
  echo "Invalid time format. Use HH:MM (00–23:59)."; exit 1
fi


# Convert times to minutes since midnight for easy comparison
convert_to_minutes() {
    IFS=: read -r hour minute <<< "$1"
    echo $((10#$hour * 60 + 10#$minute))
}

TURN_OFF_MINUTES=$(convert_to_minutes "$TURN_OFF_TIME")
TURN_ON_MINUTES=$(convert_to_minutes "$TURN_ON_TIME")
CURRENT_TIME=$(date +"%H:%M")
CURRENT_MINUTES=$(convert_to_minutes "$CURRENT_TIME")

# handle normal (on<off) and overnight (on>off) windows
is_active_now=false
if (( TURN_ON_MINUTES < TURN_OFF_MINUTES )); then
  # same-day window: ON .. OFF
  (( CURRENT_MINUTES >= TURN_ON_MINUTES && CURRENT_MINUTES < TURN_OFF_MINUTES )) && is_active_now=true
else
  # overnight window: ON .. 24:00 or 00:00 .. OFF
  (( CURRENT_MINUTES >= TURN_ON_MINUTES || CURRENT_MINUTES < TURN_OFF_MINUTES )) && is_active_now=true
fi

# Check if current time is outside the active period
# Set X env vars in case xset is used
export DISPLAY=:0

ts() { date '+%Y-%m-%d %H:%M:%S'; }
have() { command -v "$1" >/dev/null 2>&1; }

if ! $is_active_now; then
  echo "$(ts) 🔌 Turning OFF monitor at $CURRENT_TIME"
  have vcgencmd && vcgencmd display_power 0 >/dev/null 2>&1
  have xset && xset -display :0 dpms force off >/dev/null 2>&1
else
  echo "$(ts) 💡 Turning ON monitor at $CURRENT_TIME"
  have vcgencmd && vcgencmd display_power 1 >/dev/null 2>&1
  have xset && { xset -display :0 dpms force on >/dev/null 2>&1; xset -display :0 s reset >/dev/null 2>&1; }
fi