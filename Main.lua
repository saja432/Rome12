--[=[
    NEMIR HUB - BLADE BALL
    Integrated Parry Engine

    Core:
      * Native Block.Activated path when the executor exposes firesignal
      * RemoteEvent / BindableEvent fallback
      * F-key / mouse fallback
      * zoomies.VectorVelocity support
      * multi-ball tracking
      * target + trajectory prediction
      * curve / acceleration guard
      * ping compensation
      * close-fight mode
      * controlled repeat protection
      * optional target-facing redirect assist
      * anti-lag

    This is client-side and cannot override server validation or guarantee
    a successful parry after a game update.
]=]

if getgenv then
    if getgenv().NemirBladeBallUnload then
        pcall(getgenv().NemirBladeBallUnload)
    end
end

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local Stats = game:GetService("Stats")
local Lighting = game:GetService("Lighting")
local LocalPlayer = Players.LocalPlayer

local State = {
    AutoParry = false,
    Redirect = false,
    CloseFight = true,
    CurveGuard = true,
    AntiLag = false,
    Destroyed = false,
    LastParry = 0,
    LastBall = nil,
    LastTarget = nil,
    ParryCount = 0,
    LastMethod = "none",
    RequestTimes = {},
    FailureTimes = {},
    GuardUntil = 0,
    Connections = {},
    SavedLighting = {},
}

local BallMemory = setmetatable({}, {__mode = "k"})
local BallCooldown = setmetatable({}, {__mode = "k"})
local Camera = workspace.CurrentCamera

local function safe(fn, ...)
    local ok, a, b, c, d = pcall(fn, ...)
    if ok then return a, b, c, d end
end

local function connect(signal, fn)
    local c = signal:Connect(fn)
    table.insert(State.Connections, c)
    return c
end

local function getCharacter()
    local char = LocalPlayer.Character
    if not char then return end
    local root = char:FindFirstChild("HumanoidRootPart")
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not root or not hum or hum.Health <= 0 then return end
    return char, root, hum
end

local function getBallsContainer()
    return workspace:FindFirstChild("Balls") or workspace:FindFirstChild("Runtime")
end

local function getBallPart(obj)
    if obj:IsA("BasePart") then return obj end
    return obj:FindFirstChildWhichIsA("BasePart", true)
end

local function getBallVelocity(ball)
    if not ball then return Vector3.zero end
    local z = safe(function() return ball:FindFirstChild("zoomies") end)
    if z then
        local v = safe(function() return z.VectorVelocity end)
        if typeof(v) == "Vector3" and v.Magnitude > 0.01 then return v end
    end
    local v = safe(function() return ball.AssemblyLinearVelocity end)
    if typeof(v) == "Vector3" and v.Magnitude > 0.01 then return v end
    v = safe(function() return ball.Velocity end)
    return typeof(v) == "Vector3" and v or Vector3.zero
end

local function getPing()
    local p = safe(function()
        return Stats.Network.ServerStatsItem["Data Ping"]:GetValue()
    end)
    return type(p) == "number" and math.clamp(p / 1000, 0.015, 0.30) or 0.06
end

local function matchesLocal(v, char)
    if v == nil then return false end
    if typeof(v) == "Instance" then
        return v == LocalPlayer or v == char
    end
    local s = string.lower(tostring(v))
    return s == string.lower(LocalPlayer.Name)
        or s == string.lower(LocalPlayer.DisplayName)
        or s == tostring(LocalPlayer.UserId)
        or s == string.lower(tostring(LocalPlayer))
end

local function isTargeted(ball, char)
    if not ball then return false end
    for _, key in ipairs({"target", "Target", "TargetPlayer", "targetPlayer", "TargetedPlayer"}) do
        if matchesLocal(safe(function() return ball:GetAttribute(key) end), char) then
            return true
        end
    end
    if char and safe(function() return char:GetAttribute("Targeted") end) == true then
        return true
    end
    return false
end

