--[[
    vibecode.lua
    Universal shooter utility suite
    Version 3.0.0

    Runtime: Roblox Luau in an executor environment.
    External packages: none.

    Component inventory
      Maid            deterministic cleanup for connections and objects
      Signal          small synchronous event primitive
      Store           validated settings, change notifications, persistence
      InputRouter     keyboard and mouse binding state
      Targeting       target validation, projection, visibility and scoring
      AimController   sticky acquisition, prediction and camera/mouse aiming
      Triggerbot      crosshair ray selection and rate-limited click dispatch
      EspController   Drawing-based boxes, tracers, skeletons and labels
      Overlay         FOV circle, crosshair and live target indicator
      Library         dependency-free draggable window and controls
      Runtime         lifecycle, respawns, camera replacement and shutdown

    The file deliberately uses one RenderStepped connection. Per-player ESP
    records are cached, so the steady-state update is O(P) for P players and
    creates no Instances or Drawing objects per frame.
]]

-- // Services

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local HttpService = game:GetService("HttpService")
local CoreGui = game:GetService("CoreGui")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer
local Camera = Workspace.CurrentCamera

if not LocalPlayer then
    error("vibecode: LocalPlayer is unavailable")
end

-- // Executor capability detection

local Capabilities = {
    drawing = type(Drawing) == "table" and type(Drawing.new) == "function",
    mouseMove = type(mousemoverel) == "function",
    mousePress = type(mouse1press) == "function",
    mouseRelease = type(mouse1release) == "function",
    mouseClick = type(mouse1click) == "function",
    fileRead = type(readfile) == "function",
    fileWrite = type(writefile) == "function",
    fileExists = type(isfile) == "function",
    folderCreate = type(makefolder) == "function",
    folderExists = type(isfolder) == "function",
    protectGui = type(syn) == "table" and type(syn.protect_gui) == "function",
    getGuiRoot = type(gethui) == "function",
}

-- // Constants

local PRODUCT_NAME = "vibecode"
local PRODUCT_VERSION = "3.0.0"
local CONFIG_FOLDER = "vibecode"
local CONFIG_PATH = CONFIG_FOLDER .. "/config.json"
local GUI_NAME = "Vibecode_3_0_Runtime"

local COLORS = {
    background = Color3.fromRGB(12, 14, 20),
    surface = Color3.fromRGB(18, 21, 29),
    surfaceRaised = Color3.fromRGB(25, 29, 39),
    surfaceHover = Color3.fromRGB(31, 36, 48),
    border = Color3.fromRGB(43, 49, 64),
    text = Color3.fromRGB(235, 239, 248),
    textMuted = Color3.fromRGB(139, 149, 170),
    accent = Color3.fromRGB(122, 92, 255),
    accentLight = Color3.fromRGB(160, 139, 255),
    success = Color3.fromRGB(78, 221, 152),
    warning = Color3.fromRGB(255, 190, 92),
    danger = Color3.fromRGB(255, 91, 112),
    black = Color3.new(0, 0, 0),
    white = Color3.new(1, 1, 1),
}

local DEFAULTS = {
    General = {
        MenuKey = "Delete",
        MenuVisible = true,
        Watermark = true,
        Notifications = true,
        AccentR = 122,
        AccentG = 92,
        AccentB = 255,
        SaveConfig = true,
    },
    Aim = {
        Enabled = false,
        ActiveMode = "Hold",
        Key = "MouseButton2",
        Output = "Mouse",
        AimPart = "Head",
        TargetMode = "Crosshair",
        TeamCheck = true,
        WallCheck = true,
        AliveCheck = true,
        ForceFieldCheck = false,
        Sticky = true,
        StickyFovMultiplier = 1.35,
        Fov = 150,
        DynamicFov = false,
        ReferenceFov = 70,
        MaxDistance = 1500,
        Smoothness = 9,
        VerticalSmoothness = 9,
        MaxStep = 90,
        Deadzone = 0.75,
        Prediction = true,
        PredictionMode = "Velocity",
        PredictionTime = 0.115,
        ProjectileSpeed = 1000,
        GravityCompensation = 0,
        VelocitySmoothing = 0.45,
        SwitchDelay = 0.08,
        Randomization = 0,
        IgnoreFriends = false,
    },
    Trigger = {
        Enabled = false,
        ActiveMode = "Always",
        Key = "MouseButton1",
        TeamCheck = true,
        WallCheck = true,
        MaxDistance = 1000,
        Delay = 0.035,
        HoldTime = 0.025,
        Cooldown = 0.085,
        Burst = 1,
        BurstGap = 0.045,
        Hitboxes = "Any",
    },
    Esp = {
        Enabled = false,
        TeamCheck = false,
        WallCheck = false,
        MaxDistance = 2000,
        UpdateRate = 0,
        Box = true,
        BoxStyle = "Corner",
        BoxThickness = 1.5,
        BoxFill = false,
        BoxFillAlpha = 0.82,
        Name = true,
        DisplayName = false,
        Distance = true,
        HealthBar = true,
        HealthText = false,
        Weapon = false,
        Skeleton = false,
        Tracer = false,
        TracerOrigin = "Bottom",
        HeadDot = false,
        OffscreenArrow = true,
        ArrowRadius = 240,
        ArrowSize = 14,
        Chams = false,
        ChamsFillAlpha = 0.72,
        ChamsOutlineAlpha = 0,
        VisibleR = 75,
        VisibleG = 230,
        VisibleB = 145,
        HiddenR = 255,
        HiddenG = 92,
        HiddenB = 112,
        TeamR = 100,
        TeamG = 165,
        TeamB = 255,
        TextSize = 13,
    },
    Visuals = {
        FovCircle = true,
        FovFilled = false,
        FovThickness = 1.5,
        FovSides = 64,
        FovAlpha = 0.05,
        Crosshair = false,
        CrosshairSize = 7,
        CrosshairGap = 3,
        CrosshairThickness = 1.5,
        TargetLine = false,
        TargetName = true,
        RainbowFov = false,
    },
}

-- // Generic utilities

local Utility = {}

function Utility.clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
end

function Utility.round(value, precision)
    local power = 10 ^ (precision or 0)
    return math.floor(value * power + 0.5) / power
end

function Utility.lerp(a, b, alpha)
    return a + (b - a) * alpha
end

function Utility.deepCopy(source)
    local copy = {}

    for key, value in pairs(source) do
        if type(value) == "table" then
            copy[key] = Utility.deepCopy(value)
        else
            copy[key] = value
        end
    end

    return copy
end

function Utility.mergeKnown(destination, source, schema)
    if type(source) ~= "table" then
        return
    end

    for key, schemaValue in pairs(schema) do
        local incoming = source[key]

        if type(schemaValue) == "table" then
            if type(incoming) == "table" then
                Utility.mergeKnown(destination[key], incoming, schemaValue)
            end
        elseif incoming ~= nil and type(incoming) == type(schemaValue) then
            destination[key] = incoming
        end
    end
end

function Utility.colorFromSettings(section, prefix)
    return Color3.fromRGB(
        Utility.clamp(section[prefix .. "R"] or 255, 0, 255),
        Utility.clamp(section[prefix .. "G"] or 255, 0, 255),
        Utility.clamp(section[prefix .. "B"] or 255, 0, 255)
    )
end

function Utility.safeDestroy(object)
    if object == nil then
        return
    end

    pcall(function()
        object:Destroy()
    end)
end

function Utility.safeDisconnect(connection)
    if connection == nil then
        return
    end

    pcall(function()
        connection:Disconnect()
    end)
end

function Utility.safeRemove(drawing)
    if drawing == nil then
        return
    end

    pcall(function()
        drawing:Remove()
    end)
end

function Utility.create(className, properties, children)
    local instance = Instance.new(className)

    for property, value in pairs(properties or {}) do
        instance[property] = value
    end

    for _, child in ipairs(children or {}) do
        child.Parent = instance
    end

    return instance
end

function Utility.tween(instance, duration, properties)
    local tween = TweenService:Create(
        instance,
        TweenInfo.new(duration, Enum.EasingStyle.Quart, Enum.EasingDirection.Out),
        properties
    )

    tween:Play()
    return tween
end

function Utility.getGuiParent()
    if Capabilities.getGuiRoot then
        local success, result = pcall(gethui)

        if success and result then
            return result
        end
    end

    return CoreGui
end

function Utility.getMousePosition()
    local position = UserInputService:GetMouseLocation()
    return Vector2.new(position.X, position.Y)
end

function Utility.toInputName(input)
    if input.UserInputType == Enum.UserInputType.Keyboard then
        return input.KeyCode.Name
    end

    return input.UserInputType.Name
end

function Utility.inputEnum(name)
    local keyCode = Enum.KeyCode[name]

    if keyCode and keyCode ~= Enum.KeyCode.Unknown then
        return keyCode
    end

    return Enum.UserInputType[name]
end

function Utility.isMouseName(name)
    return name == "MouseButton1"
        or name == "MouseButton2"
        or name == "MouseButton3"
end

function Utility.formatKey(name)
    local replacements = {
        MouseButton1 = "M1",
        MouseButton2 = "M2",
        MouseButton3 = "M3",
        LeftControl = "LCtrl",
        RightControl = "RCtrl",
        LeftShift = "LShift",
        RightShift = "RShift",
        CapsLock = "Caps",
        Backquote = "`",
    }

    return replacements[name] or name
end

function Utility.findHumanoid(character)
    if not character then
        return nil
    end

    return character:FindFirstChildOfClass("Humanoid")
end

function Utility.findRoot(character)
    if not character then
        return nil
    end

    return character:FindFirstChild("HumanoidRootPart")
        or character:FindFirstChild("Torso")
        or character:FindFirstChild("UpperTorso")
end

function Utility.findAimPart(character, requested)
    if not character then
        return nil
    end

    local exact = character:FindFirstChild(requested)

    if exact and exact:IsA("BasePart") then
        return exact
    end

    if requested == "Torso" then
        return character:FindFirstChild("UpperTorso")
            or character:FindFirstChild("Torso")
            or character:FindFirstChild("HumanoidRootPart")
    end

    return character:FindFirstChild("Head")
        or character:FindFirstChild("HumanoidRootPart")
        or character:FindFirstChildWhichIsA("BasePart")
end

function Utility.isAlive(character)
    local humanoid = Utility.findHumanoid(character)
    local root = Utility.findRoot(character)

    return humanoid ~= nil
        and root ~= nil
        and humanoid.Health > 0
        and humanoid:GetState() ~= Enum.HumanoidStateType.Dead
end

function Utility.teamEquals(first, second)
    if first == nil or second == nil then
        return false
    end

    if first.Team ~= nil and second.Team ~= nil then
        return first.Team == second.Team
    end

    if first.TeamColor ~= nil and second.TeamColor ~= nil then
        return first.TeamColor == second.TeamColor
    end

    return false
end

function Utility.viewportPoint(worldPosition)
    Camera = Workspace.CurrentCamera or Camera

    if not Camera then
        return Vector2.zero, false, -1
    end

    local projected, onScreen = Camera:WorldToViewportPoint(worldPosition)

    return Vector2.new(projected.X, projected.Y), onScreen and projected.Z > 0, projected.Z
end

function Utility.characterBounds(character)
    local success, cframe, size = pcall(function()
        return character:GetBoundingBox()
    end)

    if success then
        return cframe, size
    end

    local root = Utility.findRoot(character)

    if root then
        return root.CFrame, Vector3.new(4, 6, 2)
    end

    return nil, nil
end

function Utility.hsvClock(speed)
    return Color3.fromHSV((os.clock() * speed) % 1, 0.82, 1)
end

-- // Maid

local Maid = {}
Maid.__index = Maid

function Maid.new()
    return setmetatable({
        tasks = {},
        cleaning = false,
    }, Maid)
end

