-- Test-only KOReader user patch (never shipped): opens a CalibreShelf screen
-- on startup so the emulator can be screenshotted without menu navigation.
-- CS_AUTOOPEN = "library" | "settings" | "zenwidget"
local mode = os.getenv("CS_AUTOOPEN")
if not mode or mode == "" then return end
local UIManager = require("ui/uimanager")
UIManager:scheduleIn(3, function()
    local FileManager = require("apps/filemanager/filemanager")
    local plugin = FileManager.instance and FileManager.instance.calibreshelf
    if not plugin then return end
    if mode == "settings" then
        plugin:showSettings()
    elseif mode == "zenwidget" then
        -- Render the Home widget through the same build(ctx) ZenOS calls.
        local Blitbuffer = require("ffi/blitbuffer")
        local CenterContainer = require("ui/widget/container/centercontainer")
        local FrameContainer = require("ui/widget/container/framecontainer")
        local Geom = require("ui/geometry")
        local Screen = require("device").screen
        local ZenHome = package.loaded["calibreshelf/widgets/zenhome"]
        ZenHome.refresh(plugin, true)
        local w, h = Screen:getWidth() - 60, math.floor(Screen:getHeight() * 3 / 13)
        local frame = FrameContainer:new{
            width = Screen:getWidth(), height = Screen:getHeight(),
            background = Blitbuffer.COLOR_WHITE, bordersize = 0, padding = 0,
            CenterContainer:new{
                dimen = Geom:new{ w = Screen:getWidth(), h = Screen:getHeight() },
                FrameContainer:new{ bordersize = 2, padding = 0, ZenHome.build(plugin, { width = w, height = h }) },
            },
        }
        frame.covers_fullscreen = true
        UIManager:show(frame, "full")
    else
        plugin:showLibrary()
    end
end)
