# tlib Programming Guide (Strict Contract)

This guide defines the required architecture for all new programs built on tlib.

If a program is expected to survive reboots and resume safely, it MUST follow this contract.

## 1. Core Contract

Every resumable program MUST:

1. Load persisted state at program start.
2. Keep all program-specific state in a namespaced table under taskState.
3. Register itself as the active resumable program before critical work.
4. Persist phase transitions immediately.
5. Persist reboot checkpoints before calling reboot.
6. Verify reboot checkpoints after restart.
7. Clear resume state on successful completion.

Programs MUST NOT rely on in-memory variables for progress tracking across reboot boundaries.

## 2. Mandatory Lifecycle Call Order

Use this sequence in all resumable programs:

1. tlib.load()
2. local task = tlib.getTaskState()
3. Ensure your namespace exists, for example task.myProgram
4. tlib.registerProgram("my_program")
5. Run phase machine:
   - mutate phase state
   - immediately persist with tlib.setTaskState(task)
6. Before reboot:
   - set checkpoint token and flags in task state
   - persist with tlib.setTaskState(task)
   - ensure program is still registered with tlib.registerProgram("my_program")
   - call os.reboot()
7. After reboot:
   - verify checkpoint token and flags
   - mark checkpoint verified
   - persist state
8. On success:
   - call tlib.completeProgram(false) or tlib.completeProgram(true) to trigger a reboot

## 2.1 Startup Hook Requirement

Resume orchestration depends on tlib startup execution.

Deployments MUST install the startup hook at least once:

- tlib install

This writes startup.lua that invokes tlib.startup(), which restores resume targets and falls back to the dashboard when no resume target exists.

## 3. State Model Requirements

Each program MUST keep its data under a dedicated key to avoid collisions.

Example namespace layout:

```lua
local task = tlib.getTaskState() or {}
task.myProgram = task.myProgram or {
    version = 1,
    phase = "boot",
    rebootToken = nil,
    rebootRequested = false,
    rebootVerified = false,
    completed = false,
    updatedAt = os.time()
}
```

Minimum required fields for reboot checkpoints:

- phase
- rebootToken
- rebootRequested
- rebootVerified
- completed

Programs SHOULD include version for future migrations.

## 4. Phase Machine Pattern (Required)

Programs MUST use explicit phases and MUST save on every phase transition.

Required helper pattern:

```lua
local function saveTask(task)
    task.myProgram.updatedAt = os.time()
    tlib.setTaskState(task)
end

local function setPhase(task, nextPhase)
    task.myProgram.phase = nextPhase
    saveTask(task)
end
```

Rules:

- All transitions MUST go through setPhase.
- Any token/flag mutation related to reboot MUST be saved before reboot.
- Crash handlers SHOULD persist fatal context into task state for diagnostics.

## 5. Mandatory Wrapper APIs

### 5.1 Movement and Orientation

Programs MUST use the tlib wrappers below, not native turtle movement calls.

Required wrappers:

- tlib.forward()
- tlib.back()
- tlib.up()
- tlib.down()
- tlib.turnLeft()
- tlib.turnRight()

Why this is mandatory:

- tlib updates tracked coordinates and facing.
- tlib persists movement state.
- tlib handles obstruction retries and broadcasts critical movement failures.

Forbidden in resumable movement logic:

- turtle.forward()
- turtle.back()
- turtle.up()
- turtle.down()
- turtle.turnLeft()
- turtle.turnRight()

### 5.2 Fuel and Inventory

Programs SHOULD use:

- tlib.ensureFuel(needed)
- tlib.scanInventory()
- tlib.selectItem(name)
- tlib.equip(name, preferredSide)

Do not bypass chunk-loader lock policy by calling raw equip logic in custom code.

### 5.3 Program Execution and Error Handling

Programs SHOULD run top-level logic through:

- tlib.execute(function() ... end)

This ensures crashes are surfaced and status can be reported.

### 5.4 GPS and Comms

Programs that use location/comms SHOULD use:

- tlib.syncGPS()
- tlib.calibrateGPS()
- tlib.broadcastStatus(status, isError)
- tlib.sendStatus(targetId, status, isError)
- tlib.checkOfflineMessages(mailboxServerId)

These APIs use modem transaction handling and hardware constraints already encoded in tlib.

## 6. Reboot Checkpoint Pattern (Required)

Before reboot, programs MUST arm a checkpoint:

```lua
local p = task.myProgram
p.rebootToken = "rb-" .. tostring(os.time())
p.rebootRequested = true
p.rebootVerified = false
setPhase(task, "post_reboot_verify")
tlib.registerProgram("my_program")
os.reboot()
```

After restart, verification MUST happen before continuing:

```lua
local p = task.myProgram
if p.rebootRequested and not p.rebootVerified and p.rebootToken then
    p.rebootVerified = true
    saveTask(task)
else
    -- handle missing/incomplete checkpoint as failure path
end
```

## 7. Program Completion and Cleanup

On successful completion, programs MUST clear resumable metadata:

- Use tlib.completeProgram(false) if no reboot is needed.
- Use tlib.completeProgram(true) to clear state and reboot immediately.

Programs MUST NOT leave stale currentProgram or resumeCommand values after normal completion.

## 8. Anti-Patterns (Do Not Do These)

1. Direct native movement calls in resumable logic.
2. Mutating task state without calling tlib.setTaskState(task).
3. Rebooting without persisted phase/token flags.
4. Running critical phases without calling tlib.registerProgram first.
5. Ending successfully without tlib.completeProgram(...).

Dashboard launch caveat:

- If a program is launched manually from the dashboard and the program does not call tlib.registerProgram(...), reboot resume is not guaranteed.
- Every resumable script MUST self-register in its own run path regardless of how it is launched.

## 9. Minimal Starter Skeleton

```lua
local tlib = require("tlib")

tlib.load()
local task = tlib.getTaskState() or {}

task.myProgram = task.myProgram or {
    version = 1,
    phase = "boot",
    rebootToken = nil,
    rebootRequested = false,
    rebootVerified = false,
    completed = false,
    updatedAt = os.time()
}

local function saveTask()
    task.myProgram.updatedAt = os.time()
    tlib.setTaskState(task)
end

local function setPhase(nextPhase)
    task.myProgram.phase = nextPhase
    saveTask()
end

local function run()
    tlib.registerProgram("my_program")

    if task.myProgram.phase == "boot" then
        -- safe setup only
        setPhase("work")
    end

    if task.myProgram.phase == "work" then
        -- use only tlib movement wrappers
        local ok, err = tlib.forward()
        if not ok then
            error("forward failed: " .. tostring(err))
        end
        setPhase("finalize")
    end

    if task.myProgram.phase == "finalize" then
        task.myProgram.completed = true
        saveTask()
        tlib.completeProgram(false)
    end
end

tlib.execute(run)
```

## 10. Author Verification Checklist

Before shipping a new program, verify all checks pass:

1. Program resumes correctly after forced reboot in at least one mid-phase checkpoint.
2. Program uses only tlib movement/turn wrappers.
3. Every phase transition persists state.
4. Reboot checkpoint token and flags are persisted before reboot.
5. Completion clears resume metadata via tlib.completeProgram.
6. Crash path preserves enough task-state context to debug and recover.

## 11. Reference Implementation

Use test.lua as the canonical example of:

- task-state namespacing
- phase-driven orchestration
- reboot checkpoint arming and verification
- summary/finalization workflow

Use tlib.lua as the source of truth for wrapper behavior and startup resume orchestration.
