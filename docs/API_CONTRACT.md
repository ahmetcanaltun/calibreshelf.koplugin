# CalibreShelf — upstream API contract

Verified against (shallow clones in `~/sw/ref/`):

| Source | Commit | Date |
|---|---|---|
| koreader/koreader | `0deae50039d4` | 2026-10-09 |
| kovidgoyal/calibre | `a41c889814f2` | 2026-10-11 |
| xZenLabs/zen-os | `a2c4524cd6c3` | 2026-10-03 |

If any of these move, re-verify the fields below before changing `api/calibre.lua`.

## Calibre Content Server (src/calibre/srv)

All responses are JSON (`postprocess=json`). JSON object keys are strings, so the
`metadata` maps are keyed by `"123"`, not `123`. `book_ids` are numbers.

### `GET /ajax/library-info` (ajax.py `library_info`)
→ `{ library_map: {library_id: display_name}, default_library: library_id }`
Lightest authenticated request, used by **Test connection** and library selection.

### `GET /interface-data/get-books` (code.py `get_books`)
Query: `library_id`, `num`, `sort` (`field.asc|desc`, comma-separated),
`search` (Calibre search syntax), `vl`.
→ `{ search_result, metadata }`
Used for the **first page** of every listing. It is lighter than `books-init`, which also
returns `field_metadata`, `sortable_fields`, and other data.
Invalid search → **HTTP 400**, body `Invalid search expression: …`.

### `POST /interface-data/more-books?num=&library_id=` (code.py `more_books`)
Body (JSON, every key required, else 400):
`{ query, offset, sort, sort_order, vl }`. `sort` and `sort_order` are comma strings,
copied from the previous `search_result`.
→ `{ search_result, metadata }`. Used for **pagination**.

### `search_result` (ajax.py `search_result`)
`total_num, num_books_without_search, offset, num, sort, sort_order, query,
library_id, book_ids[], vl, base_url, [bad_restriction]`

### `metadata[id]` = `book_as_json` (metadata.py)
Always present: `formats[]` (upper-case, only those with size > 0), `format_sizes{FMT: bytes}`,
`format_mtimes{FMT: iso}`.
Other fields are included only when non-empty: `title, authors[], author_sort, sort, series,
series_index, tags[], comments` (HTML), `timestamp` (date added, ISO), `pubdate`,
`last_modified`, `publisher, languages[], identifiers{}, rating, uuid, …`.
Code must treat every non-format field as optional.

### `GET /interface-data/newly-added?num=&library_id=` (code.py `newly_added`)
→ `{ library_id, books[ids], titles{id: title}, authors{id: [authors]} }`.
This is the ZenOS widget's only source.

### `GET /interface-data/browse-field/{field}?library_id=&vl=` (code.py `browse_field`)
`field` ∈ keys of `browse_field_map` (`series, authors, publisher, tags, formats,
rating, pubdate`, plus custom fields). Unknown field → 404.
→ `{ field, items: [{ name, count, avg_rating, search_name, search }] }`.
`search` is a ready-made search expression, e.g. `authors:"=Name"`. It is fed back into `get-books`.

### `GET /interface-data/book-metadata/{book_id}?library_id=`
→ `book_as_json` plus `id`. Missing book → 404. Used to refresh the details page.

### Content (content.py `get`)
- `GET /get/thumb/{book_id}/{library_id}?sz=WxH`: JPEG scaled to **fit** W×H
  (`&fill=1` scales to cover). If there's no cover, the server generates one.
- `GET /get/cover/{book_id}/{library_id}`: full-size JPEG (details page only, never cached).
- `GET /get/{FMT}/{book_id}/{library_id}`: the book file. Missing format → 404
  `No fmt format for the book N`. Missing book → 404.
  The response's `Content-Disposition` contains both
  `filename="ascii"` and `filename*=utf-8''<pct-encoded>`.
  The server pattern is `"{title[:30]} - {authors[:30]}_{id}.{ext}"`.

Path segments (`library_id`, `field`) must be percent-encoded.

### Sort fields
Server-side `sort` accepts any `sortable_field_keys`. We use `timestamp` (date added),
`title` (uses title_sort), `authors` (uses author_sort), `series`.
Default when none is given: `timestamp.desc`.

### Authentication (auth.py, opts.py)
- `auth_mode`: `auto` (default) | `basic` | `digest`. **`auto` = Digest unless SSL is configured.**
  So most LAN servers with users enabled require **Digest**.
