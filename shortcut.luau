--!nonstrict
-- Grabit Launcher - control-center shortcut.
-- Mirrors the bar widget: left click captures, right click opens menu.

local state = "idle"
local available = false

local function applyStatus(status)
    if type(status) == "table" then
        state = status.state or "idle"
        available = if status.available then true else false
    end
end

function onClick()
    if not available then return end
    if state ~= "idle" then
        noctalia.state.set("command", { action = "stop" })
    else
        noctalia.state.set("command", { action = "capture", mode = noctalia.getConfig("default_action") })
    end
end

function onRightClick()
    if not available then return end
    noctalia.state.set("command", { action = "menu" })
end

applyStatus(noctalia.state.get("status"))
noctalia.state.watch("status", applyStatus)