#!/usr/bin/env bash
# Tap (or hold with HOLD=1) at device pixel coordinates in the emulator.
set -euo pipefail
if [ -n "${HOLD:-}" ]; then
  docker exec calibreshelf-emu sh -c "DISPLAY=:1 xdotool mousemove $1 $2 mousedown 1 sleep 1.2 mouseup 1"
else
  docker exec calibreshelf-emu sh -c "DISPLAY=:1 xdotool mousemove $1 $2 click 1"
fi
