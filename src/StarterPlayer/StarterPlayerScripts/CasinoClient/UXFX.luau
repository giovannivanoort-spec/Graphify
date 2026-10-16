--!nonstrict
-- UXFX.luau — the "Showtime" juice layer (cream / crimson / gold, Luckiest
-- Guy). Optional by design: init.client requires + starts it inside pcall and
-- every other module reaches it through UILib.fx(...), a silent no-op while
-- UXFX isn't running — so nothing here can ever break a UI or the game.
--
-- On its own (no UI module has to know):
--   * buttons: hover tick + click; tabs tick; panels whoosh open / shut
--   * toasts by kind: unlock = ka-ching + confetti from the button you pressed
--     (which pops), income = coin chime, ticket = pink pop, error = buzz + the
--     button and the toast shake
--   * money: coins fly from where it came from (the button you pressed, the
--     machine you sold, a big windfall) into the HUD cash pill — the pill
--     pulses per coin, the number rolls as they land and "+$X" pops; spending
--     sends a few coins from the pill to what you bought
--   * your casino (server FX remote, Gambling.luau): "+$X" over each of your
--     machines as the house wins (green; gold for concessions) and a coin
--     flying to the pill; a guest's big win = bulbs strobe + coin fountain +
--     light flash at the machine; 20x+ = a JACKPOT banner
--   * placement: the machine drops in (fall, thud, dust ring, small hop);
--     storing / selling one = a puff of smoke + sparkles (+ the sale's coins)
--   * night rush: purple vignette pulse + jingle + sparkles on the clock badge
--
-- Wired in by: UILib (button / tab / panel / toast hooks), HudUI (cashGain,
-- cashSpend, ticketGain + UILib.fxTargets), PlacementController
-- (expectPlacement / placeDrop / cancelExpected), DayNightFX (nightRush),
-- init.client (start), and Gambling.luau on the server (the FX remote;
-- Gambling.fxIncome(owner, machine, amount) gives any income source — e.g. the
-- NPCs' concession visits — its "+$X" pop over that machine).
--
-- API for other modules — call through UILib.fx so a UXFX failure is harmless.
-- An `anchor` is a GuiObject (its centre), a Vector3 / BasePart / Model (world)
-- or a Vector2 in AbsolutePosition pixels; nil = the middle of the screen.
--   UILib.fx("celebrate", kind, anchor?)          kind "unlock" | "income" | "ticket" | "big" | "small"
--   UILib.fx("banner", title, subtitle?, style?, sound?)
--        style "gold" (default) | "crimson" | "purple" | "green" | "blue"; queued, one at a time
--        e.g. UILib.fx("banner", "NEW MACHINE UNLOCKED!", "Mega Wheel is in the Showroom")
--             UILib.fx("banner", "RANK UP!", "You're a HIGH ROLLER now", "crimson")
--   UILib.fx("coinBurst", from, amount?, target?)  coins fly into the HUD: from = GuiObject |
--        Vector3 | BasePart | Model | Vector2 (AbsolutePosition px); target "cash" (default) | "tickets"
--   UILib.fx("shake", gui, strength?)             the "no" wiggle
--   UILib.fx("pop", gui, scale?)                  scale pop (never touches a UIScale named AutoScale)
--   UILib.fx("sound", name, speed?, volume?)      names: see SOUNDS
--   UILib.fx("confetti", anchor?, count?, palette?)   palette "show" | "money" | "ticket" | "night"
--   UILib.fx("sparkle", anchor, count?, color?)
--   UILib.fx("flash", color?, strength?)          full-screen flash
--   UILib.fx("punch", strength?)                  camera FOV punch (additive; Reduced Motion skips it)
--   UILib.fx("vignette", color?, pulses?)
--   UILib.fx("worldText", where, text, color?, size?)   where = Vector3 | BasePart | Model
--   UILib.fx("puff", position, radius?)           smoke puff in the world
--   UILib.fx("reducedMotion")                     -> boolean
-- Or directly: local ok, UXFX = pcall(require, script.Parent:WaitForChild("UXFX")) — the same table;
-- every function is a no-op until start().
--
-- Performance: everything is client-local and pooled (coins, confetti, stars,
-- rings, "+$X" labels; three shared particle emitters for the world), one
-- RenderStepped runs only while something moves, particle counts are capped
-- and cut on touch devices; Reduced Motion (the player's Roblox setting) drops
-- shake / punch / the drop-in and halves particles. UXFX.MasterVolume scales
-- every sound (one SoundGroup).

local CollectionService = game:GetService("CollectionService")
local ContentProvider = game:GetService("ContentProvider")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TextService = game:GetService("TextService")
local Workspace = game:GetService("Workspace")

local UILib = require(script.Parent:WaitForChild("UILib"))
local C = UILib.Colors
local F = UILib.Fonts

local UXFX = {}
local player = Players.LocalPlayer

------------------------------------------------------------------
-- tuning
------------------------------------------------------------------
UXFX.MasterVolume = 0.8 -- every UXFX sound plays through one SoundGroup at this volume
UXFX.Settings = {
	reducedMotion = nil, -- nil = follow the player's Roblox "Reduced Motion" setting; true / false forces it
	intensity = 1,       -- scales particle counts
}

local MAX_COINS = 30
local MAX_CONFETTI = 72
local MAX_SPARKS = 28
local MAX_RINGS = 10
local MAX_LABELS = 10
local INCOME_RANGE = 150 -- studs: "+$X" pops only for machines this close to the camera
local INCOME_POPS = 6    -- labels per server batch
local INCOME_COINS = 4   -- coins flying to the pill per server batch
local JACKPOT_MULT = 20  -- a guest win of this many x the bet gets the JACKPOT banner
local DROP_H, FALL_T, SETTLE_T = 5, 0.24, 0.3 -- placement drop-in
local LABEL_LIFT = Vector3.new(0, 1.8, 0) -- "+$X" starts above the machine's name tag

-- Built-in files ship with every Roblox client (content/sounds); the rest are
-- free Creator Store audio (Pro Sound Effects / APM / Daily Sounds libraries)
-- and the machines' own win jingle. A primary that fails to load swaps to its
-- fallback at runtime (verifySounds), so a moderated id only ever costs polish.
local TICK = "rbxasset://sounds/volume_slider.ogg"
local LAND = "rbxasset://sounds/action_jump_land.mp3"
local SOUNDS = {
	click   = { id = "rbxassetid://9119717523", vol = 0.32, speed = 1.1, gap = 0.04, voices = 2, fallback = TICK },
	hover   = { id = TICK, vol = 0.1, speed = 1.7, gap = 0.07 },
	tab     = { id = TICK, vol = 0.3, speed = 1.2, gap = 0.05 },
	tick    = { id = TICK, vol = 0.24, speed = 1.4, gap = 0.03, voices = 2 },
	open    = { id = "rbxassetid://9126283592", vol = 0.2, speed = 1.3, gap = 0.12, fallback = TICK, fbSpeed = 0.8 },
	close   = { id = "rbxassetid://9126283592", vol = 0.16, speed = 0.9, gap = 0.12, fallback = TICK, fbSpeed = 0.7 },
	coin    = { id = "rbxassetid://130378474223829", vol = 0.26, speed = 1, gap = 0.035, voices = 4,
		fallback = "rbxassetid://3299794881" },
	kaching = { id = "rbxassetid://101396758527961", vol = 0.42, speed = 1, gap = 0.2, maxLen = 2.2,
		fallback = "rbxassetid://9113728756" },
	pop     = { id = "rbxassetid://106984966606682", vol = 0.3, speed = 1, gap = 0.03, voices = 3, fallback = TICK },
	error   = { id = "rbxassetid://96795857757261", vol = 0.3, speed = 1.5, gap = 0.2, maxLen = 0.45,
		fallback = TICK, fbSpeed = 0.45 },
	thud    = { id = "rbxassetid://94978851787238", vol = 0.3, speed = 1.25, gap = 0.08, voices = 2, maxLen = 1.2,
		fallback = LAND, fbSpeed = 0.85 },
	poof    = { id = "rbxassetid://9126283592", vol = 0.28, speed = 0.6, gap = 0.08, voices = 2, fallback = TICK,
		fbSpeed = 0.5 },
	jackpot = { id = "rbxassetid://4879566787", vol = 0.45, speed = 1, gap = 1 },
	fanfare = { id = "rbxassetid://9045808575", vol = 0.4, speed = 1, gap = 0.5, fallback = "rbxassetid://4879566787" },
	jingle  = { id = "rbxassetid://9046296613", vol = 0.36, speed = 1, gap = 2, fallback = "rbxassetid://4879566787" },
}

local PALETTES = {
	show   = { C.Gold, C.GoldTop, C.Crimson, C.CrimsonTop, C.Cream, C.Pink, C.Blue, C.Green, C.Purple },
	money  = { C.Gold, C.GoldTop, C.GoldDeep, C.Green, C.GreenTop, C.Cream },
	ticket = { C.Pink, C.PinkTop, C.Purple, C.PurpleTop, C.Cream },
	night  = { C.Purple, C.PurpleTop, C.Pink, C.PinkTop, C.BlueTop },
}

local BANNER_STYLES = {
	gold    = { band = { C.CrimsonTop, C.CrimsonDeep }, title = { C.White, C.GoldTop }, rays = C.GoldTop, confetti = "show", sound = "fanfare" },
	crimson = { band = { C.GoldTop, C.GoldDeep }, title = { C.White, C.CrimsonTop }, rays = C.CrimsonTop, confetti = "show", sound = "fanfare" },
	purple  = { band = { C.PurpleTop, C.PurpleShadow }, title = { C.White, C.PinkTop }, rays = C.PinkTop, confetti = "night", sound = "jackpot" },
	green   = { band = { C.GreenTop, C.GreenShadow }, title = { C.White, C.GoldTop }, rays = C.GoldTop, confetti = "money", sound = "fanfare" },
	blue    = { band = { C.BlueTop, C.BlueShadow }, title = { C.White, C.GoldTop }, rays = C.BlueTop, confetti = "show", sound = "fanfare" },
}

------------------------------------------------------------------
-- state
------------------------------------------------------------------
local started = false
local deps = {}
local overlay: ScreenGui? = nil
local layer: Frame? = nil -- full-screen reference frame: every position below is in its pixels
local vignetteLayer, bannerLayer, confettiLayer, labelLayer, coinLayer, sparkLayer
local flashFrame: Frame? = nil
local vignette = {}

------------------------------------------------------------------
-- helpers
------------------------------------------------------------------
local function viewport(): Vector2
	local cam = Workspace.CurrentCamera
	return cam and cam.ViewportSize or Vector2.new(1280, 720)
end

-- the HUD's design scale (layouts are authored at 1280x720)
local function uiScale(): number
	local vp = viewport()
	return math.clamp(math.min(vp.X / 1280, vp.Y / 720), 0.5, 1.4)
end

local rmCache, rmChecked = false, -10
local function reducedMotion(): boolean
	local forced = UXFX.Settings.reducedMotion
	if forced ~= nil then return forced == true end
	local now = os.clock()
	if now - rmChecked > 2 then
		rmChecked = now
		local ok, v = pcall(function() return (GuiService :: any).ReducedMotionEnabled end)
		rmCache = ok and v == true
	end
	return rmCache
end

local function intensity(): number
	local k = tonumber(UXFX.Settings.intensity) or 1
	if UILib.IsTouch then k *= 0.65 end
	if reducedMotion() then k *= 0.5 end
	return k
end

local function backOut(x: number): number
	local c1 = 1.70158
	local u = x - 1
	return 1 + (c1 + 1) * u * u * u + c1 * u * u
end

-- a GuiObject's centre / an AbsolutePosition-space point, in layer pixels
local function centerOf(g: GuiObject): Vector2
	return g.AbsolutePosition + g.AbsoluteSize * 0.5 - (layer :: Frame).AbsolutePosition
end
local function absToLayer(p: Vector2): Vector2
	return p - (layer :: Frame).AbsolutePosition
end

-- world -> layer pixels. The overlay covers the whole viewport (no insets),
-- so viewport coordinates are layer coordinates. nil behind the camera.
local function project(pos: Vector3): (number?, number?)
	local cam = Workspace.CurrentCamera
	if not cam then return nil, nil end
	local v = cam:WorldToViewportPoint(pos)
	if v.Z <= 0 then return nil, nil end
	return v.X, v.Y
end

local function onScreen(x: number, y: number, margin: number?): boolean
	local vp = viewport()
	local m = margin or 0
	return x >= -m and y >= -m and x <= vp.X + m and y <= vp.Y + m
end

local function screenCenter(): Vector2
	local vp = viewport()
	return Vector2.new(vp.X * 0.5, vp.Y * 0.45)
end

-- the top of a machine model (where its "+$X" floats). Heights are cached for
-- a while (a model can still be streaming in when it's first measured).
local heights = setmetatable({}, { __mode = "k" }) -- model -> { h, t }
local function topOf(model: Instance?): Vector3?
	if not (model and model.Parent and model:IsA("Model")) then return nil end
	local ok, cf = pcall(model.GetPivot, model)
	if not ok then return nil end
	local now = os.clock()
	local rec = heights[model]
	if not rec or now - rec.t > 30 then
		local ok2, size = pcall(model.GetExtentsSize, model)
		rec = { h = (ok2 and size.Y > 0) and size.Y or 6, t = now }
		heights[model] = rec
	end
	local h = rec.h
	-- code-built machines pivot on the floor, the rest at their centre
	if model:GetAttribute("GroundPivot") then
		return cf.Position + Vector3.new(0, h + 0.6, 0)
	end
	return cf.Position + Vector3.new(0, h * 0.5 + 0.6, 0)
end

-- anything -> layer pixels: GuiObject (its centre), Vector2 (AbsolutePosition
-- space), Vector3 / BasePart / Model (world)
local function anchorToLayer(anchor): Vector2?
	local t = typeof(anchor)
	if t == "Instance" then
		if not anchor.Parent then return nil end
		if anchor:IsA("GuiObject") then return centerOf(anchor) end
		local pos = nil
		if anchor:IsA("BasePart") then
			pos = anchor.Position
		elseif anchor:IsA("Model") then
			pos = topOf(anchor)
		end
		if pos then
			local x, y = project(pos)
			if x then return Vector2.new(x, y) end
		end
		return nil
	elseif t == "Vector3" then
		local x, y = project(anchor)
		if x then return Vector2.new(x, y) end
		return nil
	elseif t == "Vector2" then
		return absToLayer(anchor)
	end
	return nil
end

------------------------------------------------------------------
-- sounds
------------------------------------------------------------------
local soundGroup: SoundGroup? = nil
local sounds = {}

local function buildSounds()
	local g = Instance.new("SoundGroup")
	g.Name = "UXFX"
	g.Volume = UXFX.MasterVolume
	g.Parent = SoundService
	soundGroup = g
	for name, spec in SOUNDS do
		local rec = { spec = spec, voices = {}, cursor = 0, last = -1, token = 0, failed = false }
		for i = 1, spec.voices or 1 do
			local s = Instance.new("Sound")
			s.Name = name
			s.SoundId = spec.id
			s.Volume = spec.vol
			s.PlaybackSpeed = spec.speed or 1
			s.SoundGroup = g
			s.Parent = g
			rec.voices[i] = s
		end
		sounds[name] = rec
	end
end

local function idKey(id: string): string
	return string.match(id, "(%d+)%s*$") or id
end

local function useFallback(rec)
	if rec.failed or not rec.spec.fallback then return end
	rec.failed = true
	for _, v in rec.voices do v.SoundId = rec.spec.fallback end
end

-- a primary sound that can't be fetched (moderated, private, offline) plays
-- its fallback instead
local function verifySounds()
	local list, byKey = {}, {}
	for _, rec in sounds do
		local spec = rec.spec
		if spec.fallback and string.find(spec.id, "rbxassetid://", 1, true) then
			table.insert(list, rec.voices[1])
			local k = idKey(spec.id)
			byKey[k] = byKey[k] or {}
			table.insert(byKey[k], rec)
		end
	end
	pcall(function()
		ContentProvider:PreloadAsync(list, function(contentId, status)
			if status == Enum.AssetFetchStatus.Failure then
				for _, rec in (byKey[idKey(tostring(contentId))] or {}) do useFallback(rec) end
			end
		end)
	end)
	-- belt and braces: whatever still hasn't loaded a while later falls back too
	task.wait(8)
	for _, rec in sounds do
		local v = rec.voices[1]
		if rec.spec.fallback and not rec.failed and v and not v.IsLoaded then useFallback(rec) end
	end
end

local function play(name: string, speed: number?, volume: number?)
	local rec = sounds[name]
	if not rec then return end
	local now = os.clock()
	local spec = rec.spec
	if now - rec.last < (spec.gap or 0.03) then return end
	rec.last = now
	rec.cursor = rec.cursor % #rec.voices + 1
	local s = rec.voices[rec.cursor]
	local spd = speed or spec.speed or 1
	if rec.failed and spec.fbSpeed then spd = spec.fbSpeed end
	pcall(function()
		s.PlaybackSpeed = spd
		s.Volume = spec.vol * (volume or 1)
		s.TimePosition = 0
		s:Play()
	end)
	if spec.maxLen then
		rec.token += 1
		local tok = rec.token
		task.delay(spec.maxLen, function()
			if rec.token == tok then pcall(function() s:Stop() end) end
		end)
	end
end

------------------------------------------------------------------
-- overlay: its own ScreenGui over the whole screen (above the HUD and the
-- panels, below the travel veil). Nothing in it takes input.
------------------------------------------------------------------
local function buildOverlay()
	local pg = player:WaitForChild("PlayerGui")
	local old = pg:FindFirstChild("CasinoUXFX")
	if old then old:Destroy() end
	local gui = Instance.new("ScreenGui")
	gui.Name = "CasinoUXFX"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 12
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	pcall(function() (gui :: any).ScreenInsets = Enum.ScreenInsets.None end)
	pcall(function() (gui :: any).ClipToDeviceSafeArea = false end)
	gui.Parent = pg
	overlay = gui
	local function sub(name: string, z: number): Frame
		local f = Instance.new("Frame")
		f.Name = name
		f.BackgroundTransparency = 1
		f.BorderSizePixel = 0
		f.Size = UDim2.fromScale(1, 1)
		f.ZIndex = z
		f.Parent = gui
		return f
	end
	layer = sub("Origin", 0)
	vignetteLayer = sub("Vignette", 1)
	flashFrame = sub("Flash", 2)
	bannerLayer = sub("Banner", 3)
	confettiLayer = sub("Confetti", 4)
	labelLayer = sub("Labels", 5)
	coinLayer = sub("Coins", 6)
	sparkLayer = sub("Sparks", 7)
	local fl = flashFrame :: Frame
	fl.BackgroundColor3 = C.White

	-- vignette: four edge strips fading inward (no texture needed)
	local fade = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(0.55, 0.62), NumberSequenceKeypoint.new(1, 1),
	})
	local function strip(name: string, pos: UDim2, size: UDim2, rot: number)
		local f = Instance.new("Frame")
		f.Name = name
		f.BackgroundColor3 = C.Purple
		f.BackgroundTransparency = 1
		f.BorderSizePixel = 0
		f.Position = pos
		f.Size = size
		f.Parent = vignetteLayer
		local g = Instance.new("UIGradient")
		g.Rotation = rot
		g.Transparency = fade
		g.Parent = f
		table.insert(vignette, f)
	end
	strip("Left", UDim2.fromScale(0, 0), UDim2.fromScale(0.2, 1), 0)
	strip("Right", UDim2.fromScale(0.8, 0), UDim2.fromScale(0.2, 1), 180)
	strip("Top", UDim2.fromScale(0, 0), UDim2.fromScale(1, 0.26), 90)
	strip("Bottom", UDim2.fromScale(0, 0.74), UDim2.fromScale(1, 0.26), 270)
end

------------------------------------------------------------------
-- pools + the frame loop (one RenderStepped while anything moves)
------------------------------------------------------------------
local function newPool(max: number, make)
	return { free = {}, made = 0, max = max, make = make }
end
local function take(p)
	local n = #p.free
	if n > 0 then
		local r = p.free[n]
		p.free[n] = nil
		return r
	end
	if p.made >= p.max then return nil end
	p.made += 1
	return p.make(p.made)
end
local function give(p, r)
	table.insert(p.free, r)
end
-- swap-remove (lists are walked backwards, so the swapped-in entry is done)
local function drop(list, i: number)
	local n = #list
	list[i] = list[n]
	list[n] = nil
end

local coinPool = newPool(MAX_COINS, function()
	local img = Instance.new("ImageLabel")
	img.Name = "Coin"
	img.BackgroundTransparency = 1
	img.Image = UILib.Icons.coin
	img.ScaleType = Enum.ScaleType.Fit
	img.AnchorPoint = Vector2.new(0.5, 0.5)
	img.Visible = false
	img.Parent = coinLayer
	return { gui = img }
end)

local confettiPool = newPool(MAX_CONFETTI, function(i: number)
	local f = Instance.new("Frame")
	f.Name = "Confetti"
	f.BorderSizePixel = 0
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Visible = false
	local round = i % 3 == 0
	local c = Instance.new("UICorner")
	c.CornerRadius = round and UDim.new(0.5, 0) or UDim.new(0, 2)
	c.Parent = f
	f.Parent = confettiLayer
	return { gui = f, round = round }
end)

local sparkPool = newPool(MAX_SPARKS, function()
	local img = Instance.new("ImageLabel")
	img.Name = "Spark"
	img.BackgroundTransparency = 1
	img.Image = UILib.Icons.star
	img.ScaleType = Enum.ScaleType.Fit
	img.AnchorPoint = Vector2.new(0.5, 0.5)
	img.Visible = false
	img.Parent = sparkLayer
	return { gui = img }
end)

local ringPool = newPool(MAX_RINGS, function()
	local f = Instance.new("Frame")
	f.Name = "Ring"
	f.BackgroundTransparency = 1
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Visible = false
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0.5, 0)
	c.Parent = f
	local st = Instance.new("UIStroke")
	st.Color = C.GoldTop
	st.Thickness = 4
	st.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	st.Parent = f
	f.Parent = sparkLayer
	return { gui = f, stroke = st }
end)

local labelPool = newPool(MAX_LABELS, function()
	local face, holder = UILib.text(labelLayer, {
		name = "Pop", text = "", font = F.Number, size = 30, stroke = 3, shadow = 3,
		frameSize = UDim2.fromOffset(600, 60), anchor = Vector2.new(0.5, 0.5),
	})
	holder.Visible = false
	local sc = Instance.new("UIScale")
	sc.Parent = holder
	local strokes = {}
	for _, d in holder:GetDescendants() do
		if d:IsA("UIStroke") then table.insert(strokes, d) end
	end
	return { holder = holder, face = face, scale = sc, strokes = strokes }
end)

local coins, confetti, sparks, rings, labels = {}, {}, {}, {}, {}
local shaking = {}  -- gui -> { t, base, amp }
local steppers = {} -- fn(dt) -> false to stop (banner, ...)
local stepConn: RBXScriptConnection? = nil
local step

local function wake()
	if not stepConn then stepConn = RunService.RenderStepped:Connect(step) end
end

-- coins from `from` into `to` (layer px): a short burst outward, then an
-- arc that speeds into the target. onLand(i) per arrival. Returns how many flew.
local function flyCoins(from: Vector2, to: Vector2?, n: number, burst: number, onLand, endScale: number?): number
	local s = uiScale()
	local count = 0
	for i = 1, n do
		local r = take(coinPool)
		if not r then break end
		count += 1
		local ang = math.random() * math.pi * 2
		local rad = (14 + math.random() * burst) * s
		r.s = s
		r.x0, r.y0 = from.X, from.Y
		r.x1 = from.X + math.cos(ang) * rad
		r.y1 = from.Y + math.sin(ang) * rad * 0.8 - 12 * s
		if to then
			r.x2, r.y2 = to.X, to.Y
			-- the control point sits off to one side so each coin arcs in its own way
			local dx, dy = to.X - r.x1, to.Y - r.y1
			local side = (math.random() - 0.5) * 0.7
			r.cx = (r.x1 + to.X) * 0.5 - dy * side
			r.cy = (r.y1 + to.Y) * 0.5 + dx * side - 50 * s
		else
			r.x2, r.y2 = nil, nil
		end
		r.t = -(i - 1) * 0.035
		r.tb = 0.15 + math.random() * 0.07
		r.tf = 0.4 + math.random() * 0.18
		r.size = (30 + math.random() * 10) * s
		r.endScale = endScale or 0.62
		r.rot = math.random() * 360
		r.vr = (math.random() - 0.5) * 600
		r.onLand = onLand
		r.index = i
		r.gui.ImageTransparency = 0
		r.gui.Visible = false
		table.insert(coins, r)
	end
	if count > 0 then wake() end
	return count
end

local function confettiBurst(at: Vector2, n: number, palette, dirDeg: number?, spreadDeg: number?, speedMul: number?)
	n = math.floor(n * intensity() + 0.5)
	if n <= 0 then return end
	palette = palette or PALETTES.show
	local s = uiScale()
	local dir = math.rad(dirDeg or -90)
	local spread = math.rad(spreadDeg or 70)
	local spawned = 0
	for _ = 1, n do
		local r = take(confettiPool)
		if not r then break end
		spawned += 1
		local a = dir + (math.random() * 2 - 1) * spread
		local sp = (700 + math.random() * 600) * s * (speedMul or 1)
		r.x, r.y = at.X, at.Y
		r.vx, r.vy = math.cos(a) * sp, math.sin(a) * sp
		r.g = 650 * s
		r.rot = math.random() * 360
		r.vr = (math.random() - 0.5) * 900
		r.flip = math.random() * 6.28
		r.vf = 7 + math.random() * 8
		r.life = 1.6 + math.random() * 0.6
		r.w = (r.round and 9 or (8 + math.random() * 5)) * s
		r.h = (r.round and 9 or (12 + math.random() * 7)) * s
		local g = r.gui
		g.BackgroundColor3 = palette[math.random(1, #palette)]
		g.BackgroundTransparency = 0
		g.Size = UDim2.fromOffset(r.w, r.h)
		g.Position = UDim2.fromOffset(r.x, r.y)
		g.Visible = true
		table.insert(confetti, r)
	end
	if spawned > 0 then wake() end
end

-- little gold stars that twinkle around a point
local function sparkle(at: Vector2, n: number, spread: number, color: Color3?)
	local s = uiScale()
	local spawned = 0
	for i = 1, n do
		local r = take(sparkPool)
		if not r then break end
		spawned += 1
		r.x = at.X + (math.random() * 2 - 1) * spread
		r.y = at.Y + (math.random() * 2 - 1) * spread * 0.7
		r.t = -(i - 1) * 0.045
		r.dur = 0.45 + math.random() * 0.25
		r.size = (16 + math.random() * 16) * s
		r.rot = math.random() * 360
		r.vr = (math.random() - 0.5) * 260
		r.rise = (10 + math.random() * 16) * s
		r.gui.ImageColor3 = color or C.White
		r.gui.Visible = false
		table.insert(sparks, r)
	end
	if spawned > 0 then wake() end
end

-- an expanding gold ring (a "glint")
local function ring(at: Vector2, r0: number, r1: number, dur: number, color: Color3?, thickness: number?)
	local r = take(ringPool)
	if not r then return end
	r.t = 0
	r.dur = dur
	r.r0, r.r1 = r0, r1
	r.th = thickness or 5
	r.stroke.Color = color or C.GoldTop
	r.stroke.Transparency = 0
	r.gui.Position = UDim2.fromOffset(at.X, at.Y)
	r.gui.Size = UDim2.fromOffset(r0, r0)
	r.gui.Visible = false
	table.insert(rings, r)
	wake()
end

-- "+$X" text that pops in and rises: over a world point (follows it as the
-- camera moves) or at fixed layer px when `pos` is nil
local function worldLabel(pos: Vector3?, text: string, color: Color3, size: number, dur: number?, x: number?, y: number?)
	local r = take(labelPool)
	if not r then return end
	local s = uiScale()
	r.world = pos
	r.x, r.y = x or 0, y or 0
	r.t = 0
	r.dur = dur or 1.15
	r.rise = 50 * s
	local face = r.face
	face.Text = text
	face.TextColor3 = color
	face.TextSize = math.floor(size * s + 0.5)
	face.TextTransparency = 0
	for _, st in r.strokes do
		st.Transparency = 0
		st.Thickness = math.max(1.5, 3.2 * s)
	end
	r.holder.Size = UDim2.fromOffset(640 * s, (size + 16) * s)
	r.scale.Scale = 0.3
	r.holder.Visible = false
	table.insert(labels, r)
	wake()
end

local function stepBody(dt: number)
	local vpY = viewport().Y

	for i = #coins, 1, -1 do
		local r = coins[i]
		r.t += dt
		local t = r.t
		if t >= 0 then
			local g = r.gui
			local x, y, sc = 0, 0, 1
			local landed, gone = false, false
			if t < r.tb then
				local a = t / r.tb
				local e = 1 - (1 - a) * (1 - a)
				x = r.x0 + (r.x1 - r.x0) * e
				y = r.y0 + (r.y1 - r.y0) * e
				sc = 0.45 + 0.55 * e
			elseif r.x2 then
				local a = (t - r.tb) / r.tf
				if a >= 1 then
					a = 1
					landed = true
				end
				local e = a * a -- speeds up: sucked into the counter
				local u = 1 - e
				x = u * u * r.x1 + 2 * u * e * r.cx + e * e * r.x2
				y = u * u * r.y1 + 2 * u * e * r.cy + e * e * r.y2
				sc = 1 - (1 - r.endScale) * e
			else
				local a = (t - r.tb) / 0.45
				if a >= 1 then
					a = 1
					gone = true
				end
				x, y = r.x1, r.y1 - 18 * a * r.s
				g.ImageTransparency = a
			end
			if landed or gone then
				g.Visible = false
				g.ImageTransparency = 0
				drop(coins, i)
				give(coinPool, r)
				local f, idx = r.onLand, r.index
				r.onLand = nil
				if landed and f then f(idx) end
			else
				r.rot += r.vr * dt
				local px = r.size * sc
				g.Position = UDim2.fromOffset(x, y)
				g.Size = UDim2.fromOffset(px, px)
				g.Rotation = r.rot
				if not g.Visible then g.Visible = true end
			end
		end
	end

	for i = #confetti, 1, -1 do
		local r = confetti[i]
		r.life -= dt
		if r.life <= 0 or r.y > vpY + 60 then
			r.gui.Visible = false
			drop(confetti, i)
			give(confettiPool, r)
		else
			r.vx -= r.vx * math.min(1, 2.2 * dt)
			r.vy += r.g * dt - r.vy * math.min(1, 2.8 * dt)
			r.x += r.vx * dt
			r.y += r.vy * dt
			r.rot += r.vr * dt
			r.flip += r.vf * dt
			local g = r.gui
			g.Position = UDim2.fromOffset(r.x, r.y)
			g.Rotation = r.rot
			if not r.round then
				-- the width breathes like a tumbling paper strip
				g.Size = UDim2.fromOffset(math.max(1, r.w * math.abs(math.cos(r.flip))), r.h)
			end
			if r.life < 0.45 then g.BackgroundTransparency = 1 - r.life / 0.45 end
		end
	end

	for i = #sparks, 1, -1 do
		local r = sparks[i]
		r.t += dt
		if r.t >= 0 then
			local a = r.t / r.dur
			local g = r.gui
			if a >= 1 then
				g.Visible = false
				drop(sparks, i)
				give(sparkPool, r)
			else
				local px = r.size * math.sin(a * math.pi)
				g.Size = UDim2.fromOffset(px, px)
				g.Rotation = r.rot + r.vr * r.t
				g.Position = UDim2.fromOffset(r.x, r.y - r.rise * a)
				if not g.Visible then g.Visible = true end
			end
		end
	end

	for i = #rings, 1, -1 do
		local r = rings[i]
		r.t += dt
		local a = r.t / r.dur
		if a >= 1 then
			r.gui.Visible = false
			drop(rings, i)
			give(ringPool, r)
		else
			local e = 1 - (1 - a) * (1 - a)
			local d = r.r0 + (r.r1 - r.r0) * e
			r.gui.Size = UDim2.fromOffset(d, d)
			r.stroke.Transparency = a
			r.stroke.Thickness = math.max(1, r.th * (1 - a))
			if not r.gui.Visible then r.gui.Visible = true end
		end
	end

	for i = #labels, 1, -1 do
		local r = labels[i]
		r.t += dt
		local a = r.t / r.dur
		if a >= 1 then
			r.holder.Visible = false
			drop(labels, i)
			give(labelPool, r)
		else
			local x, y = r.x, r.y
			if r.world then x, y = project(r.world) end
			if x then
				local rise = r.rise * (1 - (1 - a) * (1 - a))
				r.holder.Position = UDim2.fromOffset(x, y - rise)
				local pa = r.t / 0.26
				r.scale.Scale = pa < 1 and (0.3 + 0.7 * backOut(pa)) or 1
				if a > 0.72 then
					local f = (a - 0.72) / 0.28
					r.face.TextTransparency = f
					for _, st in r.strokes do st.Transparency = f end
				end
				if not r.holder.Visible then r.holder.Visible = true end
			elseif r.holder.Visible then
				r.holder.Visible = false
			end
		end
	end

	for gui, sh in shaking do
		sh.t += dt
		local a = sh.t / 0.36
		if a >= 1 or not gui.Parent then
			if gui.Parent then gui.Rotation = sh.base end
			shaking[gui] = nil
		else
			gui.Rotation = sh.base + sh.amp * (1 - a) * math.sin(sh.t * 52)
		end
	end

	for fn in steppers do
		local ok, keep = pcall(fn, dt)
		if not ok or keep == false then steppers[fn] = nil end
	end
end

local stepWarned = false
-- throw everything back into the pools (after an error, so it can't repeat every frame)
local function clearAll()
	for _, r in coins do r.gui.Visible = false; r.onLand = nil; give(coinPool, r) end
	for _, r in confetti do r.gui.Visible = false; give(confettiPool, r) end
	for _, r in sparks do r.gui.Visible = false; give(sparkPool, r) end
	for _, r in rings do r.gui.Visible = false; give(ringPool, r) end
	for _, r in labels do r.holder.Visible = false; give(labelPool, r) end
	table.clear(coins); table.clear(confetti); table.clear(sparks); table.clear(rings); table.clear(labels)
	table.clear(shaking)
end

step = function(dt: number)
	if dt > 0.1 then dt = 0.1 end
	local ok, err = pcall(stepBody, dt)
	if not ok then
		if not stepWarned then
			stepWarned = true
			warn("[UXFX] frame: " .. tostring(err))
		end
		pcall(clearAll)
	end
	if #coins == 0 and #confetti == 0 and #sparks == 0 and #rings == 0 and #labels == 0
		and next(shaking) == nil and next(steppers) == nil and stepConn then
		stepConn:Disconnect()
		stepConn = nil
	end
end

------------------------------------------------------------------
-- small effects
------------------------------------------------------------------
local function popScaleOf(gui: Instance): UIScale?
	for _, ch in gui:GetChildren() do
		if ch:IsA("UIScale") then
			if ch.Name == "AutoScale" then return nil end -- viewport scaling: hands off
			return ch
		end
	end
	local sc = Instance.new("UIScale")
	sc.Name = "UXFXPop"
	sc.Parent = gui
	return sc
end

-- the glossy buttons' hitbox is a "Click" TextButton: act on the button itself
local function buttonRoot(gui: Instance): Instance
	if gui:IsA("GuiButton") and gui.Name == "Click" and gui.Parent and gui.Parent:IsA("GuiObject") then
		return gui.Parent
	end
	return gui
end

function UXFX.pop(gui, scale: number?)
	if not started or typeof(gui) ~= "Instance" or not gui:IsA("GuiObject") or not gui.Parent then return end
	local target = buttonRoot(gui)
	local sc = popScaleOf(target)
	if not sc then return end
	sc.Scale = scale or 1.15
	UILib.tween(sc, { Scale = 1 }, 0.38, Enum.EasingStyle.Back)
end

function UXFX.shake(gui, strength: number?)
	if not started or typeof(gui) ~= "Instance" or not gui:IsA("GuiObject") or not gui.Parent then return end
	if reducedMotion() then return end
	local target = buttonRoot(gui) :: GuiObject
	local sh = shaking[target]
	if sh then
		sh.t = 0
		return
	end
	shaking[target] = { t = 0, base = target.Rotation, amp = 7 * (strength or 1) }
	wake()
end

function UXFX.flash(color: Color3?, strength: number?)
	if not started or not flashFrame then return end
	local k = math.clamp(strength or 1, 0, 1) * (reducedMotion() and 0.35 or 1)
	local f = flashFrame :: Frame
	f.BackgroundColor3 = typeof(color) == "Color3" and color or C.White
	f.BackgroundTransparency = 1 - 0.5 * k
	UILib.tween(f, { BackgroundTransparency = 1 }, 0.4, Enum.EasingStyle.Quad)
end

local vignetteToken = 0
function UXFX.vignette(color: Color3?, pulses: number?)
	if not started then return end
	local rm = reducedMotion()
	local peak = rm and 0.55 or 0.2
	local n = rm and 1 or math.clamp(pulses or 2, 1, 4)
	vignetteToken += 1
	local tok = vignetteToken
	for _, f in vignette do f.BackgroundColor3 = typeof(color) == "Color3" and color or C.Purple end
	task.spawn(function()
		for i = 1, n do
			if tok ~= vignetteToken then return end
			for _, f in vignette do UILib.tween(f, { BackgroundTransparency = peak }, 0.32, Enum.EasingStyle.Sine) end
			task.wait(0.34)
			if tok ~= vignetteToken then return end
			local last = i == n
			for _, f in vignette do
				UILib.tween(f, { BackgroundTransparency = last and 1 or 0.6 }, last and 0.9 or 0.3, Enum.EasingStyle.Sine)
			end
			task.wait(last and 0.9 or 0.32)
		end
	end)
end

-- Camera FOV punch, additive: the offset goes on after the camera scripts
-- (render step Camera+1) and comes off again before anything else runs
-- (Stepped, before Sprint's Heartbeat FOV lerp), so it never drifts the
-- player's own field of view.
local PUNCH_IN, PUNCH_OUT = 0.06, 0.34
local punch = { t = 0, mag = 0, applied = 0, cam = nil, bound = false, conn = nil }
local function punchRender(dt: number)
	punch.t += dt
	local t = punch.t
	local k = 0
	if t < PUNCH_IN then
		k = t / PUNCH_IN
	elseif t < PUNCH_IN + PUNCH_OUT then
		local a = (t - PUNCH_IN) / PUNCH_OUT
		k = (1 - a) * (1 - a)
	end
	local cam = Workspace.CurrentCamera
	if cam and k > 0 then
		local off = -punch.mag * k
		cam.FieldOfView += off
		punch.applied += off
		punch.cam = cam
	end
	if t >= PUNCH_IN + PUNCH_OUT then
		punch.bound = false
		pcall(function() RunService:UnbindFromRenderStep("UXFXPunch") end)
	end
end
local function punchRemove()
	if punch.applied ~= 0 then
		local cam = punch.cam
		if cam then pcall(function() cam.FieldOfView -= punch.applied end) end
		punch.applied = 0
	end
	if not punch.bound and punch.conn then
		punch.conn:Disconnect()
		punch.conn = nil
	end
end
function UXFX.punch(strength: number?)
	if not started or reducedMotion() then return end
	punch.t = 0
	punch.mag = math.clamp(4 * (strength or 1), 0, 10)
	if not punch.conn then punch.conn = RunService.Stepped:Connect(punchRemove) end
	if not punch.bound then
		punch.bound = true
		local ok = pcall(function()
			RunService:BindToRenderStep("UXFXPunch", Enum.RenderPriority.Camera.Value + 1, punchRender)
		end)
		if not ok then punch.bound = false end
	end
end

------------------------------------------------------------------
-- banner: crimson velvet band with chasing bulbs, gold title, cream
-- subtitle pill, spinning rays; queued, one at a time
------------------------------------------------------------------
local banner = nil
local bannerQueue = {}
local bannerBusy = false

local function buildBanner()
	local root = UILib.make("Frame", {
		Name = "Banner", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.36), Size = UDim2.fromOffset(1000, 320), Visible = false, Parent = bannerLayer,
	})
	local scale = UILib.make("UIScale", { Scale = 0.01, Parent = root })
	local rays = UILib.image(root, UILib.Tex.sunburst, {
		size = UDim2.fromOffset(640, 640), anchor = Vector2.new(0.5, 0.5), position = UDim2.fromScale(0.5, 0.4),
		color = C.GoldTop, transparency = 0.5,
	})
	UILib.image(root, UILib.Tex.glow, {
		size = UDim2.fromOffset(780, 330), anchor = Vector2.new(0.5, 0.5), position = UDim2.fromScale(0.5, 0.4),
		transparency = 0.2,
	})
	local shadow = UILib.make("Frame", {
		Name = "BandShadow", BackgroundColor3 = C.Ink, AnchorPoint = Vector2.new(0.5, 0.5), BorderSizePixel = 0,
		Position = UDim2.new(0.5, 0, 0.4, 10), Size = UDim2.fromOffset(600, 112), Parent = root,
	})
	UILib.corner(shadow, 28)
	local band = UILib.make("Frame", {
		Name = "Band", BackgroundColor3 = C.White, AnchorPoint = Vector2.new(0.5, 0.5), BorderSizePixel = 0,
		Position = UDim2.fromScale(0.5, 0.4), Size = UDim2.fromOffset(600, 112), Parent = root,
	})
	UILib.corner(band, 28)
	local bandGrad = UILib.gradient(band, C.CrimsonTop, C.CrimsonDeep)
	UILib.stroke(band, C.Ink, 5, true)
	local trim = UILib.make("Frame", {
		Name = "Trim", BackgroundTransparency = 1, Position = UDim2.fromOffset(9, 9), Size = UDim2.new(1, -18, 1, -18),
		Parent = band,
	})
	UILib.corner(trim, 20)
	UILib.stroke(trim, C.GoldTop, 2.5, true, 0.1)
	local bulbs = {}
	for i = 1, 64 do
		local b = UILib.make("Frame", {
			Name = "Bulb", AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(9, 9), BorderSizePixel = 0,
			BackgroundColor3 = C.GoldTop, Visible = false, Parent = band,
		})
		UILib.corner(b, 999)
		bulbs[i] = b
	end
	local title = UILib.text(band, {
		name = "Title", text = "", size = 62, autoX = true, frameSize = UDim2.fromScale(0, 1),
		anchor = Vector2.new(0.5, 0.5), position = UDim2.fromScale(0.5, 0.5), stroke = 6, shadow = 6,
		gradient = { C.White, C.GoldTop },
	})
	local sub = UILib.make("Frame", {
		Name = "Sub", BackgroundColor3 = C.Cream, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0.4, 70),
		Size = UDim2.fromOffset(0, 46), AutomaticSize = Enum.AutomaticSize.X, Parent = root,
	})
	UILib.corner(sub, 999)
	UILib.stroke(sub, C.Ink, 3.5, true)
	UILib.pad(sub, 24, 0, 24, 0)
	local subText = UILib.body(sub, {
		name = "Text", text = "", font = F.Display, size = 24, color = C.Crimson, autoX = true,
		frameSize = UDim2.fromScale(0, 1), xAlign = Enum.TextXAlignment.Center,
	})
	banner = {
		root = root, scale = scale, rays = rays, band = band, shadow = shadow, bandGrad = bandGrad, bulbs = bulbs,
		title = title, titleGrad = title:FindFirstChildOfClass("UIGradient"), sub = sub, subText = subText,
		nBulbs = 0, phase = 0, bulbT = 0,
	}
end

local function layoutBulbs(W: number, H: number)
	local b = banner
	local n = 0
	for x = 24, W - 24, 32 do
		for _, y in { 6, H - 6 } do
			n += 1
			local bulb = b.bulbs[n]
			if not bulb then break end
			bulb.Position = UDim2.fromOffset(x, y)
			bulb.Visible = true
		end
	end
	n = math.min(n, #b.bulbs)
	for i = n + 1, #b.bulbs do b.bulbs[i].Visible = false end
	b.nBulbs = n
end

local function bannerStep(dt: number)
	local b = banner
	if not (b and b.root.Visible) then return false end
	b.rays.Rotation = (b.rays.Rotation + 24 * dt) % 360
	b.bulbT += dt
	if b.bulbT >= 0.12 then
		b.bulbT = 0
		b.phase = 1 - b.phase
		for i = 1, b.nBulbs do
			b.bulbs[i].BackgroundColor3 = ((i + b.phase) % 2 == 0) and C.GoldTop or C.GoldDeep
		end
	end
	return true
end

local showBanner
local function nextBanner()
	bannerBusy = false
	local item = table.remove(bannerQueue, 1)
	if item then
		local ok, err = pcall(showBanner, item)
		if not ok then
			bannerBusy = false
			warn("[UXFX] banner: " .. tostring(err))
		end
	end
end

showBanner = function(item)
	bannerBusy = true
	if not banner then buildBanner() end
	local b = banner
	local st = BANNER_STYLES[item.style] or BANNER_STYLES.gold
	local size = 62
	local tw = TextService:GetTextSize(item.title, size, F.Display, Vector2.new(5000, 400)).X
	if tw > 880 then
		size = math.max(30, math.floor(size * 880 / tw))
		tw = TextService:GetTextSize(item.title, size, F.Display, Vector2.new(5000, 400)).X
	end
	b.title.TextSize = size
	b.title.Text = item.title
	local W, H = math.max(380, tw + 150), 112
	b.band.Size = UDim2.fromOffset(W, H)
	b.shadow.Size = UDim2.fromOffset(W, H)
	layoutBulbs(W, H)
	b.bandGrad.Color = ColorSequence.new(st.band[1], st.band[2])
	if b.titleGrad then b.titleGrad.Color = ColorSequence.new(st.title[1], st.title[2]) end
	b.rays.ImageColor3 = st.rays
	local hasSub = type(item.subtitle) == "string" and item.subtitle ~= ""
	b.sub.Visible = hasSub
	b.subText.Text = hasSub and item.subtitle or ""
	b.root.Visible = true
	b.root.Rotation = -5
	b.scale.Scale = 0.2
	local s = uiScale()
	UILib.tween(b.scale, { Scale = s }, 0.45, Enum.EasingStyle.Back)
	UILib.tween(b.root, { Rotation = 0 }, 0.45, Enum.EasingStyle.Back)
	play(type(item.sound) == "string" and item.sound or st.sound)
	local vp = viewport()
	local pal = PALETTES[st.confetti] or PALETTES.show
	confettiBurst(Vector2.new(0, vp.Y * 0.62), 26, pal, -55, 22, 1.25)
	confettiBurst(Vector2.new(vp.X, vp.Y * 0.62), 26, pal, -125, 22, 1.25)
	ring(Vector2.new(vp.X * 0.5, vp.Y * 0.36), 60 * s, 560 * s, 0.6, st.rays, 8 * s)
	steppers[bannerStep] = true
	wake()
	task.delay(2.1, function()
		UILib.tween(b.scale, { Scale = 0.01 }, 0.22, Enum.EasingStyle.Back, Enum.EasingDirection.In)
		task.delay(0.24, function()
			b.root.Visible = false
			steppers[bannerStep] = nil
			nextBanner()
		end)
	end)
end

function UXFX.banner(title: string, subtitle: string?, style: string?, sound: string?)
	if not started or type(title) ~= "string" or title == "" then return end
	local item = { title = title, subtitle = subtitle, style = style, sound = sound }
	if bannerBusy then
		if #bannerQueue < 3 then table.insert(bannerQueue, item) end
		return
	end
	local ok, err = pcall(showBanner, item)
	if not ok then
		bannerBusy = false
		warn("[UXFX] banner: " .. tostring(err))
	end
end

------------------------------------------------------------------
-- world effects: three hidden client-only anchor parts with shared emitters
-- (particles live in world space, so an anchor can move on right after)
------------------------------------------------------------------
local world = nil

local function emitterOn(parent: Instance, props): ParticleEmitter
	local e = Instance.new("ParticleEmitter")
	e.Enabled = false
	for k, v in props do
		pcall(function() (e :: any)[k] = v end)
	end
	e.Parent = parent
	return e
end

local function anchorPart(name: string, folder: Instance): BasePart
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Transparency = 1
	p.Size = Vector3.new(0.2, 0.2, 0.2)
	p.CFrame = CFrame.new(0, -400, 0)
	p.Parent = folder
	return p
end

local function buildWorld()
	if world and world.folder.Parent then return world end
	local folder = Instance.new("Folder")
	folder.Name = "UXFXLocal"
	folder.Parent = Workspace
	local w = { folder = folder }
	w.dustPart = anchorPart("Dust", folder)
	w.ringPart = anchorPart("Ring", folder)
	w.burstPart = anchorPart("Burst", folder)
	w.dust = emitterOn(w.dustPart, {
		Texture = "rbxasset://textures/particles/smoke_main.dds",
		Color = ColorSequence.new(C.Cream, C.CreamLine),
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.3), NumberSequenceKeypoint.new(0.6, 0.6), NumberSequenceKeypoint.new(1, 1),
		}),
		Size = NumberSequence.new(1.1, 3.2),
		Lifetime = NumberRange.new(0.45, 0.8),
		Speed = NumberRange.new(9, 14),
		Drag = 6,
		Acceleration = Vector3.new(0, 2.5, 0),
		Rotation = NumberRange.new(0, 360),
		RotSpeed = NumberRange.new(-90, 90),
		EmissionDirection = Enum.NormalId.Front,
		SpreadAngle = Vector2.new(8, 8),
		LightInfluence = 0.5,
		LightEmission = 0.1,
		ZOffset = 0.4,
	})
	w.ring = emitterOn(w.ringPart, {
		Texture = "rbxasset://textures/particles/explosion01_shockwave_main.dds",
		Color = ColorSequence.new(C.GoldTop),
		Transparency = NumberSequence.new(0.15, 1),
		Size = NumberSequence.new(0.6, 6),
		Lifetime = NumberRange.new(0.42),
		Speed = NumberRange.new(0.01),
		EmissionDirection = Enum.NormalId.Top,
		Orientation = Enum.ParticleOrientation.VelocityPerpendicular,
		SpreadAngle = Vector2.new(0, 0),
		LightEmission = 0.7,
		LightInfluence = 0,
		ZOffset = 0.2,
	})
	w.coins = emitterOn(w.burstPart, {
		Texture = UILib.Icons.coin,
		Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.9), NumberSequenceKeypoint.new(0.85, 1.05), NumberSequenceKeypoint.new(1, 0),
		}),
		Lifetime = NumberRange.new(1, 1.5),
		Speed = NumberRange.new(20, 30),
		SpreadAngle = Vector2.new(28, 28),
		EmissionDirection = Enum.NormalId.Top,
		Acceleration = Vector3.new(0, -62, 0),
		Drag = 0.5,
		Rotation = NumberRange.new(0, 360),
		RotSpeed = NumberRange.new(-260, 260),
		LightEmission = 0.2,
		LightInfluence = 0,
	})
	w.sparks = emitterOn(w.burstPart, {
		Texture = "rbxasset://textures/particles/sparkles_main.dds",
		Color = ColorSequence.new(C.GoldTop, C.Gold),
		Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.3), NumberSequenceKeypoint.new(0.4, 1), NumberSequenceKeypoint.new(1, 0),
		}),
		Lifetime = NumberRange.new(0.5, 0.9),
		Speed = NumberRange.new(5, 11),
		SpreadAngle = Vector2.new(180, 180),
		Drag = 2.5,
		Rotation = NumberRange.new(0, 360),
		RotSpeed = NumberRange.new(-180, 180),
		LightEmission = 1,
		LightInfluence = 0,
	})
	w.smoke = emitterOn(w.burstPart, {
		Texture = "rbxasset://textures/particles/smoke_main.dds",
		Color = ColorSequence.new(C.White, C.CreamRow),
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.15), NumberSequenceKeypoint.new(0.5, 0.45), NumberSequenceKeypoint.new(1, 1),
		}),
		Size = NumberSequence.new(2, 5.5),
		Lifetime = NumberRange.new(0.5, 0.9),
		Speed = NumberRange.new(5, 9),
		SpreadAngle = Vector2.new(180, 180),
		Drag = 4,
		Acceleration = Vector3.new(0, 3, 0),
		Rotation = NumberRange.new(0, 360),
		RotSpeed = NumberRange.new(-60, 60),
		LightInfluence = 0.4,
		LightEmission = 0.15,
	})
	local light = Instance.new("PointLight")
	light.Brightness = 0
	light.Range = 22
	light.Color = C.GoldTop
	light.Shadows = false
	light.Parent = w.burstPart
	w.light = light
	world = w
	return w
