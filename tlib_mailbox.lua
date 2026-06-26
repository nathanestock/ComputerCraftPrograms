-- tlib_mailbox.lua
-- Mailbox server + CLI utility for turtle status relay/queue operations.

local ok, tlibOrErr = pcall(require, "tlib")
if not ok then
    print("Failed to load tlib: " .. tostring(tlibOrErr))
    return
end

local tlib = tlibOrErr

local plib = require("plib")
local fs = rawget(_G, "fs")
local textutils = rawget(_G, "textutils")
local peripheral = rawget(_G, "peripheral")
local rednet = rawget(_G, "rednet")
local colors = rawget(_G, "colors") or {}
local printError = rawget(_G, "printError") or function(msg)
    print(tostring(msg))
end
local getComputerIDFn = (os and rawget(os, "getComputerID")) or rawget(_G, "getComputerID")
local epochFn = os and rawget(os, "epoch")

local function currentComputerID()
    if type(getComputerIDFn) == "function" then
        return getComputerIDFn()
    end
    return -1
end

local MAILBOX_PROTOCOL = "turtle_mailbox"
local MAILBOX_STORE_FILE = "turtle_mailbox_store.json"

local function loadMailboxStore()
    if not fs.exists(MAILBOX_STORE_FILE) then
        return {}
    end

    local f = fs.open(MAILBOX_STORE_FILE, "r")
    if not f then
        return {}
    end

    local raw = f.readAll()
    f.close()

    if not raw or raw == "" then
        return {}
    end

    local parsed = textutils.unserialize(raw)
    if type(parsed) ~= "table" then
        return {}
    end

    return parsed
end

local function saveMailboxStore(store)
    local f = fs.open(MAILBOX_STORE_FILE, "w")
    if not f then
        return false, "Failed to open mailbox store for writing"
    end

    f.write(textutils.serialize(store or {}))
    f.close()
    return true
end

local function appendMailboxMessage(store, targetID, entry)
    local key = tostring(targetID)
    if type(store[key]) ~= "table" then
        store[key] = {}
    end
    table.insert(store[key], entry)
end

local function getTotalQueued(store)
    local count = 0
    for _, messages in pairs(store) do
        if type(messages) == "table" then
            count = count + #messages
        end
    end
    return count
end

local function ensureRednetOpen()
    for _, side in ipairs(peripheral.getNames()) do
        if peripheral.getType(side) == "modem" then
            local okWireless, isWireless = pcall(peripheral.call, side, "isWireless")
            if okWireless and isWireless then
                if not rednet.isOpen(side) then
                    rednet.open(side)
                end
                return true, side
            end
        end
    end

    for _, side in ipairs(peripheral.getNames()) do
        if peripheral.getType(side) == "modem" then
            if not rednet.isOpen(side) then
                rednet.open(side)
            end
            return true, side
        end
    end

    return false, "No modem peripheral available"
end

local function formatUptime(seconds)
    local total = math.max(0, math.floor(seconds or 0))
    local h = math.floor(total / 3600)
    local m = math.floor((total % 3600) / 60)
    local s = total % 60
    return string.format("%02d:%02d:%02d", h, m, s)
end

local function addLog(state, line)
    state.log = state.log or {}
    table.insert(state.log, os.date("%H:%M:%S") .. " " .. tostring(line))
    while #state.log > 10 do
        table.remove(state.log, 1)
    end
end

local function writeLine(termObj, x, y, text, fg, bg)
    if bg and termObj.setBackgroundColor then
        termObj.setBackgroundColor(bg)
    end
    if fg and termObj.setTextColor then
        termObj.setTextColor(fg)
    end
    termObj.setCursorPos(x, y)
    termObj.write(text)
end

