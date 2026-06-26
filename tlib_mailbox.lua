-- tlib_mailbox.lua
-- Mailbox server + CLI utility for turtle status relay/queue operations.

local ok, tlibOrErr = pcall(require, "tlib")
if not ok then
    printError("Failed to load tlib: " .. tostring(tlibOrErr))
    return
end

local tlib = tlibOrErr

local function runServerLoop()
    local success, err = tlib.runMailboxServer()
    if not success then
        printError("Mailbox server exited: " .. tostring(err))
    end
end

local function joinFrom(args, startIndex)
    local parts = {}
    for i = startIndex, #args do
        parts[#parts + 1] = tostring(args[i])
    end
    return table.concat(parts, " ")
end

local function printUsage()
    print("tlib_mailbox usage:")
    print("  tlib_mailbox                 (run mailbox server)")
    print("  tlib_mailbox server          (run mailbox server)")
    print("  tlib_mailbox ping [serverId]")
    print("  tlib_mailbox broadcast <status text>")
    print("  tlib_mailbox broadcast_error <status text>")
    print("  tlib_mailbox send <targetId> <status text> [serverId]")
    print("  tlib_mailbox send_error <targetId> <status text> [serverId]")
    print("  tlib_mailbox send_direct <targetId> <status text>")
    print("  tlib_mailbox send_direct_error <targetId> <status text>")
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
    runServerLoop()
    return
end

if cmd == "server" then
    runServerLoop()
    return
end

if cmd == "ping" then
    local mailboxServerID = tonumber(args[2])
    local success, reply = tlib.pingMailbox(mailboxServerID)
    if success then
        print("Mailbox server reachable: " .. tostring(reply and reply.server_id or "unknown"))
    else
        printError("Ping failed: " .. tostring(reply))
    end
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

    local mailboxServerID = nil
    local messageEndIndex = #args
    if #args >= 4 then
        local maybeServer = tonumber(args[#args])
        if maybeServer then
            mailboxServerID = maybeServer
            messageEndIndex = #args - 1
        end
    end

    local parts = {}
    for i = 3, messageEndIndex do
        parts[#parts + 1] = tostring(args[i])
    end
    local statusText = table.concat(parts, " ")

    if statusText == "" then
        printError("Status text is required.")
        return
    end

    local isError = (cmd == "send_error")
    local success, ret = tlib.sendStatusViaMailbox(targetId, statusText, isError, mailboxServerID)
    if success then
        if type(ret) == "table" and ret.delivered then
            print("Status delivered directly to " .. tostring(targetId) .. ".")
        else
            print("Status queued for " .. tostring(targetId) .. ".")
        end
    else
        printError("Send failed: " .. tostring(ret))
    end
    return
end

if cmd == "send_direct" or cmd == "send_direct_error" then
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

    local isError = (cmd == "send_direct_error")
    local success, ret = tlib.sendStatus(targetId, statusText, isError)
    if success then
        print("Direct status message sent to " .. tostring(targetId) .. ".")
    else
        printError("Direct send failed: " .. tostring(ret))
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
