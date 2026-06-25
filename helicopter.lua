local plib = require("plib")

-- Configurable Settings
local settings = {
    hoverBasePower = 150, -- Base speed required to fight gravity
    gyroActiveSpeed = 256,
    inputRampSpeed = 1.5, -- How fast controls reach 100% (seconds)
}

-- Peripherals
local altitudeSensor = plib.wrap("altitudeSensor", "altitude_sensor")
local mainRotor = plib.wrap("mainRotor", "Create_RotationSpeedController")
local mainRotorMotor1 = plib.wrap("mainRotorMotor1", "electric_motor")
local mainRotorMotor2 = plib.wrap("mainRotorMotor2", "electric_motor")
local gyroMotor = plib.wrap("gyro", "electric_motor")
local propellerLeft = plib.wrap("leftPropeller", "electric_motor")
local propellerRight = plib.wrap("rightPropeller", "electric_motor")
local monitor = plib.wrap("monitor", "monitor")
local gimbal = plib.wrap("gimbal", "gimbal_sensor")
local typewriter = plib.wrap("typewriter", "linked_typewriter")
local navigationTable = plib.wrap("navigationTable", "navigation_table")
local enableLever = plib.wrap("enableLever","redstone_relay")

-- State Variables
local ship = {
    enabled = false,         -- Master enable switch
    altitude = 0,            -- Current altitude from sensor
    heading = 0,             -- 0 to 360 degrees
    rotorSpeed = 0,          -- 0 to 256
    leftPropellerSpeed = 0,  -- 0 to 100%
    rightPropellerSpeed = 0, -- 0 to 100%
    pitch = 0,               -- degrees, positive is forward
    roll = 0,                -- degrees, positive is right
}

local pilot = {
    altitudeTarget = 0, -- Target altitude in blocks
    headingTarget = 0,  -- 0 to 360 degrees
    thrustTarget = 0,   -- -100% to 100% for forward/backward
}

local function createPID(kp, ki, kd, maxInt)
    return {
        kp = kp,
        ki = ki,
        kd = kd,
        maxInt = maxInt,
        integral = 0,
        lastError = 0,
        update = function(self, target, current, dt)
            local error = target - current
            self.integral = math.max(-self.maxInt, math.min(self.maxInt, self.integral + error * dt))
            local derivative = (error - self.lastError) / dt
            self.lastError = error
            return (error * self.kp) + (self.integral * self.ki) + (derivative * self.kd)
        end,
        reset = function(self)
            self.integral = 0
            self.lastError = 0
        end
    }
end

local function getNormalizedHeading()
    local heading = navigationTable.getHeading() or 0
    -- Convert atan2 (-180 to 180) to (0 to 360)
    if heading < 0 then
        heading = heading + 360
    end
    return heading
end

-- Pull flight data from sensors continuously
local function shipSensorLoop()
    while true do
        ship.enabled = enableLever.getInput("bottom")

        ship.altitude = altitudeSensor.getHeight() or 0
        local gimbalData = gimbal.getAngles()
        ship.pitch = gimbalData[2] or 0
        ship.roll = gimbalData[1] or 0
        ship.heading = getNormalizedHeading()

        sleep(0.01)
    end
end

-- Key Definitions (GLFW Codes)
local KEY = {
    W = keys.w,
    S = keys.s,
    A = keys.a,
    D = keys.d,
    SPACE = keys.space,
    LSHIFT = keys.leftShift,
    TAB = keys.tab,
}

local heldKeys = {}

-- Process pilot input and update target states
local function processPilotInput(dt)
    -- Altitude Control
    if heldKeys[KEY.SPACE] then
        pilot.altitudeTarget = pilot.altitudeTarget + 1 * dt
    elseif heldKeys[KEY.LSHIFT] then
        pilot.altitudeTarget = pilot.altitudeTarget - 1 * dt
    end

    -- Zero Altitude and Heading targets
    if heldKeys[KEY.TAB] then
        pilot.altitudeTarget = ship.altitude
        pilot.headingTarget = ship.heading
    end

    -- Heading Control
    if heldKeys[KEY.A] then
        pilot.headingTarget = (pilot.headingTarget + 5 * dt) % 360
    elseif heldKeys[KEY.D] then
        pilot.headingTarget = (pilot.headingTarget - 5 * dt) % 360
    end

    -- Thrust Control
    if heldKeys[KEY.W] then
        pilot.thrustTarget = math.min(100, pilot.thrustTarget + 50 * dt)
    elseif heldKeys[KEY.S] then
        pilot.thrustTarget = math.max(-100, pilot.thrustTarget - 50 * dt)
    else
        -- Auto-leveling when no forward/backward input
        if math.abs(pilot.thrustTarget) > 0 then
            local decay = 100 * dt
            if pilot.thrustTarget > 0 then
                pilot.thrustTarget = math.max(0, pilot.thrustTarget - decay)
            else
                pilot.thrustTarget = math.min(0, pilot.thrustTarget + decay)
            end
        end
    end
