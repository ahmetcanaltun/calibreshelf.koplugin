#!/usr/bin/env bash
# Screenshot the emulator: tests/emulator/out/<name>.png (+ <name>_small.png)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
docker exec calibreshelf-emu sh -c "DISPLAY=:1 import -window root /out/$1.png"
sips -Z 900 "$HERE/out/$1.png" --out "$HERE/out/$1_small.png" >/dev/null
