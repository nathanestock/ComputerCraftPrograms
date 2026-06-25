local tlib = require("tlib")

-- =============================================================================
-- Cached Globals
-- =============================================================================
local ccTurtle     = rawget(_G, "turtle")
local ccPeripheral = rawget(_G, "peripheral")
local ccSleep      = rawget(_G, "sleep") or function(_) end

-- =============================================================================
-- State Setup
-- =============================================================================
tlib.load()
local task = tlib.getTaskState() or {}

task.digitalMining = task.digitalMining or {
    version           = 1,
    phase             = "boot",
    transporterStep   = 0,   -- 0–4: how many back+place steps completed
    teardownStep      = 0,   -- 0=up nav, 1–4=dig+forward per transporter
    monitorChecks     = 0,
    homePos           = nil, -- {x, y, z, facing} at boot
    rebootToken       = nil,
    rebootRequested   = false,
    rebootVerified    = false,
    completed         = false,
    updatedAt         = os.time()
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

-- TODO: implement quantum entangloporter configuration
local function setupEntangloporter(periph) -- luacheck: ignore periph
    print("Entangloporter connected. Configuration: TODO")
end

-- TODO: implement digital miner configuration (radius, filter, auto-start, etc.)
local function setupMiner(periph) -- luacheck: ignore periph
    print("Digital miner connected. Configuration: TODO")
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

        local x, y, z, facing = tlib.getPosition()
        p.homePos = { x = x, y = y, z = z, facing = facing }
        saveTask()

        tlib.scanInventory()
        local minerCount        = countItem("digital_miner")
        local transporterCount  = countItem("ultimate_logistical_transporter")
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
        mv(tlib.back,    "nav_to_pipe_start: back(1)")
        mv(tlib.back,    "nav_to_pipe_start: back(2)")
        mv(tlib.up,      "nav_to_pipe_start: up(1)")
        mv(tlib.up,      "nav_to_pipe_start: up(2)")
        mv(tlib.up,      "nav_to_pipe_start: up(3)")
        mv(tlib.forward, "nav_to_pipe_start: forward(1)")
        mv(tlib.forward, "nav_to_pipe_start: forward(2)")
        tlib.turnRight()

        setPhase("place_transporters")
    end

    -- -------------------------------------------------------------------------
    -- place_transporters: back 1 then place, repeated 4 times
    -- transporterStep tracks completed steps (0 = none, 4 = all done)
    -- Each back places the transporter where the turtle just was (in front).
    -- T1→(0,3,0), T2→(-1,3,0), T3→(-2,3,0), T4→(-3,3,0)
    -- -------------------------------------------------------------------------
    if p.phase == "place_transporters" then
        while p.transporterStep < 4 do
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
            print(string.format("Transporter %d/4 placed.", p.transporterStep))
        end

        setPhase("nav_to_entangloporter")
    end

    -- -------------------------------------------------------------------------
    -- nav_to_entangloporter: down 1
    -- Turtle: (-4,3,0) → (-4,2,0) facing East
    -- -------------------------------------------------------------------------
    if p.phase == "nav_to_entangloporter" then
        mv(tlib.down, "nav_to_entangloporter: down(1)")
        setPhase("place_entangloporter")
    end

    -- -------------------------------------------------------------------------
    -- place_entangloporter: place quantum entangloporter in front
    -- Turtle at (-4,2,0) facing East → places at (-3,2,0), adjacent below T4 ✓
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
        local periph = ccPeripheral and ccPeripheral.wrap("front")
        if not periph then
            error("setup_entangloporter: Could not wrap entangloporter as peripheral")
        end

        setupEntangloporter(periph)
        setPhase("nav_to_miner")
    end

    -- -------------------------------------------------------------------------
    -- nav_to_miner: turnRight, forward×2, turnLeft, forward×3, turnLeft
    -- (-4,2,0) facing East
    --   → turnRight → facing South
    --   → forward×2 → (-4,2,2)
    --   → turnLeft  → facing East
    --   → forward×3 → (-1,2,2)
    --   → turnLeft  → facing North (in front of digital miner) ✓
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

        setPhase("setup_miner")
    end

    -- -------------------------------------------------------------------------
    -- setup_miner: wrap peripheral and configure digital miner
    -- -------------------------------------------------------------------------
    if p.phase == "setup_miner" then
        local periph = ccPeripheral and ccPeripheral.wrap("front")
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
        local periph = ccPeripheral and ccPeripheral.wrap("front")
        if not periph then
            error("monitor: Could not wrap digital miner as peripheral")
        end

        print("Monitoring digital miner...")

        while true do
            local running   = periph.isRunning and periph.isRunning()
            local minerState = periph.getState  and periph.getState()

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
    -- teardown_miner: dig the digital miner (currently in front)
    -- -------------------------------------------------------------------------
    if p.phase == "teardown_miner" then
        local dug = ccTurtle.dig()
        if not dug then
            error("teardown_miner: Failed to dig digital miner")
        end

        tlib.scanInventory()
        print("Digital miner picked up.")
        setPhase("nav_to_entangloporter_teardown")
    end

    -- -------------------------------------------------------------------------
    -- nav_to_entangloporter_teardown: reverse of nav_to_miner
    -- (-1,2,2) facing North
    --   → turnRight → facing East
    --   → back×3    → (-4,2,2)
    --   → turnRight → facing South
    --   → back×2    → (-4,2,0)
    --   → turnLeft  → facing East (entangloporter at (-3,2,0) in front) ✓
    -- -------------------------------------------------------------------------
    if p.phase == "nav_to_entangloporter_teardown" then
        tlib.turnRight()
        mv(tlib.back, "nav_to_entangloporter_teardown: back(1)")
        mv(tlib.back, "nav_to_entangloporter_teardown: back(2)")
        mv(tlib.back, "nav_to_entangloporter_teardown: back(3)")
        tlib.turnRight()
        mv(tlib.back, "nav_to_entangloporter_teardown: back(4)")
        mv(tlib.back, "nav_to_entangloporter_teardown: back(5)")
        tlib.turnLeft()

        setPhase("teardown_entangloporter")
    end

    -- -------------------------------------------------------------------------
    -- teardown_entangloporter: dig quantum entangloporter (in front)
    -- -------------------------------------------------------------------------
    if p.phase == "teardown_entangloporter" then
        local dug = ccTurtle.dig()
        if not dug then
            error("teardown_entangloporter: Failed to dig quantum entangloporter")
        end

        tlib.scanInventory()
        print("Quantum entangloporter picked up.")
        setPhase("teardown_transporters")
    end

    -- -------------------------------------------------------------------------
    -- teardown_transporters: up 1 then dig+forward × 4 (T4 → T1)
    -- teardownStep 0: up 1 → (-4,3,0), T4 in front at (-3,3,0)
    -- teardownStep 1: dig T4, forward → (-3,3,0), T3 in front
    -- teardownStep 2: dig T3, forward → (-2,3,0), T2 in front
    -- teardownStep 3: dig T2, forward → (-1,3,0), T1 in front
    -- teardownStep 4: dig T1, forward → (0,3,0)  ← ready for return_home
    -- -------------------------------------------------------------------------
    if p.phase == "teardown_transporters" then
        if p.teardownStep == 0 then
            mv(tlib.up, "teardown_transporters: up(1)")
            p.teardownStep = 1
            saveTask()
        end

        while p.teardownStep <= 4 do
            local dug = ccTurtle.dig()
            if not dug then
                error(string.format("teardown_transporters: Failed to dig transporter (step %d)",
                    p.teardownStep))
            end

            mv(tlib.forward,
               string.format("teardown_transporters: forward (step %d)", p.teardownStep))

            tlib.scanInventory()
            print(string.format("Transporter %d/4 picked up.", p.teardownStep))
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
        mv(tlib.back,    "return_home: back(1)")
        mv(tlib.back,    "return_home: back(2)")
        mv(tlib.down,    "return_home: down(1)")
        mv(tlib.down,    "return_home: down(2)")
        mv(tlib.down,    "return_home: down(3)")
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
