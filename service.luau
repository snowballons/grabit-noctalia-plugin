--!nonstrict
-- Grabit Launcher - headless service.
-- Owns grabit process tracking and spawns grabit for captures and recording.
-- The bar widget and shortcut are thin clients: they read the published "status"
-- and drive grabit by writing to the "command" channel.

noctalia.setUpdateInterval(500)

local CHECK_TICKS = 4 -- 4 * 500ms = 2s between process checks
local PENDING_TICKS = 4 -- 4 * 500ms = 2s wait for recording to start

local state = "idle" -- idle | pending | recording | paused
local recordingSince = 0
local isAvailable = false
local tickCount = 0
local pendingSince = 0
local processCheckPending = false
local stateGeneration = 0

local function cfg(key)
    return noctalia.getConfig(key)
end

local function log(msg)
    noctalia.log(`grabit: {msg}`)
end

-- ── Status publication ───────────────────────────────────────────

local function publishStatus()
    noctalia.state.set("status", {
        state = state,
        available = isAvailable,
        recordingSince = recordingSince,
    })
end

-- ── Availability ─────────────────────────────────────────────────

local function checkAvailability()
    if noctalia.commandExists("grabit") then
        log("grabit found")
        return true
    end
    if tickCount % CHECK_TICKS == 0 then -- log sparingly
        log("grabit NOT found on PATH")
    end
    return false
end

-- ── Command builders ─────────────────────────────────────────────

local function buildCaptureCommand(mode)
    local flags = ""

    if mode == "fullscreen" then
        flags = "-F"
    elseif mode == "window" then
        flags = "-w"
    elseif mode == "last" then
        flags = "-L"
    elseif mode == "pin" then
        flags = "--pin"
    elseif mode == "unpin-all" then
        flags = "--close-all"
    elseif mode == "ocr" then
        flags = "--tesseract"
    elseif mode == "annotate" then
        flags = "-e"
    elseif mode == "upload" then
        flags = "-u"
    elseif mode == "save" then
        flags = "-o"
    else
        -- default: copy to clipboard
        flags = "-c"
    end

    -- Upload service only applies to upload mode; grabit rejects service
    -- flags for any other action.
    if mode == "upload" then
        local service = cfg("upload_service")
        if service ~= "" and service ~= nil then
            flags = flags .. " --" .. service
        end
    end

    -- Cursor visibility is the `capture.cursor` config key (written by the
    -- settings panel). grabit has no --no-cursor flag, so don't pass one.
    return `grabit {flags}`
end

local function buildRecordCommand()
    return "grabit --record"
end

-- ── State management ─────────────────────────────────────────────

local function setState(nextState)
    if state == nextState then return end
    log(`state: {state} → {nextState}`)
    state = nextState
    stateGeneration += 1
    publishStatus()
end

-- Defer spawning so a closing panel/tooltip is gone before grabit freezes the
-- screen. grabit's --delay flag only accepts whole seconds, so wait here via
-- runAsync's documented onResult callback instead.
local function defer(delayMs, fn)
    if type(delayMs) ~= "number" or delayMs <= 0 then
        fn()
        return
    end

    local ok = noctalia.runAsync({ "sleep", string.format("%.3f", delayMs / 1000) }, fn)
    if not ok then
        log("failed to defer, running immediately")
        fn()
    end
end

-- ── Process detection ────────────────────────────────────────────

local function detectRecordingState(callback)
    local pending = 1

    local function finish(recording)
        pending -= 1
        if pending > 0 then return end
        callback(recording)
    end

    -- Check for grabit --record process
    local ok = noctalia.processMatches(function(matched)
        log(`process match --record: {matched}`)
        finish(matched)
    end, "grabit", "--record")
    if not ok then
        log("processMatches unavailable")
        finish(false)
    end
end

-- ── Recording controls ───────────────────────────────────────────

