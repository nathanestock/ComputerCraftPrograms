local tlib = require("tlib")
local ccTurtle = rawget(_G, "turtle")
local osSleep = os and rawget(os, "sleep")
local ccSleep = rawget(_G, "sleep") or function(seconds)
    if osSleep then
        osSleep(seconds)
    end
end
local ccPrintError = rawget(_G, "printError") or function(msg)
    print(msg)
end
local ccRead = rawget(_G, "read")
local ccShell = rawget(_G, "shell")
local ccTerm = rawget(_G, "term")
local ccColors = rawget(_G, "colors")
local rebootFn = os and os["reboot"]

local statusColors = ccColors and {
    PASS = ccColors.green,
    FAIL = ccColors.red,
    SKIP = ccColors.yellow,
    WARN = ccColors.orange,
}

local function setColor(color)
    if ccTerm and color and ccTerm.setTextColor then
        ccTerm.setTextColor(color)
    end
end

local function resetColor()
    if ccTerm and ccTerm.setTextColor then
        ccTerm.setTextColor(ccColors and ccColors.white or 1)
    end
end

local function nowStamp()
    return os.time()
end

local function ensureHarnessState(taskState)
    if type(taskState) ~= "table" then
        taskState = {}
    end

    if type(taskState.tlibTest) ~= "table" then
        taskState.tlibTest = {
            version = 1,
            phase = "boot",
            createdAt = nowStamp(),
            updatedAt = nowStamp(),
            rebootRequested = false,
            rebootVerified = false,
            completed = false,
            allowDestructive = false,
            allowIntegration = false,
            assertions = {},
            counts = {
                PASS = 0,
                FAIL = 0,
                SKIP = 0,
                WARN = 0
            }
        }
    end

    local h = taskState.tlibTest
    h.phase = h.phase or "boot"
    h.assertions = h.assertions or {}
    h.counts = h.counts or { PASS = 0, FAIL = 0, SKIP = 0, WARN = 0 }
    h.counts.PASS = h.counts.PASS or 0
    h.counts.FAIL = h.counts.FAIL or 0
    h.counts.SKIP = h.counts.SKIP or 0
    h.counts.WARN = h.counts.WARN or 0
    h.allowDestructive = h.allowDestructive or false
    h.allowIntegration = h.allowIntegration or false

    if h.phase == "boot" and h.rebootRequested and not h.rebootVerified and h.rebootToken then
        h.phase = "post_reboot_verify"
    end

    h.updatedAt = nowStamp()
    return taskState, h
end

tlib.load()
local task = tlib.getTaskState()
task, test = ensureHarnessState(task)

local function saveTask()
    test.updatedAt = nowStamp()
    tlib.setTaskState(task)
end

local function record(status, id, message)
    local entry = {
        id = id,
        status = status,
        message = message,
        at = nowStamp()
    }
    table.insert(test.assertions, entry)

    if test.counts[status] == nil then
        test.counts[status] = 0
    end
    test.counts[status] = test.counts[status] + 1

    local line = string.format("[%s] %s - %s", status, id, message)
    if status == "FAIL" then
        ccPrintError(line)
    else
        setColor(statusColors and statusColors[status])
        print(line)
        resetColor()
    end
end

local function assertTrue(id, condition, passMessage, failMessage)
    if condition then
        record("PASS", id, passMessage)
        return true
    end
    record("FAIL", id, failMessage)
    return false
end

local function markSkip(id, reason)
    record("SKIP", id, reason)
end

local function markWarn(id, reason)
    record("WARN", id, reason)
end

local function setPhase(nextPhase)
    test.phase = nextPhase
    saveTask()
end

local function hasFunction(name)
    return type(tlib[name]) == "function"
end

local function getResumeProgram()
    local runningProgram = ccShell and ccShell.getRunningProgram and ccShell.getRunningProgram() or nil
    if type(runningProgram) == "string" and runningProgram ~= "" then
        return runningProgram
    end
    return "test"
end

local function promptTestOptions()
    if type(ccRead) ~= "function" then return end

    print("")
    if ccTerm and ccTerm.setTextColor and ccColors then
        ccTerm.setTextColor(ccColors.lightBlue)
    end
    print("=== tlib Self-Test Configuration ===")
    resetColor()

    write("Enable destructive movement tests? (y/N): ")
    local d = ccRead()
    test.allowDestructive = (d == "y" or d == "Y")

    write("Enable integration tests (GPS/Rednet)? (y/N): ")
    local i = ccRead()
    test.allowIntegration = (i == "y" or i == "Y")

    print("")