local function isUsableBall(ball)
    if not ball or not ball:IsDescendantOf(workspace) then return false end
    local real = safe(function() return ball:GetAttribute("realBall") end)
    if real == false then return false end
    local v = getBallVelocity(ball)
    return v.Magnitude > 1
end

local function sample(ball)
    local now = os.clock()
    local p = ball.Position
    local v = getBallVelocity(ball)
    local old = BallMemory[ball]
    local acceleration = Vector3.zero
    local turnRate = 0
    if old then
        local dt = math.max(now - old.t, 1 / 240)
        acceleration = (v - old.v) / dt
        if old.v.Magnitude > 5 and v.Magnitude > 5 then
            turnRate = math.acos(math.clamp(old.v.Unit:Dot(v.Unit), -1, 1)) / dt
        end
    end
    BallMemory[ball] = {p = p, v = v, t = now}
    return v, acceleration, turnRate
end

local function predict(ball, root, playerVelocity)
    local v = getBallVelocity(ball)
    local rel = root.Position - ball.Position
    local vv = v - playerVelocity
    local denom = vv:Dot(vv)
    if denom < 4 then return math.huge, rel.Magnitude end
    local t = math.clamp(rel:Dot(vv) / denom, 0, 1.5)
    local closest = ball.Position + v * t
    local miss = (root.Position + playerVelocity * t - closest).Magnitude
    return t, miss
end

local function getBestBall(root, char)
    local container = getBallsContainer()
    if not container then return end
    local best, bestInfo, bestScore = nil, nil, math.huge
    local playerVelocity = root.AssemblyLinearVelocity

    for _, obj in ipairs(container:GetChildren()) do
        local ball = getBallPart(obj)
        if ball and isUsableBall(ball) then
            local v, accel, turnRate = sample(ball)
            local speed = v.Magnitude
            local offset = root.Position - ball.Position
            local dist = offset.Magnitude
            if dist > 0.05 then
                local dot = v:Dot(offset.Unit) / math.max(speed, 1)
                local targeted = isTargeted(ball, char)
                local tti, miss = predict(ball, root, playerVelocity)
                local directTti = dist / speed

                -- Targeted balls are prioritized. A strongly incoming untagged
                -- ball remains a fallback for games/rounds where target is hidden.
                local score = math.min(tti, directTti)
                if targeted then score -= 0.75 end
                if dot > 0.80 then score -= 0.25 end
                if dot > 0.93 then score -= 0.20 end
                if miss < 7 then score -= 0.25 end
                if turnRate > 1.0 then score -= 0.10 end

                if dot > 0.35 and score < bestScore then
                    bestScore = score
                    best = ball
                    bestInfo = {
                        velocity = v,
                        acceleration = accel,
                        turnRate = turnRate,
                        speed = speed,
                        distance = dist,
                        dot = dot,
                        targeted = targeted,
                        tti = tti,
                        directTti = directTti,
                        miss = miss,
                    }
                end
            end
        end
    end
    return best, bestInfo
end

local function chooseTarget(root)
    local alive = workspace:FindFirstChild("Alive")
    local list = alive and alive:GetChildren() or Players:GetPlayers()
    local best, bestDistance = nil, math.huge

    for _, obj in ipairs(list) do
        local plr, char
        if obj:IsA("Player") then
            plr, char = obj, obj.Character
        else
            char, plr = obj, Players:GetPlayerFromCharacter(obj)
        end
        if char and char ~= LocalPlayer.Character then
            local hum = char:FindFirstChildOfClass("Humanoid")
            local root = char:FindFirstChild("HumanoidRootPart") or char.PrimaryPart
            if hum and hum.Health > 0 and root then
                local _, localRoot = getCharacter()
                if not localRoot then continue end
                local d = (root.Position - localRoot.Position).Magnitude
                if d > 1 and d < bestDistance then
                    bestDistance = d
                    best = plr or char
                end
            end
        end
    end
    return best
end

local function getBlockButton()
    local gui = LocalPlayer:FindFirstChild("PlayerGui")
    local hotbar = gui and gui:FindFirstChild("Hotbar")
    return hotbar and hotbar:FindFirstChild("Block")
