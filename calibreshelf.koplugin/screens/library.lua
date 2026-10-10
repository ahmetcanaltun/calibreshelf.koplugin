--[[--
Full-screen cover grid of the remote Calibre library.

Data flow: books are fetched page-by-page from the server (get-books, then
more-books with an offset) and kept as an ordered id list plus a small
normalized-metadata map. Only the visible page has widgets; cover BlitBuffers
of the previous page are freed on page turn.

E-ink: one refresh for the page, then covers are filled in from the disk cache
(sync, one refresh) and from the network one per UI tick, refreshed in
row-sized batches with "ui" + dithering. A "full" refresh is done every
FULL_REFRESH_EVERY page turns to clear ghosting.

@module calibreshelf.screens.library
]]

local Button = require("ui/widget/button")
local ButtonDialog = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconButton = require("ui/widget/iconbutton")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local Notification = require("ui/widget/notification")
local NetworkMgr = require("ui/network/manager")
local OverlapGroup = require("ui/widget/overlapgroup")
local RenderImage = require("ui/renderimage")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Blitbuffer = require("ffi/blitbuffer")
local logger = require("logger")
local util = require("util")
local Screen = Device.screen
local _ = require("gettext")
local T = require("ffi/util").template

local csrequire = require("calibreshelf/require")
local BookCard = csrequire("widgets/bookcard")
local Calibre = csrequire("api/calibre")
local Common = csrequire("widgets/common")
local Downloads = csrequire("lib/downloads")
local Store = csrequire("lib/store")

local FULL_REFRESH_EVERY = 6

local SORT_LABELS = {
    timestamp = _("Date added"),
    title = _("Title"),
    authors = _("Author"),
    series = _("Series"),
}

local LibraryScreen = Common.Page:extend{
    plugin = nil,
}

function LibraryScreen:init()
    self:initPage()
    self.client = self.plugin:getClient()
    self.server_key = self.client:serverKey()
    self.library_id = self.plugin.server.library_id
    self.query = {
        search = "",
        sort = self.plugin.sort.field,
        order = self.plugin.sort.order,
        title = self.plugin.server.library_name or _("Library"),
        tab = "all",
    }
    self.browse_cache = {}
    self.initial_load = true -- the saved catalog may stand in until the first load succeeds
    self.page = 1
    self.turns = 0
    self.selecting = false
    self.selected = {}
    self.selected_count = 0
    self:resetData()
    self.listener = function(job) self:onJobUpdate(job) end
    self.plugin.downloader:addListener(self.listener)
    self:computeLayout()
    self.ges_events.Tap = { GestureRange:new{ ges = "tap", range = self.dimen } }
    self.ges_events.Hold = { GestureRange:new{ ges = "hold", range = self.dimen } }
    self:build()
    UIManager:nextTick(function() self:goToPage(1) end)
end

function LibraryScreen:resetData()
    self.ids = {}
    self.books = {}
    self.total = nil
    self.last_result = nil
    self.message = nil
end

--- Grid geometry: columns from a target cell width, rows rounded so covers stay ~2:3.
function LibraryScreen:computeLayout()
    local S = Common.S
    local W, H = self.dimen.w, self.dimen.h
    self.show_series = true
    self.header_h = self:buildHeader():getSize().h
    self.footer_h = S.footer_h + S.gap
    local grid_w = W - 2 * S.margin
    local grid_h = H - self.header_h - self.footer_h
    local target_cell = Screen:scaleBySize(130)
    local cols = math.max(2, math.floor((grid_w + S.gap) / (target_cell + S.gap)))
    local cell_w = math.floor((grid_w - (cols - 1) * S.gap) / cols)
    local text_h = BookCard.textHeight(self.show_series)
    -- Aim for ~3 rows on a Paperwhite portrait page; covers then fit each cell.
    local ideal_h = math.floor(cell_w * 1.2) + text_h
    local rows = math.max(1, math.floor((grid_h + S.gap) / (ideal_h + S.gap) + 0.5))
    local cell_h = math.floor((grid_h - (rows - 1) * S.gap) / rows)
    local cover_h = cell_h - text_h
    local cover_w = math.min(cell_w, math.floor(cover_h / 1.5))
    if cover_w < cell_w and cover_h > math.floor(cover_w * 1.5) then
        cover_h = math.floor(cover_w * 1.5)
    end
    self.cols, self.rows = cols, rows
    self.cell_w, self.cell_h = cell_w, cell_h
    self.cover_w, self.cover_h = cover_w, cover_h
    self.per_page = cols * rows
    self.fetch_size = self.per_page * 2
    logger.dbg("CalibreShelf: grid", cols, "x", rows, "cover", cover_w, "x", cover_h)
