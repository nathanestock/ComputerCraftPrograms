local plib = require("plib")

local settings = {
    minAltitude = 60,
    maxAltitude = 300,
    headingRange = 30, -- degrees left and right,
    hoverPower = 100,
}

-- Wrap peripherals using plib
local altitudeSensor = plib.wrap("altitudeSensor", "altitude_sensor")
local gimbalSensor = plib.wrap("gimbalSensor", "gimbal_sensor")
local velocitySensor = plib.wrap("velocitySensor", "velocity_sensor")
local navigationTable = plib.wrap("navigationTable", "navigation_table")
local altitudeThrottleLever = plib.wrap("altitudeThrottleLever", "throttle_lever")
local burnerFrontLeft = plib.wrap("frontLeftBurner", "hot_air_burner")
local burnerRelayFrontLeft = plib.wrap("frontLeftRelay", "redstone_relay")
local burnerFrontRight = plib.wrap("frontRightBurner", "hot_air_burner")
local burnerRelayFrontRight = plib.wrap("frontRightRelay", "redstone_relay")
local burnerRearLeft = plib.wrap("rearLeftBurner", "hot_air_burner")
local burnerRelayRearLeft = plib.wrap("rearLeftRelay", "redstone_relay")
local burnerRearRight = plib.wrap("rearRightBurner", "hot_air_burner")
local burnerRelayRearRight = plib.wrap("rearRightRelay", "redstone_relay")
local propellerLeft = plib.wrap("leftPropeller", "electric_motor")
local propellerRight = plib.wrap("rightPropeller", "electric_motor")
local forwardThrottleLever = plib.wrap("forwardThrottleLever", "throttle_lever")
local headingSteeringWheel = plib.wrap("headingSteeringWheel", "steering_wheel")
local monitor = plib.wrap("monitor", "monitor")
local reverseLeverRelay = plib.wrap("reverseLever", "redstone_relay")
local gyroscope1 = plib.wrap("gyro1", "electric_motor")
local gyroscope2 = plib.wrap("gyro2", "electric_motor")

local ship = {
    isRunning = false,
    autoPilot = false,

    -- Auto Pilot
    navigationTargetHeading = 0,
    navigationTargetDistance = 0,

    -- Telemetry
    currentAlt = 0,
    targetAltThrottle = 0,
    targetAlt = 0,
    vertSpeed = 0,
    airPressure = 0,
    pitch = 0,
    roll = 0,

    -- Trim Effort
    pitchTrimEffort = 0,
    rollTrimEffort = 0,

    -- Outputs
    burnerOutputs = { fl = 0, fr = 0, rl = 0, rr = 0 },
    gyroSpeed = 0,

    -- Propeller/Heading
    isReversed = false,
    forwardThrottle = 0, -- 0-100
    currentHeading = 0,
    targetHeading = 0,
    propSpeeds = { left = 0, right = 0 }
}

local altitudeStrategies = {
    height = function() return altitudeSensor.getHeight() end,
    sea_level = function()
        -- Assuming standard atmospheric pressure calculation:
        -- Pressure decreases as you go up. Adjust base/multiplier for your world.
        return (1013 - altitudeSensor.getAirPressure()) * 5
    end
}

local currentStrategy = "height" -- Can be switched via nav table

local function createPID(kp, ki, kd, maxIntegral)
    return {
        kp = kp,
        ki = ki,
        kd = kd,
        maxIntegral = maxIntegral,
        integral = 0,
        lastError = 0,
        update = function(self, target, current, rate, dt)
            local c = current or target
            local error = target - c
            -- Ensure rate is a number
            local derivative = rate or 0

            -- Only accumulate integral if we are close to the target (within 20 units)
            -- This prevents the "windup" while climbing from low altitudes
            if math.abs(error) < 20 then
                self.integral = math.max(-self.maxIntegral, math.min(self.maxIntegral, self.integral + (error * dt)))
            else
                self.integral = 0
            end

            return (error * self.kp) + (self.integral * self.ki) + (derivative * self.kd)
        end
    }
