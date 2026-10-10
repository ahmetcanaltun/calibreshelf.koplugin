-- Test stub: verbatim copies of the koreader/koreader frontend/util.lua functions we use.
local util = {}
function util.trim(s)
    local from = s:match"^%s*()"
    return from > #s and "" or s:match(".*%S", from)
end
function util.urlEncode(url, preserve_chars)
    local char_to_hex = function(c)
        return string.format("%%%02X", string.byte(c))
    end
    preserve_chars = preserve_chars or ""
    local pattern_base = "^%w%-%._~"
    local pattern = string.format("([%s%s])", pattern_base, preserve_chars)
    if url == nil then
        return
    end
    url = url:gsub("\n", "\r\n")
    url = url:gsub(pattern, char_to_hex)
    return url
end
function util.urlDecode(url)
    local hex_to_char = function(x)
        return string.char(tonumber(x, 16))
    end
    if url == nil then
        return
    end
    url = url:gsub("%%(%x%x)", hex_to_char)
    return url
end
return util
