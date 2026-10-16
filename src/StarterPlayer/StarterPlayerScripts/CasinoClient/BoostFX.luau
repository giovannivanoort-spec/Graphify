--!nonstrict
-- BoostFX.luau — the x3 machine boost on the client (server: MachineBoost.luau).
--   * the aura: every boosted machine near the camera (attribute BoostLeft > 0, set by
--     the server, refreshed every ~5 s) gets a turning golden sunburst halo on the
--     floor, flame embers rising around its footprint, sparkles, a warm pulsing light
--     and a floating "x3 12:34" badge that counts down. Client-only, culled by distance
--     (AURA_RANGE) and capped at the MAX_AURAS nearest. Your own machine gets a little
--     celebration when time lands on it.
--   * BoostFX.machineSection(parent, machine, panel, y): the boost strip of your own
--     machine's popup (ManageUI.openForMachine): a big "x3 BOOST • 15 MIN" button with
--     the Robux price (SetBoostTarget(placedId), then the machine_boost product prompt;
--     buying again ADDS 15 min), the time left on this machine and "USE STORED"
--     (ApplyStoredBoost, up to 15 min a click).
-- Works with StreamingEnabled (tagged machines are tracked as they stream in and out).

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")
local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Remotes = require(Common:WaitForChild("Remotes"))
local Config = require(Common:WaitForChild("Config"))
local UILib = require(script.Parent:WaitForChild("UILib"))
local C = UILib.Colors
local F = UILib.Fonts

local BoostFX = {}
local player = Players.LocalPlayer
local deps = {}
local started = false

local CFG = Config.MachineBoost or {}
local MULT = tonumber(CFG.Multiplier) or 3
local CHUNK = tonumber(CFG.Seconds) or 900
local AURA_RANGE = 150       -- studs from the camera
local MAX_AURAS = 10         -- the nearest boosted machines get one
local TOUCH = UILib.IsTouch
local FIRE = "rbxasset://textures/particles/fire_main.dds"
local SPARKLE = "rbxasset://textures/particles/sparkles_main.dds"
local GOLD = Color3.fromRGB(255, 205, 64)
local GOLD_TOP = Color3.fromRGB(255, 243, 168)
local EMBER = Color3.fromRGB(255, 128, 36)
local MAGENTA = Color3.fromRGB(255, 72, 170)

------------------------------------------------------------------
-- which machines are boosted (BoostLeft, interpolated between server refreshes)
------------------------------------------------------------------
local boosted: {[Instance]: { base: number, t: number }} = {}
local watched: {[Instance]: RBXScriptConnection} = {}
local auras: {[Instance]: any} = {}
local fxFolder: Folder? = nil

local function leftOn(model: Instance): number
	local b = boosted[model]
	if not b then return 0 end
	return math.max(0, b.base - (os.clock() - b.t))
end

local function folder(): Folder
	if fxFolder and fxFolder.Parent then return fxFolder end
	local f = Instance.new("Folder")
	f.Name = "BoostFX"
	f.Parent = Workspace
	fxFolder = f
	return f
end

local function ghostPart(name: string, size: Vector3, cf: CFrame, parent: Instance): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Transparency = 1
	p.Size = size
	p.CFrame = cf
	p.Parent = parent
	return p
end

local function loopTween(inst: Instance, info: TweenInfo, goal)
	local tw = TweenService:Create(inst, info, goal)
	tw:Play()
	return tw
end

------------------------------------------------------------------
-- the aura
------------------------------------------------------------------
local function destroyAura(model: Instance)
	local a = auras[model]
	if not a then return end
	auras[model] = nil
	if a.root then a.root:Destroy() end
end