function Maid:give(taskObject)
    if taskObject == nil then
        return nil
    end

    self.tasks[#self.tasks + 1] = taskObject
    return taskObject
end

function Maid:remove(taskObject)
    for index = #self.tasks, 1, -1 do
        if self.tasks[index] == taskObject then
            table.remove(self.tasks, index)
            break
        end
    end
end

function Maid:clean()
    if self.cleaning then
        return
    end

    self.cleaning = true

    for index = #self.tasks, 1, -1 do
        local taskObject = self.tasks[index]
        self.tasks[index] = nil

        if typeof(taskObject) == "RBXScriptConnection" then
            Utility.safeDisconnect(taskObject)
        elseif typeof(taskObject) == "Instance" then
            Utility.safeDestroy(taskObject)
        elseif type(taskObject) == "function" then
            pcall(taskObject)
        elseif type(taskObject) == "table" then
            if type(taskObject.Disconnect) == "function" then
                pcall(function()
                    taskObject:Disconnect()
                end)
            elseif type(taskObject.Destroy) == "function" then
                pcall(function()
                    taskObject:Destroy()
                end)
            elseif type(taskObject.Remove) == "function" then
                Utility.safeRemove(taskObject)
            elseif type(taskObject.clean) == "function" then
                pcall(function()
                    taskObject:clean()
                end)
            end
        end
    end

    self.cleaning = false
end

-- // Signal

local Signal = {}
Signal.__index = Signal

function Signal.new()
    return setmetatable({
        listeners = {},
        nextId = 0,
    }, Signal)
end

function Signal:connect(callback)
    assert(type(callback) == "function", "Signal callback must be a function")

    self.nextId = self.nextId + 1

    local id = self.nextId
    local connected = true
    self.listeners[id] = callback

    local parentSignal = self

    return {
        Disconnect = function()
            if connected then
                connected = false
                parentSignal.listeners[id] = nil
            end
        end,
    }
end

function Signal:fire(...)
    local arguments = table.pack(...)

    for _, callback in pairs(self.listeners) do
        task.spawn(function()
            local success, reason = pcall(callback, table.unpack(arguments, 1, arguments.n))

            if not success then
                warn("vibecode signal listener failed:", reason)
            end
        end)
    end
end

function Signal:destroy()
    table.clear(self.listeners)
end

-- // Store

local Store = {}
Store.__index = Store

function Store.new(defaults)
    local self = setmetatable({}, Store)

    self.defaults = Utility.deepCopy(defaults)
    self.values = Utility.deepCopy(defaults)
    self.changed = Signal.new()
    self.saveQueued = false

    return self
end

function Store:get(section, key)
    local group = self.values[section]

    if group == nil then
        return nil
    end

    return group[key]
end

function Store:set(section, key, value, silent)
    local group = self.values[section]
    local schema = self.defaults[section]

    if group == nil or schema == nil or schema[key] == nil then
        warn(string.format("vibecode: rejected unknown setting %s.%s", tostring(section), tostring(key)))
        return false
    end

    if type(value) ~= type(schema[key]) then
        warn(string.format(
            "vibecode: rejected %s.%s type %s, expected %s",
            tostring(section),
            tostring(key),
            type(value),
            type(schema[key])
        ))
        return false
    end

    local previous = group[key]

    if previous == value then
        return true
    end

    group[key] = value

    if not silent then
        self.changed:fire(section, key, value, previous)
        self:queueSave()
    end

    return true
end

function Store:reset(section)
    if section ~= nil and self.defaults[section] ~= nil then
        self.values[section] = Utility.deepCopy(self.defaults[section])
        self.changed:fire(section, "*", self.values[section], nil)
    else
        self.values = Utility.deepCopy(self.defaults)
        self.changed:fire("*", "*", self.values, nil)
    end

    self:queueSave()
end

function Store:serialize()
    return HttpService:JSONEncode(self.values)
end

function Store:load()
    if not Capabilities.fileRead or not Capabilities.fileExists then
        return false, "file API unavailable"
    end

    local exists = false
    local checkSuccess = pcall(function()
        exists = isfile(CONFIG_PATH)
    end)

    if not checkSuccess or not exists then
        return false, "config absent"
    end

    local success, result = pcall(function()
        local decoded = HttpService:JSONDecode(readfile(CONFIG_PATH))
        local merged = Utility.deepCopy(self.defaults)
        Utility.mergeKnown(merged, decoded, self.defaults)
        self.values = merged
    end)

    if success then
        self.changed:fire("*", "*", self.values, nil)
        return true
    end

    return false, tostring(result)
end

function Store:save()
    if not self:get("General", "SaveConfig") then
        return false, "saving disabled"
    end

    if not Capabilities.fileWrite then
        return false, "writefile unavailable"
    end

    local success, result = pcall(function()
        if Capabilities.folderCreate then
            local folderReady = false

            if Capabilities.folderExists then
                folderReady = isfolder(CONFIG_FOLDER)
            end

            if not folderReady then
                makefolder(CONFIG_FOLDER)
            end
        end

        writefile(CONFIG_PATH, self:serialize())
    end)

    return success, result
end

function Store:queueSave()
    if self.saveQueued then
        return
    end

    self.saveQueued = true

    task.delay(0.75, function()
        self.saveQueued = false
        self:save()
    end)
end

local Settings = Store.new(DEFAULTS)
Settings:load()

-- // Runtime character state

local CharacterState = {
    character = nil,
    humanoid = nil,
    root = nil,
}

function CharacterState:update(character)
    self.character = character or LocalPlayer.Character
    self.humanoid = Utility.findHumanoid(self.character)
    self.root = Utility.findRoot(self.character)
end

CharacterState:update()

-- // Input router

local InputRouter = {}
InputRouter.__index = InputRouter

function InputRouter.new()
    local self = setmetatable({}, InputRouter)

    self.down = {}
    self.toggled = {}
    self.bindListeners = {}
    self.capturing = nil
    self.maid = Maid.new()

    self.maid:give(UserInputService.InputBegan:Connect(function(input, gameProcessed)
        self:_onBegan(input, gameProcessed)
    end))

    self.maid:give(UserInputService.InputEnded:Connect(function(input)
        self:_onEnded(input)
    end))

    return self
end

function InputRouter:_onBegan(input, gameProcessed)
    local name = Utility.toInputName(input)

    self.down[name] = true
    self.toggled[name] = not self.toggled[name]

    if self.capturing then
        local callback = self.capturing
        self.capturing = nil
        callback(name)
        return
    end

    local listeners = self.bindListeners[name]

    if listeners then
        for _, listener in pairs(listeners) do
            task.spawn(listener, gameProcessed)
        end
    end
end

function InputRouter:_onEnded(input)
    local name = Utility.toInputName(input)
    self.down[name] = false
end

function InputRouter:isDown(name)
    return self.down[name] == true
end

function InputRouter:isToggled(name)
    return self.toggled[name] == true
end

function InputRouter:isActive(name, mode, enabled)
    if not enabled then
        return false
    end

    if mode == "Always" then
        return true
    end

    if mode == "Toggle" then
        return self:isToggled(name)
    end

    return self:isDown(name)
end

function InputRouter:bind(name, id, callback)
    if not self.bindListeners[name] then
        self.bindListeners[name] = {}
    end

    self.bindListeners[name][id] = callback

    return function()
        if self.bindListeners[name] then
            self.bindListeners[name][id] = nil
        end
    end
end

function InputRouter:capture(callback)
    self.capturing = callback
end

function InputRouter:cancelCapture()
    self.capturing = nil
end

function InputRouter:Destroy()
    self.maid:clean()
    table.clear(self.down)
    table.clear(self.toggled)
    table.clear(self.bindListeners)
end

local Input = InputRouter.new()

-- // Targeting

local Targeting = {}

local visibilityParams = RaycastParams.new()
visibilityParams.FilterType = Enum.RaycastFilterType.Exclude
visibilityParams.IgnoreWater = true

function Targeting.isFriendly(player)
    return Utility.teamEquals(LocalPlayer, player)
end

function Targeting.isFriend(player)
    local success, result = pcall(function()
        return LocalPlayer:IsFriendsWith(player.UserId)
    end)

    return success and result == true
end

function Targeting.worldDistance(part)
    local origin = CharacterState.root

    if not origin or not part then
        return math.huge
    end

    return (part.Position - origin.Position).Magnitude
end

function Targeting.isVisible(part, character)
    Camera = Workspace.CurrentCamera or Camera

    if not Camera or not part then
        return false
    end

    local filter = {}

    if CharacterState.character then
        filter[#filter + 1] = CharacterState.character
    end

    visibilityParams.FilterDescendantsInstances = filter

    local origin = Camera.CFrame.Position
    local direction = part.Position - origin
    local result = Workspace:Raycast(origin, direction, visibilityParams)

    if result == nil then
        return true
    end

    return character ~= nil and result.Instance:IsDescendantOf(character)
end

function Targeting.effectiveFov()
    local configured = Settings:get("Aim", "Fov")

    if not Settings:get("Aim", "DynamicFov") or not Camera then
        return configured
    end

    local reference = math.max(Settings:get("Aim", "ReferenceFov"), 1)
    local current = math.max(Camera.FieldOfView, 1)

    return configured * (reference / current)
end

function Targeting.validate(player, options)
    if player == nil or player == LocalPlayer then
        return nil
    end

    local character = player.Character

    if character == nil then
        return nil
    end

    local humanoid = Utility.findHumanoid(character)
    local root = Utility.findRoot(character)
    local part = Utility.findAimPart(character, options.aimPart)

    if not humanoid or not root or not part then
        return nil
    end

    if options.aliveCheck and humanoid.Health <= 0 then
        return nil
    end

    if options.teamCheck and Targeting.isFriendly(player) then
        return nil
    end

    if options.ignoreFriends and Targeting.isFriend(player) then
        return nil
    end

    if options.forceFieldCheck and character:FindFirstChildOfClass("ForceField") then
        return nil
    end

    local distance = Targeting.worldDistance(root)

    if distance > options.maxDistance then
        return nil
    end

    local screen, onScreen, depth = Utility.viewportPoint(part.Position)

    if not onScreen or depth <= 0 then
        return nil
    end

    local mouse = Utility.getMousePosition()
    local screenDistance = (screen - mouse).Magnitude

    if screenDistance > options.fov then
        return nil
    end

    local visible = Targeting.isVisible(part, character)

    if options.wallCheck and not visible then
        return nil
    end

    return {
        player = player,
        character = character,
        humanoid = humanoid,
        root = root,
        part = part,
        screen = screen,
        screenDistance = screenDistance,
        worldDistance = distance,
        visible = visible,
        healthFraction = humanoid.MaxHealth > 0 and humanoid.Health / humanoid.MaxHealth or 0,
    }
end

function Targeting.score(candidate, mode)
    if mode == "Distance" then
        return candidate.worldDistance
    end

    if mode == "Health" then
        return candidate.humanoid.Health
    end

    return candidate.screenDistance
end

function Targeting.acquire(options)
    local best = nil
    local bestScore = math.huge

    for _, player in ipairs(Players:GetPlayers()) do
        local candidate = Targeting.validate(player, options)

        if candidate then
            local score = Targeting.score(candidate, options.targetMode)

            if score < bestScore then
                best = candidate
                bestScore = score
            end
        end
    end

    return best
end

function Targeting.playerFromDescendant(instance)
    local cursor = instance

    while cursor and cursor ~= Workspace do
        local player = Players:GetPlayerFromCharacter(cursor)

        if player then
            return player, cursor
        end

        cursor = cursor.Parent
    end

    return nil, nil
end

function Targeting.crosshairHit(maxDistance)
    Camera = Workspace.CurrentCamera or Camera

    if not Camera then
        return nil
    end

    local mouse = Utility.getMousePosition()
    local unitRay = Camera:ViewportPointToRay(mouse.X, mouse.Y)
    local filters = {}

    if CharacterState.character then
        filters[#filters + 1] = CharacterState.character
    end

    visibilityParams.FilterDescendantsInstances = filters

    return Workspace:Raycast(
        unitRay.Origin,
        unitRay.Direction * maxDistance,
        visibilityParams
    )
end

-- // Aim controller

local AimController = {}
AimController.__index = AimController

function AimController.new()
    return setmetatable({
        target = nil,
        targetAcquiredAt = 0,
        targetLostAt = 0,
        lastSwitchAt = 0,
        velocitySamples = {},
        lastOutput = Vector2.zero,
    }, AimController)
end

function AimController:_options(fovMultiplier)
    return {
        aimPart = Settings:get("Aim", "AimPart"),
        targetMode = Settings:get("Aim", "TargetMode"),
        teamCheck = Settings:get("Aim", "TeamCheck"),
        wallCheck = Settings:get("Aim", "WallCheck"),
        aliveCheck = Settings:get("Aim", "AliveCheck"),
        forceFieldCheck = Settings:get("Aim", "ForceFieldCheck"),
        ignoreFriends = Settings:get("Aim", "IgnoreFriends"),
        maxDistance = Settings:get("Aim", "MaxDistance"),
        fov = Targeting.effectiveFov() * (fovMultiplier or 1),
    }
end

function AimController:_validateSticky()
    if not self.target or not Settings:get("Aim", "Sticky") then
        return nil
    end

    return Targeting.validate(
        self.target.player,
        self:_options(Settings:get("Aim", "StickyFovMultiplier"))
    )
end

function AimController:_selectTarget()
    local sticky = self:_validateSticky()

    if sticky then
        self.target = sticky
        return sticky
    end

    local now = os.clock()

    if now - self.lastSwitchAt < Settings:get("Aim", "SwitchDelay") then
        return nil
    end

    local acquired = Targeting.acquire(self:_options(1))
    self.lastSwitchAt = now

    if acquired then
        self.target = acquired
        self.targetAcquiredAt = now
    else
        self.target = nil
        self.targetLostAt = now
    end

    return acquired
end

function AimController:_smoothedVelocity(candidate, deltaTime)
    local userId = candidate.player.UserId
    local current = candidate.root.AssemblyLinearVelocity
    local previous = self.velocitySamples[userId]
    local configuredAlpha = Settings:get("Aim", "VelocitySmoothing")
    local frameAlpha = 1 - ((1 - configuredAlpha) ^ math.max(deltaTime * 60, 0.01))
    local smoothed = previous and previous:Lerp(current, frameAlpha) or current

    self.velocitySamples[userId] = smoothed
    return smoothed
end

function AimController:_predictionTime(candidate)
    local mode = Settings:get("Aim", "PredictionMode")

    if mode == "Projectile" then
        local speed = math.max(Settings:get("Aim", "ProjectileSpeed"), 1)
        return candidate.worldDistance / speed
    end

    return Settings:get("Aim", "PredictionTime")
end

function AimController:_predictedPosition(candidate, deltaTime)
    local position = candidate.part.Position

    if not Settings:get("Aim", "Prediction") then
        return position
    end

    local travelTime = self:_predictionTime(candidate)
    local velocity = self:_smoothedVelocity(candidate, deltaTime)
    local gravityCompensation = Settings:get("Aim", "GravityCompensation")

    position = position + velocity * travelTime

    if gravityCompensation ~= 0 then
        position = position + Vector3.new(
            0,
            0.5 * gravityCompensation * travelTime * travelTime,
            0
        )
    end

    return position
end

function AimController:_mouseOutput(screenPosition, deltaTime)
    if not Capabilities.mouseMove then
        return
    end

    local mouse = Utility.getMousePosition()
    local rawDelta = screenPosition - mouse
    local deadzone = Settings:get("Aim", "Deadzone")

    if rawDelta.Magnitude <= deadzone then
        self.lastOutput = Vector2.zero
        return
    end

    local horizontal = math.max(Settings:get("Aim", "Smoothness"), 1)
    local vertical = math.max(Settings:get("Aim", "VerticalSmoothness"), 1)
    local response = Utility.clamp(deltaTime * 60, 0.2, 2.5)
    local output = Vector2.new(
        rawDelta.X / horizontal,
        rawDelta.Y / vertical
    ) * response

    local randomization = Settings:get("Aim", "Randomization")

    if randomization > 0 then
        output = output + Vector2.new(
            (math.random() - 0.5) * randomization,
            (math.random() - 0.5) * randomization
        )
    end

    local maximum = Settings:get("Aim", "MaxStep")

    if output.Magnitude > maximum then
        output = output.Unit * maximum
    end

    self.lastOutput = output

    pcall(function()
        mousemoverel(output.X, output.Y)
    end)
end

function AimController:_cameraOutput(worldPosition, deltaTime)
    if not Camera then
        return
    end

    local desired = CFrame.lookAt(Camera.CFrame.Position, worldPosition)
    local smoothness = math.max(Settings:get("Aim", "Smoothness"), 1)
    local alpha = 1 - math.exp(-deltaTime * (60 / smoothness))

    Camera.CFrame = Camera.CFrame:Lerp(desired, Utility.clamp(alpha, 0, 1))
end

function AimController:isActive()
    return Input:isActive(
        Settings:get("Aim", "Key"),
        Settings:get("Aim", "ActiveMode"),
        Settings:get("Aim", "Enabled")
    )
end

function AimController:update(deltaTime)
    if not self:isActive() then
        self.target = nil
        self.lastOutput = Vector2.zero
        return
    end

    local candidate = self:_selectTarget()

    if not candidate then
        return
    end

    local predicted = self:_predictedPosition(candidate, deltaTime)
    local screen, onScreen, depth = Utility.viewportPoint(predicted)

    if not onScreen or depth <= 0 then
        self.target = nil
        return
    end

    if Settings:get("Aim", "Output") == "Camera" then
        self:_cameraOutput(predicted, deltaTime)
    else
        self:_mouseOutput(screen, deltaTime)
    end
end

function AimController:clearPlayer(player)
    self.velocitySamples[player.UserId] = nil

    if self.target and self.target.player == player then
        self.target = nil
    end
end

function AimController:Destroy()
    self.target = nil
    table.clear(self.velocitySamples)
end

local Aim = AimController.new()

-- // Triggerbot

local Triggerbot = {}
Triggerbot.__index = Triggerbot

function Triggerbot.new()
    return setmetatable({
        lastShotAt = -math.huge,
        pending = false,
        generation = 0,
    }, Triggerbot)
end

function Triggerbot:isActive()
    return Input:isActive(
        Settings:get("Trigger", "Key"),
        Settings:get("Trigger", "ActiveMode"),
        Settings:get("Trigger", "Enabled")
    )
end

function Triggerbot:_hitboxAllowed(instance)
    local mode = Settings:get("Trigger", "Hitboxes")

    if mode == "Any" then
        return instance:IsA("BasePart")
    end

    if mode == "Head" then
        return instance.Name == "Head"
    end

    return instance.Name == "HumanoidRootPart"
        or instance.Name == "Torso"
        or instance.Name == "UpperTorso"
        or instance.Name == "LowerTorso"
end

function Triggerbot:_canShoot()
    if self.pending then
        return false
    end

    return os.clock() - self.lastShotAt >= Settings:get("Trigger", "Cooldown")
end

function Triggerbot:_dispatchClick(generation)
    if generation ~= self.generation then
        return
    end

    local burst = Settings:get("Trigger", "Burst")
    local holdTime = Settings:get("Trigger", "HoldTime")
    local burstGap = Settings:get("Trigger", "BurstGap")

    for shot = 1, burst do
        if generation ~= self.generation then
            break
        end

        if Capabilities.mousePress and Capabilities.mouseRelease then
            pcall(mouse1press)
            task.wait(holdTime)
            pcall(mouse1release)
        elseif Capabilities.mouseClick then
            pcall(mouse1click)
        end

        if shot < burst then
            task.wait(burstGap)
        end
    end

    self.lastShotAt = os.clock()
    self.pending = false
end

function Triggerbot:update()
    if not self:isActive() or not self:_canShoot() then
        return
    end

    local result = Targeting.crosshairHit(Settings:get("Trigger", "MaxDistance"))

    if not result or not self:_hitboxAllowed(result.Instance) then
        return
    end

    local player, character = Targeting.playerFromDescendant(result.Instance)

    if not player or player == LocalPlayer or not Utility.isAlive(character) then
        return
    end

    if Settings:get("Trigger", "TeamCheck") and Targeting.isFriendly(player) then
        return
    end

    if Settings:get("Trigger", "WallCheck")
        and not Targeting.isVisible(result.Instance, character)
    then
        return
    end

    self.pending = true
    self.generation = self.generation + 1

    local generation = self.generation
    local delay = Settings:get("Trigger", "Delay")

    task.delay(delay, function()
        self:_dispatchClick(generation)
    end)
end

function Triggerbot:cancel()
    self.generation = self.generation + 1
    self.pending = false

    if Capabilities.mouseRelease then
        pcall(mouse1release)
    end
end

function Triggerbot:Destroy()
    self:cancel()
end

local Trigger = Triggerbot.new()

-- // Drawing helpers

local function newDrawing(kind, properties)
    if not Capabilities.drawing then
        return nil
    end

    local drawing = Drawing.new(kind)

    for property, value in pairs(properties or {}) do
        drawing[property] = value
    end

    return drawing
end

local function setDrawingVisible(drawing, visible)
    if drawing then
        drawing.Visible = visible
    end
end

local function hideDrawingGroup(group)
    for _, drawing in pairs(group) do
        if type(drawing) == "table" then
            hideDrawingGroup(drawing)
        else
            setDrawingVisible(drawing, false)
        end
    end
end

local function removeDrawingGroup(group)
    for key, drawing in pairs(group) do
        if type(drawing) == "table" then
            removeDrawingGroup(drawing)
        else
            Utility.safeRemove(drawing)
        end

        group[key] = nil
    end
end

-- // ESP controller

local EspController = {}
EspController.__index = EspController

local R15_BONES = {
    { "Head", "UpperTorso" },
    { "UpperTorso", "LowerTorso" },
    { "UpperTorso", "LeftUpperArm" },
    { "LeftUpperArm", "LeftLowerArm" },
    { "LeftLowerArm", "LeftHand" },
    { "UpperTorso", "RightUpperArm" },
    { "RightUpperArm", "RightLowerArm" },
    { "RightLowerArm", "RightHand" },
    { "LowerTorso", "LeftUpperLeg" },
    { "LeftUpperLeg", "LeftLowerLeg" },
    { "LeftLowerLeg", "LeftFoot" },
    { "LowerTorso", "RightUpperLeg" },
    { "RightUpperLeg", "RightLowerLeg" },
    { "RightLowerLeg", "RightFoot" },
}

local R6_BONES = {
    { "Head", "Torso" },
    { "Torso", "Left Arm" },
    { "Torso", "Right Arm" },
    { "Torso", "Left Leg" },
    { "Torso", "Right Leg" },
}

function EspController.new()
    return setmetatable({
        records = {},
        accumulator = 0,
    }, EspController)
end

function EspController:_createRecord(player)
    self:_destroyRecord(player)

    local record = {
        player = player,
        character = nil,
        drawings = {},
        highlight = nil,
    }

    local drawings = record.drawings

    drawings.boxOutline = newDrawing("Square", {
        Visible = false,
        Filled = false,
        Thickness = 3,
        Color = COLORS.black,
        Transparency = 0.7,
    })

    drawings.box = newDrawing("Square", {
        Visible = false,
        Filled = false,
        Thickness = Settings:get("Esp", "BoxThickness"),
        Color = COLORS.white,
        Transparency = 1,
    })

    drawings.boxFill = newDrawing("Square", {
        Visible = false,
        Filled = true,
        Thickness = 0,
        Color = COLORS.white,
        Transparency = 0.18,
    })

    drawings.corners = {}
    drawings.cornerOutlines = {}

    for index = 1, 8 do
        drawings.cornerOutlines[index] = newDrawing("Line", {
            Visible = false,
            Thickness = 3.5,
            Color = COLORS.black,
            Transparency = 0.75,
        })

        drawings.corners[index] = newDrawing("Line", {
            Visible = false,
            Thickness = Settings:get("Esp", "BoxThickness"),
            Color = COLORS.white,
            Transparency = 1,
        })
    end

    drawings.name = newDrawing("Text", {
        Visible = false,
        Center = true,
        Outline = true,
        Font = 2,
        Size = Settings:get("Esp", "TextSize"),
        Color = COLORS.white,
        Transparency = 1,
        Text = player.Name,
    })

    drawings.distance = newDrawing("Text", {
        Visible = false,
        Center = true,
        Outline = true,
        Font = 2,
        Size = Settings:get("Esp", "TextSize") - 1,
        Color = COLORS.white,
        Transparency = 1,
        Text = "",
    })

    drawings.healthText = newDrawing("Text", {
        Visible = false,
        Center = false,
        Outline = true,
        Font = 2,
        Size = Settings:get("Esp", "TextSize") - 1,
        Color = COLORS.white,
        Transparency = 1,
        Text = "",
    })

    drawings.weapon = newDrawing("Text", {
        Visible = false,
        Center = true,
        Outline = true,
        Font = 2,
        Size = Settings:get("Esp", "TextSize") - 1,
        Color = COLORS.white,
        Transparency = 1,
        Text = "",
    })

    drawings.healthBackground = newDrawing("Square", {
        Visible = false,
        Filled = true,
        Thickness = 0,
        Color = COLORS.black,
        Transparency = 0.75,
    })

    drawings.health = newDrawing("Square", {
        Visible = false,
        Filled = true,
        Thickness = 0,
        Color = COLORS.success,
        Transparency = 1,
    })

    drawings.tracerOutline = newDrawing("Line", {
        Visible = false,
        Thickness = 3.5,
        Color = COLORS.black,
        Transparency = 0.75,
    })

    drawings.tracer = newDrawing("Line", {
        Visible = false,
        Thickness = 1.5,
        Color = COLORS.white,
        Transparency = 1,
    })

    drawings.headDotOutline = newDrawing("Circle", {
        Visible = false,
        Filled = true,
        NumSides = 24,
        Radius = 5,
        Color = COLORS.black,
        Transparency = 0.75,
    })

    drawings.headDot = newDrawing("Circle", {
        Visible = false,
        Filled = true,
        NumSides = 24,
        Radius = 3.5,
        Color = COLORS.white,
        Transparency = 1,
    })

    drawings.arrowOutline = newDrawing("Triangle", {
        Visible = false,
        Filled = true,
        Thickness = 0,
        Color = COLORS.black,
        Transparency = 0.8,
    })

    drawings.arrow = newDrawing("Triangle", {
        Visible = false,
        Filled = true,
        Thickness = 0,
        Color = COLORS.white,
        Transparency = 1,
    })

    drawings.skeleton = {}
    drawings.skeletonOutline = {}

    for index = 1, #R15_BONES do
        drawings.skeletonOutline[index] = newDrawing("Line", {
            Visible = false,
            Thickness = 3.5,
            Color = COLORS.black,
            Transparency = 0.72,
        })

        drawings.skeleton[index] = newDrawing("Line", {
            Visible = false,
            Thickness = 1.5,
            Color = COLORS.white,
            Transparency = 1,
        })
    end

    self.records[player] = record
    return record
end

function EspController:_destroyRecord(player)
    local record = self.records[player]

    if not record then
        return
    end

    hideDrawingGroup(record.drawings)
    removeDrawingGroup(record.drawings)
    Utility.safeDestroy(record.highlight)
    self.records[player] = nil
end

function EspController:addPlayer(player)
    if player ~= LocalPlayer and not self.records[player] then
        self:_createRecord(player)
    end
end

function EspController:removePlayer(player)
    self:_destroyRecord(player)
end

function EspController:_ensureHighlight(record, character)
    if record.highlight and record.highlight.Parent == character then
        return record.highlight
    end

    Utility.safeDestroy(record.highlight)

    local highlight = Instance.new("Highlight")
    highlight.Name = "VibecodeHighlight"
    highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    highlight.Enabled = false
    highlight.Parent = character

    record.highlight = highlight
    return highlight
end

function EspController:_color(player, visible)
    local section = Settings.values.Esp

    if Targeting.isFriendly(player) then
        return Utility.colorFromSettings(section, "Team")
    end

    if visible then
        return Utility.colorFromSettings(section, "Visible")
    end

    return Utility.colorFromSettings(section, "Hidden")
end

function EspController:_screenBox(character)
    local boundsCFrame, boundsSize = Utility.characterBounds(character)

    if not boundsCFrame or not boundsSize then
        return nil
    end

    local half = boundsSize * 0.5
    local minimum = Vector2.new(math.huge, math.huge)
    local maximum = Vector2.new(-math.huge, -math.huge)
    local anyInFront = false

    for x = -1, 1, 2 do
        for y = -1, 1, 2 do
            for z = -1, 1, 2 do
                local world = boundsCFrame:PointToWorldSpace(Vector3.new(
                    half.X * x,
                    half.Y * y,
                    half.Z * z
                ))
                local screen, _, depth = Utility.viewportPoint(world)

                if depth > 0 then
                    anyInFront = true
                    minimum = Vector2.new(
                        math.min(minimum.X, screen.X),
                        math.min(minimum.Y, screen.Y)
                    )
                    maximum = Vector2.new(
                        math.max(maximum.X, screen.X),
                        math.max(maximum.Y, screen.Y)
                    )
                end
            end
        end
    end

    if not anyInFront then
        return nil
    end

    local size = maximum - minimum

    if size.X < 2 or size.Y < 2 then
        return nil
    end

    return minimum, size
end

function EspController:_setLine(line, from, to, color, visible)
    if not line then
        return
    end

    line.From = from
    line.To = to
    line.Color = color
    line.Visible = visible
end

function EspController:_hideBoxes(drawings)
    setDrawingVisible(drawings.box, false)
    setDrawingVisible(drawings.boxOutline, false)
    setDrawingVisible(drawings.boxFill, false)

    for index = 1, 8 do
        setDrawingVisible(drawings.corners[index], false)
        setDrawingVisible(drawings.cornerOutlines[index], false)
    end
end

function EspController:_updateFullBox(drawings, topLeft, size, color)
    local enabled = Settings:get("Esp", "Box")

    if drawings.box then
        drawings.box.Position = topLeft
        drawings.box.Size = size
        drawings.box.Color = color
        drawings.box.Thickness = Settings:get("Esp", "BoxThickness")
        drawings.box.Visible = enabled
    end

    if drawings.boxOutline then
        drawings.boxOutline.Position = topLeft
        drawings.boxOutline.Size = size
        drawings.boxOutline.Visible = enabled
    end

    if drawings.boxFill then
        drawings.boxFill.Position = topLeft
        drawings.boxFill.Size = size
        drawings.boxFill.Color = color
        drawings.boxFill.Transparency = 1 - Settings:get("Esp", "BoxFillAlpha")
        drawings.boxFill.Visible = enabled and Settings:get("Esp", "BoxFill")
    end

    for index = 1, 8 do
        setDrawingVisible(drawings.corners[index], false)
        setDrawingVisible(drawings.cornerOutlines[index], false)
    end
end

function EspController:_updateCornerBox(drawings, topLeft, size, color)
    setDrawingVisible(drawings.box, false)
    setDrawingVisible(drawings.boxOutline, false)

    if drawings.boxFill then
        drawings.boxFill.Position = topLeft
        drawings.boxFill.Size = size
        drawings.boxFill.Color = color
        drawings.boxFill.Transparency = 1 - Settings:get("Esp", "BoxFillAlpha")
        drawings.boxFill.Visible = Settings:get("Esp", "Box")
            and Settings:get("Esp", "BoxFill")
    end

    local x = topLeft.X
    local y = topLeft.Y
    local width = size.X
    local height = size.Y
    local segmentX = math.max(width * 0.27, 4)
    local segmentY = math.max(height * 0.2, 4)

    local segments = {
        { Vector2.new(x, y), Vector2.new(x + segmentX, y) },
        { Vector2.new(x, y), Vector2.new(x, y + segmentY) },
        { Vector2.new(x + width, y), Vector2.new(x + width - segmentX, y) },
        { Vector2.new(x + width, y), Vector2.new(x + width, y + segmentY) },
        { Vector2.new(x, y + height), Vector2.new(x + segmentX, y + height) },
        { Vector2.new(x, y + height), Vector2.new(x, y + height - segmentY) },
        { Vector2.new(x + width, y + height), Vector2.new(x + width - segmentX, y + height) },
        { Vector2.new(x + width, y + height), Vector2.new(x + width, y + height - segmentY) },
    }

    for index, segment in ipairs(segments) do
        self:_setLine(
            drawings.cornerOutlines[index],
            segment[1],
            segment[2],
            COLORS.black,
            Settings:get("Esp", "Box")
        )
        self:_setLine(
            drawings.corners[index],
            segment[1],
            segment[2],
            color,
            Settings:get("Esp", "Box")
        )

        if drawings.corners[index] then
            drawings.corners[index].Thickness = Settings:get("Esp", "BoxThickness")
        end
    end
end

function EspController:_updateBox(drawings, topLeft, size, color)
    if Settings:get("Esp", "BoxStyle") == "Full" then
        self:_updateFullBox(drawings, topLeft, size, color)
    else
        self:_updateCornerBox(drawings, topLeft, size, color)
    end
end

function EspController:_updateHealth(drawings, humanoid, topLeft, size)
    local enabled = Settings:get("Esp", "HealthBar")
    local ratio = humanoid.MaxHealth > 0
        and Utility.clamp(humanoid.Health / humanoid.MaxHealth, 0, 1)
        or 0
    local barHeight = size.Y * ratio
    local barX = topLeft.X - 7
    local color = Color3.fromRGB(
        math.floor(255 * (1 - ratio)),
        math.floor(255 * ratio),
        50
    )

    if drawings.healthBackground then
        drawings.healthBackground.Position = Vector2.new(barX - 1, topLeft.Y - 1)
        drawings.healthBackground.Size = Vector2.new(4, size.Y + 2)
        drawings.healthBackground.Visible = enabled
    end

    if drawings.health then
        drawings.health.Position = Vector2.new(barX, topLeft.Y + size.Y - barHeight)
        drawings.health.Size = Vector2.new(2, barHeight)
        drawings.health.Color = color
        drawings.health.Visible = enabled
    end

    if drawings.healthText then
        drawings.healthText.Text = tostring(math.floor(humanoid.Health + 0.5))
        drawings.healthText.Position = Vector2.new(barX - 3, topLeft.Y + size.Y - barHeight - 7)
        drawings.healthText.Color = color
        drawings.healthText.Visible = Settings:get("Esp", "HealthText")
    end
end

function EspController:_weaponName(character)
    local tool = character:FindFirstChildOfClass("Tool")

    if tool then
        return tool.Name
    end

    return ""
end

function EspController:_updateText(record, topLeft, size, distance, color)
    local drawings = record.drawings
    local player = record.player
    local bottom = topLeft.Y + size.Y
    local name = Settings:get("Esp", "DisplayName") and player.DisplayName or player.Name

    if drawings.name then
        drawings.name.Text = name
        drawings.name.Position = Vector2.new(topLeft.X + size.X * 0.5, topLeft.Y - 17)
        drawings.name.Size = Settings:get("Esp", "TextSize")
        drawings.name.Color = color
        drawings.name.Visible = Settings:get("Esp", "Name")
    end

    if drawings.distance then
        drawings.distance.Text = string.format("[%dm]", math.floor(distance + 0.5))
        drawings.distance.Position = Vector2.new(topLeft.X + size.X * 0.5, bottom + 3)
        drawings.distance.Size = Settings:get("Esp", "TextSize") - 1
        drawings.distance.Color = color
        drawings.distance.Visible = Settings:get("Esp", "Distance")
    end

    if drawings.weapon then
        local offset = Settings:get("Esp", "Distance") and 17 or 3
        drawings.weapon.Text = self:_weaponName(record.character)
        drawings.weapon.Position = Vector2.new(topLeft.X + size.X * 0.5, bottom + offset)
        drawings.weapon.Size = Settings:get("Esp", "TextSize") - 1
        drawings.weapon.Color = color
        drawings.weapon.Visible = Settings:get("Esp", "Weapon")
            and drawings.weapon.Text ~= ""
    end
end

function EspController:_tracerOrigin()
    local viewport = Camera.ViewportSize
    local mode = Settings:get("Esp", "TracerOrigin")

    if mode == "Top" then
        return Vector2.new(viewport.X * 0.5, 0)
    end

    if mode == "Mouse" then
        return Utility.getMousePosition()
    end

    return Vector2.new(viewport.X * 0.5, viewport.Y)
end

function EspController:_updateTracer(drawings, target, color)
    local visible = Settings:get("Esp", "Tracer")
    local origin = self:_tracerOrigin()

    self:_setLine(drawings.tracerOutline, origin, target, COLORS.black, visible)
    self:_setLine(drawings.tracer, origin, target, color, visible)
end

function EspController:_updateHeadDot(drawings, character, color)
    local head = character:FindFirstChild("Head")

    if not head or not Settings:get("Esp", "HeadDot") then
        setDrawingVisible(drawings.headDot, false)
        setDrawingVisible(drawings.headDotOutline, false)
        return
    end

    local center, centerVisible = Utility.viewportPoint(head.Position)
    local edge = Utility.viewportPoint(head.Position + Camera.CFrame.UpVector * (head.Size.Y * 0.5))
    local radius = Utility.clamp((center - edge).Magnitude, 2, 14)

    if drawings.headDotOutline then
        drawings.headDotOutline.Position = center
        drawings.headDotOutline.Radius = radius + 1.5
        drawings.headDotOutline.Visible = centerVisible
    end

    if drawings.headDot then
        drawings.headDot.Position = center
        drawings.headDot.Radius = radius
        drawings.headDot.Color = color
        drawings.headDot.Visible = centerVisible
    end
end

function EspController:_updateSkeleton(drawings, character, color)
    local enabled = Settings:get("Esp", "Skeleton")
    local humanoid = Utility.findHumanoid(character)
    local bones = humanoid and humanoid.RigType == Enum.HumanoidRigType.R6
        and R6_BONES
        or R15_BONES

    for index = 1, #R15_BONES do
        local connection = bones[index]
        local visible = false
        local from = Vector2.zero
        local to = Vector2.zero

        if enabled and connection then
            local first = character:FindFirstChild(connection[1])
            local second = character:FindFirstChild(connection[2])

            if first and second then
                local firstScreen, firstVisible = Utility.viewportPoint(first.Position)
                local secondScreen, secondVisible = Utility.viewportPoint(second.Position)

                visible = firstVisible and secondVisible
                from = firstScreen
                to = secondScreen
            end
        end

        self:_setLine(drawings.skeletonOutline[index], from, to, COLORS.black, visible)
        self:_setLine(drawings.skeleton[index], from, to, color, visible)
    end
end

function EspController:_updateArrow(drawings, root, color, onScreen)
    local enabled = Settings:get("Esp", "OffscreenArrow") and not onScreen

    if not enabled or not Camera then
        setDrawingVisible(drawings.arrow, false)
        setDrawingVisible(drawings.arrowOutline, false)
        return
    end

    local viewport = Camera.ViewportSize
    local center = Vector2.new(viewport.X * 0.5, viewport.Y * 0.5)
    local cameraSpace = Camera.CFrame:PointToObjectSpace(root.Position)
    local angle = math.atan2(cameraSpace.X, -cameraSpace.Z)
    local direction = Vector2.new(math.sin(angle), -math.cos(angle))
    local perpendicular = Vector2.new(-direction.Y, direction.X)
    local radius = math.min(
        Settings:get("Esp", "ArrowRadius"),
        math.min(viewport.X, viewport.Y) * 0.45
    )
    local size = Settings:get("Esp", "ArrowSize")
    local tip = center + direction * radius
    local base = tip - direction * size
    local first = base + perpendicular * (size * 0.62)
    local second = base - perpendicular * (size * 0.62)

    if drawings.arrowOutline then
        drawings.arrowOutline.PointA = tip + direction * 2
        drawings.arrowOutline.PointB = first + perpendicular * 1.5
        drawings.arrowOutline.PointC = second - perpendicular * 1.5
        drawings.arrowOutline.Visible = true
    end

    if drawings.arrow then
        drawings.arrow.PointA = tip
        drawings.arrow.PointB = first
        drawings.arrow.PointC = second
        drawings.arrow.Color = color
        drawings.arrow.Visible = true
    end
end

function EspController:_updateHighlight(record, character, color)
    local highlight = self:_ensureHighlight(record, character)
    local enabled = Settings:get("Esp", "Chams")

    highlight.Enabled = enabled
    highlight.FillColor = color
    highlight.OutlineColor = color
    highlight.FillTransparency = Settings:get("Esp", "ChamsFillAlpha")
    highlight.OutlineTransparency = Settings:get("Esp", "ChamsOutlineAlpha")
end

function EspController:_hideRecord(record)
    hideDrawingGroup(record.drawings)

    if record.highlight then
        record.highlight.Enabled = false
    end
end

function EspController:_updateRecord(record)
    local player = record.player
    local character = player.Character

    record.character = character

    if not character or not Utility.isAlive(character) then
        self:_hideRecord(record)
        return
    end

    if Settings:get("Esp", "TeamCheck") and Targeting.isFriendly(player) then
        self:_hideRecord(record)
        return
    end

    local root = Utility.findRoot(character)
    local humanoid = Utility.findHumanoid(character)

    if not root or not humanoid then
        self:_hideRecord(record)
        return
    end

    local distance = Targeting.worldDistance(root)

    if distance > Settings:get("Esp", "MaxDistance") then
        self:_hideRecord(record)
        return
    end

    local visible = Targeting.isVisible(root, character)

    if Settings:get("Esp", "WallCheck") and not visible then
        self:_hideRecord(record)
        return
    end

    local color = self:_color(player, visible)
    local rootScreen, rootOnScreen = Utility.viewportPoint(root.Position)

    self:_updateArrow(record.drawings, root, color, rootOnScreen)
    self:_updateHighlight(record, character, color)

    if not rootOnScreen then
        hideDrawingGroup({
            box = record.drawings.box,
            boxOutline = record.drawings.boxOutline,
            boxFill = record.drawings.boxFill,
            corners = record.drawings.corners,
            cornerOutlines = record.drawings.cornerOutlines,
            name = record.drawings.name,
            distance = record.drawings.distance,
            health = record.drawings.health,
            healthBackground = record.drawings.healthBackground,
            healthText = record.drawings.healthText,
            weapon = record.drawings.weapon,
            tracer = record.drawings.tracer,
            tracerOutline = record.drawings.tracerOutline,
            skeleton = record.drawings.skeleton,
            skeletonOutline = record.drawings.skeletonOutline,
            headDot = record.drawings.headDot,
            headDotOutline = record.drawings.headDotOutline,
        })
        return
    end

    local topLeft, size = self:_screenBox(character)

    if not topLeft then
        self:_hideRecord(record)
        return
    end

    self:_updateBox(record.drawings, topLeft, size, color)
    self:_updateHealth(record.drawings, humanoid, topLeft, size)
    self:_updateText(record, topLeft, size, distance, color)
    self:_updateTracer(record.drawings, rootScreen, color)
    self:_updateHeadDot(record.drawings, character, color)
    self:_updateSkeleton(record.drawings, character, color)
end

function EspController:update(deltaTime)
    if not Settings:get("Esp", "Enabled") then
        for _, record in pairs(self.records) do
            self:_hideRecord(record)
        end

        return
    end

    local updateRate = Settings:get("Esp", "UpdateRate")

    if updateRate > 0 then
        self.accumulator = self.accumulator + deltaTime

        if self.accumulator < updateRate then
            return
        end

        self.accumulator = 0
    end

    for _, record in pairs(self.records) do
        local success, reason = pcall(function()
            self:_updateRecord(record)
        end)

        if not success then
            self:_hideRecord(record)
            warn("vibecode ESP update failed for", record.player.Name, reason)
        end
    end
end

function EspController:Destroy()
    local players = {}

    for player in pairs(self.records) do
        players[#players + 1] = player
    end

    for _, player in ipairs(players) do
        self:_destroyRecord(player)
    end
end

local ESP = EspController.new()

-- // Overlay

local Overlay = {}
Overlay.__index = Overlay

function Overlay.new()
    local self = setmetatable({}, Overlay)

    self.drawings = {}
    self.drawings.fovOutline = newDrawing("Circle", {
        Visible = false,
        Filled = false,
        Thickness = 3.5,
        NumSides = 64,
        Radius = 150,
        Color = COLORS.black,
        Transparency = 0.65,
    })
    self.drawings.fov = newDrawing("Circle", {
        Visible = false,
        Filled = false,
        Thickness = 1.5,
        NumSides = 64,
        Radius = 150,
        Color = COLORS.accent,
        Transparency = 1,
    })
    self.drawings.targetLineOutline = newDrawing("Line", {
        Visible = false,
        Thickness = 3.5,
        Color = COLORS.black,
        Transparency = 0.65,
    })
    self.drawings.targetLine = newDrawing("Line", {
        Visible = false,
        Thickness = 1.5,
        Color = COLORS.accentLight,
        Transparency = 1,
    })
    self.drawings.targetName = newDrawing("Text", {
        Visible = false,
        Center = true,
        Outline = true,
        Font = 2,
        Size = 13,
        Color = COLORS.text,
        Transparency = 1,
        Text = "",
    })
    self.drawings.crosshair = {}
    self.drawings.crosshairOutline = {}

    for index = 1, 4 do
        self.drawings.crosshairOutline[index] = newDrawing("Line", {
            Visible = false,
            Thickness = 3.5,
            Color = COLORS.black,
            Transparency = 0.7,
        })
        self.drawings.crosshair[index] = newDrawing("Line", {
            Visible = false,
            Thickness = 1.5,
            Color = COLORS.accentLight,
            Transparency = 1,
        })
    end

    return self
end

function Overlay:_accent()
    if Settings:get("Visuals", "RainbowFov") then
        return Utility.hsvClock(0.13)
    end

    return Utility.colorFromSettings(Settings.values.General, "Accent")
end

function Overlay:_updateFov(mouse, accent)
    local visible = Settings:get("Visuals", "FovCircle")
        and Settings:get("Aim", "Enabled")
    local radius = Targeting.effectiveFov()
    local filled = Settings:get("Visuals", "FovFilled")

    if self.drawings.fovOutline then
        self.drawings.fovOutline.Position = mouse
        self.drawings.fovOutline.Radius = radius
        self.drawings.fovOutline.NumSides = Settings:get("Visuals", "FovSides")
        self.drawings.fovOutline.Visible = visible and not filled
    end

    if self.drawings.fov then
        self.drawings.fov.Position = mouse
        self.drawings.fov.Radius = radius
        self.drawings.fov.NumSides = Settings:get("Visuals", "FovSides")
        self.drawings.fov.Thickness = Settings:get("Visuals", "FovThickness")
        self.drawings.fov.Filled = filled
        self.drawings.fov.Transparency = filled
            and (1 - Settings:get("Visuals", "FovAlpha"))
            or 1
        self.drawings.fov.Color = accent
        self.drawings.fov.Visible = visible
    end
end

function Overlay:_updateCrosshair(mouse, accent)
    local enabled = Settings:get("Visuals", "Crosshair")
    local size = Settings:get("Visuals", "CrosshairSize")
    local gap = Settings:get("Visuals", "CrosshairGap")
    local segments = {
        { Vector2.new(mouse.X - gap, mouse.Y), Vector2.new(mouse.X - gap - size, mouse.Y) },
        { Vector2.new(mouse.X + gap, mouse.Y), Vector2.new(mouse.X + gap + size, mouse.Y) },
        { Vector2.new(mouse.X, mouse.Y - gap), Vector2.new(mouse.X, mouse.Y - gap - size) },
        { Vector2.new(mouse.X, mouse.Y + gap), Vector2.new(mouse.X, mouse.Y + gap + size) },
    }

    for index, segment in ipairs(segments) do
        local outline = self.drawings.crosshairOutline[index]
        local line = self.drawings.crosshair[index]

        if outline then
            outline.From = segment[1]
            outline.To = segment[2]
            outline.Visible = enabled
        end

        if line then
            line.From = segment[1]
            line.To = segment[2]
            line.Color = accent
            line.Thickness = Settings:get("Visuals", "CrosshairThickness")
            line.Visible = enabled
        end
    end
end

function Overlay:_updateTarget(mouse, accent)
    local target = Aim.target
    local hasTarget = target ~= nil and Aim:isActive()
    local lineEnabled = hasTarget and Settings:get("Visuals", "TargetLine")
    local nameEnabled = hasTarget and Settings:get("Visuals", "TargetName")

    if not hasTarget then
        setDrawingVisible(self.drawings.targetLine, false)
        setDrawingVisible(self.drawings.targetLineOutline, false)
        setDrawingVisible(self.drawings.targetName, false)
        return
    end

    local screen, onScreen = Utility.viewportPoint(target.part.Position)

    if not onScreen then
        setDrawingVisible(self.drawings.targetLine, false)
        setDrawingVisible(self.drawings.targetLineOutline, false)
        setDrawingVisible(self.drawings.targetName, false)
        return
    end

    if self.drawings.targetLineOutline then
        self.drawings.targetLineOutline.From = mouse
        self.drawings.targetLineOutline.To = screen
        self.drawings.targetLineOutline.Visible = lineEnabled
    end

    if self.drawings.targetLine then
        self.drawings.targetLine.From = mouse
        self.drawings.targetLine.To = screen
        self.drawings.targetLine.Color = accent
        self.drawings.targetLine.Visible = lineEnabled
    end

    if self.drawings.targetName then
        self.drawings.targetName.Text = string.format(
            "%s  |  %dm  |  %d HP",
            target.player.Name,
            math.floor(target.worldDistance + 0.5),
            math.floor(target.humanoid.Health + 0.5)
        )
        self.drawings.targetName.Position = mouse + Vector2.new(0, 22)
        self.drawings.targetName.Color = accent
        self.drawings.targetName.Visible = nameEnabled
    end
end

function Overlay:update()
    if not Capabilities.drawing then
        return
    end

    local mouse = Utility.getMousePosition()
    local accent = self:_accent()

    self:_updateFov(mouse, accent)
    self:_updateCrosshair(mouse, accent)
    self:_updateTarget(mouse, accent)
end

function Overlay:Destroy()
    removeDrawingGroup(self.drawings)
end

local HUD = Overlay.new()

-- // GUI library

local Library = {}
Library.__index = Library

local CONTROL_HEIGHT = 38
local SECTION_GAP = 8
local PANEL_WIDTH = 500
local PANEL_HEIGHT = 610

function Library.new()
    local self = setmetatable({}, Library)

    self.maid = Maid.new()
    self.tabs = {}
    self.controls = {}
    self.notifications = {}
    self.selectedTab = nil
    self.visible = true
    self.destroyed = false
    self.dragging = false
    self.dragStart = nil
    self.startPosition = nil
    self.accent = Utility.colorFromSettings(Settings.values.General, "Accent")

    self:_buildRoot()
    self:_buildWindow()
    self:_wireDragging()

    return self
end

function Library:_buildRoot()
    local previous = Utility.getGuiParent():FindFirstChild(GUI_NAME)

    if previous then
        Utility.safeDestroy(previous)
    end

    local screenGui = Utility.create("ScreenGui", {
        Name = GUI_NAME,
        ResetOnSpawn = false,
        IgnoreGuiInset = false,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
        DisplayOrder = 1000000,
    })

    if Capabilities.protectGui then
        pcall(function()
            syn.protect_gui(screenGui)
        end)
    end

    screenGui.Parent = Utility.getGuiParent()
    self.gui = screenGui
    self.maid:give(screenGui)

    self.notificationHost = Utility.create("Frame", {
        Name = "Notifications",
        AnchorPoint = Vector2.new(1, 1),
        Position = UDim2.new(1, -18, 1, -18),
        Size = UDim2.fromOffset(310, 350),
        BackgroundTransparency = 1,
        Parent = screenGui,
    })

    Utility.create("UIListLayout", {
        Padding = UDim.new(0, 8),
        HorizontalAlignment = Enum.HorizontalAlignment.Right,
        VerticalAlignment = Enum.VerticalAlignment.Bottom,
        SortOrder = Enum.SortOrder.LayoutOrder,
        Parent = self.notificationHost,
    })
end

function Library:_buildWindow()
    self.shadow = Utility.create("ImageLabel", {
        Name = "Shadow",
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0.5, 0.5),
        Size = UDim2.fromOffset(PANEL_WIDTH + 54, PANEL_HEIGHT + 54),
        BackgroundTransparency = 1,
        Image = "rbxassetid://6015897843",
        ImageColor3 = COLORS.black,
        ImageTransparency = 0.3,
        ScaleType = Enum.ScaleType.Slice,
        SliceCenter = Rect.new(49, 49, 450, 450),
        Parent = self.gui,
    })

    self.main = Utility.create("Frame", {
        Name = "Window",
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0.5, 0.5),
        Size = UDim2.fromOffset(PANEL_WIDTH, PANEL_HEIGHT),
        BackgroundColor3 = COLORS.background,
        BorderSizePixel = 0,
        ClipsDescendants = true,
        Parent = self.gui,
    }, {
        Utility.create("UICorner", {
            CornerRadius = UDim.new(0, 10),
        }),
        Utility.create("UIStroke", {
            Color = COLORS.border,
            Thickness = 1,
            Transparency = 0.15,
        }),
    })

    self.topbar = Utility.create("Frame", {
        Name = "Topbar",
        Size = UDim2.new(1, 0, 0, 58),
        BackgroundColor3 = COLORS.surface,
        BorderSizePixel = 0,
        Parent = self.main,
    })

    Utility.create("Frame", {
        Name = "Accent",
        Position = UDim2.new(0, 0, 1, -2),
        Size = UDim2.new(1, 0, 0, 2),
        BackgroundColor3 = self.accent,
        BorderSizePixel = 0,
        Parent = self.topbar,
    })

    Utility.create("TextLabel", {
        Name = "Title",
        Position = UDim2.fromOffset(18, 8),
        Size = UDim2.new(1, -80, 0, 24),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold,
        Text = "vibecode",
        TextColor3 = COLORS.text,
        TextSize = 20,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = self.topbar,
    })

    Utility.create("TextLabel", {
        Name = "Version",
        Position = UDim2.fromOffset(19, 31),
        Size = UDim2.new(1, -80, 0, 16),
        BackgroundTransparency = 1,
        Font = Enum.Font.Gotham,
        Text = "universal suite  •  v" .. PRODUCT_VERSION,
        TextColor3 = COLORS.textMuted,
        TextSize = 11,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = self.topbar,
    })

    self.closeButton = Utility.create("TextButton", {
        Name = "Close",
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -16, 0.5, 0),
        Size = UDim2.fromOffset(32, 32),
        BackgroundColor3 = COLORS.surfaceRaised,
        AutoButtonColor = false,
        Font = Enum.Font.GothamBold,
        Text = "×",
        TextColor3 = COLORS.textMuted,
        TextSize = 22,
        Parent = self.topbar,
    }, {
        Utility.create("UICorner", {
            CornerRadius = UDim.new(0, 7),
        }),
    })

    self.maid:give(self.closeButton.MouseEnter:Connect(function()
        Utility.tween(self.closeButton, 0.15, {
            BackgroundColor3 = COLORS.danger,
            TextColor3 = COLORS.white,
        })
    end))

    self.maid:give(self.closeButton.MouseLeave:Connect(function()
        Utility.tween(self.closeButton, 0.15, {
            BackgroundColor3 = COLORS.surfaceRaised,
            TextColor3 = COLORS.textMuted,
        })
    end))

    self.maid:give(self.closeButton.MouseButton1Click:Connect(function()
        self:setVisible(false)
    end))

    self.sidebar = Utility.create("Frame", {
        Name = "Sidebar",
        Position = UDim2.fromOffset(0, 58),
        Size = UDim2.new(0, 126, 1, -58),
        BackgroundColor3 = COLORS.surface,
        BorderSizePixel = 0,
        Parent = self.main,
    })

    self.tabList = Utility.create("Frame", {
        Name = "TabList",
        Position = UDim2.fromOffset(8, 12),
        Size = UDim2.new(1, -16, 1, -24),
        BackgroundTransparency = 1,
        Parent = self.sidebar,
    })

    Utility.create("UIListLayout", {
        Padding = UDim.new(0, 6),
        FillDirection = Enum.FillDirection.Vertical,
        HorizontalAlignment = Enum.HorizontalAlignment.Center,
        SortOrder = Enum.SortOrder.LayoutOrder,
        Parent = self.tabList,
    })

    self.content = Utility.create("Frame", {
        Name = "Content",
        Position = UDim2.fromOffset(126, 58),
        Size = UDim2.new(1, -126, 1, -58),
        BackgroundColor3 = COLORS.background,
        BorderSizePixel = 0,
        ClipsDescendants = true,
        Parent = self.main,
    })

    self.watermark = Utility.create("TextLabel", {
        Name = "Watermark",
        AnchorPoint = Vector2.new(1, 0),
        Position = UDim2.new(1, -14, 0, 14),
        Size = UDim2.fromOffset(230, 30),
        BackgroundColor3 = COLORS.surface,
        BackgroundTransparency = 0.08,
        BorderSizePixel = 0,
        Font = Enum.Font.GothamSemibold,
        Text = string.format("  %s  |  %s", PRODUCT_NAME, LocalPlayer.Name),
        TextColor3 = COLORS.text,
        TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left,
        Visible = Settings:get("General", "Watermark"),
        Parent = self.gui,
    }, {
        Utility.create("UICorner", {
            CornerRadius = UDim.new(0, 7),
        }),
        Utility.create("UIStroke", {
            Color = self.accent,
            Thickness = 1,
            Transparency = 0.25,
        }),
    })
end

function Library:_wireDragging()
    self.maid:give(self.topbar.InputBegan:Connect(function(input)
        if input.UserInputType ~= Enum.UserInputType.MouseButton1 then
            return
        end

        self.dragging = true
        self.dragStart = input.Position
        self.startPosition = self.main.Position
    end))

    self.maid:give(UserInputService.InputChanged:Connect(function(input)
        if not self.dragging or input.UserInputType ~= Enum.UserInputType.MouseMovement then
            return
        end

        local delta = input.Position - self.dragStart
        local target = UDim2.new(
            self.startPosition.X.Scale,
            self.startPosition.X.Offset + delta.X,
            self.startPosition.Y.Scale,
            self.startPosition.Y.Offset + delta.Y
        )

        self.main.Position = target
        self.shadow.Position = target
    end))

    self.maid:give(UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            self.dragging = false
        end
    end))
