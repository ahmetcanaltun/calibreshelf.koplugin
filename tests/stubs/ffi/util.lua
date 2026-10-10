-- Test stub for koreader-base ffi/util: only template(), same %1..%n behaviour.
local util = {}
function util.template(str, ...)
    local params = { ... }
    return (str:gsub("%%(%d+)", function(i) return tostring(params[tonumber(i)]) end))
end
return util
