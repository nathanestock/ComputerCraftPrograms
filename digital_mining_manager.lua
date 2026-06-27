local nlib = require("nlib")
local plib = require("plib")

local fs = rawget(_G, "fs")
local textutils = rawget(_G, "textutils")
local rednet = rawget(_G, "rednet")
local sleep = rawget(_G, "sleep") or function(_) end
local term = rawget(_G, "term")
local colors = rawget(_G, "colors")
local printError = rawget(_G, "printError") or function(msg) print(tostring(msg)) end
local epochFn = os and rawget(os, "epoch")

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
local assignNextTaskToWorker

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

local function deepCopy(value, seen)
    if type(value) ~= "table" then
        return value
    end

    seen = seen or {}
    if seen[value] then
        return seen[value]
    end

    local out = {}
    seen[value] = out
    for k, v in pairs(value) do
        out[deepCopy(k, seen)] = deepCopy(v, seen)
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

local function workerCount()
    local c = 0
    for _ in pairs(state.workers) do
        c = c + 1
    end
    return c
end

local function activeCount()
    local c = 0
    for _ in pairs(state.active) do
        c = c + 1
    end
    return c
end

local function formatAgo(lastSeen)
    local ts = tonumber(lastSeen)
    if not ts then
        return "never"
    end

    local delta = nowSeconds() - ts
    if delta < 0 then
        delta = 0
    end

    if delta < 60 then
        return tostring(delta) .. "s ago"
    end
    if delta < 3600 then
        return tostring(math.floor(delta / 60)) .. "m ago"
    end
    return tostring(math.floor(delta / 3600)) .. "h ago"
end

local function formatWorkerPosition(worker)
    local pos = type(worker.position) == "table" and worker.position or nil
    if not pos then
        return "?, ?, ?"
    end

    local x = tonumber(pos.x)
    local y = tonumber(pos.y)
    local z = tonumber(pos.z)
    if not (x and y and z) then
        return "?, ?, ?"
    end

    return string.format("%d,%d,%d", x, y, z)
end

local function formatWorkerFacing(worker)
    local facing = tonumber(worker.facing)
    if not facing then
        return "?"
    end

    local normalized = ((math.floor(facing) % 4) + 4) % 4
    if normalized == 0 then
        return "N"
    end
    if normalized == 1 then
        return "E"
    end
    if normalized == 2 then
        return "S"
    end
    return "W"
end

local function dispatchOneTask()
    if state.dispatchPaused then
        return false, "dispatch paused"
    end
    if #state.queue == 0 then
        return false, "queue empty"
    end

    local workerKeys = {}
    for id in pairs(state.workers) do
        workerKeys[#workerKeys + 1] = id
    end
    table.sort(workerKeys)

    for i = 1, #workerKeys do
        local id = workerKeys[i]
        local worker = state.workers[id]
        if worker and not worker.activeTaskId then
            return assignNextTaskToWorker(tonumber(id))
        end
    end
    return false, "no idle worker"
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
        filters = deepCopy(filters),
        settings = mergedSettings,
        footprint = footprint,
        createdAt = nowSeconds(),
        status = "queued"
    }

    saveState()
    return true, taskId
end

assignNextTaskToWorker = function(workerID)
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

    local position = type(body.position) == "table" and body.position or nil
    if position then
        worker.position = worker.position or {}
        worker.position.x = tonumber(position.x) or worker.position.x
        worker.position.y = tonumber(position.y) or worker.position.y
        worker.position.z = tonumber(position.z) or worker.position.z
    end
    if body.facing ~= nil then
        worker.facing = tonumber(body.facing) or worker.facing
    end

    if payload.messageType == "task_request" then
        worker.status = "idle"
    elseif payload.messageType == "task_start" then
        worker.status = "busy"
    elseif payload.messageType == "task_complete" then
        worker.status = "idle"
    elseif payload.messageType == "heartbeat" then
        worker.status = worker.activeTaskId and "busy" or "online"
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
        saveState()
        return "task accepted by worker " .. tostring(senderID)
    end

    if payload.messageType == "task_start" then
        saveState()
        return "task started by worker " .. tostring(senderID)
    end

    if payload.messageType == "heartbeat" then
        saveState()
        return "heartbeat " .. tostring(senderID)
    end

    saveState()
    return "message " .. tostring(payload.messageType) .. " from " .. tostring(senderID)
end

