-- Download queue. One job at a time, each in a forked subprocess so the UI
-- stays usable. The child writes to "<dir>/.calibreshelf-<id>.<fmt>.part";
-- the parent polls its size for progress and renames it into place when the
-- child reports success.
--
-- job = {
--   book, fmt, dir, client_opts = {url, username, password, library_id},
--   server_key, library_id,
--   replace_path = existing file to overwrite (optional),
--   on_conflict = function(job, final_path, resolve) (optional; default keeps both),
--   on_done = function(job) (optional),
-- }
-- job.status: queued | downloading | completed | failed | cancelled | skipped

local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local buffer = require("string.buffer")
local ffiutil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")

local csrequire = require("calibreshelf/require")
local Calibre = csrequire("api/calibre")
local Downloads = csrequire("lib/downloads")

local POLL_INTERVAL = 0.5

local Downloader = {}
Downloader.__index = Downloader

function Downloader:new(downloads)
    return setmetatable({
        downloads = downloads,
        jobs = {},
        listeners = {},
        current = nil,
    }, self)
end

function Downloader:addListener(fn)
    self.listeners[fn] = true
end

function Downloader:removeListener(fn)
    self.listeners[fn] = nil
end

function Downloader:notify(job)
    for fn in pairs(self.listeners) do
        local ok, err = pcall(fn, job)
        if not ok then logger.warn("CalibreShelf: download listener failed", err) end
    end
end

function Downloader:enqueue(job)
    job.status = "queued"
    job.bytes = 0
    job.size = job.book.format_sizes and job.book.format_sizes[job.fmt]
    job.error = nil
    table.insert(self.jobs, job)
    self:notify(job)
    self:startNext()
    return job
end

function Downloader:pending()
    local n = 0
    for _i, job in ipairs(self.jobs) do
        if job.status == "queued" or job.status == "downloading" then n = n + 1 end
    end
    return n
end

function Downloader:startNext()
    if self.current then return end
    local job
    for _i, j in ipairs(self.jobs) do
        if j.status == "queued" then
            job = j
            break
        end
    end
    if not job then return end
    NetworkMgr:runWhenOnline(function() self:run(job) end)
end

function Downloader:fail(job, err, tmp)
    if tmp then os.remove(tmp) end
    job.status = "failed"
    job.error = err.message
    logger.warn("CalibreShelf: download failed", job.book.id, job.fmt, err.kind, err.detail)
    self:done(job)
end

function Downloader:done(job)
    if self.current == job then self.current = nil end
    self:notify(job)
    if job.on_done then
        local ok, err = pcall(job.on_done, job)
        if not ok then logger.warn("CalibreShelf: on_done failed", err) end
    end
    self:startNext()
end

function Downloader:run(job)
    if self.current or job.status ~= "queued" then return end
    self.current = job
    job.status = "downloading"
    self:notify(job)

    if not util.directoryExists(job.dir) then
        util.makePath(job.dir)
    end
    local usage = util.diskUsage(job.dir)
    if usage.available and job.size and usage.available < job.size + 1024 * 1024 then
        return self:fail(job, Calibre.makeError(Calibre.ERR.DISK,
            string.format("%s: %d bytes free, need %d", job.dir, usage.available, job.size)))
    end

    local tmp = Downloads.tempPath(job.dir, job.book, job.fmt)
    os.remove(tmp)
    job.tmp = tmp
    local opts, book_id, fmt = job.client_opts, job.book.id, job.fmt
    local pid, fd = ffiutil.runInSubProcess(function(_arg, write_fd)
        local headers, err = Calibre:new(opts):downloadFormat(book_id, fmt, tmp)
        local result = {
            filename = headers and Calibre.filenameFromHeaders(headers) or nil,
            err = err and { kind = err.kind, message = err.message, detail = err.detail } or nil,
        }
        ffiutil.writeToFD(write_fd, buffer.encode(result), true)
    end, true)
    if not pid then
        return self:fail(job, Calibre.makeError(Calibre.ERR.HTTP, "fork: " .. tostring(fd),
            _("Could not start the download.")), tmp)
    end
    job.pid, job.fd = pid, fd
    self:poll(job)
