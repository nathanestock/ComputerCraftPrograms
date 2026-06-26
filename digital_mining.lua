local tlib                     = require("tlib")
local plib                     = require("plib")
local nlib                     = require("nlib")

local fs                       = rawget(_G, "fs")
local textutils                = rawget(_G, "textutils")
local rednet                   = rawget(_G, "rednet")
local ccWrite                  = rawget(_G, "write") or function(msg) print(tostring(msg or "")) end
local ccRead                   = rawget(_G, "read") or function() return nil end
local epochFn                  = os and rawget(os, "epoch")

local getComputerIDFn          = (os and rawget(os, "getComputerID")) or rawget(_G, "getComputerID")
local getComputerLabelFn       = (os and rawget(os, "getComputerLabel")) or rawget(_G, "getComputerLabel")

-- =============================================================================
-- Cached Globals
-- =============================================================================
local ccTurtle                 = rawget(_G, "turtle")
local ccSleep                  = rawget(_G, "sleep") or function(_) end
local PERIPHERAL_CONNECT_DELAY = 1
local ENTANGLOPORTER_FREQ      = "digital_miners"
local ENTANGLOPORTER_REFUEL_FREQ = "lava_buckets"
local DISCOVERY_PROTOCOL       = "digital_mining_discovery"
local WORKER_CONFIG_FILE       = "digital_mining_worker_config.json"

-- =============================================================================
-- State Setup
-- =============================================================================
tlib.load()
local task = tlib.getTaskState() or {}

task.digitalMining = task.digitalMining or {
    version         = 2,
    phase           = "boot",
    transporterStep = 0,     -- 0–5: how many transporter placements completed
    teardownStep    = 0,     -- step tracker for transporter teardown sequence
    monitorChecks   = 0,
    homePos         = nil,   -- {x, y, z, facing} at boot
    rebootToken     = nil,
    rebootRequested = false,
    rebootVerified  = false,
    completed       = false,
    serviceMode     = true,
    activeTask      = nil,
    currentSettings = nil,
    currentFilters  = nil,
    managerLabel    = nil,
    managerProtocol = nil,
    updatedAt       = os.time()
}

local p = task.digitalMining

if tonumber(p.version or 1) < 2 then
    p.version = 2
    p.phase = "boot"
    p.serviceMode = true
    p.activeTask = nil
    p.currentSettings = nil
    p.currentFilters = nil
end

-- =============================================================================
-- Phase Helpers
-- =============================================================================
local function saveTask()
    p.updatedAt = os.time()
    tlib.setTaskState(task)
end

local function setPhase(nextPhase)
    p.phase = nextPhase
    saveTask()
end

-- Helper: run a movement function and error on failure
local function mv(fn, label)
    local ok, err = fn()
    if not ok then
        error(label .. " failed: " .. tostring(err))
    end
end

-- =============================================================================
-- Inventory Counter
-- =============================================================================
local function countItem(pattern)
    if not ccTurtle then return 0 end
    local total = 0
    for slot = 1, 16 do
        local detail = ccTurtle.getItemDetail(slot)
        if detail and detail.name and detail.name:find(pattern, 1, true) then
            total = total + detail.count
        end
    end
    return total
end

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
        return tostring(getComputerLabelFn() or ("worker_" .. tostring(computerID())))
    end
    return "worker_" .. tostring(computerID())
end

local function readWorkerConfig()
    if not fs or not fs.exists or not fs.exists(WORKER_CONFIG_FILE) then
        return {}
    end

    local file = fs.open(WORKER_CONFIG_FILE, "r")
    if not file then
        return {}
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
        return {}
    end

    return parsed
end

local function writeWorkerConfig(config)
    if not fs or not fs.open then
        return false, "filesystem unavailable"
    end

    local file = fs.open(WORKER_CONFIG_FILE, "w")
    if not file then
        return false, "unable to open config for writing"
    end

    local serialized = nil
    if textutils and textutils.serializeJSON then
        serialized = textutils.serializeJSON(config)
    end
    if not serialized and textutils and textutils.serialize then
        serialized = textutils.serialize(config)
    end
    if not serialized then
        file.close()
        return false, "serializer unavailable"
    end

    file.write(serialized)
    file.close()
    return true
