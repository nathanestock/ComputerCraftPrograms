local tlib = require("lib/turtle_helper")
tlib.registerProgram("programs/builder.lua")

local task = tlib.getTaskState()
if not task.initialized then
    task.initialized = true
    task.current_height = 0
    task.target_height = 5
    tlib.setTaskState(task)
end

while task.current_height < task.target_height do
    -- Find and select "cobblestone" (Cache checked first)
    local hasBlock, err = tlib.selectItem("minecraft:cobblestone")

    if hasBlock then
        -- Place block and move up
        turtle.placeDown()
        local success = tlib.up()
        if success then
            task.current_height = task.current_height + 1
            tlib.setTaskState(task)
            print("Built layer: " .. task.current_height)
        end
    else
        print("Out of Cobblestone! Waiting for reload... error: " .. tostring(err))
        sleep(5)
    end
end

print("Pillar complete!")
tlib.clearProgram()
 