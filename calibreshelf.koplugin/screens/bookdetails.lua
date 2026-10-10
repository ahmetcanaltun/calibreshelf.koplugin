-- Full-screen book page: cover, metadata, formats, description and the
-- Download / Open actions. Download progress updates only the status line.

local Button = require("ui/widget/button")
local ButtonDialog = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local LeftContainer = require("ui/widget/container/leftcontainer")
local NetworkMgr = require("ui/network/manager")
local RenderImage = require("ui/renderimage")
local ScrollTextWidget = require("ui/widget/scrolltextwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local logger = require("logger")
local util = require("util")
local Screen = Device.screen
local _ = require("gettext")
local T = require("ffi/util").template

local csrequire = require("calibreshelf/require")
local BookCard = csrequire("widgets/bookcard")
local Common = csrequire("widgets/common")
local Downloads = csrequire("lib/downloads")
local Store = csrequire("lib/store")

local BookDetails = Common.Page:extend{
    plugin = nil,
    book = nil,
    client = nil,
    on_change = nil, -- called when the downloaded state may have changed
}

function BookDetails:init()
    self:initPage()
    local S = Common.S
    local W = self.dimen.w
    self.server_key = self.client:serverKey()
    self.library_id = self.client.library_id
    self.cover_w = math.floor(W * 0.38)
    self.cover_h = math.floor(self.cover_w * 1.5)
    self.info_w = W - 2 * S.margin - self.cover_w - 2 * S.gap
    self.fmt = Downloads.pickFormat(self.book, self.plugin.formats)

    self.listener = function(job)
        if job == self.job then self:onJobUpdate(job) end
    end
    self.plugin.downloader:addListener(self.listener)
    -- Resume showing progress if this book is already in the queue.
    for _i, job in ipairs(self.plugin.downloader.jobs) do
        if job.book.id == self.book.id and (job.status == "queued" or job.status == "downloading") then
            self.job = job
        end
    end

    self:rebuild()
    UIManager:nextTick(function() self:loadCover() end)
end

function BookDetails:downloadedPath(fmt)
    return self.plugin.downloads:get(self.server_key, self.library_id, self.book.id, fmt)
end

local function friendlySize(bytes)
    return bytes and util.getFriendlySize(bytes) or nil
end

function BookDetails:buildCover()
    local box = Geom:new{ w = self.cover_w, h = self.cover_h }
    if self.cover_bb then
        return CenterContainer:new{
            dimen = box,
            ImageWidget:new{ image = self.cover_bb, image_disposable = false },
        }
    end
    return FrameContainer:new{
        width = box.w,
        height = box.h,
        padding = 0,
        bordersize = Screen:scaleBySize(1),
        color = Common.LIGHT,
        background = Common.LIGHT,
        CenterContainer:new{
            dimen = Geom:new{ w = box.w - 2, h = box.h - 2 },
            TextBoxWidget:new{
                text = self.book.title,
                face = Common.F.heading,
                width = box.w - 4 * Common.S.gap,
                alignment = "center",
                bgcolor = Common.LIGHT,
            },
        },
    }
end

function BookDetails:buildInfo()
    local book = self.book
    local F = Common.F
    local w = self.info_w
    local group = VerticalGroup:new{ align = "left" }
    local function add(widget, space)
        if space then table.insert(group, VerticalSpan:new{ width = space }) end
        table.insert(group, widget)
    end
    add(TextBoxWidget:new{
        text = book.title,
        face = F.title,
        width = w,
        height = math.floor(self.cover_h * 0.45),
        height_adjust = true,
        height_overflow_show_ellipsis = true,
    })
    add(TextBoxWidget:new{
        text = #book.authors > 0 and table.concat(book.authors, ", ") or _("Unknown author"),
        face = F.body,
        width = w,
    }, Common.S.gap)
    local series = BookCard.seriesText(book)
    if series then
        add(TextWidget:new{ text = series, face = F.body, fgcolor = Common.GRAY, max_width = w }, Common.S.gap)
    end
    if #book.tags > 0 then
        add(TextBoxWidget:new{
            text = table.concat(book.tags, " · "),
            face = F.small,
            fgcolor = Common.GRAY,
            width = w,
            height = 2 * TextWidget:new{ text = "Ag", face = F.small }:getSize().h,
            height_overflow_show_ellipsis = true,
        }, Common.S.gap)
    end
    add(TextWidget:new{ text = _("Formats"):upper(), face = F.small_bold, fgcolor = Common.GRAY }, Common.S.gap * 2)
    for _i, fmt in ipairs(book.formats) do
        local label = fmt
        local size = friendlySize(book.format_sizes[fmt])
        if size then label = label .. "  " .. size end
        if self:downloadedPath(fmt) then label = label .. "  · " .. _("on device") end
        add(TextWidget:new{
            text = label,
            face = fmt == self.fmt and F.body_bold or F.body,
            max_width = w,
        })
    end
    if #book.formats == 0 then
        add(TextWidget:new{ text = _("No files"), face = F.body, fgcolor = Common.GRAY })
    end
    return group
end

function BookDetails:actionButton(text, callback, primary, width)
    return Button:new{
        text = text,
        width = width,
        text_font_size = 22,
        bordersize = primary and Screen:scaleBySize(2) or 0,
        background = (not primary) and Common.LIGHT or nil,
        radius = Screen:scaleBySize(10),
        padding_v = Common.S.gap,
        callback = callback,
        show_parent = self,
    }
end

function BookDetails:buildButtons()
    local S = Common.S
    local W = self.dimen.w - 2 * S.margin
    local row = HorizontalGroup:new{}
    local busy = self.job and (self.job.status == "queued" or self.job.status == "downloading")
    local fmt = self.fmt
    local local_path = fmt and self:downloadedPath(fmt) or self.plugin:downloadedPath(self.book)
    local multi = #self.book.formats > 1

    if busy then
        table.insert(row, self:actionButton(_("Cancel download"), function()
            self.plugin.downloader:cancel(self.job)
        end, true, W))
    elseif not fmt then
        local label = #self.book.formats == 0 and _("No files to download") or _("No format KOReader can open")
        table.insert(row, self:actionButton(label, nil, false, W))
        row[1]:disable()
    elseif local_path then
        local half = math.floor((W - S.gap) / 2)
        table.insert(row, self:actionButton(_("Open"), function()
            self:onClose()
            self.plugin:openFile(local_path)
        end, true, multi and half or math.floor((W - S.gap) * 0.6)))
        table.insert(row, HorizontalSpan:new{ width = S.gap })
        table.insert(row, self:actionButton(multi and _("Formats…") or _("Download again"), function()
            if multi then self:chooseFormat() else self:startDownload(fmt) end
        end, false, multi and half or (W - S.gap - math.floor((W - S.gap) * 0.6))))
    else
        local main_w = multi and math.floor((W - S.gap) * 0.62) or W
        table.insert(row, self:actionButton(T(_("Download %1"), fmt), function()
            self:startDownload(fmt)
        end, true, main_w))
        if multi then
            table.insert(row, HorizontalSpan:new{ width = S.gap })
            table.insert(row, self:actionButton(_("Formats…"), function()
                self:chooseFormat()
            end, false, W - S.gap - main_w))
        end
    end
    return HorizontalGroup:new{ HorizontalSpan:new{ width = S.margin }, row }
end

function BookDetails:statusText()
    local job = self.job
    if not job then return "" end
    if job.status == "queued" then
        return _("Waiting to download…")
    elseif job.status == "downloading" then
        if job.size and job.size > 0 then
            local pct = math.min(99, math.floor(job.bytes * 100 / job.size / 5) * 5)
            return T(_("Downloading… %1%"), pct)
        end
        return T(_("Downloading… %1"), friendlySize(job.bytes) or "")
    elseif job.status == "completed" then
        return T(_("Saved to %1"), job.path)
    elseif job.status == "failed" then
        return job.error or _("Download failed.")
    elseif job.status == "cancelled" then
        return _("Download cancelled.")
    end
    return ""
end

function BookDetails:buildStatus()
    local S = Common.S
    local W = self.dimen.w
    local h = TextWidget:new{ text = "Ag", face = Common.F.small }:getSize().h + S.gap
    self.status_box = LeftContainer:new{
        dimen = Geom:new{ w = W, h = h },
        HorizontalGroup:new{
            HorizontalSpan:new{ width = S.margin },
            TextWidget:new{
                text = self:statusText(),
                face = Common.F.small,
                fgcolor = Common.GRAY,
                max_width = W - 2 * S.margin,
            },
        },
    }
    return self.status_box
end

function BookDetails:rebuild()
    local S = Common.S
    local W, H = self.dimen.w, self.dimen.h
    local header = Common.header{
        width = W,
        title = "",
        show_parent = self,
        actions = { { icon = "close", callback = function() self:onClose() end, allow_flash = false } },
    }
    local top = HorizontalGroup:new{
        align = "top",
        HorizontalSpan:new{ width = S.margin },
        self:buildCover(),
        HorizontalSpan:new{ width = S.gap * 2 },
        self:buildInfo(),
    }
    local content = VerticalGroup:new{
        align = "left",
        header,
        top,
        VerticalSpan:new{ width = S.gap * 2 },
        self:buildButtons(),
        VerticalSpan:new{ width = math.floor(S.gap / 2) },
        self:buildStatus(),
    }
    local used = content:getSize().h
    local desc_h = H - used - S.gap * 2
    local text = self.book.comments and util.htmlToPlainTextIfHtml(self.book.comments)
    if desc_h > S.row_h then
        table.insert(content, VerticalSpan:new{ width = S.gap })
        table.insert(content, HorizontalGroup:new{
            HorizontalSpan:new{ width = S.margin },
            ScrollTextWidget:new{
                text = (text and text ~= "") and text or _("No description."),
                face = Common.F.body,
                width = W - 2 * S.margin,
                height = desc_h,
                dialog = self,
            },
        })
        content:resetLayout() -- children added after measuring
    end
    if self[1] then self[1]:free() end
    self[1] = self:wrap(content)
    UIManager:setDirty(self, "ui")
end

function BookDetails:onJobUpdate(job)
    if job.status == "downloading" or job.status == "queued" then
        local text = self:statusText()
        if text == self.last_status then return end
        self.last_status = text
        local box = self.status_box
        box[1][2]:setText(text)
        UIManager:setDirty(self, "ui", box.dimen)
    else
        -- Finished: buttons change (Open / Download again), so rebuild once.
        self.last_status = nil
        self:rebuild()
        if self.on_change then self.on_change() end
    end
end

function BookDetails:chooseFormat()
    local dialog
    local buttons = {}
    for _i, fmt in ipairs(self.book.formats) do
        local size = friendlySize(self.book.format_sizes[fmt])
        local label = fmt .. (size and ("  " .. size) or "")
        if self:downloadedPath(fmt) then label = label .. "  · " .. _("on device") end
        if not Downloads.canOpen(fmt) then label = label .. "  · " .. _("cannot open") end
        table.insert(buttons, {{
            text = label,
            callback = function()
                UIManager:close(dialog)
                self.fmt = fmt
                self:rebuild()
            end,
        }})
    end
    dialog = ButtonDialog:new{ title = _("Choose format"), buttons = buttons }
    UIManager:show(dialog)
end

function BookDetails:startDownload(fmt)
    local existing = self:downloadedPath(fmt)
    if not existing then
        return self:queue(fmt)
    end
    local dialog
    dialog = ButtonDialog:new{
        title = T(_("%1 is already on this device."), fmt),
        buttons = {
            {{ text = _("Open"), callback = function()
                UIManager:close(dialog)
                self:onClose()
                self.plugin:openFile(existing)
            end }},
            {{ text = _("Replace"), callback = function()
                UIManager:close(dialog)
                self:queue(fmt, existing)
            end }},
            {{ text = _("Skip"), callback = function() UIManager:close(dialog) end }},
        },
    }
    UIManager:show(dialog)
end

function BookDetails:queue(fmt, replace_path)
    local plugin = self.plugin
    self.job = plugin:downloadBook(self.book, fmt, {
        replace_path = replace_path,
        on_conflict = function(_arg, final, resolve)
            local dialog
            dialog = ButtonDialog:new{
                title = T(_("A file named %1 already exists."), final:match("[^/]+$")),
                buttons = {
                    {{ text = _("Open existing"), callback = function()
                        UIManager:close(dialog)
                        resolve("skip")
                        plugin:openFile(final)
                    end }},
                    {{ text = _("Replace"), callback = function()
                        UIManager:close(dialog)
                        resolve("replace")
                    end }},
                    {{ text = _("Keep both"), callback = function()
                        UIManager:close(dialog)
                        resolve("keep")
                    end }},
                    {{ text = _("Skip"), callback = function()
                        UIManager:close(dialog)
                        resolve("skip")
                    end }},
                },
            }
            UIManager:show(dialog)
        end,
        on_done = function(job)
            if job.status ~= "completed" then return end
            UIManager:show(ConfirmBox:new{
                text = T(_("%1\n\nDownloaded."), job.book.title),
                ok_text = _("Open now"),
                cancel_text = _("Later"),
                ok_callback = function()
                    if self.dimen and not self.closed then self:onClose() end
                    plugin:openFile(job.path)
                end,
            })
        end,
    })
    self:rebuild()
end

function BookDetails:loadCover()
    if self.closed then return end
    local path = Store.thumbPath(self.server_key, self.library_id, self.book, self.cover_w, self.cover_h)
    local data = Store.readFile(path)
    if not data and NetworkMgr:isConnected() then
        local err
        data, err = self.client:fetchThumbnail(self.book.id, self.cover_w, self.cover_h)
        if data then
            Store.writeFile(path, data)
        else
            logger.warn("CalibreShelf: cover failed", err and err.kind)
        end
    end
    if not data or self.closed then return end
    local ok, bb = pcall(RenderImage.renderImageData, RenderImage, data, #data, false)
    if not ok or not bb then return end
    local bw, bh = bb:getWidth(), bb:getHeight()
    if bw > self.cover_w or bh > self.cover_h then
        local f = math.min(self.cover_w / bw, self.cover_h / bh)
        bb = RenderImage:scaleBlitBuffer(bb, math.floor(bw * f), math.floor(bh * f), true)
    end
    self.cover_bb = bb
    self:rebuild()
end

function BookDetails:onClose()
    self.closed = true
    self.plugin.downloader:removeListener(self.listener)
    UIManager:close(self)
    if self.close_callback then self.close_callback() end
    return true
end

function BookDetails:onCloseWidget()
    if self[1] then self[1]:free() end
    if self.cover_bb then
        self.cover_bb:free()
        self.cover_bb = nil
    end
end

return BookDetails
