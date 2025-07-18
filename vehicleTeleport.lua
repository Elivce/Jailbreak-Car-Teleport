-- Jailbreak Teleport Script (Optimized)
-- Fixes player body whitelisting and pathfinding issues

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local PathfindingService = game:GetService("PathfindingService")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

-- Main variables
local Player = Players.LocalPlayer
local Teleporting = false
local StopVelocity = false

-- Module dependencies
local Modules = {
    UI = require(ReplicatedStorage.Module.UI),
    Store = require(ReplicatedStorage.App.store),
    PlayerUtils = require(ReplicatedStorage.Game.PlayerUtils),
    VehicleData = require(ReplicatedStorage.Game.Garage.VehicleData),
    CharacterUtil = require(ReplicatedStorage.Game.CharacterUtil),
    Paraglide = require(ReplicatedStorage.Game.Paraglide)
}

-- Configuration
local Config = {
    UpVector = Vector3.new(0, 300, 0),
    PlayerSpeed = 120,
    VehicleSpeed = 400,
    MaxTeleportHeight = 500,
    MinClearanceHeight = 50,
    PathfindingWaypointSpacing = 3
}

-- Vehicle classifications
local Vehicles = {
    Helicopters = { Heli = true },
    Motorcycles = { Volt = true },
    FreeVehicles = { Camaro = true },
    Unsupported = { SWATVan = true, Celestial = true }
}

-- Initialize raycast parameters
local RaycastParams = RaycastParams.new()
RaycastParams.FilterType = Enum.RaycastFilterType.Blacklist
RaycastParams.FilterDescendantsInstances = {}

-- Cache for door positions
local DoorPositions = {}

--[[
    Utility Functions
]]
local function getServerHash()
    for _, child in pairs(game:GetService("ReplicatedStorage"):GetChildren()) do
        if select(2, string.gsub(child.Name, "%-", "")) == 4 then
            return child.Name
        end
    end
    return nil
end

-- Gets Hidden Hashes
local function getEventValue(key)
    local EventTable = (function()
        for i, v in ipairs(getgc(false)) do
            if typeof(v) == "function" and islclosure(v) and debug.info(v, "n") == "EventFireServer" then
                local upvalues = debug.getupvalues(v)
                if typeof(upvalues[3]) == "table" then
                    return upvalues[3]
                end
            end
        end
    end)()
    return EventTable and EventTable[key]
end

local function teamMenu()
    local serverHash = getServerHash()
    local switchHash = getEventValue("jwfcps55")
    local args = {
        [1] = switchHash
    }
    game:GetService("ReplicatedStorage"):FindFirstChild(serverHash):FireServer(unpack(args))
end

-- Select Team
local function selectTeam(team)
    local serverHash = getServerHash()
    local prisonerHash = getEventValue("mto4108g")
    local args = {
        [1] = prisonerHash,
        [2] = team,
    }
    game:GetService("ReplicatedStorage"):FindFirstChild(serverHash):FireServer(unpack(args))
end

local function UpdateRaycastFilter()
    local filterList = { workspace.Vehicles }
    
    -- Add weather objects
    for _, name in ipairs({"Rain", "Snow", "Hail", "Fog", "Storm", "Clouds"}) do
        local weather = workspace:FindFirstChild(name)
        if weather then table.insert(filterList, weather) end
    end
    
    -- Add all non-collidable player parts
    if Player.Character then
        for _, part in ipairs(Player.Character:GetDescendants()) do
            if part:IsA("BasePart") and part.CanCollide == false then
                table.insert(filterList, part)
            end
        end
        -- Ensure critical parts are always included
        local criticalParts = {"Head", "HumanoidRootPart", "UpperTorso", "LowerTorso"}
        for _, name in ipairs(criticalParts) do
            local part = Player.Character:FindFirstChild(name)
            if part and not table.find(filterList, part) then
                table.insert(filterList, part)
            end
        end
    end
    
    RaycastParams.FilterDescendantsInstances = filterList
end

local function IsPositionClear(position)
    -- First check if there's immediate clearance above
    local immediateCheck = workspace:Raycast(
        position,
        Vector3.new(0, Config.MinClearanceHeight, 0),
        RaycastParams
    )
    
    if not immediateCheck then return true end
    
    -- Then check full height if needed
    local fullCheck = workspace:Raycast(
        position,
        Config.UpVector,
        RaycastParams
    )
    
    return not fullCheck
end

local function ToggleDoorCollision(door, state)
    if door and door:FindFirstChild("Model") then
        for _, part in ipairs(door.Model:GetDescendants()) do
            if part:IsA("BasePart") then
                part.CanCollide = state
            end
        end
    end
end