end

local function runSafeTests()
    print("Running safe API tests...")

    if not ccTurtle then
        markSkip("ENV-01", "turtle API unavailable in current runtime")
        return
    end

    local x, y, z, facing = tlib.getPosition()
    assertTrue("POS-01", type(x) == "number" and type(y) == "number" and type(z) == "number",
        "Position values are numeric", "Position values are invalid")
    assertTrue("POS-02", type(facing) == "number", "Facing value is numeric", "Facing value is invalid")

    local marker = "phase-safe-" .. tostring(nowStamp())
    task.tlibTest.persistenceMarker = marker
    saveTask()

    local loadedState = tlib.load()
    local loadedTask = loadedState and loadedState.taskState
    local loadedHarness = loadedTask and loadedTask.tlibTest
    assertTrue("ST-LOAD-01", loadedHarness and loadedHarness.persistenceMarker == marker,
        "Task state persisted through save/load", "Task state marker did not persist")

    tlib.scanInventory()
    local selectedSlotBefore = ccTurtle.getSelectedSlot()
    local missing, missingErr = tlib.selectItem("__tlib_missing_item__")
    assertTrue("INV-01", missing == false,
        "Missing item is correctly reported as unavailable", "Missing item unexpectedly resolved")
    assertTrue("INV-02", tostring(missingErr) ~= "",
        "Missing item returned a reason", "Missing item reason was empty")
    ccTurtle.select(selectedSlotBefore)

    local fuelCheck = tlib.ensureFuel(0)
    assertTrue("FUEL-01", fuelCheck == true,
        "ensureFuel(0) succeeds", "ensureFuel(0) returned false")

    local _, _, _, facingStart = tlib.getPosition()
    local trOk = tlib.turnRight()
    local _, _, _, facingRight = tlib.getPosition()
    local tlOk = tlib.turnLeft()
    local _, _, _, facingRestored = tlib.getPosition()
    assertTrue("TURN-01", trOk == true and tlOk == true,
        "Turn wrappers returned success", "Turn wrapper returned failure")
    assertTrue("TURN-02", facingRight == ((facingStart + 1) % 4),
        "turnRight updated facing", "turnRight facing update mismatch")
    assertTrue("TURN-03", facingRestored == facingStart,
        "turnLeft restored facing", "Facing did not restore after turnRight+turnLeft")

    local execSuccess = tlib.execute(function()
        return true
    end)
    assertTrue("EXEC-01", execSuccess == true,
        "execute returned true for healthy function", "execute did not return true for healthy function")

    local crashCaught = pcall(function()
        tlib.execute(function()
            error("intentional execute crash")
        end)
    end)
    assertTrue("EXEC-02", crashCaught == false,
        "execute rethrew crashes as expected", "execute did not propagate crash")

    if hasFunction("refreshHardwareState") then
        tlib.refreshHardwareState()
        assertTrue("HW-01", type(tlib.isWireless()) == "boolean",
            "Wireless flag is boolean", "Wireless flag type was invalid")
        assertTrue("HW-02", type(tlib.isChunkLoaded()) == "boolean",
            "Chunk loader flag is boolean", "Chunk loader flag type was invalid")
        assertTrue("HW-03", type(tlib.isGpsAvailable()) == "boolean",
            "GPS flag is boolean", "GPS flag type was invalid")
    else
        markSkip("HW-00", "refreshHardwareState unavailable on this tlib build")
    end
end

local function runRequirementsUiProbe()
    print("Running required-items UI probe...")

    local candidateNames = {
        "showProgramRequirementsUI",
        "showRequirementsUI",
        "programPreflightUI",
        "preflightRequirements",
        "ensureProgramRequirements"
    }

    local selectedName = nil
    for _, name in ipairs(candidateNames) do
        if hasFunction(name) then
            selectedName = name
            break
        end
    end

    if not selectedName then
        markSkip("REQ-UI-01", "No preflight requirements API found in tlib")
        return
    end

    local callOk, r1, r2 = pcall(tlib[selectedName], {
        title = "tlib self test requirements",
        requiresGps = true,
        requiresWireless = true,
        requiredItems = {
            { name = "minecraft:cobblestone", count = 4 },
            { name = "minecraft:coal", count = 1 }
        }
    })

    if not callOk then
        record("FAIL", "REQ-UI-02", "Requirements UI API crashed: " .. tostring(r1))
        return
    end

    local detail = string.format("API '%s' returned: %s / %s", selectedName, tostring(r1), tostring(r2))
    record("PASS", "REQ-UI-03", detail)
