--[[--
Shared look & building blocks for CalibreShelf screens.

Style: monochrome, large type, generous spacing, minimal borders, big touch
targets (>= ~9 mm). No animations. Everything is sized with Screen:scaleBySize
so it scales from the 300 PPI Paperwhite 12 down to older devices.

@module calibreshelf.widgets.common
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconButton = require("ui/widget/iconbutton")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local RightContainer = require("ui/widget/container/rightcontainer")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local BD = require("ui/bidi")
local Screen = Device.screen

local Common = {}

Common.S = {
    margin = Screen:scaleBySize(18),      -- outer page margin
    gap = Screen:scaleBySize(12),         -- space between grid items
    header_h = Screen:scaleBySize(64),
    footer_h = Screen:scaleBySize(56),
    row_h = Screen:scaleBySize(58),
    icon = Screen:scaleBySize(34),
    icon_pad = Screen:scaleBySize(12),
    line = Screen:scaleBySize(1),
}

Common.F = {
    title = Font:getFace("smalltfont", 30),       -- bold
    heading = Font:getFace("smalltfont", 22),     -- bold
    body = Font:getFace("cfont", 21),
    body_bold = Font:getFace("smalltfont", 21),
    small = Font:getFace("cfont", 17),
    small_bold = Font:getFace("smalltfont", 17),
    tiny = Font:getFace("cfont", 15),
}

Common.GRAY = Blitbuffer.COLOR_GRAY_9
Common.LIGHT = Blitbuffer.COLOR_GRAY_E

function Common.hline(width, color, thickness)
    return LineWidget:new{
        dimen = Geom:new{ w = width, h = thickness or Common.S.line },
        background = color or Blitbuffer.COLOR_LIGHT_GRAY,
    }
end

--[[--
Full-width header: big bold title on the left, icon actions on the right.
@param o { width, title, subtitle, actions = { {icon=, callback=, hold_callback=} } }
]]
function Common.header(o)
    local S = Common.S
    local icons = HorizontalGroup:new{}
    for _, a in ipairs(o.actions or {}) do
        table.insert(icons, IconButton:new{
            icon = a.icon,
            width = S.icon,
            height = S.icon,
            padding = S.icon_pad,
            callback = a.callback,
            hold_callback = a.hold_callback,
            allow_flash = a.allow_flash ~= false,
            show_parent = o.show_parent,
        })
    end
    local icons_w = icons:getSize().w
    local title_w = o.width - 2 * S.margin - icons_w
    local title_group = VerticalGroup:new{ align = "left" }
    table.insert(title_group, TextWidget:new{
        text = o.title or "",
        face = Common.F.title,
        max_width = title_w,
    })
    if o.subtitle and o.subtitle ~= "" then
        table.insert(title_group, TextWidget:new{
            text = o.subtitle,
            face = Common.F.small,
            fgcolor = Common.GRAY,
            max_width = title_w,
        })
    end
    local h = math.max(S.header_h, title_group:getSize().h, icons:getSize().h) + S.gap
    return FrameContainer:new{
        padding = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        OverlapGroup:new{
            dimen = Geom:new{ w = o.width, h = h },
            LeftContainer:new{
                dimen = Geom:new{ w = o.width, h = h },
                HorizontalGroup:new{
                    HorizontalSpan:new{ width = S.margin },
                    title_group,
                },
            },
            RightContainer:new{
                dimen = Geom:new{ w = o.width - S.margin + S.icon_pad, h = h },
                icons,
            },
        },
    }
end

--[[--
A tappable settings row: bold label on the left, value (gray) on the right.
]]
local Row = InputContainer:extend{
    width = nil,
    label = "",
    value = nil,
    callback = nil,
    enabled = true,
}

function Row:init()
    local S = Common.S
    self.dimen = Geom:new{ w = self.width, h = S.row_h }
    local inner_w = self.width - 2 * S.margin
    local label = TextWidget:new{
        text = self.label,
        face = Common.F.body_bold,
        fgcolor = self.enabled and Blitbuffer.COLOR_BLACK or Common.GRAY,
        max_width = (self.value and self.value ~= "") and math.floor(inner_w * 0.45) or inner_w,
    }
    local value = TextWidget:new{
        text = self.value and BD.auto(self.value) or "",
        face = Common.F.body,
        fgcolor = Common.GRAY,
        max_width = inner_w - label:getSize().w - S.gap,
    }
    self[1] = VerticalGroup:new{
        OverlapGroup:new{
            dimen = Geom:new{ w = self.width, h = S.row_h - S.line },
            LeftContainer:new{
                dimen = Geom:new{ w = self.width, h = S.row_h - S.line },
                HorizontalGroup:new{ HorizontalSpan:new{ width = S.margin }, label },
            },
            RightContainer:new{
                dimen = Geom:new{ w = self.width - S.margin, h = S.row_h - S.line },
                value,
            },
        },
        LeftContainer:new{
            dimen = Geom:new{ w = self.width, h = S.line },
            HorizontalGroup:new{
                HorizontalSpan:new{ width = S.margin },
                Common.hline(inner_w),
            },
        },
    }
    self.ges_events.Tap = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } }
end

function Row:onTap()
    if self.enabled and self.callback then
        -- Brief inversion as touch feedback, then run.
        UIManager:widgetInvert(self, self.dimen.x, self.dimen.y, self.dimen.w, self.dimen.h)
        UIManager:setDirty(nil, "fast", self.dimen)
        UIManager:forceRePaint()
        UIManager:widgetInvert(self, self.dimen.x, self.dimen.y, self.dimen.w, self.dimen.h)
        UIManager:setDirty(nil, "ui", self.dimen)
        self.callback()
    end
    return true
end

Common.Row = Row

--- Section heading inside a page (small caps-ish gray label).
function Common.section(width, text)
    local S = Common.S
    return VerticalGroup:new{
        VerticalSpan:new{ width = math.floor(S.gap * 1.5) },
        LeftContainer:new{
            dimen = Geom:new{ w = width, h = Common.F.small_bold.size * 1.6 },
            HorizontalGroup:new{
                HorizontalSpan:new{ width = S.margin },
                TextWidget:new{ text = text:upper(), face = Common.F.small_bold, fgcolor = Common.GRAY },
            },
        },
    }
end

--[[--
Base class for full-screen pages. Subclasses build self[1] and may override
onSwipe. Back key / swipe-down / close icon call onClose.
]]
local Page = InputContainer:extend{
    covers_fullscreen = true, -- hint for UIManager:_repaint()
    close_callback = nil,
}

function Page:initPage()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end
    if Device:isTouchDevice() then
        self.ges_events.Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } }
    end
end

function Page:onSwipe(_, ges)
    local direction = BD.flipDirectionIfMirroredUILayout(ges.direction)
    if direction == "west" and self.onNextPage then
        return self:onNextPage()
    elseif direction == "east" and self.onPrevPage then
        return self:onPrevPage()
    elseif direction == "south" then
        return self:onClose()
    elseif direction ~= "north" then
        -- Diagonal swipe: user-requested full refresh to clear ghosting.
        UIManager:setDirty(nil, "full")
        return false
    end
end

function Page:onClose()
    UIManager:close(self)
    if self.close_callback then self.close_callback() end
    return true
end

--- Wrap content in a white full-screen frame.
function Page:wrap(content)
    return FrameContainer:new{
        width = self.dimen.w,
        height = self.dimen.h,
        padding = 0,
        margin = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        content,
    }
end

Common.Page = Page

return Common
