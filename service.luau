--!nonstrict
-- Grabit Launcher - headless service.
-- Owns grabit process tracking and spawns grabit for captures and recording.
-- The bar widget and shortcut are thin clients: they read the published "status"
-- and drive grabit by writing to the "command" channel.

noctalia.setUpdateInterval(500)

local CHECK_TICKS = 4 -- 4 * 500ms = 2s between process checks
local PENDING_TICKS = 4 -- 4 * 500ms = 2s wait for recording to start

local function log(msg)
    noctalia.log(`grabit: {msg}`)
end

-- grabit writes the recording PID here (XDG_RUNTIME_DIR / grabit_recording.pid).
-- XDG_RUNTIME_DIR is mandatory in every Wayland session (set by the session
-- manager before any user process starts), so os.getenv should always succeed.
-- The fallback reads the real UID from /proc/self/loginuid rather than using
-- os.getenv("UID"), which is a bash shell variable and is never exported.
local function resolveRuntimeDir()
    local xdg = os.getenv("XDG_RUNTIME_DIR")
    if xdg and xdg ~= "" then return xdg end

    -- Fallback: derive from the real UID via /proc/self/loginuid
    local ok, uid = pcall(function()
        return noctalia.readFile("/proc/self/loginuid")
    end)
    if ok and uid then
        uid = uid:match("^%s*(%d+)%s*$")
        if uid and tonumber(uid) ~= 4294967295 then -- 0xFFFFFFFF = unset loginuid
            return "/run/user/" .. uid
        end
    end

    -- Last resort: log and return nil so callers skip PID-file tracking
    log("cannot determine XDG_RUNTIME_DIR; PID tracking disabled")
    return nil
end
local GRABIT_PID_FILE = (function()
    local dir = resolveRuntimeDir()
    return dir and (dir .. "/grabit_recording.pid") or nil
end)()

local state = "idle" -- idle | pending | recording | paused
local recordingSince = 0
local isAvailable = false
local tickCount = 0
local pendingSince = 0
local processCheckPending = false
local stateGeneration = 0
-- PID of the grabit --record process this service spawned.
-- nil when no recording is owned by this plugin instance.
-- Used to distinguish our recording from a foreign one started outside the plugin.
local ownedPid = nil

local function cfg(key)
    return noctalia.getConfig(key)
end

-- ── Status publication ───────────────────────────────────────────

-- Track last-published values so we can skip redundant state.set calls.
-- publishStatus() fires every 500ms unconditionally from update(); without this
-- guard it wakes every watcher (widget, recording_layer) 2×/s even when idle.
local lastPublished = { state = "", available = false, recordingSince = -1 }

local function publishStatus()
    if lastPublished.state == state
        and lastPublished.available == isAvailable
        and lastPublished.recordingSince == recordingSince
    then
        return
    end
    lastPublished = { state = state, available = isAvailable, recordingSince = recordingSince }
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

-- Returns an argv table for the given capture mode.
-- Using an array avoids shell parsing of service names or future flag values.
local function buildCaptureArgv(mode)
    local args = { "grabit" }

    if mode == "fullscreen" then
        table.insert(args, "-F")
    elseif mode == "window" then
        table.insert(args, "-w")
    elseif mode == "last" then
        table.insert(args, "-L")
    elseif mode == "pin" then
        table.insert(args, "--pin")
    elseif mode == "unpin-all" then
        table.insert(args, "--close-all")
    elseif mode == "ocr" then
        table.insert(args, "--tesseract")
    elseif mode == "annotate" then
        table.insert(args, "-e")
    elseif mode == "upload" then
        table.insert(args, "-u")
    elseif mode == "save" then
        table.insert(args, "-o")
    else
        -- default: copy to clipboard
        table.insert(args, "-c")
    end

    -- Upload service only applies to upload mode; grabit rejects service
    -- flags for any other action.
    if mode == "upload" then
        local service = cfg("upload_service")
        if service ~= "" and service ~= nil then
            -- Pass as a separate argv element; no shell quoting needed.
            table.insert(args, "--" .. service)
        end
    end

    -- Cursor visibility is the `capture.cursor` config key (written by the
    -- settings panel). grabit has no --no-cursor flag, so don't pass one.
    return args
end

local function buildRecordCommand()
    return { "grabit", "--record" }
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

