-- nlib.lua
-- Network library for Rednet wrappers plus mailbox server/client operations.

local nlib = {}

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
local getComputerLabelFn = (os and rawget(os, "getComputerLabel")) or rawget(_G, "getComputerLabel")
local epochFn = os and rawget(os, "epoch")

local MAILBOX_PROTOCOL = "turtle_mailbox"
local STATUS_PROTOCOL = "turtle_status"
local MAILBOX_STORE_FILE = "turtle_mailbox_store.json"
local MAILBOX_ACK_TIMEOUT_SECONDS = 5

local customTransactionRunner = nil
local statusPayloadProvider = nil

local function currentComputerID()
    if type(getComputerIDFn) == "function" then
        return getComputerIDFn()
    end
    return -1
end

local function currentComputerLabel()
    if type(getComputerLabelFn) == "function" then
        return getComputerLabelFn() or "Computer"
    end
    return "Computer"
end

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

local function nextMailboxMessageID(store)
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
        message_id = nextMailboxMessageID(store),
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

local function defaultRunTransaction(transactionFunc)
    local modemOk, modemSideOrErr = ensureRednetOpen()
    if not modemOk then
        return false, modemSideOrErr
    end

    local side = modemSideOrErr
    local wasOpen = rednet.isOpen(side)
    if not wasOpen then
        rednet.open(side)
    end

    local ok, ret = pcall(transactionFunc, side)

    if not wasOpen then
        rednet.close(side)
    end

    if not ok then
        error(ret)
    end

    return true, ret
end

local function runTransaction(transactionFunc)
    if type(customTransactionRunner) == "function" then
        return customTransactionRunner(transactionFunc)
    end
    return defaultRunTransaction(transactionFunc)
end

local function createStatusPayload(statusText, isError, extra)
    if type(statusPayloadProvider) == "function" then
        local ok, payloadOrErr = pcall(statusPayloadProvider, statusText, isError, extra)
        if ok and type(payloadOrErr) == "table" then
            return payloadOrErr
        end
    end

    local payload = {
        id = currentComputerID(),
        label = currentComputerLabel(),
        status = statusText,
        is_error = isError or false
    }

    if type(extra) == "table" then
        for k, v in pairs(extra) do
            payload[k] = v
        end
    end

    return payload
end

local function queuePayloadWithMailboxServer(targetID, payload, mailboxServerID, tryDirect)
    local request = {
        type = "store_status",
        target_id = targetID,
        payload = payload,
        try_direct = (tryDirect ~= false),
        ack_timeout_s = MAILBOX_ACK_TIMEOUT_SECONDS
    }

    return runTransaction(function(side)
        if mailboxServerID then
            rednet.send(mailboxServerID, request, MAILBOX_PROTOCOL)
        else
            rednet.broadcast(request, MAILBOX_PROTOCOL)
        end

        local sender, reply = rednet.receive(MAILBOX_PROTOCOL, 2.0)
        if not sender then
            return false, "Mailbox server did not respond"
        end

        if type(reply) ~= "table" then
            return false, "Mailbox server response was invalid"
        end

        if reply.ok then
            return true, reply
        end

        return false, tostring(reply.error or "Mailbox server rejected request")
    end)
end

function nlib.setTransactionRunner(runner)
    if runner ~= nil and type(runner) ~= "function" then
        return false, "runner must be a function or nil"
    end
    customTransactionRunner = runner
    return true
end

function nlib.setStatusProvider(provider)
    if provider ~= nil and type(provider) ~= "function" then
        return false, "provider must be a function or nil"
    end
    statusPayloadProvider = provider
    return true
end

function nlib.open(side)
    if type(side) == "string" and side ~= "" then
        if peripheral.getType(side) ~= "modem" then
            return false, "Requested side is not a modem"
        end
        if not rednet.isOpen(side) then
            rednet.open(side)
        end
        return true, side
    end

    return ensureRednetOpen()
end

