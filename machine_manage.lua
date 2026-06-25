local CONFIG_FILE = "config.json"

local defaultSettings = {
    setupName = "Ethene Generator",
    themeColor = "purple",
    meBridge = "me_bridge_0",
    monitor = "left",
    machines = {
        { name = "Crusher",                peripheral = "basicCrushingFactory_0",    strategy = "energy_usage" },
        { name = "Electrolytic Separator", peripheral = "electrolyticSeparator_0",      strategy = "energy_usage" },
        { name = "Reaction Chamber",       peripheral = "pressurizedReactionChamber_0", strategy = "energy_usage" },
        { name = "Gas Burner",       peripheral = "gasBurningGenerator_0", strategy = "gas_generator" }
    },
    trackedItems = {
        { name = "Ethene",    id = "mekanism:ethene",    type = "chemical", pinned = true },
        { name = "Bio Fuel",  id = "mekanism:bio_fuel",  type = "item",     pinned = false },
        { name = "Substrate", id = "mekanism:substrate", type = "item",     pinned = false },
        { name = "Oxygen",    id = "mekanism:oxygen",    type = "chemical", pinned = false },
    }
}

-- Load Config
if not fs.exists(CONFIG_FILE) then
    local f = fs.open(CONFIG_FILE, "w")
    f.write(textutils.serialize(defaultSettings))
    f.close()
end
local config = textutils.unserialize(fs.open(CONFIG_FILE, "r").readAll())

-- State
local state = { bridgeOnline = false, machines = {}, resources = {} }
local bridge = peripheral.wrap(config.meBridge)
local mon = peripheral.wrap(config.monitor)
local machineHandles = {}
for i, m in ipairs(config.machines) do machineHandles[i] = peripheral.wrap(m.peripheral) end

local function pollBridge()
    while true do
        if bridge then
            local success, _ = pcall(function() bridge.getEnergyUsage() end)
            if not success then
                state.bridgeOnline = false
            else
                state.bridgeOnline = true

                -- Check if any cpus are crafting
                local ok, cpus = pcall(bridge.getCraftingCPUs)
                if ok and type(cpus) == "table" then
                    local working = false
                    for _, cpu in pairs(cpus) do
                        if cpu.isBusy then
                            working = true
                            break
                        end
                    end
                    state.isCrafting = working
                else
                    state.isCrafting = false
                end

                local anyMissing = false
                for i, res in ipairs(config.trackedItems) do
                    -- Wrap each API call in pcall to handle unexpected peripheral errors
                    local status, result = pcall(function()
                        if res.type == "item" then
                            return bridge.getItem({ name = res.id })
                        elseif res.type == "fluid" then
                            return bridge.getFluid({ name = res.id })
                        elseif res.type == "chemical" then
                            return bridge.getChemical({ name = res.id })
                        end
                    end)

                    if status and result then
                        state.resources[i] = { name = res.name, amount = result.count or 0 }
                    else
                        state.resources[i] = { name = res.name, amount = 0 }
                    end

                    -- Check can craft
                    if res.pinned then
                        local ok, canCraft = pcall(function() return bridge.isCraftable({ name = res.id }) end)
                        if ok and not canCraft then
                            anyMissing = true
                        end
                    end
                end

                state.missingIngredients = anyMissing
            end
        else
            state.bridgeOnline = false
            bridge = peripheral.wrap(config.meBridge)
        end
        sleep(2)
    end
end

-- Machine on/off state detection
local machineStrategies = {
    energy_usage = function(p)
        if p.getEnergyUsage then
            local ok, usage = pcall(p.getEnergyUsage)
            return ok and usage > 0
        end
        return false
    end,
    gas_generator = function(p)
        if p.getBurnRate then
            local ok, rate = pcall(p.getBurnRate)
            return ok and rate > 0
        end
        return false
    end
}

local function pollMachines()
    while true do
        for i, m in ipairs(config.machines) do
            local p = machineHandles[i]
            local active = false

            if p then
                -- Determine strategy name (default to energy_usage)
                local strategyName = m.strategy or "energy_usage"
                local strategy = machineStrategies[strategyName]

                -- Execute strategy if it exists
                if strategy then
                    active = strategy(p)
                else
                    -- Fallback/Error handling if an invalid strategy is named
                    active = false
                end
            end

            state.machines[i] = active
        end
        sleep(0.5)
    end
end