local function buildAura(model: Model)
	local ok, bbCF, bbSize = pcall(function() return model:GetBoundingBox() end)
	if not ok or not bbCF then return nil end
	local center = bbCF.Position
	local bottom = center.Y - bbSize.Y / 2
	local radius = tonumber(model:GetAttribute("FootprintRadius")) or math.max(bbSize.X, bbSize.Z) / 2
	radius = math.clamp(radius, 1.5, 9)

	local root = Instance.new("Model")
	root.Name = "Boost_" .. tostring(model:GetAttribute("PlacedId") or model.Name)

	-- the floor halo: a glow pool + a turning sunburst on a SurfaceGui
	local d = (radius + 1.6) * 2
	local halo = ghostPart("Halo", Vector3.new(d, 0.1, d), CFrame.new(center.X, bottom + 0.08, center.Z), root)
	local gui = Instance.new("SurfaceGui")
	gui.Name = "HaloGui"
	gui.Face = Enum.NormalId.Top
	gui.LightInfluence = 0
	gui.Brightness = 1.6
	gui.SizingMode = Enum.SurfaceGuiSizingMode.FixedSize
	gui.CanvasSize = Vector2.new(256, 256)
	gui.Adornee = halo
	gui.Parent = halo
	local pool = Instance.new("ImageLabel")
	pool.Name = "Pool"
	pool.BackgroundTransparency = 1
	pool.Image = UILib.Tex.glow
	pool.ImageColor3 = GOLD
	pool.ImageTransparency = 0.2
	pool.Size = UDim2.fromScale(1, 1)
	pool.Parent = gui
	local rays = Instance.new("ImageLabel")
	rays.Name = "Rays"
	rays.BackgroundTransparency = 1
	rays.Image = UILib.Tex.sunburst
	rays.ImageColor3 = GOLD_TOP
	rays.ImageTransparency = 0.45
	rays.AnchorPoint = Vector2.new(0.5, 0.5)
	rays.Position = UDim2.fromScale(0.5, 0.5)
	rays.Size = UDim2.fromScale(0.95, 0.95)
	rays.Parent = gui
	loopTween(rays, TweenInfo.new(9, Enum.EasingStyle.Linear, Enum.EasingDirection.In, -1), { Rotation = 360 })
	loopTween(pool, TweenInfo.new(0.9, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ ImageTransparency = 0.45 })

	-- flame embers rising around the footprint
	local jets = TOUCH and 6 or 8
	local flames = {}
	for i = 1, jets do
		local ang = (i - 1) / jets * math.pi * 2
		local att = Instance.new("Attachment")
		att.Name = "Jet"
		att.Position = Vector3.new(math.cos(ang) * (radius + 0.4), 0.1, math.sin(ang) * (radius + 0.4))
		att.Parent = halo
		local e = Instance.new("ParticleEmitter")
		e.Name = "Flame"
		e.Texture = FIRE
		e.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, GOLD_TOP), ColorSequenceKeypoint.new(0.45, EMBER), ColorSequenceKeypoint.new(1, MAGENTA),
		})
		e.LightEmission = 1
		e.LightInfluence = 0
		e.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.85), NumberSequenceKeypoint.new(1, 0.1) })
		e.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.3), NumberSequenceKeypoint.new(0.7, 0.55), NumberSequenceKeypoint.new(1, 1),
		})
		e.Lifetime = NumberRange.new(0.5, 0.9)
		e.Rate = TOUCH and 4 or 7
		e.Speed = NumberRange.new(2.5, 4.5)
		e.SpreadAngle = Vector2.new(12, 12)
		e.EmissionDirection = Enum.NormalId.Top
		e.Acceleration = Vector3.new(0, 3, 0)
		e.Rotation = NumberRange.new(0, 360)
		e.RotSpeed = NumberRange.new(-60, 60)
		e.Parent = att
		table.insert(flames, e)
	end

	-- sparkles through the machine + a warm pulsing light
	local volume = ghostPart("Volume", Vector3.new(math.max(1, bbSize.X), math.max(1, bbSize.Y), math.max(1, bbSize.Z)),
		bbCF, root)   -- (turned with the machine)
	local sparks = Instance.new("ParticleEmitter")
	sparks.Name = "Sparkles"
	sparks.Texture = SPARKLE
	sparks.Color = ColorSequence.new(GOLD_TOP, GOLD)
	sparks.LightEmission = 1
	sparks.LightInfluence = 0
	sparks.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.45), NumberSequenceKeypoint.new(1, 0) })
	sparks.Transparency = NumberSequence.new(0.1, 1)
	sparks.Lifetime = NumberRange.new(1, 1.6)
	sparks.Rate = TOUCH and 3 or 6
	sparks.Speed = NumberRange.new(1, 2)
	sparks.EmissionDirection = Enum.NormalId.Top
	sparks.SpreadAngle = Vector2.new(25, 25)
	sparks.Parent = volume
	local light = Instance.new("PointLight")
	light.Name = "BoostLight"
	light.Color = GOLD
	light.Brightness = 1.6
	light.Range = math.clamp(radius * 3, 10, 18)
	light.Shadows = false
	light.Parent = volume
	loopTween(light, TweenInfo.new(0.9, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), { Brightness = 3 })

	-- the floating "x3 12:34" badge, above the machine's name tag
	local bb = Instance.new("BillboardGui")
	bb.Name = "BoostBadge"
	bb.AlwaysOnTop = true
	bb.LightInfluence = 0
	bb.MaxDistance = 110
	bb.Size = UDim2.fromScale(4.8, 1.5)
	bb.StudsOffsetWorldSpace = Vector3.new(0, bbSize.Y / 2 + 3.4, 0)
	bb.Adornee = volume
	bb.Parent = volume
	local pop = Instance.new("UIScale")
	pop.Parent = bb
	local pill = Instance.new("Frame")
	pill.Name = "Pill"
	pill.BackgroundColor3 = C.Ink
	pill.BackgroundTransparency = 0.12
	pill.Size = UDim2.fromScale(1, 1)
	pill.Parent = bb
	UILib.corner(pill, 999)
	UILib.stroke(pill, C.Gold, 2, true)
	local icon = Instance.new("ImageLabel")
	icon.Name = "Icon"
	icon.BackgroundTransparency = 1
	icon.Image = UILib.resolveIcon("boost")
	icon.ScaleType = Enum.ScaleType.Fit
	icon.Size = UDim2.fromScale(0.34, 1.35)
	icon.Position = UDim2.fromScale(-0.1, -0.2)
	icon.ZIndex = 3
	icon.Parent = pill
	local function label(name: string, text: string, font, x: number, w: number, color: Color3): TextLabel
		local l = Instance.new("TextLabel")
		l.Name = name
		l.BackgroundTransparency = 1
		l.Text = text
		l.Font = font
		l.TextScaled = true
		l.TextColor3 = color
		l.Position = UDim2.fromScale(x, 0.12)
		l.Size = UDim2.fromScale(w, 0.76)
		l.ZIndex = 2
		l.Parent = pill
		local s = Instance.new("UIStroke")
		s.Color = C.Ink
		s.Thickness = 2
		s.Parent = l
		return l
	end
	local mult = label("Mult", "x" .. MULT, F.Display, 0.22, 0.26, GOLD_TOP)
	local grad = Instance.new("UIGradient")
	grad.Rotation = 90
	grad.Color = ColorSequence.new(Color3.new(1, 1, 1), GOLD)
	grad.Parent = mult
	local time = label("Time", "", F.Number, 0.5, 0.45, Color3.new(1, 1, 1))
	loopTween(pop, TweenInfo.new(0.55, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), { Scale = 1.07 })

	root.Parent = folder()
	return {
		root = root, halo = halo, volume = volume, sparks = sparks, flames = flames, time = time,
		pivot = model:GetPivot().Position,
	}