end

-- a machine lands: thud, dust pushed out along the floor, a gold ring
local function impact(pos: Vector3, radius: number?)
	play("thud")
	local w = buildWorld()
	local r = math.clamp(radius or 2.5, 1.5, 7)
	local n = math.max(6, math.floor(10 * math.min(1, intensity() + 0.3)))
	local base = math.random() * math.pi * 2
	for i = 1, n do
		local yaw = base + i * (math.pi * 2 / n)
		w.dustPart.CFrame = CFrame.new(pos) * CFrame.Angles(0, yaw, 0) * CFrame.new(0, 0.45, -r * 0.8)
			* CFrame.Angles(math.rad(10), 0, 0)
		w.dust:Emit(1)
	end
	w.ring.Size = NumberSequence.new(r * 0.6, r * 3.2)
	w.ringPart.CFrame = CFrame.new(pos + Vector3.new(0, 0.12, 0))
	w.ring:Emit(1)
	w.burstPart.CFrame = CFrame.new(pos + Vector3.new(0, 1.2, 0))
	w.sparks:Emit(8)
	local cam = Workspace.CurrentCamera
	if cam and (cam.CFrame.Position - pos).Magnitude < 70 then UXFX.punch(0.35) end
end

function UXFX.puff(pos: Vector3, radius: number?)
	if not started or typeof(pos) ~= "Vector3" then return end
	local w = buildWorld()
	local r = math.clamp(radius or 2.5, 1.5, 7)
	w.burstPart.CFrame = CFrame.new(pos + Vector3.new(0, 1.2 + r * 0.25, 0))
	w.smoke:Emit(math.max(5, math.floor(12 * math.min(1, intensity() + 0.2))))
	w.sparks:Emit(12)
	play("poof")
	play("pop", 0.8)
