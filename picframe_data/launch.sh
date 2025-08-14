#!/bin/bash
xset +dpms
xset s off
xset dpms 0 0 0
exec /usr/bin/python3 /home/ivan.cherednychok/picframe/picframe_data/run_start.py \
  /home/ivan.cherednychok/picframe/picframe_data/config/configuration.yaml