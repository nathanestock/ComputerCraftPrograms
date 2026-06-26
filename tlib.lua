-- Turtle Library (tlib.lua)
local tlib = {}
local turtle = rawget(_G, "turtle")
local hasTurtle = type(turtle) == "table"

if not hasTurtle then
    local selectedSlot = 1
    local function unsupportedTurtleAction()
        return false, "Turtle API unavailable on this computer"
    end

    turtle = {
        getFuelLevel = function() return "unlimited" end,
        getFuelLimit = function() return "unlimited" end,
        getSelectedSlot = function() return selectedSlot end,
        select = function(slot)
            if type(slot) == "number" and slot >= 1 and slot <= 16 then
                selectedSlot = math.floor(slot)
                return true
            end
            return false
        end,
        getItemDetail = function() return nil end,
        refuel = unsupportedTurtleAction,
        place = unsupportedTurtleAction,
        placeUp = unsupportedTurtleAction,
        placeDown = unsupportedTurtleAction,
        suck = unsupportedTurtleAction,
        suckUp = unsupportedTurtleAction,
        suckDown = unsupportedTurtleAction,
        drop = unsupportedTurtleAction,
        dropUp = unsupportedTurtleAction,
        dropDown = unsupportedTurtleAction,
        dig = unsupportedTurtleAction,
        digUp = unsupportedTurtleAction,
        digDown = unsupportedTurtleAction,
        equipLeft = unsupportedTurtleAction,
        equipRight = unsupportedTurtleAction,
        getEquippedLeft = function() return nil end,
        getEquippedRight = function() return nil end,
        forward = unsupportedTurtleAction,
        back = unsupportedTurtleAction,
        up = unsupportedTurtleAction,
        down = unsupportedTurtleAction,
        turnLeft = unsupportedTurtleAction,
        turnRight = unsupportedTurtleAction,
        detect = function() return false end,
        detectUp = function() return false end,
        detectDown = function() return false end
    }
end

local dependencies = {
    "tlib",
    "plib",
    "nlib",
}

local programs = {
    "test",
    "digital_mining",
}

-- Directional math vectors:
-- 0: North (-Z), 1: East (+X), 2: South (+Z), 3: West (-X)
local vectors = {
    [0] = { x = 0, z = -1 },
    [1] = { x = 1, z = 0 },
    [2] = { x = 0, z = 1 },
    [3] = { x = -1, z = 0 }
}

-- Internal Library State
local state = {
    x = 0,
    y = 0,
    z = 0,
    facing = 0,
    currentProgram = nil,
    resumeCommand = nil,
    taskState = {},
    inventory = {},      -- Cache structure: [slot] = { name = "minecraft:coal", count = 64 }
    gpsAvailable = false,
    hasWireless = false,
    hasChunkLoader = false,
    refuelStrategy = "inventory_scan",
    refuelStrategies = {}
}

local STATE_FILE = "turtle_state.json"

local REFUEL_SIDE_MAP = {
    front = {
        place = turtle.place,
        suck = turtle.suck,
        drop = turtle.drop,
        dig = turtle.dig,
        sideName = "front",
    },
    up = {
        place = turtle.placeUp,
        suck = turtle.suckUp,
        drop = turtle.dropUp,
        dig = turtle.digUp,
        sideName = "top",
    },
    down = {
        place = turtle.placeDown,
        suck = turtle.suckDown,
        drop = turtle.dropDown,
        dig = turtle.digDown,
        sideName = "bottom",
    }
}

local refuelStrategies = {}

local function cloneTable(value)
    if type(value) ~= "table" then
        return value
    end

    local copy = {}
    for k, v in pairs(value) do
        if type(v) == "table" then
            copy[k] = cloneTable(v)
        else
            copy[k] = v
        end
    end

    return copy
end

local function mergeOptions(defaults, overrides)
    local merged = {}
    for k, v in pairs(defaults or {}) do
        merged[k] = (type(v) == "table") and cloneTable(v) or v
    end
    for k, v in pairs(overrides or {}) do
        merged[k] = (type(v) == "table") and cloneTable(v) or v
    end
    return merged
end

local function ensureStateDefaults()
    if type(state.taskState) ~= "table" then
        state.taskState = {}
    end

    if type(state.inventory) ~= "table" then
        state.inventory = {}
    end

    if type(state.refuelStrategies) ~= "table" then
        state.refuelStrategies = {}
    end

    if type(state.refuelStrategy) ~= "string" or state.refuelStrategy == "" then
        state.refuelStrategy = "inventory_scan"
    end
end

local function getFuelLevelNumber()
    local level = turtle.getFuelLevel()
    if level == "unlimited" then
        return math.huge
    end
    return level or 0
end

local function getFuelTarget(options)
    local needed = tonumber(options and options.needed) or 1
    if needed < 1 then needed = 1 end
    return getFuelLevelNumber() + needed
end

local function snapshotInventory()
    local snapshot = {}
    for slot = 1, 16 do
        local detail = turtle.getItemDetail(slot)
        if detail then
            snapshot[slot] = { name = detail.name, count = detail.count }
        end
    end
    return snapshot
end

local function shouldReturnItem(detail, options)
    if not detail or not detail.name then
        return false
    end

    local returnPatterns = options.returnPatterns or { "bucket", options.fuelItemPattern }
    for _, pattern in ipairs(returnPatterns) do
        if type(pattern) == "string" and pattern ~= "" and detail.name:find(pattern, 1, true) then
            return true
        end
    end

    return false
end

local function registerRefuelStrategy(name, handler)
    refuelStrategies[name] = handler
end

local function runInventoryRefuelStrategy(options)
    local targetFuel = tonumber(options.targetFuel) or getFuelTarget(options)
    local selectedBefore = turtle.getSelectedSlot()

    for slot = 1, 16 do
        turtle.select(slot)
        if turtle.refuel(0) then
            turtle.refuel()

            local detail = turtle.getItemDetail(slot)
            if detail then
                state.inventory[slot] = { name = detail.name, count = detail.count }
            else
                state.inventory[slot] = nil
            end

            if getFuelLevelNumber() >= targetFuel then
                turtle.select(selectedBefore)
                tlib.save()
                return true, "inventory_scan_success"
            end
        end
    end

    turtle.select(selectedBefore)
    tlib.save()
    return false, "No consumable fuel found in inventory"
end