end

-- a guest's big win on one of your machines
local function jackpotWorld(pos: Vector3, model: Instance?, big: boolean)
	local w = buildWorld()
	local mfx = deps.MachineFX
	if model and mfx and type(mfx.flash) == "function" then pcall(mfx.flash, model, big and 4 or 2.5) end
	w.burstPart.CFrame = CFrame.new(pos)
	w.sparks:Emit(big and 26 or 14)
	w.light.Brightness = big and 8 or 5
	UILib.tween(w.light, { Brightness = 0 }, big and 1.3 or 0.9, Enum.EasingStyle.Quad)
	local batches = big and 5 or 3
	task.spawn(function()
		for _ = 1, batches do
			if not w.burstPart.Parent then return end
			w.burstPart.CFrame = CFrame.new(pos)
			w.coins:Emit(big and 8 or 5)
			task.wait(0.08)
		end
	end)
end

------------------------------------------------------------------
-- money: coins into the HUD
------------------------------------------------------------------
local function targetFor(which: string?): Vector2?
	local t = UILib.fxTargets[which or "cash"]
	if type(t) ~= "table" then return nil end
	local g = t.Icon
	if not (typeof(g) == "Instance" and g.Parent) then g = t.Instance end
	if typeof(g) ~= "Instance" or not g.Parent or not g:IsA("GuiObject") or not g.Visible then return nil end
	return centerOf(g)