end

function Library:_newPage(name)
    local page = Utility.create("ScrollingFrame", {
        Name = name .. "Page",
        Position = UDim2.fromOffset(0, 0),
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        CanvasSize = UDim2.fromOffset(0, 0),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        ScrollBarThickness = 3,
        ScrollBarImageColor3 = self.accent,
        ScrollingDirection = Enum.ScrollingDirection.Y,
        Visible = false,
        Parent = self.content,
    })

    Utility.create("UIPadding", {
        PaddingTop = UDim.new(0, 14),
        PaddingBottom = UDim.new(0, 14),
        PaddingLeft = UDim.new(0, 14),
        PaddingRight = UDim.new(0, 14),
        Parent = page,
    })

    Utility.create("UIListLayout", {
        Padding = UDim.new(0, SECTION_GAP),
        FillDirection = Enum.FillDirection.Vertical,
        HorizontalAlignment = Enum.HorizontalAlignment.Center,
        SortOrder = Enum.SortOrder.LayoutOrder,
        Parent = page,
    })

    return page
end

function Library:addTab(name, glyph)
    local tab = {
        name = name,
        page = self:_newPage(name),
        controls = {},
    }

    tab.button = Utility.create("TextButton", {
        Name = name,
        Size = UDim2.new(1, 0, 0, 38),
        BackgroundColor3 = COLORS.surface,
        BackgroundTransparency = 1,
        AutoButtonColor = false,
        Font = Enum.Font.GothamSemibold,
        Text = string.format("%s  %s", glyph or "•", name),
        TextColor3 = COLORS.textMuted,
        TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = self.tabList,
    }, {
        Utility.create("UICorner", {
            CornerRadius = UDim.new(0, 7),
        }),
        Utility.create("UIPadding", {
            PaddingLeft = UDim.new(0, 12),
        }),
    })

    self.maid:give(tab.button.MouseButton1Click:Connect(function()
        self:selectTab(name)
    end))

    self.maid:give(tab.button.MouseEnter:Connect(function()
        if self.selectedTab ~= tab then
            Utility.tween(tab.button, 0.12, {
                BackgroundTransparency = 0.35,
                BackgroundColor3 = COLORS.surfaceRaised,
                TextColor3 = COLORS.text,
            })
        end
    end))

    self.maid:give(tab.button.MouseLeave:Connect(function()
        if self.selectedTab ~= tab then
            Utility.tween(tab.button, 0.12, {
                BackgroundTransparency = 1,
                TextColor3 = COLORS.textMuted,
            })
        end
    end))

    self.tabs[name] = tab

    if not self.selectedTab then
        self:selectTab(name)
    end

    return tab
