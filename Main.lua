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
local Debris = game:GetService("Debris")
local LocalPlayer = Players.LocalPlayer

local State = {
    AutoParry = false,
    Redirect = false,
    CloseFight = true,
    CurveGuard = true,
    AutoAbility = true,
    SurvivalGuard = true,
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
    LastDecision = "idle",
    LastTTI = math.huge,
    LastSpeed = 0,
    LastDistance = math.huge,
    LastRisk = 0,
    BallCount = 0,
    TargetChanges = 0,
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
        v = safe(function() return z.Velocity end)
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

    for _, key in ipairs({"target", "Target", "TargetPlayer", "targetPlayer", "TargetedPlayer", "TargetName", "targetName"}) do
        local value = safe(function() return ball:GetAttribute(key) end)
        if matchesLocal(value, char) then return true end
        if value ~= nil and char then
            local text = string.lower(tostring(value))
            if text == string.lower(char.Name) or text == string.lower(tostring(char)) then
                return true
            end
        end
    end

    if char then
        if safe(function() return char:GetAttribute("Targeted") end) == true then return true end
        if safe(function() return char:GetAttribute("targeted") end) == true then return true end
    end

    -- Some builds signal the active target visually instead of exposing a target attribute.
    local brick = safe(function() return ball.BrickColor.Name end)
    if brick == "Really red" then return true end

    local color = safe(function() return ball.Color end)
    if typeof(color) == "Color3" and color.R > 0.65 and color.G < 0.30 and color.B < 0.30 then
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

local function predict(ball, root, playerVelocity, acceleration)
    local v = getBallVelocity(ball)
    local a = typeof(acceleration) == "Vector3" and acceleration or Vector3.zero
    local rel0 = ball.Position - root.Position
    local relV = v - playerVelocity
    local nowDist = rel0.Magnitude

    local function distAt(t)
        local pos = rel0 + relV * t + a * (0.5 * t * t)
        return pos.Magnitude
    end

    local horizon = math.clamp(nowDist / math.max(v.Magnitude, 1) + 0.15, 0.10, 1.50)
    local bestT, bestD = 0, nowDist
    local steps = 18
    for i = 1, steps do
        local t = horizon * (i / steps)
        local d = distAt(t)
        if d < bestD then
            bestD, bestT = d, t
        end
    end

    -- Refine around the best sample. This makes the decision less dependent on frame rate.
    local lo = math.max(0, bestT - horizon / steps)
    local hi = math.min(horizon, bestT + horizon / steps)
    for _ = 1, 7 do
        local m1 = lo + (hi - lo) / 3
        local m2 = hi - (hi - lo) / 3
        if distAt(m1) < distAt(m2) then
            hi = m2
        else
            lo = m1
        end
    end
    bestT = (lo + hi) * 0.5
    bestD = distAt(bestT)

    local direction = root.Position - ball.Position
    local speedToward = 0
    if direction.Magnitude > 0.001 then
        speedToward = v:Dot(direction.Unit) - playerVelocity:Dot(direction.Unit)
    end
    local linearTti = speedToward > 0 and math.max((nowDist - 3.0) / speedToward, 0) or math.huge

    return math.min(bestT, linearTti), bestD, linearTti
end

local function getBestBall(root, char)
    local container = getBallsContainer()
    if not container then return nil end
    local best, bestInfo, bestScore = nil, nil, math.huge
    local playerVelocity = root.AssemblyLinearVelocity
    local count = 0

    for _, obj in ipairs(container:GetChildren()) do
        local ball = getBallPart(obj)
        if ball and isUsableBall(ball) then
            count += 1
            local v, accel, turnRate = sample(ball)
            local speed = v.Magnitude
            local offset = root.Position - ball.Position
            local dist = offset.Magnitude
            if dist > 0.05 and speed > 1 then
                local dot = v:Dot(offset.Unit) / math.max(speed, 1)
                local targeted = isTargeted(ball, char)
                local tti, miss, linearTti = predict(ball, root, playerVelocity, accel)
                local incoming = dot > 0.20 or targeted

                if incoming then
                    local score = tti
                    if targeted then score -= 0.90 end
                    if dot > 0.80 then score -= 0.20 end
                    if dot > 0.93 then score -= 0.15 end
                    if miss < 7 then score -= 0.20 end
                    if turnRate > 0.90 then score -= 0.08 end
                    if dist < 10 then score -= 0.15 end

                    if score < bestScore then
                        bestScore = score
                        best = ball
                        bestInfo = {
                            velocity = v, acceleration = accel, turnRate = turnRate,
                            speed = speed, distance = dist, dot = dot, targeted = targeted,
                            tti = tti, directTti = dist / speed, linearTti = linearTti, miss = miss,
                        }
                    end
                end
            end
        end
    end
    State.BallCount = count
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
            return off.Y
        end
    end
    return nil
end

local function blockReady()
    local offsetY = getBlockCooldown()
    if offsetY == nil then return true end
    -- In the reference implementation the gradient is below 0.5 while Block is cooling down.
    return offsetY >= 0.5
end

-- Ability path taken from the same gameplay pattern used by the reference:
-- when Block is unavailable during a dangerous close-range attack, use an
-- equipped deflection/rapture ability instead of blindly spamming Block.
local function getAbilityRemote()
    local remotes = ReplicatedStorage:FindFirstChild("Remotes")
    if not remotes then return nil end
    return remotes:FindFirstChild("AbilityButtonPress", true)
end

local function abilityReady()
    local gui = LocalPlayer:FindFirstChild("PlayerGui")
    local hotbar = gui and gui:FindFirstChild("Hotbar")
    local ability = hotbar and hotbar:FindFirstChild("Ability")
    local border = ability and ability:FindFirstChild("border2")
    local grad = border and border:FindFirstChildOfClass("UIGradient")
    if not grad then return true end
    local off = grad.Offset
    if typeof(off) ~= "Vector2" then return true end
    -- Reference builds expose 0.5 when the ability is available.
    return off.Y >= 0.49
end

local AbilityNames = {
    "Raging Deflection",
    "Rapture",
    "Calming Deflection",
    "Aerodynamic Slash",
    "Fracture",
    "Death Slash",
}

local function equippedDeflectionAbility()
    local char = LocalPlayer.Character
    local abilities = char and char:FindFirstChild("Abilities")
    if not abilities then return nil end
    for _, name in ipairs(AbilityNames) do
        local ability = abilities:FindFirstChild(name)
        if ability and safe(function() return ability.Enabled end) == true then
            return ability
        end
    end
    return nil
end

local function fireAbility()
    if not abilityReady() then return false end
    if not equippedDeflectionAbility() then return false end
    local remote = getAbilityRemote()
    if not remote then return false end

    local ok = false
    if remote:IsA("BindableEvent") then
        ok = pcall(function() remote:Fire() end)
    elseif remote:IsA("RemoteEvent") then
        ok = pcall(function() remote:FireServer() end)
    end
    if ok then
        State.LastMethod = "ability"
    end
    return ok
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

local function doParry(force)
    local now = os.clock()
    local minGap = force and 0.045 or 0.070
    if now - State.LastParry < minGap then return false end
    if not allowParryRequest(now) then return false end
    -- The reference implementation performs an immediate parry inside the close range.
    -- Do not let a UI gradient/cooldown read prevent that emergency attempt.
    if not force and not blockReady() then return false end

    table.insert(State.RequestTimes, now)

    -- Use one input path per attempt. Chaining several paths can accidentally send
    -- duplicate parries in the same frame.
    local remote = getParryRemote()
    local success = false
    if remote and remote:IsA("BindableEvent") then
        -- This is the path used by several Blade Ball builds: the game's own
        -- BindableEvent already contains the correct local action handling.
        success = pcall(function() remote:Fire() end)
        if success then State.LastMethod = "bindable" end
    elseif fireNativeInput() then
        -- Prefer the real Block button when the game exposes it. This preserves
        -- whatever arguments/state the current client build expects.
        success = true
    elseif remote and remote:IsA("RemoteEvent") then
        success = pcall(function() remote:FireServer() end)
        if success then State.LastMethod = "remote" end
    elseif fireKey() then
        success = true
    end

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
    if info.dot <= 0.25 and not info.targeted then return false end

    if not blockReady() and info.distance > 5.5 then
        return false
    end

    local window, tti = parryWindow(info)
    local ping = getPing()
    local effectiveTti = tti - ping * 0.72

    -- Close-range override prevents a miss when the ball crosses the player between frames.
    -- Match the proven close-range behavior: the reference fires as soon as the
    -- targeted ball is inside 15 studs, then also uses the dynamic TTI threshold.
    if info.targeted and info.distance <= 15 and info.dot > 0.15 then
        return true
    end
    if info.distance <= (State.CloseFight and 8.5 or 6.0) and info.dot > 0.20 then
        return true
    end
    if info.miss <= 4.0 and info.dot > 0.50 then return true end
    return effectiveTti <= window
end

local function shouldUseSurvivalGuard(info)
    if not State.SurvivalGuard or not State.AutoAbility or not info then return false end
    if not info.targeted and info.dot < 0.70 then return false end
    if abilityReady() == false then return false end

    -- Emergency fallback for the exact situation where Block is unavailable
    -- and the incoming ball is already inside the lethal close-fight window.
    if not blockReady() then
        return info.distance <= 14 or info.tti <= (0.12 + getPing() * 0.45)
    end
    return false
end

local function parryTick()
    if State.Destroyed or not State.AutoParry then return end
    local char, root = getCharacter()
    if not char then return end

    local ball, info = getBestBall(root, char)
    if not ball or not info then
        State.LastDecision = "searching"
        State.LastTTI = math.huge
        return
    end

    State.LastBall = ball
    State.LastTTI = info.tti
    State.LastSpeed = info.speed
    State.LastDistance = info.distance
    State.LastRisk = math.clamp((1 - info.dot) + (info.turnRate * 0.18) + (info.speed / 1000), 0, 2)

    -- Survival/ability layer runs before the normal Block attempt. This is
    -- intentionally limited to an actual incoming lethal situation.
    if shouldUseSurvivalGuard(info) then
        local target = State.Redirect and chooseTarget(root) or nil
        if target then
            State.LastTarget = target
            aimTarget(target, root)
        end
        if fireAbility() then
            State.LastDecision = "SURVIVAL ABILITY"
            State.LastParry = os.clock()
            BallCooldown[ball] = os.clock()
            return
        end
    end

    if not shouldParry(ball, info) then
        State.LastDecision = curveRisk(info) and "curve-wait" or "tracking"
        return
    end

    local now = os.clock()
    local gap = State.CloseFight and 0.050 or 0.070
    if curveRisk(info) then gap = 0.040 end

    local last = BallCooldown[ball] or 0
    if now - last < gap then return end

    local target = State.Redirect and chooseTarget(root) or nil
    if target then
        if State.LastTarget ~= target then State.TargetChanges += 1 end
        State.LastTarget = target
        aimTarget(target, root)
    end

    local emergencyClose = info.targeted and info.distance <= 15 and info.dot > 0.15
    if doParry(emergencyClose) then
        BallCooldown[ball] = now
        State.LastDecision = "PARRIED"
    else
        State.LastDecision = "input-failed"
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

-- Ball lifecycle hooks: keep prediction memory clean without scanning the entire
-- workspace every frame.
local ballsContainer = getBallsContainer()
if ballsContainer then
    connect(ballsContainer.ChildRemoved, function(obj)
        BallMemory[obj] = nil
        BallCooldown[obj] = nil
        if State.LastBall == obj then State.LastBall = nil end
    end)
    connect(ballsContainer.ChildAdded, function(obj)
        task.defer(function()
            local ball = getBallPart(obj)
            if ball then BallMemory[ball] = nil end
        end)
    end)
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
Main.Size = UDim2.fromOffset(325, 500)
Main.Position = UDim2.new(0.5, -162, 0.5, -250)
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
makeToggle("Survival Guard  •  emergency ability", 307, "SurvivalGuard")
makeToggle("Auto Ability  •  deflection / rapture", 361, "AutoAbility")
makeToggle("Anti-Lag  •  local effects", 415, "AntiLag", antiLag)

local Info = Instance.new("TextLabel", Main)
Info.BackgroundTransparency = 1
Info.Position = UDim2.fromOffset(16,467)
Info.Size = UDim2.new(1,-32,0,20)
Info.Font = Enum.Font.Gotham
Info.Text = "Prediction • zoomies • multi-ball • curve • cooldown • input"
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

connect(RunService.PreSimulation, function()
    if State.Destroyed then return end
    Camera = workspace.CurrentCamera or Camera
    if not LocalPlayer.Parent then
        destroy()
        return
    end
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
    StatsLabel.Text = string.format("Parries: %d • Balls: %d • %.0fms • %.0f u/s • %s", State.ParryCount, State.BallCount, math.min(State.LastTTI, 9)*1000, State.LastSpeed, State.LastDecision)
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