end

local function getBlockCooldown()
    local button = getBlockButton()
    if not button then return nil end
    local border = button:FindFirstChild("border1")
    local grad = border and border:FindFirstChildOfClass("UIGradient")
    if grad then
        local off = grad.Offset
        if typeof(off) == "Vector2" then
            return off.X
        end
    end
    return nil
end

local function getParryRemote()
    local remotes = ReplicatedStorage:FindFirstChild("Remotes")
    if not remotes then return end
    return remotes:FindFirstChild("ParryButtonPress", true)
end

local function fireNativeInput()
    local button = getBlockButton()
    if not button then return false end
    if type(firesignal) == "function" then
        local ok = pcall(function() firesignal(button.Activated) end)
        if ok then
            State.LastMethod = "native"
            return true
        end
    end
    return false
end

local function fireRemote()
    local remote = getParryRemote()
    if not remote then return false end
    if remote:IsA("BindableEvent") then
        local ok = pcall(function() remote:Fire() end)
        if ok then State.LastMethod = "bindable" end
        return ok
    end
    if remote:IsA("RemoteEvent") then
        local ok = pcall(function() remote:FireServer() end)
        if ok then State.LastMethod = "remote" end
        return ok
    end
    return false
end

local function fireKey()
    if not VirtualInputManager then return false end
    local ok = pcall(function()
        VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.F, false, game)
        VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.F, false, game)
    end)
    if ok then State.LastMethod = "F" end
    return ok
end

local function fireMouse()
    if not VirtualInputManager then return false end
    local camera = workspace.CurrentCamera
    local x, y = 0, 0
    if camera then
        x, y = camera.ViewportSize.X / 2, camera.ViewportSize.Y / 2
    end
    local ok = pcall(function()
        VirtualInputManager:SendMouseButtonEvent(x, y, 0, true, game, 0)
        VirtualInputManager:SendMouseButtonEvent(x, y, 0, false, game, 0)
    end)
    if ok then State.LastMethod = "mouse" end
    return ok
end

local function pruneTimes(list, now, window)
    local i = 1
    while i <= #list do
        if now - list[i] > window then
            table.remove(list, i)
        else
            i += 1
        end
    end
end

-- Stability guard: this is deliberately a rate limiter, not an anti-cheat
-- bypass. It prevents this client from hammering the game's action boundary
-- when prediction becomes unstable or a game update changes the ball state.
local function allowParryRequest(now)
    if now < State.GuardUntil then return false end

    pruneTimes(State.RequestTimes, now, 1.0)
    pruneTimes(State.FailureTimes, now, 2.0)

    -- Conservative client-side ceiling. The server remains authoritative.
    if #State.RequestTimes >= 8 then
        State.GuardUntil = now + 0.35
        return false
    end

    if #State.FailureTimes >= 3 then
        State.GuardUntil = now + 0.75
        table.clear(State.FailureTimes)
        return false
    end

    return true
end

local function doParry()
    local now = os.clock()
    if now - State.LastParry < 0.055 then return false end
    if not allowParryRequest(now) then return false end

    table.insert(State.RequestTimes, now)

    -- Prefer the game's own UI activation path; it keeps the game's current
    -- input/remote arguments intact when the executor supports firesignal.
    local success = fireNativeInput() or fireRemote() or fireKey() or fireMouse()
    if success then
        State.LastParry = now
        State.ParryCount += 1
        return true
    end

    table.insert(State.FailureTimes, now)
    return false
end

local function curveRisk(info)
    if not State.CurveGuard or not info then return false end
    local s = info.speed
    if info.turnRate > 0.85 then return true end
    if info.acceleration.Magnitude > math.max(65, s * 1.35) then return true end
    if s > 180 and info.dot < 0.78 then return true end
    return false
end