end

local lastBump = 0
local function bumpTarget(which: string?)
	local now = os.clock()
	if now - lastBump < 0.07 then return end
	lastBump = now
	local t = UILib.fxTargets[which or "cash"]
	if type(t) == "table" and type(t.bump) == "function" then pcall(t.bump) end
end

local function coinsFor(amount: number?): number
	local a = math.max(1, tonumber(amount) or 1)
	local n = math.floor(math.log10(a) * 2 + 2)
	return math.clamp(math.floor(n * intensity() + 0.5), 2, 12)
end

-- what just happened, so a cash change knows where its coins come from
local lastToastKind, lastToastT, lastToastTile = nil, 0, nil
local worldAnchor: Vector3? = nil
local worldAnchorT = 0
local creditT = 0      -- last time the server reported machine income
local spendAmt, spendT = 0, 0 -- recent cash spent (HudUI reports every drop)
local lastSpendAt = -10        -- (never consumed: tells purchases from rewards)
local robuxT = 0       -- a Robux product purchase just went through

-- HudUI: the cash went up by `amount` (coalesced). Returns true when the coins
-- will fly; onLand() then fires as the first lands (rolls the number) and
-- UXFX pops the "+$X". false = HudUI does its own bump + float.
function UXFX.cashGain(amount: number, onLand, newCash: number?): boolean
	if not started or type(amount) ~= "number" or amount <= 0 then return false end
	local now = os.clock()
	local from: Vector2? = nil
	local moneyToast = now - lastToastT < 1.6
		and (lastToastKind == "income" or lastToastKind == "unlock" or lastToastKind == "ticket")
	-- an "unlock" right after spending was a purchase: income arriving now isn't its money
	if moneyToast and lastToastKind == "unlock" and now - lastSpendAt < 2.5 then moneyToast = false end
	if moneyToast then
		if worldAnchor and now - worldAnchorT < 2 then
			local x, y = project(worldAnchor)
			if x and onScreen(x, y) then from = Vector2.new(x, y) end
		end
		local lp = UILib.lastPress
		if not from and lp and now - lp.t < 3 then from = absToLayer(lp.at) end
		if not from and lastToastTile and lastToastTile.Parent then from = centerOf(lastToastTile) end
	elseif now - robuxT < 20 then
		-- a Robux cash pack landed: shower from the middle of the screen
		robuxT = 0
		from = screenCenter()
		confettiBurst(from, 30, PALETTES.money, -90, 75, 1.1)
		sparkle(from, 6, 60 * uiScale(), C.GoldTop)
		play("kaching")
	elseif type(newCash) == "number" and amount >= 1000 and amount >= (newCash - amount) * 0.5 and now - creditT > 1.5 then
		from = screenCenter() -- a windfall nobody announced
	end
	if not from then return false end
	local target = targetFor("cash")
	if not target then return false end
	local landed = false
	local function first()
		if landed then return end
		landed = true
		if onLand then pcall(onLand) end
	end
	local function land(i: number)
		if not landed then
			first()
			local t = UILib.fxTargets.cash
			if type(t) == "table" and t.Instance then
				UILib.floatText("+" .. UILib.money(amount), C.GreenTop, t.Instance)
			end
			local s = uiScale()
			ring(target, 20 * s, 96 * s, 0.4, C.GoldTop, 5 * s)
		end
		bumpTarget("cash")
		play("coin", 1 + math.min(i, 10) * 0.045)
	end
	if flyCoins(from, target, coinsFor(amount), 70, land) == 0 then return false end
	play("pop", 1.15, 0.7)
	task.delay(1.8, first) -- the number never waits on a coin that didn't make it
	return true