local function configureEntangloporterForFuel(peripheralObj, frequency)
    if type(peripheralObj) ~= "table" then
        return false, "Invalid entangloporter peripheral"
    end

    if type(peripheralObj.setMode) ~= "function" then
        return false, "Entangloporter missing setMode()"
    end

    local ok, err = pcall(peripheralObj.setMode, "ITEM", "BACK", "INPUT_OUTPUT")
    if not ok then
        return false, "setMode ITEM INPUT_OUTPUT failed: " .. tostring(err)
    end

    local ok2, err2 = pcall(peripheralObj.setFrequency, frequency)
    if not ok2 then
        return false, "setFrequency FUEL failed: " .. tostring(err2)
    end

    return true
end

local function bufferItemMatches(detail, options)
    if type(detail) ~= "table" then
        return false
    end

    local pattern = options.fuelItemPattern or "lava_bucket"
    local name = detail.name or detail.id
    return type(name) == "string" and name:find(pattern, 1, true) ~= nil
end

local function consumeFuelFromInventory(targetFuel, fuelPattern)
    local fuelBefore = getFuelLevelNumber()

    for slot = 1, 16 do
        local detail = turtle.getItemDetail(slot)
        if detail and detail.name and detail.name:find(fuelPattern, 1, true) then
            turtle.select(slot)
            while getFuelLevelNumber() < targetFuel and turtle.refuel(1) do
            end
        end

        if getFuelLevelNumber() >= targetFuel then
            break
        end
    end

    return getFuelLevelNumber() > fuelBefore
end

local function runEntangloporterRefuelStrategy(options)
    local cfg = mergeOptions({
        side = "front",
        entangloporterItem = "quantum_entangloporter",
        fuelItemPattern = "lava_bucket",
        pullCount = 16,
        maxCycles = 10,
        retryDelay = 0.5,
        attachDelay = 0.2,
        requireBufferItem = true,
        returnLeftovers = true
    }, options)

    local ops = REFUEL_SIDE_MAP[cfg.side]
    if not ops then
        return false, "Invalid refuel side. Expected front/up/down"
    end

    local targetFuel = tonumber(cfg.targetFuel) or getFuelTarget(cfg)
    local selectedBefore = turtle.getSelectedSlot()
    local inventoryBefore = snapshotInventory()
    local entangloporterSlot = nil
    local placed = false
    local peripheralObj = nil

    local function cleanup()
        if cfg.returnLeftovers then
            for slot = 1, 16 do
                local current = turtle.getItemDetail(slot)
                if current and shouldReturnItem(current, cfg) then
                    local previous = inventoryBefore[slot]
                    local dropCount = current.count
                    if previous and previous.name == current.name then
                        dropCount = current.count - previous.count
                    end

                    if dropCount > 0 then
                        turtle.select(slot)
                        ops.drop(dropCount)
                    end
                end
            end
        end

        if placed then
            turtle.select(entangloporterSlot or selectedBefore)
            local digFn = tlib.dig
            if cfg.side == "up" then
                digFn = tlib.digUp
            elseif cfg.side == "down" then
                digFn = tlib.digDown
            end

            local dug, digErr = digFn()
            if not dug then
                turtle.select(selectedBefore)
                tlib.scanInventory()
                return false, "cleanup_failed: could not recover entangloporter (" .. tostring(digErr) .. ")"
            end

            placed = false
        end

        turtle.select(selectedBefore)
        tlib.scanInventory()
        return true
    end

    local found, slotOrErr = tlib.selectItem(cfg.entangloporterItem)
    if not found then
        return false, "Entangloporter item not found: " .. tostring(slotOrErr)
    end
    entangloporterSlot = slotOrErr

    ops.dig()

    local placedOk, placeErr = ops.place()
    if not placedOk then
        turtle.select(selectedBefore)
        return false, "Failed to place entangloporter: " .. tostring(placeErr)
    end
    placed = true

    sleep(cfg.attachDelay)

    for _ = 1, 5 do
        peripheralObj = peripheral.wrap(ops.sideName)
        if peripheralObj then break end
        sleep(0.1)
    end

    if not peripheralObj then
        local cleaned, cleanupErr = cleanup()
        if not cleaned then
            return false, cleanupErr
        end
        return false, "Failed to wrap entangloporter peripheral on " .. ops.sideName
    end

    local configOk, configErr = configureEntangloporterForFuel(peripheralObj, cfg.entangloporterFrequency)
    if not configOk then
        local cleaned, cleanupErr = cleanup()
        if not cleaned then
            return false, cleanupErr
        end
        return false, configErr
    end

    local cycles = 0
    while getFuelLevelNumber() < targetFuel and cycles < cfg.maxCycles do
        if cfg.requireBufferItem then
            if type(peripheralObj.getBufferItem) ~= "function" then
                local cleaned, cleanupErr = cleanup()
                if not cleaned then
                    return false, cleanupErr
                end
                return false, "Entangloporter missing getBufferItem()"
            end

            local ok, bufferItem = pcall(peripheralObj.getBufferItem)
            if not ok then
                local cleaned, cleanupErr = cleanup()
                if not cleaned then
                    return false, cleanupErr
                end
                return false, "getBufferItem() failed: " .. tostring(bufferItem)
            end

            if not bufferItemMatches(bufferItem, cfg) then
                cycles = cycles + 1
                sleep(cfg.retryDelay)
            else
                ops.suck(cfg.pullCount)
                local consumed = consumeFuelFromInventory(targetFuel, cfg.fuelItemPattern)
                if not consumed then
                    cycles = cycles + 1
                    sleep(cfg.retryDelay)
                end
            end
        else
            ops.suck(cfg.pullCount)
            local consumed = consumeFuelFromInventory(targetFuel, cfg.fuelItemPattern)
            if not consumed then
                cycles = cycles + 1
                sleep(cfg.retryDelay)
            end
        end
    end

    local success = getFuelLevelNumber() >= targetFuel
    local cleaned, cleanupErr = cleanup()
    if not cleaned then
        return false, cleanupErr
    end

    if success then
        return true, "entangloporter_refuel_success"
    end

    return false, "Entangloporter refuel did not reach requested target"
end

registerRefuelStrategy("inventory_scan", runInventoryRefuelStrategy)
registerRefuelStrategy("entangloporter", runEntangloporterRefuelStrategy)

ensureStateDefaults()