function nlib.close(side)
    if type(side) == "string" and side ~= "" then
        if rednet.isOpen(side) then
            rednet.close(side)
        end
        return true
    end

    for _, modemSide in ipairs(peripheral.getNames()) do
        if peripheral.getType(modemSide) == "modem" and rednet.isOpen(modemSide) then
            rednet.close(modemSide)
        end
    end

    return true
end

function nlib.broadcast(message, protocol)
    return runTransaction(function(side)
        rednet.broadcast(message, protocol)
        return true
    end)
end

function nlib.send(targetID, message, protocol)
    return runTransaction(function(side)
        rednet.send(targetID, message, protocol)
        return true
    end)
end

function nlib.receive(protocolFilter, timeout)
    return runTransaction(function(side)
        local senderID, payload, proto = rednet.receive(protocolFilter, timeout)
        return {
            sender_id = senderID,
            payload = payload,
            protocol = proto
        }
    end)
end

function nlib.host(protocol, hostname)
    if type(protocol) ~= "string" or protocol == "" then
        return false, "protocol is required"
    end
    if type(hostname) ~= "string" or hostname == "" then
        return false, "hostname is required"
    end

    local ok, err = nlib.open()
    if not ok then
        return false, err
    end

    rednet.host(protocol, hostname)
    return true
end

function nlib.unhost(protocol, hostname)
    if type(protocol) ~= "string" or protocol == "" then
        return false, "protocol is required"
    end
    if type(hostname) ~= "string" or hostname == "" then
        return false, "hostname is required"
    end

    local ok, err = nlib.open()
    if not ok then
        return false, err
    end

    rednet.unhost(protocol, hostname)
    return true
end

function nlib.lookup(protocol, hostname)
    return runTransaction(function(side)
        return rednet.lookup(protocol, hostname)
    end)
end

function nlib.broadcastStatus(statusText, isError, extra)
    local payload = createStatusPayload(statusText, isError, extra)
    return nlib.broadcast(payload, STATUS_PROTOCOL)
end

function nlib.sendStatus(targetID, statusText, isError, mailboxServerID, extra)
    local payload = createStatusPayload(statusText, isError, extra)

    if mailboxServerID then
        return queuePayloadWithMailboxServer(targetID, payload, mailboxServerID, true)
    end

    return nlib.send(targetID, payload, STATUS_PROTOCOL)
end

function nlib.queueStatus(targetID, statusText, isError, mailboxServerID, extra)
    local payload = createStatusPayload(statusText, isError, extra)
    return queuePayloadWithMailboxServer(targetID, payload, mailboxServerID, false)
end

function nlib.sendStatusViaMailbox(targetID, statusText, isError, mailboxServerID, extra)
    local payload = createStatusPayload(statusText, isError, extra)
    return queuePayloadWithMailboxServer(targetID, payload, mailboxServerID, true)
end

function nlib.pingMailbox(mailboxServerID)
    local query = {
        type = "ping",
        sender_id = currentComputerID()
    }

    return runTransaction(function(side)
        if mailboxServerID then
            rednet.send(mailboxServerID, query, MAILBOX_PROTOCOL)
        else
            rednet.broadcast(query, MAILBOX_PROTOCOL)
        end

        local sender, reply = rednet.receive(MAILBOX_PROTOCOL, 2.0)
        if not sender then
            return false, "Mailbox server did not respond"
        end

        if type(reply) ~= "table" then
            return false, "Mailbox server response was invalid"
        end

        if reply.ok and reply.type == "pong" then
            if reply.server_id == nil then
                reply.server_id = sender
            end
            return true, reply
        end

        return false, tostring(reply.error or "Mailbox ping failed")
    end)
end

