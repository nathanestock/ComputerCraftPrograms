local nlib = require("nlib")
local plib = require("plib")

local fs = rawget(_G, "fs")
local textutils = rawget(_G, "textutils")
local rednet = rawget(_G, "rednet")
local sleep = rawget(_G, "sleep") or function(_) end
local term = rawget(_G, "term")
local parallel = rawget(_G, "parallel")
local ccRead = rawget(_G, "read") or function() return nil end
local ccWrite = rawget(_G, "write") or function(msg) print(tostring(msg or "")) end
local printError = rawget(_G, "printError") or function(msg) print(tostring(msg)) end
local epochFn = os and rawget(os, "epoch")
local pullEventFn = os and rawget(os, "pullEvent")
local startTimerFn = os and rawget(os, "startTimer")

local getComputerIDFn = (os and rawget(os, "getComputerID")) or rawget(_G, "getComputerID")
local getComputerLabelFn = (os and rawget(os, "getComputerLabel")) or rawget(_G, "getComputerLabel")

local STATE_FILE = "digital_mining_manager_state.json"
local DISCOVERY_PROTOCOL = "digital_mining_discovery"
local PROTOCOL_PREFIX = "digital_mining_"

local function nowSeconds()
    if type(epochFn) == "function" then
        return math.floor(epochFn("utc") / 1000)
    end
    return math.floor(os.clock())
end

local function computerID()
    if type(getComputerIDFn) == "function" then
        return tonumber(getComputerIDFn()) or -1
    end
    return -1
end

local function computerLabel()
    if type(getComputerLabelFn) == "function" then
        return tostring(getComputerLabelFn() or ("manager_" .. tostring(computerID())))
    end
    return "manager_" .. tostring(computerID())
end

local function managerProtocolForLabel(label)
    return PROTOCOL_PREFIX .. tostring(label)
end

local function chunkOriginFromCoordinate(value)
    local n = math.floor(tonumber(value) or 0)
    local remainder = ((n % 16) + 16) % 16
    return n - remainder
end

local function normalizeTaskLocation(x, z)
    local requestedX = tonumber(x) or 0
    local requestedZ = tonumber(z) or 0
    local chunkOriginX = chunkOriginFromCoordinate(requestedX)
    local chunkOriginZ = chunkOriginFromCoordinate(requestedZ)

    return {
        requestedX = requestedX,
        requestedZ = requestedZ,
        chunkOriginX = chunkOriginX,
        chunkOriginZ = chunkOriginZ,
        turtleTargetX = chunkOriginX + 3,
        turtleTargetZ = chunkOriginZ + 3
    }
end

local function makeDefaultState()
    local label = computerLabel()
    return {
        schemaVersion = 1,
        manager = {
            label = label,
            protocol = managerProtocolForLabel(label),
            id = computerID()
        },
        settingsDefaults = {
            radius = 32,
            minY = -64,
            maxY = 319,
            silkTouch = true,
            autoEject = true
        },
        filterPresets = {
            ores = {
                {
                    ["type"] = "MINER_TAG_FILTER",
                    ["tag"] = "*:ores"
                }
            }
        },
        workers = {},
        queue = {},
        active = {},
        completed = {},
        minedHistory = {},
        nextTaskId = 1,
        dispatchPaused = false,
        updatedAt = nowSeconds()
    }
end

local state = makeDefaultState()

local function shallowCopy(tbl)
    if type(tbl) ~= "table" then
        return tbl
    end
    local out = {}
    for k, v in pairs(tbl) do
        out[k] = v
    end
    return out
end

