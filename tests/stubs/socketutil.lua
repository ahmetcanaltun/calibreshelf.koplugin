-- Test stub: the parts of koreader/koreader frontend/socketutil.lua that api/calibre.lua uses.
local http = require("socket.http")
local ltn12 = require("ltn12")
local socketutil = { block_timeout = 60, total_timeout = -1 }
socketutil.LARGE_BLOCK_TIMEOUT = 10
socketutil.LARGE_TOTAL_TIMEOUT = 30
socketutil.FILE_BLOCK_TIMEOUT = 15
socketutil.FILE_TOTAL_TIMEOUT = 60
socketutil.TIMEOUT_CODE = "timeout"
socketutil.SSL_HANDSHAKE_CODE = "wantread"
socketutil.SINK_TIMEOUT_CODE = "sink timeout"
function socketutil:set_timeout(b, t) self.block_timeout, self.total_timeout = b or 5, t or 15; http.TIMEOUT = self.block_timeout end
function socketutil:reset_timeout() self.block_timeout, self.total_timeout = 60, -1; http.TIMEOUT = 60 end
function socketutil.table_sink(t) return ltn12.sink.table(t) end
function socketutil.redact_request(r)
    local safe = {}
    for k, v in pairs(r) do safe[k] = v end
    if r.headers then
        safe.headers = {}
        for k, v in pairs(r.headers) do safe.headers[k] = k:lower() == "authorization" and "REDACTED" or v end
    end
    return safe
end
return socketutil