end

-- Listen for pilot input
local function typewriterEventListener()
    while true do
        local event, key, held = os.pullEvent()
        if event == "key" then
            heldKeys[key] = true
        elseif event == "key_up" then
            heldKeys[key] = false
        end

        processPilotInput(0.1) -- Process input every key event with a small delta time
    end
end

local altitudePID = createPID(5.0, 0.1, 2.0, 100)
local headingPID = createPID(0.8, 0.001, 0.6, 20)

-- Main Flight Logic
local function flightControllerLoop()
    while true do
        if ship.enabled then
            -- Activate gyro for stabilization and main rotor motors
            gyroMotor.setSpeed(settings.gyroActiveSpeed)
            mainRotorMotor1.setSpeed(256)
            mainRotorMotor2.setSpeed(-256)

            -- Calculate Altitude Correction
            local dt = 0.1
            local altError = pilot.altitudeTarget - ship.altitude
            local pidOutput = altitudePID:update(pilot.altitudeTarget, ship.altitude, dt)

            -- Combine base hover power with PID output
            -- The maxRotorSpeed (256) is our ceiling
            local targetSpeed = settings.hoverBasePower + pidOutput
            ship.rotorSpeed = math.max(0, math.min(256, targetSpeed))

            -- Apply to Main Rotor
            mainRotor.setTargetSpeed(ship.rotorSpeed)

            -- Heading Control
            local rawError = pilot.headingTarget - ship.heading
            local shortestPathError = (rawError + 180) % 360 - 180
            local headingCorrection = headingPID:update(0, -shortestPathError, dt)

            -- Thrust Control (Forward/Backward)
            local thrust = pilot.thrustTarget / 100 * 256 -- Scale to motor speed
            ship.leftPropellerSpeed = math.max(-256, math.min(256, thrust - headingCorrection))
            propellerLeft.setSpeed(-ship.leftPropellerSpeed)
            ship.rightPropellerSpeed = math.max(-256, math.min(256, thrust + headingCorrection))
            propellerRight.setSpeed(ship.rightPropellerSpeed)
        else
            -- Shutdown
            mainRotor.setTargetSpeed(0)
            mainRotorMotor1.setSpeed(0)
            mainRotorMotor2.setSpeed(0)
            gyroMotor.setSpeed(0)
            propellerLeft.setSpeed(0)
            propellerRight.setSpeed(0)

            -- Reset PID controllers
            altitudePID:reset()
            headingPID:reset()
        end
        
        sleep(0.01)
    end
end

-- Simple Monitor UI
local function monitorLoop()
    while true do
        monitor.clear()
        monitor.setCursorPos(1, 1)
        if ship.enabled then
            monitor.write(string.format("ALT: %d / TGT: %d", ship.altitude, pilot.altitudeTarget))
            monitor.setCursorPos(1, 2)
            monitor.write(string.format("HDG: %d / TGT: %d", ship.heading, pilot.headingTarget))
            monitor.setCursorPos(1, 3)
            monitor.write(string.format("ROTOR: %d | THRUST: %d", ship.rotorSpeed, pilot.thrustTarget))
            monitor.setCursorPos(1, 4)
            monitor.write(string.format("PITCH: %d%% ROLL: %d%%", ship.pitch, ship.roll))
            monitor.setCursorPos(1, 5)
            monitor.write(string.format("PROPS L: %d R: %d", ship.leftPropellerSpeed, ship.rightPropellerSpeed))
        else
            monitor.write("OFF")
        end
        
        sleep(0.1)
    end
end

parallel.waitForAny(shipSensorLoop, typewriterEventListener, monitorLoop, flightControllerLoop)