function nlib.ackMailboxMessage(messageID, mailboxServerID, targetID)
    if type(messageID) ~= "string" or messageID == "" then
        return false, "messageID is required"
    end

    local ackTargetID = tonumber(targetID) or currentComputerID()
    if not ackTargetID then
        return false, "Unable to resolve target turtle ID for ACK"
    end

    local query = {
        type = "ack_status",
        turtle_id = ackTargetID,
        message_id = messageID,
        sender_id = currentComputerID()
    }

    return runTransaction(function(side)
        if mailboxServerID then
            rednet.send(mailboxServerID, query, MAILBOX_PROTOCOL)
        else
            rednet.broadcast(query, MAILBOX_PROTOCOL)
        end

        local sender, reply = rednet.receive(MAILBOX_PROTOCOL, 2.0)
        if not sender then
            return false, "Mailbox server did not respond"
        end

        if type(reply) ~= "table" then
            return false, "Mailbox server response was invalid"
        end

        if reply.ok then
            return true, reply
        end

        return false, tostring(reply.error or "Mailbox ACK failed")
    end)
end

function nlib.listenStatus(options)
    local opts = options
    if type(opts) ~= "table" then
        opts = {}
    end

    local timeout = tonumber(opts.timeout)
    local protocol = type(opts.protocol) == "string" and opts.protocol or STATUS_PROTOCOL
    local autoAck = opts.autoAck ~= false
    local onMessage = opts.onMessage

    if onMessage ~= nil and type(onMessage) ~= "function" then
        return false, "options.onMessage must be a function"
    end

    return runTransaction(function(side)
        local senderID, payload = rednet.receive(protocol, timeout)
        if not senderID then
            return true, {
                received = false,
                timeout = true
            }
        end

        local handlerSuccess = true
        local handlerResult = nil
        if onMessage then
            handlerSuccess, handlerResult = pcall(onMessage, payload, senderID)
        end

        local processed = handlerSuccess and handlerResult ~= false
        local result = {
            received = true,
            sender_id = senderID,
            payload = payload,
            handler_ok = handlerSuccess,
            handled = processed,
            handler_result = handlerResult
        }

        if not handlerSuccess then
            result.handler_error = tostring(handlerResult)
        end

        local isEnvelope = type(payload) == "table"
            and payload.mailbox_ack_required == true
            and type(payload.mailbox_message_id) == "string"
            and payload.mailbox_message_id ~= ""

        if autoAck and processed and isEnvelope then
            local ackServerID = tonumber(opts.mailboxServerID) or tonumber(payload.mailbox_server_id)
            local ackTargetID = tonumber(payload.mailbox_target_id) or currentComputerID()
            local ackOk, ackRet = nlib.ackMailboxMessage(payload.mailbox_message_id, ackServerID, ackTargetID)

            result.ack_attempted = true
            result.ack_ok = ackOk
            if ackOk then
                result.ack_reply = ackRet
            else
                result.ack_error = tostring(ackRet)
            end
        end

        return true, result
    end)
end

function nlib.checkOfflineMessages(mailboxServerID, options)
    local opts = options
    if type(opts) ~= "table" then
        opts = {}
    end

    local query = {
        type = "fetch_mailbox",
        turtle_id = currentComputerID()
    }

    local success, messages = runTransaction(function(side)
        if mailboxServerID then
            rednet.send(mailboxServerID, query, MAILBOX_PROTOCOL)
        else
            rednet.broadcast(query, MAILBOX_PROTOCOL)
        end

        local sender, reply = rednet.receive(MAILBOX_PROTOCOL, 2.0)
        if sender and type(reply) == "table" and (reply.type == "mailbox_messages" or reply.messages) then
            return reply.messages
        end
        return {}
    end)

    if success and opts.autoAck ~= false and type(messages) == "table" then
        for i = 1, #messages do
            local msg = messages[i]
            if type(msg) == "table" and type(msg.message_id) == "string" then
                local targetID = tonumber(msg.target) or currentComputerID()
                local ackOk, ackRet = nlib.ackMailboxMessage(msg.message_id, mailboxServerID, targetID)
                msg.ack_ok = ackOk
                if not ackOk then
                    msg.ack_error = tostring(ackRet)
                end
            end
        end
    end

    return success, messages
end

