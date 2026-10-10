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
local NetworkMgr = require("ui/network/manager")
local OverlapGroup = require("ui/widget/overlapgroup")
local RenderImage = require("ui/renderimage")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local logger = require("logger")
local Screen = Device.screen
local _ = require("gettext")
local T = require("ffi/util").template

local csrequire = require("calibreshelf/require")
local BookCard = csrequire("widgets/bookcard")
local Calibre = csrequire("api/calibre")
local Common = csrequire("widgets/common")
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
    }
    self.page = 1
    self.turns = 0
    self:resetData()
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
    return count .. " · " .. (SORT_LABELS[self.query.sort] or self.query.sort)
        .. (self.query.order == "desc" and " ↓" or " ↑")
end

function LibraryScreen:buildHeader()
    return Common.header{
        width = self.dimen.w,
        title = self.query.title,
        subtitle = self:subtitle(),
        show_parent = self,
        actions = {
            { icon = "appbar.menu", callback = function() self:showMenu() end },
            { icon = "close", callback = function() self:onClose() end, allow_flash = false },
        },
    }
end

function LibraryScreen:totalPages()
    if not self.total or self.total == 0 then return 1 end
    return math.ceil(self.total / self.per_page)
end

function LibraryScreen:buildFooter()
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
    for _, card in ipairs(self.cards or {}) do card:free() end
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
    local content = VerticalGroup:new{
        align = "left",
        self:buildHeader(),
        self:buildGrid(),
        self:buildFooter(),
    }
    -- Free old widget tree, but cards were already freed/rebuilt by buildGrid.
    self[1] = self:wrap(content)
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
function LibraryScreen:ensureLoaded(page, callback)
    local need = page * self.per_page
    if self.total then need = math.min(need, self.total) end
    if self.total and #self.ids >= need then
        return callback(true)
    end
    NetworkMgr:runWhenOnline(function()
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
                for _, id in ipairs(result.ids) do
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
            return callback(false, err)
        end
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
    for _, card in ipairs(cards) do
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
    for _, card in ipairs(self.cards) do
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
    if not NetworkMgr:isOnline() then return end

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
    for _, card in ipairs(self.cards or {}) do
        if card.dimen and card.dimen.x and card.dimen:contains(pos) then
            return card
        end
    end
end

function LibraryScreen:onTap(_, ges)
    local card = self:cardAt(ges.pos)
    if card then
        self:openBook(card.book)
        return true
    end
end

function LibraryScreen:onHold(_, ges)
    local card = self:cardAt(ges.pos)
    if card then
        -- Multi-selection arrives in Stage 3.
        self:openBook(card.book)
        return true
    end
end

function LibraryScreen:openBook(book)
    -- Full details screen arrives in Stage 2; show a compact summary for now.
    local lines = { book.title }
    if #book.authors > 0 then table.insert(lines, table.concat(book.authors, ", ")) end
    local series = BookCard.seriesText(book)
    if series then table.insert(lines, series) end
    if #book.formats > 0 then table.insert(lines, table.concat(book.formats, " · ")) end
    UIManager:show(InfoMessage:new{ text = table.concat(lines, "\n"), show_icon = false })
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

function LibraryScreen:showMenu()
    local dialog
    dialog = ButtonDialog:new{
        buttons = {
            {{ text = _("Refresh"), callback = function()
                UIManager:close(dialog)
                self:refresh()
            end }},
            {{ text = _("Server settings"), callback = function()
                UIManager:close(dialog)
                self:onClose()
                self.plugin:showSettings()
            end }},
        },
    }
    UIManager:show(dialog)
end

function LibraryScreen:onClose()
    self.closed = true
    self.cover_gen = (self.cover_gen or 0) + 1
    UIManager:close(self, "full")
    if self.close_callback then self.close_callback() end
    return true
end

function LibraryScreen:onCloseWidget()
    self:freeCards()
    UIManager:scheduleIn(5, Store.pruneThumbs)
end

return LibraryScreen
