--[[--
CalibreShelf: a native e-ink client for Calibre Content Server.

Browse, search and download books from a remote Calibre library.

@module koplugin.CalibreShelf
]]

-- Root-anchored module loader. KOReader appends every plugin dir to
-- package.path, so plain require("screens/settings") could resolve to another
-- plugin's file. Our modules load via csrequire("screens/settings") instead and
-- are cached under a "calibreshelf/" prefix in package.loaded.
local plugin_root = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or "."
local function csrequire(name)
    local key = "calibreshelf/" .. name
    local mod = package.loaded[key]
    if mod == nil then
        mod = dofile(plugin_root .. "/" .. name .. ".lua")
        package.loaded[key] = mod
    end
    return mod
end
package.loaded["calibreshelf/require"] = csrequire

local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local LuaSettings = require("luasettings")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")

local Calibre = csrequire("api/calibre")
local Downloader = csrequire("lib/downloader")
local Downloads = csrequire("lib/downloads")

local DEFAULT_FORMATS = { "EPUB", "AZW3", "MOBI", "PDF" }

local CalibreShelf = WidgetContainer:extend{
    name = "calibreshelf",
    is_doc_only = false,
}

function CalibreShelf:init()
    self.plugin_root = plugin_root
    self:loadSettings()
    self.downloads = Downloads:new(self.settings)
    self.downloader = Downloader:new(self.downloads)
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function CalibreShelf:loadSettings()
    if self.settings then return end
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/calibreshelf.lua")
    self.server = self.settings:readSetting("server", {})
    self.formats = self.settings:readSetting("formats", { unpack(DEFAULT_FORMATS) })
    self.sort = self.settings:readSetting("sort", { field = "timestamp", order = "desc" })
end

--- Persist settings now (small file; written on change, not on every repaint).
function CalibreShelf:saveSettings()
    self.settings:saveSetting("server", self.server)
    self.settings:saveSetting("formats", self.formats)
    self.settings:saveSetting("sort", self.sort)
    self.settings:flush()
end

function CalibreShelf:isConfigured()
    return self.server.url ~= nil and self.server.url ~= ""
end

function CalibreShelf:getDownloadDir()
    -- Device.home_dir is /mnt/us on Kindle (KOReader frontend/device/kindle/device.lua).
    return self.settings:readSetting("download_dir")
        or G_reader_settings:readSetting("home_dir")
        or Device.home_dir
        or DataStorage:getFullDataDir()
end

--- Backend client for the configured server (cheap; create per use).
function CalibreShelf:getClient()
    return Calibre:new(self:clientOptions())
end

function CalibreShelf:clientOptions()
    return {
        url = self.server.url,
        username = self.server.username,
        password = self.server.password,
        library_id = self.server.library_id,
    }
end

-- Local path of a downloaded copy of `book`, if any (preferred formats first).
function CalibreShelf:downloadedPath(book)
    return self.downloads:find(Calibre.normalizeUrl(self.server.url), self.server.library_id, book, self.formats)
end

-- Queue one book. `extra` may set replace_path, on_conflict, on_done.
function CalibreShelf:downloadBook(book, fmt, extra)
    local job = {
        book = book,
        fmt = fmt,
        dir = self:getDownloadDir(),
        client_opts = self:clientOptions(),
        server_key = Calibre.normalizeUrl(self.server.url),
        library_id = self.server.library_id,
    }
    for k, v in pairs(extra or {}) do job[k] = v end
    return self.downloader:enqueue(job)
end

function CalibreShelf:onDispatcherRegisterActions()
    Dispatcher:registerAction("calibreshelf_show", {
        category = "none", event = "ShowCalibreShelf", title = _("CalibreShelf library"), general = true,
    })
end

function CalibreShelf:addToMainMenu(menu_items)
    menu_items.calibreshelf = {
        text = _("CalibreShelf"),
        sorting_hint = "search",
        sub_item_table = {
            {
                text = _("Open Calibre library"),
                callback = function() self:onShowCalibreShelf() end,
            },
            {
                text = _("Server settings"),
                callback = function() self:showSettings() end,
            },
        },
    }
end

function CalibreShelf:onShowCalibreShelf()
    if not self:isConfigured() then
        self:showSettings()
        return true
    end
    self:showLibrary()
    return true
end

function CalibreShelf:showLibrary()
    local LibraryScreen = csrequire("screens/library")
    if self.library_screen then UIManager:close(self.library_screen) end
    self.library_screen = LibraryScreen:new{
        plugin = self,
        close_callback = function() self.library_screen = nil end,
    }
    UIManager:show(self.library_screen)
end

function CalibreShelf:showSettings()
    local SettingsScreen = csrequire("screens/settings")
    UIManager:show(SettingsScreen:new{ plugin = self })
end

--- Open a local file in KOReader (used by "Open" / "Open now").
function CalibreShelf:openFile(path)
    if self.library_screen then
        self.library_screen:onClose()
    end
    logger.info("CalibreShelf: opening", path)
    if self.ui.document then
        self.ui:switchDocument(path)
    else
        self.ui:openFile(path)
    end
end

function CalibreShelf:onFlushSettings()
    if self.settings then self.settings:flush() end
end

return CalibreShelf
