-- ZenOS Home widget, registered only through ZenOS's public API
-- (__ZENOS_REGISTER_HOME_ITEM). The builder runs on every Home render, so it
-- only reads saved state; network refreshes happen elsewhere and re-register
-- the item to make ZenOS redraw it.
--
-- State (plugin settings "home"):
--   { library_name, total, recent = { {id, title, author, thumb}, ... }, updated }

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local NetworkMgr = require("ui/network/manager")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local Screen = Device.screen
local _ = require("gettext")
local T = require("ffi/util").template

local csrequire = require("calibreshelf/require")
local Common = csrequire("widgets/common")
local Store = csrequire("lib/store")

local ZenHome = {
    ID = "calibreshelf.home",
    MAX_COVERS = 4,
    STALE_AFTER = 3600, -- seconds between background refreshes
    THUMB_W = 180,
    THUMB_H = 270,
}

local function registerFn()
    local fn = rawget(_G, "__ZENOS_REGISTER_HOME_ITEM") or rawget(_G, "__ZEN_UI_REGISTER_HOME_ITEM")
    return type(fn) == "function" and fn or nil
end

function ZenHome.available()
    return registerFn() ~= nil
end

local Tile = InputContainer:extend{
    width = nil,
    height = nil,
    callback = nil,
}

function Tile:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self.ges_events.Tap = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } }
end

function Tile:onTap()
    if self.callback then self.callback() end
    return true
end

local function placeholder(w, h, title)
    return FrameContainer:new{
        width = w,
        height = h,
        padding = 0,
        bordersize = Screen:scaleBySize(1),
        color = Blitbuffer.COLOR_LIGHT_GRAY,
        background = Common.LIGHT,
        CenterContainer:new{
            dimen = Geom:new{ w = w - 2, h = h - 2 },
            TextBoxWidget:new{
                text = title or "",
                face = Common.F.tiny,
                width = w - Screen:scaleBySize(8),
                height = h - Screen:scaleBySize(8),
                height_overflow_show_ellipsis = true,
                alignment = "center",
                bgcolor = Common.LIGHT,
            },
        },
    }
end

local function cover(book, w, h)
    if book.thumb and lfs.attributes(book.thumb, "mode") == "file" then
        return CenterContainer:new{
            dimen = Geom:new{ w = w, h = h },
            ImageWidget:new{
                file = book.thumb,
                file_do_cache = false,
                width = w,
                height = h,
                scale_factor = 0,
            },
        }
    end
    return placeholder(w, h, book.title)
end

function ZenHome.build(plugin, ctx)
    local w, h = ctx.width, ctx.height
    local state = plugin.settings:readSetting("home") or {}
    local face_title = ctx.face_title or Common.F.heading
    local face_label = ctx.face_label or Common.F.small

    local status
    if not plugin:isConfigured() then
        status = _("Tap to set up your Calibre server")
    elseif state.total then
        status = T(_("%1 · %2 books"), state.library_name or _("Library"), state.total)
    else
        status = _("Tap to open your library")
    end
    local gap = Common.S.gap
    local recent = state.recent or {}
    local n = math.min(#recent, ZenHome.MAX_COVERS)
    -- Covers fill the tile height on the right; text sits on the left.
    local cover_h = h - 2 * gap
    local cover_w = math.floor(cover_h * 2 / 3)
    local covers_w = n > 0 and (n * cover_w + (n - 1) * gap) or 0
    local max_covers_w = math.floor(w * 0.62)
    if covers_w > max_covers_w then
        cover_w = math.floor((max_covers_w - (n - 1) * gap) / n)
        cover_h = math.floor(cover_w * 3 / 2)
        covers_w = n * cover_w + (n - 1) * gap
    end
    local text_w = w - covers_w - 3 * gap
    local head = VerticalGroup:new{
        align = "left",
        TextWidget:new{ text = _("Calibre"), face = face_title, max_width = text_w },
        VerticalSpan:new{ width = math.floor(gap / 2) },
        TextBoxWidget:new{ text = status, face = face_label, fgcolor = Common.GRAY, width = text_w },
    }
    local row = HorizontalGroup:new{
        align = "center",
        HorizontalSpan:new{ width = gap },
        LeftContainer:new{ dimen = Geom:new{ w = text_w, h = h }, head },
    }
    if n > 0 and cover_h > Screen:scaleBySize(40) then
        table.insert(row, HorizontalSpan:new{ width = gap })
        for i = 1, n do
            if i > 1 then table.insert(row, HorizontalSpan:new{ width = gap }) end
            table.insert(row, cover(recent[i], cover_w, cover_h))
        end
    end
    local content = row

    return Tile:new{
        width = w,
        height = h,
        callback = function() plugin:onShowCalibreShelf() end,
        LeftContainer:new{ dimen = Geom:new{ w = w, h = h }, content },
    }
end

function ZenHome.register(plugin)
    local register = registerFn()
    if not register then return false end
    local ok, res = pcall(register, ZenHome.ID, function(ctx)
        return ZenHome.build(plugin, ctx)
    end, { label = _("Calibre"), size = "m" })
    if not ok then
        logger.warn("CalibreShelf: ZenOS register failed", res)
        return false
    end
    logger.info("CalibreShelf: ZenOS home widget registered", res ~= false)
    return res ~= false
end

--- Save new Home state from a page of books (newest first) and redraw the widget.
-- `books` are normalized books; `thumb_for(book)` returns a cached thumbnail path.
function ZenHome.update(plugin, total, books, thumb_for)
    local recent = {}
    for i = 1, math.min(#books, ZenHome.MAX_COVERS) do
        local b = books[i]
        table.insert(recent, { id = b.id, title = b.title, author = b.authors[1], thumb = thumb_for(b) })
    end
    plugin.settings:saveSetting("home", {
        library_name = plugin.server.library_name,
        total = total,
        recent = recent,
        updated = os.time(),
    })
    plugin.settings:flush()
    if ZenHome.available() then ZenHome.register(plugin) end
end

--- Background refresh: newest books and their thumbnails. Never prompts for Wi-Fi.
function ZenHome.refresh(plugin, force)
    if not plugin:isConfigured() or not NetworkMgr:isConnected() then return end
    local state = plugin.settings:readSetting("home") or {}
    if not force and state.updated and os.time() - state.updated < ZenHome.STALE_AFTER then return end
    local client = plugin:getClient()
    local page, err = client:getBooks{ sort = "timestamp", order = "desc", num = ZenHome.MAX_COVERS }
    if not page then
        logger.info("CalibreShelf: home refresh skipped", err and err.kind)
        return
    end
    local books = {}
    for _i, id in ipairs(page.ids) do table.insert(books, page.books[id]) end
    local server_key, library_id = client:serverKey(), client.library_id
    ZenHome.update(plugin, page.total, books, function(book)
        local path = Store.thumbPath(server_key, library_id, book, ZenHome.THUMB_W, ZenHome.THUMB_H)
        if not lfs.attributes(path) then
            local data = client:fetchThumbnail(book.id, ZenHome.THUMB_W, ZenHome.THUMB_H)
            if data then Store.writeFile(path, data) end
        end
        return path
    end)
end

--- Schedule a refresh shortly after startup so it never delays the Home page.
function ZenHome.scheduleRefresh(plugin)
    UIManager:scheduleIn(5, function() ZenHome.refresh(plugin) end)
end

return ZenHome
