#!/usr/bin/env bash
# Run api/calibre.lua integration tests against real calibre-server instances
# (open, basic auth, digest auth). Requires: calibre, luajit, luarocks.
# Lua deps (luasocket, dkjson) are installed into tests/.rocks on first run.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CB="${CALIBRE_BIN:-/Applications/calibre.app/Contents/MacOS}"
LJ="$(brew --prefix luajit 2>/dev/null || dirname "$(dirname "$(command -v luajit)")")"
ROCKS="$ROOT/tests/.rocks"
WORK="$(mktemp -d)"
PORT=8091
SERVER_PID=""

cleanup() { [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT

if [ ! -f "$ROCKS/share/lua/5.1/dkjson.lua" ]; then
  for rock in luasocket dkjson; do
    luarocks --lua-version=5.1 --lua-dir="$LJ" --tree="$ROCKS" install "$rock" >/dev/null
  done
fi
export LUA_PATH="$ROOT/tests/stubs/?.lua;$ROCKS/share/lua/5.1/?.lua;$ROCKS/share/lua/5.1/?/init.lua;;"
export LUA_CPATH="$ROCKS/lib/lua/5.1/?.so;;"

echo "Building fixture libraries in $WORK"
mkdir -p "$WORK/src" "$WORK/lib1" "$WORK/lib2"
cd "$WORK/src"
for i in 1 2 3 4 5 6 7; do printf "Chapter One\n\nTest book %s.\n" "$i" > "book$i.txt"; done
"$CB/ebook-convert" book1.txt book1.epub --title "Dune" --authors "Frank Herbert" \
  --series "Dune Chronicles" --series-index 1 --tags "Sci-Fi,Classic" >/dev/null 2>&1
"$CB/ebook-convert" book2.txt book2.epub --title "Dune Messiah" --authors "Frank Herbert" \
  --series "Dune Chronicles" --series-index 2 --tags "Sci-Fi" >/dev/null 2>&1
"$CB/ebook-convert" book3.txt book3.azw3 --title "Ağaçlar & Şehir: Uzun Bir Başlık Örneği Türkçe" \
  --authors "Orhan Pamuk" --tags "Roman" >/dev/null 2>&1
"$CB/ebook-convert" book4.txt book4.pdf --title "The Pragmatic Programmer" \
  --authors "Andrew Hunt & David Thomas" >/dev/null 2>&1
"$CB/calibredb" add --library-path "$WORK/lib1" book1.epub book2.epub book3.azw3 book4.pdf \
  book5.txt book6.txt book7.txt >/dev/null 2>&1
"$CB/calibredb" add --library-path "$WORK/lib2" book1.epub >/dev/null 2>&1
"$CB/calibre-server" --userdb "$WORK/users.sqlite" --manage-users -- add reader 'p%ss:w0rd' >/dev/null 2>&1
cd "$ROOT"

start_server() {
  "$CB/calibre-server" --port "$PORT" --listen-on 127.0.0.1 "$@" >"$WORK/server.log" 2>&1 &
  SERVER_PID=$!
  for _ in $(seq 1 60); do
    curl -s -o /dev/null "http://127.0.0.1:$PORT/" && return 0
    sleep 0.5
  done
  cat "$WORK/server.log"; return 1
}
stop_server() { kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; SERVER_PID=""; }

status=0
run_mode() {
  local mode="$1"; shift
  start_server "$@"
  CS_MODE="$mode" CS_URL="http://127.0.0.1:$PORT" CS_TMP="$WORK" luajit tests/test_api.lua || status=1
  stop_server
}

run_mode open "$WORK/lib1" "$WORK/lib2"
run_mode basic --enable-auth --auth-mode basic --userdb "$WORK/users.sqlite" "$WORK/lib1"
run_mode digest --enable-auth --userdb "$WORK/users.sqlite" "$WORK/lib1"
exit $status