end

function Downloader:poll(job)
    UIManager:scheduleIn(POLL_INTERVAL, function()
        if job.status ~= "downloading" or self.current ~= job then return end
        local size = lfs.attributes(job.tmp, "size")
        if size and size ~= job.bytes then
            job.bytes = size
            self:notify(job)
        end
        if not ffiutil.isSubProcessDone(job.pid) then
            return self:poll(job)
        end
        local data = ffiutil.readAllFromFD(job.fd)
        job.pid, job.fd = nil, nil
        local ok, result = pcall(buffer.decode, data)
        if not ok or type(result) ~= "table" then
            return self:fail(job, Calibre.makeError(Calibre.ERR.HTTP, "no result from download process",
                _("The download was interrupted.")), job.tmp)
        end
        if result.err then
            return self:fail(job, result.err, job.tmp)
        end
        self:finish(job, result.filename)
    end)
end

local function uniquePath(path)
    local base, ext = path:match("^(.-)(%.[^./]+)$")
    if not base then base, ext = path, "" end
    for i = 2, 99 do
        local candidate = string.format("%s (%d)%s", base, i, ext)
        if not lfs.attributes(candidate) then return candidate end
    end
    return path
end

function Downloader:finish(job, server_filename)
    local final = Downloads.finalPath(job.dir, server_filename, job.book, job.fmt)
    if lfs.attributes(final) and final ~= job.replace_path then
        if job.on_conflict then
            job.on_conflict(job, final, function(choice)
                if choice == "replace" then
                    self:commit(job, final)
                elseif choice == "keep" then
                    self:commit(job, uniquePath(final))
                else -- skip / open existing
                    os.remove(job.tmp)
                    job.status = "skipped"
                    job.path = final
                    self:done(job)
                end
            end)
            return
        end
        final = uniquePath(final)
    end
    self:commit(job, final)
end

function Downloader:commit(job, final)
    local ok, err = os.rename(job.tmp, final)
    if not ok then
        return self:fail(job, Calibre.makeError(Calibre.ERR.DISK, "rename: " .. tostring(err)), job.tmp)
    end
    if job.replace_path and job.replace_path ~= final then
        os.remove(job.replace_path)
    end
    job.status = "completed"
    job.path = final
    self.downloads:record(job.server_key, job.library_id, job.book.id, job.fmt, final)
    logger.info("CalibreShelf: downloaded", final)
    local FileManager = require("apps/filemanager/filemanager")
    if FileManager.instance then FileManager.instance:onRefresh() end
    self:done(job)
end

function Downloader:cancel(job)
    if job.status == "queued" then
        job.status = "cancelled"
        self:notify(job)
    elseif job.status == "downloading" then
        job.status = "cancelled"
        if job.pid then
            local pid, fd, tmp = job.pid, job.fd, job.tmp
            ffiutil.terminateSubProcess(pid)
            local function collect()
                if ffiutil.isSubProcessDone(pid) then
                    if fd then ffiutil.readAllFromFD(fd) end
                    os.remove(tmp)
                else
                    UIManager:scheduleIn(1, collect)
                end
            end
            UIManager:scheduleIn(1, collect)
            job.pid, job.fd = nil, nil
        end
        self:done(job)
    end
end

function Downloader:retry(job)
    if job.status == "failed" or job.status == "cancelled" then
        job.status = "queued"
        job.bytes = 0
        job.error = nil
        self:notify(job)
        self:startNext()
    end
end

function Downloader:clearFinished()
    local keep = {}
    for _i, job in ipairs(self.jobs) do
        if job.status == "queued" or job.status == "downloading" then
            table.insert(keep, job)
        end
    end
    self.jobs = keep
end

return Downloader