local function loadState()
    if not fs or not fs.exists or not fs.exists(STATE_FILE) then
        return makeDefaultState()
    end

    local file = fs.open(STATE_FILE, "r")
    if not file then
        return makeDefaultState()
    end

    local raw = file.readAll() or ""
    file.close()

    local parsed = nil
    if textutils and textutils.unserializeJSON then
        parsed = textutils.unserializeJSON(raw)
    end
    if type(parsed) ~= "table" and textutils and textutils.unserialize then
        parsed = textutils.unserialize(raw)
    end

    if type(parsed) ~= "table" then
        return makeDefaultState()
    end

    local defaults = makeDefaultState()
    parsed.manager = type(parsed.manager) == "table" and parsed.manager or defaults.manager
    parsed.manager.label = parsed.manager.label or defaults.manager.label
    parsed.manager.protocol = parsed.manager.protocol or managerProtocolForLabel(parsed.manager.label)
    parsed.manager.id = parsed.manager.id or defaults.manager.id

    parsed.settingsDefaults = type(parsed.settingsDefaults) == "table" and parsed.settingsDefaults or defaults.settingsDefaults
    parsed.filterPresets = type(parsed.filterPresets) == "table" and parsed.filterPresets or defaults.filterPresets
    parsed.workers = type(parsed.workers) == "table" and parsed.workers or {}
    parsed.queue = type(parsed.queue) == "table" and parsed.queue or {}
    parsed.active = type(parsed.active) == "table" and parsed.active or {}
    parsed.completed = type(parsed.completed) == "table" and parsed.completed or {}
    parsed.minedHistory = type(parsed.minedHistory) == "table" and parsed.minedHistory or {}
    parsed.nextTaskId = tonumber(parsed.nextTaskId) or 1
    parsed.dispatchPaused = parsed.dispatchPaused == true
    parsed.updatedAt = tonumber(parsed.updatedAt) or nowSeconds()

    return parsed
end

local function saveState()
    state.updatedAt = nowSeconds()

    if not fs or not fs.open then
        return false, "filesystem unavailable"
    end

    local file = fs.open(STATE_FILE, "w")
    if not file then
        return false, "unable to open state file"
    end

    local serialized = nil
    if textutils and textutils.serializeJSON then
        serialized = textutils.serializeJSON(state)
    end
    if not serialized and textutils and textutils.serialize then
        serialized = textutils.serialize(state)
    end
    if not serialized then
        file.close()
        return false, "serializer unavailable"
    end

    file.write(serialized)
    file.close()
    return true
end

local display = {
    device = nil,
    width = 0,
    height = 0,
    usingMonitor = false
}

local function attachDisplay()
    local monitor = nil
    local ok, wrapped = pcall(function()
        return plib.wrap("monitor", "monitor")
    end)

    if ok and wrapped then
        monitor = wrapped
    end

    if monitor and type(monitor.getSize) == "function" then
        if type(monitor.setTextScale) == "function" then
            monitor.setTextScale(0.5)
        end

        local w, h = monitor.getSize()
        display.device = monitor
        display.width = w
        display.height = h
        display.usingMonitor = true
        return true
    end

    if term and type(term.getSize) == "function" then
        local w, h = term.getSize()
        display.device = term
        display.width = w
        display.height = h
    else
        display.device = nil
        display.width = 0
        display.height = 0
    end

    display.usingMonitor = false
    return false
end

local function writeLine(device, x, y, message)
    local text = tostring(message or "")
    device.setCursorPos(x, y)
    device.clearLine()
    device.write(text)
end