local function renderUI()
    local page = 1
    local itemsPerPage = 4
    local timer = os.startTimer(5)
    local theme = colors[config.themeColor] or colors.blue

    local function drawRow(y, leftText, rightText, bgColor, textColor, rightTextColor)
        mon.setCursorPos(1, y)
        mon.setBackgroundColor(bgColor)
        mon.setTextColor(textColor)
        local width = mon.getSize()
        local padding = width - #leftText - #rightText
        mon.write(leftText .. string.rep(" ", math.max(0, padding - 1)))
        if rightTextColor then mon.setTextColor(rightTextColor) end
        mon.write(rightText)
        mon.setBackgroundColor(colors.black)
    end

    local function formatAmt(res, itemCfg)
        if itemCfg.type == "item" then
            return tostring(res.amount)
        else
            return string.format("%.3f", res.amount / 1000):gsub("0+$", ""):gsub("%.$", "") .. " B"
        end
    end

    while true do
        mon.setTextScale(1)
        mon.clear()

        local w = mon.getSize()

        -- Header
        mon.setCursorPos(1, 1)
        mon.setBackgroundColor(theme)
        mon.setTextColor(colors.white)
        mon.write(config.setupName .. string.rep(" ", math.max(0, w - #config.setupName)))
        mon.setBackgroundColor(colors.black)

        local statusText = " STANDBY "
        local statusColor = colors.blue

        if state.isCrafting then
            statusText = " WORKING "
            statusColor = colors.green
        elseif state.missingIngredients then
            statusText = " MISSING INGREDIENTS "
            statusColor = colors.red
        end

        mon.setCursorPos(1, 2)
        mon.setBackgroundColor(statusColor)
        mon.setTextColor(colors.white)
        mon.write(statusText .. string.rep(" ", math.max(0, w - #statusText)))

        -- Row 3 remains black (negative space / bottom padding)
        mon.setCursorPos(1, 3)
        mon.setBackgroundColor(colors.black)

        if not state.bridgeOnline then
            mon.setCursorPos(1, 4); mon.setTextColor(colors.red); mon.write("BRIDGE OFFLINE")
        else
            -- 1. Organize Data
            local pinned = {}
            local normal = {}
            for i, res in ipairs(state.resources) do
                local itemCfg = config.trackedItems[i]
                local data = { res = res, cfg = itemCfg }
                if itemCfg.pinned then table.insert(pinned, data) else table.insert(normal, data) end
            end

            -- 2. Render Pinned
            local currentY = 4
            for _, item in ipairs(pinned) do
                local amtStr = formatAmt(item.res, item.cfg)
                mon.setCursorPos(1, currentY)
                mon.setTextColor(colors.yellow)
                mon.write(item.res.name)
                mon.setCursorPos(w - #amtStr + 1, currentY)
                mon.write(amtStr)
                currentY = currentY + 2
            end

            -- 3. Render Machines
            drawRow(currentY, " Machines", "", colors.lightGray, colors.black)
            currentY = currentY + 1
            for i, m in ipairs(config.machines) do
                local y = currentY + (i * 2) - 1
                local isOn = state.machines[i]
                local statusText = isOn and " ON " or " OFF "
                mon.setCursorPos(1, y); mon.setTextColor(colors.white); mon.write(" " .. m.name)
                mon.setCursorPos(w - #statusText + 1, y)
                mon.setBackgroundColor(isOn and colors.green or colors.red)
                mon.write(statusText); mon.setBackgroundColor(colors.black)
            end

            -- 4. Render Inventory
            local startY = currentY + (#config.machines * 2) + 1
            drawRow(startY, " Inventory", "", colors.lightGray, colors.black)

            local totalPages = math.max(1, math.ceil(#normal / itemsPerPage))
            local startIdx = ((page - 1) * itemsPerPage) + 1
            local endIdx = math.min(startIdx + itemsPerPage - 1, #normal)

            for i = startIdx, endIdx do
                local item = normal[i]
                local y = startY + ((i - startIdx + 1) * 2)
                local amtStr = formatAmt(item.res, item.cfg)

                mon.setCursorPos(1, y); mon.setTextColor(colors.white); mon.write(" " .. item.res.name)
                mon.setCursorPos(w - #amtStr + 1, y); mon.write(amtStr .. " ")
            end
        end

        local event, p1 = os.pullEvent()
        if event == "timer" and p1 == timer then
            local _, normalCount = 0, 0
            for _, v in ipairs(config.trackedItems) do if not v.pinned then normalCount = normalCount + 1 end end
            page = (page % (math.max(1, math.ceil(normalCount / itemsPerPage))) + 1)
            timer = os.startTimer(5)
        end
    end
end


parallel.waitForAny(pollBridge, pollMachines, renderUI)