local function parryWindow(info)
    local ping = getPing()
    local speed = math.max(info.speed, 1)
    local t = info.tti

    -- Based on the reference implementation's dynamic threshold idea,
    -- but using actual time-to-impact plus ping rather than distance alone.
    local window = 0.105 + ping * 0.55
    window += math.clamp(speed / 2400, 0, 0.18)
    if speed > 150 then window += 0.025 end
    if speed > 250 then window += 0.035 end
    if info.distance < 15 then window = math.max(window, 0.145) end
    if info.distance < 8 then window = math.max(window, 0.185) end
    if curveRisk(info) then window += 0.035 end
    if info.miss < 5 then window = math.max(window, 0.13) end
    if State.CloseFight and info.distance < 18 then window += 0.025 end
    return math.clamp(window, 0.075, 0.31), t
end

local function aimTarget(target, root)
    if not State.Redirect or not target then return end
    local char = target:IsA("Player") and target.Character or target
    local hrp = char and (char:FindFirstChild("HumanoidRootPart") or char.PrimaryPart)
    if not hrp then return end
    Camera = workspace.CurrentCamera or Camera
    if not Camera then return end
    local lead = hrp.Position
    local tv = hrp.AssemblyLinearVelocity
    if typeof(tv) == "Vector3" then
        lead += tv * math.clamp(getPing(), 0.02, 0.14)
    end
    safe(function()
        Camera.CFrame = CFrame.lookAt(Camera.CFrame.Position, lead)
    end)
end

local function shouldParry(ball, info)
    if not ball or not info then return false end
    if info.dot <= 0.30 and not info.targeted then return false end

    local cooldown = getBlockCooldown()
    if cooldown and cooldown > 0.90 and info.distance > 7 then return false end

    local window, tti = parryWindow(info)
    local effectiveTti = tti - getPing() * 0.65

    if info.distance <= (State.CloseFight and 7.5 or 5.5) then return true end
    if info.miss <= 4.5 and info.dot > 0.55 then return true end
    return effectiveTti <= window
end

local function parryTick()
    if State.Destroyed or not State.AutoParry then return end
    local char, root = getCharacter()
    if not char then return end

    local ball, info = getBestBall(root, char)
    if not ball or not info then return end
    State.LastBall = ball

    if not shouldParry(ball, info) then return end

    local now = os.clock()
    local gap = State.CloseFight and 0.045 or 0.065
    if curveRisk(info) then gap = 0.040 end

    local last = BallCooldown[ball] or 0
    if now - last < gap then return end

    -- Allow a second/third press only while the same ball is still genuinely
    -- inside the impact window; never run an unconditional spam loop.
    local target = State.Redirect and chooseTarget(root) or nil
    if target then
        State.LastTarget = target
        aimTarget(target, root)
    end

    if doParry() then
        BallCooldown[ball] = now
    end
end

local function antiLag(enabled)
    if enabled then
        State.SavedLighting.GlobalShadows = Lighting.GlobalShadows
        State.SavedLighting.FogEnd = Lighting.FogEnd
        Lighting.GlobalShadows = false
        Lighting.FogEnd = 100000
        for _, obj in ipairs(workspace:GetDescendants()) do
            if obj:IsA("ParticleEmitter") or obj:IsA("Trail") or obj:IsA("Beam") then
                if obj:GetAttribute("NemirSavedEnabled") == nil then
                    obj:SetAttribute("NemirSavedEnabled", obj.Enabled)
                end
                obj.Enabled = false
            end
        end
    else
        if State.SavedLighting.GlobalShadows ~= nil then Lighting.GlobalShadows = State.SavedLighting.GlobalShadows end
        if State.SavedLighting.FogEnd ~= nil then Lighting.FogEnd = State.SavedLighting.FogEnd end
        for _, obj in ipairs(workspace:GetDescendants()) do
            if obj:IsA("ParticleEmitter") or obj:IsA("Trail") or obj:IsA("Beam") then
                local saved = obj:GetAttribute("NemirSavedEnabled")
                if saved ~= nil then
                    obj.Enabled = saved
                    obj:SetAttribute("NemirSavedEnabled", nil)
                end
            end
        end
    end
end

-- UI ------------------------------------------------------------------------
local oldGui = safe(function()
    local p = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    return p and p:FindFirstChild("NemirBladeBall")
end)
if oldGui then pcall(function() oldGui:Destroy() end) end