end

-- Constants for the mixer
local MAX_BURNER_POWER = 500

-- PID instances
local pidAltitude      = createPID(50, 0.1, 100, 50)
local pidPitch         = createPID(50, 0.5, 20, 50)
local pidRoll          = createPID(50, 0.5, 20, 50)

local function setBurnersEnabled(enabled) 
    if enabled then
        burnerRelayFrontLeft.setAllSides(true)
        burnerRelayFrontRight.setAllSides(true)
        burnerRelayRearLeft.setAllSides(true)
        burnerRelayRearRight.setAllSides(true)
        else
        burnerRelayFrontLeft.setAllSides(false)
        burnerRelayFrontRight.setAllSides(false)
        burnerRelayRearLeft.setAllSides(false)
        burnerRelayRearRight.setAllSides(false)
    end
end

local function setBurnerOutputs(altOut, pitchOut, rollOut)
    -- Normalize PID outputs:
    -- We map the PID output (which is just a raw number)
    -- to a relative contribution to the 0-500 burner range.

    local function clamp(val) return math.max(0, math.min(MAX_BURNER_POWER, val)) end

    local base = math.max(0, altOut)

    -- Mixing math
    local fl = base - pitchOut - rollOut
    local fr = base - pitchOut + rollOut
    local rl = base + pitchOut - rollOut
    local rr = base + pitchOut + rollOut

    local clampedFl = clamp(fl)
    local clampedFr = clamp(fr)
    local clampedRl = clamp(rl)
    local clampedRr = clamp(rr)

    burnerFrontLeft.setTargetAmount(clampedFl)
    burnerFrontRight.setTargetAmount(clampedFr)
    burnerRearLeft.setTargetAmount(clampedRl)
    burnerRearRight.setTargetAmount(clampedRr)

    ship.burnerOutputs.fl = clampedFl
    ship.burnerOutputs.fr = clampedFr
    ship.burnerOutputs.rl = clampedRl
    ship.burnerOutputs.rr = clampedRr
end

-- Threshold for when to kick in the gyro
local STABILITY_THRESHOLD = 5
local MIN_GYRO_SPEED = 100 -- Minimum speed to keep it useful
local ALTITUDE_DEADBAND = 8

