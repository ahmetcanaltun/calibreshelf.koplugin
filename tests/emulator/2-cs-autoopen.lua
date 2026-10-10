-- Test-only KOReader user patch (never shipped): opens a CalibreShelf screen
-- on startup so the emulator can be screenshotted without menu navigation.
-- CS_AUTOOPEN = "library" | "settings"
local mode = os.getenv("CS_AUTOOPEN")
if not mode then return end
local UIManager = require("ui/uimanager")
UIManager:scheduleIn(3, function()
    local FileManager = require("apps/filemanager/filemanager")
    local plugin = FileManager.instance and FileManager.instance.calibreshelf
    if not plugin then return end
    if mode == "settings" then plugin:showSettings() else plugin:showLibrary() end
end)