end

local function normalizeFilterList(filters)
    if type(filters) ~= "table" then
        return {
            {
                ["type"] = "MINER_TAG_FILTER",
                ["tag"] = "*:ores"
            }
        }
    end

    if #filters > 0 then
        return filters
    end

    -- Accept a single filter map and normalize it to an array.
    if filters.type then
        return { filters }
    end

    return {
        {
            ["type"] = "MINER_TAG_FILTER",
            ["tag"] = "*:ores"
        }
    }
end

local function normalizeSettings(settings)
    settings = type(settings) == "table" and settings or {}
    return {
        autoEject = settings.autoEject ~= false,
        silkTouch = settings.silkTouch ~= false,
        maxY = tonumber(settings.maxY) or 319,
        minY = tonumber(settings.minY) or -64,
        radius = tonumber(settings.radius) or 32
    }
end

-- =============================================================================
-- Peripheral Setup Stubs
-- =============================================================================

local function setupEntangloporter(periph)
    if not periph.setMode then
        error("setupEntangloporter: Peripheral missing setMode()")
    end
    if not periph.setEjecting then
        error("setupEntangloporter: Peripheral missing setEjecting()")
    end

    periph.setMode("ENERGY", "LEFT", "OUTPUT")
    periph.setMode("ITEM", "TOP", "INPUT")
    periph.setEjecting("ENERGY", true)

    periph.setFrequency(ENTANGLOPORTER_FREQ)

    print("Entangloporter configured: ENERGY/FRONT=OUTPUT, ITEM/TOP=INPUT, ENERGY ejecting enabled")
end

local function setupMiner(periph, settings, filters)
    if not periph then
        error("setupMiner: Missing digital miner peripheral")
    end

    if not periph.setAutoEject then
        error("setupMiner: Peripheral missing setAutoEject()")
    end
    if not periph.setSilkTouch then
        error("setupMiner: Peripheral missing setSilkTouch()")
    end
    if not periph.setMaxY then
        error("setupMiner: Peripheral missing setMaxY()")
    end
    if not periph.setMinY then
        error("setupMiner: Peripheral missing setMinY()")
    end
    if not periph.setRadius then
        error("setupMiner: Peripheral missing setRadius()")
    end
    if not periph.addFilter then
        error("setupMiner: Peripheral missing addFilter()")
    end

    local cfg = normalizeSettings(settings)
    local filterList = normalizeFilterList(filters)

    periph.setAutoEject(cfg.autoEject)
    periph.setSilkTouch(cfg.silkTouch)
    periph.setMaxY(cfg.maxY)
    periph.setMinY(cfg.minY)
    periph.setRadius(cfg.radius)

    periph.reset()

    local existingFilters = periph.getFilters and periph.getFilters()
    if existingFilters and #existingFilters > 0 then
        print("setupMiner: Existing filters detected, clearing...")
        for _, filter in ipairs(existingFilters) do
            local success, err = periph.removeFilter(filter)
            if not success then
                error("setupMiner: Failed to remove existing filter: " .. tostring(err))
            end
        end
    end

    for index, filter in ipairs(filterList) do
        local success, err = periph.addFilter(filter)
        if not success then
            error("setupMiner: Failed to add filter #" .. tostring(index) .. ": " .. tostring(err))
        end
    end

    print(string.format(
        "Digital miner configured: autoEject=%s, silkTouch=%s, y=[%d,%d], radius=%d, filters=%d",
        tostring(cfg.autoEject), tostring(cfg.silkTouch), cfg.minY, cfg.maxY, cfg.radius, #filterList
    ))
end

local function chunkOriginFromCoordinate(value)
    local n = math.floor(tonumber(value) or 0)
    local remainder = ((n % 16) + 16) % 16
    return n - remainder
