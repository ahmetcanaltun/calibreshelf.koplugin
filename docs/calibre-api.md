# Calibre server API notes

Checked against calibre `a41c889814f2` (src/calibre/srv), koreader `0deae50039d4`
and zen-os `a2c4524cd6c3`. Re-check these before changing api/calibre.lua.

The /interface-data routes are internal to calibre's web UI, not a public API.
All of them return JSON. Map keys are strings, so metadata is keyed `"123"`;
`book_ids` are numbers. Path segments (library id, field) must be url-encoded.

## Routes used

`GET /ajax/library-info`
: `{ library_map = {id: name}, default_library }`. Used by Test connection.

`GET /interface-data/get-books?library_id&num&sort&search&vl`
: First page of a listing. `sort` is `field.asc` or `field.desc`.
  Returns `{ search_result, metadata }`. A bad search gives 400 with
  `Invalid search expression: ...`. Lighter than `books-init`, which also sends
  field_metadata and friends.

`POST /interface-data/more-books?library_id&num`
: Body `{ query, offset, sort, sort_order, vl }`, all keys required, copied from
  the previous `search_result`. Same response shape as get-books.

`search_result`
: `total_num, num_books_without_search, offset, num, sort, sort_order, query,
  library_id, book_ids, vl`. Note calibre rewrites `title` to `sort` in the echo.

`metadata[id]` (book_as_json)
: Always `formats`, `format_sizes`, `format_mtimes`. Everything else (title,
  authors, series, series_index, tags, comments as HTML, timestamp,
  last_modified, ...) is only present when set, so treat it as optional.

`GET /interface-data/browse-field/{field}?library_id`
: `{ field, items = [{ name, count, avg_rating, search_name, search }] }`.
  `search` is a ready search expression. Not in calibre 7.x: the route 404s with
  an empty body. An unknown field 404s with `<field> is not a browse field`.

`GET /interface-data/field-names/{field}?library_id`
: Sorted list of names. Fallback for browse-field on older servers; we build
  `field:"=name"` searches the same way calibre does. Unknown fields give 404,
  or 500 on calibre 7.x.

`GET /interface-data/book-metadata/{id}?library_id`
: One book_as_json. Missing book: 404.

`GET /get/thumb/{id}/{library_id}?sz=WxH`
: JPEG scaled to fit WxH (`fill=1` covers instead). Books without a cover get a
  generated one.

`GET /get/cover/{id}/{library_id}`
: Full-size cover. Not used, sized thumbs are enough.

`GET /get/{FMT}/{id}/{library_id}`
: The file. Missing format: 404 `No fmt format for the book N`. Sends
  `Content-Disposition` with `filename="..."` and `filename*=utf-8''...`.

Sorting uses `timestamp` (date added, the server default), `title`, `authors`
and `series`.

## Authentication

`auth_mode` is `auto`, `basic` or `digest`. `auto` means digest unless the
server has SSL, so most home servers with users enabled want digest, which we
do not implement.

- No users configured: no auth at all.
- Basic server: 401 with `WWW-Authenticate: Basic realm="calibre"`.
- Digest server: 401 with a `Digest` challenge, and 400
  `Unsupported authentication method` if sent Basic credentials.
- Repeated failures can get the IP banned (403 `Too many login attempts`),
  so bad credentials are never retried automatically.

## KOReader

- Network: `NetworkMgr:runWhenConnected` / `isConnected`. Not the `*Online`
  variants, those resolve an internet hostname and fail on LAN-only networks.
- HTTP: `socket.http` with `socketutil:set_timeout` (LARGE_* for JSON,
  FILE_* for books), redirects handled like opds.koplugin.
- Book downloads write through a plain file sink. `socketutil.file_sink`
  enforces FILE_TOTAL_TIMEOUT over the whole transfer and kills large files.
- Downloads run in `ffiutil.runInSubProcess`; the parent polls the .part file
  size for progress and reads the result over the pipe (`string.buffer`).
- Images: `RenderImage:renderImageData`; TurboJPEG already decodes to gray on
  non-color screens.

## ZenOS

`rawget(_G, "__ZENOS_REGISTER_HOME_ITEM")(id, build, { label, size })`.
`build(ctx)` gets `width`, `height`, `is_first_row`, `module_cfg` and ZenOS
fonts (`face_title`, `face_value`, `face_label`), and runs on every Home render.
Registering the same id again replaces it and redraws Home. ZenOS broadcasts
`ZenOSReady` once loaded. New items start disabled (Zen Settings > Home > Widgets).