end

-- HudUI: cash went down (every drop, uncoalesced). Only remembered here: when
-- a purchase is confirmed (an "unlock" toast right after a button press) a
-- few coins leave the pill for that button and the confetti pops as they land.
function UXFX.cashSpend(amount: number)
	if not started or type(amount) ~= "number" or amount <= 0 then return end
	local now = os.clock()
	if now - spendT > 1.5 then spendAmt = 0 end
	spendAmt += amount
	spendT = now
	lastSpendAt = now
end

-- coins from the cash pill to `at` (layer px); fn(at) runs as the first lands.
-- Returns false (and runs nothing) when no coins could fly.
local function spendCoins(at: Vector2, amount: number, fn): boolean
	local from = targetFor("cash")
	if not from then return false end
	local done = false
	local n = flyCoins(from, at, math.clamp(coinsFor(amount) - 2, 2, 7), 26, function()
		if done then return end
		done = true
		fn(at)
	end, 0.75)
	return n > 0
end

function UXFX.ticketGain(_amount: number?)
	if not started then return end
	local at = targetFor("tickets")
	if not at then return end
	local s = uiScale()
	sparkle(at, 5, 34 * s, C.PinkTop)
	ring(at, 20 * s, 100 * s, 0.45, C.PinkTop, 5 * s)
	play("pop", 1.2)
