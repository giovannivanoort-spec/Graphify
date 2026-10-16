--!nonstrict
-- CheatersUI.luau — cheaters on the client (GUESTS package; server: Cheaters.luau,
-- NPCs.luau, Config.Cheaters). init.client starts it (start(deps)); it starts GuestTags
-- (the Showtime tag over every guest's head) too.
--   * KICK OUT: every guest inside YOUR casino (model attributes CasinoOwner = you and
--     Inside) gets a local ProximityPrompt (hold KickHoldSeconds; F / ButtonY / touch),
--     drawn as a Showtime pill: crimson velvet with a gold trim, a cream key cap, "KICK
--     OUT" over "SUSPECT!" / "GUEST", the 3D handcuffs; the pill fills with gold while
--     you hold. Triggering it calls KickGuest(model); the server checks it all again.
--     No prompts while you place / move things (PlacementController.isBusy).
--   * CheaterAlert (you): "CHEATER ALERT!" with the machine's name (the cheater icon) and
--     a red vignette pulse (the very first time: a banner that explains it); the HUD
--     chip "CHEATER: <MACHINE>" pulses while a suspect is in your casino (click: hop
--     home). kind "escaped": one walked off with your money (+ a Security hint).
--   * GuestKicked (everyone near): "BUSTED!" / "CAUGHT!" / "HEY!" over the guest (the
--     tag's stamp is GuestTags'). Your kick: the CHEATER BUSTED! banner + the coins fly
--     from the cheater into your cash pill (+XP); Security: a toast, and the nearest
--     guard (StaffClient.borrowGuard) hurries over, leads them out and goes back to
--     the post; an honest guest: "Oops - that guest was honest!".

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Config = require(Common:WaitForChild("Config"))
local Remotes = require(Common:WaitForChild("Remotes"))
local UILib = require(script.Parent:WaitForChild("UILib"))
local C = UILib.Colors
local F = UILib.Fonts
local make = UILib.make

local CheatersUI = {}
local player = Players.LocalPlayer
local CC = Config.Cheaters or {}
local deps = {}
local started = false
local GuestTags = nil

local TAG = "CasinoPatron"
local PROMPT_ATTR = "CasinoKick"
local HOLD = tonumber(CC.KickHoldSeconds) or 0.6
local REACH = tonumber(CC.KickPromptDistance) or 10
local FX_RANGE = 160          -- studs from the camera: kick effects over the guest
local ESCORT_RANGE = 220      -- ... the guard's escort
local HURRY, STROLL = 13, 7   -- the guard's speeds (studs/s)
local ALERT_MEMORY = 75       -- seconds the HUD chip remembers an alert it can't see
local ICON_FALLBACK = { cheater = "staff", handcuffs = "lock", shield = "staff" }
local E = Config.Building.Elevator

------------------------------------------------------------------
-- helpers
------------------------------------------------------------------
local function icon(name: string): string
	local id = UILib.resolveIcon(name)
	if id == "" and ICON_FALLBACK[name] then id = UILib.resolveIcon(ICON_FALLBACK[name]) end
	return id
end

local warned = 0
local function softWarn(msg: string)
	if warned < 10 then
		warned += 1
		warn("[CheatersUI] " .. msg)
	end
end

-- our toasts wear our own 3D icons (UILib.toast picks one per kind; the "toast" fx
-- event hands us its tile right away)
local toastIcons: {[string]: string} = {}
local function onFx(event: string, _kind, _card, tile, title)
	if event ~= "toast" or typeof(tile) ~= "Instance" then return end
	local name = toastIcons[title]
	local img = name and tile:FindFirstChildWhichIsA("ImageLabel")
	if img then
		local id = icon(name)
		if id ~= "" then img.Image = id end
	end
end
local function toast(title: string, kind: string, message: string?, iconName: string?)
	if iconName then toastIcons[title] = iconName end
	UILib.toast(title, kind, message)
end

local function rootOf(model: Instance?): BasePart?
	local r = model and model:FindFirstChild("HumanoidRootPart")
	return (r and r:IsA("BasePart")) and r or nil
end

local function cameraDistance(pos: Vector3): number
	local cam = Workspace.CurrentCamera
	return cam and (cam.CFrame.Position - pos).Magnitude or math.huge
end

local function placing(): boolean
	local pc = deps.PlacementController
	if pc and type(pc.isBusy) == "function" then
		local ok, busy = pcall(pc.isBusy)
		return ok and busy == true
	end
	return false
end

-- is my character inside my own casino's footprint?
local function inMyCasino(): boolean
	local root = rootOf(player.Character)
	local plots = Workspace:FindFirstChild("Plots")
	if not (root and plots) then return false end
	for _, plot in plots:GetChildren() do
		if plot:GetAttribute("OwnerId") == player.UserId then
			local base = plot:FindFirstChild("Base")
			if base and base:IsA("BasePart") then
				local rel = base.CFrame:PointToObjectSpace(root.Position)
				return math.abs(rel.X) <= base.Size.X / 2 + 2 and math.abs(rel.Z) <= base.Size.Z / 2 + 2
			end
		end
	end
	return false
end

------------------------------------------------------------------
-- the KICK OUT prompt's Showtime UI (ProximityPrompt Style = Custom)
------------------------------------------------------------------
local promptUI = {} -- prompt -> { gui, conns, sweep, sweepTween, cap, scale, sub }

local function hidePromptUI(prompt)
	local ui = promptUI[prompt]
	if not ui then return end
	promptUI[prompt] = nil
	for _, c in ui.conns do c:Disconnect() end
	if ui.sweepTween then ui.sweepTween:Cancel() end
	if ui.holding then pcall(function() prompt:InputHoldEnd() end) end
	ui.gui:Destroy()
end

local function keyText(prompt, inputType): string
	if inputType == Enum.ProximityPromptInputType.Gamepad then return "Y" end
	if inputType == Enum.ProximityPromptInputType.Touch then return "" end
	local ok, s = pcall(function() return UserInputService:GetStringForKeyCode(prompt.KeyboardKeyCode) end)
	if ok and type(s) == "string" and s ~= "" then return string.upper(s) end
	return prompt.KeyboardKeyCode.Name
end

local SWEEP_EMPTY, SWEEP_FULL = Vector2.new(-0.5, 0), Vector2.new(0.5, 0)

local function showPromptUI(prompt, inputType)
	hidePromptUI(prompt)
	local part = prompt.Parent
	local pg = player:FindFirstChildOfClass("PlayerGui")
	if not (part and part:IsA("BasePart") and pg) then return end
	local touch = inputType == Enum.ProximityPromptInputType.Touch
	local gui = make("BillboardGui", {
		Name = "KickPromptUI", Adornee = part, AlwaysOnTop = true, LightInfluence = 0, Active = true,
		Size = UDim2.fromOffset(228, 66), SizeOffset = Vector2.new(0.64, 0.12), -- beside the guest, not over them
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling, ResetOnSpawn = false,
	})
	local button = make("TextButton", {
		Name = "Hold", Text = "", AutoButtonColor = false, BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1), Parent = gui,
	})
	local scale = make("UIScale", { Scale = 0.55, Parent = button })
	-- hard ink shadow under a crimson velvet pill with a gold trim
	local shadow = make("Frame", {
		Name = "Shadow", BackgroundColor3 = C.Ink, BorderSizePixel = 0, Position = UDim2.fromOffset(0, 5),
		Size = UDim2.new(1, -26, 1, -5), Parent = button,
	})
	UILib.corner(shadow, 999)
	local pill = make("Frame", {
		Name = "Pill", BackgroundColor3 = C.White, BorderSizePixel = 0, Size = UDim2.new(1, -26, 1, -5), Parent = button,
	})
	UILib.corner(pill, 999)
	UILib.gradient(pill, C.CrimsonTop, C.CrimsonDeep, C.Crimson)
	UILib.stroke(pill, C.Ink, 3, true)
	-- the gold sweep: fills left to right while the button is held
	local sweepFrame = make("Frame", {
		Name = "Sweep", BackgroundColor3 = C.Gold, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), ZIndex = 2,
		Parent = pill,
	})
	UILib.corner(sweepFrame, 999)
	local sweep = make("UIGradient", {
		Rotation = 0, Offset = SWEEP_EMPTY,
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.1), NumberSequenceKeypoint.new(0.495, 0.1),
			NumberSequenceKeypoint.new(0.505, 1), NumberSequenceKeypoint.new(1, 1),
		}),
		Parent = sweepFrame,
	})
	local trim = make("Frame", {
		Name = "Trim", BackgroundTransparency = 1, Position = UDim2.fromOffset(4, 4), Size = UDim2.new(1, -8, 1, -8),
		ZIndex = 3, Parent = pill,
	})
	UILib.corner(trim, 999)
	UILib.stroke(trim, C.GoldTop, 1.6, true, 0.15)
	local shine = make("Frame", {
		Name = "Shine", BackgroundColor3 = C.White, BackgroundTransparency = 0.82, BorderSizePixel = 0,
		Position = UDim2.fromOffset(58, 6), Size = UDim2.new(1, -84, 0, 15), ZIndex = 3, Parent = pill,
	})
	UILib.corner(shine, 999)
	-- the key cap
	local cap = make("Frame", {
		Name = "Key", BackgroundColor3 = C.White, BorderSizePixel = 0, AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 6, 0.5, 0), Size = UDim2.fromOffset(46, 46), ZIndex = 4, Parent = pill,
	})
	UILib.corner(cap, 999)
	UILib.gradient(cap, C.Cream, C.CreamRow)
	UILib.stroke(cap, C.Ink, 3, true)
	local capScale = make("UIScale", { Scale = 1, Parent = cap })
	local key = keyText(prompt, inputType)
	if key ~= "" then
		UILib.text(cap, { text = key, size = #key > 1 and 16 or 26, color = C.Ink, stroke = 0, shadow = 0, z = 5 })
	else
		UILib.image(cap, "handcuffs", { size = UDim2.fromScale(0.8, 0.8), anchor = Vector2.new(0.5, 0.5),
			position = UDim2.fromScale(0.5, 0.5), z = 5 }).Image = icon("handcuffs")
	end
	-- KICK OUT / GUEST
	UILib.text(pill, {
		text = prompt.ActionText, size = 24, color = C.White, stroke = 2.5, shadow = 2, z = 5,
		frameSize = UDim2.new(1, -118, 0, 28), position = UDim2.fromOffset(60, 5), xAlign = Enum.TextXAlignment.Left,
	})
	local sub = UILib.body(pill, {
		text = prompt.ObjectText, font = F.Heavy, size = 13, z = 5,
		color = prompt.ObjectText == "SUSPECT!" and C.GoldTop or C.Cream,
		frameSize = UDim2.new(1, -118, 0, 16), position = UDim2.fromOffset(61, 34),
	})
	-- the 3D handcuffs hang off the right end
	local cuffs = UILib.image(button, "handcuffs", {
		size = UDim2.fromOffset(60, 60), anchor = Vector2.new(0.5, 0.5), position = UDim2.new(1, -30, 0.5, -2),
		rotation = 12, z = 6,
	})
	cuffs.Image = icon("handcuffs")
	gui.Parent = pg
	TweenService:Create(scale, TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()

	local ui = { gui = gui, conns = {}, sweep = sweep, sweepTween = nil, cap = capScale, scale = scale, sub = sub }
	promptUI[prompt] = ui
	local function sweepTo(goal: Vector2, t: number, style)
		if ui.sweepTween then ui.sweepTween:Cancel() end
		ui.sweepTween = TweenService:Create(sweep, TweenInfo.new(t, style or Enum.EasingStyle.Linear), { Offset = goal })
		ui.sweepTween:Play()
	end
	table.insert(ui.conns, prompt.PromptButtonHoldBegan:Connect(function()
		sweep.Offset = SWEEP_EMPTY
		sweepTo(SWEEP_FULL, math.max(0.05, prompt.HoldDuration))
		TweenService:Create(capScale, TweenInfo.new(0.08), { Scale = 0.88 }):Play()
	end))
	table.insert(ui.conns, prompt.PromptButtonHoldEnded:Connect(function()
		sweepTo(SWEEP_EMPTY, 0.16, Enum.EasingStyle.Quad)
		TweenService:Create(capScale, TweenInfo.new(0.12, Enum.EasingStyle.Back), { Scale = 1 }):Play()
	end))
	table.insert(ui.conns, prompt.Triggered:Connect(function()
		scale.Scale = 1.18
		TweenService:Create(scale, TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	end))
	table.insert(ui.conns, prompt:GetPropertyChangedSignal("ObjectText"):Connect(function()
		sub.Text = prompt.ObjectText
		sub.TextColor3 = prompt.ObjectText == "SUSPECT!" and C.GoldTop or C.Cream
	end))
	-- touch / mouse: press and hold the pill itself
	local function isPress(input: InputObject): boolean
		return input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1
	end
	table.insert(ui.conns, button.InputBegan:Connect(function(input)
		if isPress(input) and not ui.holding then
			ui.holding = true
			pcall(function() prompt:InputHoldBegin() end)
		end
	end))
	table.insert(ui.conns, button.InputEnded:Connect(function(input)
		if isPress(input) and ui.holding then
			ui.holding = false
			pcall(function() prompt:InputHoldEnd() end)
		end
	end))
	table.insert(ui.conns, prompt.Destroying:Connect(function() hidePromptUI(prompt) end))
	if touch then ui.touch = true end
end

------------------------------------------------------------------
-- KICK OUT prompts on my casino's guests
------------------------------------------------------------------
local patrons = {} -- guest model -> { prompt, conn }
local kicking = {} -- guest model -> a KickGuest call is on its way

local function kick(model: Instance)
	if kicking[model] then return end
	kicking[model] = true
	task.spawn(function()
		local ok, res = pcall(function() return Remotes.KickGuest():InvokeServer(model) end)
		kicking[model] = nil
		if not ok then
			toast("Couldn't kick them out right now.", "error")
		elseif type(res) == "table" and res.ok ~= true then
			toast(tostring(res.message or "Can't kick them out."), "error")
		end
		-- (success: GuestKicked brings the effects)
	end)
end

local function wantsPrompt(model: Instance): boolean
	return model:GetAttribute("CasinoOwner") == player.UserId and model:GetAttribute("Inside") == true
		and model:GetAttribute("Busted") == nil and model:GetAttribute("Kicked") ~= true and not kicking[model]
end

local function objectText(model: Instance): string
	if model:GetAttribute("Suspect") == true then return "SUSPECT!" end
	if model:GetAttribute("GuestTier") == "vip" then return "VIP GUEST" end
	return "GUEST"
end

local function makePrompt(model: Instance, root: BasePart): ProximityPrompt
	local p = Instance.new("ProximityPrompt")
	p.Name = "KickPrompt"
	p.ActionText = "KICK OUT"
	p.ObjectText = objectText(model)
	p.HoldDuration = HOLD
	p.MaxActivationDistance = REACH
	p.RequiresLineOfSight = false
	p.KeyboardKeyCode = Enum.KeyCode.F           -- (E is the machines' prompt)
	p.GamepadKeyCode = Enum.KeyCode.ButtonY
	p.Exclusivity = Enum.ProximityPromptExclusivity.OnePerButton
	p.Style = Enum.ProximityPromptStyle.Custom
	p:SetAttribute(PROMPT_ATTR, true)
	p.Triggered:Connect(function(who)
		if who == player then kick(model) end
	end)
	p.Parent = root
	return p
end

local function syncPrompt(model: Instance)
	local entry = patrons[model]
	if not entry then return end
	local p = entry.prompt
	if wantsPrompt(model) and not placing() then
		if not (p and p.Parent) then
			local root = rootOf(model)
			if root then entry.prompt = makePrompt(model, root) end
		else
			local text = objectText(model)
			if p.ObjectText ~= text then p.ObjectText = text end
		end
	elseif p then
		entry.prompt = nil
		p:Destroy()
	end
end

------------------------------------------------------------------
-- the HUD chip: a suspect is in your casino
------------------------------------------------------------------
local chip, chipPulse, pulseTween = nil, nil, nil
local alertName, alertAt = nil, 0

local function mySuspects(): number
	local n = 0
	for model in patrons do
		if model:GetAttribute("CasinoOwner") == player.UserId and model:GetAttribute("Suspect") == true
			and model:GetAttribute("Busted") == nil and model:GetAttribute("Leaving") ~= true then
			n += 1
		end
	end
	return n
end

local function onChipClick()
	if not inMyCasino() and deps.HudUI and type(deps.HudUI.travelTo) == "function" then
		deps.HudUI.travelTo("casino")
	else
		toast("Look for the red ? over a guest!", "info",
			(UILib.IsTouch and "Walk up to them and hold KICK OUT." or "Walk up to them and hold F to kick them out."), "cheater")
	end
end

local function ensureChip()
	if chip then return chip end
	local hud = deps.HudUI
	if not (hud and type(hud.addChip) == "function") then return nil end
	local ok, handle = pcall(hud.addChip, "cheater", "Red", "cheater", 5)
	if not ok or type(handle) ~= "table" or not handle.Instance then return nil end
	chip = handle
	local f = handle.Instance
	local img = f:FindFirstChildWhichIsA("ImageLabel")
	if img and img.Image == "" then img.Image = icon("cheater") end
	chipPulse = make("UIScale", { Name = "CheaterPulse", Scale = 1, Parent = f })
	-- clickable (pure-scale buttons: the chip sizes itself to its text)
	for _, holder in { f, img } do
		if holder then
			local hit = make("TextButton", {
				Name = "Hit", Text = "", AutoButtonColor = false, BackgroundTransparency = 1,
				Size = UDim2.fromScale(1, 1), ZIndex = 20, Parent = holder,
			})
			hit.Activated:Connect(onChipClick)
		end
	end
	return chip
end

local function setPulse(on: boolean)
	if not chipPulse then return end
	if on and not pulseTween then
		pulseTween = TweenService:Create(chipPulse,
			TweenInfo.new(0.45, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), { Scale = 1.1 })
		pulseTween:Play()
	elseif not on and pulseTween then
		pulseTween:Cancel()
		pulseTween = nil
		chipPulse.Scale = 1
	end
end

local function refreshChip()
	local n = mySuspects()
	local remembered = alertName ~= nil and os.clock() - alertAt < ALERT_MEMORY
	local show = n > 0 or remembered
	if not show and not chip then return end
	local c = ensureChip()
	if not c then return end
	if show then
		local text
		if n > 1 then
			text = ("%d CHEATERS!"):format(n)
		elseif alertName then
			text = "CHEATER: " .. string.upper(string.sub(alertName, 1, 16))
		else
			text = "CHEATER!"
		end
		c.set(text)
	end
	c.show(show)
	setPulse(show)
end

------------------------------------------------------------------
-- guests come and go (CollectionService, streaming-safe)
------------------------------------------------------------------
local WATCH = { CasinoOwner = true, Inside = true, Busted = true, Kicked = true, Suspect = true, GuestTier = true,
	Leaving = true }

local function track(model: Instance)
	if not model:IsA("Model") or patrons[model] then return end
	local entry = { prompt = nil }
	patrons[model] = entry
	entry.conn = model.AttributeChanged:Connect(function(attr)
		if not WATCH[attr] then return end
		syncPrompt(model)
		if attr == "Suspect" or attr == "Busted" or attr == "Leaving" or attr == "CasinoOwner" then refreshChip() end
	end)
	syncPrompt(model)
	if model:GetAttribute("Suspect") == true then refreshChip() end
end

local function untrack(model: Instance)
	local entry = patrons[model]
	patrons[model] = nil
	kicking[model] = nil
	if not entry then return end
	if entry.conn then entry.conn:Disconnect() end
	if entry.prompt then entry.prompt:Destroy() end
	refreshChip()
end

------------------------------------------------------------------
-- Security walks a caught cheater out (a guard on loan from StaffClient)
------------------------------------------------------------------
local escorting = {} -- guest model -> true

local function runEscort(guard, model: Instance, npcRoot: BasePart)
	local gRoot = guard.root
	local frame = guard.frame
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local ignore = { model }
	local staffFolder = Workspace:FindFirstChild("CasinoStaffLocal")
	if staffFolder then table.insert(ignore, staffFolder) end
	for _, p in Players:GetPlayers() do
		if p.Character then table.insert(ignore, p.Character) end
	end
	params.FilterDescendantsInstances = ignore
	pcall(function() params.CollisionGroup = Config.CollisionGroups.NPC end) -- (rays pass guests + players)
	local y = gRoot.Position.Y
	local nextRay = 0
	local walking = false
	local function setWalking(on: boolean, speed: number?)
		if on == walking then return end
		walking = on
		if on then
			guard.stop("idle", 0.15)
			guard.play("walk", { fade = 0.15, speed = math.clamp((speed or STROLL) / 12, 0.6, 1.5) })
		else
			guard.stop("walk", 0.2)
			guard.play("idle", { fade = 0.2 })
		end
	end
	-- one frame toward `target` (flat) at `speed`, standing on the ground under them
	local function step(target: Vector3, speed: number, dt: number, face: Vector3?): number
		local here = gRoot.Position
		local d = Vector3.new(target.X - here.X, 0, target.Z - here.Z)
		local dist = d.Magnitude
		local move = math.min(dist, speed * dt)
		local p = dist > 1e-3 and (here + d.Unit * move) or here
		local now = os.clock()
		if now >= nextRay then
			nextRay = now + 0.15
			local hit = Workspace:Raycast(Vector3.new(p.X, y + 2, p.Z), Vector3.new(0, -(guard.lift + 8), 0), params)
			local ground = hit and hit.Position.Y + guard.lift
			if ground and math.abs(ground - y) < 1.8 then y = ground end -- (curbs and steps, not machine tops)
		end
		local look = face or d
		look = Vector3.new(look.X, 0, look.Z)
		if look.Magnitude < 1e-3 then look = Vector3.new(gRoot.CFrame.LookVector.X, 0, gRoot.CFrame.LookVector.Z) end
		if look.Magnitude < 1e-3 then look = Vector3.zAxis end
		local at = Vector3.new(p.X, y, p.Z)
		guard.rig:PivotTo(CFrame.lookAt(at, at + look.Unit))
		return dist - move
	end
	local function outside(pos: Vector3): boolean
		local rel = frame:PointToObjectSpace(pos)
		return math.abs(rel.X) > guard.W / 2 + 4 or math.abs(rel.Z) > guard.D / 2 + 4
	end
	-- (a cheater upstairs comes down the elevator: the guard waits beside its door)
	local lift = (frame * CFrame.new(E.x - 2.6, 0, E.z - E.size / 2 - 5.2)).Position

	local phase, since = "approach", os.clock()
	while true do
		local dt = RunService.Heartbeat:Wait()
		if not guard.alive() then return end
		local now = os.clock()
		local here = model.Parent ~= nil and npcRoot.Parent ~= nil
		if phase == "approach" then
			if not here then
				phase, since = "back", now
			else
				local np = npcRoot.Position
				local upstairs = np.Y - gRoot.Position.Y > 8
				local target, face = lift, nil
				if not upstairs then
					local away = Vector3.new(gRoot.Position.X - np.X, 0, gRoot.Position.Z - np.Z)
					target = np + (away.Magnitude > 0.1 and away.Unit or Vector3.xAxis) * 2.3
					face = np - gRoot.Position
				end
				local left = step(target, HURRY, dt, face)
				setWalking(left > 0.25, HURRY)
				if (not upstairs and left <= 0.25) or now - since > 9 then
					if not upstairs then guard.play("point", { fade = 0.1 }) end
					phase, since = "follow", now
				end
			end
		elseif phase == "follow" then
			if not here or outside(npcRoot.Position) or now - since > 35 then
				phase, since = "back", now
			elseif npcRoot.Position.Y - gRoot.Position.Y > 8 then
				setWalking(step(lift, STROLL, dt) > 0.25, STROLL)
			else
				-- a step behind them, at their right shoulder, matching their pace
				local np = npcRoot.Position
				local look = Vector3.new(npcRoot.CFrame.LookVector.X, 0, npcRoot.CFrame.LookVector.Z)
				look = look.Magnitude > 1e-3 and look.Unit or Vector3.zAxis
				local target = np - look * 1.5 + look:Cross(Vector3.yAxis) * 1.7
				local gap = Vector3.new(target.X - gRoot.Position.X, 0, target.Z - gRoot.Position.Z).Magnitude
				local speed = math.clamp(gap * 3, 0, 18)
				setWalking(step(target, speed, dt, look) > 0.3, math.max(speed, STROLL))
			end
		else
			-- back to the post
			local home = guard.home()
			local left = step(home.Position, STROLL, dt)
			setWalking(left > 0.2, STROLL)
			if left <= 0.2 or now - since > 25 then return end
		end
	end
end

local function escort(model: Instance, ownerId: number?)
	local sc = deps.StaffClient
	if escorting[model] or not (sc and type(sc.borrowGuard) == "function") then return end
	local npcRoot = rootOf(model)
	if not npcRoot or cameraDistance(npcRoot.Position) > ESCORT_RANGE then return end
	local ok, guard = pcall(sc.borrowGuard, ownerId, npcRoot.Position)
	if not (ok and type(guard) == "table") then return end
	escorting[model] = true
	local okRun, err = pcall(runEscort, guard, model, npcRoot)
	if not okRun then softWarn("escort: " .. tostring(err)) end
	escorting[model] = nil
	pcall(guard.release)
end

------------------------------------------------------------------
-- server pushes
------------------------------------------------------------------
local firstAlertShown = false

local function onAlert(info)
	if type(info) ~= "table" then return end
	local name = type(info.name) == "string" and info.name or "your casino"
	if info.kind == "escaped" then
		alertName = nil
		local stats = UILib.state.cheaters
		local security = type(stats) == "table" and tonumber(stats.security) or 0
		local hint = (security or 0) > 0 and "Kick cheaters out before they leave!"
			or "Hire Security (SHOP > STAFF) to catch cheaters for you."
		toast("A CHEATER GOT AWAY!", "error",
			("They walked off with %s. %s"):format(UILib.money(tonumber(info.amount) or 0), hint), "cheater")
		refreshChip()
		return
	end
	alertName, alertAt = name, os.clock()
	local how = UILib.IsTouch and "hold KICK OUT" or "hold F"
	local stats = UILib.state.cheaters
	local busted = type(stats) == "table" and ((tonumber(stats.kicked) or 0) + (tonumber(stats.caught) or 0)) or 0
	if busted == 0 and not firstAlertShown then
		-- the very first one: say what's going on
		firstAlertShown = true
		UILib.fx("banner", "CHEATER ALERT!", "A red ? = a cheater. Kick them out for a reward!", "crimson", "error")
	else
		toast("CHEATER ALERT!", "error", ("Someone's cheating at %s! Find the red ? and %s."):format(name, how), "cheater")
	end
	UILib.fx("vignette", C.Crimson, 2)
	refreshChip()
end

local function onKicked(info)
	if type(info) ~= "table" then return end
	local model = typeof(info.npc) == "Instance" and info.npc or nil
	if model and not model.Parent then model = nil end
	local root = rootOf(model)
	local pos = (root and root.Position) or (typeof(info.pos) == "Vector3" and info.pos) or nil
	local near = pos ~= nil and cameraDistance(pos) <= FX_RANGE
	local mine = info.ownerId == player.UserId
	if model then
		if patrons[model] then syncPrompt(model) end
		if GuestTags and GuestTags.refresh then pcall(GuestTags.refresh, model) end
	end
	local where = model or pos
	if info.cheater then
		if near then
			UILib.fx("worldText", where, info.by == "security" and "CAUGHT!" or "BUSTED!", C.CrimsonTop, 40)
		end
		if info.by == "security" and model then task.spawn(escort, model, info.ownerId) end
		if mine then
			alertName = nil
			local reward = tonumber(info.reward) or 0
			local cash = UILib.money(reward)
			if info.by == "owner" then
				local xp = tonumber(info.xp) or 0
				local sub = "Winnings confiscated: +" .. cash
				if xp > 0 then sub ..= "   +" .. UILib.short(xp) .. " XP" end
				UILib.fx("banner", info.raid and "RAID BUST! x2" or "CHEATER BUSTED!", sub, "crimson", "kaching")
				if where then UILib.fx("coinBurst", where, math.max(reward, 100)) end
				if near and xp > 0 then
					task.delay(0.55, function()
						UILib.fx("worldText", (model and model.Parent and model) or pos, "+" .. UILib.short(xp) .. " XP",
							C.BlueTop, 28)
					end)
				end
			else
				toast("SECURITY CAUGHT A CHEATER!", "income", "Their winnings are yours: +" .. cash, "shield")
			end
		end
	else
		if near then UILib.fx("worldText", where, "HEY!", C.Cream, 30) end
		if mine then
			toast("Oops - that guest was honest!", "error",
				"They left with their wallet. Cheaters get a red ? over their head.", "cheater")
		end
	end
	refreshChip()
end

------------------------------------------------------------------
-- start
------------------------------------------------------------------
function CheatersUI.start(d)
	if started then return end
	started = true
	deps = type(d) == "table" and d or {}

	-- the tag over every guest's head
	local tagsModule = script.Parent:FindFirstChild("GuestTags")
	if tagsModule then
		local ok, res = pcall(require, tagsModule)
		if ok and type(res) == "table" then
			GuestTags = res
			local okStart, err = pcall(res.start)
			if not okStart then softWarn("GuestTags.start: " .. tostring(err)) end
		else
			softWarn("GuestTags failed to load: " .. tostring(res))
		end
	else
		softWarn("GuestTags is missing: guests have no tags")
	end

	UILib.onFx(onFx)

	-- the KICK OUT prompt's own look
	ProximityPromptService.PromptShown:Connect(function(prompt, inputType)
		if prompt:GetAttribute(PROMPT_ATTR) then
			local ok, err = pcall(showPromptUI, prompt, inputType)
			if not ok then softWarn("prompt: " .. tostring(err)) end
		end
	end)
	ProximityPromptService.PromptHidden:Connect(function(prompt)
		if promptUI[prompt] then hidePromptUI(prompt) end
	end)

	for _, m in CollectionService:GetTagged(TAG) do track(m) end
	CollectionService:GetInstanceAddedSignal(TAG):Connect(track)
	CollectionService:GetInstanceRemovedSignal(TAG):Connect(untrack)

	task.spawn(function()
		local okA, alertEv = pcall(function() return Remotes.CheaterAlert() end)
		if okA and alertEv then
			alertEv.OnClientEvent:Connect(function(info)
				local ok, err = pcall(onAlert, info)
				if not ok then softWarn("alert: " .. tostring(err)) end
			end)
		end
		local okK, kickedEv = pcall(function() return Remotes.GuestKicked() end)
		if okK and kickedEv then
			kickedEv.OnClientEvent:Connect(function(info)
				local ok, err = pcall(onKicked, info)
				if not ok then softWarn("kicked: " .. tostring(err)) end
			end)
		end
	end)

	-- the slow tick: prompts follow build mode, the chip forgets old alerts
	task.spawn(function()
		while true do
			task.wait(0.4)
			local ok, err = pcall(function()
				for model in patrons do syncPrompt(model) end
				refreshChip()
			end)
			if not ok then softWarn("tick: " .. tostring(err)) end
		end
	end)
end

return CheatersUI
