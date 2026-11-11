--!nonstrict
-- Recording indicator layer: shows a thin red bar at the top of each output
-- while a recording is active. Click-through so it doesn't interfere with
-- grabit's own recording control bar.

local RED = "error"
local DIM = "#00000040"

local function render()
    local status = noctalia.state.get("status")
    local recording = type(status) == "table" and status.state == "recording"

    if not recording then
        layer.render(ui.column({}))
        return
    end

    local elapsed = ""
    if status.recordingSince and status.recordingSince > 0 then
        local secs = os.time() - status.recordingSince
        local mins = math.floor(secs / 60)
        local s = secs % 60
        elapsed = string.format(" %d:%02d", mins, s)
    end

    layer.render(ui.column({
        fill = DIM,
        height = 32,
    }, {
        ui.row({
            height = 32,
            padding = { left = 12, right = 12 },
            align = "center",
            gap = 8,
        }, {
            ui.glyph({ name = "record-filled", size = 12, color = RED }),
            ui.label({
                text = "Recording" .. elapsed,
                color = "on_surface",
                fontWeight = "bold",
                fontSize = 13,
            }),
        }),
    }))
end

noctalia.state.watch("status", render)
render()