end

local function runOptionalDestructiveTests()
    if not test.allowDestructive then
        markSkip("DST-00", "Destructive movement tests disabled (set taskState.tlibTest.allowDestructive=true)")
        return
    end

    if not ccTurtle then
        markSkip("DST-ENV", "turtle API unavailable in current runtime")
        return
    end

    print("Running destructive movement/refuel tests...")

    local sx, sy, sz = tlib.getPosition()
    local movedForward, moveErr = tlib.forward()
    if movedForward then
        local movedBack, backErr = tlib.back()
        if movedBack then
            local ex, ey, ez = tlib.getPosition()
            assertTrue("DST-01", ex == sx and ey == sy and ez == sz,
                "Forward/back returned to original position", "Position mismatch after forward/back")
        else
            markWarn("DST-02", "Forward succeeded but back failed: " .. tostring(backErr))
        end
    else
        markWarn("DST-03", "forward() blocked or failed: " .. tostring(moveErr))
    end

    local movedUp, upErr = tlib.up()
    if movedUp then
        local movedDown, downErr = tlib.down()
        if movedDown then
            local ex, ey, ez = tlib.getPosition()
            assertTrue("DST-04", ex == sx and ey == sy and ez == sz,
                "Up/down returned to original position", "Position mismatch after up/down")
        else
            markWarn("DST-05", "up() succeeded but down() failed: " .. tostring(downErr))
        end
    else
        markWarn("DST-06", "up() blocked or failed: " .. tostring(upErr))
    end
end

