-- tlib_mailbox.lua
-- Mailbox server + CLI utility for turtle status relay/queue operations.

local tlib = nil
do
    local ok, tlibOrErr = pcall(require, "tlib")
    if ok and type(tlibOrErr) == "table" then
        tlib = tlibOrErr
    end
end

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
local MAILBOX_ACK_TIMEOUT_SECONDS = 5

local function mailboxNowSeconds()
    if type(epochFn) == "function" then
        return math.floor(epochFn("utc") / 1000)
    end
    return math.floor(os.clock())
end

local function cloneShallowTable(value)
    if type(value) ~= "table" then
        return value
    end

    local out = {}
    for k, v in pairs(value) do
        out[k] = v
    end
    return out
end

local function ensureMailboxStoreShape(store)
    if type(store) ~= "table" then
        store = {}
    end

    local queued = store.queued
    local inflight = store.inflight

    if type(queued) ~= "table" or type(inflight) ~= "table" then
        local migratedQueued = {}
        for key, value in pairs(store) do
            if type(key) == "string" and type(value) == "table" then
                migratedQueued[key] = value
            end
        end

        queued = migratedQueued
        inflight = {}
        store = {
            queued = queued,
            inflight = inflight,
            sequence = tonumber(store.sequence) or 0
        }
        return store
    end

    store.queued = queued
    store.inflight = inflight
    store.sequence = tonumber(store.sequence) or 0
    return store
end

local function ensureMailboxBucket(tbl, key)
    if type(tbl[key]) ~= "table" then
        tbl[key] = {}
    end
    return tbl[key]
end

local function removeMessageById(messages, messageID)
    if type(messages) ~= "table" then
        return nil
    end

    for i = #messages, 1, -1 do
        local msg = messages[i]
        if type(msg) == "table" and msg.message_id == messageID then
            table.remove(messages, i)
            return msg
        end
    end

    return nil
end

local function nextMailboxMessageID(store, targetID)
    store.sequence = (tonumber(store.sequence) or 0) + 1
    return string.format("%s-%s-%s", tostring(currentComputerID()), tostring(mailboxNowSeconds()),
        tostring(store.sequence))
end

local function buildMailboxEntry(store, senderID, targetID, payload, ackTimeout)
    local timeout = tonumber(ackTimeout) or MAILBOX_ACK_TIMEOUT_SECONDS
    if timeout < 1 then
        timeout = MAILBOX_ACK_TIMEOUT_SECONDS
    end

    return {
        message_id = nextMailboxMessageID(store, targetID),
        from = senderID,
        target = targetID,
        payload = cloneShallowTable(payload),
        message = payload and payload.status or nil,
        is_error = payload and payload.is_error or false,
        ts = mailboxNowSeconds(),
        ack_timeout_s = timeout,
        expires_at = nil
    }
end

local function moveToInflight(store, targetID, entry)
    local key = tostring(targetID)
    local inflightBucket = ensureMailboxBucket(store.inflight, key)
    entry.expires_at = mailboxNowSeconds() + (tonumber(entry.ack_timeout_s) or MAILBOX_ACK_TIMEOUT_SECONDS)
    table.insert(inflightBucket, entry)
end

local function enqueueMailboxEntry(store, targetID, entry)
    local key = tostring(targetID)
    local queuedBucket = ensureMailboxBucket(store.queued, key)
    entry.expires_at = nil
    table.insert(queuedBucket, entry)
end

local function requeueExpiredInflight(store)
    local changed = false
    local now = mailboxNowSeconds()
    for key, inflightBucket in pairs(store.inflight) do
        if type(inflightBucket) == "table" and #inflightBucket > 0 then
            for i = #inflightBucket, 1, -1 do
                local entry = inflightBucket[i]
                local expiresAt = tonumber(entry and entry.expires_at)
                if not expiresAt or now >= expiresAt then
                    table.remove(inflightBucket, i)
                    if type(entry) == "table" then
                        enqueueMailboxEntry(store, key, entry)
                        changed = true
                    end
                end
            end
        end
    end

    return changed
end

