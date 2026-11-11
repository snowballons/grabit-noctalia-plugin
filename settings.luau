--!nonstrict
-- Grabit settings panel: configures grabit via `grabit set` / `grabit get`.

local settings = {}

local function indexOf(arr, value)
    for i, v in ipairs(arr) do
        if v == value then return i - 1 end
    end
    return 0
end

-- Write a grabit config value via CLI (argv form avoids shell parsing of values)
local function grabitSet(key, value)
    noctalia.runAsync({ "grabit", "set", key, value }, function(res)
        if res.exitCode ~= 0 then
            noctalia.notifyError("Grabit", "Failed to set config: " .. (res.stderr or "unknown error"))
        end
    end)
end

function onOpen()
    settings.defaultAction = noctalia.getConfig("default_action") or "copy"
    settings.uploadService = noctalia.getConfig("upload_service") or ""
    settings.showCursor = noctalia.getConfig("show_cursor")
    if settings.showCursor == nil then settings.showCursor = true end

    renderSettings()
end

function renderSettings()
    panel.render(ui.column({
        padding = 16,
        gap = 12,
        width = 420,
    }, {
        ui.label({
            text = "Grabit Settings",
            fontWeight = "bold",
            fontSize = 16,
            padding = { bottom = 4 },
        }),
        ui.label({
            text = "Configure grabit behavior. Changes are applied immediately.",
            fontSize = 12,
            color = "on_surface_variant",
        }),

        ui.separator({}),

        -- Default action
        ui.label({ text = "Default action", fontWeight = "bold" }),
        ui.select({
            options = { "Copy to clipboard", "Save to file", "Upload" },
            selectedIndex = indexOf({ "copy", "save", "upload" }, settings.defaultAction),
            onChange = function(idx)
                local values = { "copy", "save", "upload" }
                local newVal = values[idx + 1]
                settings.defaultAction = newVal
                grabitSet("default_action", newVal)
            end,
        }),

        -- Upload service (shown when default is upload)
        ui.label({ text = "Upload service" }),
        ui.input({
            value = settings.uploadService or "",
            placeholder = "zipline, nest, or .sxcu uploader name",
            onChange = function(value)
                settings.uploadService = value
                grabitSet("service", value)
            end,
        }),

        -- Show cursor
        ui.row({ gap = 8, align = "center" }, {
            ui.toggle({
                checked = settings.showCursor,
                onChange = function(value)
                    settings.showCursor = value == "true"
                    grabitSet("capture.cursor", tostring(settings.showCursor))
                end,
            }),
            ui.label({ text = "Include mouse cursor in captures" }),
        }),

        ui.separator({}),

        -- Open grabit config directly
        ui.button({
            text = "Open grabit config directory",
            glyph = "folder-open",
            variant = "outline",
            onClick = function()
                noctalia.runAsync("xdg-open ~/.config/grabit")
            end,
        }),

        ui.button({
            text = "Reset grabit config",
            glyph = "refresh",
            variant = "destructive",
            onClick = function()
                -- grabit set --reset only resets individual keys; there is no
                -- "reset everything" subcommand. Reset the keys this plugin
                -- manages explicitly instead.
                -- Use argv form to avoid shell parsing.
                local keysToReset = {
                    "default_action",
                    "capture.cursor",
                    "service",
                }
                for _, key in ipairs(keysToReset) do
                    -- `grabit set <key> --reset` only works for keys.* keybinds.
                    -- `grabit unset <key>` removes the key and restores the default.
                    noctalia.runAsync({ "grabit", "unset", key }, function(res)
                        if res.exitCode ~= 0 then
                            noctalia.notifyError("Grabit", "Failed to reset " .. key .. ": " .. (res.stderr or ""))
                        end
                    end)
                end
                noctalia.notify("Grabit", "Config keys reset to defaults")
                -- Reload the panel to reflect the new values
                onOpen()
            end,
        }),
    }))
end