local function resolveProgramPath(programName)
    if type(programName) ~= "string" or programName == "" then
        return nil
    end

    local candidates = { programName }
    if not programName:match("%.lua$") then
        table.insert(candidates, programName .. ".lua")
    end

    if shell and type(shell.resolveProgram) == "function" then
        for _, candidate in ipairs(candidates) do
            local resolved = shell.resolveProgram(candidate)
            if resolved and fs.exists(resolved) then
                return resolved
            end
        end
    end

    for _, candidate in ipairs(candidates) do
        if fs.exists(candidate) then
            return candidate
        end

        if candidate:sub(1, 1) ~= "/" then
            local rooted = "/" .. candidate
            if fs.exists(rooted) then
                return rooted
            end
        end
    end

    return programName
end

local function buildLaunchCandidates(programName)
    if type(programName) ~= "string" or programName == "" then
        return {}
    end

    local seen = {}
    local list = {}

    local function add(value)
        if type(value) == "string" and value ~= "" and not seen[value] then
            seen[value] = true
            table.insert(list, value)
        end
    end

    add(programName)

    if programName:match("%.lua$") then
        add(programName:sub(1, -5))
    else
        add(programName .. ".lua")
    end

    local resolved = resolveProgramPath(programName)
    add(resolved)

    return list
end

local function runProgramFlexible(programName)
    local candidates = buildLaunchCandidates(programName)
    for _, candidate in ipairs(candidates) do
        if shell.run(candidate) then
            return true, candidate
        end
    end

    return false, nil
end



function tlib.isGpsAvailable() return state.gpsAvailable end

function tlib.isWireless() return state.hasWireless end

function tlib.isChunkLoaded() return state.hasChunkLoader end

-- =============================================================================
-- Startup Orchestrator
-- =============================================================================

function tlib.startup()
    -- Check for an interrupted program
    local loadedState = tlib.load()
    local tlibTest = loadedState.taskState and loadedState.taskState.tlibTest

    local resumeCommand = loadedState.resumeCommand
    if (type(resumeCommand) ~= "string" or resumeCommand == "") and tlibTest and tlibTest.phase and tlibTest.phase ~= "done" then
        resumeCommand = tlibTest.resumeCommand
    end

    local resumeProgram = resolveProgramPath(loadedState.currentProgram)
    if not resumeProgram and tlibTest and tlibTest.phase and tlibTest.phase ~= "done" then
        resumeProgram = resolveProgramPath(tlibTest.resumeProgram)
    end

    local launchTarget = resumeCommand or resumeProgram
    if (type(launchTarget) ~= "string" or launchTarget == "") and tlibTest and tlibTest.phase and tlibTest.phase ~= "done" then
        -- Safety net: if test harness is mid-phase but resume target was not persisted,
        -- recover via default test launcher rather than dropping to dashboard.
        launchTarget = "test"
    end

    print(string.format("Boot resume check: phase=%s currentProgram=%s resumeCommand=%s",
        tostring(tlibTest and tlibTest.phase),
        tostring(loadedState.currentProgram),
        tostring(loadedState.resumeCommand)))

    if type(launchTarget) == "string" and launchTarget ~= "" then
        print("\nRecovering state: Resuming " .. launchTarget)
        -- We don't use tlib.execute here because we are restarting the program loop,
        -- not running a single block of logic.
        local ok, launchedAs = runProgramFlexible(launchTarget)
        if ok then
            if launchedAs ~= launchTarget then
                print("Resume target adjusted to: " .. launchedAs)
            end
            return
        end

        printError("Resume launch failed for: " .. tostring(launchTarget))
    end

    -- If nothing to resume or launch fails, load the Dashboard
    print("\nSystem ready. Loading Dashboard...")
    sleep(0.5)
    tlib.showUI()
end

-- =============================================================================
-- Global Chunk Loader Lock & Interceptors (Strict Single-Loader Restriction)
-- =============================================================================

-- Safely detects if a physical slot currently holds a chunk loader
local function isChunkLoader(side)
    local pType = peripheral.getType(side)
    return pType and (pType:find("chunk") or pType:find("loader")) ~= nil
end

-- Checks if an inventory item detail represents a chunk loader item
local function isChunkLoaderItem(detail)
    if not detail then return false end
    return detail.name and (detail.name:find("chunk") or detail.name:find("loader")) ~= nil
end

-- Preserve the native ComputerCraft equip functions
local nativeEquipLeft = turtle.equipLeft
local nativeEquipRight = turtle.equipRight
local nativeDig = turtle.dig
local nativeDigUp = turtle.digUp
local nativeDigDown = turtle.digDown

-- Override equipLeft globally
turtle.equipLeft = function()
    if isChunkLoader("left") then
        return false, "Locked: Cannot unequip or replace a chunk loader!"
    end

    local activeSlot = turtle.getSelectedSlot()
    local detail = turtle.getItemDetail(activeSlot)
    if isChunkLoaderItem(detail) and isChunkLoader("right") then
        return false, "Locked: Only one chunk loader can be equipped on a turtle at a time!"
    end

    local success, err = nativeEquipLeft()
    if success then tlib.scanInventory() end
    return success, err
end

-- Override equipRight globally
turtle.equipRight = function()
    if isChunkLoader("right") then
        return false, "Locked: Cannot unequip or replace a chunk loader!"
    end

    local activeSlot = turtle.getSelectedSlot()
    local detail = turtle.getItemDetail(activeSlot)
    if isChunkLoaderItem(detail) and isChunkLoader("left") then
        return false, "Locked: Only one chunk loader can be equipped on a turtle at a time!"
    end

    local success, err = nativeEquipRight()
    if success then tlib.scanInventory() end
    return success, err
end

local function getEquippedItemName(side)
    local getter = (side == "left") and turtle.getEquippedLeft or turtle.getEquippedRight
    if type(getter) == "function" then
        local ok, equipped = pcall(getter)
        if ok then
            if type(equipped) == "string" then
                return equipped
            end

            if type(equipped) == "table" then
                if type(equipped.name) == "string" then
                    return equipped.name
                end

                if type(equipped.id) == "string" then
                    return equipped.id
                end
            end
        end
    end

    local pType = peripheral.getType(side)
    if type(pType) == "string" then
        return pType
    end

    return nil
end

local function isDiamondPickaxe(side)
    local equippedName = getEquippedItemName(side)
    return type(equippedName) == "string" and equippedName:find("diamond_pickaxe", 1, true) ~= nil
end

