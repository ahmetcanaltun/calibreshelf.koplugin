--[[
Integration test for api/calibre.lua against a real calibre-server.

Usage: tests/run_api_tests.sh   (starts servers, runs every mode)
   or: CS_MODE=open CS_URL=http://127.0.0.1:8091 luajit tests/test_api.lua

Modes:
  open   - no auth, two libraries (first has the 7 fixture books)
  basic  - --auth-mode basic, user "reader" / password "p%ss:w0rd"
  digest - --enable-auth with default auth_mode (digest without SSL)
]]

local Calibre = dofile("calibreshelf.koplugin/api/calibre.lua")
local ERR = Calibre.ERR

local mode = os.getenv("CS_MODE") or "open"
local base = os.getenv("CS_URL") or "http://127.0.0.1:8091"
local tmpdir = os.getenv("CS_TMP") or "/tmp"

local passed, failed = 0, 0
local function check(name, cond, extra)
    if cond then
        passed = passed + 1
        print("  ok   " .. name)
    else
        failed = failed + 1
        print("  FAIL " .. name .. (extra and ("  -- " .. tostring(extra)) or ""))
    end
end
local function errkind(err) return err and err.kind end

print(string.format("== api/calibre.lua [%s] %s", mode, base))

if mode == "open" then
    -- URL normalization
    check("normalize adds scheme", Calibre.normalizeUrl("192.168.1.2:8080/") == "http://192.168.1.2:8080")
    check("normalize keeps https", Calibre.normalizeUrl(" https://h.example/calibre/ ") == "https://h.example/calibre")
    check("normalize rejects ftp", Calibre.normalizeUrl("ftp://x") == nil)
    check("normalize rejects empty", Calibre.normalizeUrl("  ") == nil)

    local c = Calibre:new{ url = base }
    local info, err = c:libraryInfo()
    check("libraryInfo ok", info, errkind(err))
    local nlibs = 0
    for _ in pairs(info and info.library_map or {}) do nlibs = nlibs + 1 end
    check("two libraries", nlibs == 2, nlibs)
    check("default library set", info and info.default_library)
    c.library_id = "lib1"

    local p1, e1 = c:getBooks{ sort = "title", order = "asc", num = 3 }
    check("getBooks ok", p1, errkind(e1))
    check("total 7", p1 and p1.total == 7, p1 and p1.total)
    check("3 ids", p1 and #p1.ids == 3)
    local b = p1 and p1.books[p1.ids[1]]
    check("book has title", b and type(b.title) == "string")
    check("book has authors list", b and type(b.authors) == "table")
    check("book has formats", b and #b.formats >= 1, b and table.concat(b.formats, ","))
    -- calibre sanitizes "title" to its sort column "sort"; we just pass it back to more-books.
    check("sort echoed", p1 and (p1.sort == "title" or p1.sort == "sort") and p1.sort_order == "asc",
        p1 and (p1.sort .. "/" .. p1.sort_order))

    local p2, e2 = c:moreBooks(p1, 3, 3)
    check("moreBooks ok", p2, errkind(e2))
    check("moreBooks offset 3", p2 and p2.offset == 3)
    local overlap = false
    for _, id in ipairs(p2 and p2.ids or {}) do
        for _, id1 in ipairs(p1.ids) do if id == id1 then overlap = true end end
    end
    check("moreBooks pages disjoint", p2 and #p2.ids == 3 and not overlap)
    local p3 = c:moreBooks(p1, 6, 3)
    check("last page has 1", p3 and #p3.ids == 1, p3 and #p3.ids)

    local titles = {}
    for _, page in ipairs{ p1, p2, p3 } do
        for _, id in ipairs(page.ids) do table.insert(titles, page.books[id].title) end
    end
    local sorted = true
    for i = 2, #titles do if titles[i - 1]:lower() > titles[i]:lower() then sorted = false end end
    check("title sort ascending across pages", sorted, table.concat(titles, " | "))

    local s, se = c:getBooks{ search = 'authors:"=Frank Herbert"', sort = "series", order = "asc" }
    check("search by author", s and s.total == 2, se and se.detail or (s and s.total))
    local dune = s and s.books[s.ids[1]]
    check("series parsed", dune and dune.series == "Dune Chronicles" and dune.series_index == 1,
        dune and tostring(dune.series) .. " " .. tostring(dune.series_index))
    check("tags parsed", dune and #dune.tags >= 1)
    check("format sizes", dune and (dune.format_sizes.EPUB or 0) > 0)

    local _, bad = c:getBooks{ search = "(((" }
    check("bad search classified", errkind(bad) == ERR.BAD_SEARCH, errkind(bad))

    local na, nae = c:newlyAdded(4)
    check("newlyAdded ok", na and #na.ids == 4, errkind(nae))
    check("newlyAdded titles", na and type(na.titles[na.ids[1]]) == "string")

    local authors, ae = c:browseField("authors")
    check("browseField authors", authors and #authors >= 3, errkind(ae) or (ae and ae.detail))
    local fh
    for _, it in ipairs(authors or {}) do if it.name == "Frank Herbert" then fh = it end end
    -- counts only exist with browse-field (newer calibre); field-names fallback has none
    check("author item count 2 (or nil on fallback)", fh and (fh.count == 2 or (fh.count == nil and c.no_browse_field)))
    if fh then
        local r = c:getBooks{ search = fh.search }
        check("browse search expression works", r and r.total == 2, fh.search)
    end
    local series = c:browseField("series")
    check("browseField series", series and #series == 1)
    local _, be = c:browseField("no_such_field")
    check("unknown browse field -> incompatible", errkind(be) == ERR.INCOMPATIBLE, errkind(be))

    local m, me = c:bookMetadata(dune and dune.id or 1)
    check("bookMetadata ok", m and m.title == "Dune", errkind(me))
    local _, nf = c:bookMetadata(99999)
    check("missing book -> not_found", errkind(nf) == ERR.NOT_FOUND, errkind(nf))

    local thumb, te = c:fetchThumbnail(1, 200, 300)
    check("thumbnail is JPEG", thumb and thumb:sub(1, 2) == "\255\216", errkind(te))
    local cover = c:fetchCover(1)
    check("cover is JPEG and bigger", cover and thumb and cover:sub(1, 2) == "\255\216" and #cover > #thumb)

    local dest = tmpdir .. "/cs_test_download.part"
    local headers, de = c:downloadFormat(dune.id, "epub", dest)
    check("download ok", headers, errkind(de) or (de and de.detail))
    local f = io.open(dest, "rb")
    local magic = f and f:read(2)
    if f then f:close() end
    check("downloaded file is a zip/epub", magic == "PK")
    local fname = Calibre.filenameFromHeaders(headers)
    check("content-disposition filename", fname and fname:match("%.epub$"), fname)
    os.remove(dest)

    local t3 = c:getBooks{ search = "authors:\"=Orhan Pamuk\"" }
    local tid = t3 and t3.ids[1]
    if tid then
        local h3 = c:downloadFormat(tid, "AZW3", dest)
        local n3 = Calibre.filenameFromHeaders(h3)
        check("utf-8 filename* decoded", n3 and n3:find("Ağaçlar", 1, true), n3)
        os.remove(dest)
    end

    local _, mf = c:downloadFormat(dune.id, "PDF", dest)
    check("missing format -> not_found", errkind(mf) == ERR.NOT_FOUND, errkind(mf))
    check("missing format leaves no file", io.open(dest, "rb") == nil)

    local _, disk = c:downloadFormat(dune.id, "EPUB", "/nonexistent-dir/x.part")
    check("unwritable dest -> disk", errkind(disk) == ERR.DISK, errkind(disk))

    local down = Calibre:new{ url = "http://127.0.0.1:1" }
    local _, ue = down:libraryInfo()
    check("refused -> unreachable", errkind(ue) == ERR.UNREACHABLE, errkind(ue))

    local foreign = os.getenv("CS_FOREIGN_URL")
    if foreign then
        local _, fe = Calibre:new{ url = foreign }:libraryInfo()
        check("other web server on the port -> not_calibre", errkind(fe) == ERR.NOT_CALIBRE, errkind(fe))
        check("not_calibre names the server", fe and fe.message:find("SimpleHTTP", 1, true), fe and fe.message)
    end

    local c2 = Calibre:new{ url = base, library_id = "lib2" }
    local l2 = c2:getBooks{}
    check("second library selected", l2 and l2.total == 1, l2 and l2.total)

elseif mode == "basic" then
    local _, e0 = Calibre:new{ url = base }:libraryInfo()
    check("no creds -> auth_required", errkind(e0) == ERR.AUTH_REQUIRED, errkind(e0))
    local _, e1 = Calibre:new{ url = base, username = "reader", password = "wrong" }:libraryInfo()
    check("bad password -> auth_failed", errkind(e1) == ERR.AUTH_FAILED, errkind(e1))
    local ok, e2 = Calibre:new{ url = base, username = "reader", password = "p%ss:w0rd" }:libraryInfo()
    check("password with % and : works", ok, errkind(e2))
    local c = Calibre:new{ url = base, username = "reader", password = "p%ss:w0rd" }
    local p = c:getBooks{ num = 2 }
    check("authenticated getBooks", p and p.total == 7)
    local t = p and c:fetchThumbnail(p.ids[1], 100, 150)
    check("authenticated thumbnail", t and t:sub(1, 2) == "\255\216")

elseif mode == "digest" then
    local _, e0 = Calibre:new{ url = base }:libraryInfo()
    check("digest server, no creds -> auth_digest", errkind(e0) == ERR.AUTH_DIGEST, errkind(e0))
    local _, e1 = Calibre:new{ url = base, username = "reader", password = "p%ss:w0rd" }:libraryInfo()
    check("digest server, basic creds -> auth_digest", errkind(e1) == ERR.AUTH_DIGEST, errkind(e1))
    check("digest message explains fix", e1 and e1.message:find("basic", 1, true))
end

print(string.format("== %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