local function GetNearestVehicle(tried)
    local nearest, minDistance = nil, math.huge
    tried = tried or {}

    for _, action in pairs(Modules.UI.CircleAction.Specs) do
        if action.IsVehicle and action.ShouldAllowEntry and action.Enabled and action.Name == "Enter Driver" then
            local vehicle = action.ValidRoot
            
            if not table.find(tried, vehicle) and workspace.VehicleSpawns:FindFirstChild(vehicle.Name) then
                if not Vehicles.Unsupported[vehicle.Name] and 
                   (Modules.Store._state.garageOwned.Vehicles[vehicle.Name] or Vehicles.FreeVehicles[vehicle.Name]) and 
                   not vehicle.Seat.Player.Value then
                    
                    if IsPositionClear(vehicle.Seat.Position) then
                        local distance = (vehicle.Seat.Position - Player.Character.HumanoidRootPart.Position).Magnitude
                        
                        if distance < minDistance then
                            minDistance = distance
                            nearest = action
                        end
                    end
                end
            end
        end
    end

    return nearest
end

local function IsInVehicle()
    if not Player.Character then return false end
    local humanoid = Player.Character:FindFirstChildOfClass("Humanoid")
    return humanoid and humanoid.SeatPart and humanoid.SeatPart:FindFirstAncestorOfClass("Model")
end

--[[
    Movement Functions
]]