local function ensureDiamondPickaxeEquipped()
    if isDiamondPickaxe("left") or isDiamondPickaxe("right") then
        return true
    end

    local success, err = tlib.equip("minecraft:diamond_pickaxe", "right")
    if success then
        sleep(0.1) -- Allow time for equip to register
        return true
    end

    return false, err or "Diamond pickaxe is required for digging"
end

tlib.dig = function(...)
    local ok, err = ensureDiamondPickaxeEquipped()
    if not ok then
        return false, err
    end
    return nativeDig(...)
end

tlib.digUp = function(...)
    local ok, err = ensureDiamondPickaxeEquipped()
    if not ok then
        return false, err
    end
    return nativeDigUp(...)
end

tlib.digDown = function(...)
    local ok, err = ensureDiamondPickaxeEquipped()
    if not ok then
        return false, err
    end
    return nativeDigDown(...)
end

-- =============================================================================
-- Core State Management
-- =============================================================================

function tlib.save()
    local f = fs.open(STATE_FILE, "w")
    if f then
        f.write(textutils.serialize(state))
        f.close()
    end
end

function tlib.load()
    if fs.exists(STATE_FILE) then
        local f = fs.open(STATE_FILE, "r")
        if f then
            local data = textutils.unserialize(f.readAll())
            f.close()
            if data then state = data end
        end
    end
    ensureStateDefaults()
    return state
end

function tlib.useRefuelStrategy(name, options)
    if type(name) ~= "string" or name == "" then
        return false, "Strategy name is required"
    end

    if not refuelStrategies[name] then
        return false, "Unknown refuel strategy: " .. tostring(name)
    end

    ensureStateDefaults()
    state.refuelStrategy = name
    if options then
        state.refuelStrategies[name] = cloneTable(options)
    elseif not state.refuelStrategies[name] then
        state.refuelStrategies[name] = {}
    end

    tlib.save()
    return true
end

function tlib.getRefuelStrategy()
    ensureStateDefaults()
    local name = state.refuelStrategy
    local opts = state.refuelStrategies[name] or {}
    return name, cloneTable(opts)
end

function tlib.refuel(options)
    if turtle.getFuelLevel() == "unlimited" then
        return true, "unlimited"
    end

    ensureStateDefaults()

    local strategyName = state.refuelStrategy or "inventory_scan"
    local strategy = refuelStrategies[strategyName]
    local defaultOptions = state.refuelStrategies[strategyName] or {}
    local merged = mergeOptions(defaultOptions, options)
    merged.targetFuel = tonumber(merged.targetFuel) or getFuelTarget(merged)

    if not strategy then
        strategyName = "inventory_scan"
        strategy = refuelStrategies[strategyName]
    end

    local ok, reason = strategy(merged)
    if ok and getFuelLevelNumber() >= merged.targetFuel then
        return true, reason
    end

    if strategyName ~= "inventory_scan" and merged.allowFallback ~= false then
        if type(reason) == "string" and reason:find("^cleanup_failed:") then
            return false, reason
        end

        local fallbackDefaults = state.refuelStrategies.inventory_scan or {}
        local fallbackOptions = mergeOptions(fallbackDefaults, merged)
        fallbackOptions.targetFuel = merged.targetFuel
        local fallback = refuelStrategies.inventory_scan
        local fOk, fReason = fallback(fallbackOptions)
        if fOk and getFuelLevelNumber() >= merged.targetFuel then
            return true, "fallback_inventory_scan: " .. tostring(fReason)
        end
        return false, tostring(reason or "strategy_failed") .. "; fallback: " .. tostring(fReason)
    end

    return false, reason or "Refuel failed"
end

function tlib.getPosition() return state.x, state.y, state.z, state.facing end

function tlib.getTaskState() return state.taskState end

function tlib.setTaskState(tState)
    state.taskState = tState
    tlib.save()
end

function tlib.registerProgram(programName)
    state.resumeCommand = programName
    state.currentProgram = resolveProgramPath(programName)
    tlib.save()
end

function tlib.clearProgram()
    state.resumeCommand = nil
    state.currentProgram = nil
    state.taskState = {}
    tlib.save()
end

-- Marks a program as fully complete. Clears task state and program registration
-- while preserving turtle navigation state (position, facing, inventory, hardware).
-- Pass reboot=true to trigger os.reboot() after clearing state.
function tlib.completeProgram(reboot)
    state.resumeCommand = nil
    state.currentProgram = nil
    state.taskState = {}
    tlib.save()
    if reboot then
        os.reboot()
    end
end

-- =============================================================================
-- Self-Healing Inventory & Selection Engine
-- =============================================================================

function tlib.scanInventory()
    state.inventory = {}
    for slot = 1, 16 do
        local detail = turtle.getItemDetail(slot)
        if detail then
            state.inventory[slot] = {
                name = detail.name,
                count = detail.count
            }
        else
            state.inventory[slot] = nil
        end
    end
    tlib.save()
end

local function isMatch(cachedItem, searchName)
    if not cachedItem then return false end
    return cachedItem.name == searchName or string.find(cachedItem.name, searchName) ~= nil
end

function tlib.selectItem(itemName)
    if not state.inventory or #state.inventory == 0 then
        tlib.scanInventory()
    end

    local cachedSlot = nil
    for slot = 1, 16 do
        local item = state.inventory[slot]
        if isMatch(item, itemName) and item.count > 0 then
            cachedSlot = slot
            break
        end
    end

    if cachedSlot then
        local detail = turtle.getItemDetail(cachedSlot)
        if detail and isMatch(detail, itemName) and detail.count > 0 then
            state.inventory[cachedSlot].count = detail.count
            turtle.select(cachedSlot)
            tlib.save()
            return true, cachedSlot
        end
    end

    tlib.scanInventory()

    for slot = 1, 16 do
        local item = state.inventory[slot]
        if isMatch(item, itemName) and item.count > 0 then
            turtle.select(slot)
            return true, slot
        end
    end

    return false, "Item not found"
end

-- Attempts to equip an item by name to a preferred side. Respects chunk loader locks.
function tlib.equip(itemName, preferredSide)
    local found, slot = tlib.selectItem(itemName)
    if not found then
        return false, "Item not found in inventory: " .. tostring(itemName)
    end

    local side = preferredSide or "right"
    if isChunkLoader(side) then
        local otherSide = (side == "right") and "left" or "right"
        if isChunkLoader(otherSide) then
            return false, "Both slots are locked by chunk loaders."
        end
        side = otherSide
    end

    local success, err
    if side == "right" then
        success, err = turtle.equipRight()
    else
        success, err = turtle.equipLeft()
    end

    return success, err
