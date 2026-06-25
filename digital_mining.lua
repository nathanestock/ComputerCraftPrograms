local tlib                     = require("tlib")
local plib                     = require("plib")

-- =============================================================================
-- Cached Globals
-- =============================================================================
local ccTurtle                 = rawget(_G, "turtle")
local ccSleep                  = rawget(_G, "sleep") or function(_) end
local PERIPHERAL_CONNECT_DELAY = 1
local ENTANGLOPORTER_FREQ      = "digital_miners"

-- =============================================================================
-- State Setup
-- =============================================================================
tlib.load()
local task = tlib.getTaskState() or {}

task.digitalMining = task.digitalMining or {
    version         = 1,
    phase           = "boot",
    transporterStep = 0,     -- 0–4: how many placement steps completed (1–3=back, 4=down)
    teardownStep    = 0,     -- 0=up nav, 1–3=dig+forward per transporter
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

    periph.setMode("ENERGY", "FRONT", "OUTPUT")
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
    if not periph.createMinerTagFilter then
        error("setupMiner: Peripheral missing createMinerTagFilter()")
    end
    if not periph.addFilter then
        error("setupMiner: Peripheral missing addFilter()")
    end

    periph.setAutoEject(true)
    periph.setSilkTouch(true)
    periph.setMaxY(319)
    periph.setMinY(-64)
    periph.setRadius(32)

    local existingFilters = periph.getFilters()
    for _, filter in ipairs(existingFilters) do
        periph.removeFilter(filter)
    end

    local diamondFilter = {
        type = "TagFilter",
        tagName = "c:ores/diamond"
    }

    local success, err = periph.addFilter(diamondFilter)
    if not success then
        error("setupMiner: Failed to add filter: " .. tostring(err))
    end

    print("Digital miner configured: autoEject=true, silkTouch=true, y=[-64,319], radius=32, filter=*ores/diamond")
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
        if transporterCount < 4 then
            error("Boot: Need 4 Ultimate Logistical Transporters (found " .. transporterCount .. ")")
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
    -- nav_to_pipe_start: back×2, up×3, forward×2, turnRight
    -- From start (0,0,0) → (0,3,0) facing East
    -- -------------------------------------------------------------------------
    if p.phase == "nav_to_pipe_start" then
        mv(tlib.back, "nav_to_pipe_start: back(1)")
        mv(tlib.back, "nav_to_pipe_start: back(2)")
        mv(tlib.up, "nav_to_pipe_start: up(1)")
        mv(tlib.up, "nav_to_pipe_start: up(2)")
        mv(tlib.up, "nav_to_pipe_start: up(3)")
        mv(tlib.forward, "nav_to_pipe_start: forward(1)")
        mv(tlib.forward, "nav_to_pipe_start: forward(2)")
        tlib.turnRight()

        setPhase("place_transporters")
    end

    -- -------------------------------------------------------------------------
    -- place_transporters: steps 1–3 = back+place; step 4 = down+place
    -- transporterStep tracks completed steps (0 = none, 4 = all done)
    -- T1→(0,3,0), T2→(-1,3,0), T3→(-2,3,0) via back; T4→(-2,2,0) via down
    -- -------------------------------------------------------------------------
    if p.phase == "place_transporters" then
        while p.transporterStep < 4 do
            if p.transporterStep < 3 then
                mv(tlib.back, string.format("place_transporters: back (step %d)", p.transporterStep + 1))
            else
                mv(tlib.down, "place_transporters: down (step 4)")
            end

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
            print(string.format("Transporter %d/4 placed.", p.transporterStep))
        end

        setPhase("nav_to_entangloporter")
    end

    -- -------------------------------------------------------------------------
    -- nav_to_entangloporter: down 1
    -- Turtle: (-3,2,0) → (-3,1,0) facing East
    -- -------------------------------------------------------------------------
    if p.phase == "nav_to_entangloporter" then
        mv(tlib.down, "nav_to_entangloporter: down(1)")
        setPhase("place_entangloporter")
    end

    -- -------------------------------------------------------------------------
    -- place_entangloporter: place quantum entangloporter in front
    -- Turtle at (-3,1,0) facing East → places at (-2,1,0), adjacent below T4 at (-2,2,0) ✓
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
    -- nav_to_miner: move around entangloporter and return under miner
    -- (-3,1,0) facing East
    --   → turnRight → facing South
    --   → forward×2 → (-3,1,2)
    --   → turnLeft  → facing East
    --   → forward×3 → (0,1,2)
    --   → turnLeft  → facing North
    --   → down      → (0,0,2)
    --   → forward×2 → (0,0,0) facing North (miner above at (0,1,0)) ✓
    -- -------------------------------------------------------------------------
    if p.phase == "nav_to_miner" then
        tlib.turnRight()
        mv(tlib.forward, "nav_to_miner: forward(1)")
        mv(tlib.forward, "nav_to_miner: forward(2)")
        tlib.turnLeft()
        mv(tlib.forward, "nav_to_miner: forward(3)")
        mv(tlib.forward, "nav_to_miner: forward(4)")
        mv(tlib.forward, "nav_to_miner: forward(5)")
        tlib.turnLeft()
        mv(tlib.down, "nav_to_miner: down(1)")
        mv(tlib.forward, "nav_to_miner: forward(6)")
        mv(tlib.forward, "nav_to_miner: forward(7)")

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

        ccSleep(10)

        while true do
            local running    = periph.isRunning and periph.isRunning()
            local minerState = periph.getState and periph.getState()

            print(string.format("[Check %d] State: %s | Running: %s",
                p.monitorChecks, tostring(minerState), tostring(running)))

            p.monitorChecks = p.monitorChecks + 1
            saveTask()

            if not running then
                print("Digital miner has completed operation.")
                break
            end

            ccSleep(5)
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
    -- nav_to_entangloporter_teardown: reverse of nav_to_miner
    -- (0,0,0) facing North
    --   → back×2    → (0,0,2)
    --   → up        → (0,1,2)
    --   → turnRight → facing East
    --   → back×3    → (-3,1,2)
    --   → turnRight → facing South
    --   → back×2    → (-3,1,0)
    --   → turnLeft  → facing East (entangloporter at (-2,1,0) in front) ✓
    -- -------------------------------------------------------------------------
    if p.phase == "nav_to_entangloporter_teardown" then
        mv(tlib.back, "nav_to_entangloporter_teardown: back(1)")
        mv(tlib.back, "nav_to_entangloporter_teardown: back(2)")
        mv(tlib.up, "nav_to_entangloporter_teardown: up(1)")
        tlib.turnRight()
        mv(tlib.back, "nav_to_entangloporter_teardown: back(3)")
        mv(tlib.back, "nav_to_entangloporter_teardown: back(4)")
        mv(tlib.back, "nav_to_entangloporter_teardown: back(5)")
        tlib.turnRight()
        mv(tlib.back, "nav_to_entangloporter_teardown: back(6)")
        mv(tlib.back, "nav_to_entangloporter_teardown: back(7)")
        tlib.turnLeft()

        setPhase("teardown_entangloporter")
    end

    -- -------------------------------------------------------------------------
    -- teardown_entangloporter: dig quantum entangloporter (in front)
    -- -------------------------------------------------------------------------
    if p.phase == "teardown_entangloporter" then
        local dug = tlib.dig()
        if not dug then
            error("teardown_entangloporter: Failed to dig quantum entangloporter")
        end

        tlib.scanInventory()
        print("Quantum entangloporter picked up.")
        setPhase("teardown_transporters")
    end

    -- -------------------------------------------------------------------------
    -- teardown_transporters: up×2 to dig T4+T3, then forward+dig×2 for T2+T1, forward
    -- teardownStep 0: up → (-3,2,0), dig T4 at (-2,2,0)
    -- teardownStep 1: up → (-3,3,0), dig T3 at (-2,3,0)
    -- teardownStep 2: forward → (-2,3,0), dig T2 at (-1,3,0)
    -- teardownStep 3: forward → (-1,3,0), dig T1 at (0,3,0)
    -- teardownStep 4: forward → (0,3,0)  ← ready for return_home
    -- -------------------------------------------------------------------------
    if p.phase == "teardown_transporters" then
        -- Step 0: up to T4 level, dig T4
        if p.teardownStep == 0 then
            mv(tlib.up, "teardown_transporters: up to T4")
            local dug = tlib.dig()
            if not dug then
                error("teardown_transporters: Failed to dig T4")
            end
            tlib.scanInventory()
            print("Transporter 4/4 picked up.")
            p.teardownStep = 1
            saveTask()
        end

        -- Step 1: up to T3 level, dig T3
        if p.teardownStep == 1 then
            mv(tlib.up, "teardown_transporters: up to T3")
            local dug = tlib.dig()
            if not dug then
                error("teardown_transporters: Failed to dig T3")
            end
            tlib.scanInventory()
            print("Transporter 3/4 picked up.")
            p.teardownStep = 2
            saveTask()
        end

        -- Steps 2–3: forward then dig (T2, T1); step 4: forward to (0,3,0)
        while p.teardownStep <= 4 do
            mv(tlib.forward,
                string.format("teardown_transporters: forward (step %d)", p.teardownStep))

            if p.teardownStep <= 3 then
                local dug = tlib.dig()
                if not dug then
                    error(string.format("teardown_transporters: Failed to dig transporter (step %d)",
                        p.teardownStep))
                end
                tlib.scanInventory()
                print(string.format("Transporter %d/4 picked up.", 4 - p.teardownStep))
            end

            p.teardownStep = p.teardownStep + 1
            saveTask()
        end

        setPhase("return_home")
    end

    -- -------------------------------------------------------------------------
    -- return_home: turnLeft, back×2, down×3, forward×2
    -- (0,3,0) facing East
    --   → turnLeft  → facing North
    --   → back×2    → (0,3,2)   [backing south from north]
    --   → down×3    → (0,0,2)
    --   → forward×2 → (0,0,0)  facing North ✓
    -- -------------------------------------------------------------------------
    if p.phase == "return_home" then
        tlib.turnLeft()
        mv(tlib.back, "return_home: back(1)")
        mv(tlib.back, "return_home: back(2)")
        mv(tlib.down, "return_home: down(1)")
        mv(tlib.down, "return_home: down(2)")
        mv(tlib.down, "return_home: down(3)")
        mv(tlib.forward, "return_home: forward(1)")
        mv(tlib.forward, "return_home: forward(2)")

        setPhase("finalize")
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