local function checkoutQueuedMessages(store, targetID)
    local key = tostring(targetID)
    local queuedBucket = store.queued[key] or {}
    store.queued[key] = {}

    local checkout = {}
    for i = 1, #queuedBucket do
        local entry = queuedBucket[i]
        if type(entry) == "table" then
            moveToInflight(store, targetID, entry)
            checkout[#checkout + 1] = cloneShallowTable(entry)
        end
    end

    return checkout
end

local function ackMailboxMessageInStore(store, targetID, messageID)
    local key = tostring(targetID)

    local inflightBucket = store.inflight[key]
    local inflightEntry = removeMessageById(inflightBucket, messageID)
    if inflightEntry then
        return true, "acked_inflight"
    end

    local queuedBucket = store.queued[key]
    local queuedEntry = removeMessageById(queuedBucket, messageID)
    if queuedEntry then
        return true, "acked_queued"
    end

    return false, "unknown_message"
end

local function countQueuedForTarget(store, targetID)
    local key = tostring(targetID)
    local queuedBucket = store.queued[key]
    if type(queuedBucket) ~= "table" then
        return 0
    end
    return #queuedBucket
end

local function countInflightForTarget(store, targetID)
    local key = tostring(targetID)
    local inflightBucket = store.inflight[key]
    if type(inflightBucket) ~= "table" then
        return 0
    end
    return #inflightBucket
end

local function getTotalInflight(store)
    local count = 0
    local inflight = store.inflight or {}
    for _, messages in pairs(inflight) do
        if type(messages) == "table" then
            count = count + #messages
        end
    end
    return count
end

local function decorateStatusPayloadForAck(payload, messageID, serverID, targetID)
    local out = cloneShallowTable(payload)
    out.mailbox_message_id = messageID
    out.mailbox_server_id = serverID
    out.mailbox_target_id = targetID
    out.mailbox_ack_required = true
    out.mailbox_protocol = MAILBOX_PROTOCOL
    return out
end

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
        return ensureMailboxStoreShape({})
    end

    return ensureMailboxStoreShape(parsed)
end

local function saveMailboxStore(store)
    local f = fs.open(MAILBOX_STORE_FILE, "w")
    if not f then
        return false, "Failed to open mailbox store for writing"
    end

    f.write(textutils.serialize(ensureMailboxStoreShape(store or {})))
    f.close()
    return true
end

local function appendMailboxMessage(store, targetID, entry)
    enqueueMailboxEntry(ensureMailboxStoreShape(store), targetID, entry)
end

local function getTotalQueued(store)
    local count = 0
    local queued = (type(store) == "table" and store.queued) or {}
    for _, messages in pairs(queued) do
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
    writeLine(monitor, 1, 9, string.format("In Flight: %d", getTotalInflight(store)), colors.lightBlue, colors.black)

    writeLine(monitor, 1, 11, "Recent Activity:", colors.white, colors.black)
    local row = 12
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
        store = ensureMailboxStoreShape(store)
        local changedBySweep = requeueExpiredInflight(store)
        if changedBySweep then
            saveMailboxStore(store)
        end

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
                    local entry = buildMailboxEntry(store, senderID, targetID, payload, request.ack_timeout_s)
                    local delivered = false
                    if request.try_direct ~= false then
                        local outbound = decorateStatusPayloadForAck(payload, entry.message_id, currentComputerID(),
                            targetID)
                        local sentOk, sentRet = pcall(rednet.send, targetID, outbound, "turtle_status")
                        delivered = (sentOk and sentRet == true)
                    end

                    if delivered then
                        moveToInflight(store, targetID, entry)
                        addLog(state,
                            string.format("Direct sent %s -> %s (%s)", tostring(senderID), tostring(targetID),
                                tostring(entry.message_id)))
                    else
                        appendMailboxMessage(store, targetID, entry)
                        state.queuedCount = state.queuedCount + 1
                        addLog(state,
                            string.format("Queued for %s (%d pending)", tostring(targetID),
                                countQueuedForTarget(store, targetID)))
                    end

                    local saved, saveErr = saveMailboxStore(store)
                    if not saved then
                        rednet.send(senderID, { ok = false, error = saveErr or "Failed to persist mailbox" },
                            MAILBOX_PROTOCOL)
                        addLog(state, "Store persist failed for target " .. tostring(targetID))
                    else
                        rednet.send(senderID, {
                            ok = true,
                            delivered = false,
                            ack_pending = delivered,
                            queued = not delivered,
                            message_id = entry.message_id,
                            queued_count = countQueuedForTarget(store, targetID),
                            inflight_count = countInflightForTarget(store, targetID)
                        }, MAILBOX_PROTOCOL)
                    end
                end
            elseif request.type == "fetch_mailbox" then
                local turtleID = tonumber(request.turtle_id or senderID)
                local messages = checkoutQueuedMessages(store, turtleID)
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
            elseif request.type == "ack_status" then
                local turtleID = tonumber(request.turtle_id or senderID)
                local messageID = request.message_id

                if not turtleID or type(messageID) ~= "string" or messageID == "" then
                    rednet.send(senderID, {
                        ok = false,
                        error = "ack_status requires turtle_id and message_id"
                    }, MAILBOX_PROTOCOL)
                    addLog(state, "Bad ack_status from " .. tostring(senderID))
                else
                    local acked, reason = ackMailboxMessageInStore(store, turtleID, messageID)
                    local saved, saveErr = saveMailboxStore(store)
                    if not saved then
                        rednet.send(senderID, { ok = false, error = saveErr or "Failed to persist mailbox" },
                            MAILBOX_PROTOCOL)
                        addLog(state, "ACK save failed for " .. tostring(turtleID))
                    else
                        if acked then
                            state.deliveredCount = state.deliveredCount + 1
                            addLog(state,
                                string.format("ACK %s for %s (%s)", tostring(senderID), tostring(turtleID),
                                    tostring(messageID)))
                        else
                            addLog(state,
                                string.format("Unknown ACK %s for %s (%s)", tostring(senderID), tostring(turtleID),
                                    tostring(messageID)))
                        end
                        rednet.send(senderID, {
                            ok = acked,
                            acked = acked,
                            reason = reason,
                            message_id = messageID,
                            turtle_id = turtleID,
                            queued_count = countQueuedForTarget(store, turtleID),
                            inflight_count = countInflightForTarget(store, turtleID),
                            error = acked and nil or "Message not found"
                        }, MAILBOX_PROTOCOL)
                    end
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
    print("  tlib_mailbox fetch_noack [mailboxServerId]")
    print("  tlib_mailbox ack <messageId> [serverId] [targetId]")
    print("  NOTE: ping/broadcast/send/fetch commands require tlib (turtle client)")
end

local function requireTlib(commandName)
    if tlib then
        return true
    end

    printError(string.format(
        "Command '%s' requires tlib/turtle APIs. Run server mode on this computer, or run this command on a turtle with tlib installed.",
        tostring(commandName)
    ))
    return false
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
            local messageID = tostring(msg.message_id or "n/a")
            local ackState = msg.ack_ok == nil and "pending" or (msg.ack_ok and "acked" or "ack_failed")
            print(string.format("  [%d] id=%s from=%s ack=%s msg=%s", i, messageID, from, ackState, body))
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
    if not requireTlib("ping") then
        return
    end

    local lib = assert(tlib)
    local mailboxServerID = tonumber(args[2])
    local success, reply = lib.pingMailbox(mailboxServerID)
    if success then
        local serverID = "unknown"
        if type(reply) == "table" and reply.server_id ~= nil then
            serverID = tostring(reply.server_id)
        elseif type(reply) == "number" or type(reply) == "string" then
            serverID = tostring(reply)
        end
        print("Mailbox server reachable: " .. serverID)
    else
        printError("Ping failed: " .. tostring(reply))
    end
    return
end

if cmd == "broadcast" then
    if not requireTlib("broadcast") then
        return
    end

    local lib = assert(tlib)
    local statusText = joinFrom(args, 2)
    if statusText == "" then
        printError("Status text is required.")
        return
    end

    local success, ret = lib.broadcastStatus(statusText, false)
    if success then
        print("Status broadcast sent.")
    else
        printError("Broadcast failed: " .. tostring(ret))
    end
    return
end

if cmd == "broadcast_error" then
    if not requireTlib("broadcast_error") then
        return
    end

    local lib = assert(tlib)
    local statusText = joinFrom(args, 2)
    if statusText == "" then
        printError("Status text is required.")
        return
    end

    local success, ret = lib.broadcastStatus(statusText, true)
    if success then
        print("Error status broadcast sent.")
    else
        printError("Broadcast failed: " .. tostring(ret))
    end
    return
end

if cmd == "send" or cmd == "send_error" then
    if not requireTlib(cmd) then
        return
    end

    local lib = assert(tlib)
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
    local success, ret = lib.sendStatusViaMailbox(targetId, statusText, isError, mailboxServerID)
    if success then
        if type(ret) == "table" and type(ret.message_id) == "string" then
            if ret.queued then
                print("Status queued for " .. tostring(targetId) .. " (message_id=" .. ret.message_id .. ").")
            elseif ret.ack_pending then
                print("Status sent to " .. tostring(targetId) .. " and awaiting ACK (message_id=" .. ret.message_id ..
                    ").")
            else
                print("Status accepted by mailbox server for " .. tostring(targetId) .. " (message_id=" ..
                    ret.message_id .. ").")
            end
        else
            print("Status accepted by mailbox server.")
        end
    else
        printError("Send failed: " .. tostring(ret))
    end
    return
end

if cmd == "send_direct" or cmd == "send_direct_error" then
    if not requireTlib(cmd) then
        return
    end

    local lib = assert(tlib)
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
    local success, ret = lib.sendStatus(targetId, statusText, isError)
    if success then
        print("Direct status message sent to " .. tostring(targetId) .. ".")
    else
        printError("Direct send failed: " .. tostring(ret))
    end
    return
end

if cmd == "fetch" or cmd == "fetch_noack" then
    if not requireTlib("fetch") then
        return
    end

    local lib = assert(tlib)
    local mailboxServerID = tonumber(args[2])
    local options = { autoAck = (cmd ~= "fetch_noack") }
    local success, messages = lib.checkOfflineMessages(mailboxServerID, options)
    if success then
        printMessages(messages)
    else
        printError("Fetch failed: " .. tostring(messages))
    end
    return
end

if cmd == "ack" then
    if not requireTlib("ack") then
        return
    end

    local lib = assert(tlib)
    local messageID = tostring(args[2] or "")
    if messageID == "" then
        printError("messageId is required.")
        return
    end

    local mailboxServerID = tonumber(args[3])
    local targetID = tonumber(args[4])
    local success, reply = lib.ackMailboxMessage(messageID, mailboxServerID, targetID)
    if success then
        print("ACK accepted for message_id=" .. tostring(messageID) .. ".")
    else
        printError("ACK failed: " .. tostring(reply))
    end
    return
end

printError("Unknown command: " .. tostring(cmd))
printUsage()