end

-- =============================================================================
-- Transient Rednet Modem Handler (Equip / Unequip Logic)
-- =============================================================================

local function getWirelessModemSide()
    -- peripheral.getNames() returns a table of all directions that have a peripheral
    for _, side in ipairs(peripheral.getNames()) do
        -- Ensure the type is actually a modem before calling 'isWireless'
        if peripheral.getType(side) == "modem" then
            -- Note: Some wired modems might not have 'isWireless',
            -- so we use pcall to be safe.
            local ok, wireless = pcall(peripheral.call, side, "isWireless")
            if ok and wireless then
                return side
            end
        end
    end
    return nil
end

local function getAnyModemSide()
    for _, side in ipairs(peripheral.getNames()) do
        if peripheral.getType(side) == "modem" then
            return side
        end
    end
    return nil
end

local function equipModem()
    local existingSide = getWirelessModemSide() or getAnyModemSide()
    if existingSide then
        return true, existingSide, false
    end

    if not hasTurtle then
        return false, "No modem peripheral attached to this computer."
    end

    local targetSide = "left"
    if isChunkLoader("left") then
        targetSide = "right"
    end

    local found, slot = tlib.selectItem("modem")
    if not found then
        return false, "No wireless modem found in inventory."
    end

    local success, err
    if targetSide == "right" then
        success, err = turtle.equipRight()
    else
        success, err = turtle.equipLeft()
    end

    if success then
        tlib.scanInventory()
        return true, targetSide, true, slot
    else
        return false, err or "Equip operation failed."
    end
end

local function unequipModem(side, swappedSlot)
    if not side or not swappedSlot then return false end

    turtle.select(swappedSlot)
    local success, err
    if side == "right" then
        success, err = turtle.equipRight()
    else
        success, err = turtle.equipLeft()
    end

    if success then
        tlib.scanInventory()
    end
    return success, err
end

local function runRednetTransaction(transactionFunc)
    local success, side, didSwap, swappedSlot = equipModem()
    if not success then
        return false, side
    end

    local wasOpen = rednet.isOpen(side)
    if not wasOpen then
        rednet.open(side)
    end

    local ok, ret = pcall(transactionFunc, side)

    if didSwap then
        rednet.close(side)
        unequipModem(side, swappedSlot)
    elseif not wasOpen then
        rednet.close(side)
    end

    if not ok then
        error(ret)
    end

    return true, ret
end

-- =============================================================================
-- GPS Positional Sync & Compass Calibration
-- =============================================================================

-- Executes raw coordinate locate using the GPS API
local function locateGps()
    if not gps then return nil end
    local success, coords = runRednetTransaction(function(side)
        local cx, cy, cz = gps.locate(2) -- 2 second timeout
        if cx then
            return { x = cx, y = cy, z = cz }
        end
        return nil
    end)
    if success and coords then
        return coords
    end
    return nil
end

-- Syncs relative coordinates directly to physical GPS coordinates (facing remains unchanged)
function tlib.syncGPS()
    local p = locateGps()
    if p then
        state.x = p.x
        state.y = p.y
        state.z = p.z
        tlib.save()
        return true
    end
    return false
end

-- Moves one block and maps vector changes to determine real compass direction
-- Fallback strategy: Turns left or right if direct forward/back coordinates are blocked
function tlib.calibrateGPS()
    print("Connecting to GPS Satellites...")
    local p1 = locateGps()
    if not p1 then
        print("GPS Calibration Failed: No signal.")
        return false, "No GPS signal"
    end

    if not tlib.ensureFuel(1) then
        return false, "No fuel for calibration movement."
    end

    local success = false
    local movedType = nil -- "forward" or "backward"
    local turnOffset = 0  -- 0: none, -1: turned left, 1: turned right

    -- Attempt 1: Direct Forward
    if turtle.forward() then
        success = true
        movedType = "forward"
        turnOffset = 0
        -- Attempt 2: Direct Backward
    elseif turtle.back() then
        success = true
        movedType = "backward"
        turnOffset = 0
    else
        -- Attempt 3: Turn Left first, then try forward/backward
        print("Path blocked. Trying left-side calibration...")
        turtle.turnLeft()
        if turtle.forward() then
            success = true
            movedType = "forward"
            turnOffset = -1
        elseif turtle.back() then
            success = true
            movedType = "backward"
            turnOffset = -1
        else
            -- Restore original heading
            turtle.turnRight()

            -- Attempt 4: Turn Right first, then try forward/backward
            print("Path blocked. Trying right-side calibration...")
            turtle.turnRight()
            if turtle.forward() then
                success = true
                movedType = "forward"
                turnOffset = 1
            elseif turtle.back() then
                success = true
                movedType = "backward"
                turnOffset = 1
            else
                -- Restore original heading
                turtle.turnLeft()
            end
        end
    end

    if not success then
        return false, "GPS Calibration Failed: Path completely obstructed on all horizontal sides."
    end

    -- Capture secondary position
    local p2 = locateGps()

    -- Restores original physical position
    if movedType == "forward" then
        turtle.back()
    elseif movedType == "backward" then
        turtle.forward()
    end

    -- Restores original heading rotation
    if turnOffset == -1 then
        turtle.turnRight()
    elseif turnOffset == 1 then
        turtle.turnLeft()
    end

    if not p2 then
        return false, "GPS Calibration Failed: Signal lost mid-motion."
    end

    -- Calculate axes difference
    local dx = p2.x - p1.x
    local dz = p2.z - p1.z

    local f_world = nil
    if dx == 1 and dz == 0 then
        f_world = 1 -- East
    elseif dx == -1 and dz == 0 then
        f_world = 3 -- West
    elseif dz == 1 and dx == 0 then
        f_world = 2 -- South
    elseif dz == -1 and dx == 0 then
        f_world = 0 -- North
    end

    if not f_world then
        return false, "Inconclusive orientation metrics from GPS."
    end

    -- Calculate temporary turned facing heading
    local f_temp = f_world
    if movedType == "backward" then
        f_temp = (f_world + 2) % 4
    end

    -- Adjust back for any turn offset used during calibration
    local detectedFacing = (f_temp - turnOffset) % 4

    state.x = p1.x
    state.y = p1.y
    state.z = p1.z
    state.facing = detectedFacing
    tlib.save()
    print(string.format("GPS Calibrated! Pos: (%d,%d,%d) Facing: %d", state.x, state.y, state.z, state.facing))
    return true
