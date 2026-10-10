--[[--
Server setup screen: URL, credentials, Test connection, library selection,
download folder, preferred format order, cache clearing.

@module calibreshelf.screens.settings
]]

local Button = require("ui/widget/button")
local ButtonDialog = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Geom = require("ui/geometry")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local NetworkMgr = require("ui/network/manager")
local SortWidget = require("ui/widget/sortwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen
local _ = require("gettext")
local T = require("ffi/util").template

local csrequire = require("calibreshelf/require")
local Calibre = csrequire("api/calibre")
local Common = csrequire("widgets/common")
local Store = csrequire("lib/store")

-- Formats offered in the preference list (KOReader can open all of these).
local KNOWN_FORMATS = { "EPUB", "KEPUB", "AZW3", "MOBI", "PDF", "FB2", "CBZ", "DJVU", "DOCX", "RTF", "TXT", "HTML" }

local SettingsScreen = Common.Page:extend{
    plugin = nil,
}

function SettingsScreen:init()
    self:initPage()
    self.status = nil -- result line under Test connection
    self:rebuild()
end

function SettingsScreen:rebuild()
    local plugin = self.plugin
    local server = plugin.server
    local W = self.dimen.w
    local S = Common.S

    local function row(label, value, callback, enabled)
        return Common.Row:new{ width = W, label = label, value = value, callback = callback, enabled = enabled ~= false }
    end

    local content = VerticalGroup:new{
        align = "left",
        Common.header{
            width = W,
            title = _("Calibre server"),
            show_parent = self,
            actions = { { icon = "close", callback = function() self:onClose() end, allow_flash = false } },
        },
        Common.section(W, _("Server")),
        row(_("Server address"), server.url or _("Not set"), function() self:editField("url") end),
        row(_("Username"), server.username or _("None"), function() self:editField("username") end),
        row(_("Password"), (server.password and server.password ~= "") and "••••••" or _("None"),
            function() self:editField("password") end),
        VerticalSpan:new{ width = S.gap * 2 },
        CenterContainer:new{
            dimen = Geom:new{ w = W, h = S.row_h },
            Button:new{
                -- Result is shown in the label itself so the page height never changes.
                text = self.status or _("Test connection"),
                width = W - 2 * S.margin,
                text_font_size = 22,
                bordersize = Screen:scaleBySize(2),
                radius = Screen:scaleBySize(10),
                padding_v = S.gap,
                enabled = plugin:isConfigured(),
                callback = function() self:testConnection() end,
                show_parent = self,
            },
        },
    }
    table.insert(content, Common.section(W, _("Library")))
    table.insert(content, row(_("Calibre library"),
        server.library_name or server.library_id or _("Default"),
        function() self:chooseLibrary() end, plugin:isConfigured()))

    table.insert(content, Common.section(W, _("Downloads")))
    table.insert(content, row(_("Download folder"), plugin:getDownloadDir(), function() self:chooseDownloadDir() end))
    table.insert(content, row(_("Preferred formats"), table.concat(plugin.formats, ", "), function() self:editFormats() end))

    table.insert(content, row(_("Clear CalibreShelf cache"), nil, function() self:clearCache() end))

    table.insert(content, VerticalSpan:new{ width = S.gap * 2 })
    table.insert(content, CenterContainer:new{
        dimen = Geom:new{ w = W, h = S.row_h },
        Button:new{
            text = _("Open library"),
            width = W - 2 * S.margin,
            text_font_size = 22,
            bordersize = 0,
            radius = Screen:scaleBySize(10),
            padding_v = S.gap,
            background = Common.LIGHT,
            enabled = plugin:isConfigured(),
            callback = function()
                self:onClose()
                plugin:showLibrary()
            end,
            show_parent = self,
        },
    })

    if self[1] then self[1]:free() end
    self[1] = self:wrap(content)
    UIManager:setDirty(self, "ui")
end

function SettingsScreen:editField(field)
    local server = self.plugin.server
    local titles = {
        url = _("Server address"),
        username = _("Username"),
        password = _("Password"),
    }
    local hints = {
        url = "http://192.168.1.10:8080",
        username = _("Leave empty if not required"),
        password = _("Leave empty if not required"),
    }
    local dialog
    dialog = InputDialog:new{
        title = titles[field],
        input = server[field] or "",
        input_hint = hints[field],
        input_type = field == "url" and "string" or nil,
        text_type = field == "password" and "password" or nil,
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    local value = dialog:getInputText()
                    if field == "url" then
                        local normalized = Calibre.normalizeUrl(value)
                        if value ~= "" and not normalized then
                            UIManager:show(InfoMessage:new{ text = _("Please enter an address like http://192.168.1.10:8080") })
                            return
                        end
                        if normalized ~= server.url then
                            -- New server: library ids from the old one are meaningless.
                            server.library_id, server.library_name = nil, nil
                        end
                        value = normalized
                    elseif value == "" then
                        value = nil
                    end
                    UIManager:close(dialog)
                    server[field] = value
                    self.status = nil
                    self.plugin:saveSettings()
                    self:rebuild()
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- Run fn(client) when online, with a "Connecting…" message shown meanwhile.
function SettingsScreen:withConnection(fn)
    NetworkMgr:runWhenOnline(function()
        local info = InfoMessage:new{ text = _("Connecting to Calibre…") }
        UIManager:show(info)
        UIManager:forceRePaint()
        local result, err = self.plugin:getClient():libraryInfo()
        UIManager:close(info)
        fn(result, err)
    end)
end

local function sortedLibraries(map)
    local libs = {}
    for id, name in pairs(map) do
        table.insert(libs, { id = id, name = type(name) == "string" and name or id })
    end
    table.sort(libs, function(a, b) return a.name:lower() < b.name:lower() end)
    return libs
end

function SettingsScreen:applyLibraryInfo(info)
    local server = self.plugin.server
    self.libraries = sortedLibraries(info.library_map)
    if not (server.library_id and info.library_map[server.library_id]) then
        server.library_id = info.default_library or (self.libraries[1] and self.libraries[1].id)
    end
    server.library_name = server.library_id and info.library_map[server.library_id] or nil
    self.plugin:saveSettings()
end

function SettingsScreen:testConnection()
    self:withConnection(function(info, err)
        if not info then
            self.status = _("✕ Not connected · tap to retry")
            UIManager:show(InfoMessage:new{ text = err.message })
        else
            self:applyLibraryInfo(info)
            local n = #self.libraries
            self.status = n > 1
                and T(_("✓ Connected · %1 libraries available"), n)
                or _("✓ Connected")
        end
        self:rebuild()
    end)
end

function SettingsScreen:chooseLibrary()
    local function show()
        local server = self.plugin.server
        local dialog
        local buttons = {}
        for _, lib in ipairs(self.libraries) do
            table.insert(buttons, {{
                text = lib.name .. (lib.id == server.library_id and "  ✓" or ""),
                callback = function()
                    UIManager:close(dialog)
                    server.library_id, server.library_name = lib.id, lib.name
                    self.plugin:saveSettings()
                    self:rebuild()
                end,
            }})
        end
        dialog = ButtonDialog:new{ title = _("Calibre library"), buttons = buttons }
        UIManager:show(dialog)
    end
    if self.libraries then
        show()
        return
    end
    self:withConnection(function(info, err)
        if not info then
            UIManager:show(InfoMessage:new{ text = err.message })
            return
        end
        self:applyLibraryInfo(info)
        self:rebuild()
        show()
    end)
end

function SettingsScreen:chooseDownloadDir()
    require("ui/downloadmgr"):new{
        onConfirm = function(path)
            self.plugin.settings:saveSetting("download_dir", path)
            self.plugin:saveSettings()
            UIManager:nextTick(function() self:rebuild() end)
        end,
    }:chooseDir(self.plugin:getDownloadDir())
end

function SettingsScreen:editFormats()
    local plugin = self.plugin
    local enabled, items, seen = {}, {}, {}
    for _, f in ipairs(plugin.formats) do enabled[f] = true end
    local order = plugin.settings:readSetting("format_order") or {}
    local function add(f)
        if seen[f] then return end
        seen[f] = true
        table.insert(items, {
            text = f,
            fmt = f,
            checked_func = function() return enabled[f] end,
            callback = function() enabled[f] = not enabled[f] end,
        })
    end
    for _, f in ipairs(plugin.formats) do add(f) end
    for _, f in ipairs(order) do add(f) end
    for _, f in ipairs(KNOWN_FORMATS) do add(f) end

    UIManager:show(SortWidget:new{
        title = _("Preferred formats (top first)"),
        item_table = items,
        callback = function()
            local formats, full = {}, {}
            for _, it in ipairs(items) do
                table.insert(full, it.fmt)
                if enabled[it.fmt] then table.insert(formats, it.fmt) end
            end
            if #formats == 0 then formats = { "EPUB" } end
            plugin.formats = formats
            plugin.settings:saveSetting("format_order", full)
            plugin:saveSettings()
            self:rebuild()
        end,
    })
end

function SettingsScreen:clearCache()
    UIManager:show(ConfirmBox:new{
        text = _("Clear cached covers and catalog data?\n\nDownloaded books are not affected."),
        ok_text = _("Clear"),
        ok_callback = function()
            Store.clearCache()
            UIManager:show(InfoMessage:new{ text = _("CalibreShelf cache cleared."), timeout = 2 })
        end,
    })
end

return SettingsScreen