end

local function normalizeTaskLocation(taskPayload)
    local requestedX = tonumber(taskPayload and taskPayload.x) or 0
    local requestedZ = tonumber(taskPayload and taskPayload.z) or 0
    local originX = chunkOriginFromCoordinate(requestedX)
    local originZ = chunkOriginFromCoordinate(requestedZ)

    return {
        requestedX = requestedX,
        requestedZ = requestedZ,
        chunkOriginX = originX,
        chunkOriginZ = originZ,
        turtleTargetX = originX + 3,
        turtleTargetZ = originZ + 3
    }
end

local function rotateToFacing(targetFacing)
    local _, _, _, facing = tlib.getPosition()
    local current = facing % 4
    local target = (tonumber(targetFacing) or 0) % 4
    local delta = (target - current) % 4

    if delta == 0 then
        return
    end

    if delta == 1 then
        tlib.turnRight()
    elseif delta == 2 then
        tlib.turnRight()
        tlib.turnRight()
    elseif delta == 3 then
        tlib.turnLeft()
    end
end

local function moveAlongX(targetX)
    local x = tlib.getPosition()
    while x ~= targetX do
        if x < targetX then
            rotateToFacing(1)
        else
            rotateToFacing(3)
        end
        mv(tlib.forward, "travel_to_target: moveAlongX")
        x = tlib.getPosition()
    end
end

local function moveAlongZ(targetZ)
    local _, _, z = tlib.getPosition()
    while z ~= targetZ do
        if z < targetZ then
            rotateToFacing(2)
        else
            rotateToFacing(0)
        end
        mv(tlib.forward, "travel_to_target: moveAlongZ")
        _, _, z = tlib.getPosition()
    end
end

local function moveToTaskLocation(location)
    if not location then
        error("moveToTaskLocation: missing location")
    end

    print(string.format(
        "Travel target chunk origin (%d, %d), turtle target (%d, %d)",
        location.chunkOriginX,
        location.chunkOriginZ,
        location.turtleTargetX,
        location.turtleTargetZ
    ))

    moveAlongX(location.turtleTargetX)
    moveAlongZ(location.turtleTargetZ)
end

local function sendWorkerMessage(managerID, managerProtocol, messageType, body)
    if type(managerID) ~= "number" then
        return false, "invalid manager ID: expected number, got " .. type(managerID)
    end

    local payload = {
        messageType = messageType,
        protocolVersion = 1,
        workerId = computerID(),
        workerLabel = computerLabel(),
        sentAt = nowSeconds(),
        body = body or {}
    }

    local txOk, sendOk, sendErr = tlib.runRednetTransaction(function()
        return nlib.send(managerID, payload, managerProtocol)
    end)
    if not txOk then
        return false, sendOk
    end
    return sendOk, sendErr
end