end

-- =============================================================================
-- Rednet Status Communications & Mailbox Client
-- =============================================================================
local requireNlibOk, nlibOrErr = pcall(require, "nlib")
local nlib = requireNlibOk and nlibOrErr or nil
local reportNlibIssue = rawget(_G, "printError") or print

local function bindNlibMethod(methodName)
    if nlib and type(nlib[methodName]) == "function" then
        tlib[methodName] = function(...)
            return nlib[methodName](...)
        end
        return
    end

    tlib[methodName] = function()
        if nlib then
            return false, "nlib method unavailable: " .. methodName
        end
        return false, "nlib unavailable: " .. tostring(nlibOrErr)
    end
end

if nlib then
    if type(nlib.setTransactionRunner) == "function" then
        nlib.setTransactionRunner(runRednetTransaction)
    end

    if type(nlib.setStatusProvider) == "function" then
        nlib.setStatusProvider(function(statusText, isError, extra)
            local payload = {
                id = os.getComputerID(),
                label = os.getComputerLabel() or "Turtle",
                x = state.x,
                y = state.y,
                z = state.z,
                facing = state.facing,
                fuel = turtle.getFuelLevel(),
                status = statusText,
                is_error = isError or false
            }

            if type(extra) == "table" then
                for k, v in pairs(extra) do
                    payload[k] = v
                end
            end

            return payload
        end)
    end
else
    reportNlibIssue("nlib not installed; status and mailbox features are disabled.")
end

bindNlibMethod("broadcastStatus")
bindNlibMethod("sendStatus")
bindNlibMethod("queueStatus")
bindNlibMethod("sendStatusViaMailbox")
bindNlibMethod("listenStatus")
bindNlibMethod("checkOfflineMessages")
bindNlibMethod("pingMailbox")
bindNlibMethod("ackMailboxMessage")

-- =============================================================================
-- Initialize Method (Respects Single-Loader Lock & Calibrates GPS)
-- =============================================================================

function tlib.initialize()
    print("Initializing Turtle Systems...")
    tlib.scanInventory()

    local leftHasLoader = isChunkLoader("left")
    local rightHasLoader = isChunkLoader("right")

    -- Check if either side already has a chunk loader active
    if leftHasLoader or rightHasLoader then
        print("Chunk loader already locked in slot: " .. (leftHasLoader and "left" or "right"))
    else
        -- Only proceed to locate and equip if neither side is currently upgraded
        local loaderSlot = nil
        for slot = 1, 16 do
            local item = state.inventory[slot]
            if item and (item.name:find("chunk") or item.name:find("loader")) then
                loaderSlot = slot
                break
            end
        end

        if loaderSlot then
            print("Detected chunk loader in inventory slot " .. loaderSlot .. ". Equipping to right slot...")
            turtle.select(loaderSlot)
            local success, err = turtle.equipRight()
            if success then
                print("Chunk loader successfully locked in place.")
            else
                printError("Failed to mount chunk loader: " .. tostring(err))
            end
        else
            print("No chunk loader found in inventory.")
        end
    end

    -- Run automatic GPS calibration on startup
    local gpsSuccess, gpsErr = tlib.calibrateGPS()
    state.gpsAvailable = gpsSuccess
    tlib.save()
    if not gpsSuccess then
        print("GPS Unavailable. Restored local coordinate tracking: " .. tostring(gpsErr))
    end

    local ok, err = tlib.broadcastStatus("System Initialized")
    if ok then
        print("Initialization broadcast completed successfully.")
    else
        print("Offline/Broadcast skipped: " .. tostring(err))
    end
end

-- =============================================================================
-- Fuel Management
-- =============================================================================

function tlib.ensureFuel(needed)
    if turtle.getFuelLevel() == "unlimited" then return true end
    if turtle.getFuelLevel() >= needed then return true end

    local missing = needed - turtle.getFuelLevel()
    local ok, err = tlib.refuel({ needed = missing })
    if ok and turtle.getFuelLevel() >= needed then
        return true
    end

    -- SYSTEM CRITICAL ERROR: OUT OF FUEL (Broadcasting over Rednet with is_error=true)
    local errMsg = string.format("ERROR: Out of fuel! Needed: %d, Current: %s, Refuel: %s", needed,
        tostring(turtle.getFuelLevel()), tostring(err))
    printError("\n" .. errMsg)
    tlib.broadcastStatus(errMsg, true)

    return false
end

-- =============================================================================
-- Wrapped Movement Engine (Traps and Dispatches Obstruction Errors)
-- =============================================================================

local function handleObstructedMovement(detectFunc, digFunc)
    if detectFunc() then
        digFunc()
    else
        sleep(0.5)
    end
end

function tlib.forward()
    if not tlib.ensureFuel(1) then return false, "No fuel" end

    local success, err = turtle.forward()
    local retries = 0
    while not success and retries < 5 do
        if err == "Movement obstructed" then
            handleObstructedMovement(turtle.detect, turtle.dig)
            success, err = turtle.forward()
        else
            return false, err
        end
        retries = retries + 1
    end

    if success then
        state.x = state.x + vectors[state.facing].x
        state.z = state.z + vectors[state.facing].z
        tlib.save()
    else
        -- SYSTEM CRITICAL ERROR: STUCK/OBSTRUCTED (Broadcasts error over Rednet)
        local errMsg = string.format("ERROR: Forward failed at (%d,%d,%d). Reason: %s", state.x, state.y, state.z,
            tostring(err))
        printError("\n" .. errMsg)
        tlib.broadcastStatus(errMsg, true)
    end
    return success, err
end

function tlib.back()
    if not tlib.ensureFuel(1) then return false, "No fuel" end

    local success, err = turtle.back()
    local retries = 0
    while not success and retries < 5 do
        if err == "Movement obstructed" then
            sleep(0.5)
            success, err = turtle.back()
        else
            return false, err
        end
        retries = retries + 1
    end

    if success then
        state.x = state.x - vectors[state.facing].x
        state.z = state.z - vectors[state.facing].z
        tlib.save()
    else
        local errMsg = string.format("ERROR: Back failed at (%d,%d,%d). Reason: %s", state.x, state.y, state.z,
            tostring(err))
        printError("\n" .. errMsg)
        tlib.broadcastStatus(errMsg, true)
    end
    return success, err
end