end

local function celebrate(model: Instance)
	if model:GetAttribute("OwnerId") ~= player.UserId then return end
	UILib.fx("worldText", model, ("x%d BOOST!"):format(MULT), GOLD_TOP, 34)
	UILib.fx("sound", "kaching")
	local a = auras[model]
	if a and a.sparks and a.sparks.Parent then pcall(function() a.sparks:Emit(30) end) end
end

------------------------------------------------------------------
-- tracking (streaming-safe)
------------------------------------------------------------------
local function readBoost(model: Instance, fresh: boolean)
	local v = tonumber(model:GetAttribute("BoostLeft")) or 0
	local before = leftOn(model)
	if v > 0 then
		boosted[model] = { base = v, t = os.clock() }
		if fresh and v > before + 30 then celebrate(model) end
	else
		boosted[model] = nil
		destroyAura(model)
	end
end

local function track(model: Instance)
	if watched[model] or not model:IsA("Model") then return end
	watched[model] = model:GetAttributeChangedSignal("BoostLeft"):Connect(function()
		readBoost(model, true)
	end)
	readBoost(model, false)
end

local function untrack(model: Instance)
	local conn = watched[model]
	if conn then conn:Disconnect() end
	watched[model] = nil
	boosted[model] = nil
	destroyAura(model)
