--[=[
    Blade Ball - NemirHub
    Focused build: Auto Parry, Redirect/Curve Assist, Anti-Lag.
    No fake toggles: every toggle is wired to a real runtime loop.

    NOTE:
    - This is an executor-side client script and depends on the current Blade Ball remotes.
    - No client script can honestly guarantee 0 ms network latency or 100% parry success.
    - The game can change its remotes/anti-cheat at any time.
]=]

if getgenv then
    if getgenv().NemirBladeBallLoaded then
        pcall(function() getgenv().NemirBladeBallUnload() end)
    end
    getgenv().NemirBladeBallLoaded = true
end

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Stats = game:GetService("Stats")
local Lighting = game:GetService("Lighting")

local LocalPlayer = Players.LocalPlayer
local Camera = workspace.CurrentCamera

local State = {
    AutoParry = false,
    Redirect = false,
    AntiLag = false,
    Debug = false,
    Destroyed = false,
    LastParry = 0,
    LastBall = nil,
    LastTarget = nil,
    LastParryBall = nil,
    Connections = {},
    SavedLighting = {},
}

local function connect(signal, fn)
    local c = signal:Connect(fn)
    table.insert(State.Connections, c)
    return c
end

local function safe(fn, ...)
    local ok, a, b, c = pcall(fn, ...)
    if ok then return a, b, c end
    return nil
end

local function getCharacter()
    local char = LocalPlayer.Character
    if not char then return nil end
    local root = char:FindFirstChild("HumanoidRootPart")
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not root or not hum or hum.Health <= 0 then return nil end
    return char, root, hum
end

local CachedParryRemote = nil

local function getRemotes()
    -- Blade Ball has changed the remote layout between versions.
    -- Prefer Remotes/ParryButtonPress, then search ReplicatedStorage.
    local remotes = ReplicatedStorage:FindFirstChild("Remotes")
    local parry = remotes and remotes:FindFirstChild("ParryButtonPress")

    if not parry then
        if CachedParryRemote and CachedParryRemote.Parent then
            parry = CachedParryRemote
        else
            for _, obj in ipairs(ReplicatedStorage:GetDescendants()) do
                if obj.Name == "ParryButtonPress"
                    and (obj:IsA("RemoteEvent") or obj:IsA("BindableEvent")) then
                    parry = obj
                    break
                end
            end
        end
    end

    if parry then
        CachedParryRemote = parry
    end

    return remotes, parry
end

local function getBallsFolder()
    return workspace:FindFirstChild("Balls")
end

local function isRealBall(ball)
    if not ball or not ball:IsA("BasePart") then return false end
    if not ball:IsDescendantOf(workspace) then return false end
    local ok, value = pcall(function() return ball:GetAttribute("realBall") end)
    return ok and value == true
end

local function getBallVelocity(ball)
    local v = safe(function() return ball.AssemblyLinearVelocity end)
    if typeof(v) == "Vector3" and v.Magnitude > 0.01 then return v end
    v = safe(function() return ball.Velocity end)
    if typeof(v) == "Vector3" then return v end
    return Vector3.zero
end

local function isTargeted(ball, char)
    if not ball or not char then return false end

    -- Different Blade Ball versions expose target in different forms.
    local target = safe(function() return ball:GetAttribute("target") end)
    if target ~= nil then
        if target == LocalPlayer
            or target == LocalPlayer.Name
            or target == tostring(LocalPlayer.UserId)
            or target == LocalPlayer.UserId then
            return true
        end

        if typeof(target) == "Instance" then
            if target == LocalPlayer or target.Name == LocalPlayer.Name then
                return true
            end
        end
    end

    if char:GetAttribute("Targeted") == true then return true end
    if char:FindFirstChild("Highlight") then return true end
    return false
end

local function getPingSeconds()
    local ping = safe(function()
        return Stats.Network.ServerStatsItem["Data Ping"]:GetValue()
    end)
    if type(ping) ~= "number" then return 0.06 end
    return math.clamp(ping / 1000, 0.02, 0.30)
end