- No users configured → no auth at all.
- Basic server: `401` + `WWW-Authenticate: Basic realm="calibre"`.
- Digest server: `401` + `WWW-Authenticate: Digest realm=…, nonce=…, algorithm="MD5", qop="auth"`.
- Basic credentials sent to a Digest server → **400 `Unsupported authentication method`**.
- Repeated failures may lead to an IP ban (`ban_after`, default 5) → `403 Too many login attempts`.
  Never auto-retry bad credentials.

Client strategy: probe `/ajax/library-info` **without** credentials first.
Then: 200 → open server. 401 Basic → retry once with Basic. 401 Digest → explain
("set *Authentication mode* to *basic* in Calibre → Preferences → Sharing over the net →
Advanced, or remove users").

## KOReader APIs used

| Module (require path) | Use |
|---|---|
| `ui/widget/container/widgetcontainer` | plugin base (`name`, `init`, `self.ui.menu:registerToMainMenu`) |
| `dispatcher` | `Dispatcher:registerAction(id, {category="none", event=…, title=…, general=true})` |
| `luasettings` + `datastorage` | `LuaSettings:open(DataStorage:getSettingsDir().."/calibreshelf.lua")`, `readSetting/saveSetting/flush` |
| `ui/network/manager` | `NetworkMgr:runWhenOnline(cb)` before any request, `isOnline()` |
| `socketutil` | `set_timeout(LARGE_BLOCK_TIMEOUT, LARGE_TOTAL_TIMEOUT)` for JSON, `FILE_*` for books, `reset_timeout()`, `table_sink`, `file_sink`, `redact_request`, `TIMEOUT_CODE`, `SINK_TIMEOUT_CODE` |
| `socket.http`, `socket`, `ltn12`, `socket.url`, `mime` | `socket.skip(1, http.request{url, method, headers, sink, source, redirect=false})`, same as opds.koplugin `OPDSClient:request` |
| `json` | `pcall(json.decode, s)`, `json.encode(t)` |
| `cache` | `Cache:new{slots=N}` in-memory listing cache |
| `ui/trapper` | `Trapper:wrap` + `dismissableRunInSubprocess` for cancellable downloads (Stage 3) |
| `document/documentregistry` | `DocumentRegistry:hasProvider(path)` to check that a format can be opened |
| `ui/renderimage` | `RenderImage:renderImageData(data, #data, false, w, h)` → BlitBuffer |
| `ui/widget/imagewidget` | `ImageWidget:new{image=bb, image_disposable=true}`, `:free()` |
| Widgets | `InputContainer`, `FrameContainer`, `CenterContainer`, `LeftContainer`, `OverlapGroup`, `HorizontalGroup`, `VerticalGroup`, `HorizontalSpan`, `VerticalSpan`, `TextWidget`, `TextBoxWidget`, `LineWidget`, `Button`, `TitleBar`, `InputDialog`, `ButtonDialog`, `ConfirmBox`, `InfoMessage`, `SortWidget`, `ui/downloadmgr` |
| Layout | `Device.screen` (`getWidth/getHeight/scaleBySize`), `ui/geometry`, `ui/size`, `ui/font` (`Font:getFace(name, size)`), `ffi/blitbuffer` |
| Gestures | `ui/gesturerange` → `self.ges_events = { Tap = {GestureRange:new{ges="tap", range=dimen}} }`, `hold`, `swipe` |
| Refresh | `UIManager:show/close/setDirty(widget, "ui"/"partial"/"full", region)`, `scheduleIn`, `nextTick`, `unschedule`, `forceRePaint` |
| `util` | `getSafeFilename`, `makePath`, `removeFile`, `urlEncode`, `htmlToPlainTextIfHtml`, `getFriendlySize`, `diskUsage` |
| `logger` | `dbg/info/warn/err` |

## ZenOS (modules/filebrowser/patches/home/components/registry.lua)

```lua
local register = rawget(_G, "__ZENOS_REGISTER_HOME_ITEM")   -- fallback "__ZEN_UI_REGISTER_HOME_ITEM"
register("calibreshelf.home", function(ctx) --[[ctx.width, ctx.height, ctx.is_first_row, ctx.module_cfg]]
    return widget
end, { label = "Calibre", size = "m" })   -- xs=1 s=2 m=3 l=4 xl=10 grid units
```
- `register` returns false for an invalid id or builder. Re-registering the same id replaces the entry and
  triggers a Home refresh.
- `_G.__ZENOS_UNREGISTER_HOME_ITEM(id)`.
- `ZenOSReady` is broadcast with `UIManager:broadcastEvent(Event:new("ZenOSReady"))`, so the plugin
  implements `onZenOSReady()`. New items are disabled by default and the user enables them in Zen Settings.
