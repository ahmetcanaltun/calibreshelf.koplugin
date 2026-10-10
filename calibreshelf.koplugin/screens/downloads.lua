-- Download manager: queued, downloading, completed, failed and cancelled jobs
-- with Cancel / Retry / Open per row. Progress redraws only the changed row.

local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LeftContainer = require("ui/widget/container/leftcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local RightContainer = require("ui/widget/container/rightcontainer")
local TextWidget = require("ui/widget/textwidget")
local TopContainer = require("ui/widget/container/topcontainer")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local util = require("util")
local Screen = Device.screen
local _ = require("gettext")
local T = require("ffi/util").template

local csrequire = require("calibreshelf/require")
local Common = csrequire("widgets/common")

local DownloadsScreen = Common.Page:extend{
    plugin = nil,
}

function DownloadsScreen:init()
    self:initPage()
    local S = Common.S
    self.downloader = self.plugin.downloader
    self.page = 1
    self.row_h = math.floor(S.row_h * 1.35)
    self.header_h = self:buildHeader():getSize().h
    self.footer_h = S.footer_h + S.gap
    local list_h = self.dimen.h - self.header_h - self.footer_h
    self.per_page = math.max(1, math.floor(list_h / self.row_h))
    self.listener = function(job) self:onJobUpdate(job) end
    self.downloader:addListener(self.listener)
    self:build()
end

function DownloadsScreen:totalPages()
    if not self.per_page then return 1 end -- header is measured before layout
    return math.max(1, math.ceil(#self.downloader.jobs / self.per_page))
end

function DownloadsScreen:subtitle()
    local counts = { queued = 0, downloading = 0, failed = 0, completed = 0 }
    for _i, job in ipairs(self.downloader.jobs) do
        counts[job.status] = (counts[job.status] or 0) + 1
    end
    local parts = {}
    if counts.downloading > 0 then table.insert(parts, T(_("%1 downloading"), counts.downloading)) end
    if counts.queued > 0 then table.insert(parts, T(_("%1 queued"), counts.queued)) end
    if counts.completed > 0 then table.insert(parts, T(_("%1 done"), counts.completed)) end
    if counts.failed > 0 then table.insert(parts, T(_("%1 failed"), counts.failed)) end
    local text = table.concat(parts, " · ")
    if self:totalPages() > 1 then
        text = text .. "  ·  " .. T(_("page %1/%2"), self.page, self:totalPages())
    end
    return text
end

function DownloadsScreen:buildHeader()
    return Common.header{
        width = self.dimen.w,
        title = _("Downloads"),
        subtitle = self:subtitle(),
        show_parent = self,
        actions = { { icon = "close", callback = function() self:onClose() end, allow_flash = false } },
    }
end

function DownloadsScreen:statusText(job)
    local fmt = job.fmt
    if job.status == "queued" then
        return T(_("%1 · Waiting"), fmt)
    elseif job.status == "downloading" then
        if job.size and job.size > 0 then
            return T(_("%1 · %2% of %3"), fmt, math.min(99, math.floor(job.bytes * 100 / job.size)),
                util.getFriendlySize(job.size))
        end
        return T(_("%1 · %2"), fmt, util.getFriendlySize(job.bytes or 0))
    elseif job.status == "completed" then
        return T(_("%1 · Downloaded"), fmt)
    elseif job.status == "skipped" then
        return T(_("%1 · Skipped, file already exists"), fmt)
    elseif job.status == "cancelled" then
        return T(_("%1 · Cancelled"), fmt)
    end
    return T(_("%1 · %2"), fmt, job.error or _("Failed"))
end

function DownloadsScreen:buildRow(job)
    local S = Common.S
    local W = self.dimen.w
    local action, label
    if job.status == "queued" or job.status == "downloading" then
        label, action = _("Cancel"), function() self.downloader:cancel(job) end
    elseif job.status == "failed" or job.status == "cancelled" then
        label, action = _("Retry"), function() self.downloader:retry(job) end
    elseif job.path then
        label, action = _("Open"), function()
            self:onClose()
            self.plugin:openFile(job.path)
        end
    end
    local button_w = math.floor(W * 0.24)
    local text_w = W - 2 * S.margin - button_w - S.gap
    local h = self.row_h - S.line
    local right = HorizontalSpan:new{ width = 0 }
    if action then
        right = Button:new{
            text = label,
            width = button_w,
            text_font_size = 19,
            bordersize = label == _("Open") and Screen:scaleBySize(2) or 0,
            background = label ~= _("Open") and Common.LIGHT or nil,
            radius = Screen:scaleBySize(10),
            padding_v = S.gap,
            callback = action,
            show_parent = self,
        }
    end
    return VerticalGroup:new{
        OverlapGroup:new{
            dimen = Geom:new{ w = W, h = h },
            LeftContainer:new{
                dimen = Geom:new{ w = W, h = h },
                HorizontalGroup:new{
                    HorizontalSpan:new{ width = S.margin },
                    VerticalGroup:new{
                        align = "left",
                        TextWidget:new{ text = job.book.title, face = Common.F.body_bold, max_width = text_w },
                        TextWidget:new{
                            text = self:statusText(job),
                            face = Common.F.small,
                            fgcolor = Common.GRAY,
                            max_width = text_w,
                        },
                    },
                },
            },
            RightContainer:new{
                dimen = Geom:new{ w = W - S.margin, h = h },
                right,
            },
        },
        LeftContainer:new{
            dimen = Geom:new{ w = W, h = S.line },
            HorizontalGroup:new{
                HorizontalSpan:new{ width = S.margin },
                Common.hline(W - 2 * S.margin),
            },
        },
    }
end

function DownloadsScreen:buildFooter()
    local S = Common.S
    local W = self.dimen.w - 2 * S.margin
    local half = math.floor((W - S.gap) / 2)
    local function button(text, callback)
        return Button:new{
            text = text,
            width = half,
            height = S.footer_h - S.gap,
            text_font_size = 20,
            bordersize = 0,
            background = Common.LIGHT,
            radius = Screen:scaleBySize(10),
            padding_v = 0,
            callback = callback,
            show_parent = self,
        }
    end
    return VerticalGroup:new{
        VerticalSpan:new{ width = S.gap },
        HorizontalGroup:new{
            HorizontalSpan:new{ width = S.margin },
            button(_("Clear finished"), function()
                self.downloader:clearFinished()
                self.page = 1
                self:build()
                UIManager:setDirty(self, "ui")
            end),
            HorizontalSpan:new{ width = S.gap },
            button(_("Cancel all"), function()
                for _i, job in ipairs(self.downloader.jobs) do
                    if job.status == "queued" then self.downloader:cancel(job) end
                end
                if self.downloader.current then self.downloader:cancel(self.downloader.current) end
            end),
        },
    }
end

function DownloadsScreen:build()
    local W = self.dimen.w
    local list_h = self.dimen.h - self.header_h - self.footer_h
    self.page = math.min(self.page, self:totalPages())
    self.rows = {}
    local list = VerticalGroup:new{ align = "left" }
    local first = (self.page - 1) * self.per_page + 1
    for i = first, math.min(#self.downloader.jobs, first + self.per_page - 1) do
        local job = self.downloader.jobs[i]
        local holder = LeftContainer:new{
            dimen = Geom:new{ w = W, h = self.row_h },
            self:buildRow(job),
        }
        holder.region = Geom:new{ x = 0, y = self.header_h + (i - first) * self.row_h, w = W, h = self.row_h }
        self.rows[job] = holder
        table.insert(list, holder)
    end
    local body
    if #self.downloader.jobs == 0 then
        body = CenterContainer:new{
            dimen = Geom:new{ w = W, h = list_h },
            TextWidget:new{ text = _("No downloads yet."), face = Common.F.body, fgcolor = Common.GRAY },
        }
    else
        body = TopContainer:new{ dimen = Geom:new{ w = W, h = list_h }, list }
    end
    self.header_holder = LeftContainer:new{
        dimen = Geom:new{ w = W, h = self.header_h },
        self:buildHeader(),
    }
    if self[1] then self[1]:free() end
    self[1] = self:wrap(VerticalGroup:new{
        align = "left",
        self.header_holder,
        body,
        self:buildFooter(),
    })
end

function DownloadsScreen:onJobUpdate(job)
    local holder = self.rows[job]
    if not holder then
        -- New job (or one on another page): cheap enough to rebuild the page.
        self:build()
        UIManager:setDirty(self, "ui")
        return
    end
    holder[1]:free()
    holder[1] = self:buildRow(job)
    UIManager:setDirty(self, "ui", holder.region)
    if job.status ~= "downloading" then
        -- Counts in the header changed.
        self.header_holder[1]:free()
        self.header_holder[1] = self:buildHeader()
        UIManager:setDirty(self, "ui", Geom:new{ x = 0, y = 0, w = self.dimen.w, h = self.header_h })
    end
end

function DownloadsScreen:onNextPage()
    if self.page < self:totalPages() then
        self.page = self.page + 1
        self:build()
        UIManager:setDirty(self, "partial")
    end
    return true
end

function DownloadsScreen:onPrevPage()
    if self.page > 1 then
        self.page = self.page - 1
        self:build()
        UIManager:setDirty(self, "partial")
    end
    return true
end

function DownloadsScreen:onCloseWidget()
    self.downloader:removeListener(self.listener)
    if self[1] then self[1]:free() end
end

return DownloadsScreen
