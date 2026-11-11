--!nonstrict
-- Grabit mode menu: right-click panel with all capture mode options.

local function closePanel()
    panel.close()
end

local function captureMode(mode)
    noctalia.state.set("command", { action = "capture", mode = mode })
    closePanel()
end

local function recordMode()
    noctalia.state.set("command", { action = "record" })
    closePanel()
end

local function openSettings()
    closePanel()
    noctalia.togglePanel("snowballons/grabit:settings")
end

function onOpen()
    panel.render(ui.column({
        padding = 8,
        gap = 2,
        width = 220,
    }, {
        ui.label({
            text = "Grabit",
            fontWeight = "bold",
            fontSize = 14,
            padding = { bottom = 8, top = 4 },
        }),

        -- Capture modes
        ui.button({
            text = "Region (copy)",
            glyph = "screenshot",
            variant = "ghost",
            onClick = function() captureMode("copy") end,
        }),
        ui.button({
            text = "Region (save)",
            glyph = "download",
            variant = "ghost",
            onClick = function() captureMode("save") end,
        }),
        ui.button({
            text = "Region (upload)",
            glyph = "upload",
            variant = "ghost",
            onClick = function() captureMode("upload") end,
        }),

        ui.separator({ margin = 4 }),

        ui.button({
            text = "Fullscreen",
            glyph = "maximize",
            variant = "ghost",
            onClick = function() captureMode("fullscreen") end,
        }),
        ui.button({
            text = "Window",
            glyph = "window",
            variant = "ghost",
            onClick = function() captureMode("window") end,
        }),
        ui.button({
            text = "Last region",
            glyph = "history",
            variant = "ghost",
            onClick = function() captureMode("last") end,
        }),

        ui.separator({ margin = 4 }),

        ui.button({
            text = "Annotate",
            glyph = "edit",
            variant = "ghost",
            onClick = function() captureMode("annotate") end,
        }),
        ui.button({
            text = "OCR to clipboard",
            glyph = "text-recognition",
            variant = "ghost",
            onClick = function() captureMode("ocr") end,
        }),
        ui.button({
            text = "Pin to desktop",
            glyph = "pin",
            variant = "ghost",
            onClick = function() captureMode("pin") end,
        }),

        ui.separator({ margin = 4 }),

        ui.button({
            text = "Start recording",
            glyph = "video",
            variant = "ghost",
            onClick = recordMode,
        }),

        ui.separator({ margin = 8 }),

        ui.button({
            text = "Settings...",
            glyph = "settings",
            variant = "ghost",
            onClick = openSettings,
        }),
    }))
end