function tlib.up()
    if not tlib.ensureFuel(1) then return false, "No fuel" end

    local success, err = turtle.up()
    local retries = 0
    while not success and retries < 5 do
        if err == "Movement obstructed" then
            handleObstructedMovement(turtle.detectUp, turtle.digUp)
            success, err = turtle.up()
        else
            return false, err
        end
        retries = retries + 1
    end

    if success then
        state.y = state.y + 1
        tlib.save()
    else
        local errMsg = string.format("ERROR: Up failed at (%d,%d,%d). Reason: %s", state.x, state.y, state.z,
            tostring(err))
        printError("\n" .. errMsg)
        tlib.broadcastStatus(errMsg, true)
    end
    return success, err
end

function tlib.down()
    if not tlib.ensureFuel(1) then return false, "No fuel" end

    local success, err = turtle.down()
    local retries = 0
    while not success and retries < 5 do
        if err == "Movement obstructed" then
            handleObstructedMovement(turtle.detectDown, turtle.digDown)
            success, err = turtle.down()
        else
            return false, err
        end
        retries = retries + 1
    end

    if success then
        state.y = state.y - 1
        tlib.save()
    else
        local errMsg = string.format("ERROR: Down failed at (%d,%d,%d). Reason: %s", state.x, state.y, state.z,
            tostring(err))
        printError("\n" .. errMsg)
        tlib.broadcastStatus(errMsg, true)
    end
    return success, err
end

function tlib.turnLeft()
    if turtle.turnLeft() then
        state.facing = (state.facing - 1) % 4
        tlib.save()
        return true
    end
    return false
end

function tlib.turnRight()
    if turtle.turnRight() then
        state.facing = (state.facing + 1) % 4
        tlib.save()
        return true
    end
    return false
end

-- =============================================================================
-- Safe Execution Wrapper
-- =============================================================================

-- Runs a client program function safely. Catches any crashes, dispatches them
-- over Rednet with an error flag, and then raises the exception.
function tlib.execute(programFunc, ...)
    local success, err = pcall(programFunc, ...)

    if not success then
        local crashMsg = "CRITICAL PROGRAM CRASH: " .. tostring(err)
        printError("\n" .. crashMsg)

        -- Broadcast the crash message globally over Rednet with is_error = true
        tlib.broadcastStatus(crashMsg, true)

        -- Re-throw the error to exit the script cleanly
        error(err, 0)
    end

    return true
end

-- =============================================================================
-- Interactive Terminal UI Window Engine
-- =============================================================================