local Gui = Instance.new("ScreenGui")
Gui.Name = "NemirBladeBall"
Gui.ResetOnSpawn = false
Gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
Gui.Parent = (gethui and gethui()) or LocalPlayer:WaitForChild("PlayerGui")

local Main = Instance.new("Frame")
Main.Size = UDim2.fromOffset(325, 390)
Main.Position = UDim2.new(0.5, -162, 0.5, -195)
Main.BackgroundColor3 = Color3.fromRGB(18,20,27)
Main.BorderSizePixel = 0
Main.Parent = Gui
Instance.new("UICorner", Main).CornerRadius = UDim.new(0,14)
local stroke = Instance.new("UIStroke", Main)
stroke.Color = Color3.fromRGB(70,75,95)
stroke.Thickness = 1

local Title = Instance.new("TextLabel", Main)
Title.BackgroundTransparency = 1
Title.Position = UDim2.fromOffset(16,5)
Title.Size = UDim2.new(1,-50,0,42)
Title.Font = Enum.Font.GothamBold
Title.Text = "NEMIR HUB  •  BLADE BALL"
Title.TextColor3 = Color3.fromRGB(245,245,250)
Title.TextSize = 16
Title.TextXAlignment = Enum.TextXAlignment.Left

local Close = Instance.new("TextButton", Main)
Close.BackgroundTransparency = 1
Close.Position = UDim2.new(1,-43,0,8)
Close.Size = UDim2.fromOffset(35,35)
Close.Text = "×"
Close.Font = Enum.Font.GothamBold
Close.TextSize = 24
Close.TextColor3 = Color3.fromRGB(220,220,230)

local Status = Instance.new("TextLabel", Main)
Status.BackgroundTransparency = 1
Status.Position = UDim2.fromOffset(16,43)
Status.Size = UDim2.new(1,-32,0,25)
Status.Font = Enum.Font.Gotham
Status.Text = "● READY"
Status.TextColor3 = Color3.fromRGB(145,150,165)
Status.TextSize = 11
Status.TextXAlignment = Enum.TextXAlignment.Left

local StatsLabel = Instance.new("TextLabel", Main)
StatsLabel.BackgroundTransparency = 1
StatsLabel.Position = UDim2.fromOffset(16,66)
StatsLabel.Size = UDim2.new(1,-32,0,22)
StatsLabel.Font = Enum.Font.Gotham
StatsLabel.Text = "Parries: 0  •  Method: none"
StatsLabel.TextColor3 = Color3.fromRGB(120,125,140)
StatsLabel.TextSize = 10
StatsLabel.TextXAlignment = Enum.TextXAlignment.Left

local function makeToggle(text, y, key, callback)
    local b = Instance.new("TextButton", Main)
    b.Size = UDim2.new(1,-32,0,48)
    b.Position = UDim2.fromOffset(16,y)
    b.BackgroundColor3 = Color3.fromRGB(28,31,41)
    b.AutoButtonColor = false
    b.Text = ""
    Instance.new("UICorner", b).CornerRadius = UDim.new(0,10)

    local label = Instance.new("TextLabel", b)
    label.BackgroundTransparency = 1
    label.Position = UDim2.fromOffset(14,0)
    label.Size = UDim2.new(1,-70,1,0)
    label.Font = Enum.Font.GothamMedium
    label.Text = text
    label.TextColor3 = Color3.fromRGB(235,235,242)
    label.TextSize = 12
    label.TextXAlignment = Enum.TextXAlignment.Left

    local pill = Instance.new("Frame", b)
    pill.Size = UDim2.fromOffset(42,22)
    pill.Position = UDim2.new(1,-55,0.5,-11)
    pill.BackgroundColor3 = Color3.fromRGB(65,68,80)
    Instance.new("UICorner", pill).CornerRadius = UDim.new(1,0)

    local knob = Instance.new("Frame", pill)
    knob.Size = UDim2.fromOffset(18,18)
    knob.Position = UDim2.fromOffset(2,2)
    knob.BackgroundColor3 = Color3.fromRGB(235,235,240)
    Instance.new("UICorner", knob).CornerRadius = UDim.new(1,0)

    local function render()
        local on = State[key]
        pill.BackgroundColor3 = on and Color3.fromRGB(65,170,105) or Color3.fromRGB(65,68,80)
        knob.Position = on and UDim2.fromOffset(22,2) or UDim2.fromOffset(2,2)
    end

    connect(b.MouseButton1Click, function()
        State[key] = not State[key]
        if callback then callback(State[key]) end
        render()
    end)
    render()
