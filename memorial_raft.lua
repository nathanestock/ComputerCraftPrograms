local config = {
    speed = 8,          -- Rotational speed of the electric motor
    baseSignal = 4,     -- The default redstone signal (0-15) for straight travel
    turningRatio = 1, -- The offset to add/subtract for steering
    leftPropSide = "left",
    rightPropSide = "right",
}

local plib = require("plib")

local motor = plib.wrap("motor", "electric_motor")
local redstone_relay = plib.wrap("redstone_relay", "redstone_relay")

-- Helper to ensure signals stay within 0-15
local function clamp(val)
    return math.max(0, math.min(15, math.floor(val)))
end

-- Initialize motor speed
motor.setSpeed(config.speed)

print("Raft active. Traveling in a clockwise circle...")

while true do
    -- Calculate raw signals
    local leftSignalRaw = config.baseSignal + config.turningRatio
    local rightSignalRaw = config.baseSignal - config.turningRatio

    -- Apply clamping
    local leftSignal = clamp(leftSignalRaw)
    local rightSignal = clamp(rightSignalRaw)

    -- Apply the signals
    redstone_relay.setAnalogOutput(config.leftPropSide, leftSignal)
    redstone_relay.setAnalogOutput(config.rightPropSide, rightSignal)

    -- Print current signals
    print(string.format("Signals -> Left: %d, Right: %d", leftSignal, rightSignal))

    -- Keep the loop alive
    os.sleep(0.5)
end
