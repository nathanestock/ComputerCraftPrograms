-- tlib_mailbox.lua
-- CLI utility for turtle mailbox/status operations via tlib.

local ok, tlibOrErr = pcall(require, "tlib")
if not ok then
    printError("Failed to load tlib: " .. tostring(tlibOrErr))
    return
end

local tlib = tlibOrErr

local function joinFrom(args, startIndex)
    local parts = {}
    for i = startIndex, #args do
        parts[#parts + 1] = tostring(args[i])
    end
    return table.concat(parts, " ")
end

local function printUsage()
    print("tlib_mailbox usage:")
    print("  tlib_mailbox broadcast <status text>")
    print("  tlib_mailbox broadcast_error <status text>")
    print("  tlib_mailbox send <targetId> <status text>")
    print("  tlib_mailbox send_error <targetId> <status text>")
    print("  tlib_mailbox fetch [mailboxServerId]")
end

local function printMessages(messages)
    if type(messages) ~= "table" or #messages == 0 then
        print("No offline messages.")
        return
    end

    print("Offline messages:")
    for i = 1, #messages do
        local msg = messages[i]
        if type(msg) == "table" then
            local from = tostring(msg.from or msg.sender or "unknown")
            local body = tostring(msg.message or msg.text or textutils.serialize(msg))
            print(string.format("  [%d] from=%s msg=%s", i, from, body))
        else
            print(string.format("  [%d] %s", i, tostring(msg)))
        end
    end
end

local args = { ... }
local cmd = args[1]

if not cmd then
    printUsage()
    return
end

if cmd == "broadcast" then
    local statusText = joinFrom(args, 2)
    if statusText == "" then
        printError("Status text is required.")
        return
    end

    local success, ret = tlib.broadcastStatus(statusText, false)
    if success then
        print("Status broadcast sent.")
    else
        printError("Broadcast failed: " .. tostring(ret))
    end
    return
end

if cmd == "broadcast_error" then
    local statusText = joinFrom(args, 2)
    if statusText == "" then
        printError("Status text is required.")
        return
    end

    local success, ret = tlib.broadcastStatus(statusText, true)
    if success then
        print("Error status broadcast sent.")
    else
        printError("Broadcast failed: " .. tostring(ret))
    end
    return
end

if cmd == "send" or cmd == "send_error" then
    local targetId = tonumber(args[2])
    if not targetId then
        printError("targetId must be a number.")
        return
    end

    local statusText = joinFrom(args, 3)
    if statusText == "" then
        printError("Status text is required.")
        return
    end

    local isError = (cmd == "send_error")
    local success, ret = tlib.sendStatus(targetId, statusText, isError)
    if success then
        print("Status message sent to " .. tostring(targetId) .. ".")
    else
        printError("Send failed: " .. tostring(ret))
    end
    return
end

if cmd == "fetch" then
    local mailboxServerID = tonumber(args[2])
    local success, messages = tlib.checkOfflineMessages(mailboxServerID)
    if success then
        printMessages(messages)
    else
        printError("Fetch failed: " .. tostring(messages))
    end
    return
end

printError("Unknown command: " .. tostring(cmd))
printUsage()