local function drawDashboard(win, w, h, programs, selectedIndex)
    win.setVisible(false) -- Hide while drawing to prevent flicker/ghosting
    win.clear()           -- Full clear
    win.setCursorPos(1, 1)

    -- Header: Label Left, Fuel Right
    win.setBackgroundColor(colors.blue)
    win.setTextColor(colors.white)
    win.clearLine()
    local name = os.getComputerLabel() or "ID: " .. os.getComputerID()
    local fuel = string.format("Fuel: %s/%s", tostring(turtle.getFuelLevel()), tostring(turtle.getFuelLimit()))
    win.setCursorPos(1, 1)
    win.write(name)
    win.setCursorPos(w - #fuel + 1, 1)
    win.write(fuel)

    -- Row 2: Hardware Status (Ldr, Mod, GPS)
    win.setBackgroundColor(colors.black)
    win.setCursorPos(1, 2)
    win.write("Chunk Loader:")
    win.setTextColor(state.hasChunkLoader and colors.green or colors.red)
    win.write(state.hasChunkLoader and "ON " or "OFF")

    win.setTextColor(colors.white)
    win.write(" Wireless:")
    win.setTextColor(state.hasWireless and colors.green or colors.red)
    win.write(state.hasWireless and "ON " or "OFF")

    -- Separator
    win.setTextColor(colors.gray)
    win.setCursorPos(1, 3)
    win.write(string.rep("-", w))

    -- Programs List
    win.setTextColor(colors.lightBlue)
    win.setCursorPos(2, 4)
    win.write("Programs:")
    
    local listStartY = 8
    local maxDisplayProgs = 3

    if #programs == 0 then
        win.setTextColor(colors.red)
        win.setCursorPos(4, listStartY)
        win.write("No scripts in /programs/")
    else
        local startIdx = 1
        if selectedIndex > maxDisplayProgs then
            startIdx = selectedIndex - maxDisplayProgs + 1
        end
        local endIdx = math.min(startIdx + maxDisplayProgs - 1, #programs)

        for i = startIdx, endIdx do
            local lineY = listStartY + (i - startIdx)
            win.setCursorPos(2, lineY)
            if i == selectedIndex then
                win.setBackgroundColor(colors.lightGray)
                win.setTextColor(colors.black)
                win.write(" > " .. programs[i] .. " ")
                win.setBackgroundColor(colors.black)
            else
                win.setTextColor(colors.gray)
                win.write("   " .. programs[i])
            end
        end
    end

    win.setTextColor(colors.gray)
    win.setCursorPos(1, 11)
    win.write(string.rep("-", w))

    -- Footer (two-row action layout)
    local firstFooterRow = h - 1

    win.setTextColor(colors.yellow)
    win.setCursorPos(1, firstFooterRow)
    win.clearLine()
    local runAction = "[Enter] Run Selected Program"
    local runX = math.max(1, math.floor((w - #runAction) / 2) + 1)
    win.setCursorPos(runX, firstFooterRow)
    win.write(runAction)

    win.setCursorPos(1, h)
    win.clearLine()
    win.write("[U] Update  [T] Terminal  [Q] Quit")

    win.setVisible(true) -- Show after drawing is finished
end

-- Scans peripherals and updates the state variables
function tlib.refreshHardwareState()
    -- Give the game engine 0.1s to finish peripheral registration after inventory change
    sleep(0.1)

    state.hasWireless = false
    state.hasChunkLoader = false

    for _, side in ipairs(peripheral.getNames()) do
        local pType = peripheral.getType(side)
        if pType == "modem" then
            local ok, val = pcall(peripheral.call, side, "isWireless")
            if ok and val then state.hasWireless = true end
        elseif pType and (pType:find("chunk") or pType:find("loader")) then
            state.hasChunkLoader = true
        end
    end

    if not state.hasWireless or not state.hasChunkLoader then
        tlib.scanInventory()

        for _, item in pairs(state.inventory) do
            if item and item.name then
                if not state.hasWireless and item.name:find("modem") then
                    state.hasWireless = true
                end
                if not state.hasChunkLoader and (item.name:find("chunk") or item.name:find("loader")) then
                    state.hasChunkLoader = true
                end
            end
        end
    end

    tlib.save()
end

function tlib.showUI()
    local parent = term.current()
    local w, h = parent.getSize()

    local dashboardWin = window.create(parent, 1, 1, w, h, true)
    local terminalWin = window.create(parent, 1, 1, w, h, false)

    local selectedIndex = 1
    local mode = "dashboard"

    -- Initial state sync
    tlib.refreshHardwareState()

    local function redraw()
        if mode == "dashboard" then
            drawDashboard(dashboardWin, w, h, programs, selectedIndex)
        end
    end

    local function runUpdates()
        term.redirect(parent)
        parent.clear()
        parent.setCursorPos(1, 1)
        print("Running update sequence...\n")

        local sh = shell or _G.shell
        if not sh then
            printError("Shell is unavailable. Cannot run pull updates.")
            print("\nPress any key to return to Control...")
            os.pullEvent("key")
            term.redirect(dashboardWin)
            return
        end

        local targets = {}

        for i = 1, #dependencies do
            table.insert(targets, dependencies[i])
        end

        for i = 1, #programs do
            table.insert(targets, programs[i])
        end

        local okCount = 0
        local failCount = 0

        for i = 1, #targets do
            local target = targets[i]
            print(string.format("[%d/%d] pull %s", i, #targets, target))
            local ok, pullResult = pcall(function()
                return sh.run("pull", target)
            end)

            if ok and pullResult then
                okCount = okCount + 1
                print("  OK")
            else
                failCount = failCount + 1
                local reason = ok and "pull returned false" or tostring(pullResult)
                printError("  Failed: " .. reason)
            end
        end

        print(string.format("\nUpdate complete. Success: %d  Failed: %d", okCount, failCount))
        print("Rebooting to apply updates...")
        sleep(0.75)
        os.reboot()
    end

    redraw()

    -- Main Event Handler Loop
    while true do
        -- Use os.pullEvent to catch both keyboard and inventory events
        local eventData = { os.pullEvent() }
        local event = eventData[1]

        local isRescanning = false

        if event == "turtle_inventory" or event == "peripheral" or event == "peripheral_detach" then
            if not isRescanning then
                isRescanning = true
                tlib.refreshHardwareState()
                if mode == "dashboard" then redraw() end
                isRescanning = false
            end
        end

        if mode == "dashboard" then
            if event == "key" then
                local key = eventData[2]
                if key == keys.up then
                    if selectedIndex > 1 then
                        selectedIndex = selectedIndex - 1
                        redraw()
                    end
                elseif key == keys.down then
                    if selectedIndex < #programs then
                        selectedIndex = selectedIndex + 1
                        redraw()
                    end
                elseif key == keys.enter then
                    if #programs > 0 then
                        term.redirect(parent)
                        parent.clear()
                        parent.setCursorPos(1, 1)
                        print("Launching " .. programs[selectedIndex] .. "...\n")

                        local success, err = pcall(function()
                            local sh = shell or _G.shell
                            if sh then
                                sh.run(programs[selectedIndex])
                            else
                                os.run({}, programs[selectedIndex])
                            end
                        end)

                        if not success then
                            printError("Runtime error: " .. tostring(err))
                        end

                        print("\nPress any key to return to Control...")
                        os.pullEvent("key")

                        term.redirect(dashboardWin)
                        redraw()
                    end
                elseif key == keys.u then
                    runUpdates()
                    redraw()
                elseif key == keys.t then
                    mode = "terminal"
                    redraw()
                elseif key == keys.q then
                    break
                end
            end
        elseif mode == "terminal" then
            dashboardWin.setVisible(false)
            terminalWin.setVisible(true)

            term.redirect(terminalWin)
            terminalWin.clear()
            terminalWin.setCursorPos(1, 1)

            terminalWin.setTextColor(colors.green)
            print("--- SANDBOX TERMINAL ---")
            terminalWin.setTextColor(colors.white)
            print("Type 'exit' to return to Dashboard.")
            print("Usage: Call 'h' or 'tlib' methods.")
            print("Example: h.forward() or h.scanInventory()")
            print("")

            while true do
                write("adhoc> ")
                local cmd = read()
                if cmd == "exit" then break end

                if cmd and cmd ~= "" then
                    local sandboxEnv = setmetatable({ tlib = tlib, h = tlib }, { __index = _G })
                    local fn, err = load(cmd, "adhoc_sandbox", "t", sandboxEnv)

                    if fn then
                        local runSuccess, runErr = pcall(fn)
                        if not runSuccess then
                            terminalWin.setTextColor(colors.red)
                            print("Error: " .. tostring(runErr))
                            terminalWin.setTextColor(colors.white)
                        end
                    else
                        terminalWin.setTextColor(colors.red)
                        print("Syntax: " .. tostring(err))
                        terminalWin.setTextColor(colors.white)
                    end
                end
            end

            mode = "dashboard"
            terminalWin.setVisible(false)
            dashboardWin.setVisible(true)
            term.redirect(dashboardWin)
            redraw()
        end
    end

    term.redirect(parent)
    parent.clear()
    parent.setCursorPos(1, 1)
end

-- =============================================================================
-- CLI Entry Point
-- =============================================================================

local args = { ... }
if args[1] == "install_digital_mining_manager" or args[1] == "-idmm" then
    local startupContent = [[local ok, err = pcall(function()
    local sh = shell or _G.shell
    if sh then
        sh.run("digital_mining_manager")
    else
        os.run({}, "digital_mining_manager")
    end
end)

if not ok then
    printError("Failed to launch digital_mining_manager: " .. tostring(err))
end]]

    local f = fs.open("startup.lua", "w")
    if f then
        f.write(startupContent)
        f.close()
        print("startup.lua installed for digital_mining_manager.")
    else
        printError("Failed to write startup.lua.")
    end
elseif args[1] == "install" or args[1] == "-i" then
    local startupContent = [[local ok, tlib = pcall(require, "tlib")
if ok then
    tlib.startup()
else
    printError("Failed to load tlib: " .. tostring(tlib))
end]]
    local f = fs.open("startup.lua", "w")
    if f then
        f.write(startupContent)
        f.close()
        print("startup.lua installed. tlib will run automatically on next boot.")
    else
        printError("Failed to write startup.lua.")
    end
end

return tlib