local function getBestBall(root, char)
    local folder = getBallsFolder()
    if not folder then return nil end

    local best, bestScore = nil, math.huge
    for _, ball in ipairs(folder:GetChildren()) do
        if isRealBall(ball) then
            local vel = getBallVelocity(ball)
            local offset = root.Position - ball.Position
            local dist = offset.Magnitude
            if dist > 0.001 then
                local toward = vel:Dot(offset.Unit)
                local targeted = isTargeted(ball, char)

                -- A realBall moving directly toward the local player is still
                -- considered when the target attribute is absent/different.
                -- This prevents the entire loop from becoming a no-op on
                -- versions that do not expose target as a Player/name.
                if toward > 0 and (targeted or isRealBall(ball)) then
                    local speed = math.max(vel.Magnitude, 1)
                    local tti = dist / speed
                    local score = tti
                    if not targeted then score = score + 0.08 end
                    if dist < 18 then score = score - 0.20 end
                    if score < bestScore then
                        bestScore = score
                        best = ball
                    end
                end
            end
        end
    end
    return best
end

local function chooseTarget(root)
    local best, bestScore = nil, math.huge
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LocalPlayer then
            local char = plr.Character
            local hrp = char and char:FindFirstChild("HumanoidRootPart")
            local hum = char and char:FindFirstChildOfClass("Humanoid")
            if hrp and hum and hum.Health > 0 then
                local delta = hrp.Position - root.Position
                local dist = delta.Magnitude
                if dist > 1 then
                    local score = dist
                    local screenPos, visible = Camera:WorldToViewportPoint(hrp.Position)
                    if visible then score = score * 0.75 end
                    if screenPos.Z > 0 and score < bestScore then
                        bestScore = score
                        best = plr
                    end
                end
            end
        end
    end
    return best
end

local function fireParry()
    local _, parry = getRemotes()
    if not parry then return false end

    -- Blade Ball builds in the wild expose this action through Fire(),
    -- while other builds/execution environments expose FireServer().
    -- Try the game's commonly used Fire() call first, then fall back.
    local ok = pcall(function() parry:Fire() end)
    if not ok then
        ok = pcall(function() parry:FireServer() end)
    end

    if ok then
        State.LastParry = os.clock()
    end
    return ok
end

local function aimAtTarget(target)
    if not State.Redirect or not target then return end
    local char = target.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    if not hrp or not Camera then return end

    -- Only steer the camera at the exact redirect moment; no continuous camera lock.
    local camPos = Camera.CFrame.Position
    local desired = CFrame.lookAt(camPos, hrp.Position)
    safe(function()
        Camera.CFrame = desired
    end)
end

local function adaptiveWindow(ball, root)
    local velocity = getBallVelocity(ball)
    local speed = velocity.Magnitude
    if speed < 1 then return 0.22 end

    local dist = (ball.Position - root.Position).Magnitude
    local ping = getPingSeconds()
    local tti = dist / speed

    -- Larger reaction window for high speed/close range, while keeping it small
    -- enough to avoid constant spam.
    local window = 0.075 + ping * 0.45
    if speed > 150 then window = window + 0.025 end
    if speed > 250 then window = window + 0.035 end
    if dist < 12 then window = math.max(window, 0.12) end
    if dist < 7 then window = math.max(window, 0.15) end
    return math.clamp(window, 0.065, 0.23), tti
end

local function parryTick()
    if State.Destroyed or not State.AutoParry then return end
    local char, root = getCharacter()
    if not char then return end

    local ball = getBestBall(root, char)
    if not ball then
        State.LastBall = nil
        State.LastTarget = nil
        return
    end

    local velocity = getBallVelocity(ball)
    local offset = root.Position - ball.Position
    local dist = offset.Magnitude
    if dist <= 0.001 or velocity.Magnitude < 1 then return end

    local toward = velocity:Dot(offset.Unit)
    if toward <= 0 then return end

    local window, tti = adaptiveWindow(ball, root)
    local emergency = dist <= 6.5 or tti <= 0.055
    local ready = emergency or tti <= window
    if not ready then return end

    -- Prevent repeated Fire() calls against the same incoming ball during one window.
    local now = os.clock()
    local minGap = emergency and 0.085 or 0.115
    if now - State.LastParry < minGap then return end

    local target = State.Redirect and chooseTarget(root) or nil
    if target then aimAtTarget(target) end

    if fireParry() then
        State.LastBall = ball
        State.LastTarget = target
        State.LastParryBall = ball
    end