local function createUI()
    local okBasalt, basaltModule = pcall(require, "basalt")
    if not okBasalt or not basaltModule then
        error("Basalt is required for digital_mining_manager UI.")
    end

    local basalt = basaltModule
    local main = basalt.getMainFrame()

    local okMonitor, monitor = pcall(function()
        return plib.wrap("monitor", "monitor")
    end)
    if okMonitor and monitor and type(main.setTerm) == "function" then
        if type(monitor.setTextScale) == "function" then
            monitor.setTextScale(0.5)
        end
        main:setTerm(monitor)
    elseif term and type(main.setTerm) == "function" then
        main:setTerm(term)
    end

    local ui = {
        basalt = basalt,
        statusLine = "starting",
        fields = {}
    }

    local screenW, screenH = 51, 19
    if monitor and type(monitor.getSize) == "function" then
        screenW, screenH = monitor.getSize()
    elseif term and type(term.getSize) == "function" then
        screenW, screenH = term.getSize()
    end

    local bodyTop = 4
    local bodyHeight = math.max(4, screenH - 3)
    local leftWidth = math.max(20, math.floor(screenW / 2))
    local rightX = leftWidth + 1
    local rightWidth = math.max(20, screenW - leftWidth)

    ui.header = main:addLabel()
        :setPosition(1, 1)
        :setForeground(colors and colors.white or 1)

    ui.identity = main:addLabel()
        :setPosition(1, 2)
        :setForeground(colors and colors.lightGray or 1)

    ui.status = main:addLabel()
        :setPosition(1, 3)
        :setForeground(colors and colors.yellow or 1)

    ui.left = main:addFrame()
        :setPosition(1, bodyTop)
        :setSize(leftWidth, bodyHeight)
        :setBackground(colors and colors.gray or 1)

    ui.right = main:addFrame()
        :setPosition(rightX, bodyTop)
        :setSize(rightWidth, bodyHeight)
        :setBackground(colors and colors.black or 1)

    ui.left:addLabel()
        :setPosition(2, 1)
        :setText("Configuration")
        :setForeground(colors and colors.white or 1)

    local row = 3
    local function addInput(name, label, value)
        ui.left:addLabel()
            :setPosition(2, row)
            :setText(label)
            :setForeground(colors and colors.white or 1)

        ui.fields[name] = ui.left:addInput()
            :setPosition(18, row)
            :setSize(16, 1)
            :setText(tostring(value or ""))

        row = row + 2
    end

    addInput("x", "Task X", "0")
    addInput("z", "Task Z", "0")
    addInput("preset", "Preset", "ores")
    addInput("radius", "Radius", tostring(state.settingsDefaults.radius or 32))
    addInput("minY", "Min Y", tostring(state.settingsDefaults.minY or -64))
    addInput("maxY", "Max Y", tostring(state.settingsDefaults.maxY or 319))
    addInput("silkTouch", "SilkTouch", tostring(state.settingsDefaults.silkTouch ~= false))

    ui.queueBtn = ui.left:addButton()
        :setPosition(2, row + 1)
        :setSize(12, 1)
        :setText("Queue Task")

    ui.pauseBtn = ui.left:addButton()
        :setPosition(16, row + 1)
        :setSize(14, 1)

    ui.dispatchBtn = ui.left:addButton()
        :setPosition(2, row + 3)
        :setSize(12, 1)
        :setText("Dispatch")

    ui.refreshBtn = ui.left:addButton()
        :setPosition(16, row + 3)
        :setSize(14, 1)
        :setText("Refresh")

    ui.workersTitle = ui.right:addLabel()
        :setPosition(2, 1)
        :setForeground(colors and colors.white or 1)

    ui.workerList = ui.right:addList()
        :setPosition(2, 3)
        :setSize(math.max(10, rightWidth - 2), math.max(4, bodyHeight - 3))

    local function fieldValue(name)
        return ui.fields[name] and ui.fields[name]:getText() or ""
    end

    local function parseBoolean(value)
        local v = tostring(value or ""):lower()
        if v == "true" or v == "1" or v == "yes" or v == "y" then
            return true
        end
        if v == "false" or v == "0" or v == "no" or v == "n" then
            return false
        end
        return nil
    end

    ui.render = function()
        local identity = state.manager.label
        if identity == nil or identity == "" then
            identity = tostring(state.manager.id)
        end

        ui.header:setText("Digital Mining Manager")
        ui.identity:setText(string.format("Manager: %s | protocol: %s", tostring(identity), tostring(state.manager.protocol)))
        ui.status:setText(string.format("Status: %s | queue:%d active:%d completed:%d", tostring(ui.statusLine), #state.queue,
            activeCount(), #state.completed))

        if state.dispatchPaused then
            ui.pauseBtn:setText("Resume")
            ui.pauseBtn:setBackground(colors and colors.green or 1)
        else
            ui.pauseBtn:setText("Pause")
            ui.pauseBtn:setBackground(colors and colors.red or 1)
        end

        ui.workersTitle:setText(string.format("Workers (%d)", workerCount()))

        ui.workerList:clear()
        local rows = {}
        for workerID, worker in pairs(state.workers) do
            rows[#rows + 1] = {
                id = tostring(workerID),
                label = tostring(worker.label or ("worker_" .. tostring(workerID))),
                status = tostring(worker.status or "unknown"),
                position = formatWorkerPosition(worker),
                facing = formatWorkerFacing(worker),
                age = formatAgo(worker.lastSeen)
            }
        end

        table.sort(rows, function(a, b)
            return a.id < b.id
        end)

        if #rows == 0 then
            ui.workerList:addItem("no workers connected")
            return
        end

        for i = 1, #rows do
            local rowData = rows[i]
            local line = string.format("%s/%s | %s | %s %s | %s", rowData.label, rowData.id, rowData.status,
                rowData.position, rowData.facing, rowData.age)
            ui.workerList:addItem(line)
        end
    end

    ui.queueBtn:onClick(function()
        local x = tonumber(fieldValue("x"))
        local z = tonumber(fieldValue("z"))
        if not x or not z then
            ui.statusLine = "queue failed: x and z must be numbers"
            ui.render()
            return
        end

        local preset = fieldValue("preset")
        if preset == "" then
            preset = "ores"
        end

        local settings = {}
        local radius = tonumber(fieldValue("radius"))
        local minY = tonumber(fieldValue("minY"))
        local maxY = tonumber(fieldValue("maxY"))
        local silk = parseBoolean(fieldValue("silkTouch"))

        if radius then
            settings.radius = radius
        end
        if minY then
            settings.minY = minY
        end
        if maxY then
            settings.maxY = maxY
        end
        if silk ~= nil then
            settings.silkTouch = silk
        end

        local okTask, taskRet = enqueueTask(x, z, preset, settings)
        if okTask then
            ui.statusLine = "queued " .. tostring(taskRet)
        else
            ui.statusLine = "queue failed: " .. tostring(taskRet)
        end
        ui.render()
    end)

    ui.pauseBtn:onClick(function()
        state.dispatchPaused = not state.dispatchPaused
        saveState()
        ui.statusLine = state.dispatchPaused and "dispatch paused" or "dispatch resumed"
        ui.render()
    end)

    ui.dispatchBtn:onClick(function()
        local okDispatch, dispatchRet = dispatchOneTask()
        if okDispatch then
            saveState()
            ui.statusLine = "assigned " .. tostring(dispatchRet)
        else
            ui.statusLine = tostring(dispatchRet)
        end
        ui.render()
    end)

    ui.refreshBtn:onClick(function()
        ui.statusLine = "refreshed"
        ui.render()
    end)

    ui.render()
    return ui
end

local function runManagerNetwork(ui)
    local okOpen, openErr = nlib.open()
    if not okOpen then
        error("Failed to open rednet modem: " .. tostring(openErr))
    end

    local mailboxOk, mailboxResult = nlib.discoverMailboxServer()
    if mailboxOk then
        print("Mailbox server discovered: ID " .. tostring(mailboxResult))
    else
        print("Mailbox server not found: " .. tostring(mailboxResult))
    end

    local okHost, hostErr = nlib.host(state.manager.protocol, state.manager.label)
    if not okHost then
        error("Failed to host manager protocol: " .. tostring(hostErr))
    end

    local okDiscoveryHost, discoveryErr = nlib.host(DISCOVERY_PROTOCOL, state.manager.label)
    if not okDiscoveryHost then
        error("Failed to host discovery protocol: " .. tostring(discoveryErr))
    end

    ui.statusLine = "online"
    ui.render()

    while true do
        local senderID, payload, protocol = rednet.receive(nil, 1)
        if senderID and protocol then
            if protocol == DISCOVERY_PROTOCOL then
                handleDiscovery(senderID, payload)
                ui.statusLine = "discovery from " .. tostring(senderID)
            elseif protocol == state.manager.protocol then
                ui.statusLine = handleManagerProtocol(senderID, payload)
            end
            ui.render()
        else
            ui.render()
        end
        sleep(0)
    end
end

local function main()
    state = loadState()
    saveState()

    local ui = createUI()
    ui.basalt.schedule(function()
        local ok, err = pcall(runManagerNetwork, ui)
        if not ok then
            ui.statusLine = "network loop crashed"
            ui.render()
            printError("network loop crashed: " .. tostring(err))
        end
    end)

    ui.basalt.run()
end

local ok, err = pcall(main)
if not ok then
    printError("digital_mining_manager crashed: " .. tostring(err))
    error(err, 0)
end
