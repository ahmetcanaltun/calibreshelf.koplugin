--[[--
One book in the library grid: cover (or a text placeholder), title, author,
optional series line, plus Downloaded / Selected markers.

The card owns its cover BlitBuffer and frees it in free(). The card itself has
no gesture handling; the library screen hit-tests cards by their dimen, which
keeps the event tree small.

@module calibreshelf.widgets.bookcard
]]

local Blitbuffer = require("ffi/blitbuffer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local ImageWidget = require("ui/widget/imagewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Screen = Device.screen
local _ = require("gettext")
local T = require("ffi/util").template

local csrequire = require("calibreshelf/require")
local Common = csrequire("widgets/common")

local BookCard = WidgetContainer:extend{
    book = nil,
    width = nil,
    cover_w = nil,
    cover_h = nil,
    selected = false,
    downloaded = false,
    show_series = true,
    cover_bb = nil,
}

local SELECT_BORDER = Screen:scaleBySize(4)
local BADGE_PAD = Screen:scaleBySize(4)

--- Height of the text block under the cover (constant for a given layout).
function BookCard.textHeight(show_series)
    local F = Common.F
    local line = function(face) return TextWidget:new{ text = "Ag", face = face, padding = 0 }:getSize().h end
    local h = Screen:scaleBySize(6) + line(F.small_bold) + line(F.tiny)
    if show_series then h = h + line(F.tiny) end
    return h
end

function BookCard.seriesText(book)
    if not book.series then return nil end
    if book.series_index then
        local idx = book.series_index
        idx = (idx == math.floor(idx)) and string.format("%d", idx) or string.format("%.1f", idx)
        -- Index first so truncation never hides it.
        return T(_("#%1 %2"), idx, book.series)
    end
    return book.series
end

function BookCard:init()
    self.dimen = Geom:new{ w = self.width, h = self.cover_h + BookCard.textHeight(self.show_series) }
    self:build()
end

local function badge(text, inverted)
    return FrameContainer:new{
        padding = BADGE_PAD,
        padding_left = BADGE_PAD * 2,
        padding_right = BADGE_PAD * 2,
        bordersize = inverted and 0 or Screen:scaleBySize(1.5),
        radius = Screen:scaleBySize(6),
        background = inverted and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE,
        TextWidget:new{
            text = text,
            face = Common.F.small_bold,
            fgcolor = inverted and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK,
            padding = 0,
        },
    }
end

function BookCard:buildCover()
    local box = Geom:new{ w = self.cover_w, h = self.cover_h }
    local cover
    if self.cover_bb then
        -- Bottom-aligned so every cover in a row sits on the same baseline.
        cover = BottomContainer:new{
            dimen = box,
            ImageWidget:new{ image = self.cover_bb, image_disposable = false },
        }
    else
        local pad = Common.S.gap
        cover = FrameContainer:new{
            width = box.w,
            height = box.h,
            padding = 0,
            bordersize = Screen:scaleBySize(1),
            color = Blitbuffer.COLOR_LIGHT_GRAY,
            background = Common.LIGHT,
            CenterContainer:new{
                dimen = Geom:new{ w = box.w - 2 * Screen:scaleBySize(1), h = box.h - 2 * Screen:scaleBySize(1) },
                TextBoxWidget:new{
                    text = self.book.title,
                    face = Common.F.small_bold,
                    width = box.w - 2 * pad,
                    height = box.h - 2 * pad,
                    height_overflow_show_ellipsis = true,
                    alignment = "center",
                    bgcolor = Common.LIGHT,
                },
            },
        }
    end

    local layers = OverlapGroup:new{ dimen = box:copy(), cover }
    if self.selected then
        table.insert(layers, FrameContainer:new{
            width = box.w,
            height = box.h,
            padding = 0,
            bordersize = SELECT_BORDER,
            color = Blitbuffer.COLOR_BLACK,
            VerticalSpan:new{ width = 0 },
        })
        local b = badge("\u{2713}", true)
        b.overlap_offset = { SELECT_BORDER * 2, SELECT_BORDER * 2 }
        table.insert(layers, b)
    end
    if self.downloaded then
        local b = badge(_("On device"), false)
        local bs = b:getSize()
        b.overlap_offset = { box.w - bs.w - SELECT_BORDER * 2, box.h - bs.h - SELECT_BORDER * 2 }
        table.insert(layers, b)
    end
    return layers
end

function BookCard:build()
    local F = Common.F
    local book = self.book
    -- Everything is centered in the cell so columns read evenly even when the
    -- (height-bound) cover is narrower than the cell.
    local function centered(widget)
        return CenterContainer:new{
            dimen = Geom:new{ w = self.width, h = widget:getSize().h },
            widget,
        }
    end
    local function line(text, face, color)
        return centered(TextWidget:new{
            text = text,
            face = face,
            fgcolor = color,
            max_width = self.width,
            padding = 0,
        })
    end
    local group = VerticalGroup:new{
        centered(self:buildCover()),
        VerticalSpan:new{ width = Screen:scaleBySize(6) },
        line(book.title, F.small_bold),
        line(#book.authors > 0 and table.concat(book.authors, ", ") or _("Unknown author"), F.tiny, Common.GRAY),
    }
    if self.show_series then
        table.insert(group, line(BookCard.seriesText(book) or " ", F.tiny, Common.GRAY))
    end
    if self[1] then self[1]:free() end
    self[1] = group
end

function BookCard:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    self[1]:paintTo(bb, x, y)
end

function BookCard:getSize()
    return self.dimen
end

--- Take ownership of a rendered cover BlitBuffer.
function BookCard:setCover(bb)
    if self.cover_bb and self.cover_bb ~= bb then self.cover_bb:free() end
    self.cover_bb = bb
    self:build()
end

function BookCard:setSelected(selected)
    if self.selected == selected then return end
    self.selected = selected
    self:build()
end

function BookCard:setDownloaded(downloaded)
    if self.downloaded == downloaded then return end
    self.downloaded = downloaded
    self:build()
end

function BookCard:free()
    if self[1] then self[1]:free() end
    if self.cover_bb then
        self.cover_bb:free()
        self.cover_bb = nil
    end
end

return BookCard
