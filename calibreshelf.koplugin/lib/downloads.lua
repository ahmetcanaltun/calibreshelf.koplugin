-- Persistent map of downloaded books: server|library|book_id|FORMAT -> local path.
-- Stored in the plugin settings file under "downloaded".

local DocumentRegistry = require("document/documentregistry")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")

local Downloads = {}
Downloads.__index = Downloads

function Downloads:new(settings)
    return setmetatable({
        settings = settings,
        map = settings:readSetting("downloaded", {}),
    }, self)
end

local function key(server_key, library_id, book_id, fmt)
    return table.concat({ server_key, library_id or "", tostring(book_id), fmt:upper() }, "|")
end

function Downloads:get(server_key, library_id, book_id, fmt)
    local path = self.map[key(server_key, library_id, book_id, fmt)]
    if path and lfs.attributes(path, "mode") == "file" then
        return path
    end
end

-- First downloaded format of a book that still exists on disk, in the given order.
function Downloads:find(server_key, library_id, book, formats)
    for _i, fmt in ipairs(formats or book.formats) do
        local path = self:get(server_key, library_id, book.id, fmt)
        if path then return path, fmt end
    end
    for _i, fmt in ipairs(book.formats) do
        local path = self:get(server_key, library_id, book.id, fmt)
        if path then return path, fmt end
    end
end

function Downloads:record(server_key, library_id, book_id, fmt, path)
    self.map[key(server_key, library_id, book_id, fmt)] = path
    self.settings:saveSetting("downloaded", self.map)
    self.settings:flush()
end

function Downloads:forget(server_key, library_id, book_id, fmt)
    self.map[key(server_key, library_id, book_id, fmt)] = nil
    self.settings:saveSetting("downloaded", self.map)
    self.settings:flush()
end

function Downloads.canOpen(fmt)
    return DocumentRegistry:hasProvider("x." .. fmt:lower()) and true or false
end

-- Preferred format the book has, else the first one KOReader can open.
function Downloads.pickFormat(book, preferred)
    local have = {}
    for _i, f in ipairs(book.formats) do have[f] = true end
    for _i, f in ipairs(preferred or {}) do
        if have[f] then return f end
    end
    for _i, f in ipairs(book.formats) do
        if Downloads.canOpen(f) then return f end
    end
end

-- "Author - Title.ext", used when the server sends no usable filename.
function Downloads.metadataFilename(book, fmt)
    local name = book.title
    if book.authors[1] then
        name = book.authors[1] .. " - " .. name
    end
    return name .. "." .. fmt:lower()
end

function Downloads.finalPath(dir, filename, book, fmt)
    local ext = "." .. fmt:lower()
    if not filename or filename == "" or not filename:lower():find(ext, -#ext, true) then
        filename = Downloads.metadataFilename(book, fmt)
    end
    filename = util.getSafeFilename(filename, dir)
    return (dir:gsub("/+$", "")) .. "/" .. filename
end

function Downloads.tempPath(dir, book, fmt)
    return string.format("%s/.calibreshelf-%d.%s.part", (dir:gsub("/+$", "")), book.id, fmt:lower())
end

return Downloads
