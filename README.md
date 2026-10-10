# CalibreShelf

A KOReader plugin for browsing and downloading books from a
[Calibre Content Server](https://manual.calibre-ebook.com/server.html),
built for e-ink. Developed on a Kindle Paperwhite (12th gen).

It talks to the same server the Calibre web interface uses, so it is neither
Wireless Device mode nor an OPDS browser.

- Cover grid of the whole library, paged, with lazy thumbnail loading
- Search with Calibre's own search syntax, sort by date added, title, author or series
- Browse by author, series or tag, or just the recently added books
- Book page with cover, series, tags, description, formats and sizes
- Long-press to select several books and download them in one go
- Download queue with progress, cancel and retry; files are written to a
  temporary file and only renamed once complete
- Remembers what you downloaded and marks those books "On device"
- The last viewed catalog stays browsable offline
- Optional [ZenOS](https://github.com/xZenLabs/zen-os) Home widget

## Install

Copy the `calibreshelf.koplugin` folder into KOReader's `plugins` directory
(`/mnt/us/koreader/plugins/` on a Kindle) and restart KOReader.

Open it from the search menu (magnifier) > **CalibreShelf**. You can also bind
**CalibreShelf library** to a gesture.

## Setup

1. In Calibre, start the content server (Preferences > Sharing over the net).
2. In CalibreShelf > Server settings, enter the address shown by Calibre,
   for example `http://192.168.1.10:8080`, then **Test connection**.
3. If the server has several libraries, pick one.

The download folder and preferred format order (EPUB, AZW3, MOBI, PDF by
default) are on the same screen.

### Logins

Servers without users work as is. With users enabled, Calibre defaults to
Digest authentication unless it runs over HTTPS, and CalibreShelf only
supports Basic. Set Preferences > Sharing over the net > Advanced >
Authentication mode to **basic** and restart the server. CalibreShelf tells you
when it runs into a Digest-only server.

The password is stored in KOReader's settings folder in plain text, as with
KOReader's OPDS plugin.

### ZenOS

If ZenOS is installed, a **Calibre** widget appears under Zen Settings > Home >
Widgets. It shows the library and its newest covers, and opens CalibreShelf
when tapped.

## Compatibility

Tested with calibre 7.24 and KOReader 2026.07. Author, series and tag counts
need a calibre version that has the `browse-field` route; older servers still
work, just without counts.

## Development

```sh
luacheck calibreshelf.koplugin tests     # static checks
tests/run_api_tests.sh                   # API tests against a real calibre-server
```

`tests/emulator/` runs the official KOReader Linux build headless in Docker at
Paperwhite resolution, with VNC on `localhost:5900`. See `start.sh` there.
Notes on the Calibre routes in use are in `docs/calibre-api.md`.