end

local function applyAntiLag(enabled)
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
        if State.SavedLighting.GlobalShadows ~= nil then
            Lighting.GlobalShadows = State.SavedLighting.GlobalShadows
        end
        if State.SavedLighting.FogEnd ~= nil then
            Lighting.FogEnd = State.SavedLighting.FogEnd
        end
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
local Gui = Instance.new("ScreenGui")
Gui.Name = "NemirBladeBall"
Gui.ResetOnSpawn = false
Gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
Gui.Parent = (type(gethui) == "function" and gethui()) or LocalPlayer:WaitForChild("PlayerGui")

local Main = Instance.new("Frame")
Main.Size = UDim2.fromOffset(310, 300)
Main.Position = UDim2.new(0.5, -155, 0.5, -150)
Main.BackgroundColor3 = Color3.fromRGB(18, 20, 27)
Main.BorderSizePixel = 0
Main.Parent = Gui
Instance.new("UICorner", Main).CornerRadius = UDim.new(0, 14)

local Stroke = Instance.new("UIStroke")
Stroke.Color = Color3.fromRGB(70, 75, 95)
Stroke.Thickness = 1
Stroke.Parent = Main

local Title = Instance.new("TextLabel")
Title.BackgroundTransparency = 1
Title.Size = UDim2.new(1, -50, 0, 45)
Title.Position = UDim2.fromOffset(16, 5)
Title.Font = Enum.Font.GothamBold
Title.Text = "NEMIR HUB  •  BLADE BALL"
Title.TextColor3 = Color3.fromRGB(245,245,250)
Title.TextSize = 16
Title.TextXAlignment = Enum.TextXAlignment.Left
Title.Parent = Main

local Close = Instance.new("TextButton")
Close.Size = UDim2.fromOffset(35,35)
Close.Position = UDim2.new(1,-43,0,9)
Close.BackgroundTransparency = 1
Close.Text = "×"
Close.Font = Enum.Font.GothamBold
Close.TextSize = 24
Close.TextColor3 = Color3.fromRGB(220,220,230)
Close.Parent = Main

local Status = Instance.new("TextLabel")
Status.BackgroundTransparency = 1
Status.Size = UDim2.new(1,-32,0,25)
Status.Position = UDim2.fromOffset(16,47)
Status.Font = Enum.Font.Gotham
Status.Text = "● READY"
Status.TextColor3 = Color3.fromRGB(120,220,150)
Status.TextSize = 12
Status.TextXAlignment = Enum.TextXAlignment.Left
Status.Parent = Main

local function makeToggle(text, y, key)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(1,-32,0,48)
    b.Position = UDim2.fromOffset(16,y)
    b.BackgroundColor3 = Color3.fromRGB(28,31,41)
    b.AutoButtonColor = false
    b.Text = ""
    b.Parent = Main
    Instance.new("UICorner", b).CornerRadius = UDim.new(0,10)

    local label = Instance.new("TextLabel")
    label.BackgroundTransparency = 1
    label.Size = UDim2.new(1,-65,1,0)
    label.Position = UDim2.fromOffset(14,0)
    label.Font = Enum.Font.GothamMedium
    label.Text = text
    label.TextColor3 = Color3.fromRGB(235,235,242)
    label.TextSize = 13
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Parent = b

    local pill = Instance.new("Frame")
    pill.Size = UDim2.fromOffset(42,22)
    pill.Position = UDim2.new(1,-55,0.5,-11)
    pill.BackgroundColor3 = Color3.fromRGB(65,68,80)
    pill.Parent = b
    Instance.new("UICorner", pill).CornerRadius = UDim.new(1,0)

    local knob = Instance.new("Frame")
    knob.Size = UDim2.fromOffset(18,18)
    knob.Position = UDim2.fromOffset(2,2)
    knob.BackgroundColor3 = Color3.fromRGB(235,235,240)
    knob.Parent = pill
    Instance.new("UICorner", knob).CornerRadius = UDim.new(1,0)

    local function render()
        local on = State[key]
        pill.BackgroundColor3 = on and Color3.fromRGB(65,170,105) or Color3.fromRGB(65,68,80)
        knob.Position = on and UDim2.fromOffset(22,2) or UDim2.fromOffset(2,2)
    end

    b.MouseButton1Click:Connect(function()
        State[key] = not State[key]

        if key == "AntiLag" then
            applyAntiLag(State[key])
        elseif key == "AutoParry" and State[key] then
            local _, remote = getRemotes()
            if not getBallsFolder() then
                Status.Text = "● WAITING FOR BALLS"
                Status.TextColor3 = Color3.fromRGB(240,190,90)
            elseif not remote then
                Status.Text = "● PARRY REMOTE NOT FOUND"
                Status.TextColor3 = Color3.fromRGB(240,100,100)
            else
                Status.Text = "● AUTO PARRY ACTIVE"
                Status.TextColor3 = Color3.fromRGB(120,220,150)
            end
        elseif key == "AutoParry" and not State[key] then
            Status.Text = "● READY"
            Status.TextColor3 = Color3.fromRGB(145,150,165)
        end

        render()
    end)
    render()
    return b