end

function UXFX.coinBurst(from, amount: number?, target: string?)
	if not started then return end
	local at = (from ~= nil and anchorToLayer(from)) or screenCenter()
	local which = target == "tickets" and "tickets" or "cash"
	local to = targetFor(which)
	flyCoins(at, to, coinsFor(amount or 100), 60, function(i: number)
		bumpTarget(which)
		play("coin", 1 + math.min(i, 10) * 0.045)
	end)
	play("pop", 1.15, 0.7)
end

------------------------------------------------------------------
-- the server's owner-facing FX (Gambling.luau)
------------------------------------------------------------------
local function handleIncome(list)
	if type(list) ~= "table" then return end
	creditT = os.clock()
	if UILib.hasOpenPanel() then return end -- the world is behind a panel right now
	local cam = Workspace.CurrentCamera
	if not cam then return end
	local camPos = cam.CFrame.Position
	local target = targetFor("cash")
	local pops, coinsLeft = 0, math.max(1, math.floor(INCOME_COINS * intensity() + 0.5))
	local chimed = false
	local function landed()
		bumpTarget("cash")
		if not chimed then
			chimed = true
			play("coin", 1.05, 0.55)
		end
	end
	for _, e in list do
		if pops >= INCOME_POPS then break end
		if type(e) == "table" and type(e.a) == "number" and e.a > 0 then
			local m = typeof(e.m) == "Instance" and e.m or nil
			-- skip machines the story cutaway (or a drop-in) is hiding
			local prim = m and m:IsA("Model") and m.PrimaryPart
			if not (prim and prim.LocalTransparencyModifier >= 1) then
				local pos = topOf(m)
				if not pos and typeof(e.p) == "Vector3" then pos = e.p + Vector3.new(0, 3.5, 0) end
				if pos then pos += LABEL_LIFT end
				if pos and (pos - camPos).Magnitude <= INCOME_RANGE then
					local x, y = project(pos)
					if x and onScreen(x, y, -20) then
						pops += 1
						worldLabel(pos, "+" .. UILib.money(e.a), e.c and C.GoldTop or C.GreenTop, e.c and 26 or 28)
						if target and coinsLeft > 0 then
							coinsLeft -= 1
							flyCoins(Vector2.new(x, y), target, 1, 16, landed)
						end
					end
				end
			end
		end
	end
