#!/bin/sh
# Paperwhite 12 geometry: 1236x1648 @ 300 PPI.
Xvfb :1 -screen 0 1236x1648x24 -nolisten tcp >/tmp/xvfb.log 2>&1 &
sleep 1
# VNC (password "koreader"; published on host loopback only) so a human can drive the emulator.
x11vnc -display :1 -forever -shared -passwd koreader -quiet -rfbport 5900 >/tmp/vnc.log 2>&1 &
export DISPLAY=:1 EMULATE_READER_W=1236 EMULATE_READER_H=1648 EMULATE_READER_DPI=300 HOME=/root
mkdir -p /root/Books
cd /opt/lib/koreader && exec ./luajit reader.lua -d /root/Books > /out/ko.log 2>&1