local function burnerControllerLoop()
    local lastTime = os.epoch("utc")
    while true do
        local currentTime = os.epoch("utc")
        local dt = (currentTime - lastTime) / 1000
        lastTime = currentTime

        ship.isRunning = (ship.targetAltThrottle > 0)
        setBurnersEnabled(ship.isRunning)

        if ship.isRunning then
            local ang = gimbalSensor.getAnglesRad()
            local rates = gimbalSensor.getAngularRatesRad()

            if ang and rates and #rates >= 3 then
                local currentAlt = altitudeStrategies[currentStrategy]()
                local vSpeed = altitudeSensor.getVerticalSpeed() or 0
                local targetAlt = settings.minAltitude + (ship.targetAltThrottle / 15) * (settings.maxAltitude - settings.minAltitude)

                ship.currentAlt = currentAlt
                ship.targetAlt = targetAlt
                ship.vertSpeed = vSpeed
                ship.pitch = ang[1] or 0
                ship.roll = ang[2] or 0

                -- DEADZONE LOGIC
                local altError = (targetAlt - currentAlt) or 0
                local altOut = 0

                if math.abs(altError) < ALTITUDE_DEADBAND then
                    -- Inside deadband: stop PID accumulation, maintain hover throttle
                    -- We can add a slight proportional adjustment based on vertical speed to catch descent
                    altOut = settings.hoverPower - (vSpeed * 20)
                    pidAltitude.integral = 0 -- Reset PID to prevent accumulation
                else
                    -- Outside deadband: let PID handle the correction
                    altOut = pidAltitude:update(targetAlt, currentAlt, -vSpeed, dt)
                end

                -- Proceed with mixing (using the altOut calculated above)
                local pitchOut = pidPitch:update(0, ang[1], rates[1], dt)
                local rollOut = pidRoll:update(0, ang[2], rates[3], dt)

                ship.pitchTrimEffort = pitchOut
                ship.rollTrimEffort = rollOut

                -- Calculate stability effort (Average of the absolute PID outputs)
                -- We multiply by a sensitivity multiplier to ensure it reaches max speed faster
                local sensitivityMultiplier = 1.5
                local stabilityRequired = ((math.abs(pitchOut) + math.abs(rollOut)) / 2) * sensitivityMultiplier

                -- Calculate speed:
                -- We use math.max to ensure it never drops below MIN_GYRO_SPEED while the system is running
                local calculatedSpeed = (stabilityRequired / STABILITY_THRESHOLD) * 256
                ship.gyroSpeed = math.max(MIN_GYRO_SPEED, math.min(256, calculatedSpeed))

                gyroscope1.setSpeed(ship.gyroSpeed)
                gyroscope2.setSpeed(ship.gyroSpeed)

                setBurnerOutputs(altOut, pitchOut, rollOut)
            else
                -- Fallback if sensors aren't ready
                gyroscope1.setSpeed(0)
                gyroscope2.setSpeed(0)
                setBurnerOutputs(0, 0, 0)
                setBurnersEnabled(false)
            end
        else
            -- Engine off state
            ship.gyroSpeed = 0
            gyroscope1.setSpeed(0)
            gyroscope2.setSpeed(0)
            setBurnerOutputs(0, 0, 0)
        end
        sleep(0.05)
    end
end

local MAX_MOTOR_SPEED = 256

local function propellerControllerLoop()
    while true do
        -- Update current heading from navigation table
        ship.currentHeading = navigationTable.getHeading() or 0
        ship.horizontalSpeed = velocitySensor.getVelocity() or 0

        -- Check if reverse is toggled
        local dir = ship.isReversed and -1 or 1

        local baseSpeed = (ship.forwardThrottle / 100) * MAX_MOTOR_SPEED * dir
        local hInput = (ship.targetHeading / settings.headingRange)
        local turnOffset = hInput * MAX_MOTOR_SPEED

        -- Left is naturally inverted to be counter-rotating
        -- When reversing, both are inverted by the 'dir' variable
        local leftSpeed = -(baseSpeed + turnOffset)
        local rightSpeed = (baseSpeed - turnOffset)

        local function clamp(val)
            return math.max(-MAX_MOTOR_SPEED, math.min(MAX_MOTOR_SPEED, val))
        end

        ship.propSpeeds.left = clamp(leftSpeed)
        ship.propSpeeds.right = clamp(rightSpeed)

        propellerLeft.setSpeed(ship.propSpeeds.left)
        propellerRight.setSpeed(ship.propSpeeds.right)

        sleep(0.05)
    end
end

