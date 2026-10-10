-- Test stub: KOReader's json module API (decode/encode) backed by dkjson.
local dkjson = require("dkjson")
return {
    decode = function(s) local v, _, err = dkjson.decode(s); if err then error(err) end; return v end,
    encode = function(t) return dkjson.encode(t) end,
}