end

function Library:selectTab(name)
    local selected = self.tabs[name]

    if not selected then
        return
    end

    for _, tab in pairs(self.tabs) do
        local active = tab == selected

        tab.page.Visible = active

        Utility.tween(tab.button, 0.15, {
            BackgroundTransparency = active and 0 or 1,
            BackgroundColor3 = active and self.accent or COLORS.surface,
            TextColor3 = active and COLORS.white or COLORS.textMuted,
        })
    end

    self.selectedTab = selected
end

function Library:addSection(tab, title)
    local section = Utility.create("Frame", {
        Name = title,
        Size = UDim2.new(1, 0, 0, 44),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundColor3 = COLORS.surface,
        BorderSizePixel = 0,
        Parent = tab.page,
    }, {
        Utility.create("UICorner", {
            CornerRadius = UDim.new(0, 8),
        }),
        Utility.create("UIStroke", {
            Color = COLORS.border,
            Thickness = 1,
            Transparency = 0.35,
        }),
    })

    Utility.create("TextLabel", {
        Name = "SectionTitle",
        Size = UDim2.new(1, 0, 0, 36),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold,
        Text = title,
        TextColor3 = COLORS.text,
        TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = section,
    }, {
        Utility.create("UIPadding", {
            PaddingLeft = UDim.new(0, 12),
        }),
    })

    local body = Utility.create("Frame", {
        Name = "Body",
        Position = UDim2.fromOffset(0, 36),
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        Parent = section,
    })

    Utility.create("UIListLayout", {
        Padding = UDim.new(0, 2),
        FillDirection = Enum.FillDirection.Vertical,
        SortOrder = Enum.SortOrder.LayoutOrder,
        Parent = body,
    })

    Utility.create("UIPadding", {
        PaddingBottom = UDim.new(0, 8),
        Parent = body,
    })

    return body
