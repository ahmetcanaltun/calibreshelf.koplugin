--[[--
Calibre Content Server client.

ALL Calibre-specific HTTP lives in this file. The /interface-data/* routes are
internal to Calibre's web UI and may change between versions; request/response
fields are documented in docs/API_CONTRACT.md (verified against calibre a41c889814f2).

The public surface (libraryInfo, getBooks, moreBooks, newlyAdded, browseField,
bookMetadata, fetchThumbnail, fetchCover, downloadFormat) is the backend
interface screens depend on. An OPDS adapter can implement the same methods.

Every method returns `result` on success or `nil, err` where
err = { kind = Calibre.ERR.*, message = <short human text>, detail = <log text> }.

@module calibreshelf.api.calibre
]]

local http = require("socket.http")
local json = require("json")
local logger = require("logger")
local ltn12 = require("ltn12")
local mime = require("mime")
local socket = require("socket")
local socketutil = require("socketutil")
local url = require("socket.url")
local util = require("util")
local _ = require("gettext")

local Calibre = {}
Calibre.__index = Calibre

Calibre.ERR = {
    UNREACHABLE = "unreachable",
    TIMEOUT = "timeout",
    AUTH_REQUIRED = "auth_required",
    AUTH_FAILED = "auth_failed",
    AUTH_DIGEST = "auth_digest",
    BANNED = "banned",
    FORBIDDEN = "forbidden",
    NOT_FOUND = "not_found",
    BAD_SEARCH = "bad_search",
    BAD_JSON = "bad_json",
    INCOMPATIBLE = "incompatible",
    HTTP = "http",
    DISK = "disk",
    CANCELLED = "cancelled",
}
local ERR = Calibre.ERR

local MESSAGES = {
    [ERR.UNREACHABLE] = _("Cannot reach the Calibre server. Check the address and that the server is running."),
    [ERR.TIMEOUT] = _("The Calibre server did not respond in time."),
    [ERR.AUTH_REQUIRED] = _("This Calibre server requires a username and password."),
    [ERR.AUTH_FAILED] = _("Calibre rejected the username or password."),
    [ERR.AUTH_DIGEST] = _("This Calibre server uses Digest authentication, which CalibreShelf does not support.\n\nIn Calibre, open Preferences → Sharing over the net → Advanced and set \"Authentication mode\" to \"basic\", then restart the server."),
    [ERR.BANNED] = _("Too many failed logins. The Calibre server is temporarily blocking this device."),
    [ERR.FORBIDDEN] = _("This user is not allowed to access the requested library."),
    [ERR.NOT_FOUND] = _("The requested item was not found on the server."),
    [ERR.BAD_SEARCH] = _("Calibre could not understand this search."),
    [ERR.BAD_JSON] = _("The server sent a response CalibreShelf could not read."),
    [ERR.INCOMPATIBLE] = _("This Calibre version is not compatible with CalibreShelf. Please update Calibre."),
    [ERR.HTTP] = _("The Calibre server returned an error."),
    [ERR.DISK] = _("Could not save the file. The device may be out of space."),
    [ERR.CANCELLED] = _("Cancelled."),
}

local function makeError(kind, detail, message)
    local err = { kind = kind, message = message or MESSAGES[kind] or MESSAGES[ERR.HTTP], detail = detail }
    logger.warn("CalibreShelf:", kind, detail or "")
    return err
end
Calibre.makeError = makeError

--- Normalize a user-entered server address: add scheme, drop trailing slashes.
function Calibre.normalizeUrl(address)
    address = util.trim(address or "")
    if address == "" then return nil end
    if not address:match("^%a[%w+.-]*://") then
        address = "http://" .. address
    end
    address = address:gsub("/+$", "")
    local parsed = url.parse(address)
    if not parsed or not parsed.host or (parsed.scheme ~= "http" and parsed.scheme ~= "https") then
        return nil
    end
    return address
end

local function encodeSegment(s)
    return util.urlEncode(tostring(s))
end

local function encodeQuery(query)
    if not query then return "" end
    local keys = {}
    for k, v in pairs(query) do
        if v ~= nil then table.insert(keys, k) end
    end
    if #keys == 0 then return "" end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do
        table.insert(parts, encodeSegment(k) .. "=" .. encodeSegment(query[k]))
    end
    return "?" .. table.concat(parts, "&")
end

--- @param o { url, username, password, library_id }
function Calibre:new(o)
    o = o or {}
    local client = setmetatable({
        base_url = Calibre.normalizeUrl(o.url),
        username = o.username ~= "" and o.username or nil,
        password = o.password or "",
        library_id = o.library_id,
    }, self)
    return client
end

--- Stable identifier of this server, used for cache paths and the download map.
function Calibre:serverKey()
    return self.base_url
end

function Calibre:buildUrl(path, query)
    return self.base_url .. path .. encodeQuery(query)
end

local function classifySocketError(code)
    local s = tostring(code)
    if s == socketutil.TIMEOUT_CODE or s == socketutil.SINK_TIMEOUT_CODE then
        return ERR.TIMEOUT
    end
    return ERR.UNREACHABLE
end

--[[--
Low-level request. Mirrors opds.koplugin's OPDSClient:request: socket.skip(1, http.request{...}),
redirect=false (followed manually, same origin only, no https→http downgrade).

opts: path, query, method, body (string), headers, sink, timeout ("large" | "file")
Returns code, headers, status, body_string_or_nil
]]
function Calibre:_rawRequest(opts)
    local request_url = opts.url or self:buildUrl(opts.path, opts.query)
    local origin = url.parse(request_url)
    local headers = {
        ["Accept-Encoding"] = "identity",
    }
    for k, v in pairs(opts.headers or {}) do headers[k] = v end
    if self.username then
        -- Set the header ourselves: LuaSocket's built-in user/password path url-unescapes the password.
        headers["Authorization"] = "Basic " .. mime.b64(self.username .. ":" .. self.password)
    end
    local source
    if opts.body then
        headers["Content-Type"] = headers["Content-Type"] or "application/json"
        headers["Content-Length"] = tostring(#opts.body)
        source = ltn12.source.string(opts.body)
    end

    if opts.timeout == "file" then
        socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    else
        socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    end

    local code, resp_headers, status, chunks
    for _ = 1, 5 do
        chunks = {}
        local sink = opts.sink or socketutil.table_sink(chunks)
        local request = {
            url = request_url,
            method = opts.method or "GET",
            headers = headers,
            source = source,
            sink = sink,
            redirect = false,
        }
        logger.dbg("CalibreShelf: request", socketutil.redact_request(request))
        code, resp_headers, status = socket.skip(1, http.request(request))
        if not (code == 301 or code == 302 or code == 303 or code == 307 or code == 308)
                or not resp_headers or not resp_headers.location or opts.sink then
            break
        end
        local next_url = url.absolute(request_url, resp_headers.location)
        local next_origin = url.parse(next_url)
        if next_origin.host ~= origin.host or (origin.scheme == "https" and next_origin.scheme == "http") then
            break
        end
        request_url = next_url
        if opts.body then source = ltn12.source.string(opts.body) end
    end
    socketutil:reset_timeout()

    local body = not opts.sink and table.concat(chunks) or nil
    return code, resp_headers, status, body
end

--- Map a non-200 response to an error object.
function Calibre:_httpError(code, headers, status, body, context)
    local detail = string.format("%s -> %s %s", context or "?", tostring(code), tostring(status or ""))
    if type(code) ~= "number" then
        return makeError(classifySocketError(code), detail)
    end
    body = body or ""
    if code == 401 then
        local challenge = headers and headers["www-authenticate"] or ""
        if challenge:lower():match("^%s*digest") then
            return makeError(ERR.AUTH_DIGEST, detail)
        end
        return makeError(self.username and ERR.AUTH_FAILED or ERR.AUTH_REQUIRED, detail)
    elseif code == 400 and body:find("Unsupported authentication method", 1, true) then
        -- Basic credentials sent to a server running in digest mode
        return makeError(ERR.AUTH_DIGEST, detail)
    elseif code == 400 and body:find("Invalid search expression", 1, true) then
        return makeError(ERR.BAD_SEARCH, detail .. " " .. body)
    elseif code == 403 then
        if body:find("Too many login attempts", 1, true) then
            return makeError(ERR.BANNED, detail)
        end
        return makeError(ERR.FORBIDDEN, detail .. " " .. body)
    elseif code == 404 then
        return makeError(ERR.NOT_FOUND, detail .. " " .. body)
    end
    return makeError(ERR.HTTP, detail .. " " .. body:sub(1, 200),
        string.format("%s (HTTP %d)", MESSAGES[ERR.HTTP], code))
end

--- GET/POST returning decoded JSON (a table).
function Calibre:_json(opts)
    local code, headers, status, body = self:_rawRequest(opts)
    local context = (opts.method or "GET") .. " " .. (opts.path or "")
    if code ~= 200 then
        return nil, self:_httpError(code, headers, status, body, context)
    end
    local ok, data = pcall(json.decode, body)
    if not ok or type(data) ~= "table" then
        return nil, makeError(ERR.BAD_JSON, context .. ": " .. tostring(data):sub(1, 200))
    end
    return data
end

-- JSON decoders may represent null as a sentinel; only accept real values.
local function str(v) return type(v) == "string" and v ~= "" and v or nil end
local function num(v) return type(v) == "number" and v or nil end
local function list(v)
    if type(v) ~= "table" then return {} end
    local out = {}
    for _, x in ipairs(v) do
        if type(x) == "string" then table.insert(out, x) end
    end
    return out
end

--- Reduce book_as_json to what the UI needs (keeps RAM low on the device).
function Calibre.normalizeBook(id, m)
    if type(m) ~= "table" then return nil end
    local sizes = {}
    if type(m.format_sizes) == "table" then
        for fmt, size in pairs(m.format_sizes) do
            if type(size) == "number" then sizes[fmt:upper()] = size end
        end
    end
    local formats = {}
    for _, f in ipairs(list(m.formats)) do table.insert(formats, f:upper()) end
    return {
        id = tonumber(id),
        title = str(m.title) or _("Unknown"),
        authors = list(m.authors),
        series = str(m.series),
        series_index = num(m.series_index),
        tags = list(m.tags),
        comments = str(m.comments),
        publisher = str(m.publisher),
        pubdate = str(m.pubdate),
        timestamp = str(m.timestamp),
        last_modified = str(m.last_modified),
        formats = formats,
        format_sizes = sizes,
    }
end

--- Validate and flatten { search_result, metadata } into a page.
local function parseBookPage(data, context)
    local sr = data.search_result
    if type(sr) ~= "table" or type(sr.book_ids) ~= "table" or type(data.metadata) ~= "table" then
        return nil, makeError(ERR.INCOMPATIBLE, context .. ": missing search_result/metadata")
    end
    local page = {
        total = num(sr.total_num) or 0,
        total_without_search = num(sr.num_books_without_search),
        offset = num(sr.offset) or 0,
        query = type(sr.query) == "string" and sr.query or "",
        sort = type(sr.sort) == "string" and sr.sort or "timestamp",
        sort_order = type(sr.sort_order) == "string" and sr.sort_order or "desc",
        vl = type(sr.vl) == "string" and sr.vl or "",
        library_id = str(sr.library_id),
        bad_restriction = str(sr.bad_restriction),
        ids = {},
        books = {},
    }
    for _, id in ipairs(sr.book_ids) do
        id = tonumber(id)
        if id then
            local book = Calibre.normalizeBook(id, data.metadata[tostring(id)])
            if book then
                table.insert(page.ids, id)
                page.books[id] = book
            end
        end
    end
    return page
end

--- { library_map = {id = name}, default_library = id }
function Calibre:libraryInfo()
    local data, err = self:_json{ path = "/ajax/library-info" }
    if not data then return nil, err end
    if type(data.library_map) ~= "table" then
        return nil, makeError(ERR.INCOMPATIBLE, "library-info: no library_map")
    end
    return {
        library_map = data.library_map,
        default_library = str(data.default_library),
    }
end

--[[--
First page of a listing.
@param q { search = "", sort = "timestamp", order = "desc", num = 30, vl = "" }
]]
function Calibre:getBooks(q)
    q = q or {}
    local data, err = self:_json{
        path = "/interface-data/get-books",
        query = {
            library_id = self.library_id,
            num = q.num or 30,
            sort = (q.sort or "timestamp") .. "." .. (q.order or "desc"),
            search = q.search or "",
            vl = q.vl or "",
        },
    }
    if not data then return nil, err end
    return parseBookPage(data, "get-books")
end

--- Next page, continuing a page returned by getBooks/moreBooks.
function Calibre:moreBooks(prev_page, offset, num_books)
    local data, err = self:_json{
        path = "/interface-data/more-books",
        method = "POST",
        query = { library_id = self.library_id, num = num_books or 30 },
        body = json.encode{
            query = prev_page.query,
            offset = offset,
            sort = prev_page.sort,
            sort_order = prev_page.sort_order,
            vl = prev_page.vl,
        },
    }
    if not data then return nil, err end
    return parseBookPage(data, "more-books")
end

--- { ids = {...}, titles = {[id]=title}, authors = {[id]={...}} }
function Calibre:newlyAdded(num_books)
    local data, err = self:_json{
        path = "/interface-data/newly-added",
        query = { library_id = self.library_id, num = num_books or 4 },
    }
    if not data then return nil, err end
    if type(data.books) ~= "table" then
        return nil, makeError(ERR.INCOMPATIBLE, "newly-added: no books")
    end
    local out = { ids = {}, titles = {}, authors = {} }
    local titles = type(data.titles) == "table" and data.titles or {}
    local authors = type(data.authors) == "table" and data.authors or {}
    for _, id in ipairs(data.books) do
        id = tonumber(id)
        if id then
            table.insert(out.ids, id)
            out.titles[id] = str(titles[tostring(id)]) or _("Unknown")
            out.authors[id] = list(authors[tostring(id)])
        end
    end
    return out
end

-- Same escaping/exact-match rule as calibre's category_browse_search_expression.
local function exactSearch(field, name)
    return string.format('%s:"=%s"', field, (name:gsub("\\", "\\\\"):gsub('"', '\\"')))
end

--- Fallback for servers without browse-field (e.g. calibre 7.x): names only, no counts.
function Calibre:_browseFieldNames(field)
    local data, err = self:_json{
        path = "/interface-data/field-names/" .. encodeSegment(field),
        query = { library_id = self.library_id },
    }
    if not data then
        -- Unknown fields give 404 (ValueError) or, on calibre 7.x, a 500 (KeyError).
        if err.kind == ERR.NOT_FOUND or err.kind == ERR.HTTP then
            err = makeError(ERR.INCOMPATIBLE, "field-names/" .. field .. ": " .. tostring(err.detail),
                _("This category is not available in this library."))
        end
        return nil, err
    end
    local items = {}
    for _, name in ipairs(data) do
        if str(name) then
            table.insert(items, { name = name, search = exactSearch(field, name) })
        end
    end
    return items
end

--- Items of a browse field: { {name, count|nil, search}, ... }
function Calibre:browseField(field)
    if self.no_browse_field then
        return self:_browseFieldNames(field)
    end
    local data, err = self:_json{
        path = "/interface-data/browse-field/" .. encodeSegment(field),
        query = { library_id = self.library_id },
    }
    if not data then
        if err.kind == ERR.NOT_FOUND and (err.detail or ""):find("is not a browse field", 1, true) then
            return nil, makeError(ERR.INCOMPATIBLE, err.detail, _("This category is not available in this library."))
        elseif err.kind == ERR.NOT_FOUND then
            -- Route added in recent calibre (empty 404 body); older servers lack it.
            logger.info("CalibreShelf: browse-field unavailable, using field-names fallback")
            self.no_browse_field = true
            return self:_browseFieldNames(field)
        end
        return nil, err
    end
    if type(data.items) ~= "table" then
        return nil, makeError(ERR.INCOMPATIBLE, "browse-field: no items")
    end
    local items = {}
    for _, it in ipairs(data.items) do
        if type(it) == "table" and str(it.name) and str(it.search) then
            table.insert(items, { name = it.name, count = num(it.count), search = it.search })
        end
    end
    return items
end

--- Full metadata of one book (normalized).
function Calibre:bookMetadata(book_id)
    local data, err = self:_json{
        path = "/interface-data/book-metadata/" .. encodeSegment(book_id),
        query = { library_id = self.library_id },
    }
    if not data then return nil, err end
    return Calibre.normalizeBook(book_id, data)
end

local function fetchImage(self, path, query, context)
    local code, headers, status, body = self:_rawRequest{ path = path, query = query }
    if code ~= 200 then
        return nil, self:_httpError(code, headers, status, body, context)
    end
    if not body or #body == 0 then
        return nil, makeError(ERR.HTTP, context .. ": empty image")
    end
    return body
end

--- JPEG bytes of a thumbnail scaled by the server to fit w x h pixels.
function Calibre:fetchThumbnail(book_id, w, h)
    return fetchImage(self,
        "/get/thumb/" .. encodeSegment(book_id) .. "/" .. encodeSegment(self.library_id or ""),
        { sz = string.format("%dx%d", w, h) },
        "thumb " .. book_id)
end

--- Full-size cover JPEG bytes (details page only; never cached).
function Calibre:fetchCover(book_id)
    return fetchImage(self,
        "/get/cover/" .. encodeSegment(book_id) .. "/" .. encodeSegment(self.library_id or ""),
        nil, "cover " .. book_id)
end

--- Filename from Content-Disposition (prefers RFC 6266 filename*), or nil.
function Calibre.filenameFromHeaders(headers)
    local cd = headers and headers["content-disposition"]
    if not cd then return nil end
    local encoded = cd:match("filename%*%s*=%s*[Uu][Tt][Ff]%-8''([^;]+)")
    if encoded then
        return util.urlDecode(util.trim(encoded))
    end
    return cd:match('filename%s*=%s*"([^"]+)"') or cd:match("filename%s*=%s*([^;]+)")
end

--[[--
Download one format to `dest_path` (caller supplies a temporary path and renames
on success). Returns headers on success, or nil, err.
]]
function Calibre:downloadFormat(book_id, fmt, dest_path)
    local handle, open_err = io.open(dest_path, "wb")
    if not handle then
        return nil, makeError(ERR.DISK, "open " .. dest_path .. ": " .. tostring(open_err))
    end
    -- Plain file sink like opds.koplugin: socketutil.file_sink would enforce
    -- FILE_TOTAL_TIMEOUT (60 s) on the whole transfer and abort large books.
    local write_failed
    local sink = function(chunk)
        if not chunk then
            handle:close()
            return 1
        end
        local ok, werr = handle:write(chunk)
        if not ok then
            write_failed = werr or "write failed"
            return nil, write_failed
        end
        return 1
    end
    local path = "/get/" .. encodeSegment(fmt:upper()) .. "/" .. encodeSegment(book_id)
        .. "/" .. encodeSegment(self.library_id or "")
    local code, headers, status = self:_rawRequest{ path = path, sink = sink, timeout = "file" }
    pcall(handle.close, handle) -- file_sink usually closed it already
    if code == 200 and not write_failed then
        return headers or {}
    end
    -- Error bodies were written to the file; read a little back for classification.
    local body = ""
    local f = io.open(dest_path, "rb")
    if f then body = f:read(512) or ""; f:close() end
    os.remove(dest_path)
    if write_failed then
        return nil, makeError(ERR.DISK, "write " .. dest_path .. ": " .. tostring(write_failed))
    end
    if code == 404 and body:find("No ", 1, true) and body:find("format", 1, true) then
        return nil, makeError(ERR.NOT_FOUND, path .. " " .. body,
            _("This format is no longer available for the book."))
    end
    return nil, self:_httpError(code, headers, status, body, "GET " .. path)
end

return Calibre