local function drawUI(statusLine)
    local device = display.device
    if not device then
        return
    end

    device.setCursorPos(1, 1)
    device.clear()

    local width = display.width
    local row = 1

    writeLine(device, 1, row, "Digital Mining Manager" .. (display.usingMonitor and " [MONITOR]" or " [TERMINAL]"))
    row = row + 1
    writeLine(device, 1, row,
        string.format("Host: %s  Protocol: %s  ID: %s", state.manager.label, state.manager.protocol, tostring(state.manager.id)))
    row = row + 1
    writeLine(device, 1, row, string.format("Workers: %d  Queue: %d  Active: %d  Completed: %d",
        (function()
            local c = 0
            for _ in pairs(state.workers) do
                c = c + 1
            end
            return c
        end)(),
        #state.queue,
        (function()
            local c = 0
            for _ in pairs(state.active) do
                c = c + 1
            end
            return c
        end)(),
        #state.completed
    ))
    row = row + 1
    writeLine(device, 1, row, string.format("Dispatch paused: %s", tostring(state.dispatchPaused)))
    row = row + 1
    writeLine(device, 1, row, "Commands: queue <x> <z> [preset] [radius] [minY] [maxY] [silkTouch] | pause | resume | presets | workers")
    row = row + 1
    writeLine(device, 1, row, "Status: " .. tostring(statusLine or "idle"))
    row = row + 2
    writeLine(device, 1, row, "Recent workers:")
    row = row + 1

    local rows = {}
    for workerID, worker in pairs(state.workers) do
        rows[#rows + 1] = string.format("- id=%s label=%s status=%s last=%s task=%s",
            tostring(workerID),
            tostring(worker.label or "?"),
            tostring(worker.status or "unknown"),
            tostring(worker.lastSeen or 0),
            tostring(worker.activeTaskId or "none")
        )
    end
    table.sort(rows)
    if #rows == 0 then
        writeLine(device, 1, row, "- none")
    else
        local availableRows = math.max(0, display.height - row + 1)
        for i = 1, math.min(#rows, availableRows) do
            writeLine(device, 1, row + i - 1, rows[i]:sub(1, width))
        end
    end
end

local function taskOverlaps(existing, candidate)
    if type(existing) ~= "table" or type(candidate) ~= "table" then
        return false
    end

    local samePreset = tostring(existing.presetName or "") == tostring(candidate.presetName or "")
    if not samePreset then
        return false
    end

    local ax1 = tonumber(existing.minX)
    local ax2 = tonumber(existing.maxX)
    local az1 = tonumber(existing.minZ)
    local az2 = tonumber(existing.maxZ)
    local bx1 = tonumber(candidate.minX)
    local bx2 = tonumber(candidate.maxX)
    local bz1 = tonumber(candidate.minZ)
    local bz2 = tonumber(candidate.maxZ)

    if not (ax1 and ax2 and az1 and az2 and bx1 and bx2 and bz1 and bz2) then
        return false
    end

    local overlapX = not (bx2 < ax1 or bx1 > ax2)
    local overlapZ = not (bz2 < az1 or bz1 > az2)
    return overlapX and overlapZ
end

local function computeFootprint(location, radius)
    local r = tonumber(radius) or 32
    return {
        minX = location.turtleTargetX - r,
        maxX = location.turtleTargetX + r,
        minZ = location.turtleTargetZ - r,
        maxZ = location.turtleTargetZ + r
    }
end

local function enqueueTask(x, z, presetName, settings)
    local preset = tostring(presetName or "ores")
    local filters = state.filterPresets[preset]
    if type(filters) ~= "table" then
        return false, "unknown preset: " .. preset
    end

    local mergedSettings = shallowCopy(state.settingsDefaults)
    for k, v in pairs(settings or {}) do
        mergedSettings[k] = v
    end

    local location = normalizeTaskLocation(x, z)
    local footprint = computeFootprint(location, mergedSettings.radius)

    local candidateHistory = {
        minX = footprint.minX,
        maxX = footprint.maxX,
        minZ = footprint.minZ,
        maxZ = footprint.maxZ,
        presetName = preset
    }

    for i = 1, #state.minedHistory do
        if taskOverlaps(state.minedHistory[i], candidateHistory) then
            return false,
                string.format("overlaps mined area for preset %s (chunk origin %d,%d)", preset, location.chunkOriginX,
                    location.chunkOriginZ)
        end
    end

    local taskId = "task_" .. tostring(state.nextTaskId)
    state.nextTaskId = state.nextTaskId + 1

    state.queue[#state.queue + 1] = {
        taskId = taskId,
        location = location,
        presetName = preset,
        filters = filters,
        settings = mergedSettings,
        footprint = footprint,
        createdAt = nowSeconds(),
        status = "queued"
    }

    saveState()
    return true, taskId
end

local function assignNextTaskToWorker(workerID)
    if state.dispatchPaused then
        return false, "dispatch paused"
    end

    local worker = state.workers[tostring(workerID)]
    if not worker then
        return false, "worker unknown"
    end

    if worker.activeTaskId then
        return false, "worker already has active task"
    end

    if #state.queue == 0 then
        return false, "queue empty"
    end

    local taskEntry = table.remove(state.queue, 1)
    taskEntry.status = "offered"
    taskEntry.assignedTo = tonumber(workerID)
    taskEntry.assignedAt = nowSeconds()

    state.active[tostring(taskEntry.taskId)] = taskEntry
    worker.activeTaskId = taskEntry.taskId
    worker.status = "busy"

    local okSend, errSend = nlib.send(tonumber(workerID), {
        messageType = "task_offer",
        managerLabel = state.manager.label,
        managerProtocol = state.manager.protocol,
        sentAt = nowSeconds(),
        body = {
            taskId = taskEntry.taskId,
            location = {
                x = taskEntry.location.requestedX,
                z = taskEntry.location.requestedZ
            },
            presetName = taskEntry.presetName,
            filters = taskEntry.filters,
            settings = taskEntry.settings
        }
    }, state.manager.protocol)

    saveState()

    if not okSend then
        return false, "failed to send task: " .. tostring(errSend)
    end

    return true, taskEntry.taskId
end

local function markTaskComplete(workerID, payload)
    local body = type(payload.body) == "table" and payload.body or {}
    local taskId = tostring(body.taskId or "")
    if taskId == "" then
        return false, "missing taskId"
    end

    local taskEntry = state.active[taskId]
    if not taskEntry then
        return false, "task not active"
    end

    state.active[taskId] = nil
    local worker = state.workers[tostring(workerID)]
    if worker then
        worker.activeTaskId = nil
        worker.status = "idle"
    end

    taskEntry.status = "completed"
    taskEntry.completedAt = nowSeconds()
    state.completed[#state.completed + 1] = taskEntry

    state.minedHistory[#state.minedHistory + 1] = {
        taskId = taskEntry.taskId,
        presetName = taskEntry.presetName,
        requestedX = taskEntry.location.requestedX,
        requestedZ = taskEntry.location.requestedZ,
        chunkOriginX = taskEntry.location.chunkOriginX,
        chunkOriginZ = taskEntry.location.chunkOriginZ,
        turtleTargetX = taskEntry.location.turtleTargetX,
        turtleTargetZ = taskEntry.location.turtleTargetZ,
        radius = taskEntry.settings.radius,
        minX = taskEntry.footprint.minX,
        maxX = taskEntry.footprint.maxX,
        minZ = taskEntry.footprint.minZ,
        maxZ = taskEntry.footprint.maxZ,
        completedAt = taskEntry.completedAt
    }

    saveState()
    return true
end

local function updateWorker(senderID, payload)
    local key = tostring(senderID)
    local worker = state.workers[key] or {}
    local body = type(payload.body) == "table" and payload.body or {}

    worker.id = senderID
    worker.label = tostring(payload.workerLabel or worker.label or ("worker_" .. key))
    worker.lastSeen = nowSeconds()
    worker.status = worker.status or "online"
    worker.phase = body.phase or worker.phase

    if payload.messageType == "task_request" then
        worker.status = "idle"
    elseif payload.messageType == "task_start" then
        worker.status = "busy"
    elseif payload.messageType == "task_complete" then
        worker.status = "idle"
    end

    state.workers[key] = worker
end

local function handleDiscovery(senderID, payload)
    if type(payload) ~= "table" then
        return
    end
    if payload.messageType ~= "discover_manager" then
        return
    end

    nlib.send(senderID, {
        messageType = "manager_announce",
        managerLabel = state.manager.label,
        managerProtocol = state.manager.protocol,
        managerId = state.manager.id,
        sentAt = nowSeconds()
    }, DISCOVERY_PROTOCOL)
end

local function handleManagerProtocol(senderID, payload)
    if type(payload) ~= "table" or type(payload.messageType) ~= "string" then
        return "ignored invalid payload"
    end

    updateWorker(senderID, payload)

    if payload.messageType == "task_request" then
        local okAssign, assignRet = assignNextTaskToWorker(senderID)
        saveState()
        if okAssign then
            return "assigned " .. tostring(assignRet) .. " to worker " .. tostring(senderID)
        end
        return "task_request from " .. tostring(senderID) .. ": " .. tostring(assignRet)
    end

    if payload.messageType == "task_complete" then
        local okComplete, completeErr = markTaskComplete(senderID, payload)
        saveState()
        if okComplete then
            return "completed task from worker " .. tostring(senderID)
        end
        return "task_complete error for " .. tostring(senderID) .. ": " .. tostring(completeErr)
    end

    if payload.messageType == "task_accept" then
        return "task accepted by worker " .. tostring(senderID)
    end

    if payload.messageType == "task_start" then
        return "task started by worker " .. tostring(senderID)
    end

    if payload.messageType == "heartbeat" then
        return "heartbeat " .. tostring(senderID)
    end

    saveState()
    return "message " .. tostring(payload.messageType) .. " from " .. tostring(senderID)
end

local function parseBoolean(value)
    if value == nil then
        return nil
    end

    local v = tostring(value):lower()
    if v == "true" or v == "1" or v == "yes" or v == "y" then
        return true
    end
    if v == "false" or v == "0" or v == "no" or v == "n" then
        return false
    end
    return nil
end

local function handleCommand(line)
    local parts = {}
    for token in tostring(line):gmatch("%S+") do
        parts[#parts + 1] = token
    end
    if #parts == 0 then
        return ""
    end

    local cmd = parts[1]

    if cmd == "pause" then
        state.dispatchPaused = true
        saveState()
        return "dispatch paused"
    end

    if cmd == "resume" then
        state.dispatchPaused = false
        saveState()
        return "dispatch resumed"
    end

    if cmd == "presets" then
        local names = {}
        for name in pairs(state.filterPresets) do
            names[#names + 1] = name
        end
        table.sort(names)
        return "presets: " .. table.concat(names, ", ")
    end

    if cmd == "workers" then
        local ids = {}
        for id in pairs(state.workers) do
            ids[#ids + 1] = id
        end
        table.sort(ids)
        return "workers: " .. (#ids == 0 and "none" or table.concat(ids, ", "))
    end

    if cmd == "queue" then
        local x = tonumber(parts[2])
        local z = tonumber(parts[3])
        if not x or not z then
            return "usage: queue <x> <z> [preset] [radius] [minY] [maxY] [silkTouch]"
        end

        local presetName = parts[4] or "ores"
        local settings = {}
        if tonumber(parts[5]) then
            settings.radius = tonumber(parts[5])
        end
        if tonumber(parts[6]) then
            settings.minY = tonumber(parts[6])
        end
        if tonumber(parts[7]) then
            settings.maxY = tonumber(parts[7])
        end
        local parsedSilk = parseBoolean(parts[8])
        if parsedSilk ~= nil then
            settings.silkTouch = parsedSilk
        end

        local okTask, retTask = enqueueTask(x, z, presetName, settings)
        if not okTask then
            return "queue failed: " .. tostring(retTask)
        end

        return "queued " .. tostring(retTask)
    end

    return "unknown command"
end

local function eventLoop()
    local statusLine = "starting"

    local okOpen, openErr = nlib.open()
    if not okOpen then
        error("Failed to open rednet modem: " .. tostring(openErr))
    end

    local okHost, hostErr = nlib.host(state.manager.protocol, state.manager.label)
    if not okHost then
        error("Failed to host manager protocol: " .. tostring(hostErr))
    end

    local okDiscoveryHost, discoveryErr = nlib.host(DISCOVERY_PROTOCOL, state.manager.label)
    if not okDiscoveryHost then
        error("Failed to host discovery protocol: " .. tostring(discoveryErr))
    end

    drawUI("online")

    local tickTimer = nil
    if type(startTimerFn) == "function" then
        tickTimer = startTimerFn(1)
    end
    while true do
        local eventData = nil
        if type(pullEventFn) == "function" then
            eventData = { pullEventFn() }
        else
            sleep(1)
            drawUI(statusLine)
            eventData = { "timer", nil }
        end
        local eventName = eventData[1]

        if eventName == "rednet_message" then
            local senderID = eventData[2]
            local payload = eventData[3]
            local protocol = eventData[4]

            if protocol == DISCOVERY_PROTOCOL then
                handleDiscovery(senderID, payload)
                statusLine = "discovery from " .. tostring(senderID)
            elseif protocol == state.manager.protocol then
                statusLine = handleManagerProtocol(senderID, payload)
            end

            drawUI(statusLine)
        elseif eventName == "timer" and (tickTimer == nil or eventData[2] == tickTimer) then
            drawUI(statusLine)
            if type(startTimerFn) == "function" then
                tickTimer = startTimerFn(1)
            end
        elseif eventName == "char" then
            -- ignored, line input handled by read() thread
        end
    end
end

local function commandLoop()
    while true do
        ccWrite("> ")
        local line = ccRead()
        if line then
            local result = handleCommand(line)
            if result and result ~= "" then
                print(result)
            end
        end
        sleep(0)
    end
end

local function main()
    state = loadState()
    saveState()
    attachDisplay()
    if display.usingMonitor then
        print("Monitor attached for digital mining manager UI.")
    else
        print("Monitor not attached. Using terminal UI.")
    end

    if parallel and parallel.waitForAny then
        parallel.waitForAny(eventLoop, commandLoop)
        return
    end

    -- Fallback for environments without parallel API: still serve network events.
    eventLoop()
end

local ok, err = pcall(main)
if not ok then
    printError("digital_mining_manager crashed: " .. tostring(err))
    error(err, 0)
end