end

function Library:_controlRow(parent, name, height)
    local row = Utility.create("Frame", {
        Name = name,
        Size = UDim2.new(1, 0, 0, height or CONTROL_HEIGHT),
        BackgroundColor3 = COLORS.surface,
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Parent = parent,
    })

    Utility.create("TextLabel", {
        Name = "Label",
        Position = UDim2.fromOffset(12, 0),
        Size = UDim2.new(0.58, -12, 1, 0),
        BackgroundTransparency = 1,
        Font = Enum.Font.Gotham,
        Text = name,
        TextColor3 = COLORS.text,
        TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = row,
    })

    self.maid:give(row.MouseEnter:Connect(function()
        Utility.tween(row, 0.1, {
            BackgroundTransparency = 0.35,
            BackgroundColor3 = COLORS.surfaceRaised,
        })
    end))

    self.maid:give(row.MouseLeave:Connect(function()
        Utility.tween(row, 0.1, {
            BackgroundTransparency = 1,
        })
    end))

    return row
end

function Library:addToggle(parent, options)
    local library = self
    local row = self:_controlRow(parent, options.name)
    local value = options.value == true

    local track = Utility.create("TextButton", {
        Name = "Toggle",
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -12, 0.5, 0),
        Size = UDim2.fromOffset(42, 22),
        BackgroundColor3 = value and self.accent or COLORS.surfaceRaised,
        AutoButtonColor = false,
        Text = "",
        Parent = row,
    }, {
        Utility.create("UICorner", {
            CornerRadius = UDim.new(1, 0),
        }),
    })

    local knob = Utility.create("Frame", {
        Name = "Knob",
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = value and UDim2.new(1, -11, 0.5, 0) or UDim2.new(0, 11, 0.5, 0),
        Size = UDim2.fromOffset(16, 16),
        BackgroundColor3 = COLORS.white,
        BorderSizePixel = 0,
        Parent = track,
    }, {
        Utility.create("UICorner", {
            CornerRadius = UDim.new(1, 0),
        }),
    })

    local control = {}

    function control:set(nextValue, invoke)
        value = nextValue == true

        Utility.tween(track, 0.16, {
            BackgroundColor3 = value and library.accent or COLORS.surfaceRaised,
        })
        Utility.tween(knob, 0.16, {
            Position = value
                and UDim2.new(1, -11, 0.5, 0)
                or UDim2.new(0, 11, 0.5, 0),
        })

        if invoke ~= false and options.callback then
            options.callback(value)
        end
    end

    function control:get()
        return value
    end

    self.maid:give(track.MouseButton1Click:Connect(function()
        control:set(not value, true)
    end))

    self.controls[#self.controls + 1] = control
    return control
end

function Library:addSlider(parent, options)
    local library = self
    local row = self:_controlRow(parent, options.name, 52)
    local minimum = options.minimum
    local maximum = options.maximum
    local step = options.step or 1
    local suffix = options.suffix or ""
    local value = Utility.clamp(options.value, minimum, maximum)
    local sliding = false

    local valueLabel = Utility.create("TextLabel", {
        Name = "Value",
        AnchorPoint = Vector2.new(1, 0),
        Position = UDim2.new(1, -12, 0, 5),
        Size = UDim2.fromOffset(110, 20),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamSemibold,
        Text = tostring(value) .. suffix,
        TextColor3 = self.accent,
        TextSize = 11,
        TextXAlignment = Enum.TextXAlignment.Right,
        Parent = row,
    })

    local track = Utility.create("TextButton", {
        Name = "Track",
        Position = UDim2.new(0, 12, 1, -15),
        Size = UDim2.new(1, -24, 0, 5),
        BackgroundColor3 = COLORS.surfaceRaised,
        AutoButtonColor = false,
        Text = "",
        Parent = row,
    }, {
        Utility.create("UICorner", {
            CornerRadius = UDim.new(1, 0),
        }),
    })

    local fill = Utility.create("Frame", {
        Name = "Fill",
        Size = UDim2.fromScale((value - minimum) / (maximum - minimum), 1),
        BackgroundColor3 = self.accent,
        BorderSizePixel = 0,
        Parent = track,
    }, {
        Utility.create("UICorner", {
            CornerRadius = UDim.new(1, 0),
        }),
    })

    local knob = Utility.create("Frame", {
        Name = "Knob",
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.new((value - minimum) / (maximum - minimum), 0, 0.5, 0),
        Size = UDim2.fromOffset(11, 11),
        BackgroundColor3 = COLORS.white,
        BorderSizePixel = 0,
        Parent = track,
    }, {
        Utility.create("UICorner", {
            CornerRadius = UDim.new(1, 0),
        }),
    })

    local control = {}

    function control:set(nextValue, invoke)
        nextValue = Utility.clamp(nextValue, minimum, maximum)
        nextValue = Utility.round(math.floor((nextValue / step) + 0.5) * step, 4)
        value = nextValue

        local alpha = (value - minimum) / (maximum - minimum)

        fill.Size = UDim2.fromScale(alpha, 1)
        knob.Position = UDim2.new(alpha, 0, 0.5, 0)
        valueLabel.Text = tostring(value) .. suffix

        if invoke ~= false and options.callback then
            options.callback(value)
        end
    end

    function control:get()
        return value
    end

    local function updateFromMouse()
        local mouseX = UserInputService:GetMouseLocation().X
        local alpha = Utility.clamp(
            (mouseX - track.AbsolutePosition.X) / track.AbsoluteSize.X,
            0,
            1
        )

        control:set(minimum + (maximum - minimum) * alpha, true)
    end

    self.maid:give(track.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            sliding = true
            updateFromMouse()
        end
    end))

    self.maid:give(UserInputService.InputChanged:Connect(function(input)
        if sliding and input.UserInputType == Enum.UserInputType.MouseMovement then
            updateFromMouse()
        end
    end))

    self.maid:give(UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            sliding = false
        end
    end))

    self.controls[#self.controls + 1] = control
    return control
end

function Library:addDropdown(parent, options)
    local library = self
    local row = self:_controlRow(parent, options.name)
    local values = options.values
    local selected = options.value
    local expanded = false

    local button = Utility.create("TextButton", {
        Name = "Dropdown",
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -12, 0.5, 0),
        Size = UDim2.fromOffset(134, 26),
        BackgroundColor3 = COLORS.surfaceRaised,
        AutoButtonColor = false,
        Font = Enum.Font.GothamSemibold,
        Text = tostring(selected) .. "   ▾",
        TextColor3 = COLORS.text,
        TextSize = 11,
        Parent = row,
    }, {
        Utility.create("UICorner", {
            CornerRadius = UDim.new(0, 6),
        }),
        Utility.create("UIStroke", {
            Color = COLORS.border,
            Thickness = 1,
            Transparency = 0.25,
        }),
    })

    local menu = Utility.create("Frame", {
        Name = "Options",
        AnchorPoint = Vector2.new(1, 0),
        Position = UDim2.new(1, -12, 1, 1),
        Size = UDim2.fromOffset(134, #values * 27 + 4),
        BackgroundColor3 = COLORS.surfaceRaised,
        BorderSizePixel = 0,
        Visible = false,
        ZIndex = 50,
        Parent = row,
    }, {
        Utility.create("UICorner", {
            CornerRadius = UDim.new(0, 6),
        }),
        Utility.create("UIStroke", {
            Color = COLORS.border,
            Thickness = 1,
        }),
        Utility.create("UIListLayout", {
            Padding = UDim.new(0, 1),
            SortOrder = Enum.SortOrder.LayoutOrder,
        }),
        Utility.create("UIPadding", {
            PaddingTop = UDim.new(0, 2),
            PaddingBottom = UDim.new(0, 2),
        }),
    })

    local control = {}

    function control:set(nextValue, invoke)
        local valid = false

        for _, candidate in ipairs(values) do
            if candidate == nextValue then
                valid = true
                break
            end
        end

        if not valid then
            return
        end

        selected = nextValue
        button.Text = tostring(selected) .. "   ▾"

        if invoke ~= false and options.callback then
            options.callback(selected)
        end
    end

    function control:get()
        return selected
    end

    local function setExpanded(nextExpanded)
        expanded = nextExpanded
        menu.Visible = expanded
        row.ZIndex = expanded and 40 or 1
        menu.ZIndex = 50
        button.Text = tostring(selected) .. (expanded and "   ▴" or "   ▾")
    end

    for _, candidate in ipairs(values) do
        local optionValue = candidate
        local optionButton = Utility.create("TextButton", {
            Name = tostring(optionValue),
            Size = UDim2.new(1, 0, 0, 26),
            BackgroundColor3 = COLORS.surfaceRaised,
            BackgroundTransparency = 1,
            AutoButtonColor = false,
            Font = Enum.Font.Gotham,
            Text = tostring(optionValue),
            TextColor3 = COLORS.textMuted,
            TextSize = 11,
            ZIndex = 51,
            Parent = menu,
        })

        self.maid:give(optionButton.MouseEnter:Connect(function()
            optionButton.BackgroundTransparency = 0
            optionButton.BackgroundColor3 = library.accent
            optionButton.TextColor3 = COLORS.white
        end))

        self.maid:give(optionButton.MouseLeave:Connect(function()
            optionButton.BackgroundTransparency = 1
            optionButton.TextColor3 = COLORS.textMuted
        end))

        self.maid:give(optionButton.MouseButton1Click:Connect(function()
            control:set(optionValue, true)
            setExpanded(false)
        end))
    end

    self.maid:give(button.MouseButton1Click:Connect(function()
        setExpanded(not expanded)
    end))

    self.controls[#self.controls + 1] = control
    return control
end

function Library:addKeybind(parent, options)
    local library = self
    local row = self:_controlRow(parent, options.name)
    local value = options.value
    local capturing = false

    local button = Utility.create("TextButton", {
        Name = "Keybind",
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -12, 0.5, 0),
        Size = UDim2.fromOffset(92, 26),
        BackgroundColor3 = COLORS.surfaceRaised,
        AutoButtonColor = false,
        Font = Enum.Font.Code,
        Text = Utility.formatKey(value),
        TextColor3 = self.accent,
        TextSize = 11,
        Parent = row,
    }, {
        Utility.create("UICorner", {
            CornerRadius = UDim.new(0, 6),
        }),
        Utility.create("UIStroke", {
            Color = COLORS.border,
            Thickness = 1,
            Transparency = 0.25,
        }),
    })

    local control = {}

    function control:set(nextValue, invoke)
        value = nextValue
        capturing = false
        button.Text = Utility.formatKey(value)
        button.TextColor3 = library.accent

        if invoke ~= false and options.callback then
            options.callback(value)
        end
    end

    function control:get()
        return value
    end

    self.maid:give(button.MouseButton1Click:Connect(function()
        capturing = true
        button.Text = "..."
        button.TextColor3 = COLORS.warning

        Input:capture(function(name)
            if name == "Escape" then
                capturing = false
                button.Text = Utility.formatKey(value)
                button.TextColor3 = library.accent
                return
            end

            control:set(name, true)
        end)
    end))

    self.controls[#self.controls + 1] = control
    return control
end

function Library:addButton(parent, options)
    local row = self:_controlRow(parent, options.name)

    local button = Utility.create("TextButton", {
        Name = "Action",
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -12, 0.5, 0),
        Size = UDim2.fromOffset(110, 26),
        BackgroundColor3 = self.accent,
        AutoButtonColor = false,
        Font = Enum.Font.GothamSemibold,
        Text = options.buttonText or "Run",
        TextColor3 = COLORS.white,
        TextSize = 11,
        Parent = row,
    }, {
        Utility.create("UICorner", {
            CornerRadius = UDim.new(0, 6),
        }),
    })

    self.maid:give(button.MouseEnter:Connect(function()
        Utility.tween(button, 0.12, {
            BackgroundColor3 = self.accent:Lerp(COLORS.white, 0.15),
        })
    end))

    self.maid:give(button.MouseLeave:Connect(function()
        Utility.tween(button, 0.12, {
            BackgroundColor3 = self.accent,
        })
    end))

    self.maid:give(button.MouseButton1Click:Connect(function()
        if options.callback then
            task.spawn(options.callback)
        end
    end))

    return button
end

function Library:addLabel(parent, text, color)
    return Utility.create("TextLabel", {
        Name = "Information",
        Size = UDim2.new(1, 0, 0, 38),
        BackgroundTransparency = 1,
        Font = Enum.Font.Gotham,
        Text = text,
        TextColor3 = color or COLORS.textMuted,
        TextSize = 11,
        TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = parent,
    }, {
        Utility.create("UIPadding", {
            PaddingLeft = UDim.new(0, 12),
            PaddingRight = UDim.new(0, 12),
        }),
    })
end

function Library:notify(title, message, duration)
    if not Settings:get("General", "Notifications") then
        return
    end

    local card = Utility.create("Frame", {
        Name = "Notification",
        Size = UDim2.fromOffset(0, 68),
        BackgroundColor3 = COLORS.surface,
        BackgroundTransparency = 0.03,
        BorderSizePixel = 0,
        ClipsDescendants = true,
        Parent = self.notificationHost,
    }, {
        Utility.create("UICorner", {
            CornerRadius = UDim.new(0, 8),
        }),
        Utility.create("UIStroke", {
            Color = self.accent,
            Thickness = 1,
            Transparency = 0.2,
        }),
    })

    Utility.create("TextLabel", {
        Position = UDim2.fromOffset(12, 8),
        Size = UDim2.new(1, -24, 0, 20),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold,
        Text = title,
        TextColor3 = COLORS.text,
        TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = card,
    })

    Utility.create("TextLabel", {
        Position = UDim2.fromOffset(12, 29),
        Size = UDim2.new(1, -24, 0, 29),
        BackgroundTransparency = 1,
        Font = Enum.Font.Gotham,
        Text = message,
        TextColor3 = COLORS.textMuted,
        TextSize = 11,
        TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = card,
    })

    Utility.tween(card, 0.25, {
        Size = UDim2.fromOffset(310, 68),
    })

    task.delay(duration or 3, function()
        if not card.Parent then
            return
        end

        local tween = Utility.tween(card, 0.2, {
            Size = UDim2.fromOffset(0, 68),
            BackgroundTransparency = 1,
        })

        tween.Completed:Wait()
        Utility.safeDestroy(card)
    end)
end

function Library:setVisible(visible)
    self.visible = visible == true
    self.main.Visible = self.visible
    self.shadow.Visible = self.visible
    Settings:set("General", "MenuVisible", self.visible, true)
end

function Library:toggle()
    self:setVisible(not self.visible)
end

function Library:setAccent(color)
    self.accent = color

    for _, descendant in ipairs(self.main:GetDescendants()) do
        if descendant.Name == "Accent" or descendant.Name == "Fill" then
            if descendant:IsA("GuiObject") then
                descendant.BackgroundColor3 = color
            end
        elseif descendant.Name == "Value" or descendant.Name == "Keybind" then
            if descendant:IsA("TextLabel") or descendant:IsA("TextButton") then
                descendant.TextColor3 = color
            end
        elseif descendant:IsA("ScrollingFrame") then
            descendant.ScrollBarImageColor3 = color
        end
    end

    if self.watermark then
        local stroke = self.watermark:FindFirstChildOfClass("UIStroke")

        if stroke then
            stroke.Color = color
        end
    end

    if self.selectedTab then
        self.selectedTab.button.BackgroundColor3 = color
    end
end

function Library:Destroy()
    if self.destroyed then
        return
    end

    self.destroyed = true
    Input:cancelCapture()
    self.maid:clean()
end

-- // GUI composition

local UI = Library.new()

local function bindToggle(parent, section, key, label)
    return UI:addToggle(parent, {
        name = label or key,
        value = Settings:get(section, key),
        callback = function(value)
            Settings:set(section, key, value)
        end,
    })
end

local function bindSlider(parent, section, key, label, minimum, maximum, step, suffix)
    return UI:addSlider(parent, {
        name = label or key,
        value = Settings:get(section, key),
        minimum = minimum,
        maximum = maximum,
        step = step,
        suffix = suffix,
        callback = function(value)
            Settings:set(section, key, value)
        end,
    })
end

local function bindDropdown(parent, section, key, label, values)
    return UI:addDropdown(parent, {
        name = label or key,
        value = Settings:get(section, key),
        values = values,
        callback = function(value)
            Settings:set(section, key, value)
        end,
    })
end

local function bindKey(parent, section, key, label)
    return UI:addKeybind(parent, {
        name = label or key,
        value = Settings:get(section, key),
        callback = function(value)
            Settings:set(section, key, value)
        end,
    })
end

local AimTab = UI:addTab("Aim", "◎")
local TriggerTab = UI:addTab("Trigger", "◆")
local EspTab = UI:addTab("ESP", "◇")
local VisualTab = UI:addTab("Visuals", "✦")
local ConfigTab = UI:addTab("Config", "⚙")

do
    local activation = UI:addSection(AimTab, "Activation")
    bindToggle(activation, "Aim", "Enabled", "Master switch")
    bindDropdown(activation, "Aim", "ActiveMode", "Activation mode", {
        "Hold",
        "Toggle",
        "Always",
    })
    bindKey(activation, "Aim", "Key", "Aim key")
    bindDropdown(activation, "Aim", "Output", "Aim output", {
        "Mouse",
        "Camera",
    })

    local selection = UI:addSection(AimTab, "Target selection")
    bindDropdown(selection, "Aim", "AimPart", "Aim bone", {
        "Head",
        "UpperTorso",
        "Torso",
        "HumanoidRootPart",
        "LowerTorso",
    })
    bindDropdown(selection, "Aim", "TargetMode", "Priority", {
        "Crosshair",
        "Distance",
        "Health",
    })
    bindToggle(selection, "Aim", "Sticky", "Sticky target")
    bindSlider(selection, "Aim", "StickyFovMultiplier", "Sticky FOV scale", 1, 2.5, 0.05, "x")
    bindSlider(selection, "Aim", "SwitchDelay", "Switch delay", 0, 0.5, 0.01, "s")

    local checks = UI:addSection(AimTab, "Validation")
    bindToggle(checks, "Aim", "TeamCheck", "Team check")
    bindToggle(checks, "Aim", "WallCheck", "Visibility check")
    bindToggle(checks, "Aim", "AliveCheck", "Alive check")
    bindToggle(checks, "Aim", "ForceFieldCheck", "Ignore ForceField")
    bindToggle(checks, "Aim", "IgnoreFriends", "Ignore friends")
    bindSlider(checks, "Aim", "MaxDistance", "Maximum distance", 50, 5000, 50, "m")

    local fieldOfView = UI:addSection(AimTab, "Field of view")
    bindSlider(fieldOfView, "Aim", "Fov", "Radius", 10, 800, 1, "px")
    bindToggle(fieldOfView, "Aim", "DynamicFov", "Scale with camera FOV")
    bindSlider(fieldOfView, "Aim", "ReferenceFov", "Reference camera FOV", 30, 120, 1, "°")

    local smoothing = UI:addSection(AimTab, "Smoothing")
    bindSlider(smoothing, "Aim", "Smoothness", "Horizontal smoothness", 1, 40, 0.25, "x")
    bindSlider(smoothing, "Aim", "VerticalSmoothness", "Vertical smoothness", 1, 40, 0.25, "x")
    bindSlider(smoothing, "Aim", "MaxStep", "Maximum frame step", 5, 300, 1, "px")
    bindSlider(smoothing, "Aim", "Deadzone", "Deadzone", 0, 10, 0.05, "px")
    bindSlider(smoothing, "Aim", "Randomization", "Micro randomization", 0, 4, 0.05, "px")

    local prediction = UI:addSection(AimTab, "Prediction")
    bindToggle(prediction, "Aim", "Prediction", "Enable prediction")
    bindDropdown(prediction, "Aim", "PredictionMode", "Prediction model", {
        "Velocity",
        "Projectile",
    })
    bindSlider(prediction, "Aim", "PredictionTime", "Velocity lead", 0, 0.5, 0.005, "s")
    bindSlider(prediction, "Aim", "ProjectileSpeed", "Projectile speed", 50, 5000, 25, "m/s")
    bindSlider(prediction, "Aim", "GravityCompensation", "Gravity compensation", -300, 300, 1, "")
    bindSlider(prediction, "Aim", "VelocitySmoothing", "Velocity filter", 0.05, 1, 0.05, "")
end

do
    local activation = UI:addSection(TriggerTab, "Activation")
    bindToggle(activation, "Trigger", "Enabled", "Master switch")
    bindDropdown(activation, "Trigger", "ActiveMode", "Activation mode", {
        "Always",
        "Hold",
        "Toggle",
    })
    bindKey(activation, "Trigger", "Key", "Trigger key")

    local filters = UI:addSection(TriggerTab, "Filters")
    bindToggle(filters, "Trigger", "TeamCheck", "Team check")
    bindToggle(filters, "Trigger", "WallCheck", "Visibility check")
    bindDropdown(filters, "Trigger", "Hitboxes", "Accepted hitboxes", {
        "Any",
        "Head",
        "Torso",
    })
    bindSlider(filters, "Trigger", "MaxDistance", "Maximum distance", 50, 5000, 50, "m")

    local timing = UI:addSection(TriggerTab, "Timing")
    bindSlider(timing, "Trigger", "Delay", "Reaction delay", 0, 0.5, 0.005, "s")
    bindSlider(timing, "Trigger", "HoldTime", "Mouse hold", 0.005, 0.25, 0.005, "s")
    bindSlider(timing, "Trigger", "Cooldown", "Shot cooldown", 0.01, 1, 0.005, "s")
    bindSlider(timing, "Trigger", "Burst", "Burst shots", 1, 8, 1, "")
    bindSlider(timing, "Trigger", "BurstGap", "Burst gap", 0.01, 0.4, 0.005, "s")
end

do
    local activation = UI:addSection(EspTab, "Activation")
    bindToggle(activation, "Esp", "Enabled", "Master switch")
    bindToggle(activation, "Esp", "TeamCheck", "Hide teammates")
    bindToggle(activation, "Esp", "WallCheck", "Visible only")
    bindSlider(activation, "Esp", "MaxDistance", "Maximum distance", 50, 10000, 50, "m")
    bindSlider(activation, "Esp", "UpdateRate", "Update interval", 0, 0.2, 0.005, "s")

    local boxes = UI:addSection(EspTab, "Boxes")
    bindToggle(boxes, "Esp", "Box", "Box")
    bindDropdown(boxes, "Esp", "BoxStyle", "Box style", {
        "Corner",
        "Full",
    })
    bindSlider(boxes, "Esp", "BoxThickness", "Thickness", 0.5, 4, 0.25, "px")
    bindToggle(boxes, "Esp", "BoxFill", "Box fill")
    bindSlider(boxes, "Esp", "BoxFillAlpha", "Fill transparency", 0, 1, 0.05, "")

    local information = UI:addSection(EspTab, "Information")
    bindToggle(information, "Esp", "Name", "Player name")
    bindToggle(information, "Esp", "DisplayName", "Use display name")
    bindToggle(information, "Esp", "Distance", "Distance")
    bindToggle(information, "Esp", "HealthBar", "Health bar")
    bindToggle(information, "Esp", "HealthText", "Health number")
    bindToggle(information, "Esp", "Weapon", "Equipped tool")
    bindSlider(information, "Esp", "TextSize", "Text size", 9, 22, 1, "px")

    local geometry = UI:addSection(EspTab, "Geometry")
    bindToggle(geometry, "Esp", "Skeleton", "Skeleton")
    bindToggle(geometry, "Esp", "Tracer", "Tracer")
    bindDropdown(geometry, "Esp", "TracerOrigin", "Tracer origin", {
        "Bottom",
        "Top",
        "Mouse",
    })
    bindToggle(geometry, "Esp", "HeadDot", "Head dot")
    bindToggle(geometry, "Esp", "OffscreenArrow", "Off-screen arrows")
    bindSlider(geometry, "Esp", "ArrowRadius", "Arrow radius", 80, 600, 5, "px")
    bindSlider(geometry, "Esp", "ArrowSize", "Arrow size", 5, 35, 1, "px")

    local chams = UI:addSection(EspTab, "Chams")
    bindToggle(chams, "Esp", "Chams", "Highlight characters")
    bindSlider(chams, "Esp", "ChamsFillAlpha", "Fill transparency", 0, 1, 0.05, "")
    bindSlider(chams, "Esp", "ChamsOutlineAlpha", "Outline transparency", 0, 1, 0.05, "")

    local visibleColor = UI:addSection(EspTab, "Visible color")
    bindSlider(visibleColor, "Esp", "VisibleR", "Red", 0, 255, 1, "")
    bindSlider(visibleColor, "Esp", "VisibleG", "Green", 0, 255, 1, "")
    bindSlider(visibleColor, "Esp", "VisibleB", "Blue", 0, 255, 1, "")

    local hiddenColor = UI:addSection(EspTab, "Hidden color")
    bindSlider(hiddenColor, "Esp", "HiddenR", "Red", 0, 255, 1, "")
    bindSlider(hiddenColor, "Esp", "HiddenG", "Green", 0, 255, 1, "")
    bindSlider(hiddenColor, "Esp", "HiddenB", "Blue", 0, 255, 1, "")

    local teamColor = UI:addSection(EspTab, "Team color")
    bindSlider(teamColor, "Esp", "TeamR", "Red", 0, 255, 1, "")
    bindSlider(teamColor, "Esp", "TeamG", "Green", 0, 255, 1, "")
    bindSlider(teamColor, "Esp", "TeamB", "Blue", 0, 255, 1, "")
end

do
    local overlay = UI:addSection(VisualTab, "Aim overlay")
    bindToggle(overlay, "Visuals", "FovCircle", "FOV circle")
    bindToggle(overlay, "Visuals", "FovFilled", "Filled FOV")
    bindSlider(overlay, "Visuals", "FovThickness", "Circle thickness", 0.5, 5, 0.25, "px")
    bindSlider(overlay, "Visuals", "FovSides", "Circle quality", 12, 128, 1, "")
    bindSlider(overlay, "Visuals", "FovAlpha", "Fill opacity", 0.01, 0.75, 0.01, "")
    bindToggle(overlay, "Visuals", "RainbowFov", "Rainbow FOV")
    bindToggle(overlay, "Visuals", "TargetLine", "Target line")
    bindToggle(overlay, "Visuals", "TargetName", "Target details")

    local crosshair = UI:addSection(VisualTab, "Crosshair")
    bindToggle(crosshair, "Visuals", "Crosshair", "Custom crosshair")
    bindSlider(crosshair, "Visuals", "CrosshairSize", "Line size", 2, 30, 1, "px")
    bindSlider(crosshair, "Visuals", "CrosshairGap", "Center gap", 0, 20, 1, "px")
    bindSlider(crosshair, "Visuals", "CrosshairThickness", "Thickness", 0.5, 5, 0.25, "px")

    local accent = UI:addSection(VisualTab, "Interface accent")
    bindSlider(accent, "General", "AccentR", "Red", 0, 255, 1, "")
    bindSlider(accent, "General", "AccentG", "Green", 0, 255, 1, "")
    bindSlider(accent, "General", "AccentB", "Blue", 0, 255, 1, "")

    local interface = UI:addSection(VisualTab, "Interface")
    bindToggle(interface, "General", "Watermark", "Watermark")
    bindToggle(interface, "General", "Notifications", "Notifications")
    bindKey(interface, "General", "MenuKey", "Menu key")
end

do
    local persistence = UI:addSection(ConfigTab, "Persistence")
    bindToggle(persistence, "General", "SaveConfig", "Automatic config saving")

    UI:addButton(persistence, {
        name = "Save current settings",
        buttonText = "Save",
        callback = function()
            local success, reason = Settings:save()

            if success then
                UI:notify("Config", "Settings saved to " .. CONFIG_PATH, 2.5)
            else
                UI:notify("Config error", tostring(reason), 3.5)
            end
        end,
    })

    UI:addButton(persistence, {
        name = "Load saved settings",
        buttonText = "Load",
        callback = function()
            local success, reason = Settings:load()

            if success then
                UI:notify("Config", "Loaded. Re-run script to refresh controls.", 3)
            else
                UI:notify("Config error", tostring(reason), 3.5)
            end
        end,
    })

    UI:addButton(persistence, {
        name = "Reset every setting",
        buttonText = "Reset",
        callback = function()
            Settings:reset()
            UI:notify("Config", "Defaults restored. Re-run to refresh controls.", 3)
        end,
    })

    local runtime = UI:addSection(ConfigTab, "Runtime")

    local capabilitySummary = string.format(
        "Drawing: %s  •  Mouse move: %s  •  Mouse click: %s  •  Files: %s",
        Capabilities.drawing and "yes" or "no",
        Capabilities.mouseMove and "yes" or "no",
        (Capabilities.mouseClick or Capabilities.mousePress) and "yes" or "no",
        (Capabilities.fileRead and Capabilities.fileWrite) and "yes" or "no"
    )

    UI:addLabel(runtime, capabilitySummary)
    UI:addLabel(runtime, "One RenderStepped loop. Cached ESP records. No remote GUI dependency.")

    UI:addButton(runtime, {
        name = "Unload all components",
        buttonText = "Unload",
        callback = function()
            if type(getgenv) == "function" then
                local environment = getgenv()

                if type(environment.VibecodeUnload) == "function" then
                    environment.VibecodeUnload()
                end
            end
        end,
    })
end

UI:setVisible(Settings:get("General", "MenuVisible"))

-- // Runtime orchestration

local Runtime = {
    maid = Maid.new(),
    playerMaids = {},
    alive = true,
    frameErrors = 0,
    lastFrameError = 0,
}

function Runtime:trackCharacter(character)
    CharacterState:update(character)

    task.defer(function()
        if character and character.Parent then
            CharacterState.humanoid = Utility.findHumanoid(character)
            CharacterState.root = Utility.findRoot(character)
        end
    end)
end

function Runtime:addPlayer(player)
    if player == LocalPlayer or self.playerMaids[player] then
        return
    end

    local maid = Maid.new()
    self.playerMaids[player] = maid

    ESP:addPlayer(player)

    maid:give(player.CharacterAdded:Connect(function()
        Aim:clearPlayer(player)
    end))

    maid:give(player.CharacterRemoving:Connect(function()
        Aim:clearPlayer(player)
    end))
end

function Runtime:removePlayer(player)
    local maid = self.playerMaids[player]

    if maid then
        maid:clean()
        self.playerMaids[player] = nil
    end

    Aim:clearPlayer(player)
    ESP:removePlayer(player)
end

function Runtime:_recordFrameError(reason)
    local now = os.clock()

    if now - self.lastFrameError > 1 then
        self.frameErrors = 0
    end

    self.lastFrameError = now
    self.frameErrors = self.frameErrors + 1

    if self.frameErrors <= 3 then
        warn("vibecode frame error:", reason)
    end
end

function Runtime:update(deltaTime)
    if not self.alive then
        return
    end

    Camera = Workspace.CurrentCamera or Camera

    if LocalPlayer.Character and CharacterState.character ~= LocalPlayer.Character then
        self:trackCharacter(LocalPlayer.Character)
    elseif CharacterState.character and not CharacterState.root then
        CharacterState:update(CharacterState.character)
    end

    local aimSuccess, aimReason = pcall(function()
        Aim:update(deltaTime)
    end)

    if not aimSuccess then
        self:_recordFrameError(aimReason)
    end

    local triggerSuccess, triggerReason = pcall(function()
        Trigger:update()
    end)

    if not triggerSuccess then
        self:_recordFrameError(triggerReason)
    end

    local espSuccess, espReason = pcall(function()
        ESP:update(deltaTime)
    end)

    if not espSuccess then
        self:_recordFrameError(espReason)
    end

    local overlaySuccess, overlayReason = pcall(function()
        HUD:update()
    end)

    if not overlaySuccess then
        self:_recordFrameError(overlayReason)
    end
end

function Runtime:Destroy()
    if not self.alive then
        return
    end

    self.alive = false
    Trigger:Destroy()
    Aim:Destroy()
    ESP:Destroy()
    HUD:Destroy()
    Input:Destroy()

    for player, maid in pairs(self.playerMaids) do
        maid:clean()
        self.playerMaids[player] = nil
    end

    self.maid:clean()
    UI:Destroy()
    Settings:save()

    if type(getgenv) == "function" then
        local environment = getgenv()

        if environment.VibecodeUnload then
            environment.VibecodeUnload = nil
        end
    end

    print("[vibecode] unloaded")
end

for _, player in ipairs(Players:GetPlayers()) do
    Runtime:addPlayer(player)
end

Runtime.maid:give(Players.PlayerAdded:Connect(function(player)
    Runtime:addPlayer(player)
end))

Runtime.maid:give(Players.PlayerRemoving:Connect(function(player)
    Runtime:removePlayer(player)
end))

Runtime.maid:give(LocalPlayer.CharacterAdded:Connect(function(character)
    Runtime:trackCharacter(character)
end))

Runtime.maid:give(LocalPlayer.CharacterRemoving:Connect(function()
    CharacterState.character = nil
    CharacterState.humanoid = nil
    CharacterState.root = nil
    Aim.target = nil
    Trigger:cancel()
end))

Runtime.maid:give(Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
    Camera = Workspace.CurrentCamera or Camera
end))