end

makeToggle("Auto Parry  •  prediction engine", 91, "AutoParry")
makeToggle("Redirect  •  target-facing assist", 145, "Redirect")
makeToggle("Close Fight  •  tighter window", 199, "CloseFight")
makeToggle("Curve Guard  •  react to turns", 253, "CurveGuard")
makeToggle("Anti-Lag  •  local effects", 307, "AntiLag", antiLag)

local Info = Instance.new("TextLabel", Main)
Info.BackgroundTransparency = 1
Info.Position = UDim2.fromOffset(16,361)
Info.Size = UDim2.new(1,-32,0,20)
Info.Font = Enum.Font.Gotham
Info.Text = "Prediction • multi-ball • ping • curve • native input"
Info.TextColor3 = Color3.fromRGB(120,125,140)
Info.TextSize = 9
Info.TextXAlignment = Enum.TextXAlignment.Center

-- Drag
local dragging, dragStart, startPos
connect(Title.InputBegan, function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        dragging = true
        dragStart = input.Position
        startPos = Main.Position
        local c
        c = input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then
                dragging = false
                pcall(function() c:Disconnect() end)
            end
        end)
    end
end)
connect(UserInputService.InputChanged, function(input)
    if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
        local d = input.Position - dragStart
        Main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset+d.X, startPos.Y.Scale, startPos.Y.Offset+d.Y)
    end
end)

local function destroy()
    if State.Destroyed then return end
    State.Destroyed = true
    State.AutoParry = false
    antiLag(false)
    for _, c in ipairs(State.Connections) do pcall(function() c:Disconnect() end) end
    State.Connections = {}
    pcall(function() Gui:Destroy() end)
    if getgenv then
        getgenv().NemirBladeBallUnload = nil
        getgenv().NemirBladeBallLoaded = nil
    end
end

connect(Close.MouseButton1Click, destroy)
if getgenv then
    getgenv().NemirBladeBallLoaded = true
    getgenv().NemirBladeBallUnload = destroy
end

connect(RunService.PreSimulation, function()
    if State.Destroyed then return end
    if State.AutoParry then
        pcall(parryTick)
    end
end)

connect(RunService.Heartbeat, function()
    if State.Destroyed then return end
    if State.AutoParry then
        Status.Text = State.Redirect and "● AUTO PARRY + REDIRECT" or "● AUTO PARRY"
        Status.TextColor3 = Color3.fromRGB(120,220,150)
    elseif State.AntiLag then
        Status.Text = "● READY + ANTI-LAG"
        Status.TextColor3 = Color3.fromRGB(120,220,150)
    else
        Status.Text = "● READY — AUTO PARRY OFF"
        Status.TextColor3 = Color3.fromRGB(145,150,165)
    end
    StatsLabel.Text = string.format("Parries: %d  •  Method: %s", State.ParryCount, State.LastMethod)
end)

connect(LocalPlayer.CharacterAdded, function()
    BallMemory = setmetatable({}, {__mode = "k"})
    BallCooldown = setmetatable({}, {__mode = "k"})
    State.LastBall = nil
    State.LastTarget = nil
end)

connect(workspace.DescendantAdded, function(obj)
    if State.AntiLag and (obj:IsA("ParticleEmitter") or obj:IsA("Trail") or obj:IsA("Beam")) then
        obj:SetAttribute("NemirSavedEnabled", obj.Enabled)
        obj.Enabled = false
    end
end)