end

local lastJackpotBanner = 0
local function handleBigWin(p)
	local m = typeof(p.machine) == "Instance" and p.machine or nil
	local pos = topOf(m)
	if not pos and typeof(p.pos) == "Vector3" then pos = p.pos + Vector3.new(0, 3, 0) end
	local mult = tonumber(p.mult) or 10
	local amount = tonumber(p.amount) or 0
	local big = mult >= JACKPOT_MULT
	local cam = Workspace.CurrentCamera
	if pos and cam and (pos - cam.CFrame.Position).Magnitude <= 170 then
		jackpotWorld(pos - Vector3.new(0, 0.8, 0), m, big)
		if not UILib.hasOpenPanel() then
			local text = big and ("JACKPOT! " .. UILib.money(amount)) or (("BIG WIN x%d!"):format(mult))
			worldLabel(pos + LABEL_LIFT, text, C.GoldTop, big and 40 or 32, 1.8)
		end
		if big then
			UXFX.flash(C.GoldTop, 0.45)
			UXFX.punch(0.7)
		else
			play("coin", 0.9)
			play("pop", 1.2, 0.8)
		end
	end
	if big and os.clock() - lastJackpotBanner > 20 then
		lastJackpotBanner = os.clock()
		local who = type(p.by) == "string" and p.by ~= "" and p.by or "A lucky guest"
		UXFX.banner("JACKPOT!", ("%s won %s on your %s!"):format(who, UILib.money(amount), tostring(p.name or "machine")),
			"purple", "jackpot")
	end
end

local function onServerFx(payload)
	if type(payload) ~= "table" then return end
	if payload.kind == "income" then
		handleIncome(payload.list)
	elseif payload.kind == "bigwin" then
		handleBigWin(payload)
	end
end

------------------------------------------------------------------
-- placement: the new machine is hidden locally while a stand-in (a copy of
-- its preview model) drops in; then the real one shows
------------------------------------------------------------------
local expected = nil -- { pos, t, saved, model?, conn?, dropping? }
local myMachines = {} -- my machine -> last known position (for the store / sell puff)

local function hideOne(d: Instance, saved)
	if saved[d] ~= nil then return end
	if d:IsA("BasePart") or d:IsA("Decal") or d:IsA("Texture") then
		if d.LocalTransparencyModifier < 1 then
			saved[d] = d.LocalTransparencyModifier
			d.LocalTransparencyModifier = 1
		end
	elseif d:IsA("SurfaceGui") or d:IsA("BillboardGui") or d:IsA("Light") or d:IsA("ParticleEmitter") or d:IsA("Beam") then
		if d.Enabled then
			saved[d] = true
			d.Enabled = false
		end
	end
end

local function revealAll(saved)
	for inst, v in saved do
		if inst.Parent then
			if inst:IsA("BasePart") or inst:IsA("Decal") or inst:IsA("Texture") then
				inst.LocalTransparencyModifier = v
			else
				inst.Enabled = v
			end
		end
	end
	table.clear(saved)
end

local function claimExpected(exp, m: Instance)
	exp.model = m
	for _, d in m:GetDescendants() do hideOne(d, exp.saved) end
	exp.conn = m.DescendantAdded:Connect(function(d) hideOne(d, exp.saved) end) -- parts still streaming in
end

local function releaseExpected(exp)
	if exp.conn then
		exp.conn:Disconnect()
		exp.conn = nil
	end
	revealAll(exp.saved)
	if expected == exp then expected = nil end
end

-- PlacementController, right before PlaceFromInventory: a machine of mine
-- showing up at `pos` stays hidden until its drop-in
function UXFX.expectPlacement(pos: Vector3): boolean
	if not started or typeof(pos) ~= "Vector3" then return false end
	if expected then releaseExpected(expected) end
	local exp = { pos = pos, t = os.clock(), saved = {} }
	expected = exp
	task.delay(5, function()
		if expected == exp and not exp.dropping then releaseExpected(exp) end
	end)
	return true
end

function UXFX.cancelExpected()
	if expected and not expected.dropping then releaseExpected(expected) end
end

-- PlacementController after a successful place / move:
-- info = { cf = ground CFrame, machineId, radius, machine? (move), restore? (move: shows the real one) }
function UXFX.placeDrop(info): boolean
	if not started or type(info) ~= "table" or typeof(info.cf) ~= "CFrame" then return false end
	local cf: CFrame = info.cf
	local exp = nil
	if typeof(info.machine) == "Instance" then
		myMachines[info.machine] = cf.Position
	else
		exp = expected
		if exp then exp.dropping = true end
	end
	local stand: Model? = nil
	local finished = false
	local function finish()
		if finished then return end
		finished = true
		if stand then
			stand:Destroy()
			stand = nil
		end
		if type(info.restore) == "function" then pcall(info.restore) end
		if exp then releaseExpected(exp) end
	end
	task.delay(3.5, finish) -- whatever happens, the real machine shows
	task.spawn(function()
		local ok, err = pcall(function()
			local folder = ReplicatedStorage:FindFirstChild("MachinePreviews")
			local tpl = (not reducedMotion()) and folder and type(info.machineId) == "string"
				and folder:FindFirstChild(info.machineId)
			if tpl and tpl:IsA("Model") then
				local m = tpl:Clone()
				for _, d in m:GetDescendants() do
					if d:IsA("BasePart") then
						d.Anchored = true
						d.CanCollide = false
						d.CanQuery = false
						d.CanTouch = false
					end
				end
				m.Name = "UXFXDrop"
				m:PivotTo(cf * CFrame.new(0, DROP_H, 0))
				m.Parent = buildWorld().folder
				stand = m
				-- fall (speeding up, a little twist)
				local t0 = os.clock()
				while not finished do
					local a = math.min((os.clock() - t0) / FALL_T, 1)
					local e = a * a
					m:PivotTo(cf * CFrame.new(0, DROP_H * (1 - e), 0) * CFrame.Angles(0, math.rad(14 * (1 - e)), 0))
					if a >= 1 then break end
					RunService.RenderStepped:Wait()
				end
			end
			if finished then return end
			impact(cf.Position, info.radius)
			if stand then
				-- settle: a small hop with a scale pulse
				local m = stand
				local t0 = os.clock()
				while not finished do
					local a = math.min((os.clock() - t0) / SETTLE_T, 1)
					local k = math.sin(a * math.pi)
					pcall(m.ScaleTo, m, 1 + 0.06 * k)
					m:PivotTo(cf * CFrame.new(0, 0.35 * k * (1 - 0.4 * a), 0))
					if a >= 1 then break end
					RunService.RenderStepped:Wait()
				end
				pcall(m.ScaleTo, m, 1)
				m:PivotTo(cf)
				-- the real one may still be on its way (streaming): hold the stand-in a moment
				if exp and not exp.model then
					local deadline = os.clock() + 1.5
					while not finished and not exp.model and os.clock() < deadline do task.wait() end
				end
			end
		end)
		if not ok then warn("[UXFX] placeDrop: " .. tostring(err)) end
		finish()
	end)
	return true
end

