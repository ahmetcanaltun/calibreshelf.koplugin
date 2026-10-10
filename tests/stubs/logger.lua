-- Test stub for KOReader's logger: quiet unless CS_VERBOSE is set.
local verbose = os.getenv("CS_VERBOSE")
local function out(level) return function(...) if verbose or level == "err" then print("[" .. level .. "]", ...) end end end
return { dbg = out("dbg"), info = out("info"), warn = out("warn"), err = out("err") }
