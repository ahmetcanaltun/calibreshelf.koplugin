-- Paged list of authors, series or tags. Tapping an item calls on_select(item),
-- where item = { name, count, search } from Calibre:browseField().

local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconButton = require("ui/widget/iconbutton")
local InputDialog = require("ui/widget/inputdialog")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

local csrequire = require("calibreshelf/require")
local Common = csrequire("widgets/common")

local BrowseScreen = Common.Page:extend{
    title = nil,
    items = nil,
    on_select = nil,
}

function BrowseScreen:init()
    self:initPage()
    local S = Common.S
    self.all_items = self.items
    self.filter = ""
    self.page = 1
    self.header_h = self:buildHeader():getSize().h
    self.footer_h = S.footer_h + S.gap
    self.per_page = math.max(1, math.floor((self.dimen.h - self.header_h - self.footer_h) / S.row_h))
    self:build()
end

function BrowseScreen:totalPages()
    if not self.per_page then return 1 end
    return math.max(1, math.ceil(#self.items / self.per_page))
end

function BrowseScreen:buildHeader()
    local n = #self.items
    local subtitle = n == 1 and _("1 item") or T(_("%1 items"), n)
    if self.filter ~= "" then subtitle = T(_("Matching \"%1\": %2"), self.filter, subtitle) end
    return Common.header{
        width = self.dimen.w,
        title = self.title,
        subtitle = subtitle,
        show_parent = self,
        actions = {
            { icon = "appbar.search", callback = function() self:showFilter() end },
            { icon = "close", callback = function() self:onClose() end, allow_flash = false },
        },
    }
end

function BrowseScreen:buildFooter()
    local S = Common.S
    local W = self.dimen.w
    local pages = self:totalPages()
    local function chevron(icon, enabled, cb)
        return IconButton:new{
            icon = icon, width = S.icon, height = S.icon, padding = S.icon_pad,
            enabled = enabled, callback = cb, show_parent = self,
        }
    end
    local prev = chevron("chevron.left", self.page > 1, function() self:onPrevPage() end)
    local nxt = chevron("chevron.right", self.page < pages, function() self:onNextPage() end)
    return VerticalGroup:new{
        VerticalSpan:new{ width = S.gap },
        HorizontalGroup:new{
            HorizontalSpan:new{ width = S.margin - S.icon_pad },
            prev,
            CenterContainer:new{
                dimen = Geom:new{ w = W - 2 * (S.margin - S.icon_pad) - 2 * prev:getSize().w, h = S.footer_h },
                TextWidget:new{ text = T(_("Page %1 of %2"), self.page, pages), face = Common.F.small },
            },
            nxt,
        },
    }
end

function BrowseScreen:build()
    local W = self.dimen.w
    local list = VerticalGroup:new{ align = "left" }
    local first = (self.page - 1) * self.per_page + 1
    for i = first, math.min(#self.items, first + self.per_page - 1) do
        local item = self.items[i]
        table.insert(list, Common.Row:new{
            width = W,
            label = item.name,
            value = item.count and tostring(item.count) or nil,
            callback = function()
                self:onClose()
                self.on_select(item)
            end,
        })
    end
    local list_h = self.dimen.h - self.header_h - self.footer_h
    local body
    if #self.items == 0 then
        body = CenterContainer:new{
            dimen = Geom:new{ w = W, h = list_h },
            TextWidget:new{ text = _("Nothing here."), face = Common.F.body, fgcolor = Common.GRAY },
        }
    else
        body = VerticalGroup:new{ list, VerticalSpan:new{ width = list_h - list:getSize().h } }
    end
    if self[1] then self[1]:free() end
    self[1] = self:wrap(VerticalGroup:new{
        align = "left",
        self:buildHeader(),
        body,
        self:buildFooter(),
    })
end

function BrowseScreen:showFilter()
    local dialog
    dialog = InputDialog:new{
        title = T(_("Find in %1"), self.title),
        input = self.filter,
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Find"), is_enter_default = true, callback = function()
                local text = util.trim(dialog:getInputText())
                UIManager:close(dialog)
                self:applyFilter(text)
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Filters the already-fetched name list; the library itself is never searched locally.
function BrowseScreen:applyFilter(text)
    self.filter = text
    if text == "" then
        self.items = self.all_items
    else
        local needle = text:lower()
        self.items = {}
        for _i, item in ipairs(self.all_items) do
            if item.name:lower():find(needle, 1, true) then table.insert(self.items, item) end
        end
    end
    self.page = 1
    self:build()
    UIManager:setDirty(self, "partial")
end

function BrowseScreen:onNextPage()
    if self.page < self:totalPages() then
        self.page = self.page + 1
        self:build()
        UIManager:setDirty(self, "partial")
    end
    return true
end

function BrowseScreen:onPrevPage()
    if self.page > 1 then
        self.page = self.page - 1
        self:build()
        UIManager:setDirty(self, "partial")
    end
    return true
end

return BrowseScreen