local function onMachineAdded(m: Instance)
	if m:GetAttribute("OwnerId") ~= player.UserId then return end
	local exp = expected
	if exp and not exp.model and os.clock() - exp.t < 5 then
		local match = true
		local prim = m:IsA("Model") and m.PrimaryPart
		if prim then
			local p = (m :: Model):GetPivot().Position
			match = math.abs(p.X - exp.pos.X) < 2.5 and math.abs(p.Z - exp.pos.Z) < 2.5
				and math.abs(p.Y - exp.pos.Y) < 6 -- (not one of mine on another floor)
		end
		if match then claimExpected(exp, m) end
	end
	task.delay(0.5, function()
		local prim = m.Parent and m:IsA("Model") and m.PrimaryPart
		if prim then myMachines[m] = prim.Position end
	end)
end

-- one of my machines is gone (stored / sold): a puff where it stood. Only
-- close to the camera (a far machine could merely have streamed out).
local function onMachineRemoved(m: Instance)
	local known = myMachines[m]
	myMachines[m] = nil
	if m:GetAttribute("OwnerId") ~= player.UserId then return end
	local prim = m:IsA("Model") and m.PrimaryPart
	local pos = (prim and prim.Position) or known
	if not pos then return end
	local cam = Workspace.CurrentCamera
	if not cam or (cam.CFrame.Position - pos).Magnitude > 75 then return end
	worldAnchor = pos + Vector3.new(0, 2, 0)
	worldAnchorT = os.clock()
	UXFX.puff(pos, m:GetAttribute("FootprintRadius"))
end

------------------------------------------------------------------
-- UILib juice hooks
------------------------------------------------------------------
local function onToast(kind: string, card, tile, _title, _message)
	lastToastKind, lastToastT, lastToastTile = kind, os.clock(), tile
	local now = os.clock()
	local icon = typeof(tile) == "Instance" and tile:FindFirstChildWhichIsA("ImageLabel") or nil
	if icon then UXFX.pop(icon, 1.45) end
	local lp = UILib.lastPress
	local pressed = (lp and now - lp.t < 3) and lp or nil
	local s = uiScale()
	-- toasts slide in, so effects anchored on the toast wait until it has arrived
	local function atToast(fn)
		task.delay(0.22, function()
			if typeof(tile) == "Instance" and tile.Parent then fn(centerOf(tile)) end
		end)
	end
	if kind == "unlock" then
		play("kaching")
		local function burst(at: Vector2)
			if pressed and pressed.gui and pressed.gui.Parent then UXFX.pop(pressed.gui, 1.14) end
			confettiBurst(at, 34, PALETTES.show, -90, 70, 1)
			sparkle(at, 5, 50 * s, C.White)
			ring(at, 16 * s, 150 * s, 0.5, C.GoldTop, 6 * s)
		end
		if pressed then
			local at = absToLayer(pressed.at)
			-- a purchase: a few coins leave the pill for the button, the confetti pops as they land
			local paid = now - spendT < 1.5 and spendAmt > 0
			if not (paid and spendCoins(at, spendAmt, burst)) then burst(at) end
			spendAmt, spendT = 0, 0
		else
			atToast(burst)
		end
	elseif kind == "income" then
		play("coin", 1.1)
		atToast(function(at) sparkle(at, 4, 30 * s, C.GoldTop) end)
	elseif kind == "ticket" then
		play("pop", 1.1)
		local function burst(at: Vector2)
			confettiBurst(at, 18, PALETTES.ticket, -90, 60, 0.85)
			sparkle(at, 4, 36 * s, C.PinkTop)
		end
		if pressed then burst(absToLayer(pressed.at)) else atToast(burst) end
	elseif kind == "error" then
		play("error")
		if typeof(card) == "Instance" then UXFX.shake(card, 0.7) end
		if lp and now - lp.t < 1.5 and lp.gui and lp.gui.Parent then UXFX.shake(lp.gui, 1) end
	elseif kind == "placed" then
		-- the drop-in plays its own thud
	else
		play("pop", 1, 0.7)
	end
end

local function onUiEvent(event: string, a, b, c, d, e)
	if event == "press" then
		play("click", 1.05 + (math.random() - 0.5) * 0.1)
	elseif event == "hover" then
		play("hover")
	elseif event == "tab" then
		play("tab")
	elseif event == "panelOpen" then
		play("open")
	elseif event == "panelClose" then
		if a ~= true then play("close") end -- (a panel replaced by another closes instantly: silent)
	elseif event == "toast" then
		onToast(a, b, c, d, e)
	end
end

------------------------------------------------------------------
-- public API
------------------------------------------------------------------
function UXFX.sound(name: string, speed: number?, volume: number?)
	if started and type(name) == "string" then play(name, speed, volume) end
end

function UXFX.setVolume(v: number)
	UXFX.MasterVolume = math.clamp(tonumber(v) or 0.8, 0, 1)
	if soundGroup then soundGroup.Volume = UXFX.MasterVolume end
end

function UXFX.reducedMotion(): boolean
	return reducedMotion()
end

function UXFX.confetti(anchor, count: number?, palette: string?)
	if not started then return end
	local at = (anchor ~= nil and anchorToLayer(anchor)) or screenCenter()
	confettiBurst(at, count or 36, PALETTES[palette or "show"] or PALETTES.show, -90, 70, 1)
end

function UXFX.sparkle(anchor, count: number?, color: Color3?)
	if not started then return end
	local at = (anchor ~= nil and anchorToLayer(anchor)) or screenCenter()
	sparkle(at, count or 6, 50 * uiScale(), typeof(color) == "Color3" and color or nil)
end

function UXFX.worldText(where, text: string, color: Color3?, size: number?)
	if not started or type(text) ~= "string" then return end
	local pos = nil
	if typeof(where) == "Vector3" then
		pos = where
	elseif typeof(where) == "Instance" then
		if where:IsA("BasePart") then
			pos = where.Position + Vector3.new(0, where.Size.Y * 0.5 + 1, 0)
		elseif where:IsA("Model") then
			pos = topOf(where)
			if pos then pos += LABEL_LIFT end
		end
	end
	if pos then worldLabel(pos, text, typeof(color) == "Color3" and color or C.GoldTop, size or 30, 1.3) end
end

-- kind: "unlock" (default) | "income" | "ticket" | "big" | "small"
function UXFX.celebrate(kind: string?, anchor)
	if not started then return end
	local at = (anchor ~= nil and anchorToLayer(anchor)) or screenCenter()
	if typeof(anchor) == "Instance" and anchor:IsA("GuiObject") then UXFX.pop(anchor, 1.15) end
	local s = uiScale()
	if kind == "income" or kind == "money" then
		play("coin")
		confettiBurst(at, 14, PALETTES.money, -90, 70, 0.8)
		sparkle(at, 4, 36 * s, C.GoldTop)
	elseif kind == "ticket" then
		play("pop", 1.1)
		confettiBurst(at, 18, PALETTES.ticket, -90, 65, 0.85)
		sparkle(at, 4, 36 * s, C.PinkTop)
	elseif kind == "big" or kind == "rankup" then
		play("fanfare")
		confettiBurst(at, 60, PALETTES.show, -90, 80, 1.15)
		sparkle(at, 8, 80 * s, C.White)
		ring(at, 30 * s, 320 * s, 0.6, C.GoldTop, 8 * s)
		UXFX.flash(C.GoldTop, 0.5)
		UXFX.punch(0.6)
	elseif kind == "small" then
		play("pop")
		sparkle(at, 5, 30 * s, C.White)
	else
		play("kaching")
		confettiBurst(at, 36, PALETTES.show, -90, 70, 1)
		sparkle(at, 6, 50 * s, C.White)
		ring(at, 16 * s, 150 * s, 0.5, C.GoldTop, 6 * s)
	end
end

-- DayNightFX: the night rush begins (badge = the clock pill)
function UXFX.nightRush(badge)
	if not started then return end
	play("jingle")
	UXFX.vignette(C.Purple, 2)
	if typeof(badge) == "Instance" and badge:IsA("GuiObject") then
		task.delay(0.1, function()
			if not badge.Parent then return end
			local at = centerOf(badge)
			local s = uiScale()
			sparkle(at, 7, 90 * s, C.PinkTop)
			ring(at, 30 * s, 220 * s, 0.6, C.PinkTop, 6 * s)
			confettiBurst(at, 16, PALETTES.night, 110, 40, 0.7)
		end)
	end
end

-- deps: { MachineFX = module } (bulb strobes on big wins)
function UXFX.start(d): boolean
	if started then return true end
	deps = type(d) == "table" and d or {}
	buildOverlay()
	buildSounds()
	started = true
	UILib.FX = UXFX
	UILib.onFx(onUiEvent)
	task.spawn(verifySounds)

	-- my machines: the placement drop-in, the store / sell puff
	for _, m in CollectionService:GetTagged("CasinoMachine") do task.spawn(onMachineAdded, m) end
	CollectionService:GetInstanceAddedSignal("CasinoMachine"):Connect(onMachineAdded)
	CollectionService:GetInstanceRemovedSignal("CasinoMachine"):Connect(function(m)
		local ok, err = pcall(onMachineRemoved, m)
		if not ok then warn("[UXFX] machine removed: " .. tostring(err)) end
	end)

	-- Robux: a cash pack's money showers in from the middle of the screen, a
	-- new game pass gets a thank-you banner
	pcall(function()
		local MarketplaceService = game:GetService("MarketplaceService")
		MarketplaceService.PromptProductPurchaseFinished:Connect(function(userId, _productId, purchased)
			if purchased and userId == player.UserId then robuxT = os.clock() end
		end)
		MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(plr, _passId, purchased)
			if purchased and plr == player then UXFX.banner("THANK YOU!", "Your game pass is active", "gold") end
		end)
	end)

	-- the server's owner-facing FX (income pops, big wins)
	task.spawn(function()
		local okR, Remotes = pcall(require, ReplicatedStorage:WaitForChild("CasinoCommon"):WaitForChild("Remotes"))
		if not okR then return end
		local okE, ev = pcall(function() return Remotes.FX() end)
		if not (okE and ev) then
			warn("[UXFX] FX remote missing; owner income pops are off.")
			return
		end
		ev.OnClientEvent:Connect(function(payload)
			local ok, err = pcall(onServerFx, payload)
			if not ok then warn("[UXFX] fx event: " .. tostring(err)) end
		end)
	end)
	return true
end

return UXFX