Runtime.maid:give(UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed and UserInputService:GetFocusedTextBox() then
        return
    end

    local inputName = Utility.toInputName(input)

    if inputName == Settings:get("General", "MenuKey") then
        UI:toggle()
    end
end))

Runtime.maid:give(Settings.changed:connect(function(section, key)
    if section == "General" and (
        key == "AccentR"
        or key == "AccentG"
        or key == "AccentB"
    ) then
        UI:setAccent(Utility.colorFromSettings(Settings.values.General, "Accent"))
    elseif section == "General" and key == "Watermark" then
        UI.watermark.Visible = Settings:get("General", "Watermark")
    elseif section == "Aim" and key == "Enabled" and not Settings:get("Aim", "Enabled") then
        Aim.target = nil
    elseif section == "Trigger" and key == "Enabled" and not Settings:get("Trigger", "Enabled") then
        Trigger:cancel()
    end
end))

Runtime.maid:give(RunService.RenderStepped:Connect(function(deltaTime)
    Runtime:update(deltaTime)
end))

if type(getgenv) == "function" then
    local environment = getgenv()

    if type(environment.VibecodeUnload) == "function" then
        pcall(environment.VibecodeUnload)
    end

    environment.VibecodeUnload = function()
        Runtime:Destroy()
    end
end

UI:notify(
    "vibecode " .. PRODUCT_VERSION,
    Capabilities.drawing
        and "Loaded. Open the menu with " .. Utility.formatKey(Settings:get("General", "MenuKey")) .. "."
        or "Loaded without Drawing API; GUI and chams remain available.",
    4
)

print(string.format(
    "[vibecode] v%s loaded | Drawing=%s | mousemoverel=%s",
    PRODUCT_VERSION,
    tostring(Capabilities.drawing),
    tostring(Capabilities.mouseMove)
))
