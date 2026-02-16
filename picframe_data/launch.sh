#!/bin/bash
xset +dpms
xset s off
xset dpms 0 0 0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec /usr/bin/python3 "$SCRIPT_DIR/run_start.py" \
  "$SCRIPT_DIR/config/configuration.yaml"