local function formatUptime(seconds)
    local total = math.max(0, math.floor(seconds or 0))
    local h = math.floor(total / 3600)
    local m = math.floor((total % 3600) / 60)
    local s = total % 60
    return string.format("%02d:%02d:%02d", h, m, s)
end

local function addLog(serverState, line)
    serverState.log = serverState.log or {}
    table.insert(serverState.log, os.date("%H:%M:%S") .. " " .. tostring(line))
    while #serverState.log > 10 do
        table.remove(serverState.log, 1)
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

local function renderMailboxUI(monitor, serverState, store)
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

    writeLine(monitor, 1, 2, string.format("Modem: %s", tostring(serverState.modemSide)), colors.lightGray, colors.black)
    writeLine(monitor, 1, 3, string.format("Uptime: %s", formatUptime(os.clock() - serverState.startedAt)), colors.lightGray,
        colors.black)
    writeLine(monitor, 1, 4, string.format("Requests: %d", serverState.requestCount), colors.white, colors.black)
    writeLine(monitor, 1, 5, string.format("Delivered: %d", serverState.deliveredCount), colors.green, colors.black)
    writeLine(monitor, 1, 6, string.format("Queued: %d", serverState.queuedCount), colors.yellow, colors.black)
    writeLine(monitor, 1, 7, string.format("Fetched: %d", serverState.fetchedCount), colors.cyan, colors.black)
    writeLine(monitor, 1, 8, string.format("In Queue: %d", getTotalQueued(store)), colors.orange, colors.black)
    writeLine(monitor, 1, 9, string.format("In Flight: %d", getTotalInflight(store)), colors.lightBlue, colors.black)

    writeLine(monitor, 1, 11, "Recent Activity:", colors.white, colors.black)
    local row = 12
    local maxRows = h - row + 1
    local start = math.max(1, #serverState.log - maxRows + 1)
    for i = start, #serverState.log do
        local line = serverState.log[i]
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

function nlib.runMailboxServer()
    local modemOk, modemSideOrErr = ensureRednetOpen()
    if not modemOk then
        return false, modemSideOrErr
    end

    local serverState = {
        modemSide = modemSideOrErr,
        startedAt = os.clock(),
        requestCount = 0,
        deliveredCount = 0,
        queuedCount = 0,
        fetchedCount = 0,
        log = {}
    }

    local store = loadMailboxStore()
    addLog(serverState, "Server online on modem " .. tostring(serverState.modemSide))
    print(string.format("Mailbox server online on ID %d (%s)", currentComputerID(), serverState.modemSide))
    print("Listening on protocol: " .. MAILBOX_PROTOCOL)

    local monitor = tryAttachMonitor()
    if monitor then
        if monitor.setTextScale then
            monitor.setTextScale(0.5)
        end
        addLog(serverState, "Monitor UI attached")
    else
        addLog(serverState, "Monitor not attached; terminal logging only")
    end

    renderMailboxUI(monitor, serverState, store)

    while true do
        store = ensureMailboxStoreShape(store)
        local changedBySweep = requeueExpiredInflight(store)
        if changedBySweep then
            saveMailboxStore(store)
        end

        local senderID, request = rednet.receive(MAILBOX_PROTOCOL, 0.5)
        if senderID then
            serverState.requestCount = serverState.requestCount + 1

            if type(request) ~= "table" then
                rednet.send(senderID, { ok = false, error = "Invalid request payload" }, MAILBOX_PROTOCOL)
                addLog(serverState, "Invalid request from " .. tostring(senderID))
            elseif request.type == "store_status" then
                local targetID = tonumber(request.target_id)
                local payload = request.payload

                if not targetID or type(payload) ~= "table" then
                    rednet.send(senderID, { ok = false, error = "store_status requires target_id and payload" },
                        MAILBOX_PROTOCOL)
                    addLog(serverState, "Bad store_status from " .. tostring(senderID))
                else
                    local entry = buildMailboxEntry(store, senderID, targetID, payload, request.ack_timeout_s)
                    local delivered = false
                    if request.try_direct ~= false then
                        local outbound = decorateStatusPayloadForAck(payload, entry.message_id, currentComputerID(),
                            targetID)
                        local sentOk, sentRet = pcall(rednet.send, targetID, outbound, STATUS_PROTOCOL)
                        delivered = (sentOk and sentRet == true)
                    end

                    if delivered then
                        moveToInflight(store, targetID, entry)
                        addLog(serverState,
                            string.format("Direct sent %s -> %s (%s)", tostring(senderID), tostring(targetID),
                                tostring(entry.message_id)))
                    else
                        appendMailboxMessage(store, targetID, entry)
                        serverState.queuedCount = serverState.queuedCount + 1
                        addLog(serverState,
                            string.format("Queued for %s (%d pending)", tostring(targetID),
                                countQueuedForTarget(store, targetID)))
                    end

                    local saved, saveErr = saveMailboxStore(store)
                    if not saved then
                        rednet.send(senderID, { ok = false, error = saveErr or "Failed to persist mailbox" },
                            MAILBOX_PROTOCOL)
                        addLog(serverState, "Store persist failed for target " .. tostring(targetID))
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
                    addLog(serverState, "Fetch save failed for " .. tostring(turtleID))
                else
                    serverState.fetchedCount = serverState.fetchedCount + #messages
                    rednet.send(senderID, {
                        ok = true,
                        type = "mailbox_messages",
                        turtle_id = turtleID,
                        messages = messages
                    }, MAILBOX_PROTOCOL)
                    addLog(serverState, string.format("Fetched %d for %s", #messages, tostring(turtleID)))
                end
            elseif request.type == "ack_status" then
                local turtleID = tonumber(request.turtle_id or senderID)
                local messageID = request.message_id

                if not turtleID or type(messageID) ~= "string" or messageID == "" then
                    rednet.send(senderID, {
                        ok = false,
                        error = "ack_status requires turtle_id and message_id"
                    }, MAILBOX_PROTOCOL)
                    addLog(serverState, "Bad ack_status from " .. tostring(senderID))
                else
                    local acked, reason = ackMailboxMessageInStore(store, turtleID, messageID)
                    local saved, saveErr = saveMailboxStore(store)
                    if not saved then
                        rednet.send(senderID, { ok = false, error = saveErr or "Failed to persist mailbox" },
                            MAILBOX_PROTOCOL)
                        addLog(serverState, "ACK save failed for " .. tostring(turtleID))
                    else
                        if acked then
                            serverState.deliveredCount = serverState.deliveredCount + 1
                            addLog(serverState,
                                string.format("ACK %s for %s (%s)", tostring(senderID), tostring(turtleID),
                                    tostring(messageID)))
                        else
                            addLog(serverState,
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
                addLog(serverState, "Ping from " .. tostring(senderID))
            else
                rednet.send(senderID, {
                    ok = false,
                    error = "Unknown request type: " .. tostring(request.type)
                }, MAILBOX_PROTOCOL)
                addLog(serverState, "Unknown request from " .. tostring(senderID))
            end

            renderMailboxUI(monitor, serverState, store)
        else
            renderMailboxUI(monitor, serverState, store)
        end
    end
end

function nlib.installServerStartup()
    local startupContent = [[local ok, nlib = pcall(require, "nlib")
if ok and type(nlib) == "table" then
    local runOk, runErr = nlib.runMailboxServer()
    if not runOk then
        printError("Failed to start nlib mailbox server: " .. tostring(runErr))
    end
else
    printError("Failed to load nlib: " .. tostring(nlib))
end]]

    local f = fs.open("startup.lua", "w")
    if not f then
        return false, "Failed to write startup.lua"
    end

    f.write(startupContent)
    f.close()
    return true, "startup.lua installed for nlib mailbox server"
end

local function joinFrom(args, startIndex)
    local parts = {}
    for i = startIndex, #args do
        parts[#parts + 1] = tostring(args[i])
    end
    return table.concat(parts, " ")
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

local function printUsage()
    print("nlib usage:")
    print("  nlib                          (run mailbox server)")
    print("  nlib server                   (run mailbox server)")
    print("  nlib install_server|-is       (write startup.lua to host mailbox server)")
    print("  nlib ping [serverId]")
    print("  nlib broadcast <status text>")
    print("  nlib broadcast_error <status text>")
    print("  nlib send <targetId> <status text> [serverId]")
    print("  nlib send_error <targetId> <status text> [serverId]")
    print("  nlib fetch [mailboxServerId]")
    print("  nlib fetch_noack [mailboxServerId]")
    print("  nlib ack <messageId> [serverId] [targetId]")
end

function nlib.cli(args)
    local argv = args or {}
    local cmd = argv[1]

    if not cmd or cmd == "server" then
        local ok, err = nlib.runMailboxServer()
        if ok == false then
            printError("Mailbox server failed: " .. tostring(err))
        end
        return
    end

    if cmd == "install_server" or cmd == "-is" then
        local ok, msg = nlib.installServerStartup()
        if ok then
            print(tostring(msg or "startup.lua installed."))
        else
            printError("Install failed: " .. tostring(msg))
        end
        return
    end

    if cmd == "ping" then
        local mailboxServerID = tonumber(argv[2])
        local success, reply = nlib.pingMailbox(mailboxServerID)
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

    if cmd == "broadcast" or cmd == "broadcast_error" then
        local statusText = joinFrom(argv, 2)
        if statusText == "" then
            printError("Status text is required.")
            return
        end

        local isError = (cmd == "broadcast_error")
        local success, ret = nlib.broadcastStatus(statusText, isError)
        if success then
            print(isError and "Error status broadcast sent." or "Status broadcast sent.")
        else
            printError("Broadcast failed: " .. tostring(ret))
        end
        return
    end

    if cmd == "send" or cmd == "send_error" then
        local targetId = tonumber(argv[2])
        if not targetId then
            printError("targetId must be a number.")
            return
        end

        local mailboxServerID = nil
        local messageEndIndex = #argv
        if #argv >= 4 then
            local maybeServer = tonumber(argv[#argv])
            if maybeServer then
                mailboxServerID = maybeServer
                messageEndIndex = #argv - 1
            end
        end

        local parts = {}
        for i = 3, messageEndIndex do
            parts[#parts + 1] = tostring(argv[i])
        end
        local statusText = table.concat(parts, " ")

        if statusText == "" then
            printError("Status text is required.")
            return
        end

        local isError = (cmd == "send_error")
        local success, ret = nlib.sendStatusViaMailbox(targetId, statusText, isError, mailboxServerID)
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

    if cmd == "fetch" or cmd == "fetch_noack" then
        local mailboxServerID = tonumber(argv[2])
        local options = { autoAck = (cmd ~= "fetch_noack") }
        local success, messages = nlib.checkOfflineMessages(mailboxServerID, options)
        if success then
            printMessages(messages)
        else
            printError("Fetch failed: " .. tostring(messages))
        end
        return
    end

    if cmd == "ack" then
        local messageID = tostring(argv[2] or "")
        if messageID == "" then
            printError("messageId is required.")
            return
        end

        local mailboxServerID = tonumber(argv[3])
        local targetID = tonumber(argv[4])
        local success, reply = nlib.ackMailboxMessage(messageID, mailboxServerID, targetID)
        if success then
            print("ACK accepted for message_id=" .. tostring(messageID) .. ".")
        else
            printError("ACK failed: " .. tostring(reply))
        end
        return
    end

    printError("Unknown command: " .. tostring(cmd))
    printUsage()
end

local args = { ... }
if #args == 0 then
    -- Direct invocation with no args should run default CLI behavior (mailbox server).
    nlib.cli(args)
elseif tostring(args[1]) ~= "nlib" then
    -- When loaded via require(), some environments pass the module name as arg[1].
    -- Skip CLI auto-execution in that case to avoid spurious "Unknown command: nlib".
    nlib.cli(args)
end

return nlib
