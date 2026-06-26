local tlib                     = require("tlib")
local plib                     = require("plib")

-- =============================================================================
-- Cached Globals
-- =============================================================================
local ccTurtle                 = rawget(_G, "turtle")
local ccSleep                  = rawget(_G, "sleep") or function(_) end
local PERIPHERAL_CONNECT_DELAY = 1
local ENTANGLOPORTER_FREQ      = "digital_miners"
local ENTANGLOPORTER_REFUEL_FREQ = "lava_buckets"

-- =============================================================================
-- State Setup
-- =============================================================================
tlib.load()
local task = tlib.getTaskState() or {}

task.digitalMining = task.digitalMining or {
    version         = 1,
    phase           = "boot",
    transporterStep = 0,     -- 0–5: how many transporter placements completed
    teardownStep    = 0,     -- step tracker for transporter teardown sequence
    monitorChecks   = 0,
    homePos         = nil,   -- {x, y, z, facing} at boot
    rebootToken     = nil,
    rebootRequested = false,
    rebootVerified  = false,
    completed       = false,
    updatedAt       = os.time()
}

local p = task.digitalMining

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

local function setupMiner(periph)
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

    periph.setAutoEject(true)
    periph.setSilkTouch(true)
    periph.setMaxY(319)
    periph.setMinY(-64)
    periph.setRadius(32)

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

    local filter = {
        ["type"] = "MINER_TAG_FILTER",
        ["tag"] = "*:ores"
    }

    local success, err = periph.addFilter(filter)
    if not success then
        error("setupMiner: Failed to add filter: " .. tostring(err))
    end

    print("Digital miner configured: autoEject=true, silkTouch=true, y=[-64,319], radius=32, filter=*ores")
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
        saveTask()

        tlib.scanInventory()
        local minerCount          = countItem("digital_miner")
        local transporterCount    = countItem("ultimate_logistical_transporter")
        local entangloporterCount = countItem("quantum_entangloporter")

        if minerCount < 1 then
            error("Boot: Missing Digital Miner (found " .. minerCount .. ")")
        end
        if transporterCount < 5 then
            error("Boot: Need 5 Ultimate Logistical Transporters (found " .. transporterCount .. ")")
        end
        if entangloporterCount < 1 then
            error("Boot: Missing Quantum Entangloporter (found " .. entangloporterCount .. ")")
        end
        if not tlib.ensureFuel(40) then
            error("Boot: Insufficient fuel for operation")
        end

        print(string.format("Inventory OK. Home: (%d, %d, %d) facing %d", x, y, z, facing))
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

        setupMiner(periph)
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
        saveTask()
        print("Digital mining operation complete. All items recovered.")
        tlib.completeProgram(false)
    end
end

-- =============================================================================
-- Entry Point
-- =============================================================================
tlib.execute(run)
