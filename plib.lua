local lib = {}
local configPath = "peripheral_config.lua"
local mapping = {}
local sides = { "top", "bottom", "left", "right", "front", "back" }

-- Define extension methods for specific peripheral types
lib.extensions = {
    redstone_relay = {
        setAllSides = function(peripheral, state)
            for _, side in ipairs(sides) do
                if peripheral.setOutput then
                    peripheral.setOutput(side, state)
                end
            end
        end,
        getAnySideInput = function(peripheral)
            for _, side in ipairs(sides) do
                if peripheral.getInput and peripheral.getInput(side) then
                    return true
                end
            end
            return false
        end,
    }
    -- Add more types here as needed
}

if fs.exists(configPath) then
    local file = fs.open(configPath, "r")
    mapping = textutils.unserialize(file.readAll()) or {}
    file.close()
end

local function saveConfig()
    local file = fs.open(configPath, "w")
    file.write(textutils.serialize(mapping))
    file.close()
end

local function getNum(name) return tonumber(name:match("%d+$")) end

-- Helper to inject extensions into the peripheral object
local function applyExtensions(p, pType)
    if lib.extensions[pType] then
        for name, func in pairs(lib.extensions[pType]) do
            p[name] = function(...) return func(p, ...) end
        end
    end
    return p
end

function lib.wrap(configName, peripheralType)
    local p = nil

    if mapping[configName] then
        local name = mapping[configName]
        if peripheral.getType(name) == peripheralType then
            p = peripheral.wrap(name)
        end
    end

    if not p then
        local available = {}
        for _, name in ipairs(peripheral.getNames()) do
            if peripheral.getType(name) == peripheralType then
                local isTaken = false
                for _, assigned in pairs(mapping) do if assigned == name then isTaken = true end end
                if not isTaken then table.insert(available, name) end
            end
        end

        if #available == 0 then
            error("No available " .. peripheralType .. " found for: " .. configName)
        elseif #available == 1 then
            mapping[configName] = available[1]
            saveConfig()
            p = peripheral.wrap(available[1])
        else
            -- Sort and selection logic...
            table.sort(available, function(a, b)
                local numA, numB = getNum(a), getNum(b)
                if numA and numB then return numA < numB end
                if numA then return true end
                if numB then return false end
                return a < b
            end)

            print("Select " .. peripheralType .. " for " .. configName .. ":")
            for _, name in ipairs(available) do
                print((getNum(name) or "?") .. ": " .. name)
            end

            while not p do
                write("Choice > ")
                local input = read()
                local inputNum = tonumber(input)
                for _, name in ipairs(available) do
                    if (inputNum and getNum(name) == inputNum) or (name == input) then
                        mapping[configName] = name
                        saveConfig()
                        p = peripheral.wrap(name)
                    end
                end
            end
        end
    end

    return applyExtensions(p, peripheralType)
end

return lib