local function runOptionalIntegrationTests()
    if not test.allowIntegration then
        markSkip("INT-00", "Integration tests disabled (set taskState.tlibTest.allowIntegration=true)")
        return
    end

    print("Running integration tests (GPS/Rednet)...")

    local bOk, bErr = tlib.broadcastStatus("tlib self-test integration ping")
    if bOk then
        record("PASS", "INT-01", "broadcastStatus completed")
    else
        markWarn("INT-01", "broadcastStatus unavailable/offline: " .. tostring(bErr))
    end

    local gpsSync = tlib.syncGPS()
    if gpsSync then
        record("PASS", "INT-02", "syncGPS succeeded")
    else
        markWarn("INT-02", "syncGPS unavailable or no signal")
    end

    local mOk, messages = tlib.checkOfflineMessages(nil)
    if mOk then
        record("PASS", "INT-03", "checkOfflineMessages returned " .. tostring(#messages) .. " message(s)")
    else
        markWarn("INT-03", "checkOfflineMessages unavailable/offline")
    end
end

local function printSummary()
    print("")
    if ccTerm and ccTerm.setTextColor and ccColors then
        ccTerm.setTextColor(ccColors.lightBlue)
    end
    print("=== tlib Self-Test Summary ===")
    resetColor()
    setColor(statusColors and statusColors.PASS)
    print("PASS: " .. tostring(test.counts.PASS))
    setColor(statusColors and statusColors.FAIL)
    print("FAIL: " .. tostring(test.counts.FAIL))
    setColor(statusColors and statusColors.SKIP)
    print("SKIP: " .. tostring(test.counts.SKIP))
    setColor(statusColors and statusColors.WARN)
    print("WARN: " .. tostring(test.counts.WARN))
    resetColor()
    print("Assertions logged: " .. tostring(#test.assertions))
    print("Phase: " .. tostring(test.phase))
    print("Completed: " .. tostring(test.completed))
    print("")
    print("Note: Summary-only failure policy is enabled.")
end

local function finalizeHarness()
    test.completed = true
    test.phase = "done"

    -- Clear resume target but preserve task state artifacts.
    tlib.registerProgram(nil)
    saveTask()
    printSummary()
end

local function persistFatalError(err)
    local message = tostring(err)
    local stack = message
    if debug and type(debug.traceback) == "function" then
        stack = debug.traceback(message, 2)
    end

    test.lastFatal = {
        at = nowStamp(),
        message = message,
        traceback = stack,
        phase = tostring(test.phase)
    }

    test.phase = "crashed"
    test.rebootRequested = false
    test.completed = false

    record("FAIL", "FATAL-UNCAUGHT", "Unhandled error persisted to task state")

    local ok, saveErr = pcall(saveTask)
    if not ok then
        ccPrintError("[FAIL] FATAL-SAVE - Unable to persist fatal error state: " .. tostring(saveErr))
    end

    ccPrintError("[FAIL] FATAL-UNCAUGHT - " .. message)
    if stack ~= message then
        ccPrintError(stack)
    end
end

local function requireErrorAcknowledgement()
    if type(ccRead) == "function" then
        print("")
        print("A fatal error occurred. Press Enter to continue...")
        ccRead()
    end
end

local function requireResultVerification(runOk)
    if type(ccRead) ~= "function" then
        return
    end

    print("")
    if runOk then
        print("Review complete. Press Enter to verify results and exit...")
    else
        print("Review fatal error details above. Press Enter to verify and exit...")
    end

    ccRead()
    test.userVerifiedAt = nowStamp()
    saveTask()
end

local function runHarness()
    if not test.completed then
        local resumeProgram = getResumeProgram()
        test.resumeProgram = resumeProgram
        test.resumeCommand = resumeProgram
        tlib.registerProgram(resumeProgram)
        saveTask()
    end

    if test.phase == "boot" then
        if test.rebootRequested and not test.rebootVerified and test.rebootToken then
            markWarn("RB-BOOT-RECOVER", "Recovered pending reboot checkpoint from boot phase")
            setPhase("post_reboot_verify")
        else
            print("Initializing tlib self-test harness...")
            promptTestOptions()
            setPhase("safe_tests")
        end
    end

    if test.phase == "safe_tests" then
        if test.rebootRequested and not test.rebootVerified and test.rebootToken then
            markWarn("RB-LOOP-GUARD", "Pending reboot checkpoint detected; skipping duplicate safe_tests")
            setPhase("post_reboot_verify")
            return
        end

        runSafeTests()
        local resumeProgram = test.resumeProgram or getResumeProgram()
        test.resumeProgram = resumeProgram
        test.resumeCommand = resumeProgram
        tlib.registerProgram(resumeProgram)
        test.rebootToken = "reboot-" .. tostring(nowStamp())
        test.rebootRequested = true
        setPhase("post_reboot_verify")

        local persistedState = tlib.load()
        local persistedProgram = persistedState and persistedState.currentProgram
        if not persistedProgram then
            record("FAIL", "RB-00", "Resume program was not persisted; skipping reboot")
            return
        end

        print("Reboot checkpoint armed. Rebooting now to verify resume behavior...")
        if rebootFn then
            ccSleep(1)
            rebootFn()
        else
            markWarn("RB-00", "os.reboot unavailable; skipping automatic reboot")
        end
    end

    if test.phase == "post_reboot_verify" then
        if test.rebootRequested and not test.rebootVerified and test.rebootToken then
            test.rebootVerified = true
            record("PASS", "RB-01", "Resumed after reboot checkpoint with persisted phase/token")
        else
            record("FAIL", "RB-01", "Reboot verification state was incomplete")
        end

        setPhase("requirements_ui")
    end

    if test.phase == "requirements_ui" then
        runRequirementsUiProbe()
        setPhase("destructive")
    end

    if test.phase == "destructive" then
        runOptionalDestructiveTests()
        setPhase("integration")
    end

    if test.phase == "integration" then
        runOptionalIntegrationTests()
        setPhase("finalize")
    end

    if test.phase == "finalize" then
        finalizeHarness()
    elseif test.phase == "done" then
        printSummary()
    elseif test.phase == "crashed" then
        markWarn("FATAL-STATE", "Harness is in crashed phase; review taskState.tlibTest.lastFatal")
        saveTask()
    end
end

local ok, err = xpcall(runHarness, function(e)
    persistFatalError(e)
    return e
end)

if not ok then
    requireErrorAcknowledgement()
    requireResultVerification(false)
    return false, err
end

requireResultVerification(true)
 