local function renderMailboxUI(monitor, state, store)
    if not monitor then
        return
    end

    local w, h = monitor.getSize()
    if colors.black and monitor.setBackgroundColor then
        monitor.setBackgroundColor(colors.black)
    end
    if colors.white and monitor.setTextColor then
        monitor.setTextColor(colors.white)
    end
    monitor.clear()

    writeLine(monitor, 1, 1, string.rep(" ", w), colors.white, colors.blue)
    local header = string.format(" Mailbox Server ID:%s ", tostring(currentComputerID()))
    writeLine(monitor, 1, 1, header:sub(1, w), colors.white, colors.blue)

    writeLine(monitor, 1, 2, string.format("Modem: %s", tostring(state.modemSide)), colors.lightGray, colors.black)
    writeLine(monitor, 1, 3, string.format("Uptime: %s", formatUptime(os.clock() - state.startedAt)), colors.lightGray,
        colors.black)
    writeLine(monitor, 1, 4, string.format("Requests: %d", state.requestCount), colors.white, colors.black)
    writeLine(monitor, 1, 5, string.format("Delivered: %d", state.deliveredCount), colors.green, colors.black)
    writeLine(monitor, 1, 6, string.format("Queued: %d", state.queuedCount), colors.yellow, colors.black)
    writeLine(monitor, 1, 7, string.format("Fetched: %d", state.fetchedCount), colors.cyan, colors.black)
    writeLine(monitor, 1, 8, string.format("In Queue: %d", getTotalQueued(store)), colors.orange, colors.black)

    writeLine(monitor, 1, 10, "Recent Activity:", colors.white, colors.black)
    local row = 11
    local maxRows = h - row + 1
    local start = math.max(1, #state.log - maxRows + 1)
    for i = start, #state.log do
        local line = state.log[i]
        writeLine(monitor, 1, row, tostring(line):sub(1, w), colors.lightGray, colors.black)
        row = row + 1
        if row > h then
            break
        end
    end
end

local function tryAttachMonitor()
    local okMonitor, monitorOrErr = pcall(function()
        local monitor = plib.wrap("monitor", "monitor")
        return monitor
    end)

    if okMonitor then
        return monitorOrErr
    end

    return nil
end

local function runServerLoop()
    local modemOk, modemSideOrErr = ensureRednetOpen()
    if not modemOk then
        printError("Mailbox server startup failed: " .. tostring(modemSideOrErr))
        return
    end

    local state = {
        modemSide = modemSideOrErr,
        startedAt = os.clock(),
        requestCount = 0,
        deliveredCount = 0,
        queuedCount = 0,
        fetchedCount = 0,
        log = {}
    }

    local store = loadMailboxStore()
    addLog(state, "Server online on modem " .. tostring(state.modemSide))
    print(string.format("Mailbox server online on ID %d (%s)", currentComputerID(), state.modemSide))
    print("Listening on protocol: " .. MAILBOX_PROTOCOL)

    local monitor = tryAttachMonitor()
    if monitor then
        if monitor.setTextScale then
            monitor.setTextScale(0.5)
        end
        addLog(state, "Monitor UI attached")
    else
        addLog(state, "Monitor not attached; terminal logging only")
    end

    renderMailboxUI(monitor, state, store)

    while true do
        local senderID, request = rednet.receive(MAILBOX_PROTOCOL, 0.5)
        if senderID then
            state.requestCount = state.requestCount + 1

            if type(request) ~= "table" then
                rednet.send(senderID, { ok = false, error = "Invalid request payload" }, MAILBOX_PROTOCOL)
                addLog(state, "Invalid request from " .. tostring(senderID))
            elseif request.type == "store_status" then
                local targetID = tonumber(request.target_id)
                local payload = request.payload

                if not targetID or type(payload) ~= "table" then
                    rednet.send(senderID, { ok = false, error = "store_status requires target_id and payload" },
                        MAILBOX_PROTOCOL)
                    addLog(state, "Bad store_status from " .. tostring(senderID))
                else
                    local delivered = false
                    if request.try_direct ~= false then
                        local sentOk, sentRet = pcall(rednet.send, targetID, payload, "turtle_status")
                        delivered = (sentOk and sentRet == true)
                    end

                    if delivered then
                        state.deliveredCount = state.deliveredCount + 1
                        rednet.send(senderID, {
                            ok = true,
                            delivered = true,
                            queued = false,
                            queued_count = #(store[tostring(targetID)] or {})
                        }, MAILBOX_PROTOCOL)
                        addLog(state, string.format("Delivered %s -> %s", tostring(senderID), tostring(targetID)))
                    else
                        appendMailboxMessage(store, targetID, {
                            from = senderID,
                            target = targetID,
                            payload = payload,
                            message = payload.status,
                            is_error = payload.is_error,
                            ts = (type(epochFn) == "function" and epochFn("utc")) or os.clock()
                        })

                        local saved, saveErr = saveMailboxStore(store)
                        if not saved then
                            rednet.send(senderID, { ok = false, error = saveErr or "Failed to persist mailbox" },
                                MAILBOX_PROTOCOL)
                            addLog(state, "Queue persist failed for target " .. tostring(targetID))
                        else
                            state.queuedCount = state.queuedCount + 1
                            local queuedCount = #store[tostring(targetID)]
                            rednet.send(senderID, {
                                ok = true,
                                delivered = false,
                                queued = true,
                                queued_count = queuedCount
                            }, MAILBOX_PROTOCOL)
                            addLog(state,
                                string.format("Queued for %s (%d pending)", tostring(targetID), queuedCount))
                        end
                    end
                end
            elseif request.type == "fetch_mailbox" then
                local turtleID = tonumber(request.turtle_id or senderID)
                local key = tostring(turtleID)
                local messages = store[key] or {}

                store[key] = {}
                local saved, saveErr = saveMailboxStore(store)
                if not saved then
                    rednet.send(senderID, { ok = false, error = saveErr or "Failed to update mailbox" },
                        MAILBOX_PROTOCOL)
                    addLog(state, "Fetch save failed for " .. tostring(turtleID))
                else
                    state.fetchedCount = state.fetchedCount + #messages
                    rednet.send(senderID, {
                        ok = true,
                        type = "mailbox_messages",
                        turtle_id = turtleID,
                        messages = messages
                    }, MAILBOX_PROTOCOL)
                    addLog(state, string.format("Fetched %d for %s", #messages, tostring(turtleID)))
                end
            elseif request.type == "ping" then
                rednet.send(senderID, {
                    ok = true,
                    type = "pong",
                    server_id = currentComputerID()
                }, MAILBOX_PROTOCOL)
                addLog(state, "Ping from " .. tostring(senderID))
            else
                rednet.send(senderID, {
                    ok = false,
                    error = "Unknown request type: " .. tostring(request.type)
                }, MAILBOX_PROTOCOL)
                addLog(state, "Unknown request from " .. tostring(senderID))
            end

            renderMailboxUI(monitor, state, store)
        else
            renderMailboxUI(monitor, state, store)
        end
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
