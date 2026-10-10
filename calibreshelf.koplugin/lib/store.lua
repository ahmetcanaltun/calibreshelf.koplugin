-- On-disk cache: sized thumbnails and the last viewed catalog, under
-- <data dir>/cache/calibreshelf. Full-size covers are never cached.

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local bit = require("bit")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")

local Store = {
    MAX_THUMBS = 800, -- ~20-30 MB of small JPEGs
    MAX_CATALOG_BOOKS = 240,
    MAX_COMMENTS = 3000,
}

Store.root = DataStorage:getDataDir() .. "/cache/calibreshelf"

-- Short stable hash (djb2, hex) for building file names from URLs/ids.
function Store.hash(s)
    local h = 5381
    s = tostring(s or "")
    for i = 1, #s do
        h = bit.band(bit.lshift(h, 5) + h + s:byte(i), 0x7fffffff)
    end
    return string.format("%08x", h)
end

local function ensureDir(path)
    if not util.directoryExists(path) then
        util.makePath(path)
    end
    return path
end

function Store.thumbDir(server_key)
    return ensureDir(Store.root .. "/thumbs/" .. Store.hash(server_key))
end

function Store.thumbPath(server_key, library_id, book, w, h)
    return string.format("%s/%s_%d_%dx%d_%s.jpg", Store.thumbDir(server_key),
        Store.hash(library_id), book.id, w, h, Store.hash(book.last_modified))
end

function Store.readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

-- Write atomically: tmp file then rename.
function Store.writeFile(path, data)
    local tmp = path .. ".tmp"
    local f = io.open(tmp, "wb")
    if not f then return false end
    local ok = f:write(data)
    f:close()
    if not ok then
        os.remove(tmp)
        return false
    end
    return os.rename(tmp, path)
end

local function catalogPath(server_key, library_id)
    return ensureDir(Store.root) .. "/catalog-" .. Store.hash(server_key) .. "-" .. Store.hash(library_id) .. ".lua"
end

-- Save the last viewed listing so it can be browsed offline.
-- listing = { query = {...}, total = n, ids = {...}, books = {[id] = book} }
function Store.saveCatalog(server_key, library_id, listing)
    local ids, books = {}, {}
    for i = 1, math.min(#listing.ids, Store.MAX_CATALOG_BOOKS) do
        local id = listing.ids[i]
        local book = listing.books[id]
        if book then
            local copy = {}
            for k, v in pairs(book) do copy[k] = v end
            if copy.comments and #copy.comments > Store.MAX_COMMENTS then
                copy.comments = copy.comments:sub(1, Store.MAX_COMMENTS) .. "…"
            end
            table.insert(ids, id)
            books[id] = copy
        end
    end
    local settings = LuaSettings:open(catalogPath(server_key, library_id))
    settings:reset{
        query = listing.query,
        total = listing.total,
        ids = ids,
        books = books,
        saved = os.time(),
    }
    settings:flush()
end

function Store.loadCatalog(server_key, library_id)
    local path = catalogPath(server_key, library_id)
    if not lfs.attributes(path) then return nil end
    local data = LuaSettings:open(path).data
    if type(data) ~= "table" or type(data.ids) ~= "table" or #data.ids == 0 then return nil end
    return data
end

-- Delete oldest thumbnails beyond MAX_THUMBS (cheap: one directory scan).
function Store.pruneThumbs()
    local base = Store.root .. "/thumbs"
    if not util.directoryExists(base) then return end
    local files = {}
    for server in lfs.dir(base) do
        if server ~= "." and server ~= ".." then
            local dir = base .. "/" .. server
            if lfs.attributes(dir, "mode") == "directory" then
                for name in lfs.dir(dir) do
                    local p = dir .. "/" .. name
                    if name:match("%.jpg$") then
                        table.insert(files, { path = p, t = lfs.attributes(p, "access") or 0 })
                    end
                end
            end
        end
    end
    if #files <= Store.MAX_THUMBS then return end
    table.sort(files, function(a, b) return a.t < b.t end)
    for i = 1, #files - Store.MAX_THUMBS do
        os.remove(files[i].path)
    end
    logger.info("CalibreShelf: pruned", #files - Store.MAX_THUMBS, "thumbnails")
end

local function removeTree(path)
    if lfs.attributes(path, "mode") ~= "directory" then
        os.remove(path)
        return
    end
    for name in lfs.dir(path) do
        if name ~= "." and name ~= ".." then
            removeTree(path .. "/" .. name)
        end
    end
    lfs.rmdir(path)
end

-- "Clear CalibreShelf cache": thumbnails and cached catalog metadata.
-- The downloaded-books map lives in settings and is NOT touched.
function Store.clearCache()
    removeTree(Store.root)
    logger.info("CalibreShelf: cache cleared")
end

return Store