-- Read the PID from grabit's lockfile (written at recording start).
-- Returns the PID as a number, or nil if the path is unknown, the file is
-- absent, or it contains something other than a bare integer.
local function readGrabitPidFile()
    if not GRABIT_PID_FILE then return nil end
    local ok, result = pcall(function()
        return noctalia.readFile(GRABIT_PID_FILE)
    end)
    if not ok or not result then return nil end
    local pid = tonumber(result:match("^%s*(%d+)%s*$"))
    return pid
end

local function detectRecordingState(callback)
    -- Check for any grabit --record process via /proc scan
    local ok = noctalia.processMatches(function(anyRecording)
        log(`process match --record: {anyRecording}`)

        if not anyRecording then
            -- No grabit --record running at all
            callback(false)
            return
        end

        -- A grabit --record process exists somewhere.  Only treat it as
        -- *ours* if either:
        --   (a) we have an ownedPid and the pid file still matches, or
        --   (b) we are in pending/recording/paused state (we spawned it).
        -- This prevents the plugin from hijacking a foreign recording
        -- started via a sway keybind or another terminal session.
        if ownedPid ~= nil then
            local filePid = readGrabitPidFile()
            if filePid == ownedPid then
                callback(true)
            else
                -- The pid file changed: our process ended and a new, foreign
                -- one started. Disown it.
                log(`pid file changed (expected {ownedPid}, got {tostring(filePid)}) — disowning`)
                ownedPid = nil
                callback(false)
            end
        elseif state == "pending" then
            -- We just spawned; we do not yet know the PID. Accept the match
            -- and record the pid from the lockfile once available.
            local filePid = readGrabitPidFile()
            if filePid then
                log(`adopted pid {filePid} from lockfile`)
                ownedPid = filePid
            end
            callback(true)
        else
            -- A grabit --record is running but we did not start it.
            log("foreign grabit --record detected; ignoring")
            callback(false)
        end
    end, "grabit", "--record")

    if not ok then
        log("processMatches unavailable")
        callback(false)
    end
end

-- ── Recording controls ───────────────────────────────────────────

local function startRecording(delayMs)
    if not isAvailable or state ~= "idle" then return end

    defer(delayMs, function()
        if not isAvailable or state ~= "idle" then return end

        setState("pending")
        pendingSince = tickCount
        ownedPid = nil -- will be populated by detectRecordingState once the lockfile appears

        local cmd = buildRecordCommand()
        log(`spawning: grabit --record`)

        -- Detached form (no callback): the callback form has a default 5s
        -- timeout and Noctalia kills the process group when it fires, which
        -- cut recordings short. update() detects the process instead.
        local ok = noctalia.runAsync(cmd)

        if not ok then
            log("failed to spawn grabit --record")
            ownedPid = nil
            setState("idle")
            noctalia.notifyError("Grabit", "Failed to start recording")
        end
    end)
end

local function stopRecording()
    if state == "idle" then return end

    log("stopping recording (toggle)")
    -- grabit --record is a toggle that works by pid file: it reads
    -- $XDG_RUNTIME_DIR/grabit_recording.pid, signals the process to stop, and
    -- removes the file.  This is true whether the recording is active or paused
    -- (the pid file exists in both cases), so there is no need to send --pause
    -- first to resume before stopping.
    noctalia.runAsync({ "grabit", "--record" })
    ownedPid = nil
    recordingSince = 0
    setState("idle")
end

-- Send grabit --pause (SIGUSR1 to the recording process).
-- grabit toggles pause/resume on each --pause invocation.
local function pauseRecording()
    if state ~= "recording" then return end

    log("pausing recording")
    local ok = noctalia.runAsync({ "grabit", "--pause" })
    if ok then
        setState("paused")
    else
        log("failed to send --pause")
        noctalia.notifyError("Grabit", "Failed to pause recording")
    end
end

local function resumeRecording()
    if state ~= "paused" then return end

    log("resuming recording")
    local ok = noctalia.runAsync({ "grabit", "--pause" })
    if ok then
        setState("recording")
    else
        log("failed to send --pause (resume)")
        noctalia.notifyError("Grabit", "Failed to resume recording")
    end
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

        local cmd = buildCaptureArgv(mode)
        log(`spawning: grabit {mode}`)

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

    elseif event == "pause" then
        pauseRecording()

    elseif event == "resume" then
        resumeRecording()

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
        ownedPid = nil
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