end

-- a machine BuildingView cut away (a story above you) or one being moved
local function hiddenLocally(model: Instance): boolean
	local body = (model:IsA("Model") and model.PrimaryPart) or model:FindFirstChild("Body")
	return body ~= nil and body:IsA("BasePart") and body.LocalTransparencyModifier >= 1
end

-- every 0.5 s: the MAX_AURAS nearest boosted machines in range get an aura; every
-- 0.25 s: the badges count down
local function cull()
	local cam = Workspace.CurrentCamera
	local camPos = cam and cam.CFrame.Position or Vector3.zero
	local list = {}
	for model in boosted do
		if not model.Parent then
			untrack(model)
		elseif leftOn(model) > 0 and not hiddenLocally(model) then
			local okP, pivot = pcall(function() return model:GetPivot().Position end)
			if okP then
				local dist = (pivot - camPos).Magnitude
				if dist <= AURA_RANGE then table.insert(list, { m = model, d = dist, p = pivot }) end
			end
		end
	end
	table.sort(list, function(a, b) return a.d < b.d end)
	local want = {}
	for i = 1, math.min(#list, MAX_AURAS) do want[list[i].m] = list[i].p end
	for model in auras do
		if not want[model] then destroyAura(model) end
	end
	for model, pivot in want do
		local a = auras[model]
		-- a machine that moved gets its aura rebuilt where it stands now
		if a and (a.pivot - pivot).Magnitude > 0.05 then
			destroyAura(model)
			a = nil
		end
		if not a then
			local ok, res = pcall(buildAura, model)
			if ok and res then
				auras[model] = res
			elseif not ok then
				warn("[BoostFX] aura: " .. tostring(res))
			end
		end
	end
end

local function updateBadges()
	for model, a in auras do
		local left = leftOn(model)
		if left <= 0 then
			destroyAura(model)
		elseif a.time then
			a.time.Text = UILib.clock(left)
		end
	end
end

------------------------------------------------------------------
-- the popup strip (ManageUI.openForMachine)
------------------------------------------------------------------
local function store()
	if deps.RobuxShopUI then return deps.RobuxShopUI end
	local mod = script.Parent:FindFirstChild("RobuxShopUI")
	if not mod then return nil end
	local ok, res = pcall(require, mod)
	return ok and type(res) == "table" and res or nil
end

local function boostProduct()
	local list = Config.Monetization and Config.Monetization.BoostProducts
	return type(list) == "table" and list[1] or nil
end

local function storedSeconds(): number
	local b = UILib.state and UILib.state.boosts
	return type(b) == "table" and math.max(0, math.floor(tonumber(b.stored) or 0)) or 0
end

-- seconds of boost left on a placed machine: the snapshot's placed[i].boost counted
-- down since it arrived, else the machine's BoostLeft attribute
local function machineLeft(machine: Instance): number
	local pid = machine:GetAttribute("PlacedId")
	for _, e in (UILib.state and UILib.state.placed or {}) do
		if e.placedId == pid then
			local v = tonumber(e.boost) or 0
			return v > 0 and UILib.secondsLeft(v) or 0
		end
	end
	return leftOn(machine)
end

-- y: where the strip starts in `parent` (design px); returns the strip Frame
function BoostFX.machineSection(parent: Instance, machine: Instance, panel, y: number?)
	local placedId = machine:GetAttribute("PlacedId")
	local prod = boostProduct()
	local W = 250  -- the buttons column

	local strip = UILib.make("Frame", {
		Name = "BoostStrip", BackgroundColor3 = C.White, Position = UDim2.fromOffset(0, y or 0),
		Size = UDim2.new(1, 0, 0, 120), ZIndex = 2, Parent = parent,
	})
	UILib.corner(strip, 20)
	UILib.gradient(strip, C.PurpleTop, C.PurpleShadow, C.Purple)
	UILib.stroke(strip, C.Ink, 3.5, true)

	-- the x3 medallion: a turning sunburst behind a gold tile, the boost icon, "x3"
	local rays = UILib.image(strip, UILib.Tex.sunburst, {
		name = "Rays", size = UDim2.fromOffset(124, 124), anchor = Vector2.new(0.5, 0.5),
		position = UDim2.fromOffset(60, 60), color = C.GoldTop, transparency = 0.5, z = 2,
	})
	UILib.spin(rays, 25)
	local tile = UILib.make("Frame", {
		Name = "Tile", BackgroundColor3 = C.White, Position = UDim2.fromOffset(12, 12),
		Size = UDim2.fromOffset(96, 96), ZIndex = 2, Parent = strip,
	})
	UILib.corner(tile, 18)
	UILib.gradient(tile, C.GoldTop, C.GoldDeep, C.Gold)
	UILib.stroke(tile, C.Ink, 3.5, true)
	UILib.image(tile, "boost", {
		size = UDim2.fromScale(0.95, 0.95), anchor = Vector2.new(0.5, 0.5), position = UDim2.fromScale(0.5, 0.42), z = 2,
	})
	UILib.text(tile, {
		text = "x" .. MULT, size = 30, frameSize = UDim2.new(1, 0, 0, 34), position = UDim2.new(0, 0, 1, -36), z = 3,
		gradient = { C.White, C.GoldTop }, stroke = 3, shadow = 3,
	})

	-- the middle: title, what it does / how long is left, the timer bar
	local midW = -(122 + W + 26)
	UILib.text(strip, {
		name = "Title", text = ("x%d CASH BOOST"):format(MULT), size = 28, xAlign = Enum.TextXAlignment.Left,
		frameSize = UDim2.new(1, midW, 0, 32), position = UDim2.fromOffset(122, 8), z = 2,
		gradient = { C.White, C.GoldTop }, stroke = 3, shadow = 3,
	})
	local status = UILib.body(strip, {
		name = "Status", text = "", rich = true, wrap = true, size = 14, color = C.Cream, z = 2,
		frameSize = UDim2.new(1, midW, 0, 36), position = UDim2.fromOffset(122, 44), yAlign = Enum.TextYAlignment.Top,
	})
	local bar = UILib.progressBar(strip, {
		name = "Timer", size = UDim2.new(1, midW, 0, 24), position = UDim2.fromOffset(122, 84), tone = "Gold",
		textSize = 14, z = 2,
	})

	-- the buttons: BUY (with the Robux price tag), USE STORED
	local buy = UILib.button({
		parent = strip, tone = "Gold", text = ("x%d BOOST • %d MIN"):format(MULT, math.floor(CHUNK / 60)),
		textSize = 19, size = UDim2.fromOffset(W, 58), anchor = Vector2.new(1, 0), position = UDim2.new(1, -12, 0, 10),
		z = 3,
		onClick = function()
			if not prod or (tonumber(prod.id) or 0) == 0 then
				UILib.toast("COMING SOON!", "info", "Machine boosts aren't on sale yet - check back soon.")
				return
			end
			local ok, res = pcall(function() return Remotes.SetBoostTarget():InvokeServer(placedId) end)
			if not (ok and type(res) == "table" and res.ok) then
				UILib.toast(ok and type(res) == "table" and res.message or "Can't boost this machine right now.", "error")
				return
			end
			local s = store()
			if s and s.promptProduct then s.promptProduct(prod.id) end
		end,
	})
	local tag = UILib.badge(buy.Instance, "R$ ...", "Green", 8, 8)
	tag.AnchorPoint = Vector2.new(1, 0)
	tag.Position = UDim2.new(1, 10, 0, -14)
	local tagLabel = tag:FindFirstChildWhichIsA("Frame") and tag:FindFirstChildWhichIsA("Frame"):FindFirstChild("Face")
	local function setTag(text: string)
		if tagLabel and tagLabel.Parent then tagLabel.Text = text end
	end
	local s = store()
	if s and s.priceText then
		s.priceText(prod and prod.id or 0, Enum.InfoType.Product, setTag)
	else
		setTag("SOON")
	end

	local useStored = UILib.button({
		parent = strip, tone = "Green", text = "USE STORED", textSize = 18, size = UDim2.fromOffset(W, 42),
		anchor = Vector2.new(1, 0), position = UDim2.new(1, -12, 0, 72), z = 3,
		onClick = function()
			local ok, res = pcall(function() return Remotes.ApplyStoredBoost():InvokeServer(placedId, CHUNK) end)
			if ok and type(res) == "table" and res.ok then
				UILib.toast(("x%d BOOST!"):format(MULT), "unlock", res.message)
			else
				UILib.toast(ok and type(res) == "table" and res.message or "Couldn't apply the boost.", "error")
			end
		end,
	})

	local peak = 0
	local lastLeft = machineLeft(machine)
	local function refresh()
		if not strip.Parent then return end
		local left = machineLeft(machine)
		local stored = storedSeconds()
		-- time landed on this machine (a purchase / USE STORED): celebrate here too
		if left > lastLeft + 30 then
			UILib.fx("celebrate", "unlock", tile)
			UILib.fx("banner", ("x%d BOOST!"):format(MULT), string.upper(machine.Name) .. " EARNS TRIPLE", "purple")
		end
		lastLeft = left
		if left > 0 then
			if left > peak then peak = math.max(left, CHUNK) end
			bar.Instance.Visible = true
			bar.set(math.clamp(left / math.max(1, peak), 0, 1), UILib.clock(left) .. " LEFT")
			status.Text = ("<b>BOOSTED!</b> This machine earns x%d. Buy again to add %d min."):format(MULT,
				math.floor(CHUNK / 60))
		else
			peak = 0
			bar.Instance.Visible = false
			status.Text = ("Triple this machine's earnings for %d min. Buy again to add time!"):format(
				math.floor(CHUNK / 60))
		end
		if stored > 0 then
			status.Text ..= ("  <b>%s stored.</b>"):format(UILib.clock(stored))
			useStored.Instance.Visible = true
			useStored.setText(("USE STORED (%s)"):format(UILib.clock(math.min(stored, CHUNK))))
			buy.Instance.Position = UDim2.new(1, -12, 0, 10)
		else
			useStored.Instance.Visible = false
			buy.Instance.Position = UDim2.new(1, -12, 0, 31)
		end
	end
	refresh()
	local unsub = UILib.subscribe(function() refresh() end)
	if panel and panel.onClose then panel.onClose(unsub) end
	task.spawn(function()
		while strip.Parent and (not panel or panel.alive ~= false) do
			task.wait(1)
			refresh()
		end
		unsub()
	end)
	return strip
end

------------------------------------------------------------------
-- start
------------------------------------------------------------------
function BoostFX.start(d)
	deps = type(d) == "table" and d or {}
	if started then return end
	started = true
	for _, m in CollectionService:GetTagged("CasinoMachine") do track(m) end
	CollectionService:GetInstanceAddedSignal("CasinoMachine"):Connect(track)
	CollectionService:GetInstanceRemovedSignal("CasinoMachine"):Connect(untrack)
	task.spawn(function()
		local beat = 0
		while true do
			task.wait(0.25)
			beat += 1
			if beat % 2 == 0 then
				local ok, err = pcall(cull)
				if not ok then warn("[BoostFX] cull: " .. tostring(err)) end
			end
			local ok, err = pcall(updateBadges)
			if not ok then warn("[BoostFX] badges: " .. tostring(err)) end
		end
	end)
end

return BoostFX