local function startRecording(delayMs)
    if not isAvailable or state ~= "idle" then return end

    defer(delayMs, function()
        if not isAvailable or state ~= "idle" then return end

        setState("pending")
        pendingSince = tickCount

        local cmd = buildRecordCommand()
        log(`spawning: {cmd}`)

        -- Detached form (no callback): the callback form has a default 5s
        -- timeout and Noctalia kills the process group when it fires, which
        -- cut recordings short. update() detects the process instead.
        local ok = noctalia.runAsync(cmd)

        if not ok then
            log("failed to spawn grabit --record")
            setState("idle")
            noctalia.notifyError("Grabit", "Failed to start recording")
        end
    end)
end

local function stopRecording()
    if state == "idle" then return end

    log("stopping recording (toggle)")
    -- grabit --record toggles: second invocation stops it
    noctalia.runAsync("grabit --record")
    recordingSince = 0
    setState("idle")
end

-- ── Capture spawning ─────────────────────────────────────────────

local function spawnCapture(mode, delayMs)
    if not isAvailable then
        noctalia.notifyError("Grabit", "grabit is not installed")
        return
    end
    if state ~= "idle" then
        noctalia.notifyError("Grabit", "A capture or recording is already in progress")
        return
    end

    defer(delayMs, function()
        if state ~= "idle" then
            noctalia.notifyError("Grabit", "A capture or recording is already in progress")
            return
        end

        local cmd = buildCaptureCommand(mode)
        log(`spawning: {cmd}`)

        -- Detached form (no callback): a region select can stay open longer
        -- than the callback form's default 5s timeout, which would kill it.
        local ok = noctalia.runAsync(cmd)

        if not ok then
            log("failed to spawn grabit")
            noctalia.notifyError("Grabit", "Failed to launch grabit")
        end
    end)
end

-- ── Update loop ──────────────────────────────────────────────────

local function checkProcessState(recording)
    if state == "pending" then
        if tickCount - pendingSince >= PENDING_TICKS then
            if recording then
                log("recording active")
                recordingSince = os.time()
                setState("recording")
            else
                log("recording never started")
                setState("idle")
                noctalia.notifyError("Grabit", "Recording failed to start")
            end
        end
    elseif state == "recording" or state == "paused" then
        if not recording then
            log("recording process ended")
            recordingSince = 0
            setState("idle")
        end
    end
end

local function requestProcessStateCheck()
    if processCheckPending then return end
    processCheckPending = true
    local generation = stateGeneration

    detectRecordingState(function(recording)
        processCheckPending = false
        if generation ~= stateGeneration then return end
        if recording then
            isAvailable = true
        end
        checkProcessState(recording)
        publishStatus()
    end)
end

function update()
    tickCount += 1

    if not isAvailable then
        isAvailable = checkAvailability()
    end

    if state ~= "idle" and tickCount % CHECK_TICKS == 0 then
        requestProcessStateCheck()
    end

    publishStatus()
end

-- ── IPC ──────────────────────────────────────────────────────────

function onIpc(event, payload)
    log(`ipc '{event}' (state={state})`)

    if event == "capture" then
        local mode = "copy"
        local delayMs = nil
        if type(payload) == "table" then
            if payload.mode ~= nil then
                mode = payload.mode
            end
            delayMs = payload.delay_ms
        elseif type(payload) == "string" and payload ~= "" then
            mode = payload
        end
        spawnCapture(mode, delayMs)

    elseif event == "menu" then
        noctalia.togglePanel("snowballons/grabit:menu")

    elseif event == "record" then
        startRecording(if type(payload) == "table" then payload.delay_ms else nil)

    elseif event == "stop" then
        stopRecording()

    elseif event == "settings" then
        noctalia.togglePanel("snowballons/grabit:settings")
    end
end

-- ── Lifecycle ────────────────────────────────────────────────────

function onExit()
    if state ~= "idle" then
        log("stopping recording (service exit)")
        stopRecording()
    end
end

-- Widget/shortcut drive this through the state channel
noctalia.state.watch("command", function(cmd)
    local action = if type(cmd) == "table" and cmd.action ~= nil then cmd.action else cmd
    if type(action) == "string" then
        onIpc(action, if type(cmd) == "table" then cmd else nil)
    end
end)