local function resolveManagerSelection()
    local config = readWorkerConfig()
    local managerLabel = config.managerLabel
    local managerProtocol = config.managerProtocol

    if type(managerLabel) == "string" and managerLabel ~= "" and type(managerProtocol) == "string" and managerProtocol ~= "" then
        p.managerLabel = managerLabel
        p.managerProtocol = managerProtocol
        saveTask()
        return managerLabel, managerProtocol
    end

    print("No manager configured. Discovering digital mining managers...")
    local discoverTxOk, candidatesOrErr, discoverErr = tlib.runRednetTransaction(function()
        if not rednet then
            return nil, "rednet unavailable"
        end

        rednet.broadcast({
            messageType = "discover_manager",
            workerId = computerID(),
            workerLabel = computerLabel(),
            sentAt = nowSeconds()
        }, DISCOVERY_PROTOCOL)

        local discovered = {}
        local started = nowSeconds()
        while nowSeconds() - started < 3 do
            local senderID, payload = rednet.receive(DISCOVERY_PROTOCOL, 0.75)
            if senderID and type(payload) == "table" then
                if payload.messageType == "manager_announce" and type(payload.managerLabel) == "string" then
                    local protocol = tostring(payload.managerProtocol or ("digital_mining_" .. payload.managerLabel))
                    discovered[#discovered + 1] = {
                        managerLabel = payload.managerLabel,
                        managerProtocol = protocol,
                        managerID = senderID
                    }
                end
            end
        end

        return discovered
    end)
    if not discoverTxOk then
        error("resolveManagerSelection: discovery transaction failed: " .. tostring(candidatesOrErr))
    end

    local candidates = candidatesOrErr
    if type(candidates) ~= "table" then
        error("resolveManagerSelection: discovery failed: " .. tostring(discoverErr))
    end

    if #candidates == 0 then
        error("No digital mining manager discovered. Start digital_mining_manager and retry.")
    end

    print("Select manager host:")
    for i = 1, #candidates do
        local c = candidates[i]
        print(string.format("[%d] %s (id=%s protocol=%s)", i, c.managerLabel, tostring(c.managerID), c.managerProtocol))
    end

    ccWrite("Selection [1-" .. tostring(#candidates) .. "]> ")
    local choice = tonumber(ccRead())
    if not choice or choice < 1 or choice > #candidates then
        error("Invalid manager selection")
    end

    local selected = candidates[choice]
    config.managerLabel = selected.managerLabel
    config.managerProtocol = selected.managerProtocol

    local saved, saveErr = writeWorkerConfig(config)
    if not saved then
        error("Failed to save worker config: " .. tostring(saveErr))
    end

    p.managerLabel = selected.managerLabel
    p.managerProtocol = selected.managerProtocol
    saveTask()

    print(string.format("Manager configured: %s (%s)", selected.managerLabel, selected.managerProtocol))
    return selected.managerLabel, selected.managerProtocol
end

local function requestTaskFromManager()
    local managerLabel, managerProtocol = resolveManagerSelection()
    local lookupTxOk, lookupOk, managerID = tlib.runRednetTransaction(function()
        return nlib.lookup(managerProtocol, managerLabel)
    end)
    if not lookupTxOk then
        error("requestTaskFromManager: manager lookup transaction failed: " .. tostring(lookupOk))
    end
    if not lookupOk then
        error("requestTaskFromManager: manager lookup failed")
    end
    if not managerID then
        error("requestTaskFromManager: manager host unavailable for protocol " .. managerProtocol)
    end

    local okSend, sendErr = sendWorkerMessage(managerID, managerProtocol, "task_request", {
        position = {
            x = select(1, tlib.getPosition()),
            y = select(2, tlib.getPosition()),
            z = select(3, tlib.getPosition())
        },
        phase = p.phase
    })
    if not okSend then
        error("requestTaskFromManager: failed to send task request: " .. tostring(sendErr))
    end

    while true do
        local recvTxOk, recvOk, recvRet = tlib.runRednetTransaction(function()
            return nlib.receive(managerProtocol, 5)
        end)
        if not recvTxOk then
            error("requestTaskFromManager: receive transaction failed: " .. tostring(recvOk))
        end
        if not recvOk then
            error("requestTaskFromManager: receive failed: " .. tostring(recvRet))
        end

        local senderID = recvRet and recvRet.sender_id
        local payload = recvRet and recvRet.payload
        if senderID == managerID and type(payload) == "table" and payload.messageType == "task_offer" then
            if type(payload.body) ~= "table" then
                error("requestTaskFromManager: invalid task offer body")
            end

            local taskPayload = payload.body
            local location = normalizeTaskLocation(taskPayload.location or {})
            local settings = normalizeSettings(taskPayload.settings)
            local filters = normalizeFilterList(taskPayload.filters)

            p.activeTask = {
                id = taskPayload.taskId,
                requestedX = location.requestedX,
                requestedZ = location.requestedZ,
                chunkOriginX = location.chunkOriginX,
                chunkOriginZ = location.chunkOriginZ,
                turtleTargetX = location.turtleTargetX,
                turtleTargetZ = location.turtleTargetZ,
                presetName = taskPayload.presetName,
                assignedAt = nowSeconds()
            }
            p.currentSettings = settings
            p.currentFilters = filters
            p.phase = "travel_to_task"
            saveTask()

            sendWorkerMessage(managerID, managerProtocol, "task_accept", {
                taskId = taskPayload.taskId,
                turtleTargetX = location.turtleTargetX,
                turtleTargetZ = location.turtleTargetZ,
                chunkOriginX = location.chunkOriginX,
                chunkOriginZ = location.chunkOriginZ
            })

            return managerID, managerProtocol
        end
    end
end

local function reportTaskComplete(managerID, managerProtocol)
    if not p.activeTask then
        return
    end

    sendWorkerMessage(managerID, managerProtocol, "task_complete", {
        taskId = p.activeTask.id,
        finishedAt = nowSeconds(),
        location = {
            requestedX = p.activeTask.requestedX,
            requestedZ = p.activeTask.requestedZ,
            chunkOriginX = p.activeTask.chunkOriginX,
            chunkOriginZ = p.activeTask.chunkOriginZ,
            turtleTargetX = p.activeTask.turtleTargetX,
            turtleTargetZ = p.activeTask.turtleTargetZ
        },
        settings = p.currentSettings,
        filters = p.currentFilters,
        monitorChecks = p.monitorChecks
    })
end

local function resetTaskRuntimeState()
    p.transporterStep = 0
    p.teardownStep = 0
    p.monitorChecks = 0
    p.completed = false
end

-- =============================================================================
-- Main Run Function
-- =============================================================================
local function run()
    tlib.registerProgram("digital_mining")

    -- -------------------------------------------------------------------------
    -- boot: validate inventory, save home position
    -- -------------------------------------------------------------------------
    if p.phase == "boot" then
        print("Digital Mining: Initializing...")

        local strategyOk, strategyErr = tlib.useRefuelStrategy("entangloporter", {
            side = "up",
            entangloporterItem = "quantum_entangloporter",
            entangloporterFrequency = ENTANGLOPORTER_REFUEL_FREQ,
            fuelItemPattern = "lava_bucket",
            pullCount = 16,
            maxCycles = 8,
            retryDelay = 0.5,
            requireBufferItem = true,
            allowFallback = true
        })
        if not strategyOk then
            print("Refuel strategy selection failed: " .. tostring(strategyErr) .. ". Using default behavior.")
        end

        tlib.initialize()

        local x, y, z, facing = tlib.getPosition()
        p.homePos = { x = x, y = y, z = z, facing = facing }
        resetTaskRuntimeState()
        saveTask()

        print(string.format("Worker initialized at (%d, %d, %d) facing %d", x, y, z, facing))
        setPhase("await_task")
    end

    -- -------------------------------------------------------------------------
    -- await_task: request work from manager and persist assignment
    -- -------------------------------------------------------------------------
    if p.phase == "await_task" then
        print("Requesting mining task from manager...")

        local managerID, managerProtocol = requestTaskFromManager()
        sendWorkerMessage(managerID, managerProtocol, "task_start", {
            taskId = p.activeTask and p.activeTask.id,
            phase = "travel_to_task"
        })
    end

    -- -------------------------------------------------------------------------
    -- travel_to_task: move to chunk-aligned dispatch target (origin+3,+3)
    -- -------------------------------------------------------------------------
    if p.phase == "travel_to_task" then
        if not p.activeTask then
            error("travel_to_task: missing active task")
        end

        resetTaskRuntimeState()
        saveTask()

        moveToTaskLocation({
            chunkOriginX = p.activeTask.chunkOriginX,
            chunkOriginZ = p.activeTask.chunkOriginZ,
            turtleTargetX = p.activeTask.turtleTargetX,
            turtleTargetZ = p.activeTask.turtleTargetZ
        })

        local x, y, z, facing = tlib.getPosition()
        p.homePos = { x = x, y = y, z = z, facing = facing }
        saveTask()

        tlib.scanInventory()
        local minerCount          = countItem("digital_miner")
        local transporterCount    = countItem("ultimate_logistical_transporter")
        local entangloporterCount = countItem("quantum_entangloporter")

        if minerCount < 1 then
            error("Task start: Missing Digital Miner (found " .. minerCount .. ")")
        end
        if transporterCount < 5 then
            error("Task start: Need 5 Ultimate Logistical Transporters (found " .. transporterCount .. ")")
        end
        if entangloporterCount < 1 then
            error("Task start: Missing Quantum Entangloporter (found " .. entangloporterCount .. ")")
        end
        if not tlib.ensureFuel(80) then
            error("Task start: Insufficient fuel for operation")
        end

        setPhase("place_miner")
    end

    -- -------------------------------------------------------------------------
    -- place_miner: place digital miner directly above the turtle
    -- -------------------------------------------------------------------------
    if p.phase == "place_miner" then
        local ok, err = tlib.selectItem("digital_miner")
        if not ok then
            error("place_miner: Digital miner not found: " .. tostring(err))
        end

        local placed = ccTurtle.placeUp()
        if not placed then
            error("place_miner: Failed to place digital miner above")
        end

        tlib.scanInventory()
        print("Digital miner placed.")
        setPhase("nav_to_pipe_start")
    end

    -- -------------------------------------------------------------------------
    -- nav_to_pipe_start: forward×2, up×2, turnRight
    -- -------------------------------------------------------------------------
    if p.phase == "nav_to_pipe_start" then
        mv(tlib.forward, "nav_to_pipe_start: forward(1)")
        mv(tlib.forward, "nav_to_pipe_start: forward(2)")
        mv(tlib.up, "nav_to_pipe_start: up(1)")
        mv(tlib.up, "nav_to_pipe_start: up(2)")
        tlib.turnRight()

        setPhase("place_transporters")
    end

    -- -------------------------------------------------------------------------
    -- place_transporters sequence:
    -- back+place, back+place, turnLeft, back+place, back+place, back+place
    -- transporterStep tracks completed placements (0 = none, 5 = all done)
    -- -------------------------------------------------------------------------
    if p.phase == "place_transporters" then
        while p.transporterStep < 5 do
            if p.transporterStep == 2 then
                tlib.turnLeft()
            end

            mv(tlib.back, string.format("place_transporters: back (step %d)", p.transporterStep + 1))


            local selOk, selErr = tlib.selectItem("ultimate_logistical_transporter")
            if not selOk then
                error(string.format("place_transporters step %d: transporter not found: %s",
                    p.transporterStep + 1, tostring(selErr)))
            end

            local placed = ccTurtle.place()
            if not placed then
                error(string.format("place_transporters step %d: place() failed", p.transporterStep + 1))
            end

            p.transporterStep = p.transporterStep + 1
            
            saveTask()
            print(string.format("Transporter %d/5 placed.", p.transporterStep))
        end

        setPhase("nav_to_entangloporter")
    end

    -- -------------------------------------------------------------------------
    -- nav_to_entangloporter: down 1
    -- -------------------------------------------------------------------------
    if p.phase == "nav_to_entangloporter" then
        mv(tlib.down, "nav_to_entangloporter: down(1)")
        setPhase("place_entangloporter")
    end

    -- -------------------------------------------------------------------------
    -- place_entangloporter: place quantum entangloporter in front
    -- -------------------------------------------------------------------------
    if p.phase == "place_entangloporter" then
        local selOk, selErr = tlib.selectItem("quantum_entangloporter")
        if not selOk then
            error("place_entangloporter: Entangloporter not found: " .. tostring(selErr))
        end

        local placed = ccTurtle.place()
        if not placed then
            error("place_entangloporter: Failed to place quantum entangloporter")
        end

        tlib.scanInventory()
        print("Quantum entangloporter placed.")
        setPhase("setup_entangloporter")
    end

    -- -------------------------------------------------------------------------
    -- setup_entangloporter: wrap peripheral and configure
    -- -------------------------------------------------------------------------
    if p.phase == "setup_entangloporter" then
        ccSleep(PERIPHERAL_CONNECT_DELAY)
        local periph = plib.wrap("entangloporter", "quantumEntangloporter")
        if not periph then
            error("setup_entangloporter: Could not wrap entangloporter as peripheral")
        end

        setupEntangloporter(periph)
        setPhase("nav_to_miner")
    end

    -- -------------------------------------------------------------------------
    -- nav_to_miner: down 1, forward 1, turnRight, forward 2, turnLeft
    -- -------------------------------------------------------------------------
    if p.phase == "nav_to_miner" then
        mv(tlib.down, "nav_to_miner: down(1)")
        mv(tlib.forward, "nav_to_miner: forward(1)")
        tlib.turnRight()
        mv(tlib.forward, "nav_to_miner: forward(2)")
        mv(tlib.forward, "nav_to_miner: forward(3)")
        tlib.turnLeft()

        setPhase("setup_miner")
    end

    -- -------------------------------------------------------------------------
    -- setup_miner: wrap peripheral and configure digital miner
    -- -------------------------------------------------------------------------
    if p.phase == "setup_miner" then
        ccSleep(PERIPHERAL_CONNECT_DELAY)
        local periph = plib.wrap("digitalMiner", "digitalMiner")
        if not periph then
            error("setup_miner: Could not wrap digital miner as peripheral")
        end

        setupMiner(periph, p.currentSettings, p.currentFilters)
        setPhase("monitor")
    end

    -- -------------------------------------------------------------------------
    -- monitor: poll digital miner until it stops running
    -- -------------------------------------------------------------------------
    if p.phase == "monitor" then
        local periph = plib.wrap("digitalMiner", "digitalMiner")
        if not periph then
            error("monitor: Could not wrap digital miner as peripheral")
        end

        print("Monitoring digital miner...")

        periph.start()

        while true do
            local toMine = periph.getToMine and periph.getToMine()

            print(string.format("[Check %d] ToMine: %s", p.monitorChecks, tostring(toMine)))

            p.monitorChecks = p.monitorChecks + 1
            saveTask()

            if toMine == 0 then
                print("Nothing left to mine. Stopping digital miner...")
                periph.stop()
                ccSleep(5)
                break
            end

            ccSleep(1)
        end

        setPhase("teardown_miner")
    end

    -- -------------------------------------------------------------------------
    -- teardown_miner: dig the digital miner (currently above)
    -- -------------------------------------------------------------------------
    if p.phase == "teardown_miner" then
        local dug = tlib.digUp()
        if not dug then
            error("teardown_miner: Failed to dig digital miner above")
        end

        tlib.scanInventory()
        print("Digital miner picked up.")
        setPhase("nav_to_entangloporter_teardown")
    end

    -- -------------------------------------------------------------------------
    -- nav_to_entangloporter_teardown: turnLeft, forward×2
    -- -------------------------------------------------------------------------
    if p.phase == "nav_to_entangloporter_teardown" then
        tlib.turnLeft()
        mv(tlib.forward, "nav_to_entangloporter_teardown: forward(1)")
        mv(tlib.forward, "nav_to_entangloporter_teardown: forward(2)")

        setPhase("teardown_entangloporter")
    end

    -- -------------------------------------------------------------------------
    -- teardown_entangloporter: digUp to break quantum entangloporter
    -- -------------------------------------------------------------------------
    if p.phase == "teardown_entangloporter" then
        local dug = tlib.digUp()
        if not dug then
            error("teardown_entangloporter: Failed to dig quantum entangloporter above")
        end

        tlib.scanInventory()
        print("Quantum entangloporter picked up.")
        setPhase("teardown_transporters")
    end

    -- -------------------------------------------------------------------------
    -- teardown_transporters sequence:
    -- up+digUp, up+turnRight+dig, forward+dig, forward+turnRight+dig,
    -- forward+dig, forward+turnLeft, down×2, back×2
    -- -------------------------------------------------------------------------
    if p.phase == "teardown_transporters" then
        if p.teardownStep == 0 then
            mv(tlib.up, "teardown_transporters: up(1)")
            local dug = tlib.digUp()
            if not dug then
                error("teardown_transporters: Failed to dig transporter (digUp step 1)")
            end
            tlib.scanInventory()
            print("Transporter 1/5 picked up.")
            p.teardownStep = 1
            saveTask()
        end

        if p.teardownStep == 1 then
            mv(tlib.up, "teardown_transporters: up(2)")
            tlib.turnRight()
            local dug = tlib.dig()
            if not dug then
                error("teardown_transporters: Failed to dig transporter (dig step 2)")
            end
            tlib.scanInventory()
            print("Transporter 2/5 picked up.")
            p.teardownStep = 2
            saveTask()
        end

        if p.teardownStep == 2 then
            mv(tlib.forward, "teardown_transporters: forward(1)")
            local dug = tlib.dig()
            if not dug then
                error("teardown_transporters: Failed to dig transporter (dig step 3)")
            end
            tlib.scanInventory()
            print("Transporter 3/5 picked up.")
            p.teardownStep = 3
            saveTask()
        end

        if p.teardownStep == 3 then
            mv(tlib.forward, "teardown_transporters: forward(2)")
            tlib.turnRight()
            local dug = tlib.dig()
            if not dug then
                error("teardown_transporters: Failed to dig transporter (dig step 4)")
            end
            tlib.scanInventory()
            print("Transporter 4/5 picked up.")
            p.teardownStep = 4
            saveTask()
        end

        if p.teardownStep == 4 then
            mv(tlib.forward, "teardown_transporters: forward(3)")
            local dug = tlib.dig()
            if not dug then
                error("teardown_transporters: Failed to dig transporter (dig step 5)")
            end
            tlib.scanInventory()
            print("Transporter 5/5 picked up.")
            p.teardownStep = 5
            saveTask()
        end

        if p.teardownStep == 5 then
            mv(tlib.forward, "teardown_transporters: forward(4)")
            tlib.turnLeft()
            p.teardownStep = 6
            saveTask()
        end

        if p.teardownStep == 6 then
            mv(tlib.down, "teardown_transporters: down(1)")
            mv(tlib.down, "teardown_transporters: down(2)")
            p.teardownStep = 7
            saveTask()
        end

        if p.teardownStep == 7 then
            mv(tlib.back, "teardown_transporters: back(1)")
            mv(tlib.back, "teardown_transporters: back(2)")
            p.teardownStep = 8
            saveTask()
        end

        if p.teardownStep >= 8 then
            setPhase("finalize")
        end
    end

    -- -------------------------------------------------------------------------
    -- finalize: mark complete and clear resume state
    -- -------------------------------------------------------------------------
    if p.phase == "finalize" then
        p.completed = true
        local managerLabel, managerProtocol = resolveManagerSelection()
        local lookupTxOk, lookupOk, managerID = tlib.runRednetTransaction(function()
            return nlib.lookup(managerProtocol, managerLabel)
        end)
        if not lookupTxOk then
            error("finalize: manager lookup transaction failed: " .. tostring(lookupOk))
        end
        if not lookupOk then
            error("finalize: manager lookup failed")
        end
        if managerID then
            reportTaskComplete(managerID, managerProtocol)
        end

        p.activeTask = nil
        p.currentSettings = nil
        p.currentFilters = nil
        resetTaskRuntimeState()
        p.phase = "await_task"
        saveTask()
        print("Digital mining task complete. Waiting for next assignment.")
    end
end

-- =============================================================================
-- Entry Point
-- =============================================================================
tlib.execute(run)