local function MoveToPosition(part, targetCFrame, speed, isVehicle, targetVehicle, triedVehicles)
    local targetPos = targetCFrame.Position
    local currentSpeed = (IsInVehicle() or isVehicle) and Config.VehicleSpeed or speed
    
    -- Check if we need pathfinding (only if not in vehicle and position isn't clear)
    if not isVehicle and not IsPositionClear(part.Position) then
        FindClearPosition()
        task.wait(0.2)
    end
    
    -- Calculate sky position
    local skyPosition = Vector3.new(targetPos.X, Config.MaxTeleportHeight, targetPos.Z)
    
    -- Move to sky position
    repeat
        local direction = (skyPosition - part.Position).Unit * currentSpeed
        part.Velocity = Vector3.new(direction.X, 0, direction.Z)
        part.CFrame = CFrame.new(part.Position.X, Config.MaxTeleportHeight, part.Position.Z)
        task.wait()
        
        -- Handle vehicle takeover cases
        if targetVehicle and targetVehicle.Seat.Player.Value then
            table.insert(triedVehicles or {}, targetVehicle)
            local newVehicle = GetNearestVehicle(triedVehicles)
            local vehicleObj = newVehicle and newVehicle.ValidRoot
            
            if vehicleObj then 
                MoveToPosition(Player.Character.HumanoidRootPart, vehicleObj.Seat.CFrame, Config.PlayerSpeed, false, vehicleObj)
            end
            return
        end
    until (part.Position - skyPosition).Magnitude < 10
    
    -- Descend to target
    part.CFrame = CFrame.new(part.Position.X, targetPos.Y, part.Position.Z)
    part.Velocity = Vector3.zero
end

local function FindClearPosition()
    -- Instead of pathfinding, we will use the team selection functions
    teamMenu()
    wait(2)  -- Wait for the team menu to process
    selectTeam("Prisoner")  -- Select the desired team
    return true  -- Indicate that we have "found" a clear position
end

--[[
    Anti-Cheat Bypasses
]]

-- No fall damage/ragdoll bypass
local originalIsPointInTag = Modules.PlayerUtils.isPointInTag
Modules.PlayerUtils.isPointInTag = function(point, tag)
    if Teleporting and (tag == "NoRagdoll" or tag == "NoFallDamage") then
        return true
    end
    return originalIsPointInTag(point, tag)
end

-- Anti skydive bypass
local originalIsFlying = Modules.Paraglide.IsFlying
Modules.Paraglide.IsFlying = function(...)
    if Teleporting and debug.info(2, "s").source:find("Falling") then
        return true
    end
    return originalIsFlying(...)
end

-- Velocity control
task.spawn(function()
    while task.wait() do
        if StopVelocity and Player.Character and Player.Character:FindFirstChild("HumanoidRootPart") then
            Player.Character.HumanoidRootPart.Velocity = Vector3.zero
        end
    end
end)

--[[
    Initialization
]]

-- Initialize vehicle classifications
for _, vehicle in pairs(Modules.VehicleData) do
    if vehicle.Type == "Heli" then
        Vehicles.Helicopters[vehicle.Make] = true
    elseif vehicle.Type == "Motorcycle" then
        Vehicles.Motorcycles[vehicle.Make] = true
    end

    if vehicle.Type ~= "Chassis" and vehicle.Type ~= "Motorcycle" and 
       vehicle.Type ~= "Heli" and vehicle.Type ~= "DuneBuggy" and vehicle.Make ~= "Volt" then
        Vehicles.Unsupported[vehicle.Make] = true
    end
    
    if not vehicle.Price then
        Vehicles.FreeVehicles[vehicle.Make] = true
    end
end

-- Cache door positions
for _, door in ipairs(workspace:GetDescendants()) do
    if door.Name:sub(-4) == "Door" then 
        local touchPart = door:FindFirstChild("Touch")
        
        if touchPart and touchPart:IsA("BasePart") then
            for distance = 5, 100, 5 do 
                local forwardPos = touchPart.Position + touchPart.CFrame.LookVector * (distance + 3)
                local backwardPos = touchPart.Position + touchPart.CFrame.LookVector * -(distance + 3)
                
                if IsPositionClear(forwardPos) then
                    table.insert(DoorPositions, {
                        instance = door,
                        position = forwardPos
                    })
                    break
                elseif IsPositionClear(backwardPos) then
                    table.insert(DoorPositions, {
                        instance = door,
                        position = backwardPos
                    })
                    break
                end
            end
        end
    end
end

-- Update filters when character changes
Player.CharacterAdded:Connect(function(character)
    UpdateRaycastFilter()
    
    character.ChildAdded:Connect(function(child)
        if child:IsA("BasePart") then
            UpdateRaycastFilter()
        end
    end)
end)

-- Initial filter update
UpdateRaycastFilter()

--[[
    Main Teleport Function
]]

return function(targetCFrame, triedVehicles)
    -- Wait for character if needed
    local Character = Player.Character or Player.CharacterAdded:Wait()
    if not Character or not Character:FindFirstChild("HumanoidRootPart") then
        return
    end

    -- Ultra-reliable vehicle check with multiple fallbacks
    local inVehicle = false
    local currentVehicle = nil
    local humanoid = Character:FindFirstChildOfClass("Humanoid")
    
    if Character:FindFirstChild("InVehicle") then
        inVehicle = true
        if humanoid and humanoid.SeatPart then
            currentVehicle = humanoid.SeatPart:FindFirstAncestorWhichIsA("Model")
        end
    elseif humanoid and humanoid.SeatPart then
        -- Fallback check for games where InVehicle doesn't exist
        inVehicle = true
        currentVehicle = humanoid.SeatPart:FindFirstAncestorWhichIsA("Model")
    end

    local rootPart = Character.HumanoidRootPart
    local distance = (targetCFrame.Position - rootPart.Position).Magnitude
    Teleporting = true
    triedVehicles = triedVehicles or {}

    if not inVehicle then
        -- Vehicle entry logic
        local nearestVehicle = GetNearestVehicle(triedVehicles)
        local vehicleObj = nearestVehicle and nearestVehicle.ValidRoot

        if vehicleObj and vehicleObj:FindFirstChild("Seat") then
            -- Approach vehicle
            MoveToPosition(rootPart, vehicleObj.Seat.CFrame, Config.PlayerSpeed, false, vehicleObj, triedVehicles)

            -- Attempt to enter vehicle
            StopVelocity = true
            local attempts = 0
            repeat
                if nearestVehicle and nearestVehicle.Callback then
                    nearestVehicle:Callback(true)
                end
                attempts = attempts + 1
                task.wait(0.1)
                -- Update vehicle status using multiple methods
                inVehicle = Character:FindFirstChild("InVehicle") or 
                          (humanoid and humanoid.SeatPart ~= nil)
            until attempts >= 10 or inVehicle

            StopVelocity = false

            if inVehicle then
                -- Successfully entered - update current vehicle
                if humanoid and humanoid.SeatPart then
                    currentVehicle = humanoid.SeatPart:FindFirstAncestorWhichIsA("Model")
                end
                -- Teleport the vehicle if we found it
                if currentVehicle and currentVehicle:FindFirstChild("Engine") then
                    MoveToPosition(currentVehicle.Engine, targetCFrame, Config.VehicleSpeed, true)
                    task.wait(0.5)
                    Teleporting = false
                    return
                end
            else
                -- Failed to enter - try another vehicle
                if vehicleObj then
                    table.insert(triedVehicles, vehicleObj)
                end
                return teleport(targetCFrame, triedVehicles)
            end
        end
    end

    -- Direct teleport with maximum reliability
    local speed = inVehicle and Config.VehicleSpeed or Config.PlayerSpeed
    local partToMove = rootPart
    
    if inVehicle and currentVehicle then
        partToMove = currentVehicle:FindFirstChild("Engine") or rootPart
    end

    MoveToPosition(partToMove, targetCFrame, speed, inVehicle)

    task.wait(0.5)
    Teleporting = false
end