local function pilotInputLoop()
    while true do
        ship.targetAltThrottle = altitudeThrottleLever.getState() -- 0-15 scale
        ship.forwardThrottle = (forwardThrottleLever.getState() / 15) * 100
        ship.isReversed = reverseLeverRelay.getInput("top")

        ship.autoPilot = navigationTable.hasTarget()

        if ship.autoPilot then
            -- Get the bearing in degrees [-180, 180]
            local bearingDeg = navigationTable.getBearing()

            -- 1. Calculate absolute target heading (0 to 360)
            -- Adding currentHeading + bearingDeg, then wrapping.
            local absoluteTarget = (ship.currentHeading + bearingDeg) % 360

            -- 2. Ensure it is positive (Lua's % operator on negative numbers can be tricky)
            if absoluteTarget < 0 then
                absoluteTarget = absoluteTarget + 360
            end

            ship.navigationTargetHeading = absoluteTarget
            ship.navigationTargetDistance = navigationTable.getDistanceToTarget() or 0

            -- if distance to target is < 20, set the throttle lever to 0 to stop the ship and set target heading to 0
            if ship.navigationTargetDistance < 20 then
                forwardThrottleLever.setSignal(0)
                ship.forwardThrottle = 0
                ship.targetHeading = 0
            else
                -- 3. Steering logic (mapping -180/180 to -1/1)
                -- Using math.clamp (or your min/max logic) to steer based on the bearing
                local targetSteer = math.max(-1, math.min(1, bearingDeg / settings.headingRange))
                ship.targetHeading = targetSteer * settings.headingRange
            end
        else
            -- Map steering wheel input
            local hInput = headingSteeringWheel.getNormalizedAngle()
            ship.targetHeading = hInput * settings.headingRange
        end

        sleep(0.1)
    end
end

local function monitorLoop()
    monitor.setTextScale(0.5)
    monitor.setBackgroundColor(colors.black)

    local col1, col2, col3 = 1, 24, 45

    while true do
        monitor.clear()

        local function draw(x, y, text, color)
            monitor.setCursorPos(x, y)
            monitor.setTextColor(color or colors.white)
            monitor.write(text)
        end

        -- Column 1: Core Systems
        local mode = (ship.isRunning and ship.autoPilot and "AUTO") or (ship.isRunning and "RUNNING") or "IDLE"
        local modeColor = (mode == "AUTO") and colors.yellow or (ship.isRunning and colors.lime or colors.gray)
        draw(col1, 1, mode, modeColor)
        draw(col1, 2, string.format("BF: %d %d", ship.burnerOutputs.fl, ship.burnerOutputs.fr), colors.red)
        draw(col1, 3, string.format("BR: %d %d", ship.burnerOutputs.rl, ship.burnerOutputs.rr), colors.red)
        draw(col1, 4, string.format("P: %d %d", ship.propSpeeds.left, ship.propSpeeds.right), colors.white)
        draw(col1, 5, string.format("REV: %s", ship.isReversed and "ON" or "OFF"),
            ship.isReversed and colors.orange or colors.gray)

        -- Column 2: Navigation & Orientation
        -- ALT (Light Blue) / Target (Gray)
        draw(col2, 1, string.format("ALT: %d", ship.currentAlt), colors.cyan)
        draw(col2 + 9, 1, string.format("/ %d", ship.targetAlt), colors.gray)

        -- HDG (Cyan) / Target (Gray)
        draw(col2, 2, string.format("HDG: %d", ship.currentHeading), colors.lime)
        draw(col2 + 9, 2, string.format("/ %.1f", ship.targetHeading), colors.gray)

        draw(col2, 3, string.format("P:%.1f R:%.1f", ship.pitch, ship.roll), colors.white)

        if ship.autoPilot then
            draw(col2, 4, string.format("NAV: %d", ship.navigationTargetHeading), colors.yellow)
            draw(col2, 5, string.format("DST: %d", ship.navigationTargetDistance), colors.yellow)
        end

        -- Column 3: Dynamics & Trim
        draw(col3, 1, string.format("HSPD: %.1f", ship.horizontalSpeed), colors.yellow)
        draw(col3, 2, string.format("VSPD: %.1f", ship.vertSpeed), colors.yellow)
        draw(col3, 3, string.format("PT: %.1f", ship.pitchTrimEffort), colors.white)
        draw(col3, 4, string.format("RT: %.1f", ship.rollTrimEffort), colors.white)
        draw(col3, 5, string.format("GYRO: %d", ship.gyroSpeed), colors.white)
        draw(col3, 6, string.format("THR: %d", ship.forwardThrottle), colors.blue)

        sleep(0.2)
    end
end

-- Use parallel to run all loops simultaneously
parallel.waitForAny(
    pilotInputLoop,
    burnerControllerLoop,
    propellerControllerLoop,
    monitorLoop,
    function() 
        while true do
            -- Keepalive/Safety check
            sleep(1)
        end
    end)