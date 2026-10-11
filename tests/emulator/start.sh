#!/usr/bin/env bash
# Start the KOReader emulator with CalibreShelf (+ ZenOS if ZENOS_DIR is set).
# Usage: CS_AUTOOPEN=library CS_SERVER=http://host.docker.internal:8091 [CS_LIBRARY=id CS_LIBRARY_NAME=name] tests/emulator/start.sh
#        tests/emulator/shot.sh name    -> tests/emulator/out/name.png
#        tests/emulator/tap.sh X Y      -> tap at device pixel coordinates
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
KO_VERSION="${KO_VERSION:-v2026.07.1}"
TARBALL="koreader-linux-arm64-$KO_VERSION.tar.xz"
mkdir -p "$HERE/out" "$HERE/cache"
if [ ! -f "$HERE/cache/$TARBALL" ]; then
  gh release download "$KO_VERSION" --repo koreader/koreader -p "$TARBALL" -D "$HERE/cache"
fi
cp "$HERE/cache/$TARBALL" "$HERE/$TARBALL"
docker build -q --build-arg KO_TARBALL="$TARBALL" -t calibreshelf-emu "$HERE" >/dev/null
rm -f "$HERE/$TARBALL"

# Seed plugin settings so the library can open without manual setup.
SETTINGS="$HERE/out/calibreshelf.lua"
cat > "$SETTINGS" <<LUA
return {
    ["server"] = { ["url"] = "${CS_SERVER:-http://host.docker.internal:8091}", ["library_id"] = "${CS_LIBRARY:-lib1}", ["library_name"] = "${CS_LIBRARY_NAME:-${CS_LIBRARY:-lib1}}" },
}
LUA

ZEN_MOUNT=""
if [ -n "${ZENOS_DIR:-}" ]; then
  ZEN_MOUNT="-v $ZENOS_DIR:/opt/lib/koreader/plugins/zenos.koplugin"
fi
docker rm -f calibreshelf-emu >/dev/null 2>&1 || true
docker run -d --name calibreshelf-emu \
  -e CS_AUTOOPEN="${CS_AUTOOPEN:-}" \
  -v "$ROOT/calibreshelf.koplugin:/opt/lib/koreader/plugins/calibreshelf.koplugin:ro" \
  -v "$HERE/2-cs-autoopen.lua:/opt/lib/koreader/patches/2-cs-autoopen.lua:ro" \
  -v "$SETTINGS:/opt/lib/koreader/settings/calibreshelf.lua" \
  -v "$HERE/out:/out" \
  -p 127.0.0.1:5900:5900 \
  $ZEN_MOUNT \
  calibreshelf-emu >/dev/null
echo "emulator started; log: $HERE/out/ko.log; view/drive it: open vnc://localhost:5900 (password: koreader)"