end

function LibraryScreen:subtitle()
    if self.message then return _("Not connected") end
    if not self.total then return _("Loading…") end
    local count = self.total == 1 and _("1 book") or T(_("%1 books"), self.total)
    if self.offline then count = _("Offline") .. " · " .. count end
    return count .. " · " .. (SORT_LABELS[self.query.sort] or self.query.sort)
        .. (self.query.order == "desc" and " ↓" or " ↑")
end

local TABS = {
    { id = "all", label = _("All") },
    { id = "recent", label = _("Recent") },
    { id = "authors", label = _("Authors") },
    { id = "series", label = _("Series") },
    { id = "tags", label = _("Tags") },
}

function LibraryScreen:buildTabs()
    local S = Common.S
    local inner = self.dimen.w - 2 * S.margin
    local tab_w = math.floor(inner / #TABS)
    local row = HorizontalGroup:new{ HorizontalSpan:new{ width = S.margin } }
    for _i, tab in ipairs(TABS) do
        local active = self.query.tab == tab.id
        table.insert(row, VerticalGroup:new{
            Button:new{
                text = tab.label,
                width = tab_w,
                bordersize = 0,
                text_font_size = 19,
                text_font_bold = active,
                padding_v = math.floor(S.gap / 2),
                callback = function() self:onTab(tab.id) end,
                show_parent = self,
            },
            LineWidget:new{
                dimen = Geom:new{ w = tab_w, h = active and Screen:scaleBySize(3) or S.line },
                background = active and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_LIGHT_GRAY,
            },
        })
    end
    return row
end

function LibraryScreen:buildHeader()
    local top = self:buildTitleBar()
    local tabs = self:buildTabs()
    if self.selecting then
        -- Same height as normal mode so the grid does not move.
        tabs = VerticalSpan:new{ width = tabs:getSize().h }
    end
    return VerticalGroup:new{ align = "left", top, tabs }
end

function LibraryScreen:buildTitleBar()
    if self.selecting then
        return Common.header{
            width = self.dimen.w,
            title = self.selected_count == 1 and _("1 selected") or T(_("%1 selected"), self.selected_count),
            subtitle = _("Tap books to select or deselect"),
            show_parent = self,
            actions = {
                { icon = "close", callback = function() self:exitSelection() end, allow_flash = false },
            },
        }
    end
    return Common.header{
        width = self.dimen.w,
        title = self.query.title,
        subtitle = self:subtitle(),
        show_parent = self,
        actions = {
            { icon = "appbar.search", callback = function() self:showSearch() end },
            { icon = "appbar.menu", callback = function() self:showMenu() end },
            { icon = "close", callback = function() self:onClose() end, allow_flash = false },
        },
    }
end

function LibraryScreen:totalPages()
    if not self.total or self.total == 0 then return 1 end
    return math.ceil(self.total / self.per_page)
end

function LibraryScreen:buildSelectionBar()
    local S = Common.S
    local W = self.dimen.w - 2 * S.margin
    local n = self.selected_count
    local function button(text, callback, primary, width, enabled)
        return Button:new{
            text = text,
            width = width,
            height = S.footer_h - S.gap,
            text_font_size = 20,
            bordersize = primary and Screen:scaleBySize(2) or 0,
            background = (not primary) and Common.LIGHT or nil,
            radius = Screen:scaleBySize(10),
            padding_v = 0,
            enabled = enabled ~= false,
            callback = callback,
            show_parent = self,
        }
    end
    local small = math.floor((W - 2 * S.gap) * 0.27)
    local big = W - 2 * S.gap - 2 * small
    return VerticalGroup:new{
        VerticalSpan:new{ width = S.gap },
        HorizontalGroup:new{
            HorizontalSpan:new{ width = S.margin },
            button(_("Select page"), function() self:selectPage() end, false, small),
            HorizontalSpan:new{ width = S.gap },
            button(_("Clear"), function() self:clearSelection() end, false, small, n > 0),
            HorizontalSpan:new{ width = S.gap },
            button(n == 1 and _("Download 1 book") or T(_("Download %1 books"), n),
                function() self:downloadSelected() end, true, big, n > 0),
        },
    }
end

function LibraryScreen:buildFooter()
    if self.selecting then return self:buildSelectionBar() end
    local S = Common.S
    local W = self.dimen.w
    local pages = self:totalPages()
    local prev = IconButton:new{
        icon = "chevron.left",
        width = S.icon, height = S.icon, padding = S.icon_pad,
        enabled = self.page > 1,
        callback = function() self:onPrevPage() end,
        show_parent = self,
    }
    local nxt = IconButton:new{
        icon = "chevron.right",
        width = S.icon, height = S.icon, padding = S.icon_pad,
        enabled = self.page < pages,
        callback = function() self:onNextPage() end,
        show_parent = self,
    }
    local label = TextWidget:new{
        text = self.total and T(_("Page %1 of %2"), self.page, pages) or "",
        face = Common.F.small,
    }
    local side_w = prev:getSize().w
    return VerticalGroup:new{
        VerticalSpan:new{ width = S.gap },
        HorizontalGroup:new{
            HorizontalSpan:new{ width = S.margin - S.icon_pad },
            prev,
            CenterContainer:new{
                dimen = Geom:new{ w = W - 2 * (S.margin - S.icon_pad) - 2 * side_w, h = S.footer_h },
                label,
            },
            nxt,
        },
    }
end

function LibraryScreen:freeCards()
    for _i, card in ipairs(self.cards or {}) do card:free() end
    self.cards = {}
end

function LibraryScreen:buildGrid()
    local S = Common.S
    local W = self.dimen.w
    local grid_h = self.dimen.h - self.header_h - self.footer_h
    local box = Geom:new{ w = W, h = grid_h }
    self:freeCards()

    if self.message then
        local text = TextBoxWidget:new{
            text = self.message,
            face = Common.F.body,
            width = W - 4 * S.margin,
            alignment = "center",
        }
        return CenterContainer:new{
            dimen = box,
            VerticalGroup:new{
                text,
                VerticalSpan:new{ width = S.gap * 2 },
                Button:new{
                    text = _("Try again"),
                    width = math.floor(W / 2),
                    text_font_size = 22,
                    bordersize = Screen:scaleBySize(2),
                    radius = Screen:scaleBySize(10),
                    padding_v = S.gap,
                    callback = function() self:refresh() end,
                    show_parent = self,
                },
            },
        }
    end

    local first = (self.page - 1) * self.per_page + 1
    local grid = VerticalGroup:new{ align = "left" }
    for r = 1, self.rows do
        local row = HorizontalGroup:new{ HorizontalSpan:new{ width = S.margin } }
        local any = false
        for c = 1, self.cols do
            local id = self.ids[first + (r - 1) * self.cols + (c - 1)]
            local book = id and self.books[id]
            if book then
                any = true
                local card = BookCard:new{
                    book = book,
                    downloaded = self.plugin:downloadedPath(book) ~= nil,
                    selected = self.selected[id] == true,
                    width = self.cell_w,
                    cover_w = self.cover_w,
                    cover_h = self.cover_h,
                    show_series = self.show_series,
                }
                table.insert(self.cards, card)
                table.insert(row, CenterContainer:new{
                    dimen = Geom:new{ w = self.cell_w, h = self.cell_h },
                    card,
                })
            else
                table.insert(row, HorizontalSpan:new{ width = self.cell_w })
            end
            if c < self.cols then table.insert(row, HorizontalSpan:new{ width = S.gap }) end
        end
        if not any then break end
        table.insert(grid, row)
        if r < self.rows then table.insert(grid, VerticalSpan:new{ width = S.gap }) end
    end

    if #self.cards == 0 then
        local empty = self.total == 0
            and (self.query.search ~= "" and _("No books match this search.") or _("This library is empty."))
            or _("Loading…")
        return CenterContainer:new{
            dimen = box,
            TextWidget:new{ text = empty, face = Common.F.body, fgcolor = Common.GRAY },
        }
    end
    return OverlapGroup:new{ dimen = box, grid }
end

function LibraryScreen:build()
    local W = self.dimen.w
    self.header_holder = LeftContainer:new{
        dimen = Geom:new{ w = W, h = self.header_h },
        self:buildHeader(),
    }
    self.footer_holder = LeftContainer:new{
        dimen = Geom:new{ w = W, h = self.footer_h },
        self:buildFooter(),
    }
    self[1] = self:wrap(VerticalGroup:new{
        align = "left",
        self.header_holder,
        self:buildGrid(),
        self.footer_holder,
    })
end

-- Rebuild header and footer only, refreshing just those strips.
function LibraryScreen:updateChrome()
    local W, H = self.dimen.w, self.dimen.h
    self.header_holder[1]:free()
    self.header_holder[1] = self:buildHeader()
    self.footer_holder[1]:free()
    self.footer_holder[1] = self:buildFooter()
    UIManager:setDirty(self, "ui", Geom:new{ x = 0, y = 0, w = W, h = self.header_h })
    UIManager:setDirty(self, "ui", Geom:new{ x = 0, y = H - self.footer_h, w = W, h = self.footer_h })
end

--- Repaint the whole screen; "partial" normally, "full" every few turns.
function LibraryScreen:repaint(force_full)
    self.turns = self.turns + 1
    local mode = (force_full or self.turns % FULL_REFRESH_EVERY == 0) and "full" or "partial"
    UIManager:setDirty(self, mode)
end

---------------------------------------------------------------------------
-- Data loading
---------------------------------------------------------------------------

--- Make sure ids for `page` are loaded, fetching more from the server if needed.
function LibraryScreen:loadCached()
    local data = Store.loadCatalog(self.server_key, self.library_id)
    if not data then return false end
    for k, v in pairs(data.query or {}) do self.query[k] = v end
    self.total = data.total or #data.ids
    self.ids, self.books = data.ids, data.books
    self.last_result = nil
    self.offline = true
    self.message = nil
    logger.info("CalibreShelf: showing saved catalog from", os.date("%Y-%m-%d %H:%M", data.saved or 0))
    return true
end

function LibraryScreen:saveCatalog()
    local ok, err = pcall(Store.saveCatalog, self.server_key, self.library_id, {
        query = self.query, total = self.total, ids = self.ids, books = self.books,
    })
    if not ok then logger.warn("CalibreShelf: could not save catalog", err) end
end

function LibraryScreen:ensureLoaded(page, callback)
    local need = page * self.per_page
    if self.total then need = math.min(need, self.total) end
    if self.total and #self.ids >= need then
        return callback(true)
    end
    if self.offline then
        return callback(false, { message = _("Connect to Wi-Fi to load more books.") })
    end
    if self.initial_load and #self.ids == 0 and not NetworkMgr:isConnected() and self:loadCached() then
        self.initial_load = false
        return callback(true)
    end
    NetworkMgr:runWhenConnected(function()
        local result, err
        while not err and (not self.total or #self.ids < need) do
            if not self.last_result then
                result, err = self.client:getBooks{
                    search = self.query.search,
                    sort = self.query.sort,
                    order = self.query.order,
                    num = math.max(self.fetch_size, need),
                }
            else
                result, err = self.client:moreBooks(self.last_result, #self.ids, self.fetch_size)
            end
            if result then
                self.last_result = result
                self.total = result.total
                for _i, id in ipairs(result.ids) do
                    if not self.books[id] then
                        table.insert(self.ids, id)
                    end
                    self.books[id] = result.books[id]
                end
                need = math.min(need, self.total)
                if #result.ids == 0 then break end -- server has nothing more; avoid looping
            end
        end
        if err then
            logger.warn("CalibreShelf: load failed", err.kind, err.detail)
            local network = err.kind == Calibre.ERR.UNREACHABLE or err.kind == Calibre.ERR.TIMEOUT
            if network and self.initial_load and #self.ids == 0 and self:loadCached() then
                self.initial_load = false
                Notification:notify(_("Server not reachable. Showing saved books."), Notification.SOURCE_ALWAYS_SHOW)
                return callback(true)
            end
            return callback(false, err)
        end
        self.initial_load = false
        self:saveCatalog()
        callback(true)
    end)
end

function LibraryScreen:goToPage(page)
    page = math.max(1, page)
    if self.total then page = math.min(page, self:totalPages()) end
    self:ensureLoaded(page, function(ok, err)
        if not ok then
            if #self.ids == 0 then
                self.message = err.message
                self:build()
                self:repaint()
            else
                UIManager:show(InfoMessage:new{ text = err.message, timeout = 4 })
            end
            return
        end
        self.message = nil
        self.page = page
        self:build()
        self:repaint()
        self:loadCovers()
    end)
end

function LibraryScreen:refresh()
    self.browse_cache = {}
    self.offline = false
    self.cover_gen = (self.cover_gen or 0) + 1
    self:resetData()
    self.page = 1
    self:build()
    self:repaint(true)
    UIManager:nextTick(function() self:goToPage(1) end)
end

---------------------------------------------------------------------------
-- Covers
---------------------------------------------------------------------------

function LibraryScreen:renderCover(data)
    local ok, bb = pcall(RenderImage.renderImageData, RenderImage, data, #data, false)
    if not ok or not bb then
        logger.warn("CalibreShelf: cannot decode thumbnail", bb)
        return nil
    end
    local bw, bh = bb:getWidth(), bb:getHeight()
    if bw > self.cover_w or bh > self.cover_h then
        local f = math.min(self.cover_w / bw, self.cover_h / bh)
        bb = RenderImage:scaleBlitBuffer(bb, math.max(1, math.floor(bw * f)), math.max(1, math.floor(bh * f)), true)
    end
    -- (Calibre thumbnails are JPEG; TurboJPEG already decodes to 8-bit gray on
    -- non-color screens, so no conversion is needed to keep RAM low.)
    return bb
end

function LibraryScreen:thumbPath(book)
    return Store.thumbPath(self.server_key, self.library_id, book, self.cover_w, self.cover_h)
end

--- Refresh only the region covering `cards` (one e-ink update per batch).
function LibraryScreen:refreshCards(cards)
    local region
    for _i, card in ipairs(cards) do
        if card.dimen and card.dimen.x then
            region = region and region:combine(card.dimen) or card.dimen:copy()
        end
    end
    if region then
        UIManager:setDirty(self, "ui", region, true)
    end
end

function LibraryScreen:loadCovers()
    self.cover_gen = (self.cover_gen or 0) + 1
    local gen = self.cover_gen
    local missing, cached = {}, {}
    for _i, card in ipairs(self.cards) do
        local data = Store.readFile(self:thumbPath(card.book))
        local bb = data and self:renderCover(data)
        if bb then
            card:setCover(bb)
            table.insert(cached, card)
        else
            table.insert(missing, card)
        end
    end
    if #cached > 0 then
        -- Page was just painted; make the cached covers part of the same refresh.
        UIManager:setDirty(self, "ui", nil, true)
    end
    if #missing == 0 then return end
    if not NetworkMgr:isConnected() then return end

    local pending = {}
    local function step()
        if gen ~= self.cover_gen or self.closed then return end
        local card = table.remove(missing, 1)
        if card then
            local data, err = self.client:fetchThumbnail(card.book.id, self.cover_w, self.cover_h)
            if gen ~= self.cover_gen or self.closed then return end
            if data then
                Store.writeFile(self:thumbPath(card.book), data)
                local bb = self:renderCover(data)
                if bb then
                    card:setCover(bb)
                    table.insert(pending, card)
                end
            elseif err.kind == Calibre.ERR.UNREACHABLE or err.kind == Calibre.ERR.TIMEOUT then
                missing = {} -- network gone: stop, keep placeholders
            end
        end
        if #pending > 0 and (#pending >= self.cols or #missing == 0) then
            self:refreshCards(pending)
            pending = {}
        end
        if #missing > 0 then
            UIManager:nextTick(step)
        end
    end
    UIManager:nextTick(step)
end

---------------------------------------------------------------------------
-- Gestures & actions
---------------------------------------------------------------------------

function LibraryScreen:cardAt(pos)
    for _i, card in ipairs(self.cards or {}) do
        if card.dimen and card.dimen.x and card.dimen:contains(pos) then
            return card
        end
    end
end

function LibraryScreen:onTap(_arg, ges)
    local card = self:cardAt(ges.pos)
    if not card then return end
    if self.selecting then
        self:toggle(card)
    else
        self:openBook(card.book)
    end
    return true
end

function LibraryScreen:onHold(_arg, ges)
    local card = self:cardAt(ges.pos)
    if not card then return end
    if not self.selecting then
        self.selecting = true
    end
    self:toggle(card)
    return true
end

---------------------------------------------------------------------------
-- Multi-selection
---------------------------------------------------------------------------

function LibraryScreen:setSelected(id, on)
    if (self.selected[id] == true) == on then return end
    self.selected[id] = on or nil
    self.selected_count = self.selected_count + (on and 1 or -1)
end

function LibraryScreen:toggle(card)
    local id = card.book.id
    local on = not self.selected[id]
    self:setSelected(id, on)
    card:setSelected(on)
    self:refreshCards({ card })
    self:updateChrome()
end

function LibraryScreen:selectPage()
    local changed = {}
    for _i, card in ipairs(self.cards) do
        if not self.selected[card.book.id] then
            self:setSelected(card.book.id, true)
            card:setSelected(true)
            table.insert(changed, card)
        end
    end
    self:refreshCards(changed)
    self:updateChrome()
end

function LibraryScreen:clearSelection()
    self.selected = {}
    self.selected_count = 0
    local changed = {}
    for _i, card in ipairs(self.cards) do
        if card.selected then
            card:setSelected(false)
            table.insert(changed, card)
        end
    end
    self:refreshCards(changed)
    self:updateChrome()
end

function LibraryScreen:exitSelection()
    self.selecting = false
    self:clearSelection()
end

function LibraryScreen:downloadSelected()
    local plugin = self.plugin
    local server_key = self.server_key
    local fresh, existing, unsupported = {}, {}, 0
    -- Keep the on-screen order for the queue.
    for _i, id in ipairs(self.ids) do
        if self.selected[id] then
            local book = self.books[id]
            local fmt = Downloads.pickFormat(book, plugin.formats)
            if not fmt then
                unsupported = unsupported + 1
            else
                local path = plugin.downloads:get(server_key, self.library_id, id, fmt)
                table.insert(path and existing or fresh, { book = book, fmt = fmt, path = path })
            end
        end
    end

    local function queue(items, replace)
        for _i, it in ipairs(items) do
            plugin:downloadBook(it.book, it.fmt, { replace_path = replace and it.path or nil })
        end
        local n = #items
        self:exitSelection()
        if n > 0 then
            self.batch_size = (self.batch_size or 0) + n
            local text = n == 1 and _("1 book added to downloads") or T(_("%1 books added to downloads"), n)
            if unsupported > 0 then
                text = text .. "\n" .. T(_("%1 skipped: no readable format"), unsupported)
            end
            Notification:notify(text, Notification.SOURCE_ALWAYS_SHOW)
        elseif unsupported > 0 then
            UIManager:show(InfoMessage:new{ text = _("None of the selected books has a format KOReader can open.") })
        end
    end

    if #existing == 0 then
        return queue(fresh)
    end
    local dialog
    local buttons = {}
    if #fresh > 0 then
        table.insert(buttons, {{ text = T(_("Skip them, download %1"), #fresh), callback = function()
            UIManager:close(dialog)
            queue(fresh)
        end }})
    end
    table.insert(buttons, {{ text = _("Replace them"), callback = function()
        UIManager:close(dialog)
        local all = {}
        for _i, it in ipairs(fresh) do table.insert(all, it) end
        for _i, it in ipairs(existing) do table.insert(all, it) end
        queue(all, true)
    end }})
    table.insert(buttons, {{ text = _("Cancel"), callback = function() UIManager:close(dialog) end }})
    dialog = ButtonDialog:new{
        title = #existing == 1 and _("1 selected book is already on this device.")
            or T(_("%1 selected books are already on this device."), #existing),
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function LibraryScreen:onJobUpdate(job)
    if job.status == "completed" then
        for _i, card in ipairs(self.cards or {}) do
            if card.book.id == job.book.id and not card.downloaded then
                card:setDownloaded(true)
                self:refreshCards({ card })
            end
        end
    end
    if (self.batch_size or 0) > 1 and self.plugin.downloader:pending() == 0
            and job.status ~= "queued" and job.status ~= "downloading" then
        local failed = 0
        for _i, j in ipairs(self.plugin.downloader.jobs) do
            if j.status == "failed" then failed = failed + 1 end
        end
        local text = failed == 0 and _("All downloads finished")
            or T(_("Downloads finished, %1 failed"), failed)
        Notification:notify(text, Notification.SOURCE_ALWAYS_SHOW)
        self.batch_size = 0
    end
end

function LibraryScreen:openBook(book)
    local BookDetails = csrequire("screens/bookdetails")
    UIManager:show(BookDetails:new{
        plugin = self.plugin,
        book = book,
        client = self.client,
        on_change = function() self:updateDownloadedBadges() end,
    })
end

function LibraryScreen:updateDownloadedBadges()
    local changed = {}
    for _i, card in ipairs(self.cards or {}) do
        local downloaded = self.plugin:downloadedPath(card.book) ~= nil
        if downloaded ~= card.downloaded then
            card:setDownloaded(downloaded)
            table.insert(changed, card)
        end
    end
    if #changed > 0 then self:refreshCards(changed) end
end

function LibraryScreen:onNextPage()
    if self.page < self:totalPages() then
        self:goToPage(self.page + 1)
    end
    return true
end

function LibraryScreen:onPrevPage()
    if self.page > 1 then
        self:goToPage(self.page - 1)
    end
    return true
end

-- Run a new listing (search and/or sort), keeping the old one if it fails.
function LibraryScreen:applyQuery(changes)
    local previous = {}
    for k, v in pairs(self.query) do previous[k] = v end
    for k, v in pairs(changes) do self.query[k] = v end
    local old_ids, old_books, old_total, old_last, old_page, old_offline =
        self.ids, self.books, self.total, self.last_result, self.page, self.offline
    self:resetData()
    self.offline = false
    self:ensureLoaded(1, function(ok, err)
        if not ok then
            self.query = previous
            self.ids, self.books, self.total, self.last_result, self.page, self.offline =
                old_ids, old_books, old_total, old_last, old_page, old_offline
            UIManager:show(InfoMessage:new{ text = err.message })
            return
        end
        self.page = 1
        self:build()
        self:repaint(true)
        self:loadCovers()
    end)
end

function LibraryScreen:defaultTitle()
    return self.plugin.server.library_name or _("Library")
end

function LibraryScreen:onTab(id)
    if id == "all" then
        self:applyQuery{ search = "", sort = self.plugin.sort.field, order = self.plugin.sort.order,
            title = self:defaultTitle(), tab = "all" }
    elseif id == "recent" then
        self:applyQuery{ search = "", sort = "timestamp", order = "desc", title = _("Recently added"), tab = "recent" }
    else
        self:showBrowse(id)
    end
end

local BROWSE_TITLES = { authors = _("Authors"), series = _("Series"), tags = _("Tags") }

function LibraryScreen:showBrowse(field)
    local function show(items)
        local BrowseScreen = csrequire("screens/browse")
        UIManager:show(BrowseScreen:new{
            title = BROWSE_TITLES[field],
            items = items,
            on_select = function(item)
                self:applyQuery{ search = item.search, title = item.name, tab = field }
            end,
        })
    end
    if self.browse_cache[field] then return show(self.browse_cache[field]) end
    NetworkMgr:runWhenConnected(function()
        local info = InfoMessage:new{ text = _("Loading…") }
        UIManager:show(info)
        UIManager:forceRePaint()
        local items, err = self.client:browseField(field)
        UIManager:close(info)
        if not items then
            UIManager:show(InfoMessage:new{ text = err.message })
            return
        end
        self.browse_cache[field] = items
        show(items)
    end)
end

function LibraryScreen:showSearch()
    local dialog
    dialog = InputDialog:new{
        title = _("Search library"),
        input = self.query.search,
        input_hint = _("Title, author, tag or Calibre search"),
        description = _("Uses Calibre's search, e.g. authors:herbert or tags:\"sci-fi\"."),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Search"), is_enter_default = true, callback = function()
                local text = util.trim(dialog:getInputText())
                UIManager:close(dialog)
                self:applyQuery{
                    search = text,
                    title = text ~= "" and text or self:defaultTitle(),
                    tab = text ~= "" and "search" or "all",
                }
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

local SORT_FIELDS = {
    { field = "timestamp", order = "desc" },
    { field = "title", order = "asc" },
    { field = "authors", order = "asc" },
    { field = "series", order = "asc" },
}

function LibraryScreen:showSort()
    local dialog
    local buttons = {}
    local function choose(field, order)
        UIManager:close(dialog)
        self.plugin.sort = { field = field, order = order }
        self.plugin:saveSettings()
        self:applyQuery{ sort = field, order = order }
    end
    for _i, s in ipairs(SORT_FIELDS) do
        local current = self.query.sort == s.field
        table.insert(buttons, {{
            text = SORT_LABELS[s.field] .. (current and "  \u{2713}" or ""),
            callback = function() choose(s.field, s.order) end,
        }})
    end
    table.insert(buttons, {{
        text = self.query.order == "desc" and _("Ascending order") or _("Descending order"),
        callback = function() choose(self.query.sort, self.query.order == "desc" and "asc" or "desc") end,
    }})
    dialog = ButtonDialog:new{ title = _("Sort by"), buttons = buttons }
    UIManager:show(dialog)
end

function LibraryScreen:showMenu()
    local dialog
    local buttons = {
        {{ text = _("Sort by…"), callback = function()
            UIManager:close(dialog)
            self:showSort()
        end }},
    }
    if self.offline then
        table.insert(buttons, 1, {{ text = _("Go online"), callback = function()
            UIManager:close(dialog)
            NetworkMgr:runWhenConnected(function() self:refresh() end)
        end }})
    end
    if self.query.search ~= "" then
        table.insert(buttons, 1, {{ text = _("Show all books"), callback = function()
            UIManager:close(dialog)
            self:applyQuery{ search = "", title = self:defaultTitle(), tab = "all" }
        end }})
    end
    local pending = self.plugin.downloader:pending()
    table.insert(buttons, {{ text = pending > 0 and T(_("Downloads (%1)"), pending) or _("Downloads"),
        callback = function()
            UIManager:close(dialog)
            self.plugin:showDownloads()
        end }})
    table.insert(buttons, {{ text = _("Select books"), callback = function()
        UIManager:close(dialog)
        self.selecting = true
        self:updateChrome()
    end }})
    table.insert(buttons, {{ text = _("Refresh"), callback = function()
        UIManager:close(dialog)
        self:refresh()
    end }})
    table.insert(buttons, {{ text = _("Server settings"), callback = function()
        UIManager:close(dialog)
        self:onClose()
        self.plugin:showSettings()
    end }})
    dialog = ButtonDialog:new{ buttons = buttons }
    UIManager:show(dialog)
end

function LibraryScreen:onClose(force)
    if self.selecting and not force then
        self:exitSelection()
        return true
    end
    self.closed = true
    self.cover_gen = (self.cover_gen or 0) + 1
    UIManager:close(self, "full")
    if self.close_callback then self.close_callback() end
    return true
end

function LibraryScreen:onCloseWidget()
    self.plugin.downloader:removeListener(self.listener)
    self:freeCards()
    UIManager:scheduleIn(5, Store.pruneThumbs)
end

return LibraryScreen