end

makeToggle("Auto Parry  •  adaptive timing", 82, "AutoParry")
makeToggle("Redirect Assist  •  aim on parry", 136, "Redirect")
makeToggle("Anti-Lag  •  reduce local effects", 190, "AntiLag")

local Info = Instance.new("TextLabel")
Info.BackgroundTransparency = 1
Info.Size = UDim2.new(1,-32,0,35)
Info.Position = UDim2.fromOffset(16,250)
Info.Font = Enum.Font.Gotham
Info.Text = "Mobile friendly  •  lightweight  •  no fake buttons"
Info.TextColor3 = Color3.fromRGB(145,150,165)
Info.TextSize = 10
Info.TextXAlignment = Enum.TextXAlignment.Center
Info.Parent = Main

-- Drag support
local dragging, dragStart, startPos
Title.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        dragging = true; dragStart = input.Position; startPos = Main.Position
        input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then dragging = false end
        end)
    end
end)
UserInputService.InputChanged:Connect(function(input)
    if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
        local d = input.Position - dragStart
        Main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset+d.X, startPos.Y.Scale, startPos.Y.Offset+d.Y)
    end
end)

local function destroy()
    if State.Destroyed then return end
    State.Destroyed = true
    State.AutoParry = false
    applyAntiLag(false)
    for _, c in ipairs(State.Connections) do pcall(function() c:Disconnect() end) end
    State.Connections = {}
    CachedParryRemote = nil
    pcall(function() Gui:Destroy() end)
    if getgenv then
        getgenv().NemirBladeBallLoaded = nil
        getgenv().NemirBladeBallUnload = nil
    end
end

Close.MouseButton1Click:Connect(destroy)

if getgenv then getgenv().NemirBladeBallUnload = destroy end

-- Main loop: Heartbeat gives a high-frequency local check without a busy while-loop.
connect(RunService.Heartbeat, function()
    if State.Destroyed then return end
    if State.AutoParry then
        local ok, err = pcall(parryTick)
        if not ok and State.Debug then warn("NemirHub AutoParry:", err) end
    end
end)

connect(LocalPlayer.CharacterAdded, function()
    State.LastBall = nil
    State.LastTarget = nil
    State.LastParryBall = nil
end)

connect(workspace.DescendantAdded, function(obj)
    if State.AntiLag and (obj:IsA("ParticleEmitter") or obj:IsA("Trail") or obj:IsA("Beam")) then
        obj:SetAttribute("NemirSavedEnabled", obj.Enabled)
        obj.Enabled = false
    end
end)

do
    local _, remote = getRemotes()
    if getBallsFolder() and remote then
        Status.Text = "● READY"
        Status.TextColor3 = Color3.fromRGB(120,220,150)
    elseif not getBallsFolder() then
        Status.Text = "● WAITING FOR BALLS"
        Status.TextColor3 = Color3.fromRGB(240,190,90)
    else
        Status.Text = "● READY • REMOTE NOT FOUND"
        Status.TextColor3 = Color3.fromRGB(240,190,90)
    end
end
