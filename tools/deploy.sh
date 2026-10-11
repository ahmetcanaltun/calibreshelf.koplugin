#!/usr/bin/env bash
# Copy the plugin to a Kindle over KOReader's SSH server
# (KOReader: Network > SSH server, port 2222, user root).
# Usage: KINDLE=192.168.0.20 tools/deploy.sh
set -euo pipefail
HOST="${KINDLE:?set KINDLE to the Kindle IP address}"
PORT="${KINDLE_PORT:-2222}"
DEST=/mnt/us/koreader/plugins
cd "$(dirname "$0")/.."

# Unpack next to the old copy, then swap, so a dropped connection never leaves
# a half-copied plugin behind.
COPYFILE_DISABLE=1 tar -cf - --exclude .DS_Store calibreshelf.koplugin |
  ssh -p "$PORT" -o StrictHostKeyChecking=accept-new "root@$HOST" "
    set -e
    rm -rf $DEST/.calibreshelf.new && mkdir -p $DEST/.calibreshelf.new
    tar -xf - -C $DEST/.calibreshelf.new
    rm -rf $DEST/calibreshelf.koplugin
    mv $DEST/.calibreshelf.new/calibreshelf.koplugin $DEST/
    rm -rf $DEST/.calibreshelf.new"
echo "Deployed to $HOST. Restart KOReader to load it (Exit > Restart KOReader)."
