--!nonstrict
-- MachineModels.luau — every machine and concession is built FROM CODE in one
-- "Showtime" 3D style that matches the UI: an ink plinth with a gold lip and a
-- neon underglow, glossy cabinets in the item's colour, gold trims, chasing neon
-- marquee bulbs, and signs that use the UI fonts + 3D icon renders.
--
-- Builders work in model space: ground at y = 0, centred on x/z, FRONT = -Z.
-- MachineVisuals.seat() then pivots the model onto a plot or pedestal.
--
-- Named rig parts the animations rely on (MachineVisuals / client MachineFX):
--   Slots     Spinny1..3 (Decal per reel), LEDs, Lever (model), sounds in Body;
--             extra reel banks SpinnyL1..3 / SpinnyR1..3 (+ LEDsL / LEDsR) roll along
--   Roulette  Wheel (+ Turret, Ball) spin around Y
--   Wheel     Wheel spins around the Z axis, Pointer at the top
--   Dice      Die1, Die2 (+ Die3); attribute DiceHop = how high they jump
--   Plinko    Ball, Pegs/P<row>_<rights>, Pockets/Pocket1..9 (see plinkoBoard)
--   any       Bulbs (folder of neon balls for the marquee chase); sub-models
--             with a SpinRate attribute turn slowly about their PrimaryPart's
--             +Y (showpiece gems; spinnerAt can aim it any way); ParticleEmitters
--             named "Sparks" burst on a win (every play with BurstOnPlay)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GeometryService = game:GetService("GeometryService")
local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local UIAssets = require(Common:WaitForChild("UIAssets"))
local GameLogic = require(Common:WaitForChild("GameLogic"))

local MachineModels = {}

local hex = Color3.fromHex
local P = {
	Ink = hex("#2B0A12"), Gold = hex("#FFCB2E"), GoldDeep = hex("#E89A0C"), GoldTop = hex("#FFF3A8"),
	Cream = hex("#FFF4DC"), Chrome = hex("#D6DCE4"), White = Color3.new(1, 1, 1),
	Crimson = hex("#D7263D"), CrimsonDeep = hex("#8E0F22"), Wood = hex("#7A3E1C"), WoodDark = hex("#4A2412"),
	Leather = hex("#3A1810"), Felt = hex("#1F8A4C"), FeltBlue = hex("#1A6FB0"),
	NeonRed = hex("#FF3B55"), NeonGreen = hex("#3DFF6E"), NeonBlue = hex("#3FC8FF"), NeonPink = hex("#FF4FD0"),
	Amber = hex("#FFC003"),
}
MachineModels.Palette = P

MachineModels.Textures = {
	roulette = "rbxassetid://101031533731227",
	fortune = "rbxassetid://84489100725163",
}

local SOUNDS = {
	spin = "rbxassetid://177266782", -- reel spin loop
	stop = "rbxassetid://3299794881", -- reel stop click
	win = "rbxassetid://4879566787", -- win jingle
}

------------------------------------------------------------------
-- tiny kit
------------------------------------------------------------------
local function new(class: string, props, parent: Instance?)
	local inst = Instance.new(class)
	for k, v in props do (inst :: any)[k] = v end
	if parent then inst.Parent = parent end
	return inst
end

-- opts: material, reflectance, transparency, solid, shape, parent, shadow
local function part(parent: Instance, name: string, size: Vector3, cf: CFrame, color: Color3, opts)
	opts = opts or {}
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = opts.material or Enum.Material.SmoothPlastic
	p.Reflectance = opts.reflectance or 0
	p.Transparency = opts.transparency or 0
	p.CanCollide = opts.solid == true
	p.CanQuery = opts.solid == true or opts.query == true
	p.CanTouch = false
	p.CastShadow = opts.shadow ~= false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	if opts.shape then p.Shape = opts.shape end
	p.Parent = parent
	return p
end
local function neon(parent, name, size, cf, color)
	return part(parent, name, size, cf, color, { material = Enum.Material.Neon, shadow = false })
end
local function gold(parent, name, size, cf)
	return part(parent, name, size, cf, P.Gold, { reflectance = 0.12 })
end
-- vertical cylinder (axis = world Y). Its top cap is the part's Right face.
local function cylY(parent, name, diameter, height, pos: Vector3, color, opts)
	opts = opts or {}
	opts.shape = Enum.PartType.Cylinder
	return part(parent, name, Vector3.new(height, diameter, diameter),
		CFrame.new(pos) * CFrame.Angles(0, 0, math.rad(90)), color, opts)
end
-- cylinder facing the front (axis = world Z). Its front (-Z) cap is the part's Right face.
local function cylZ(parent, name, diameter, length, pos: Vector3, color, opts)
	opts = opts or {}
	opts.shape = Enum.PartType.Cylinder
	return part(parent, name, Vector3.new(length, diameter, diameter),
		CFrame.new(pos) * CFrame.Angles(0, math.rad(90), 0), color, opts)
end
-- cylinder along world X
local function cylX(parent, name, diameter, length, pos: Vector3, color, opts)
	opts = opts or {}
	opts.shape = Enum.PartType.Cylinder
	return part(parent, name, Vector3.new(length, diameter, diameter), CFrame.new(pos), color, opts)
end
local function ball(parent, name, d, pos: Vector3, color, opts)
	opts = opts or {}
	opts.shape = Enum.PartType.Ball
	return part(parent, name, Vector3.new(d, d, d), CFrame.new(pos), color, opts)
end
-- rounded "stadium" slab (box + half discs at both X ends), returns the box
local function stadium(parent, name, length, width, height, centre: Vector3, color, opts)
	local core = part(parent, name, Vector3.new(length, height, width), CFrame.new(centre), color, opts)
	local o2 = table.clone(opts or {})
	cylY(parent, name .. "L", width, height, centre - Vector3.new(length / 2, 0, 0), color, o2)
	local o3 = table.clone(opts or {})
	cylY(parent, name .. "R", width, height, centre + Vector3.new(length / 2, 0, 0), color, o3)
	return core
end

-- SurfaceGui helpers ------------------------------------------------
local function surface(p: BasePart, face: Enum.NormalId, ppu: number?, light: number?)
	return new("SurfaceGui", {
		Name = "Gui_" .. face.Name, Face = face, SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud,
		PixelsPerStud = ppu or 80, LightInfluence = light or 0.2, ClipsDescendants = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	}, p)
end
-- an invisible carrier for a print lying flat (felt layouts). A Top-face
-- SurfaceGui reads "up" toward the part's -X, so the part is turned 90° about
-- Y: the print then reads upright for a player at the front (-Z), with `width`
-- running along X and `depth` along Z.
local function flatPrint(parent, name, width: number, depth: number, cf: CFrame, color: Color3?)
	return part(parent, name, Vector3.new(depth, 0.02, width), cf * CFrame.Angles(0, math.rad(90), 0),
		color or P.Felt, { transparency = 1, shadow = false })
end
local function guiText(parent, text, props)
	props = props or {}
	local l = new("TextLabel", {
		BackgroundTransparency = 1, Size = props.size or UDim2.fromScale(1, 1),
		Position = props.position or UDim2.new(), AnchorPoint = props.anchor or Vector2.zero,
		Text = text, Font = props.font or Enum.Font.LuckiestGuy, TextScaled = true,
		TextColor3 = props.color or P.White, Rotation = props.rotation or 0, ZIndex = props.z or 2,
	}, parent)
	new("UITextSizeConstraint", { MaxTextSize = props.max or 400 }, l)
	if props.stroke ~= false then
		new("UIStroke", { Color = props.strokeColor or P.Ink, Thickness = props.strokeThickness or 6,
			LineJoinMode = Enum.LineJoinMode.Round }, l)
	end
	if props.gradient then
		new("UIGradient", { Rotation = 90, Color = ColorSequence.new(props.gradient[1], props.gradient[2]) }, l)
	end
	return l
end
local function guiImage(parent, icon, props)
	props = props or {}
	return new("ImageLabel", {
		BackgroundTransparency = 1, Image = UIAssets.Icons[icon] or icon, ScaleType = Enum.ScaleType.Fit,
		Size = props.size or UDim2.fromScale(1, 1), Position = props.position or UDim2.fromScale(0.5, 0.5),
		AnchorPoint = props.anchor or Vector2.new(0.5, 0.5), ZIndex = props.z or 2,
	}, parent)
end
-- crimson sign plate with a gold border (fills a SurfaceGui)
local function signPlate(gui, fill: Color3?, border: Color3?)
	local f = new("Frame", {
		BackgroundColor3 = P.White, Size = UDim2.new(1, -8, 1, -8), Position = UDim2.fromOffset(4, 4), ZIndex = 1,
	}, gui)
	new("UICorner", { CornerRadius = UDim.new(0.12, 0) }, f)
	local c = fill or P.Crimson
	new("UIGradient", { Rotation = 90, Color = ColorSequence.new(c:Lerp(P.White, 0.18), c:Lerp(P.Ink, 0.25)) }, f)
	new("UIStroke", { Color = border or P.Gold, Thickness = 8, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, f)
	return f
end

-- a row of alternating neon bulbs between two points (into the Bulbs folder)
local function bulbsAlong(folder: Instance, a: Vector3, b: Vector3, count: number, d: number?)
	for i = 0, count - 1 do
		local t = count == 1 and 0.5 or i / (count - 1)
		local bulb = ball(folder, "Bulb", d or 0.16, a:Lerp(b, t), (i % 2 == 0) and P.GoldTop or P.White,
			{ material = Enum.Material.Neon, shadow = false })
		bulb:SetAttribute("Phase", i % 2)
	end
end
-- bulbs around a rectangle lying in an XY plane at depth z (front frame);
-- d = bulb diameter (default 0.16, as bulbsAlong)
local function bulbFrame(folder, cx, cy, w, h, z, perSide, d: number?)
	local x0, x1, y0, y1 = cx - w / 2, cx + w / 2, cy - h / 2, cy + h / 2
	bulbsAlong(folder, Vector3.new(x0, y1, z), Vector3.new(x1, y1, z), perSide, d)
	bulbsAlong(folder, Vector3.new(x0, y0, z), Vector3.new(x1, y0, z), perSide, d)
	local side = math.max(2, math.floor(perSide * h / w))
	bulbsAlong(folder, Vector3.new(x0, y0, z), Vector3.new(x0, y1, z), side, d)
	bulbsAlong(folder, Vector3.new(x1, y0, z), Vector3.new(x1, y1, z), side, d)
end

-- the shared ink plinth with a gold lip and a neon underglow (zc: its centre
-- along Z, default 0)
local function plinth(model, w: number, d: number, glow: Color3, h: number?, zc: number?)
	h = h or 0.45
	zc = zc or 0
	part(model, "Plinth", Vector3.new(w, h, d), CFrame.new(0, h / 2, zc), P.Ink, { solid = true })
	gold(model, "PlinthLip", Vector3.new(w + 0.14, 0.12, d + 0.14), CFrame.new(0, h - 0.03, zc))
	neon(model, "Underglow", Vector3.new(w - 0.3, 0.07, 0.05), CFrame.new(0, 0.16, zc - d / 2 - 0.025), glow)
	return h
end

local function addSounds(body: BasePart)
	local function snd(name, id, looped)
		new("Sound", { Name = name, SoundId = id, Volume = 0.45, Looped = looped, RollOffMaxDistance = 45,
			RollOffMinDistance = 6 }, body)
	end
	snd("Sound", SOUNDS.spin, true)
	snd("Slots", SOUNDS.stop, false)
	snd("Winner", SOUNDS.win, false)
end

------------------------------------------------------------------
-- SLOT MACHINE (Lucky 7s / Diamond)
-- spec: color, accent (neon), title, icon (topper), belly ("777" or icon)
------------------------------------------------------------------
local function slotMachine(def, spec)
	local model = new("Model", { Name = def.name })
	local bulbs = new("Folder", { Name = "Bulbs" }, model)
	local col = spec.color
	local W, D = 3.6, 2.8
	local h0 = plinth(model, W + 0.5, D + 0.4, spec.accent)

	-- lower cabinet (the Body / PrimaryPart) + belly glass
	local body = part(model, "Body", Vector3.new(W, 2.3, D), CFrame.new(0, h0 + 1.15, 0), col, { solid = true })
	model.PrimaryPart = body
	local belly = part(model, "Belly", Vector3.new(W - 0.6, 1.25, 0.08), CFrame.new(0, h0 + 1.25, -D / 2 - 0.04), col:Lerp(P.Ink, 0.35))
	local bg = surface(belly, Enum.NormalId.Front, 100, 0.1)
	signPlate(bg, col:Lerp(P.Ink, 0.15))
	local bellyText = spec.bellyText or (spec.belly == "777" and "777") or nil
	if bellyText then
		guiText(bg, bellyText, { size = UDim2.new(0.86, 0, 0.8, 0), position = UDim2.fromScale(0.07, 0.1),
			gradient = { P.GoldTop, P.Gold }, strokeThickness = 8 })
	else
		guiImage(bg, spec.icon, { size = UDim2.fromScale(0.8, 0.8) })
	end
	-- coin tray
	gold(model, "Tray", Vector3.new(2.0, 0.3, 0.6), CFrame.new(0, h0 + 0.42, -D / 2 - 0.22))
	part(model, "TraySlot", Vector3.new(1.75, 0.08, 0.42), CFrame.new(0, h0 + 0.58, -D / 2 - 0.22), P.Ink)
	-- vertical gold edge trims on the lower cabinet
	for _, sx in { -1, 1 } do
		gold(model, "EdgeTrim", Vector3.new(0.14, 2.3, 0.14), CFrame.new(sx * W / 2, h0 + 1.15, -D / 2))
	end

	-- button deck (ledge) with three glowing buttons + a big spin button
	local deckY = h0 + 2.3
	gold(model, "Deck", Vector3.new(W + 0.1, 0.2, 0.7), CFrame.new(0, deckY + 0.1, -D / 2 - 0.05))
	for i, c in { P.NeonRed, P.Amber, P.NeonGreen } do
		cylY(model, "Button" .. i, 0.26, 0.1, Vector3.new(-1.2 + (i - 1) * 0.5, deckY + 0.24, -D / 2 - 0.15), c,
			{ material = Enum.Material.Neon, shadow = false })
	end
	cylY(model, "SpinButton", 0.5, 0.12, Vector3.new(1.05, deckY + 0.25, -D / 2 - 0.12), P.NeonRed,
		{ material = Enum.Material.Neon, shadow = false })

	-- upper cabinet with the reel window
	local upD = D - 0.4
	local upZ = 0.2
	local upFront = upZ - upD / 2
	part(model, "Upper", Vector3.new(W, 2.4, upD), CFrame.new(0, deckY + 1.2, upZ), col, { solid = true })
	local reelY = deckY + 1.05
	gold(model, "ReelFrame", Vector3.new(W - 0.4, 1.55, 0.12), CFrame.new(0, reelY, upFront - 0.06))
	part(model, "ReelWindow", Vector3.new(W - 0.75, 1.25, 0.1), CFrame.new(0, reelY, upFront - 0.1), P.Ink)
	local reelImages = { UIAssets.Icons.coin, UIAssets.Icons.gem, UIAssets.Icons.star }
	for i = 1, 3 do
		local x = (i - 2) * 0.98
		local reel = part(model, "Spinny" .. i, Vector3.new(0.86, 1.08, 0.06),
			CFrame.new(x, reelY, upFront - 0.16), P.Cream)
		new("Decal", { Face = Enum.NormalId.Front, Texture = reelImages[i] }, reel)
		-- top/bottom shading sells the curved drum
		for _, sy in { -1, 1 } do
			part(model, "ReelShade", Vector3.new(0.86, 0.16, 0.02), CFrame.new(x, reelY + sy * 0.46, upFront - 0.2),
				P.Ink, { transparency = 0.55, shadow = false })
		end
	end
	neon(model, "Payline", Vector3.new(W - 0.85, 0.05, 0.02), CFrame.new(0, reelY, upFront - 0.215), P.NeonRed)
	local leds = neon(model, "LEDs", Vector3.new(W - 0.4, 0.16, 0.08), CFrame.new(0, reelY + 0.92, upFront - 0.06), P.Amber)
	leds.Color = Color3.new(1, 0.752941, 0.0117647)
	for _, sx in { -1, 1 } do
		gold(model, "UpperTrim", Vector3.new(0.14, 2.4, 0.14), CFrame.new(sx * W / 2, deckY + 1.2, upFront))
	end

	-- marquee topper with bulbs, sign and candle light
	local topY = deckY + 2.4
	local mq = gold(model, "Marquee", Vector3.new(W + 0.2, 1.35, 0.8), CFrame.new(0, topY + 0.68, upFront + 0.35))
	local mg = surface(mq, Enum.NormalId.Front, 100, 0.05)
	local plate = signPlate(mg, P.CrimsonDeep)
	guiText(plate, spec.title, { size = UDim2.new(0.84, 0, 0.62, 0), position = UDim2.fromScale(0.08, 0.2),
		gradient = { P.GoldTop, P.Gold }, strokeThickness = 7 })
	bulbFrame(bulbs, 0, topY + 0.68, W + 0.05, 1.2, upFront - 0.07, 9)
	if spec.meter then
		-- a glowing progressive-jackpot meter on top
		local meter = part(model, "JackpotMeter", Vector3.new(W + 0.4, 0.95, 0.5), CFrame.new(0, topY + 1.85, upFront + 0.35),
			P.Ink, { shadow = false })
		local mgui = surface(meter, Enum.NormalId.Front, 100, 0)
		pcall(function() mgui.Brightness = 2 end)
		guiText(mgui, spec.meter, { size = UDim2.fromScale(0.94, 0.8), position = UDim2.fromScale(0.03, 0.1),
			font = Enum.Font.FredokaOne, color = hex("#7CFF8A"), strokeThickness = 3 })
		gold(model, "MeterFrame", Vector3.new(W + 0.55, 1.1, 0.4), CFrame.new(0, topY + 1.85, upFront + 0.45))
		bulbsAlong(bulbs, Vector3.new(-(W + 0.4) / 2, topY + 2.42, upFront + 0.05), Vector3.new((W + 0.4) / 2, topY + 2.42, upFront + 0.05), 9, 0.2)
	elseif spec.icon and spec.topIcon then
		local holder = part(model, "TopIconBoard", Vector3.new(1.6, 1.6, 0.05),
			CFrame.new(0, topY + 2.15, upFront + 0.35), P.White, { transparency = 1, shadow = false })
		local g = surface(holder, Enum.NormalId.Front, 100, 0)
		guiImage(g, spec.icon, { size = UDim2.fromScale(1, 1) })
		local back = surface(holder, Enum.NormalId.Back, 100, 0)
		guiImage(back, spec.icon, { size = UDim2.fromScale(1, 1) })
	else
		cylY(model, "CandleBase", 0.42, 0.22, Vector3.new(0, topY + 1.47, upFront + 0.35), P.Gold, { reflectance = 0.12 })
		ball(model, "Candle", 0.5, Vector3.new(0, topY + 1.75, upFront + 0.35), spec.accent,
			{ material = Enum.Material.Neon, shadow = false })
	end

	-- lever on the player's right, which is model -X since the front faces -Z
	-- (its own model so it can be pulled)
	local lx = -(W / 2)
	local lever = new("Model", { Name = "Lever" }, model)
	local hub = cylX(lever, "Hub", 0.55, 0.25, Vector3.new(lx - 0.12, deckY + 0.9, 0), P.Gold, { reflectance = 0.12 })
	local arm = part(lever, "Arm", Vector3.new(0.13, 1.7, 0.13), CFrame.new(lx - 0.24, deckY + 1.75, 0), P.Chrome,
		{ reflectance = 0.25, material = Enum.Material.Metal })
	ball(lever, "Knob", 0.48, Vector3.new(lx - 0.24, deckY + 2.62, 0), P.NeonRed, { reflectance = 0.1 })
	lever.PrimaryPart = hub
	local _ = arm

	addSounds(body)
	return model
end

------------------------------------------------------------------
-- ROULETTE TABLE
------------------------------------------------------------------
local REDS = { [1] = true, [3] = true, [5] = true, [7] = true, [9] = true, [12] = true, [14] = true, [16] = true,
	[18] = true, [19] = true, [21] = true, [23] = true, [25] = true, [27] = true, [30] = true, [32] = true,
	[34] = true, [36] = true }

-- ink (optional): { line, text, zero, red, black } colours of the print
-- (defaults: white lines and numbers on green / crimson / black cells)
local function rouletteLayout(gui, feltColor, ink)
	ink = ink or {}
	local lineCol, textCol = ink.line or P.White, ink.text or P.White
	local redCol, blackCol = ink.red or P.Crimson, ink.black or hex("#231C20")
	local root = new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) }, gui)
	new("UIPadding", { PaddingLeft = UDim.new(0.02, 0), PaddingRight = UDim.new(0.02, 0),
		PaddingTop = UDim.new(0.04, 0), PaddingBottom = UDim.new(0.04, 0) }, root)
	local function cell(parent, text, pos, size, fill)
		local f = new("Frame", { BackgroundColor3 = fill, Position = pos, Size = size, BorderSizePixel = 0 }, parent)
		new("UIStroke", { Color = lineCol, Thickness = 3, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, f)
		local l = new("TextLabel", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Text = text,
			Font = Enum.Font.GothamBlack, TextScaled = true, TextColor3 = textCol }, f)
		new("UIPadding", { PaddingTop = UDim.new(0.18, 0), PaddingBottom = UDim.new(0.18, 0) }, l)
		return f
	end
	local felt = feltColor or P.Felt
	-- zero spans the three number rows on the left
	cell(root, "0", UDim2.fromScale(0, 0), UDim2.fromScale(0.07, 0.72), ink.zero or hex("#24A046"))
	for col = 0, 11 do
		for row = 0, 2 do
			local n = col * 3 + (3 - row)
			cell(root, tostring(n), UDim2.fromScale(0.07 + col * 0.0775, row * 0.24),
				UDim2.fromScale(0.0775, 0.24), REDS[n] and redCol or blackCol)
		end
	end
	local outside = { "1-18", "EVEN", "RED", "BLACK", "ODD", "19-36" }
	for i, t in outside do
		local fill = (t == "RED" and redCol) or (t == "BLACK" and blackCol) or felt
		cell(root, t, UDim2.fromScale(0.07 + (i - 1) * 0.155, 0.74), UDim2.fromScale(0.155, 0.26), fill)
	end
end

-- spec (all optional): felt, body, rail, glow, title colours as before, plus
-- railMaterial, pedestal, bowl, ballColor, ballMaterial, limitFill and
-- layout (the print's ink, see rouletteLayout) for the dressed-up versions
local function rouletteTable(def, spec)
	spec = spec or {}
	local feltCol = spec.felt or P.Felt
	local model = new("Model", { Name = def.name })
	local bulbs = new("Folder", { Name = "Bulbs" }, model)
	local L, Wd = 4.2, 4.6       -- straight length + width of the stadium top
	local topY = 3.0

	-- ink plinth + two wooden pedestals with gold bands
	part(model, "Plinth", Vector3.new(6.2, 0.4, 3.2), CFrame.new(0, 0.2, 0), P.Ink, { solid = true })
	gold(model, "PlinthLip", Vector3.new(6.34, 0.1, 3.34), CFrame.new(0, 0.38, 0))
	neon(model, "Underglow", Vector3.new(5.9, 0.07, 0.05), CFrame.new(0, 0.14, -1.625), spec.glow or P.NeonGreen)
	for _, sx in { -1, 1 } do
		part(model, "Pedestal", Vector3.new(1.0, 2.1, 2.2), CFrame.new(sx * 2.0, 0.4 + 1.05, 0), spec.pedestal or P.Wood,
			{ solid = true })
		gold(model, "PedestalBand", Vector3.new(1.1, 0.16, 2.3), CFrame.new(sx * 2.0, 2.25, 0))
	end

	-- table body, padded leather rail, gold trim, felt
	local body = stadium(model, "Body", L, Wd, 0.55, Vector3.new(0, topY - 0.3, 0), spec.body or P.WoodDark, { solid = true })
	model.PrimaryPart = body
	stadium(model, "Rail", L, Wd + 0.35, 0.36, Vector3.new(0, topY + 0.12, 0), spec.rail or P.Leather,
		{ material = spec.railMaterial or Enum.Material.Leather })
	stadium(model, "FeltTrim", L, Wd - 0.12, 0.04, Vector3.new(0, topY + 0.3, 0), P.Gold, { reflectance = 0.12 })
	stadium(model, "Felt", L, Wd - 0.3, 0.06, Vector3.new(0, topY + 0.32, 0), feltCol, { material = Enum.Material.Fabric })
	local surfaceY = topY + 0.35

	-- wheel well at the player's left end (model +X): wooden bowl, gold lip,
	-- spinning wheel + turret + ball. The layout's 0 sits next to it.
	local wx = L / 2
	cylY(model, "Bowl", 3.3, 0.36, Vector3.new(wx, surfaceY + 0.16, 0), spec.bowl or P.Wood)
	cylY(model, "BowlLip", 3.5, 0.1, Vector3.new(wx, surfaceY + 0.34, 0), P.Gold, { reflectance = 0.15 })
	local wheel = cylY(model, "Wheel", 3.0, 0.06, Vector3.new(wx, surfaceY + 0.4, 0), P.White)
	new("Decal", { Face = Enum.NormalId.Right, Texture = MachineModels.Textures.roulette }, wheel)
	cylY(model, "Turret", 0.34, 0.42, Vector3.new(wx, surfaceY + 0.62, 0), P.Gold, { reflectance = 0.2 })
	ball(model, "TurretKnob", 0.3, Vector3.new(wx, surfaceY + 0.86, 0), P.GoldTop, { reflectance = 0.2 })
	ball(model, "Ball", 0.16, Vector3.new(wx - 1.22, surfaceY + 0.48, 0), spec.ballColor or P.White,
		{ reflectance = 0.3, material = spec.ballMaterial, shadow = spec.ballMaterial ~= Enum.Material.Neon })

	-- betting layout printed on the felt (the other half)
	local layout = flatPrint(model, "Layout", 3.6, 2.9, CFrame.new(-1.45, surfaceY + 0.01, 0.05))
	local lg = surface(layout, Enum.NormalId.Top, 100, 0.3)
	rouletteLayout(lg, feltCol, spec.layout)

	-- chip rack on the dealer side + a few stacks on the felt
	part(model, "ChipRack", Vector3.new(1.8, 0.2, 0.55), CFrame.new(-0.2, surfaceY + 0.1, 1.72), P.Ink)
	local chipCols = { P.Crimson, hex("#1E9BEA"), P.Gold, hex("#36C23A"), P.White }
	for i, c in chipCols do
		for k = 0, 3 do
			cylY(model, "Chip", 0.32, 0.07, Vector3.new(-0.9 + (i - 1) * 0.34, surfaceY + 0.24 + k * 0.075, 1.72), c, { shadow = false })
		end
	end
	for i, spot in { Vector3.new(-0.9, 0, -0.5), Vector3.new(-2.4, 0, 0.4), Vector3.new(-1.6, 0, -1.0) } do
		for k = 0, i do
			cylY(model, "Chip", 0.32, 0.07, Vector3.new(spot.X, surfaceY + 0.05 + k * 0.075, spot.Z), chipCols[i], { shadow = false })
		end
	end

	-- limit sign on the dealer side
	local sign = gold(model, "LimitSign", Vector3.new(1.5, 0.75, 0.1), CFrame.new(-2.6, surfaceY + 0.55, 1.85))
	gold(model, "LimitPost", Vector3.new(0.1, 0.4, 0.1), CFrame.new(-2.6, surfaceY + 0.2, 1.85))
	local sg = surface(sign, Enum.NormalId.Front, 120, 0.1)
	local plate = signPlate(sg, spec.limitFill or P.Felt)
	guiText(plate, ("$%d - $%d"):format(def.minBet or 0, def.maxBet or 0), { size = UDim2.fromScale(0.86, 0.6),
		position = UDim2.fromScale(0.07, 0.2), strokeThickness = 4 })

	-- marquee bulbs along the front of the rail
	bulbsAlong(bulbs, Vector3.new(-L / 2, topY + 0.12, -(Wd + 0.35) / 2 - 0.05), Vector3.new(L / 2, topY + 0.12, -(Wd + 0.35) / 2 - 0.05), 12, 0.14)
	return model
end

------------------------------------------------------------------
-- more kit: half discs (CSG), signs, canopies, dice, cards
------------------------------------------------------------------
-- half disc lying flat; the straight edge runs along X through `centre`, the
-- round side bulges toward the FRONT (-Z). Falls back to a full disc if CSG fails.
local function halfDisc(parent, name, radius, height, centre: Vector3, color, opts)
	local disc = cylY(nil, name, radius * 2, height, centre, color, table.clone(opts or {}))
	local cutter = Instance.new("Part")
	cutter.Anchored = true
	cutter.Size = Vector3.new(radius * 2 + 2, height + 2, radius + 2)
	cutter.CFrame = CFrame.new(centre + Vector3.new(0, 0, (radius + 2) / 2))
	local ok, res = pcall(function()
		return GeometryService:SubtractAsync(disc, { cutter }, { SplitApart = false })
	end)
	cutter:Destroy()
	if ok and res and res[1] then
		local u = res[1]
		u.Name = name
		u.Anchored = true
		u.UsePartColor = true
		u.Color = color
		u.Material = (opts and opts.material) or Enum.Material.SmoothPlastic
		u.Reflectance = (opts and opts.reflectance) or 0
		u.CanCollide = (opts and opts.solid) == true
		u.CanQuery = u.CanCollide
		u.CanTouch = false
		u.Parent = parent
		disc:Destroy()
		return u
	end
	disc.Parent = parent
	return disc
end

-- a rounded sign board: gold body + crimson/coloured plate with a title
-- (and optionally an icon on the left). Returns the board part.
local function boardSign(parent, name, size: Vector3, cf: CFrame, title: string, opts)
	opts = opts or {}
	local board = gold(parent, name, size, cf)
	for _, face in (opts.bothSides and { Enum.NormalId.Front, Enum.NormalId.Back } or { Enum.NormalId.Front }) do
		local g = surface(board, face, opts.ppu or 100, 0.05)
		local plate = signPlate(g, opts.fill or P.CrimsonDeep)
		if opts.drawIcon then
			-- a GUI-drawn icon (e.g. a die) in the icon slot
			opts.drawIcon(plate, UDim2.fromScale(0.16, 0.5))
			guiText(plate, title, { size = UDim2.fromScale(0.62, 0.62), position = UDim2.fromScale(0.34, 0.19),
				gradient = { P.GoldTop, P.Gold }, strokeThickness = opts.stroke or 6 })
		elseif opts.icon then
			guiImage(plate, opts.icon, { size = UDim2.fromScale(0.3, 1.15), position = UDim2.fromScale(0.16, 0.5) })
			guiText(plate, title, { size = UDim2.fromScale(0.62, 0.62), position = UDim2.fromScale(0.34, 0.19),
				gradient = { P.GoldTop, P.Gold }, strokeThickness = opts.stroke or 6 })
		else
			guiText(plate, title, { size = UDim2.fromScale(0.86, 0.62), position = UDim2.fromScale(0.07, 0.19),
				gradient = { P.GoldTop, P.Gold }, strokeThickness = opts.stroke or 6 })
		end
	end
	return board
end

-- striped canopy sloping down toward the front, with scalloped discs hanging
-- off its front edge. Spans x in [-w/2, w/2], from zBack to zFront.
local function canopy(parent, w: number, yBack: number, zBack: number, zFront: number, drop: number, colors)
	local depth = zBack - zFront
	local slopeLen = math.sqrt(depth * depth + drop * drop)
	local tilt = math.atan2(drop, depth)
	local strips = math.max(4, math.floor(w / 0.6))
	local sw = w / strips
	local mid = Vector3.new(0, yBack - drop / 2, (zBack + zFront) / 2)
	for i = 1, strips do
		local x = -w / 2 + sw * (i - 0.5)
		part(parent, "Canopy", Vector3.new(sw + 0.01, 0.1, slopeLen),
			CFrame.new(x, mid.Y, mid.Z) * CFrame.Angles(-tilt, 0, 0), colors[(i - 1) % #colors + 1])
	end
	local yFront = yBack - drop
	for i = 1, strips do
		local x = -w / 2 + sw * (i - 0.5)
		cylZ(parent, "Scallop", sw * 0.98, 0.08, Vector3.new(x, yFront - 0.02, zFront - 0.02), colors[(i - 1) % #colors + 1],
			{ shadow = false })
	end
	gold(parent, "CanopyTrim", Vector3.new(w + 0.1, 0.1, 0.1), CFrame.new(0, yFront + 0.04, zFront))
end

-- dice faces (standard: opposite faces add up to 7)
local PIPS = {
	[1] = { { 0.5, 0.5 } },
	[2] = { { 0.27, 0.27 }, { 0.73, 0.73 } },
	[3] = { { 0.25, 0.25 }, { 0.5, 0.5 }, { 0.75, 0.75 } },
	[4] = { { 0.27, 0.27 }, { 0.73, 0.27 }, { 0.27, 0.73 }, { 0.73, 0.73 } },
	[5] = { { 0.25, 0.25 }, { 0.75, 0.25 }, { 0.5, 0.5 }, { 0.25, 0.75 }, { 0.75, 0.75 } },
	[6] = { { 0.27, 0.22 }, { 0.73, 0.22 }, { 0.27, 0.5 }, { 0.73, 0.5 }, { 0.27, 0.78 }, { 0.73, 0.78 } },
}
local DIE_FACES = { Top = 1, Bottom = 6, Front = 2, Back = 5, Right = 3, Left = 4 }
local function die(parent, name, size, cf: CFrame, pipColor)
	local d = part(parent, name, Vector3.new(size, size, size), cf, P.White, { reflectance = 0.05 })
	for faceName, value in DIE_FACES do
		local g = surface(d, Enum.NormalId[faceName], 120, 0.3)
		for _, xy in PIPS[value] do
			local pip = new("Frame", {
				BackgroundColor3 = (value == 1) and P.Crimson or (pipColor or P.Ink), AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(xy[1], xy[2]), Size = UDim2.fromScale(0.2, 0.2),
			}, g)
			new("UICorner", { CornerRadius = UDim.new(0.5, 0) }, pip)
		end
	end
	return d
end

-- a die face drawn in GUI (sign icon): white rounded square, five pips
local function dieIcon(parent, position: UDim2)
	local f = new("Frame", {
		BackgroundColor3 = P.White, AnchorPoint = Vector2.new(0.5, 0.5), Position = position,
		Size = UDim2.fromScale(0.9, 0.9), SizeConstraint = Enum.SizeConstraint.RelativeYY, Rotation = -12, ZIndex = 2,
	}, parent)
	new("UICorner", { CornerRadius = UDim.new(0.22, 0) }, f)
	new("UIStroke", { Color = P.Ink, Thickness = 5, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, f)
	for i, xy in PIPS[5] do
		local pip = new("Frame", {
			BackgroundColor3 = (i == 3) and P.Crimson or P.Ink, AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(xy[1], xy[2]), Size = UDim2.fromScale(0.2, 0.2), ZIndex = 3,
		}, f)
		new("UICorner", { CornerRadius = UDim.new(0.5, 0) }, pip)
	end
	return f
end

-- a playing card lying on the felt
local function playingCard(parent, pos: Vector3, yaw: number, label: string, red: boolean)
	-- long side along Z; turned like flatPrint so the rank reads upright
	local c = part(parent, "Card", Vector3.new(0.6, 0.015, 0.42),
		CFrame.new(pos) * CFrame.Angles(0, math.rad(yaw + 90), 0), P.White, { shadow = false })
	local g = surface(c, Enum.NormalId.Top, 160, 0.4)
	local f = new("Frame", { BackgroundColor3 = P.White, Size = UDim2.new(1, -6, 1, -6), Position = UDim2.fromOffset(3, 3) }, g)
	new("UICorner", { CornerRadius = UDim.new(0.12, 0) }, f)
	new("UIStroke", { Color = P.CreamLine or P.Gold, Thickness = 2, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, f)
	guiText(f, label, { size = UDim2.fromScale(0.8, 0.5), position = UDim2.fromScale(0.1, 0.25),
		color = red and P.Crimson or P.Ink, stroke = false })
	return c
end

local function chipStack(parent, pos: Vector3, count: number, color: Color3)
	for k = 0, count - 1 do
		cylY(parent, "Chip", 0.32, 0.07, pos + Vector3.new(0, 0.035 + k * 0.075, 0), color, { shadow = false })
	end
end

------------------------------------------------------------------
-- BLACKJACK TABLE (half moon, dealer counter at the back)
------------------------------------------------------------------
local function blackjackTable(def, spec)
	spec = spec or {}
	local feltCol = spec.felt or P.FeltBlue
	local model = new("Model", { Name = def.name })
	local bulbs = new("Folder", { Name = "Bulbs" }, model)
	local R, zc, topY = 3.7, 1.0, 3.0

	part(model, "Plinth", Vector3.new(6.6, 0.4, 2.6), CFrame.new(0, 0.2, -0.4), P.Ink, { solid = true })
	gold(model, "PlinthLip", Vector3.new(6.74, 0.1, 2.74), CFrame.new(0, 0.38, -0.4))
	neon(model, "Underglow", Vector3.new(6.3, 0.07, 0.05), CFrame.new(0, 0.14, -1.725), spec.glow or P.NeonBlue)
	for _, sx in { -1, 1 } do
		part(model, "Pedestal", Vector3.new(1.0, 2.1, 1.8), CFrame.new(sx * 2.2, 1.45, -0.4), P.Wood, { solid = true })
		gold(model, "PedestalBand", Vector3.new(1.1, 0.16, 1.9), CFrame.new(sx * 2.2, 2.25, -0.4))
	end

	halfDisc(model, "Body", R, 0.55, Vector3.new(0, topY - 0.3, zc), P.WoodDark, { solid = true })
	halfDisc(model, "Rail", R + 0.22, 0.36, Vector3.new(0, topY + 0.12, zc), P.Leather, { material = Enum.Material.Leather })
	halfDisc(model, "FeltTrim", R - 0.12, 0.04, Vector3.new(0, topY + 0.3, zc), P.Gold, { reflectance = 0.12 })
	halfDisc(model, "Felt", R - 0.28, 0.06, Vector3.new(0, topY + 0.32, zc), feltCol, { material = Enum.Material.Fabric })
	local surfaceY = topY + 0.35

	-- dealer counter along the flat edge, chip tray and card shoe on top
	-- the counter is the PrimaryPart: upright and facing -Z, so NPCs line up in
	-- front of the table and the prompt sits at the dealer (the half-moon
	-- unions are rotated cylinders and would skew LookVector/bounding boxes)
	local counter = part(model, "Counter", Vector3.new(2 * R + 0.7, 0.95, 0.9), CFrame.new(0, topY + 0.08, zc + 0.45), P.WoodDark, { solid = true })
	model.PrimaryPart = counter
	gold(model, "CounterTrim", Vector3.new(2 * R + 0.8, 0.1, 1.0), CFrame.new(0, topY + 0.58, zc + 0.45))
	part(model, "ChipTray", Vector3.new(2.8, 0.14, 0.62), CFrame.new(-0.4, topY + 0.68, zc + 0.45), P.Ink)
	local chipCols = { P.Crimson, hex("#1E9BEA"), P.Gold, hex("#36C23A"), P.White, hex("#8A4DE8") }
	for i, c in chipCols do
		chipStack(model, Vector3.new(-1.55 + (i - 1) * 0.46, topY + 0.72, zc + 0.45), 4, c)
	end
	part(model, "Shoe", Vector3.new(0.8, 0.45, 0.52), CFrame.new(2.5, topY + 0.9, zc + 0.45), P.Crimson)
	part(model, "ShoeCards", Vector3.new(0.7, 0.36, 0.06), CFrame.new(2.5, topY + 0.92, zc + 0.18), P.White, { shadow = false })

	-- felt print: title arc + rules line
	local printPart = flatPrint(model, "FeltPrint", 4.4, 1.2, CFrame.new(0, surfaceY + 0.012, zc - 1.0), feltCol)
	local pg = surface(printPart, Enum.NormalId.Top, 90, 0.3)
	guiText(pg, "BLACKJACK PAYS 3 TO 2", { size = UDim2.fromScale(1, 0.5), color = P.Gold, strokeThickness = 3 })
	guiText(pg, "DEALER STANDS ON 17", { size = UDim2.fromScale(0.8, 0.32), position = UDim2.fromScale(0.1, 0.6),
		font = Enum.Font.GothamBlack, color = P.White, stroke = false })

	-- five seats: betting ring, chips, two cards each
	local ranks = { "A", "K", "Q", "J", "10", "9", "7" }
	for i = 1, 5 do
		local a = math.rad(-60 + (i - 1) * 30)
		local r = R - 1.05
		local pos = Vector3.new(r * math.sin(a), surfaceY, zc - r * math.cos(a))
		cylY(model, "Spot", 0.82, 0.02, pos + Vector3.new(0, 0.006, 0), P.White, { shadow = false })
		cylY(model, "SpotInner", 0.68, 0.025, pos + Vector3.new(0, 0.01, 0), feltCol,
			{ shadow = false, material = Enum.Material.Fabric })
		chipStack(model, pos + Vector3.new(0, 0.02, 0), 1 + (i % 3), chipCols[i])
		local inward = Vector3.new(-math.sin(a), 0, math.cos(a)) * 0.75
		playingCard(model, pos + inward + Vector3.new(-0.12, 0.02, 0), math.deg(-a) + 8, ranks[i], i % 2 == 0)
		playingCard(model, pos + inward + Vector3.new(0.14, 0.035, 0.04), math.deg(-a) - 6, ranks[i + 2], i % 2 == 1)
	end
	-- dealer hand
	playingCard(model, Vector3.new(-0.25, surfaceY + 0.02, zc - 0.35), 4, "A", true)
	playingCard(model, Vector3.new(0.25, surfaceY + 0.02, zc - 0.35), -5, "K", false)

	-- bulbs around the curved rail
	for k = 0, 14 do
		local a = math.rad(-84 + k * 12)
		local rr = R + 0.25
		local bulb = ball(bulbs, "Bulb", 0.14, Vector3.new(rr * math.sin(a), topY + 0.12, zc - rr * math.cos(a)),
			(k % 2 == 0) and P.GoldTop or P.White, { material = Enum.Material.Neon, shadow = false })
		bulb:SetAttribute("Phase", k % 2)
	end
	return model
end

------------------------------------------------------------------
-- DICE (arcade cabinet with a glass dome and two big dice)
------------------------------------------------------------------
local function diceGame(def)
	local model = new("Model", { Name = def.name })
	local bulbs = new("Folder", { Name = "Bulbs" }, model)
	local col = hex("#FF8A1F")
	local h0 = plinth(model, 3.9, 3.0, P.Amber)

	local body = part(model, "Body", Vector3.new(3.4, 2.1, 2.5), CFrame.new(0, h0 + 1.05, 0), col, { solid = true })
	model.PrimaryPart = body
	local front = part(model, "FrontPanel", Vector3.new(2.7, 1.2, 0.08), CFrame.new(0, h0 + 1.0, -1.29), col:Lerp(P.Ink, 0.3))
	local fg = surface(front, Enum.NormalId.Front, 100, 0.1)
	local plate = signPlate(fg, P.CrimsonDeep)
	guiText(plate, "LUCKY DICE", { size = UDim2.fromScale(0.86, 0.55), position = UDim2.fromScale(0.07, 0.22),
		gradient = { P.GoldTop, P.Gold }, strokeThickness = 6 })
	for _, sx in { -1, 1 } do
		gold(model, "EdgeTrim", Vector3.new(0.14, 2.1, 0.14), CFrame.new(sx * 1.7, h0 + 1.05, -1.25))
	end
	-- control deck with a big roll button
	gold(model, "Deck", Vector3.new(3.5, 0.2, 0.75), CFrame.new(0, h0 + 2.2, -1.0))
	cylY(model, "RollButton", 0.62, 0.14, Vector3.new(0.85, h0 + 2.36, -1.05), P.NeonGreen,
		{ material = Enum.Material.Neon, shadow = false })
	cylY(model, "Button2", 0.3, 0.1, Vector3.new(-0.9, h0 + 2.34, -1.05), P.NeonRed, { material = Enum.Material.Neon, shadow = false })

	-- felt pad, gold ring and the glass dome with two dice inside
	local padY = h0 + 2.25
	cylY(model, "DomeRing", 2.9, 0.22, Vector3.new(0, padY + 0.1, 0.25), P.Gold, { reflectance = 0.15 })
	cylY(model, "Pad", 2.55, 0.08, Vector3.new(0, padY + 0.24, 0.25), P.Felt, { material = Enum.Material.Fabric })
	-- a clear bubble (Glass reads milky under bloom and hid the dice)
	ball(model, "Dome", 2.7, Vector3.new(0, padY + 0.25, 0.25), hex("#CFEFFF"),
		{ transparency = 0.88, reflectance = 0.3, shadow = false })
	die(model, "Die1", 0.78, CFrame.new(-0.5, padY + 0.67, 0.1) * CFrame.Angles(0, math.rad(20), 0))
	die(model, "Die2", 0.78, CFrame.new(0.5, padY + 0.67, 0.45) * CFrame.Angles(0, math.rad(-35), 0))
	-- topper sign behind the dome
	boardSign(model, "Topper", Vector3.new(3.2, 0.9, 0.3), CFrame.new(0, padY + 2.0, 1.15), "DICE", { drawIcon = dieIcon })
	bulbsAlong(bulbs, Vector3.new(-1.6, padY + 2.5, 0.98), Vector3.new(1.6, padY + 2.5, 0.98), 9)
	return model
end

------------------------------------------------------------------
-- WHEEL OF FORTUNE (big upright prize wheel)
------------------------------------------------------------------
local function fortuneWheel(def, spec)
	spec = spec or {}
	local model = new("Model", { Name = def.name })
	local bulbs = new("Folder", { Name = "Bulbs" }, model)
	local h0 = plinth(model, 4.8, 2.6, spec.glow or P.GoldTop)
	local col = hex("#FFCB2E")

	local bodyCol = spec.body or P.Crimson
	local body = part(model, "Body", Vector3.new(3.6, 1.3, 1.8), CFrame.new(0, h0 + 0.65, 0.2), bodyCol, { solid = true })
	model.PrimaryPart = body
	gold(model, "BodyTrim", Vector3.new(3.7, 0.12, 1.9), CFrame.new(0, h0 + 1.3, 0.2))
	local fp = part(model, "FrontPanel", Vector3.new(3.0, 0.9, 0.06), CFrame.new(0, h0 + 0.65, -0.72), P.CrimsonDeep)
	local fg = surface(fp, Enum.NormalId.Front, 100, 0.1)
	local plate = signPlate(fg, P.CrimsonDeep)
	guiText(plate, "SPIN TO WIN", { size = UDim2.fromScale(0.86, 0.6), position = UDim2.fromScale(0.07, 0.2),
		gradient = { P.GoldTop, P.Gold }, strokeThickness = 6 })
	-- post holding the wheel
	part(model, "Post", Vector3.new(0.7, 4.2, 0.7), CFrame.new(0, h0 + 1.3 + 2.1, 0.55), bodyCol, { solid = true })
	gold(model, "PostTrim", Vector3.new(0.8, 0.14, 0.8), CFrame.new(0, h0 + 3.3, 0.55))

	local cy = h0 + 4.15
	local R = 2.5
	cylZ(model, "Rim", R * 2 + 0.45, 0.3, Vector3.new(0, cy, 0.2), col, { reflectance = 0.15 })
	cylZ(model, "RimBack", R * 2 + 0.6, 0.18, Vector3.new(0, cy, 0.38), P.Ink)
	local wheel = cylZ(model, "Wheel", R * 2, 0.16, Vector3.new(0, cy, 0.0), P.White)
	new("Decal", { Face = Enum.NormalId.Right, Texture = MachineModels.Textures.fortune }, wheel)
	cylZ(model, "Hub", 0.75, 0.3, Vector3.new(0, cy, -0.18), P.Gold, { reflectance = 0.2 })
	ball(model, "HubCap", 0.5, Vector3.new(0, cy, -0.3), P.GoldTop, { reflectance = 0.2 })
	-- bulbs around the rim
	for k = 0, 19 do
		local a = math.rad(k * 18)
		local bulb = ball(bulbs, "Bulb", 0.2, Vector3.new(math.cos(a) * (R + 0.12), cy + math.sin(a) * (R + 0.12), -0.02),
			(k % 2 == 0) and P.GoldTop or P.White, { material = Enum.Material.Neon, shadow = false })
		bulb:SetAttribute("Phase", k % 2)
	end
	-- pointer at the top (a red wedge pointing down) on a gold block
	gold(model, "PointerBase", Vector3.new(0.6, 0.45, 0.5), CFrame.new(0, cy + R + 0.5, -0.1))
	local pointer = new("WedgePart", {
		Name = "Pointer", Anchored = true, Size = Vector3.new(0.18, 0.7, 0.5), Color = P.NeonRed,
		Material = Enum.Material.SmoothPlastic, CanCollide = false, CanQuery = false, CanTouch = false,
		CFrame = CFrame.new(0, cy + R + 0.05, -0.18) * CFrame.Angles(math.rad(180), 0, 0) * CFrame.Angles(0, math.rad(90), 0),
	}, model)
	local _ = pointer
	boardSign(model, "Topper", Vector3.new(3.6, 0.85, 0.3), CFrame.new(0, cy + R + 1.25, 0.15), spec.title or "LUCKY WHEEL",
		{ icon = spec.icon or "star", fill = spec.signFill })
	return model
end

------------------------------------------------------------------
-- CONCESSIONS
------------------------------------------------------------------
local function snackStand(def)
	local model = new("Model", { Name = def.name })
	local bulbs = new("Folder", { Name = "Bulbs" }, model)
	local h0 = plinth(model, 4.8, 2.9, P.Amber)
	-- striped counter
	local body = part(model, "Body", Vector3.new(4.4, 1.5, 2.2), CFrame.new(0, h0 + 0.75, 0.15), P.White, { solid = true })
	model.PrimaryPart = body
	for i = 0, 7 do
		part(model, "Stripe", Vector3.new(0.55, 1.5, 0.04), CFrame.new(-1.925 + i * 0.55, h0 + 0.75, -0.97),
			(i % 2 == 0) and P.Crimson or P.White)
	end
	gold(model, "CounterTop", Vector3.new(4.6, 0.16, 2.4), CFrame.new(0, h0 + 1.58, 0.15))
	-- popcorn machine on the counter
	local pmY = h0 + 1.66
	part(model, "PopperBase", Vector3.new(1.3, 0.3, 1.0), CFrame.new(-1.0, pmY + 0.15, 0.25), P.Crimson)
	part(model, "PopperGlass", Vector3.new(1.2, 1.2, 0.95), CFrame.new(-1.0, pmY + 0.9, 0.25), hex("#DFF4FF"),
		{ material = Enum.Material.Glass, transparency = 0.6, shadow = false })
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			part(model, "PopperEdge", Vector3.new(0.08, 1.2, 0.08), CFrame.new(-1.0 + sx * 0.6, pmY + 0.9, 0.25 + sz * 0.47), P.Crimson)
		end
	end
	part(model, "PopperRoof", Vector3.new(1.4, 0.25, 1.1), CFrame.new(-1.0, pmY + 1.62, 0.25), P.Crimson)
	ball(model, "PopperKnob", 0.3, Vector3.new(-1.0, pmY + 1.85, 0.25), P.Gold, { reflectance = 0.2 })
	local corn = hex("#FFF1B8")
	for k = 0, 22 do
		local x = -1.0 + ((k * 37) % 9 - 4) * 0.12
		local z = 0.25 + ((k * 53) % 7 - 3) * 0.11
		local y = pmY + 0.45 + (k % 4) * 0.12
		ball(model, "Popcorn", 0.22, Vector3.new(x, y, z), (k % 5 == 0) and P.GoldTop or corn, { shadow = false })
	end
	-- a couple of popcorn buckets on the counter
	for i, x in { 0.6, 1.3 } do
		cylY(model, "Bucket", 0.45, 0.55, Vector3.new(x, pmY + 0.28, -0.35 + i * 0.15), P.Crimson)
		ball(model, "BucketTop", 0.42, Vector3.new(x, pmY + 0.6, -0.35 + i * 0.15), corn, { shadow = false })
	end
	-- posts + striped canopy + sign
	for _, sx in { -1, 1 } do
		cylY(model, "Post", 0.16, 2.0, Vector3.new(sx * 2.05, h0 + 1.66 + 1.0, 1.1), P.Gold, { reflectance = 0.15 })
	end
	canopy(model, 4.8, h0 + 3.75, 1.3, -1.15, 0.7, { P.Crimson, P.White })
	boardSign(model, "Sign", Vector3.new(3.2, 0.95, 0.25), CFrame.new(0, h0 + 4.35, 1.2), "SNACKS",
		{ icon = "popcorn", bothSides = true })
	bulbsAlong(bulbs, Vector3.new(-2.3, h0 + 3.0, -1.2), Vector3.new(2.3, h0 + 3.0, -1.2), 10)
	return model
end

local function drinkBar(def)
	local model = new("Model", { Name = def.name })
	local bulbs = new("Folder", { Name = "Bulbs" }, model)
	local h0 = plinth(model, 5.9, 3.0, P.NeonBlue)
	-- bar counter (front) with neon underlight and a sign panel
	local body = part(model, "Body", Vector3.new(5.5, 1.6, 1.2), CFrame.new(0, h0 + 0.8, -0.75), P.WoodDark, { solid = true })
	model.PrimaryPart = body
	gold(model, "BarTop", Vector3.new(5.7, 0.14, 1.4), CFrame.new(0, h0 + 1.67, -0.75))
	neon(model, "BarGlow", Vector3.new(5.3, 0.08, 0.05), CFrame.new(0, h0 + 1.5, -1.38), P.NeonBlue)
	local fp = part(model, "FrontPanel", Vector3.new(3.2, 0.95, 0.06), CFrame.new(0, h0 + 0.85, -1.38), P.WoodDark)
	local fg = surface(fp, Enum.NormalId.Front, 100, 0.1)
	local plate = signPlate(fg, hex("#0F5A99"))
	guiText(plate, "ICE COLD SODA", { size = UDim2.fromScale(0.86, 0.6), position = UDim2.fromScale(0.07, 0.2),
		gradient = { P.GoldTop, P.Gold }, strokeThickness = 6 })
	-- a soda fountain on the counter (soft drinks only: Roblox's community
	-- standards don't allow alcohol, so no bottles, taps or cocktail glasses)
	local fx = -1.3
	part(model, "Fountain", Vector3.new(2.0, 1.5, 0.9), CFrame.new(fx, h0 + 2.49, -0.45), P.Chrome,
		{ reflectance = 0.25, material = Enum.Material.Metal })
	for i, c in { hex("#D7263D"), hex("#3DFF6E"), hex("#FF8A1F") } do
		neon(model, "Flavor", Vector3.new(0.5, 0.55, 0.05), CFrame.new(fx - 0.65 + (i - 1) * 0.65, h0 + 2.7, -0.92), c)
		cylY(model, "Nozzle", 0.14, 0.2, Vector3.new(fx - 0.65 + (i - 1) * 0.65, h0 + 2.2, -0.85), P.Ink)
	end
	part(model, "DripTray", Vector3.new(2.0, 0.08, 0.5), CFrame.new(fx, h0 + 1.78, -0.95), P.Ink)
	-- cups with lids and straws
	for i, c in { hex("#3FC8FF"), hex("#FF4FD0"), hex("#FFC003") } do
		local cx = 0.6 + i * 0.5
		cylY(model, "Cup", 0.34, 0.5, Vector3.new(cx, h0 + 1.99, -0.95), c)
		cylY(model, "Lid", 0.38, 0.06, Vector3.new(cx, h0 + 2.27, -0.95), P.White)
		cylY(model, "Straw", 0.06, 0.4, Vector3.new(cx + 0.05, h0 + 2.47, -0.95), P.White, { shadow = false })
	end
	-- back shelf: rows of colourful soda cans and cup stacks
	part(model, "Shelf", Vector3.new(5.5, 3.0, 0.6), CFrame.new(0, h0 + 1.5, 1.05), P.WoodDark, { solid = true })
	local canCols = { hex("#36C23A"), hex("#D7263D"), hex("#3FC8FF"), hex("#FFC003"), hex("#8A4DE8"), hex("#FF8A1F") }
	for row = 0, 1 do
		local y = h0 + 1.3 + row * 1.0
		gold(model, "ShelfBoard", Vector3.new(5.3, 0.08, 0.45), CFrame.new(0, y, 0.72))
		for k = 0, 9 do
			local x = -2.3 + k * 0.51
			if (k + row) % 4 == 3 then
				for s = 0, 2 do
					cylY(model, "CupStack", 0.32 - s * 0.02, 0.22, Vector3.new(x, y + 0.15 + s * 0.2, 0.7), P.White)
				end
			else
				local c = canCols[(k + row * 3) % #canCols + 1]
				cylY(model, "Can", 0.3, 0.46, Vector3.new(x, y + 0.27, 0.7), c, { reflectance = 0.2 })
				cylY(model, "CanTop", 0.26, 0.04, Vector3.new(x, y + 0.52, 0.7), P.Chrome, { material = Enum.Material.Metal })
			end
		end
	end
	-- neon sign on top of the shelf
	local sign = boardSign(model, "Sign", Vector3.new(3.4, 1.0, 0.25), CFrame.new(0, h0 + 3.6, 1.05), "SODA POP",
		{ fill = hex("#0F5A99"), bothSides = true })
	local _ = sign
	bulbsAlong(bulbs, Vector3.new(-2.7, h0 + 3.02, 0.73), Vector3.new(2.7, h0 + 3.02, 0.73), 12)
	return model
end

local function souvenirCart(def)
	local model = new("Model", { Name = def.name })
	local bulbs = new("Folder", { Name = "Bulbs" }, model)
	local col = P.Crimson
	-- no plinth: it's a cart on wheels
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			cylX(model, "Wheel", 0.9, 0.25, Vector3.new(sx * 1.75, 0.45, sz * 0.8), P.Ink)
			cylX(model, "Hub", 0.4, 0.28, Vector3.new(sx * 1.75, 0.45, sz * 0.8), P.Gold, { reflectance = 0.2 })
		end
	end
	local body = part(model, "Body", Vector3.new(3.8, 1.4, 2.1), CFrame.new(0, 1.55, 0), col, { solid = true })
	model.PrimaryPart = body
	gold(model, "BodyTrimTop", Vector3.new(3.95, 0.14, 2.25), CFrame.new(0, 2.28, 0))
	gold(model, "BodyTrimBottom", Vector3.new(3.95, 0.12, 2.25), CFrame.new(0, 0.86, 0))
	local fp = part(model, "FrontPanel", Vector3.new(2.8, 0.9, 0.06), CFrame.new(0, 1.55, -1.08), col:Lerp(P.Ink, 0.3))
	local fg = surface(fp, Enum.NormalId.Front, 100, 0.1)
	local plate = signPlate(fg, P.CrimsonDeep)
	guiText(plate, "GIFTS", { size = UDim2.fromScale(0.86, 0.62), position = UDim2.fromScale(0.07, 0.19),
		gradient = { P.GoldTop, P.Gold }, strokeThickness = 6 })
	-- push handle
	cylX(model, "Handle", 0.14, 1.6, Vector3.new(2.55, 2.1, 0), P.Chrome, { reflectance = 0.3, material = Enum.Material.Metal })
	-- goodies on top: gift boxes, plushies, a mini slot machine toy
	local topY = 2.35
	local gifts = { { -1.3, -0.4, P.Crimson, P.Gold }, { -0.7, 0.35, hex("#1E9BEA"), P.GoldTop }, { 1.25, -0.35, hex("#36C23A"), P.Crimson } }
	for _, g in gifts do
		local s = 0.55
		part(model, "Gift", Vector3.new(s, s, s), CFrame.new(g[1], topY + s / 2, g[2]) * CFrame.Angles(0, math.rad(15), 0), g[3])
		part(model, "Ribbon", Vector3.new(s + 0.02, s + 0.02, 0.1), CFrame.new(g[1], topY + s / 2, g[2]) * CFrame.Angles(0, math.rad(15), 0), g[4])
		ball(model, "Bow", 0.22, Vector3.new(g[1], topY + s + 0.08, g[2]), g[4])
	end
	for i, c in { hex("#FF8A1F"), hex("#F23FA0") } do
		local x = -0.1 + (i - 1) * 0.65
		ball(model, "Plush", 0.6, Vector3.new(x, topY + 0.3, -0.35), c)
		ball(model, "PlushHead", 0.42, Vector3.new(x, topY + 0.75, -0.35), c)
		ball(model, "PlushEarL", 0.16, Vector3.new(x - 0.15, topY + 0.95, -0.35), c)
		ball(model, "PlushEarR", 0.16, Vector3.new(x + 0.15, topY + 0.95, -0.35), c)
	end
	part(model, "ToySlot", Vector3.new(0.45, 0.7, 0.35), CFrame.new(0.6, topY + 0.35, 0.45), P.Crimson)
	gold(model, "ToySlotTop", Vector3.new(0.5, 0.12, 0.4), CFrame.new(0.6, topY + 0.76, 0.45))
	-- posts, canopy and sign
	for _, sx in { -1, 1 } do
		cylY(model, "Post", 0.14, 2.1, Vector3.new(sx * 1.8, topY + 1.05, 0.95), P.Gold, { reflectance = 0.15 })
	end
	canopy(model, 4.2, topY + 2.15, 1.15, -1.25, 0.6, { hex("#F23FA0"), P.White })
	boardSign(model, "Sign", Vector3.new(3.0, 0.9, 0.25), CFrame.new(0, topY + 2.7, 1.05), "SOUVENIRS",
		{ icon = "gift", bothSides = true })
	bulbsAlong(bulbs, Vector3.new(-1.9, topY + 1.5, -1.25), Vector3.new(1.9, topY + 1.5, -1.25), 9)
	return model
end

local function vendingMachine(def)
	local model = new("Model", { Name = def.name })
	local bulbs = new("Folder", { Name = "Bulbs" }, model)
	local col = hex("#8A4DE8")
	local h0 = plinth(model, 3.2, 2.2, P.NeonPink, 0.3)
	local body = part(model, "Body", Vector3.new(2.8, 4.4, 1.8), CFrame.new(0, h0 + 2.2, 0), col, { solid = true })
	model.PrimaryPart = body
	for _, sx in { -1, 1 } do
		gold(model, "EdgeTrim", Vector3.new(0.14, 4.4, 0.14), CFrame.new(sx * 1.4, h0 + 2.2, -0.9))
	end
	-- glass window with shelves of colourful snacks
	local wx, wy = -0.35, h0 + 2.55
	part(model, "WindowBack", Vector3.new(1.8, 2.9, 0.1), CFrame.new(wx, wy, -0.82), hex("#1B1030"))
	gold(model, "WindowFrame", Vector3.new(1.95, 3.05, 0.06), CFrame.new(wx, wy, -0.88))
	local snackCols = { P.Crimson, hex("#36C23A"), hex("#FFC003"), hex("#1E9BEA"), hex("#F23FA0"), hex("#FF8A1F") }
	for row = 0, 3 do
		local y = wy - 1.15 + row * 0.72
		part(model, "ShelfRail", Vector3.new(1.7, 0.05, 0.3), CFrame.new(wx, y - 0.2, -0.88), P.Chrome,
			{ material = Enum.Material.Metal, shadow = false })
		for k = 0, 3 do
			local c = snackCols[(row * 2 + k) % #snackCols + 1]
			local x = wx - 0.6 + k * 0.4
			if (row + k) % 3 == 0 then
				cylY(model, "Can", 0.26, 0.42, Vector3.new(x, y + 0.03, -0.95), c)
			else
				part(model, "Snack", Vector3.new(0.3, 0.42, 0.12), CFrame.new(x, y + 0.03, -0.96), c)
			end
		end
	end
	part(model, "Glass", Vector3.new(1.8, 2.9, 0.04), CFrame.new(wx, wy, -1.06), hex("#DFF4FF"),
		{ material = Enum.Material.Glass, transparency = 0.75, shadow = false })
	-- control panel: display, keypad, coin slot
	local px = 0.95
	part(model, "Panel", Vector3.new(0.6, 2.6, 0.08), CFrame.new(px, h0 + 2.5, -0.93), col:Lerp(P.Ink, 0.35))
	neon(model, "Display", Vector3.new(0.45, 0.25, 0.04), CFrame.new(px, h0 + 3.5, -0.98), P.NeonGreen)
	for r = 0, 2 do
		for c = 0, 1 do
			cylZ(model, "Key", 0.14, 0.05, Vector3.new(px - 0.11 + c * 0.22, h0 + 3.05 - r * 0.25, -0.98), P.Chrome,
				{ material = Enum.Material.Metal, shadow = false })
		end
	end
	part(model, "CoinSlot", Vector3.new(0.12, 0.3, 0.04), CFrame.new(px, h0 + 2.1, -0.98), P.Ink)
	-- pickup tray at the bottom
	part(model, "Pickup", Vector3.new(1.8, 0.5, 0.1), CFrame.new(wx, h0 + 0.5, -0.93), P.Ink)
	gold(model, "PickupFrame", Vector3.new(1.9, 0.6, 0.05), CFrame.new(wx, h0 + 0.5, -0.9))
	-- lit header sign
	boardSign(model, "Header", Vector3.new(2.9, 0.75, 0.3), CFrame.new(0, h0 + 4.7, -0.15), "TREATS", { icon = "cash" })
	bulbsAlong(bulbs, Vector3.new(-1.35, h0 + 5.12, -0.32), Vector3.new(1.35, h0 + 5.12, -0.32), 8)
	return model
end

------------------------------------------------------------------
-- CRAPS TABLE (long table with a high rail, printed layout, two dice)
------------------------------------------------------------------
local function crapsTable(def)
	local model = new("Model", { Name = def.name })
	local bulbs = new("Folder", { Name = "Bulbs" }, model)
	local L, Wd = 6.0, 4.8
	local topY = 3.0
	part(model, "Plinth", Vector3.new(8.6, 0.4, 3.6), CFrame.new(0, 0.2, 0), P.Ink, { solid = true })
	gold(model, "PlinthLip", Vector3.new(8.74, 0.1, 3.74), CFrame.new(0, 0.38, 0))
	neon(model, "Underglow", Vector3.new(8.3, 0.07, 0.05), CFrame.new(0, 0.14, -1.825), P.NeonGreen)
	for _, x in { -3.2, 0, 3.2 } do
		part(model, "Pedestal", Vector3.new(1.0, 2.1, 2.4), CFrame.new(x, 1.45, 0), P.Wood, { solid = true })
		gold(model, "PedestalBand", Vector3.new(1.1, 0.16, 2.5), CFrame.new(x, 2.25, 0))
	end
	local body = stadium(model, "Body", L, Wd, 0.55, Vector3.new(0, topY - 0.3, 0), P.WoodDark, { solid = true })
	model.PrimaryPart = body
	-- the padded leather rail: a solid stadium, so its top stays just under the
	-- felt (a lip around it) - any higher and it covers the felt and the layout
	stadium(model, "Rail", L, Wd + 0.5, 0.6, Vector3.new(0, topY + 0.04, 0), P.Leather, { material = Enum.Material.Leather })
	stadium(model, "FeltTrim", L, Wd - 0.12, 0.04, Vector3.new(0, topY + 0.325, 0), P.Gold, { reflectance = 0.12 })
	stadium(model, "Felt", L, Wd - 0.3, 0.06, Vector3.new(0, topY + 0.32, 0), P.Felt, { material = Enum.Material.Fabric })
	local surfaceY = topY + 0.35
	-- printed layout: PASS LINE along the front, FIELD in the middle, COME behind
	local layout = flatPrint(model, "Layout", 7.6, 3.6, CFrame.new(0, surfaceY + 0.01, 0.05))
	local g = surface(layout, Enum.NormalId.Top, 90, 0.3)
	local function zone(text, pos, size, color)
		local f = new("Frame", { BackgroundTransparency = 1, Position = pos, Size = size }, g)
		new("UIStroke", { Color = P.White, Thickness = 4, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, f)
		new("UICorner", { CornerRadius = UDim.new(0.2, 0) }, f)
		guiText(f, text, { size = UDim2.fromScale(0.9, 0.7), position = UDim2.fromScale(0.05, 0.15), color = color or P.White,
			stroke = false, font = Enum.Font.GothamBlack })
	end
	zone("COME", UDim2.fromScale(0.08, 0.04), UDim2.fromScale(0.84, 0.22))
	zone("FIELD  2 • 3 • 4 • 9 • 10 • 11 • 12", UDim2.fromScale(0.08, 0.3), UDim2.fromScale(0.84, 0.22), P.GoldTop)
	zone("DON'T PASS BAR", UDim2.fromScale(0.08, 0.56), UDim2.fromScale(0.84, 0.14))
	zone("PASS LINE", UDim2.fromScale(0.04, 0.74), UDim2.fromScale(0.92, 0.22), P.GoldTop)
	-- the dice (MachineFX rolls Die1 / Die2), chips and the stickman's stick
	die(model, "Die1", 0.55, CFrame.new(-0.6, surfaceY + 0.28, -0.6) * CFrame.Angles(0, math.rad(25), 0))
	die(model, "Die2", 0.55, CFrame.new(0.3, surfaceY + 0.28, -0.4) * CFrame.Angles(0, math.rad(-40), 0))
	for i, spot in { Vector3.new(-2.4, 0, -1.3), Vector3.new(1.8, 0, -1.4), Vector3.new(2.9, 0, 0.3) } do
		chipStack(model, Vector3.new(spot.X, surfaceY, spot.Z), 1 + i, ({ P.Crimson, hex("#1E9BEA"), P.Gold })[i])
	end
	part(model, "ChipRack", Vector3.new(3.4, 0.22, 0.6), CFrame.new(0, topY + 0.45, 2.35), P.Ink)
	for i, c in { P.Crimson, hex("#1E9BEA"), P.Gold, hex("#36C23A"), P.White, hex("#8A4DE8") } do
		chipStack(model, Vector3.new(-1.4 + (i - 1) * 0.56, topY + 0.56, 2.35), 3, c)
	end
	cylX(model, "Stick", 0.12, 4.2, Vector3.new(0.5, topY + 0.42, 2.75), P.Wood, { shadow = false })
	-- limit sign at the back
	local sign = gold(model, "LimitSign", Vector3.new(1.6, 0.75, 0.1), CFrame.new(-3.4, surfaceY + 0.95, 2.6))
	gold(model, "LimitPost", Vector3.new(0.1, 0.5, 0.1), CFrame.new(-3.4, surfaceY + 0.45, 2.6))
	local sg = surface(sign, Enum.NormalId.Front, 120, 0.1)
	local plate = signPlate(sg, P.Felt)
	guiText(plate, ("$%d - $%d"):format(def.minBet or 0, def.maxBet or 0), { size = UDim2.fromScale(0.86, 0.6),
		position = UDim2.fromScale(0.07, 0.2), strokeThickness = 4 })
	bulbsAlong(bulbs, Vector3.new(-L / 2, topY + 0.38, -(Wd + 0.5) / 2 - 0.05), Vector3.new(L / 2, topY + 0.38, -(Wd + 0.5) / 2 - 0.05), 14, 0.14)
	return model
end

------------------------------------------------------------------
-- ICE CREAM CART (pastel cart, freezer tubs, a giant cone on top)
------------------------------------------------------------------
local function iceCreamCart(def)
	local model = new("Model", { Name = def.name })
	local bulbs = new("Folder", { Name = "Bulbs" }, model)
	local pink, mint = hex("#FFA3DA"), hex("#9BF7D8")
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			cylX(model, "Wheel", 0.9, 0.25, Vector3.new(sx * 1.8, 0.45, sz * 0.85), P.Ink)
			cylX(model, "Hub", 0.4, 0.28, Vector3.new(sx * 1.8, 0.45, sz * 0.85), P.Gold, { reflectance = 0.2 })
		end
	end
	local body = part(model, "Body", Vector3.new(4.0, 1.5, 2.2), CFrame.new(0, 1.6, 0), pink, { solid = true })
	model.PrimaryPart = body
	gold(model, "BodyTrimTop", Vector3.new(4.15, 0.14, 2.35), CFrame.new(0, 2.38, 0))
	gold(model, "BodyTrimBottom", Vector3.new(4.15, 0.12, 2.35), CFrame.new(0, 0.86, 0))
	local fp = part(model, "FrontPanel", Vector3.new(3.0, 0.95, 0.06), CFrame.new(0, 1.6, -1.13), pink:Lerp(P.Ink, 0.3))
	local fg = surface(fp, Enum.NormalId.Front, 100, 0.1)
	local plate = signPlate(fg, hex("#C2338A"))
	guiText(plate, "ICE CREAM", { size = UDim2.fromScale(0.86, 0.62), position = UDim2.fromScale(0.07, 0.19),
		gradient = { P.GoldTop, P.Gold }, strokeThickness = 6 })
	cylX(model, "Handle", 0.14, 1.6, Vector3.new(2.65, 2.2, 0), P.Chrome, { reflectance = 0.3, material = Enum.Material.Metal })
	-- open freezer tubs on top
	local topY = 2.45
	for i, c in { hex("#FFE3B0"), hex("#FF8FB5"), hex("#6B3A22"), mint } do
		local x = -1.35 + (i - 1) * 0.9
		cylY(model, "Tub", 0.8, 0.3, Vector3.new(x, topY + 0.15, -0.35), P.Chrome, { material = Enum.Material.Metal })
		cylY(model, "Scoops", 0.66, 0.18, Vector3.new(x, topY + 0.32, -0.35), c, { shadow = false })
	end
	-- cones stacked by the tubs
	for i = 0, 2 do
		cylY(model, "ConeStack", 0.32, 0.5, Vector3.new(1.5, topY + 0.25 + i * 0.12, 0.55), hex("#E0A458"))
	end
	-- umbrella canopy + posts
	for _, sx in { -1, 1 } do
		cylY(model, "Post", 0.14, 2.3, Vector3.new(sx * 1.9, topY + 1.15, 0.95), P.Gold, { reflectance = 0.15 })
	end
	canopy(model, 4.4, topY + 2.35, 1.2, -1.3, 0.55, { pink, P.White })
	-- the giant cone on the roof
	local cx, cz, baseY = 0, 0.2, topY + 2.4
	for i = 0, 3 do
		cylY(model, "Cone", 1.1 - i * 0.24, 0.5, Vector3.new(cx, baseY - 0.25 - i * 0.45 + 1.5, cz), hex("#E0A458"))
	end
	ball(model, "ScoopPink", 1.2, Vector3.new(cx, baseY + 1.95, cz), hex("#FF8FB5"))
	ball(model, "ScoopVanilla", 1.05, Vector3.new(cx, baseY + 2.75, cz), hex("#FFF1D0"))
	ball(model, "Cherry", 0.36, Vector3.new(cx, baseY + 3.35, cz), P.Crimson, { reflectance = 0.2 })
	bulbsAlong(bulbs, Vector3.new(-2.0, topY + 1.72, -1.35), Vector3.new(2.0, topY + 1.72, -1.35), 9)
	return model
end

------------------------------------------------------------------
-- BURGER GRILL (diner counter, sizzling grill, burgers, sauces)
------------------------------------------------------------------
local function burgerGrill(def)
	local model = new("Model", { Name = def.name })
	local bulbs = new("Folder", { Name = "Bulbs" }, model)
	local red, yellow = hex("#D7263D"), hex("#FFC21A")
	local h0 = plinth(model, 5.8, 3.2, P.Amber)
	local body = part(model, "Body", Vector3.new(5.4, 1.6, 1.4), CFrame.new(0, h0 + 0.8, -0.8), red, { solid = true })
	model.PrimaryPart = body
	part(model, "Stripe", Vector3.new(5.42, 0.25, 1.42), CFrame.new(0, h0 + 0.55, -0.8), P.White)
	gold(model, "CounterTop", Vector3.new(5.6, 0.14, 1.6), CFrame.new(0, h0 + 1.67, -0.8))
	local fp = part(model, "FrontPanel", Vector3.new(3.2, 0.8, 0.06), CFrame.new(0, h0 + 1.05, -1.53), red:Lerp(P.Ink, 0.3))
	local fg = surface(fp, Enum.NormalId.Front, 100, 0.1)
	local plate = signPlate(fg, P.CrimsonDeep)
	guiText(plate, "HOT BURGERS", { size = UDim2.fromScale(0.86, 0.62), position = UDim2.fromScale(0.07, 0.19),
		gradient = { P.GoldTop, P.Gold }, strokeThickness = 6 })
	-- burgers waiting on the counter + sauces
	local cy = h0 + 1.74
	for i, x in { -1.8, -1.1 } do
		cylY(model, "BunBottom", 0.6, 0.12, Vector3.new(x, cy + 0.06, -0.9), hex("#E0A458"))
		cylY(model, "Patty", 0.64, 0.12, Vector3.new(x, cy + 0.18, -0.9), hex("#5A2E1A"))
		cylY(model, "Cheese", 0.66, 0.04, Vector3.new(x, cy + 0.26, -0.9), yellow)
		ball(model, "BunTop", 0.62, Vector3.new(x, cy + 0.32, -0.9), hex("#E8A85A"))
		local _ = i
	end
	cylY(model, "Ketchup", 0.26, 0.6, Vector3.new(1.6, cy + 0.3, -1.1), red)
	cylY(model, "Mustard", 0.26, 0.6, Vector3.new(2.0, cy + 0.3, -1.1), yellow)
	-- the grill behind the counter, glowing hot
	part(model, "GrillBase", Vector3.new(3.6, 1.6, 1.0), CFrame.new(0, h0 + 0.8, 0.6), P.Chrome,
		{ material = Enum.Material.Metal, solid = true })
	local plateTop = part(model, "GrillPlate", Vector3.new(3.5, 0.12, 0.9), CFrame.new(0, h0 + 1.66, 0.6), hex("#1A1A1F"))
	for i = 0, 3 do
		neon(model, "GrillHeat", Vector3.new(3.3, 0.04, 0.06), CFrame.new(0, h0 + 1.73, 0.28 + i * 0.21), P.Amber)
	end
	for _, x in { -1.0, 0, 1.0 } do
		cylY(model, "GrillPatty", 0.62, 0.1, Vector3.new(x, h0 + 1.78, 0.6), hex("#5A2E1A"), { shadow = false })
	end
	new("ParticleEmitter", {
		Name = "Smoke", Texture = "rbxasset://textures/particles/smoke_main.dds", Rate = 4,
		Lifetime = NumberRange.new(1.5, 2.5), Speed = NumberRange.new(1.5, 3), SpreadAngle = Vector2.new(15, 15),
		Color = ColorSequence.new(Color3.fromRGB(200, 200, 205)), LightInfluence = 1,
		Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.5), NumberSequenceKeypoint.new(1, 2.2) }),
		Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.6), NumberSequenceKeypoint.new(1, 1) }),
		EmissionDirection = Enum.NormalId.Top,
	}, plateTop)
	-- back wall with the menu sign, canopy
	part(model, "BackWall", Vector3.new(5.4, 3.6, 0.3), CFrame.new(0, h0 + 1.8, 1.3), red:Lerp(P.Ink, 0.4), { solid = true })
	for _, sx in { -1, 1 } do
		cylY(model, "Post", 0.16, 2.3, Vector3.new(sx * 2.6, h0 + 1.74 + 1.15, -1.45), P.Gold, { reflectance = 0.15 })
	end
	canopy(model, 5.8, h0 + 4.2, 1.45, -1.65, 0.6, { red, yellow })
	boardSign(model, "Sign", Vector3.new(3.4, 1.0, 0.25), CFrame.new(0, h0 + 4.8, 1.3), "BURGERS", { fill = P.CrimsonDeep, bothSides = true })
	bulbsAlong(bulbs, Vector3.new(-2.8, h0 + 3.5, -1.7), Vector3.new(2.8, h0 + 3.5, -1.7), 11)
	return model
end

------------------------------------------------------------------
-- ATM (cash machine: patrons pay a small fee)
------------------------------------------------------------------
local function atmMachine(def)
	local model = new("Model", { Name = def.name })
	local bulbs = new("Folder", { Name = "Bulbs" }, model)
	local col = hex("#16507E")
	local h0 = plinth(model, 2.8, 2.2, P.NeonBlue, 0.3)
	local body = part(model, "Body", Vector3.new(2.4, 4.4, 1.8), CFrame.new(0, h0 + 2.2, 0), col, { solid = true })
	model.PrimaryPart = body
	for _, sx in { -1, 1 } do
		gold(model, "EdgeTrim", Vector3.new(0.14, 4.4, 0.14), CFrame.new(sx * 1.2, h0 + 2.2, -0.9))
	end
	part(model, "Panel", Vector3.new(2.0, 3.0, 0.1), CFrame.new(0, h0 + 2.2, -0.92), col:Lerp(P.Ink, 0.45))
	local screen = neon(model, "Screen", Vector3.new(1.3, 0.9, 0.04), CFrame.new(0, h0 + 3.05, -0.99), hex("#2BA8E0"))
	local sg = surface(screen, Enum.NormalId.Front, 120, 0)
	guiText(sg, "WELCOME\nINSERT CARD", { size = UDim2.fromScale(0.9, 0.8), position = UDim2.fromScale(0.05, 0.1),
		color = P.White, stroke = false, font = Enum.Font.GothamBlack })
	for r = 0, 3 do
		for c = 0, 2 do
			cylZ(model, "Key", 0.16, 0.05, Vector3.new(-0.32 + c * 0.32, h0 + 2.3 - r * 0.24, -0.99), P.Chrome,
				{ material = Enum.Material.Metal, shadow = false })
		end
	end
	part(model, "CardSlot", Vector3.new(0.5, 0.08, 0.05), CFrame.new(0.65, h0 + 2.2, -0.99), P.Ink)
	gold(model, "CashSlotFrame", Vector3.new(1.4, 0.32, 0.05), CFrame.new(0, h0 + 1.15, -0.97))
	part(model, "CashSlot", Vector3.new(1.2, 0.14, 0.06), CFrame.new(0, h0 + 1.15, -0.99), P.Ink)
	boardSign(model, "Header", Vector3.new(2.6, 0.8, 0.3), CFrame.new(0, h0 + 4.82, -0.15), "ATM", { icon = "cash", fill = hex("#0F5A99") })
	bulbsAlong(bulbs, Vector3.new(-1.2, h0 + 5.27, -0.32), Vector3.new(1.2, h0 + 5.27, -0.32), 7)
	return model
end

------------------------------------------------------------------
-- GIFT BOUTIQUE (pink booth, shelves of gifts, plushies)
------------------------------------------------------------------
local function giftBoutique(def)
	local model = new("Model", { Name = def.name })
	local bulbs = new("Folder", { Name = "Bulbs" }, model)
	local pink = hex("#F23FA0")
	local h0 = plinth(model, 6.6, 3.4, P.NeonPink)
	local body = part(model, "Body", Vector3.new(6.2, 1.6, 1.3), CFrame.new(0, h0 + 0.8, -0.9), pink, { solid = true })
	model.PrimaryPart = body
	gold(model, "CounterTop", Vector3.new(6.4, 0.14, 1.5), CFrame.new(0, h0 + 1.67, -0.9))
	local fp = part(model, "FrontPanel", Vector3.new(3.6, 0.9, 0.06), CFrame.new(0, h0 + 0.85, -1.58), pink:Lerp(P.Ink, 0.3))
	local fg = surface(fp, Enum.NormalId.Front, 100, 0.1)
	local plate = signPlate(fg, hex("#9E1A63"))
	guiText(plate, "GIFTS & MORE", { size = UDim2.fromScale(0.86, 0.62), position = UDim2.fromScale(0.07, 0.19),
		gradient = { P.GoldTop, P.Gold }, strokeThickness = 6 })
	-- plushies on the counter
	for i, c in { hex("#FF8A1F"), hex("#3FC8FF"), hex("#9BF78F") } do
		local x = -1.9 + (i - 1) * 0.75
		ball(model, "Plush", 0.6, Vector3.new(x, h0 + 2.03, -0.95), c)
		ball(model, "PlushHead", 0.42, Vector3.new(x, h0 + 2.48, -0.95), c)
	end
	-- back shelves full of wrapped gifts
	part(model, "Shelf", Vector3.new(6.2, 3.6, 0.7), CFrame.new(0, h0 + 1.8, 1.0), P.WoodDark, { solid = true })
	local giftCols = { P.Crimson, hex("#1E9BEA"), hex("#36C23A"), P.Gold, hex("#8A4DE8"), hex("#FF8A1F") }
	for row = 0, 2 do
		local y = h0 + 1.0 + row * 1.05
		gold(model, "ShelfBoard", Vector3.new(6.0, 0.08, 0.55), CFrame.new(0, y, 0.6))
		for k = 0, 6 do
			local s = 0.42 + ((k + row) % 3) * 0.06
			local c = giftCols[(k + row * 2) % #giftCols + 1]
			local x = -2.6 + k * 0.86
			part(model, "Gift", Vector3.new(s, s, s), CFrame.new(x, y + s / 2 + 0.04, 0.6), c)
			part(model, "Ribbon", Vector3.new(s + 0.02, s + 0.02, 0.08), CFrame.new(x, y + s / 2 + 0.04, 0.6), P.GoldTop, { shadow = false })
		end
	end
	for _, sx in { -1, 1 } do
		cylY(model, "Post", 0.16, 2.3, Vector3.new(sx * 2.95, h0 + 1.74 + 1.15, -1.5), P.Gold, { reflectance = 0.15 })
	end
	canopy(model, 6.6, h0 + 4.2, 1.35, -1.7, 0.6, { pink, P.White })
	boardSign(model, "Sign", Vector3.new(4.0, 1.0, 0.25), CFrame.new(0, h0 + 4.8, 1.0), "GIFT BOUTIQUE",
		{ icon = "gift", fill = hex("#9E1A63"), bothSides = true })
	bulbsAlong(bulbs, Vector3.new(-3.1, h0 + 3.5, -1.75), Vector3.new(3.1, h0 + 3.5, -1.75), 12)
	return model
end

-- scale a freshly built model about its ground origin (big versions of a design)
local function scaled(model, s: number)
	if not model or s == 1 then return model end
	local primary = model.PrimaryPart
	if primary then primary.PivotOffset = primary.CFrame:Inverse() else model.WorldPivot = CFrame.new() end
	model:ScaleTo(s)
	return model
end

------------------------------------------------------------------
-- more kit (the economy patch's machines): wedges + spikes, rods, idle
-- spinners, cut gems, sub-model merging and the Plinko pin board
------------------------------------------------------------------
-- a WedgePart: its slope runs from the top-back (+Y, +Z) edge down to the
-- bottom-front (-Y, -Z) edge of its own frame
local function wedge(parent, name: string, size: Vector3, cf: CFrame, color: Color3, opts)
	opts = opts or {}
	local w = Instance.new("WedgePart")
	w.Name = name
	w.Anchored = true
	w.Size = size
	w.CFrame = cf
	w.Color = color
	w.Material = opts.material or Enum.Material.SmoothPlastic
	w.Reflectance = opts.reflectance or 0
	w.Transparency = opts.transparency or 0
	w.CanCollide = opts.solid == true
	w.CanQuery = opts.solid == true
	w.CanTouch = false
	w.CastShadow = opts.shadow ~= false
	w.TopSurface = Enum.SurfaceType.Smooth
	w.BottomSurface = Enum.SurfaceType.Smooth
	w.Parent = parent
	return w
end

-- a flat triangular spike (two mirrored wedges) in cf's XY plane: its base
-- `w` wide centred on cf's origin, its tip `h` up cf's +Y, `t` thick along
-- cf's Z. Turn cf to aim it: crown points, horns, dorsal spines.
local function spike(parent, name: string, w: number, h: number, t: number, cf: CFrame, color: Color3, opts)
	for _, s in { -1, 1 } do
		-- each wedge's upright back face stands on the centre line
		wedge(parent, name, Vector3.new(t, h, w / 2),
			cf * CFrame.new(s * w / 4, h / 2, 0) * CFrame.Angles(0, math.rad(-90 * s), 0), color, table.clone(opts or {}))
	end
end

-- a cylinder lying from a to b
local function rod(parent, name: string, a: Vector3, b: Vector3, d: number, color: Color3, opts)
	opts = table.clone(opts or {})
	opts.shape = Enum.PartType.Cylinder
	return part(parent, name, Vector3.new((b - a).Magnitude, d, d),
		CFrame.lookAt((a + b) / 2, b) * CFrame.Angles(0, math.rad(90), 0), color, opts)
end

-- a sub-model that client MachineFX turns slowly about its PrimaryPart's
-- vertical axis (SpinRate = degrees per second): showpiece gems up top
local function spinner(parent, name: string, rate: number)
	local m = new("Model", { Name = name }, parent)
	m:SetAttribute("SpinRate", rate)
	return m
end

-- a cut gem: a translucent neon cube balanced on a corner (it reads as a
-- diamond from every side) round a white-hot core. Returns the core.
local function cutGem(parent, s: number, pos: Vector3, color: Color3)
	part(parent, "Gem", Vector3.new(s, s, s),
		CFrame.new(pos) * CFrame.Angles(0, 0, math.rad(54.7356)) * CFrame.Angles(0, math.rad(45), 0), color,
		{ material = Enum.Material.Neon, transparency = 0.2, reflectance = 0.1, shadow = false })
	return ball(parent, "GemCore", s * 0.5, pos, P.White, { material = Enum.Material.Neon, shadow = false })
end

-- move a freshly built model's parts into `dst`, its ground origin landing on
-- `cf`; its bulbs join `bulbsDst` (dropped when nil)
local function mergeInto(src: Model, dst: Model, bulbsDst: Instance?, cf: CFrame)
	local primary = src.PrimaryPart
	if primary then primary.PivotOffset = primary.CFrame:Inverse() else src.WorldPivot = CFrame.new() end
	src:PivotTo(cf)
	for _, child in src:GetChildren() do
		if child.Name == "Bulbs" then
			if bulbsDst then
				for _, b in child:GetChildren() do b.Parent = bulbsDst end
			end
		else
			child.Parent = dst
		end
	end
	src:Destroy()
end

-- The Plinko pin board (client MachineFX drops the Ball through it):
--   Pegs/P<r>_<k>       the pin the ball meets in row r (1..8) after k rights
--   Pockets/Pocket1..9  the bins, viewer left -> right (model +X -> -X): the
--                       ball lands in Pocket<1 + rights> (GameLogic.plinko)
--   Ball                waits in the chute above P1_0
-- `top` is P1_0's centre; the pins run along Z round the plane z = top.Z.
-- o: dx, dy (pin pitch), pegD, pegLen, ballD, pocketH, labelH, startUp,
--    labelPpu, ballColor
local PLINKO_TONES = { hex("#FF3B55"), hex("#FF8A1F"), hex("#FFC003"), hex("#3DFF6E"), hex("#3FC8FF"),
	hex("#3DFF6E"), hex("#FFC003"), hex("#FF8A1F"), hex("#FF3B55") }
local function plinkoBoard(model, top: Vector3, o)
	local dx, dy, pegLen = o.dx, o.dy, o.pegLen
	local mults = GameLogic.PlinkoMultipliers or { 16, 4, 1.5, 0.5, 0.2, 0.5, 1.5, 4, 16 }
	local pegs = new("Folder", { Name = "Pegs" }, model)
	for r = 1, 8 do
		for k = 0, r - 1 do
			cylZ(pegs, ("P%d_%d"):format(r, k), o.pegD, pegLen,
				Vector3.new(top.X + (r - 1 - 2 * k) * dx / 2, top.Y - (r - 1) * dy, top.Z), P.Gold,
				{ reflectance = 0.25, shadow = false })
		end
	end
	-- the bins: colour plates on the board face between gold walls, a gold floor
	local pTop = top.Y - 7.55 * dy
	local ph = o.pocketH
	local pockets = new("Folder", { Name = "Pockets" }, model)
	for p = 1, 9 do
		local pocket = part(pockets, "Pocket" .. p, Vector3.new(dx - 0.04, ph, 0.06),
			CFrame.new(top.X + (5 - p) * dx, pTop - ph / 2, top.Z + pegLen / 2 - 0.03), PLINKO_TONES[p], { shadow = false })
		pocket:SetAttribute("Multiplier", mults[p])
	end
	for j = 0, 9 do
		gold(model, "PocketWall", Vector3.new(0.05, ph, pegLen), CFrame.new(top.X + (j - 4.5) * dx, pTop - ph / 2, top.Z))
	end
	gold(model, "PocketFloor", Vector3.new(9 * dx + 0.1, 0.06, pegLen + 0.06), CFrame.new(top.X, pTop - ph - 0.03, top.Z))
	-- the multipliers on a strip under the bins
	local labelH = o.labelH
	local strip = part(model, "PocketLabels", Vector3.new(9 * dx + 0.1, labelH, 0.06),
		CFrame.new(top.X, pTop - ph - 0.06 - labelH / 2, top.Z - pegLen / 2 + 0.03), P.Ink, { shadow = false })
	local g = surface(strip, Enum.NormalId.Front, o.labelPpu or 100, 0)
	for p = 1, 9 do
		guiText(g, tostring(mults[p]) .. "x", { size = UDim2.fromScale(0.105, 0.8),
			position = UDim2.fromScale((p - 1) / 9 + 0.003, 0.1), color = PLINKO_TONES[p]:Lerp(P.White, 0.3),
			font = Enum.Font.FredokaOne, strokeThickness = 2 })
	end
	ball(model, "Ball", o.ballD, top + Vector3.new(0, o.startUp, 0), o.ballColor or P.White,
		{ material = Enum.Material.Neon, shadow = false })
	return pTop - ph - 0.06 - labelH -- the strip's bottom
end

------------------------------------------------------------------
-- LUCKY PLINKO (teal arcade cabinet, a glass pin board, 9 bins)
------------------------------------------------------------------
local function plinkoMachine(def)
	local model = new("Model", { Name = def.name })
	local bulbs = new("Folder", { Name = "Bulbs" }, model)
	local teal, tealDeep = hex("#1EC8D2"), hex("#0B5E66")
	local h0 = plinth(model, 4.8, 2.8, teal)

	-- lower cabinet (Body / PrimaryPart) with a belly sign and gold edges
	local body = part(model, "Body", Vector3.new(4.4, 2.0, 2.6), CFrame.new(0, h0 + 1.0, 0), teal, { solid = true })
	model.PrimaryPart = body
	local belly = part(model, "Belly", Vector3.new(3.6, 1.15, 0.08), CFrame.new(0, h0 + 0.95, -1.34), tealDeep)
	guiText(signPlate(surface(belly, Enum.NormalId.Front, 100, 0.1), tealDeep), "DROP & WIN!", {
		size = UDim2.fromScale(0.86, 0.58), position = UDim2.fromScale(0.07, 0.21), gradient = { P.GoldTop, P.Gold },
		strokeThickness = 6 })
	for _, sx in { -1, 1 } do
		gold(model, "EdgeTrim", Vector3.new(0.14, 2.0, 0.14), CFrame.new(sx * 2.2, h0 + 1.0, -1.3))
	end
	-- control deck: the big DROP button on the player's right (model -X)
	local deckY = h0 + 2.0
	gold(model, "Deck", Vector3.new(4.5, 0.2, 0.7), CFrame.new(0, deckY + 0.1, -1.1))
	cylY(model, "DropButton", 0.62, 0.14, Vector3.new(-1.3, deckY + 0.27, -1.12), P.NeonGreen,
		{ material = Enum.Material.Neon, shadow = false })
	for i, c in { P.NeonRed, P.Amber } do
		cylY(model, "Button" .. i, 0.3, 0.1, Vector3.new(0.9 + (i - 1) * 0.5, deckY + 0.25, -1.12), c,
			{ material = Enum.Material.Neon, shadow = false })
	end

	-- the pin board: a deep back panel between teal pillars (gold + neon
	-- edges), a header bar, glass in front of the pins
	local boardTop = deckY + 5.1
	local by, bh = (deckY + boardTop) / 2, boardTop - deckY
	part(model, "BoardBack", Vector3.new(4.3, bh, 0.2), CFrame.new(0, by, 0.65), hex("#0E2F3A"), { solid = true })
	for _, sx in { -1, 1 } do
		part(model, "Pillar", Vector3.new(0.3, bh, 1.0), CFrame.new(sx * 2.3, by, 0.3), teal, { solid = true })
		gold(model, "PillarTrim", Vector3.new(0.12, bh, 0.12), CFrame.new(sx * 2.3, by, -0.22))
		neon(model, "PillarNeon", Vector3.new(0.06, bh - 0.4, 0.06), CFrame.new(sx * 2.12, by, -0.18), hex("#7DF9FF"))
	end
	part(model, "Header", Vector3.new(4.9, 0.25, 1.0), CFrame.new(0, boardTop + 0.125, 0.3), teal, { solid = true })
	gold(model, "HeaderTrim", Vector3.new(4.9, 0.08, 0.1), CFrame.new(0, boardTop + 0.02, -0.22))
	part(model, "Glass", Vector3.new(4.3, bh - 0.3, 0.04), CFrame.new(0, by - 0.1, 0.18), hex("#CFF6FF"),
		{ transparency = 0.86, reflectance = 0.15, shadow = false })

	-- pins, bins, multipliers, the ball and its chrome chute
	local top = Vector3.new(0, deckY + 4.26, 0.4)
	plinkoBoard(model, top, { dx = 0.44, dy = 0.4, pegD = 0.14, pegLen = 0.3, ballD = 0.3, pocketH = 0.6,
		labelH = 0.28, startUp = 0.55 })
	local chuteY = top.Y + 0.55
	cylY(model, "Chute", 0.7, 0.1, Vector3.new(0, chuteY + 0.22, top.Z), P.Chrome,
		{ material = Enum.Material.Metal, reflectance = 0.3 })
	for _, sx in { -1, 1 } do
		part(model, "ChuteRail", Vector3.new(0.05, 0.34, 0.3), CFrame.new(sx * 0.21, chuteY, top.Z), P.Chrome,
			{ material = Enum.Material.Metal, reflectance = 0.3, shadow = false })
	end

	-- topper ringed with chasing bulbs, more bulbs down the pillars
	local signY = boardTop + 0.25 + 0.38
	boardSign(model, "Topper", Vector3.new(4.4, 0.76, 0.3), CFrame.new(0, signY, 0.35), "PLINKO", { icon = "gem" })
	bulbFrame(bulbs, 0, signY, 4.5, 0.86, 0.15, 10)
	for _, sx in { -1, 1 } do
		bulbsAlong(bulbs, Vector3.new(sx * 2.3, deckY + 0.45, -0.36), Vector3.new(sx * 2.3, boardTop - 0.35, -0.36), 8)
	end
	return model
end

------------------------------------------------------------------
-- VIDEO POKER BAR (bar-top cabinet, a sloped card screen, a stool)
-- the three middle cards are the reel rig (Spinny1..3 + Decals: the
-- MachineVisuals roll flips them); no lever
------------------------------------------------------------------
local function pokerCard(parent, name: string, cf: CFrame, label: string, red: boolean, reel: boolean)
	local c = part(parent, name, Vector3.new(0.62, 0.84, 0.03), cf, P.White, { shadow = false })
	if reel then
		-- the reel picture fills the card; the rank sits in its corners
		new("Decal", { Face = Enum.NormalId.Front, Texture = UIAssets.Icons.coin }, c)
	end
	local g = surface(c, Enum.NormalId.Front, 120, 0.1)
	local f = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, -6, 1, -6), Position = UDim2.fromOffset(3, 3) }, g)
	new("UICorner", { CornerRadius = UDim.new(0.12, 0) }, f)
	new("UIStroke", { Color = P.Gold, Thickness = 3, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, f)
	local ink = red and P.Crimson or P.Ink
	if reel then
		guiText(f, label, { size = UDim2.fromScale(0.34, 0.24), position = UDim2.fromScale(0.04, 0.03), color = ink, stroke = false })
		guiText(f, label, { size = UDim2.fromScale(0.34, 0.24), position = UDim2.fromScale(0.62, 0.73), color = ink, stroke = false,
			rotation = 180 })
	else
		guiText(f, label, { size = UDim2.fromScale(0.8, 0.5), position = UDim2.fromScale(0.1, 0.12), color = ink, stroke = false })
		local pip = new("Frame", { BackgroundColor3 = ink, AnchorPoint = Vector2.new(0.5, 0.5), Rotation = 45,
			Position = UDim2.fromScale(0.5, 0.78), Size = UDim2.fromScale(0.24, 0.24),
			SizeConstraint = Enum.SizeConstraint.RelativeXX }, f)
		new("UICorner", { CornerRadius = UDim.new(0.15, 0) }, pip)
	end
	return c
end

local function videoPoker(def)
	local model = new("Model", { Name = def.name })
	local bulbs = new("Folder", { Name = "Bulbs" }, model)
	local blue, navy = hex("#2A5BD7"), hex("#14296B")
	local h0 = plinth(model, 4.8, 2.3, P.NeonBlue, 0.4, 0.5)

	-- the bar cabinet (Body / PrimaryPart; the reel sounds live in it)
	local body = part(model, "Body", Vector3.new(4.4, 2.6, 2.0), CFrame.new(0, h0 + 1.3, 0.6), blue, { solid = true })
	model.PrimaryPart = body
	addSounds(body)
	-- the sign sits just under the bar top, clear of the stool's seat
	local fp = part(model, "FrontPanel", Vector3.new(3.6, 0.66, 0.06), CFrame.new(0, h0 + 2.2, -0.43), navy)
	guiText(signPlate(surface(fp, Enum.NormalId.Front, 100, 0.1), navy), "JACKS OR BETTER", {
		size = UDim2.fromScale(0.88, 0.6), position = UDim2.fromScale(0.06, 0.2), gradient = { P.GoldTop, P.Gold },
		strokeThickness = 6 })
	local pay = part(model, "PayPlate", Vector3.new(2.6, 0.5, 0.05), CFrame.new(0.35, h0 + 1.2, -0.425), hex("#0B1640"))
	guiText(surface(pay, Enum.NormalId.Front, 100, 0.1), "ROYAL FLUSH  x4000", { color = P.Amber,
		font = Enum.Font.GothamBlack, strokeThickness = 2, size = UDim2.fromScale(0.92, 0.6), position = UDim2.fromScale(0.04, 0.2) })
	for _, sx in { -1, 1 } do
		gold(model, "EdgeTrim", Vector3.new(0.14, 2.6, 0.14), CFrame.new(sx * 2.2, h0 + 1.3, -0.4))
		neon(model, "SideGlow", Vector3.new(0.05, 0.1, 1.8), CFrame.new(sx * 2.215, h0 + 2.3, 0.6), P.NeonBlue)
	end
	gold(model, "Kick", Vector3.new(4.42, 0.14, 0.1), CFrame.new(0, h0 + 0.12, -0.42))
	-- bill acceptor on the player's right, under the DEAL button
	part(model, "BillSlot", Vector3.new(0.5, 0.36, 0.06), CFrame.new(-1.55, h0 + 1.2, -0.43), P.Ink)
	neon(model, "BillLight", Vector3.new(0.34, 0.05, 0.04), CFrame.new(-1.55, h0 + 1.3, -0.47), P.NeonGreen)

	-- gold bar top with a leather armrest, five HOLD buttons, DEAL and MAX BET
	local deckY = h0 + 2.6
	gold(model, "Deck", Vector3.new(4.6, 0.18, 1.25), CFrame.new(0, deckY + 0.09, -0.22))
	cylX(model, "Armrest", 0.34, 4.6, Vector3.new(0, deckY + 0.08, -0.88), P.Leather, { material = Enum.Material.Leather })
	for i = 1, 5 do
		cylY(model, "HoldButton", 0.32, 0.08, Vector3.new(1.7 - (i - 1) * 0.42, deckY + 0.22, -0.45), P.Amber,
			{ material = Enum.Material.Neon, shadow = false })
	end
	cylY(model, "DealButton", 0.62, 0.12, Vector3.new(-0.95, deckY + 0.24, -0.45), P.NeonGreen,
		{ material = Enum.Material.Neon, shadow = false })
	cylY(model, "BetButton", 0.42, 0.1, Vector3.new(-1.75, deckY + 0.23, -0.45), P.NeonRed,
		{ material = Enum.Material.Neon, shadow = false })

	-- the screen box leans back; five cards on a navy screen, LEDs over them
	local tilt = math.rad(22)
	local sw, sh, sd = 4.2, 1.6, 0.45
	local up = Vector3.new(0, math.cos(tilt), math.sin(tilt))
	local back = Vector3.new(0, -math.sin(tilt), math.cos(tilt))
	local base = Vector3.new(0, deckY + 0.18, 0.3) -- the screen box's bottom front edge
	local scf = CFrame.new(base + up * (sh / 2) + back * (sd / 2)) * CFrame.Angles(tilt, 0, 0)
	part(model, "ScreenBox", Vector3.new(sw, sh, sd), scf, P.Ink, { solid = true })
	-- a gold bezel round the screen
	for _, sy in { -1, 1 } do
		gold(model, "Bezel", Vector3.new(sw, 0.08, 0.06), scf * CFrame.new(0, sy * (sh / 2 - 0.04), -sd / 2 - 0.03))
	end
	for _, sx in { -1, 1 } do
		gold(model, "Bezel", Vector3.new(0.08, sh - 0.16, 0.06), scf * CFrame.new(sx * (sw / 2 - 0.04), 0, -sd / 2 - 0.03))
	end
	local screen = part(model, "Screen", Vector3.new(sw - 0.3, sh - 0.2, 0.04), scf * CFrame.new(0, 0, -sd / 2 - 0.02), navy)
	local sg = surface(screen, Enum.NormalId.Front, 90, 0)
	pcall(function() sg.Brightness = 1.6 end)
	new("UIGradient", { Rotation = 90, Color = ColorSequence.new(hex("#2346A8"), hex("#0B1640")) },
		new("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = P.White, BorderSizePixel = 0 }, sg))
	guiText(sg, "VIDEO POKER", { size = UDim2.fromScale(0.5, 0.15), position = UDim2.fromScale(0.25, 0.02),
		gradient = { P.GoldTop, P.Gold }, strokeThickness = 3, z = 3 })
	for i = 1, 5 do
		guiText(sg, "HOLD", { size = UDim2.fromScale(0.13, 0.1), position = UDim2.fromScale(0.035 + (i - 1) * 0.1905, 0.86),
			color = P.Amber, font = Enum.Font.GothamBlack, stroke = false, z = 3 })
	end
	local cards = { { "A", false }, { "K", true }, { "Q", false }, { "J", true }, { "10", false } }
	for i, c in cards do
		local x = (3 - i) * 0.74 -- viewer left (+X) -> right
		local reel = i >= 2 and i <= 4
		pokerCard(model, reel and ("Spinny" .. (i - 1)) or "Card", scf * CFrame.new(x, 0.0, -sd / 2 - 0.055), c[1], c[2], reel)
	end
	neon(model, "LEDs", Vector3.new(sw - 0.7, 0.06, 0.03), scf * CFrame.new(0, sh / 2 - 0.04, -sd / 2 - 0.075), P.Amber)
	-- bulbs along the screen box's top and sides
	local function at(lx, ly) return scf:PointToWorldSpace(Vector3.new(lx, ly, -sd / 2 - 0.06)) end
	bulbsAlong(bulbs, at(-sw / 2 + 0.05, sh / 2 + 0.02), at(sw / 2 - 0.05, sh / 2 + 0.02), 13)
	for _, sx in { -1, 1 } do
		bulbsAlong(bulbs, at(sx * (sw / 2 + 0.02), -sh / 2 + 0.15), at(sx * (sw / 2 + 0.02), sh / 2 - 0.2), 4)
	end
	-- the tower light on the cabinet's back corner
	cylY(model, "CandlePost", 0.16, 1.55, Vector3.new(1.9, deckY + 0.78, 1.4), P.Chrome,
		{ material = Enum.Material.Metal, reflectance = 0.25 })
	cylY(model, "CandleBase", 0.34, 0.14, Vector3.new(1.9, deckY + 1.6, 1.4), P.Gold, { reflectance = 0.15 })
	ball(model, "Candle", 0.32, Vector3.new(1.9, deckY + 1.8, 1.4), P.NeonBlue, { material = Enum.Material.Neon, shadow = false })

	-- the padded stool in front
	local sz = -1.33
	cylY(model, "StoolBase", 0.9, 0.08, Vector3.new(0, 0.04, sz), P.Chrome, { material = Enum.Material.Metal, reflectance = 0.25 })
	cylY(model, "StoolPost", 0.16, 1.75, Vector3.new(0, 0.95, sz), P.Chrome, { material = Enum.Material.Metal, reflectance = 0.25 })
	cylY(model, "Footrest", 0.72, 0.06, Vector3.new(0, 0.72, sz), P.Gold, { reflectance = 0.15 })
	cylY(model, "SeatRim", 1.1, 0.06, Vector3.new(0, 1.84, sz), P.Gold, { reflectance = 0.15 })
	cylY(model, "Seat", 1.05, 0.26, Vector3.new(0, 1.99, sz), P.Crimson, { material = Enum.Material.Leather })
	cylY(model, "SeatTop", 0.9, 0.08, Vector3.new(0, 2.14, sz), hex("#E8475B"), { material = Enum.Material.Leather })
	return model
end

------------------------------------------------------------------
-- SIC BO DOME (round red-lacquer table, three dice under a glass dome)
------------------------------------------------------------------
local function dragonFinial(model, pos: Vector3, yaw: number, k: number)
	-- a gold dragon head on a post (k = its scale), looking out along its yaw
	local cf = CFrame.new(pos) * CFrame.Angles(0, math.rad(yaw), 0)
	local function at(x, y, z) return cf * CFrame.new(x * k, y * k, z * k) end
	cylY(model, "FinialPost", 0.24 * k, 0.55 * k, at(0, 0.275, 0).Position, P.Gold, { reflectance = 0.15 })
	ball(model, "DragonHead", 0.56 * k, at(0, 0.78, 0).Position, P.Gold, { reflectance = 0.2 })
	part(model, "DragonSnout", Vector3.new(0.3, 0.24, 0.44) * k, at(0, 0.72, -0.36), P.Gold, { reflectance = 0.2 })
	part(model, "DragonJaw", Vector3.new(0.26, 0.08, 0.36) * k, at(0, 0.57, -0.33), P.GoldDeep, { reflectance = 0.15 })
	for _, s in { -1, 1 } do
		ball(model, "DragonEye", 0.1 * k, at(s * 0.14, 0.9, -0.2).Position, P.NeonRed,
			{ material = Enum.Material.Neon, shadow = false })
		spike(model, "DragonHorn", 0.16 * k, 0.36 * k, 0.08 * k,
			at(s * 0.14, 0.98, 0.05) * CFrame.Angles(math.rad(35), 0, math.rad(-18 * s)), P.GoldTop, { reflectance = 0.2 })
	end
	spike(model, "DragonMane", 0.36 * k, 0.3 * k, 0.08 * k, at(0, 0.75, 0.24) * CFrame.Angles(math.rad(70), 0, 0), P.GoldDeep)
end

local function sicBoDome(def)
	local model = new("Model", { Name = def.name })
	local bulbs = new("Folder", { Name = "Bulbs" }, model)
	local lacquer, feltCol = hex("#C8102E"), hex("#3A0A14")
	-- round ink plinth, gold lip, an amber glow ring all the way round
	cylY(model, "Plinth", 5.4, 0.4, Vector3.new(0, 0.2, 0), P.Ink, { solid = true })
	cylY(model, "PlinthLip", 5.54, 0.1, Vector3.new(0, 0.37, 0), P.Gold, { reflectance = 0.12 })
	cylY(model, "Underglow", 5.62, 0.06, Vector3.new(0, 0.14, 0), P.Amber, { material = Enum.Material.Neon, shadow = false })
	-- square lacquer pedestal (Body / PrimaryPart: upright, facing -Z)
	local body = part(model, "Body", Vector3.new(2.4, 2.1, 2.4), CFrame.new(0, 1.45, 0), lacquer,
		{ solid = true, reflectance = 0.06 })
	model.PrimaryPart = body
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			gold(model, "PedestalEdge", Vector3.new(0.14, 2.1, 0.14), CFrame.new(sx * 1.2, 1.45, sz * 1.2))
		end
	end
	gold(model, "PedestalBand", Vector3.new(2.5, 0.14, 2.5), CFrame.new(0, 2.42, 0))
	-- the round table: lacquer apron, gold band, gold rail, dark felt
	cylY(model, "Apron", 6.5, 0.45, Vector3.new(0, 2.725, 0), lacquer, { solid = true, reflectance = 0.06 })
	cylY(model, "ApronBand", 6.6, 0.1, Vector3.new(0, 2.56, 0), P.Gold, { reflectance = 0.15 })
	cylY(model, "Rail", 7.0, 0.3, Vector3.new(0, 3.1, 0), P.Gold, { reflectance = 0.18 })
	cylY(model, "Felt", 6.2, 0.06, Vector3.new(0, 3.28, 0), feltCol, { material = Enum.Material.Fabric })
	local surfaceY = 3.31

	-- the felt ring printed in gold: SMALL / BIG / TRIPLE / DOUBLE round the dome
	local fp = flatPrint(model, "FeltPrint", 6.0, 6.0, CFrame.new(0, surfaceY + 0.012, 0), feltCol)
	local g = surface(fp, Enum.NormalId.Top, 60, 0.3)
	local function ring(s: number, thick: number, color: Color3)
		local f = new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(s, s) }, g)
		new("UICorner", { CornerRadius = UDim.new(0.5, 0) }, f)
		new("UIStroke", { Color = color, Thickness = thick, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, f)
	end
	ring(0.97, 6, P.Gold)
	ring(0.64, 4, P.Gold)
	ring(0.5, 3, P.GoldDeep)
	local function word(text, x, y, w, color)
		guiText(g, text, { size = UDim2.fromScale(w, 0.09), position = UDim2.fromScale(x - w / 2, y - 0.045), color = color,
			stroke = false })
	end
	word("SMALL", 0.105, 0.5, 0.15, P.GoldTop)
	word("BIG", 0.895, 0.5, 0.15, P.GoldTop)
	word("TRIPLE 150 TO 1", 0.5, 0.905, 0.42, P.White)
	word("DOUBLE 10 TO 1", 0.5, 0.095, 0.42, P.White)

	-- the dome: gold base, red pad, a clear bubble over three big dice
	cylY(model, "DomeBase", 2.7, 0.22, Vector3.new(0, surfaceY + 0.11, 0), P.Gold, { reflectance = 0.2 })
	cylY(model, "DomePad", 2.36, 0.04, Vector3.new(0, surfaceY + 0.24, 0), P.Crimson, { material = Enum.Material.Fabric })
	local padTop = surfaceY + 0.26
	ball(model, "Dome", 2.6, Vector3.new(0, padTop, 0), hex("#CFEFFF"), { transparency = 0.75, reflectance = 0.3, shadow = false })
	local ds = 0.62
	die(model, "Die1", ds, CFrame.new(-0.48, padTop + ds / 2, 0.22) * CFrame.Angles(0, math.rad(18), 0))
	die(model, "Die2", ds, CFrame.new(0.5, padTop + ds / 2, 0.28) * CFrame.Angles(0, math.rad(-30), 0))
	die(model, "Die3", ds, CFrame.new(0.02, padTop + ds / 2, -0.42) * CFrame.Angles(0, math.rad(40), 0))
	model:SetAttribute("DiceHop", 0.45) -- MachineFX: the dice stay under the dome

	-- gold dragon heads on the rail's back quarters, a SIC BO sign at the back
	for _, sx in { -1, 1 } do
		local a = math.rad(sx * 60)
		dragonFinial(model, Vector3.new(3.3 * math.sin(a), 3.25, 3.3 * math.cos(a)), sx * -25, 1.35)
	end
	for _, sx in { -1, 1 } do
		gold(model, "SignPost", Vector3.new(0.1, 0.4, 0.1), CFrame.new(sx * 0.9, surfaceY + 0.2, 3.05))
	end
	boardSign(model, "Sign", Vector3.new(2.4, 0.7, 0.2), CFrame.new(0, surfaceY + 0.72, 3.05), "SIC BO", { drawIcon = dieIcon })
	bulbsAlong(bulbs, Vector3.new(-1.1, surfaceY + 1.13, 2.93), Vector3.new(1.1, surfaceY + 1.13, 2.93), 7)

	-- chips on the felt
	for i, a in { -55, -20, 20, 55 } do
		local r = math.rad(a)
		chipStack(model, Vector3.new(2.25 * math.sin(r), surfaceY, -2.25 * math.cos(r)), 1 + (i % 3),
			({ P.Crimson, hex("#1E9BEA"), P.Gold, hex("#36C23A") })[i])
	end
	-- marquee bulbs all round the rail
	for k = 0, 23 do
		local a = k * math.pi / 12
		local b = ball(bulbs, "Bulb", 0.14, Vector3.new(3.53 * math.sin(a), 3.1, -3.53 * math.cos(a)),
			(k % 2 == 0) and P.GoldTop or P.White, { material = Enum.Material.Neon, shadow = false })
		b:SetAttribute("Phase", k % 2)
	end
	return model
end

------------------------------------------------------------------
-- BACCARAT TABLE (wide emerald half-moon, brass rail, a gold arch)
------------------------------------------------------------------
local function baccaratTable(def)
	local model = new("Model", { Name = def.name })
	local bulbs = new("Folder", { Name = "Bulbs" }, model)
	local emerald, brass = hex("#0E7A4F"), hex("#D9A63A")
	local R, zc, topY = 4.3, 1.3, 3.0

	part(model, "Plinth", Vector3.new(7.4, 0.4, 2.8), CFrame.new(0, 0.2, -0.1), P.Ink, { solid = true })
	gold(model, "PlinthLip", Vector3.new(7.54, 0.1, 2.94), CFrame.new(0, 0.38, -0.1))
	neon(model, "Underglow", Vector3.new(7.1, 0.07, 0.05), CFrame.new(0, 0.14, -1.525), P.NeonGreen)
	for _, sx in { -1, 1 } do
		part(model, "Pedestal", Vector3.new(1.0, 2.1, 2.0), CFrame.new(sx * 2.6, 1.45, -0.1), P.WoodDark, { solid = true })
		gold(model, "PedestalBand", Vector3.new(1.1, 0.16, 2.1), CFrame.new(sx * 2.6, 2.25, -0.1))
	end
	halfDisc(model, "Body", R, 0.55, Vector3.new(0, topY - 0.3, zc), P.WoodDark, { solid = true })
	halfDisc(model, "Rail", R + 0.22, 0.36, Vector3.new(0, topY + 0.12, zc), brass,
		{ material = Enum.Material.Metal, reflectance = 0.22 })
	halfDisc(model, "FeltTrim", R - 0.12, 0.04, Vector3.new(0, topY + 0.3, zc), P.Gold, { reflectance = 0.12 })
	halfDisc(model, "Felt", R - 0.28, 0.06, Vector3.new(0, topY + 0.32, zc), emerald, { material = Enum.Material.Fabric })
	local surfaceY = topY + 0.35

	-- dealer counter (PrimaryPart: upright, facing -Z), chip tray, shoe, discards
	local counter = part(model, "Counter", Vector3.new(2 * R + 0.7, 0.95, 0.9), CFrame.new(0, topY + 0.08, zc + 0.45),
		P.WoodDark, { solid = true })
	model.PrimaryPart = counter
	gold(model, "CounterTrim", Vector3.new(2 * R + 0.8, 0.1, 1.0), CFrame.new(0, topY + 0.58, zc + 0.45))
	part(model, "ChipTray", Vector3.new(3.0, 0.14, 0.62), CFrame.new(0.2, topY + 0.68, zc + 0.45), P.Ink)
	for i, c in { P.Crimson, hex("#1E9BEA"), P.Gold, hex("#36C23A"), P.White, hex("#8A4DE8") } do
		chipStack(model, Vector3.new(-0.95 + (i - 1) * 0.46, topY + 0.72, zc + 0.45), 3, c)
	end
	gold(model, "Shoe", Vector3.new(0.85, 0.5, 0.55), CFrame.new(-3.0, topY + 0.88, zc + 0.45))
	part(model, "ShoeCards", Vector3.new(0.72, 0.4, 0.06), CFrame.new(-3.0, topY + 0.9, zc + 0.16), P.White, { shadow = false })
	part(model, "Discards", Vector3.new(0.7, 0.36, 0.55), CFrame.new(3.0, topY + 0.81, zc + 0.45), P.CrimsonDeep)

	-- the felt print: TIE / BANKER / PLAYER bands in gold
	local fp = flatPrint(model, "FeltPrint", 5.6, 1.9, CFrame.new(0, surfaceY + 0.012, zc - 1.75), emerald)
	local g = surface(fp, Enum.NormalId.Top, 90, 0.3)
	local function band(text: string, y: number, h: number, w: number, color: Color3)
		local f = new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromScale(0.5, y),
			Size = UDim2.fromScale(w, h) }, g)
		new("UICorner", { CornerRadius = UDim.new(0.5, 0) }, f)
		new("UIStroke", { Color = P.Gold, Thickness = 4, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, f)
		guiText(f, text, { size = UDim2.fromScale(0.8, 0.66), position = UDim2.fromScale(0.1, 0.17), color = color, stroke = false })
	end
	band("TIE PAYS 8 TO 1", 0.03, 0.24, 0.5, P.GoldTop)
	band("BANKER", 0.33, 0.29, 0.78, P.GoldTop)
	band("PLAYER", 0.68, 0.29, 0.96, P.White)

	-- the two hands, dealt face up at the dealer, and five betting spots
	playingCard(model, Vector3.new(1.35, surfaceY + 0.02, zc - 0.55), 6, "9", false)
	playingCard(model, Vector3.new(0.92, surfaceY + 0.035, zc - 0.52), -4, "K", true)
	playingCard(model, Vector3.new(-0.92, surfaceY + 0.02, zc - 0.55), 5, "7", true)
	playingCard(model, Vector3.new(-1.35, surfaceY + 0.035, zc - 0.52), -6, "A", false)
	local chipCols = { P.Crimson, hex("#1E9BEA"), P.Gold, hex("#36C23A"), hex("#8A4DE8") }
	for i, deg in { -60, -30, 0, 30, 60 } do
		local a = math.rad(deg)
		local pos = Vector3.new(3.45 * math.sin(a), surfaceY, zc - 3.45 * math.cos(a))
		cylY(model, "Spot", 0.78, 0.02, pos + Vector3.new(0, 0.006, 0), P.Gold, { shadow = false })
		cylY(model, "SpotInner", 0.64, 0.025, pos + Vector3.new(0, 0.01, 0), emerald, { shadow = false, material = Enum.Material.Fabric })
		chipStack(model, pos + Vector3.new(0, 0.02, 0), 1 + (i % 3), chipCols[i])
	end

	-- the gold arch over the dealer: two posts, a shallow arc, the sign
	local az = zc + 0.75
	for _, sx in { -1, 1 } do
		cylY(model, "ArchPost", 0.22, 0.4, Vector3.new(sx * 4.35, topY + 0.83, az), P.Gold, { reflectance = 0.18 })
	end
	local arcR, arcY0 = 17.48, 4.55 - 17.48 -- through (+-4.35, 4.0) and (0, 4.55)
	local half = math.asin(4.35 / arcR)
	local prev
	for k = 0, 8 do
		local phi = -half + 2 * half * k / 8
		local p = Vector3.new(arcR * math.sin(phi), arcY0 + arcR * math.cos(phi), az)
		if prev then rod(model, "Arch", prev, p, 0.14, P.Gold, { reflectance = 0.18 }) end
		local b = ball(bulbs, "Bulb", 0.14, p + Vector3.new(0, 0.06, -0.12), (k % 2 == 0) and P.GoldTop or P.White,
			{ material = Enum.Material.Neon, shadow = false })
		b:SetAttribute("Phase", k % 2)
		prev = p
	end
	boardSign(model, "Sign", Vector3.new(3.2, 0.75, 0.22), CFrame.new(0, 3.98, az + 0.05), "BACCARAT",
		{ icon = "crown", fill = hex("#0B4F33") })

	-- bulbs round the curved rail
	for k = 0, 16 do
		local a = math.rad(-84 + k * 10.5)
		local b = ball(bulbs, "Bulb", 0.14, Vector3.new(4.55 * math.sin(a), topY + 0.12, zc - 4.55 * math.cos(a)),
			(k % 2 == 0) and P.GoldTop or P.White, { material = Enum.Material.Neon, shadow = false })
		b:SetAttribute("Phase", k % 2)
	end
	return model
end

------------------------------------------------------------------
-- PACHINKO PALACE (three fused pachinko cabinets; the middle one carries
-- the Plinko rig, so it plays like Lucky Plinko)
------------------------------------------------------------------
local function pachinkoPalace(def)
	local model = new("Model", { Name = def.name })
	local bulbs = new("Folder", { Name = "Bulbs" }, model)
	local pink, violet = hex("#FF4FD8"), hex("#9B5CFF")
	local pinkDeep = hex("#8E1A78")
	local h0 = plinth(model, 7.9, 3.0, P.NeonPink)
	local winBottom, winTop, top = 3.6, 8.9, 9.15
	local cabs = { { x = 2.7, w = 2.3, side = true }, { x = 0, w = 3.1 }, { x = -2.7, w = 2.3, side = true } }
	for i, c in cabs do
		local x, w = c.x, c.w
		-- carcass: a full-depth lower box, the playfield box behind the window
		local lower = part(model, i == 2 and "Body" or "Lower", Vector3.new(w, winBottom - h0, 2.4),
			CFrame.new(x, (h0 + winBottom) / 2, 0.2), pink, { solid = true, reflectance = 0.05 })
		if i == 2 then model.PrimaryPart = lower end
		local field = part(model, "Field", Vector3.new(w, top - winBottom, 1.7), CFrame.new(x, (winBottom + top) / 2, 0.55),
			pinkDeep, { solid = true })
		local fg = surface(field, Enum.NormalId.Front, 40, 0.2)
		local bg = new("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = P.White, BorderSizePixel = 0 }, fg)
		new("UIGradient", { Rotation = 90, Color = ColorSequence.new(hex("#FFB8F2"), hex("#7A3BD9")) }, bg)
		local ringF = new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.52), Size = UDim2.fromScale(0.92, 0.92),
			SizeConstraint = Enum.SizeConstraint.RelativeXX }, fg)
		new("UICorner", { CornerRadius = UDim.new(0.5, 0) }, ringF)
		new("UIStroke", { Color = P.GoldTop, Thickness = 5, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, ringF)
		part(model, "Header", Vector3.new(w, top - winTop, 0.7), CFrame.new(x, (winTop + top) / 2, -0.65), pink, { solid = true })
		part(model, "Sill", Vector3.new(w, 0.12, 0.7), CFrame.new(x, winBottom + 0.06, -0.65), P.Chrome,
			{ material = Enum.Material.Metal, reflectance = 0.2 })
		part(model, "Glass", Vector3.new(w - 0.22, winTop - winBottom - 0.12, 0.04), CFrame.new(x, (winBottom + winTop) / 2 + 0.06, -0.98),
			hex("#F4E8FF"), { transparency = 0.88, reflectance = 0.15, shadow = false })
		-- the neon marquee frame round the window
		local nc = i == 2 and P.NeonPink or violet
		for _, sy in { winBottom + 0.2, winTop - 0.06 } do
			neon(model, "WindowNeon", Vector3.new(w - 0.3, 0.06, 0.04), CFrame.new(x, sy, -0.95), nc)
		end
		for _, sx in { -1, 1 } do
			neon(model, "WindowNeon", Vector3.new(0.06, winTop - winBottom - 0.3, 0.04),
				CFrame.new(x + sx * (w / 2 - 0.15), (winBottom + winTop) / 2 + 0.07, -0.95), nc)
		end
		-- ball tray of steel balls, the launcher knob, a speaker, a lit sign
		part(model, "Tray", Vector3.new(w - 0.3, 0.3, 0.62), CFrame.new(x, winBottom - 0.75, -1.28), P.Chrome,
			{ material = Enum.Material.Metal, reflectance = 0.25 })
		part(model, "TrayWell", Vector3.new(w - 0.5, 0.06, 0.42), CFrame.new(x, winBottom - 0.58, -1.28), P.Ink)
		for k = 1, 5 do
			ball(model, "SteelBall", 0.2, Vector3.new(x - (w - 0.8) / 2 + (k - 1) * (w - 0.8) / 4, winBottom - 0.45, -1.28 + (k % 2) * 0.08),
				P.Chrome, { material = Enum.Material.Metal, reflectance = 0.4 })
		end
		cylZ(model, "Knob", 0.42, 0.25, Vector3.new(x - w / 2 + 0.42, h0 + 0.85, -1.12), P.Chrome,
			{ material = Enum.Material.Metal, reflectance = 0.3 })
		ball(model, "KnobCap", 0.26, Vector3.new(x - w / 2 + 0.42, h0 + 0.85, -1.27), P.NeonPink,
			{ material = Enum.Material.Neon, shadow = false })
		cylZ(model, "Speaker", 0.55, 0.04, Vector3.new(x + w / 2 - 0.5, h0 + 0.85, -1.02), P.Ink)
		local lp = part(model, "LowerSign", Vector3.new(w - 0.4, 0.62, 0.05), CFrame.new(x, h0 + 1.75, -1.03), pinkDeep)
		guiText(signPlate(surface(lp, Enum.NormalId.Front, 100, 0.1), pinkDeep), i == 2 and "FEVER!" or "777", {
			size = UDim2.fromScale(0.84, 0.6), position = UDim2.fromScale(0.08, 0.2), gradient = { P.GoldTop, P.Gold },
			strokeThickness = 5 })
		-- the side cabinets: a ring of gold pins round a glowing tulip pocket
		if c.side then
			local cy = 6.4
			for k = 0, 11 do
				local a = k * math.pi / 6
				cylZ(model, "Pin", 0.1, 0.25, Vector3.new(x + 0.78 * math.cos(a), cy + 0.78 * math.sin(a), -0.425), P.Gold,
					{ reflectance = 0.25, shadow = false })
			end
			for _, s in { -1, 1 } do
				spike(model, "Tulip", 0.3, 0.42, 0.08, CFrame.new(x + s * 0.12, cy - 0.15, -0.45) * CFrame.Angles(0, 0, math.rad(-22 * s)),
					P.NeonPink, { material = Enum.Material.Neon, shadow = false })
			end
			ball(model, "TulipCup", 0.22, Vector3.new(x, cy - 0.12, -0.45), P.GoldTop, { material = Enum.Material.Neon, shadow = false })
		end
	end
	-- chrome stiles between and beside the cabinets (the window side walls)
	for _, sx in { -3.85, -1.55, 1.55, 3.85 } do
		part(model, "Stile", Vector3.new(0.22, winTop - winBottom, 0.72), CFrame.new(sx, (winBottom + winTop) / 2, -0.65), P.Chrome,
			{ material = Enum.Material.Metal, reflectance = 0.25 })
	end

	-- the middle playfield: the Plinko rig under a glowing tulip, an LCD on top
	local rig = Vector3.new(0, 7.237, -0.425)
	plinkoBoard(model, rig, { dx = 0.3, dy = 0.34, pegD = 0.1, pegLen = 0.25, ballD = 0.22, pocketH = 0.42, labelH = 0.24,
		startUp = 0.45, labelPpu = 120, ballColor = hex("#FFE6FA") })
	for _, s in { -1, 1 } do
		spike(model, "Tulip", 0.34, 0.5, 0.08, CFrame.new(s * 0.2, rig.Y + 0.28, -0.45) * CFrame.Angles(0, 0, math.rad(-24 * s)),
			P.NeonPink, { material = Enum.Material.Neon, shadow = false })
	end
	local lcd = part(model, "LCD", Vector3.new(2.3, 0.62, 0.04), CFrame.new(0, 8.42, -0.33), hex("#170A26"))
	local lg = surface(lcd, Enum.NormalId.Front, 100, 0)
	pcall(function() lg.Brightness = 2 end)
	guiText(lg, "JACKPOT x16", { size = UDim2.fromScale(0.9, 0.7), position = UDim2.fromScale(0.05, 0.15),
		gradient = { P.GoldTop, hex("#FF4FD8") }, strokeThickness = 3 })

	-- the big PACHINKO topper ringed with bulbs, a crown of three neon gems
	boardSign(model, "Topper", Vector3.new(7.6, 1.4, 0.35), CFrame.new(0, top + 0.75, 0.2), "PACHINKO",
		{ icon = "star", fill = hex("#6A0F58"), ppu = 60 })
	bulbFrame(bulbs, 0, top + 0.75, 7.7, 1.5, -0.08, 13)
	for i, x in { 2.6, 0, -2.6 } do
		cylY(model, "CrownCup", 0.42, 0.16, Vector3.new(x, top + 1.53, 0.2), P.Gold, { reflectance = 0.2 })
		ball(model, "CrownGem", i == 2 and 0.62 or 0.46, Vector3.new(x, top + (i == 2 and 1.9 or 1.82), 0.2),
			i == 2 and P.NeonPink or violet, { material = Enum.Material.Neon, shadow = false })
	end
	return model
end

------------------------------------------------------------------
-- DIAMOND DRAGON (a curved bank of three jade slot cabinets under a
-- jade-and-gold dragon; the middle cabinet is the reel rig, the bank's one
-- big lever stands on the player's right)
------------------------------------------------------------------
local function dragonSlots(def)
	local model = new("Model", { Name = def.name })
	local bulbs = new("Folder", { Name = "Bulbs" }, model)
	local jade, jadeDeep, jadeLight = hex("#14B88A"), hex("#0B6E52"), hex("#5EF0C2")
	local S, yaw = 0.66, math.rad(18)
	-- the outer cabinets turn in by 18 deg, their inner front corners on the
	-- middle cabinet's (plinth lip half-size 2.12 x 1.67 before scaling)
	local hx, hz = 2.12 * S, 1.67 * S
	local cx = hx + hx * math.cos(yaw) + hz * math.sin(yaw)
	local cz = -hz - (hx * math.sin(yaw) - hz * math.cos(yaw))
	local banks = {
		{ tag = "", x = 0, z = 0, yaw = 0, spec = { color = jade, accent = P.NeonGreen, title = "JACKPOT", bellyText = "777",
			meter = "$10,000,000" } },
		{ tag = "L", x = cx, z = cz, yaw = yaw, spec = { color = jadeDeep, accent = P.NeonGreen, title = "DRAGON",
			icon = "gem", topIcon = true } },
		{ tag = "R", x = -cx, z = cz, yaw = -yaw, spec = { color = jadeDeep, accent = P.NeonGreen, title = "DRAGON",
			icon = "gem", topIcon = true } },
	}
	for _, b in banks do
		local m = scaled(slotMachine(def, b.spec), S)
		if b.tag ~= "R" then
			local lever = m:FindFirstChild("Lever")
			if lever then lever:Destroy() end
		end
		if b.tag ~= "" then
			-- the side reels / LEDs keep their own names (MachineVisuals rolls
			-- them along with the main reels); only the main Body plays sounds
			for i = 1, 3 do
				local r = m:FindFirstChild("Spinny" .. i)
				if r then r.Name = "Spinny" .. b.tag .. i end
			end
			local leds = m:FindFirstChild("LEDs")
			if leds then leds.Name = "LEDs" .. b.tag end
			for _, c in m:GetChildren() do
				if c.Name == "ReelShade" then c:Destroy() end
			end
			local bd = m:FindFirstChild("Body")
			if bd then
				bd.Name = "Body" .. b.tag
				for _, snd in bd:GetChildren() do
					if snd:IsA("Sound") then snd:Destroy() end
				end
			end
		end
		mergeInto(m, model, b.tag == "" and bulbs or nil, CFrame.new(b.x, 0, b.z) * CFrame.Angles(0, b.yaw, 0))
	end
	model.PrimaryPart = model:FindFirstChild("Body")

	-- a jade moon gate behind the bank: a gold-rimmed disc on a panel, the
	-- dragon arching round its rim
	local bz, gateY, gateR = 2.0, 6.3, 3.55
	local panel = part(model, "Backdrop", Vector3.new(2 * gateR, gateY - 0.45, 0.3), CFrame.new(0, (gateY + 0.45) / 2, bz + 0.1),
		jadeDeep, { solid = true })
	local pg = surface(panel, Enum.NormalId.Front, 20, 0.3)
	for k = 0, 4 do
		local f = new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Rotation = 45,
			Position = UDim2.fromScale(0.1 + k * 0.2, 0.2), Size = UDim2.fromScale(0.09, 0.09),
			SizeConstraint = Enum.SizeConstraint.RelativeXX }, pg)
		new("UIStroke", { Color = P.Gold, Thickness = 2, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, f)
	end
	cylZ(model, "GateRim", 2 * gateR + 0.3, 0.26, Vector3.new(0, gateY, bz + 0.03), P.Gold, { reflectance = 0.2 })
	cylZ(model, "GateGlow", 2 * gateR + 0.08, 0.3, Vector3.new(0, gateY, bz), jadeLight, { material = Enum.Material.Neon, shadow = false })
	local disc = cylZ(model, "Gate", 2 * gateR - 0.12, 0.34, Vector3.new(0, gateY, bz - 0.01), jadeDeep)
	local dg = surface(disc, Enum.NormalId.Right, 24, 0.3) -- its front (-Z) cap
	local moon = new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.82, 0.82) }, dg)
	new("UICorner", { CornerRadius = UDim.new(0.5, 0) }, moon)
	new("UIStroke", { Color = P.Gold, Thickness = 3, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, moon)
	for _, sx in { -1, 1 } do
		gold(model, "BackdropEdge", Vector3.new(0.18, gateY - 0.45, 0.4), CFrame.new(sx * gateR, (gateY + 0.45) / 2, bz))
		neon(model, "BackdropNeon", Vector3.new(0.06, gateY - 0.85, 0.06), CFrame.new(sx * (gateR - 0.16), (gateY + 0.45) / 2, bz - 0.18),
			jadeLight)
	end

	-- the DIAMOND DRAGON marquee over the middle cabinet
	local mqY = 6.05
	boardSign(model, "Marquee", Vector3.new(5.4, 1.0, 0.3), CFrame.new(0, mqY, 0.3), "DIAMOND DRAGON",
		{ icon = "gem", fill = hex("#0A5A43") })
	bulbFrame(bulbs, 0, mqY, 5.5, 1.1, 0.1, 12)

	-- the dragon: a chain of jade balls arching over the bank (tail on the
	-- player's right, head raised on the left) with gold spines
	local ac, ar, az = Vector3.new(0, 6.3, 1.25), 3.9, 1.25
	local n = 18
	for k = 0, n - 1 do
		local t = k / (n - 1)
		local phi = math.rad(55 + 145 * t)
		local d = 1.0 - 0.58 * t
		local pos = Vector3.new(ac.X + ar * math.cos(phi), ac.Y + ar * math.sin(phi), az)
		ball(model, "DragonBody", d, pos, (k % 2 == 0) and jade or jadeLight:Lerp(jade, 0.5), { reflectance = 0.08 })
		if k % 2 == 1 then
			-- a gold spine pointing out of the arch
			spike(model, "DragonSpine", d * 0.5, d * 0.55, 0.1,
				CFrame.new(pos + Vector3.new(math.cos(phi), math.sin(phi), 0) * (d * 0.38)) * CFrame.Angles(0, 0, phi - math.pi / 2),
				P.Gold, { reflectance = 0.2 })
		end
	end
	-- tail fin
	local tailPhi = math.rad(203)
	spike(model, "DragonTail", 0.6, 0.7, 0.1,
		CFrame.new(ac + Vector3.new(ar * math.cos(tailPhi), ar * math.sin(tailPhi), 0)) * CFrame.Angles(0, 0, tailPhi), P.Gold,
		{ reflectance = 0.2 })
	-- neck and head, looking at the player
	local neck = { Vector3.new(2.7, 9.42, 0.95), Vector3.new(2.85, 9.52, 0.62) }
	for _, p in neck do
		ball(model, "DragonBody", 0.95, p, jade, { reflectance = 0.08 })
	end
	local hp = Vector3.new(2.95, 9.6, 0.3)
	ball(model, "DragonHead", 1.35, hp, jade, { reflectance = 0.1 })
	part(model, "DragonSnout", Vector3.new(0.9, 0.56, 0.82), CFrame.new(hp + Vector3.new(0, -0.17, -0.74)), jade, { reflectance = 0.1 })
	part(model, "DragonBrow", Vector3.new(1.0, 0.16, 0.3), CFrame.new(hp + Vector3.new(0, 0.42, -0.5)), P.Gold, { reflectance = 0.2 })
	part(model, "DragonJaw", Vector3.new(0.74, 0.18, 0.72), CFrame.new(hp + Vector3.new(0, -0.52, -0.64)), P.Gold, { reflectance = 0.2 })
	for _, s in { -1, 1 } do
		ball(model, "Nostril", 0.13, hp + Vector3.new(s * 0.2, 0.0, -1.16), P.Ink)
		-- gem-icon eyes
		local eye = part(model, "DragonEye", Vector3.new(0.46, 0.46, 0.04), CFrame.new(hp + Vector3.new(s * 0.34, 0.24, -0.6)), P.White,
			{ transparency = 1, shadow = false })
		guiImage(surface(eye, Enum.NormalId.Front, 100, 0), "gem")
		spike(model, "DragonHorn", 0.34, 0.95, 0.12,
			CFrame.new(hp + Vector3.new(s * 0.34, 0.5, 0.1)) * CFrame.Angles(math.rad(35), 0, math.rad(-15 * s)), P.Gold,
			{ reflectance = 0.2 })
		rod(model, "Whisker", hp + Vector3.new(s * 0.42, -0.22, -1.0), hp + Vector3.new(s * 1.15, -0.62, -1.1), 0.07, P.GoldTop)
	end
	for k = 0, 2 do
		spike(model, "DragonMane", 0.4, 0.55, 0.1,
			CFrame.new(hp + Vector3.new(0, 0.4 - k * 0.28, 0.5 + k * 0.08)) * CFrame.Angles(math.rad(60 + k * 15), 0, 0), P.Gold,
			{ reflectance = 0.2 })
	end
	-- the dragon's pearl, glowing in front of its jaw
	ball(model, "Pearl", 0.55, hp + Vector3.new(0, -0.9, -1.2), hex("#F2FFFB"), { material = Enum.Material.Neon, shadow = false })
	return model
end

------------------------------------------------------------------
-- BILLIONAIRE ROULETTE (the roulette table x1.25 in onyx, marble and gold
-- under a crown canopy on four gold columns, a giant gem turning on top)
------------------------------------------------------------------
local function billionaireRoulette(def)
	local onyx = hex("#141018")
	local model = scaled(rouletteTable(def, {
		felt = onyx, body = P.Ink, rail = hex("#F4F1EA"), railMaterial = Enum.Material.Marble, glow = P.GoldTop,
		pedestal = P.Ink, bowl = P.Ink, ballColor = hex("#D9FBFF"), ballMaterial = Enum.Material.Neon, limitFill = hex("#2B2230"),
		layout = { line = P.Gold, text = P.GoldTop, zero = hex("#0E5A3A"), red = hex("#7A0C1E"), black = onyx },
	}), 1.25)
	local bulbs = model:FindFirstChild("Bulbs")

	-- four gold columns (the velvet-rope posts) on onyx bases
	local px, pz, colTop = 5.3, 2.75, 5.5
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			local x, z = sx * px, sz * pz
			cylY(model, "ColumnBase", 0.75, 0.3, Vector3.new(x, 0.15, z), P.Ink, { solid = true })
			cylY(model, "ColumnFoot", 0.62, 0.14, Vector3.new(x, 0.37, z), P.Gold, { reflectance = 0.2 })
			cylY(model, "Column", 0.38, colTop - 0.64, Vector3.new(x, 0.44 + (colTop - 0.64) / 2, z), P.Gold,
				{ reflectance = 0.2, solid = true })
			cylY(model, "RopeRing", 0.5, 0.1, Vector3.new(x, 1.6, z), P.GoldDeep, { reflectance = 0.2 })
			cylY(model, "Capital", 0.62, 0.2, Vector3.new(x, colTop - 0.1, z), P.Gold, { reflectance = 0.2 })
		end
		-- a velvet rope swag along each end
		local x = sx * (px + 0.1)
		local pts = { Vector3.new(x, 1.6, -pz), Vector3.new(x, 1.28, -0.9), Vector3.new(x, 1.28, 0.9), Vector3.new(x, 1.6, pz) }
		for k = 1, 3 do
			rod(model, "VelvetRope", pts[k], pts[k + 1], 0.14, P.Crimson, { material = Enum.Material.Fabric })
		end
	end

	-- the crown canopy: onyx deck, gold bands, a warm light panel under it,
	-- gold crown points (gem tips along the front), marquee bulbs all round
	local cy = colTop + 0.15
	part(model, "Canopy", Vector3.new(11.2, 0.3, 6.0), CFrame.new(0, cy, 0), onyx, { solid = true })
	gold(model, "CanopyBand", Vector3.new(11.4, 0.12, 6.2), CFrame.new(0, cy - 0.12, 0))
	-- a raised onyx tier with a gold rim carries the gem
	part(model, "CanopyTier", Vector3.new(7.6, 0.24, 3.4), CFrame.new(0, cy + 0.27, 0), onyx, { solid = true })
	gold(model, "TierRim", Vector3.new(7.8, 0.08, 3.6), CFrame.new(0, cy + 0.19, 0))
	for _, sx in { -1, 1 } do
		gold(model, "TierEdge", Vector3.new(0.08, 0.26, 3.44), CFrame.new(sx * 3.8, cy + 0.27, 0))
		neon(model, "TierGlow", Vector3.new(7.6, 0.05, 0.05), CFrame.new(0, cy + 0.3, sx * 1.72), P.GoldTop)
	end
	local glowPanel = part(model, "CanopyLight", Vector3.new(4.4, 0.05, 4.2), CFrame.new(0, cy - 0.2, 0), hex("#FFE9B8"),
		{ material = Enum.Material.Neon, shadow = false })
	new("SurfaceLight", { Face = Enum.NormalId.Bottom, Brightness = 1.4, Range = 9, Angle = 100, Color = hex("#FFE2A6"),
		Shadows = false }, glowPanel)
	local gems = { P.NeonRed, P.NeonBlue, P.NeonGreen }
	for _, sz in { -1, 1 } do
		for k = 0, 6 do
			local x = -4.8 + k * 1.6
			local tall = k % 2 == 0
			local h = tall and 0.55 or 0.38
			spike(model, "CrownPoint", 0.6, h, 0.12, CFrame.new(x, cy + 0.2, sz * 2.95), P.Gold, { reflectance = 0.2 })
			if tall and sz < 0 then
				ball(model, "CrownJewel", 0.18, Vector3.new(x, cy + 0.2 + h + 0.05, sz * 2.95), gems[(k // 2) % 3 + 1],
					{ material = Enum.Material.Neon, shadow = false })
			end
		end
	end
	for _, sz in { -1, 1 } do
		bulbsAlong(bulbs, Vector3.new(-5.45, cy - 0.12, sz * 3.15), Vector3.new(5.45, cy - 0.12, sz * 3.15), 15, 0.18)
	end
	for _, sx in { -1, 1 } do
		bulbsAlong(bulbs, Vector3.new(sx * 5.75, cy - 0.12, -2.4), Vector3.new(sx * 5.75, cy - 0.12, 2.4), 5, 0.18)
	end

	-- the giant gem, turning slowly on a gold stand
	cylY(model, "GemStand", 0.8, 0.22, Vector3.new(0, cy + 0.5, 0), P.Gold, { reflectance = 0.25 })
	cylY(model, "GemCup", 0.5, 0.1, Vector3.new(0, cy + 0.66, 0), P.GoldTop, { reflectance = 0.25 })
	local spin = spinner(model, "GemSpinner", 40)
	spin.PrimaryPart = cutGem(spin, 0.8, Vector3.new(0, cy + 0.61 + 0.6, 0), hex("#7DF4FF"))
	return model
end

------------------------------------------------------------------
-- BUBBLE TEA BAR (pastel kiosk, three giant cups of boba)
------------------------------------------------------------------
local function bubbleTeaBar(def)
	local model = new("Model", { Name = def.name })
	local bulbs = new("Folder", { Name = "Bulbs" }, model)
	local mint, pink, cream = hex("#5CE1B9"), hex("#FF9CCF"), hex("#FFF4E6")
	local h0 = plinth(model, 5.4, 2.8, hex("#5CFFC9"))
	-- the kiosk counter in pastel stripes (Body / PrimaryPart)
	local body = part(model, "Body", Vector3.new(5.0, 1.5, 1.3), CFrame.new(0, h0 + 0.75, -0.65), cream, { solid = true })
	model.PrimaryPart = body
	for i = 0, 7 do
		part(model, "Stripe", Vector3.new(0.625, 1.5, 0.04), CFrame.new(-2.1875 + i * 0.625, h0 + 0.75, -1.32),
			(i % 2 == 0) and mint or pink)
	end
	gold(model, "CounterTop", Vector3.new(5.2, 0.14, 1.5), CFrame.new(0, h0 + 1.57, -0.65))
	local fp = part(model, "FrontPanel", Vector3.new(2.8, 0.75, 0.06), CFrame.new(0, h0 + 0.8, -1.37), hex("#E2569C"))
	guiText(signPlate(surface(fp, Enum.NormalId.Front, 100, 0.1), hex("#C2338A")), "FRESH BOBA", {
		size = UDim2.fromScale(0.86, 0.62), position = UDim2.fromScale(0.07, 0.19), gradient = { P.GoldTop, P.Gold },
		strokeThickness = 6 })

	-- three giant see-through cups: pastel tea, dark pearls, a lid, a fat straw
	local cupY0 = h0 + 1.64
	local teas = { { 1.55, hex("#B79CED"), P.NeonPink }, { 0, hex("#FFB347"), hex("#5CFFC9") }, { -1.55, hex("#FF8FB5"), P.Amber } }
	for ci, t in teas do
		local x, z = t[1], -0.65
		cylY(model, "Cup", 0.95, 1.35, Vector3.new(x, cupY0 + 0.675, z), t[2], { transparency = 0.4, reflectance = 0.1 })
		for k = 0, 6 do
			local a = k * 2 * math.pi / 7 + ci
			ball(model, "Pearl", 0.2, Vector3.new(x + 0.26 * math.cos(a), cupY0 + 0.14 + (k % 2) * 0.12, z + 0.26 * math.sin(a)),
				hex("#3A1F14"), { reflectance = 0.15 })
		end
		cylY(model, "Lid", 1.02, 0.08, Vector3.new(x, cupY0 + 1.39, z), P.White, { transparency = 0.2 })
		local straw = part(model, "Straw", Vector3.new(1.05, 0.24, 0.24),
			CFrame.new(x + 0.12, cupY0 + 1.75, z) * CFrame.Angles(0, 0, math.rad(90 - 12)), t[3],
			{ material = Enum.Material.Neon, shadow = false })
		straw.Shape = Enum.PartType.Cylinder
	end

	-- back counter: chrome tea urns, cup stacks, a pastel menu board
	part(model, "BackCounter", Vector3.new(5.0, 1.4, 0.7), CFrame.new(0, h0 + 0.7, 0.45), mint, { solid = true })
	gold(model, "BackCounterTop", Vector3.new(5.1, 0.1, 0.8), CFrame.new(0, h0 + 1.45, 0.45))
	for i, x in { 1.7, 0.95, 0.2 } do
		cylY(model, "Urn", 0.5, 0.8, Vector3.new(x, h0 + 1.9, 0.45), P.Chrome, { material = Enum.Material.Metal, reflectance = 0.3 })
		cylY(model, "UrnLid", 0.56, 0.08, Vector3.new(x, h0 + 2.34, 0.45), ({ hex("#B79CED"), hex("#FFB347"), hex("#FF8FB5") })[i])
	end
	for k = 0, 2 do
		cylY(model, "CupStack", 0.36 - k * 0.02, 0.24, Vector3.new(-1.3, h0 + 1.62 + k * 0.22, 0.45), P.White)
		cylY(model, "CupStack", 0.36 - k * 0.02, 0.24, Vector3.new(-1.85, h0 + 1.62 + k * 0.22, 0.45), pink)
	end
	part(model, "BackWall", Vector3.new(5.0, 3.0, 0.3), CFrame.new(0, h0 + 1.5, 1.15), hex("#3FA88A"), { solid = true })
	local menu = part(model, "Menu", Vector3.new(3.6, 0.8, 0.06), CFrame.new(0, h0 + 2.62, 0.98), cream)
	local mg = surface(menu, Enum.NormalId.Front, 90, 0.1)
	guiText(signPlate(mg, hex("#7A4FD6")), "TARO  ·  MANGO  ·  STRAWBERRY", { size = UDim2.fromScale(0.9, 0.5),
		position = UDim2.fromScale(0.05, 0.25), color = P.White, strokeThickness = 3 })

	-- posts, the mint / pink canopy, the sign, bulbs
	for _, sx in { -1, 1 } do
		cylY(model, "Post", 0.16, 1.7, Vector3.new(sx * 2.4, h0 + 3.0 + 0.85, 1.1), P.Gold, { reflectance = 0.15 })
	end
	canopy(model, 5.6, h0 + 4.55, 1.3, -1.4, 0.55, { mint, pink })
	boardSign(model, "Sign", Vector3.new(3.4, 0.95, 0.25), CFrame.new(0, h0 + 5.1, 1.2), "BUBBLE TEA",
		{ icon = "gem", fill = hex("#C2338A"), bothSides = true })
	bulbsAlong(bulbs, Vector3.new(-2.6, h0 + 3.5, -1.45), Vector3.new(2.6, h0 + 3.5, -1.45), 10)
	return model
end

------------------------------------------------------------------
-- SUSHI BAR (wooden counter, a conveyor loop of maki, red lanterns)
------------------------------------------------------------------
local function sushiBar(def)
	local model = new("Model", { Name = def.name })
	local bulbs = new("Folder", { Name = "Bulbs" }, model)
	local red, wood, woodLight = hex("#D7263D"), hex("#9A5B2E"), hex("#D9A66B")
	local h0 = plinth(model, 6.2, 3.2, P.NeonRed)
	-- the counter (Body / PrimaryPart): wood with a red lacquer front
	local body = part(model, "Body", Vector3.new(5.8, 1.6, 1.6), CFrame.new(0, h0 + 0.8, -0.6), wood, { solid = true })
	model.PrimaryPart = body
	part(model, "FrontLacquer", Vector3.new(5.8, 1.1, 0.06), CFrame.new(0, h0 + 0.75, -1.42), red)
	gold(model, "FrontTrim", Vector3.new(5.85, 0.1, 0.08), CFrame.new(0, h0 + 1.33, -1.42))
	local fp = part(model, "FrontPanel", Vector3.new(2.8, 0.7, 0.06), CFrame.new(0, h0 + 0.75, -1.47), P.CrimsonDeep)
	guiText(signPlate(surface(fp, Enum.NormalId.Front, 100, 0.1), P.CrimsonDeep), "FRESH SUSHI", {
		size = UDim2.fromScale(0.86, 0.62), position = UDim2.fromScale(0.07, 0.19), gradient = { P.GoldTop, P.Gold },
		strokeThickness = 6 })
	part(model, "CounterTop", Vector3.new(6.0, 0.14, 1.8), CFrame.new(0, h0 + 1.67, -0.6), woodLight)

	-- the conveyor loop and its plates of maki
	local beltY = h0 + 1.74
	stadium(model, "Conveyor", 4.2, 1.0, 0.1, Vector3.new(0, beltY + 0.05, -0.6), P.Ink)
	stadium(model, "Belt", 4.2, 0.86, 0.02, Vector3.new(0, beltY + 0.1, -0.6), hex("#56657A"), { material = Enum.Material.Fabric })
	stadium(model, "Island", 4.2, 0.24, 0.06, Vector3.new(0, beltY + 0.13, -0.6), woodLight)
	local fillings = { hex("#FF8A5B"), hex("#7CD36B"), hex("#E0475A") }
	local loopR, straight = 0.31, 4.2
	local total = 2 * straight + 2 * math.pi * loopR
	for k = 0, 6 do
		-- position along the loop (front run, right end, back run, left end)
		local u = (k + 0.5) * total / 7
		local x, z
		if u < straight then
			x, z = straight / 2 - u, -0.6 - loopR
		elseif u < straight + math.pi * loopR then
			local a = (u - straight) / loopR
			x, z = -straight / 2 - loopR * math.sin(a), -0.6 - loopR * math.cos(a)
		elseif u < 2 * straight + math.pi * loopR then
			x, z = -straight / 2 + (u - straight - math.pi * loopR), -0.6 + loopR
		else
			local a = (u - 2 * straight - math.pi * loopR) / loopR
			x, z = straight / 2 + loopR * math.sin(a), -0.6 + loopR * math.cos(a)
		end
		cylY(model, "Plate", 0.36, 0.04, Vector3.new(x, beltY + 0.13, z), P.White, { shadow = false })
		for m = -1, 1, 2 do
			cylY(model, "Maki", 0.15, 0.14, Vector3.new(x + m * 0.08, beltY + 0.22, z), hex("#1E2A1E"))
			cylY(model, "MakiFill", 0.1, 0.02, Vector3.new(x + m * 0.08, beltY + 0.3, z), fillings[k % 3 + 1], { shadow = false })
		end
	end

	-- the back wall, a little roof on two posts, noren curtains, lanterns
	part(model, "BackWall", Vector3.new(5.8, 4.1, 0.4), CFrame.new(0, h0 + 2.05, 1.3), wood, { solid = true })
	local menu = part(model, "Menu", Vector3.new(3.6, 0.75, 0.06), CFrame.new(0, h0 + 2.55, 1.08), P.Cream)
	guiText(signPlate(surface(menu, Enum.NormalId.Front, 90, 0.1), P.Ink, red), "NIGIRI  ·  MAKI  ·  ROLLS",
		{ size = UDim2.fromScale(0.9, 0.5), position = UDim2.fromScale(0.05, 0.25), color = P.Cream, strokeThickness = 3 })
	local eaveY, ridgeY = h0 + 4.05, h0 + 4.75
	for _, sx in { -1, 1 } do
		cylY(model, "Post", 0.2, eaveY - (h0 + 1.74), Vector3.new(sx * 2.85, (eaveY + h0 + 1.74) / 2, -1.3), wood)
	end
	local function slope(z0, y0, z1, y1)
		local len = math.sqrt((z1 - z0) ^ 2 + (y1 - y0) ^ 2)
		part(model, "Roof", Vector3.new(6.4, 0.14, len + 0.1),
			CFrame.new(0, (y0 + y1) / 2, (z0 + z1) / 2) * CFrame.Angles(-math.atan2(y1 - y0, z1 - z0), 0, 0), red,
			{ reflectance = 0.05 })
	end
	slope(-1.62, eaveY, 0.15, ridgeY)
	slope(0.15, ridgeY, 1.55, eaveY + 0.15)
	cylX(model, "Ridge", 0.2, 6.5, Vector3.new(0, ridgeY + 0.08, 0.15), P.Gold, { reflectance = 0.15 })
	for i, x in { 1.95, 0.65, -0.65, -1.95 } do
		local noren = part(model, "Noren", Vector3.new(1.2, 0.75, 0.04), CFrame.new(x, eaveY - 0.42, -1.52), hex("#1F2A5A"),
			{ material = Enum.Material.Fabric })
		local ng = surface(noren, Enum.NormalId.Front, 60, 0.3)
		local dot = new("Frame", { BackgroundColor3 = P.Cream, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.55),
			Size = UDim2.fromScale(0.5, 0.5), SizeConstraint = Enum.SizeConstraint.RelativeYY }, ng)
		new("UICorner", { CornerRadius = UDim.new(0.5, 0) }, dot)
		local _ = i
	end
	for _, sx in { -1, 1 } do
		local lp = Vector3.new(sx * 2.95, eaveY - 0.75, -1.45)
		cylY(model, "LanternCord", 0.04, 0.3, lp + Vector3.new(0, 0.55, 0), P.Ink)
		cylY(model, "LanternCap", 0.36, 0.1, lp + Vector3.new(0, 0.38, 0), P.Ink)
		ball(model, "Lantern", 0.66, lp, P.NeonRed, { material = Enum.Material.Neon, shadow = false })
		cylY(model, "LanternCap", 0.36, 0.1, lp - Vector3.new(0, 0.38, 0), P.Ink)
		cylY(model, "Tassel", 0.1, 0.3, lp - Vector3.new(0, 0.58, 0), P.Gold)
	end
	boardSign(model, "Sign", Vector3.new(2.8, 0.85, 0.25), CFrame.new(0, ridgeY + 0.62, 0.15), "SUSHI",
		{ fill = P.CrimsonDeep, bothSides = true })
	bulbsAlong(bulbs, Vector3.new(-3.05, eaveY + 0.08, -1.66), Vector3.new(3.05, eaveY + 0.08, -1.66), 11)
	return model
end

------------------------------------------------------------------
-- JEWELRY BOUTIQUE (ink-and-gold showcase, glass cases of glowing gems,
-- a velvet back with a gold mirror arch, a big diamond turning on top)
------------------------------------------------------------------
local function jewelryBoutique(def)
	local model = new("Model", { Name = def.name })
	local bulbs = new("Folder", { Name = "Bulbs" }, model)
	local purple, velvet = hex("#8A4DE8"), hex("#4A1C7A")
	local h0 = plinth(model, 6.6, 3.4, hex("#B98CFF"))
	-- the showcase counter (Body / PrimaryPart)
	local body = part(model, "Body", Vector3.new(6.0, 1.4, 1.3), CFrame.new(0, h0 + 0.7, -0.9), P.Ink, { solid = true })
	model.PrimaryPart = body
	gold(model, "CounterBand", Vector3.new(6.1, 0.12, 1.4), CFrame.new(0, h0 + 1.36, -0.9))
	gold(model, "CounterFoot", Vector3.new(6.1, 0.1, 1.4), CFrame.new(0, h0 + 0.06, -0.9))
	local fp = part(model, "FrontPanel", Vector3.new(3.4, 0.8, 0.06), CFrame.new(0, h0 + 0.7, -1.58), purple)
	guiText(signPlate(surface(fp, Enum.NormalId.Front, 100, 0.1), hex("#5B2BB0")), "FINE JEWELRY", {
		size = UDim2.fromScale(0.86, 0.62), position = UDim2.fromScale(0.07, 0.19), gradient = { P.GoldTop, P.Gold },
		strokeThickness = 6 })

	-- three glass cases on velvet, gold corner posts, glowing gems inside
	local caseY0 = h0 + 1.42
	local gemCols = { { P.NeonRed, P.NeonBlue }, { P.NeonGreen, P.NeonPink }, { P.NeonBlue, P.Amber } }
	for i, x in { 2.0, 0, -2.0 } do
		part(model, "CaseVelvet", Vector3.new(1.7, 0.1, 1.0), CFrame.new(x, caseY0 + 0.05, -0.9), velvet,
			{ material = Enum.Material.Fabric })
		part(model, "CaseGlass", Vector3.new(1.8, 0.8, 1.1), CFrame.new(x, caseY0 + 0.4, -0.9), hex("#EBDDFF"),
			{ transparency = 0.7, reflectance = 0.2, shadow = false })
		for _, sx in { -1, 1 } do
			for _, sz in { -1, 1 } do
				gold(model, "CasePost", Vector3.new(0.06, 0.8, 0.06), CFrame.new(x + sx * 0.88, caseY0 + 0.4, -0.9 + sz * 0.53))
			end
		end
		local c = gemCols[i]
		part(model, "Jewel", Vector3.new(0.26, 0.26, 0.26),
			CFrame.new(x - 0.45, caseY0 + 0.3, -0.95) * CFrame.Angles(0, 0, math.rad(54.7)) * CFrame.Angles(0, math.rad(45), 0), c[1],
			{ material = Enum.Material.Neon, shadow = false })
		part(model, "Jewel", Vector3.new(0.34, 0.18, 0.22),
			CFrame.new(x + 0.42, caseY0 + 0.22, -0.85) * CFrame.Angles(0, math.rad(30), 0), c[2],
			{ material = Enum.Material.Neon, shadow = false })
		cylZ(model, "Ring", 0.3, 0.05, Vector3.new(x + 0.05, caseY0 + 0.27, -0.75), P.Gold, { reflectance = 0.3, shadow = false })
		local card = part(model, "GemCard", Vector3.new(0.42, 0.42, 0.02), CFrame.new(x, caseY0 + 0.38, -1.05), P.White,
			{ transparency = 1, shadow = false })
		guiImage(surface(card, Enum.NormalId.Front, 100, 0), "gem")
	end

	-- velvet back panel and wings, the gold mirror arch in the middle
	part(model, "BackPanel", Vector3.new(6.2, 4.3, 0.3), CFrame.new(0, h0 + 2.15, 1.35), velvet,
		{ solid = true, material = Enum.Material.Fabric })
	for _, sx in { -1, 1 } do
		part(model, "Wing", Vector3.new(0.3, 4.3, 1.6), CFrame.new(sx * 3.1, h0 + 2.15, 0.6), P.Ink, { solid = true })
		gold(model, "WingTrim", Vector3.new(0.34, 0.12, 1.64), CFrame.new(sx * 3.1, h0 + 4.24, 0.6))
	end
	local mz, my0, mw = 1.17, h0 + 1.0, 1.9
	local mh = 2.1
	local mirrorCol = hex("#DCE6F2")
	part(model, "Mirror", Vector3.new(mw, mh, 0.05), CFrame.new(0, my0 + mh / 2, mz), mirrorCol,
		{ reflectance = 0.45, shadow = false })
	cylZ(model, "MirrorTop", mw, 0.05, Vector3.new(0, my0 + mh, mz), mirrorCol, { reflectance = 0.45, shadow = false })
	for _, sx in { -1, 1 } do
		gold(model, "ArchPost", Vector3.new(0.16, mh, 0.12), CFrame.new(sx * (mw / 2 + 0.08), my0 + mh / 2, mz - 0.03))
	end
	local prev
	for k = 0, 8 do
		local a = math.pi * k / 8
		local p = Vector3.new((mw / 2 + 0.08) * math.cos(a), my0 + mh + (mw / 2 + 0.08) * math.sin(a), mz - 0.05)
		if prev then rod(model, "Arch", prev, p, 0.14, P.Gold, { reflectance = 0.2 }) end
		prev = p
	end

	-- crown molding, the sign, and the big diamond on top ringed with bulbs
	part(model, "Cornice", Vector3.new(6.5, 0.25, 0.9), CFrame.new(0, h0 + 4.42, 1.15), P.Ink, { solid = true })
	gold(model, "CorniceTrim", Vector3.new(6.6, 0.12, 1.0), CFrame.new(0, h0 + 4.3, 1.15))
	local signY = h0 + 4.55 + 0.43
	boardSign(model, "Sign", Vector3.new(3.6, 0.85, 0.25), CFrame.new(0, signY, 1.2), "JEWELRY",
		{ icon = "gem", fill = hex("#5B2BB0"), bothSides = true })
	local standY = signY + 0.43
	cylY(model, "DiamondStand", 0.62, 0.16, Vector3.new(0, standY + 0.08, 1.2), P.Gold, { reflectance = 0.25 })
	local spin = spinner(model, "DiamondSpinner", 45)
	spin.PrimaryPart = cutGem(spin, 0.7, Vector3.new(0, standY + 0.16 + 0.62, 1.2), hex("#A9F6FF"))
	for k = 0, 9 do
		local a = k * math.pi / 5
		local b = ball(bulbs, "Bulb", 0.14, Vector3.new(0.55 * math.cos(a), standY + 0.1, 1.2 + 0.55 * math.sin(a)),
			(k % 2 == 0) and P.GoldTop or P.White, { material = Enum.Material.Neon, shadow = false })
		b:SetAttribute("Phase", k % 2)
	end
	for _, sx in { -1, 1 } do
		bulbsAlong(bulbs, Vector3.new(sx * 3.1, h0 + 0.7, -0.24), Vector3.new(sx * 3.1, h0 + 4.0, -0.24), 8)
	end
	return model
end

------------------------------------------------------------------
-- THE REBIRTH WING: 13 machines, each unlocked by a rebirth (Config.Catalog
-- `rebirth`). Each has its own silhouette and colour story and reuses one of
-- the six game types and its rig:
--   Phoenix Fire (Slots)        a phoenix with raised flame wings on a brazier
--   Thunder Wheel (Wheel)       tesla coils and a storm cloud throwing bolts
--   Crystal Cavern (Dice)       ice dice in an orb in a cluster of crystals
--   Galaxy Drop (Plinko)        star pins, a ringed planet with orbiting moons
--   Pharaoh's Fortune (Roulette) obelisks and a pylon with a winged sun
--   Pot o' Gold (Slots)         a rainbow from cloud to cloud, a pot of gold
--   Royal Crown 21 (Blackjack)  a velvet throne back crowned, royal banners
--   Neptune's Treasure (Plinko) a scallop shell crest, pearl pins, a trident
--   Volcano Eruption (Dice)     a lava cone: the dice erupt from the crater
--   Emperor's Wheel (Wheel)     a red-and-gold gate under a golden roof
--   Diamond Vault (Slots)       a vault door with a turning handle, gold bars
--   Celestial Roulette          a turning armillary sphere over the table
--   Midas Touch (Slots)         all gold on marble, a diamond in a sunburst
-- Kit additions: arcs / hoops of rods, bulb arcs, crystals, lightning bolts,
-- sparse particle effects and spinners that turn about any axis.
------------------------------------------------------------------
local function neonO(transparency: number?)
	return { material = Enum.Material.Neon, shadow = false, transparency = transparency }
end
local function metalO(reflectance: number?)
	return { material = Enum.Material.Metal, reflectance = reflectance or 0.25 }
end

-- points on an arc in cf's XY plane (angle 0 = cf's +X, pi / 2 = its +Y)
local function arcPoints(cf: CFrame, r: number, a0: number, a1: number, n: number): { Vector3 }
	local pts = {}
	for k = 0, n do
		local a = a0 + (a1 - a0) * k / n
		pts[k + 1] = cf:PointToWorldSpace(Vector3.new(math.cos(a) * r, math.sin(a) * r, 0))
	end
	return pts
end

-- rods along an arc (a hoop when it closes): the torus stand-in. Every rod
-- runs a little past its points, so the joints close.
local function arcRods(parent, name: string, cf: CFrame, r: number, a0: number, a1: number, n: number, d: number,
	color: Color3, opts)
	local pts = arcPoints(cf, r, a0, a1, n)
	for k = 1, n do
		local a, b = pts[k], pts[k + 1]
		local dir = (b - a).Unit
		rod(parent, name, a - dir * (d * 0.3), b + dir * (d * 0.3), d, color, opts)
	end
	return pts
end
local function hoop(parent, name: string, cf: CFrame, r: number, n: number, d: number, color: Color3, opts)
	return arcRods(parent, name, cf, r, 0, 2 * math.pi, n, d, color, opts)
end

-- marquee bulbs spread along an arc in cf's XY plane (a full turn leaves the
-- last bulb a step short of the first)
local function bulbArc(folder: Instance, cf: CFrame, r: number, a0: number, a1: number, n: number, d: number?)
	local closed = math.abs((a1 - a0) - 2 * math.pi) < 1e-6
	for k = 0, n - 1 do
		local t = closed and k / n or (n == 1 and 0.5 or k / (n - 1))
		local a = a0 + (a1 - a0) * t
		local b = ball(folder, "Bulb", d or 0.16, cf:PointToWorldSpace(Vector3.new(math.cos(a) * r, math.sin(a) * r, 0)),
			(k % 2 == 0) and P.GoldTop or P.White, neonO())
		b:SetAttribute("Phase", k % 2)
	end
end

-- a crystal: a square prism turned 45 deg (a diamond from the front) on
-- `base`, tipped by a cube on its corner; `lean` turns it about the base
local function crystal(parent, name: string, base: Vector3, h: number, w: number, lean: CFrame, color: Color3,
	transparency: number?)
	local cf = CFrame.new(base) * lean * CFrame.Angles(0, math.rad(45), 0)
	part(parent, name, Vector3.new(w, h, w), cf * CFrame.new(0, h / 2, 0), color, neonO(transparency or 0.3))
	local c = w * 0.8
	part(parent, name .. "Tip", Vector3.new(c, c, c),
		cf * CFrame.new(0, h, 0) * CFrame.Angles(0, 0, math.rad(54.7356)) * CFrame.Angles(0, math.rad(45), 0), color,
		neonO(transparency or 0.3))
end

-- a lightning bolt through `pts` (neon rods with rounded joints)
local function bolt(parent, name: string, pts: { Vector3 }, d: number, color: Color3)
	for k = 1, #pts - 1 do
		rod(parent, name, pts[k], pts[k + 1], d, color, neonO())
		if k > 1 then ball(parent, name, d, pts[k], color, neonO()) end
	end
end

-- a small four-point twinkle (two crossed neon bars and a bright core)
local function twinkle(parent, pos: Vector3, s: number, color: Color3)
	part(parent, "Twinkle", Vector3.new(0.06 * s, s, 0.06 * s), CFrame.new(pos), color, neonO())
	part(parent, "Twinkle", Vector3.new(s * 0.7, 0.06 * s, 0.06 * s), CFrame.new(pos), color, neonO())
	ball(parent, "Twinkle", 0.16 * s, pos, P.White, neonO())
end

-- an invisible emitter plate (its Top face sends particles up) with a sparse
-- effect: "sparks" (glowing motes) or "smoke"; every placed copy runs it
local FX_TEXTURE = {
	sparks = "rbxasset://textures/particles/sparkles_main.dds",
	smoke = "rbxasset://textures/particles/smoke_main.dds",
}
local function particles(parent, name: string, size: Vector3, pos: Vector3, kind: string, color: Color3, rate: number?,
	speed: number?)
	local plate = part(parent, name, size, CFrame.new(pos), P.White, { transparency = 1, shadow = false })
	local smoke = kind == "smoke"
	new("ParticleEmitter", {
		Name = smoke and "Smoke" or "Sparks", Texture = FX_TEXTURE[kind] or FX_TEXTURE.sparks,
		Rate = rate or (smoke and 3 or 5), EmissionDirection = Enum.NormalId.Top,
		Lifetime = smoke and NumberRange.new(2, 3.5) or NumberRange.new(0.8, 1.6),
		Speed = NumberRange.new((speed or (smoke and 2 or 3)) * 0.6, speed or (smoke and 2 or 3)),
		SpreadAngle = Vector2.new(22, 22), Color = ColorSequence.new(color),
		LightEmission = smoke and 0 or 1, LightInfluence = smoke and 1 or 0,
		Size = smoke and NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.7), NumberSequenceKeypoint.new(1, 2.8) })
			or NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(1, 0) }),
		Transparency = smoke and NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.55), NumberSequenceKeypoint.new(1, 1) })
			or NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 0.5) }),
	}, plate)
	return plate
end

-- a spinner (MachineFX turns it about its PrimaryPart's +Y) whose axis is
-- `up` (default: straight up): an invisible core at `pos` is its PrimaryPart
local function spinnerAt(parent, name: string, rate: number, pos: Vector3, up: Vector3?): Model
	local m = spinner(parent, name, rate)
	local cf = CFrame.new(pos)
	if up then
		local u = up.Unit
		local ref = math.abs(u.Y) < 0.9 and Vector3.new(0, 1, 0) or Vector3.new(1, 0, 0)
		cf = CFrame.fromMatrix(pos, ref:Cross(u).Unit, u)
	end
	m.PrimaryPart = part(m, "Core", Vector3.new(0.2, 0.2, 0.2), cf, P.White, { transparency = 1, shadow = false })
	return m
end

-- strip a slot cabinet's candle (a topper takes its place)
local function dropCandle(model: Model)
	for _, n in { "CandleBase", "Candle" } do
		local c = model:FindFirstChild(n)
		if c then c:Destroy() end
	end
end

-- a gold coin lying (or leaning) at pos
local function coin(parent, pos: Vector3, d: number, tilt: CFrame?)
	return part(parent, "Coin", Vector3.new(0.07, d, d), CFrame.new(pos) * (tilt or CFrame.new()) * CFrame.Angles(0, 0, math.rad(90)),
		P.Gold, { shape = Enum.PartType.Cylinder, reflectance = 0.3, shadow = false })
end

------------------------------------------------------------------
-- PHOENIX FIRE (rebirth 1, Slots): a fire-red cabinet; on a gold brazier
-- behind the marquee a phoenix spreads raised flame wings (orange feathers
-- with yellow cores); flame tongues lick the plinth, embers rise
------------------------------------------------------------------
local function phoenixFire(def)
	local S = 1.05
	local model = scaled(slotMachine(def, { color = hex("#7A140E"), accent = hex("#FF7A1A"), title = "PHOENIX",
		belly = "777" }), S)
	dropCandle(model)
	local fire, flame, ember, blaze = hex("#E8361C"), hex("#FF6A1A"), hex("#FFC93C"), hex("#FF3B1F")
	local W, D = 3.6 * S, 2.8 * S
	local top = 5.15 * S -- the upper cabinet's top, behind the marquee

	-- flame-orange neon down the cabinet's front edges
	for _, sx in { -1, 1 } do
		neon(model, "EdgeFlame", Vector3.new(0.06, 2.1 * S, 0.06), CFrame.new(sx * (W / 2 + 0.03), (0.45 + 1.15) * S, -D / 2 + 0.16), flame)
		neon(model, "EdgeFlame", Vector3.new(0.06, 2.2 * S, 0.06), CFrame.new(sx * (W / 2 + 0.03), (2.75 + 1.2) * S, -0.82 * S), flame)
	end

	-- the brazier, flames round its rim
	local bz = 0.6
	cylY(model, "Brazier", 1.3, 1.5, Vector3.new(0, top + 0.75, bz), P.Gold, { reflectance = 0.15 })
	cylY(model, "BrazierRim", 1.55, 0.14, Vector3.new(0, top + 1.52, bz), P.GoldTop, { reflectance = 0.2 })
	for i = 0, 7 do
		local a = i * math.pi / 4
		spike(model, "BrazierFlame", 0.38, 0.5 + (i % 2) * 0.26, 0.06,
			CFrame.new(math.cos(a) * 0.62, top + 1.56, bz + math.sin(a) * 0.62) * CFrame.Angles(0, math.pi / 2 - a, 0),
			(i % 2 == 0) and flame or ember, neonO())
	end

	-- the bird: body, neck, head looking at the player, hooked beak, crest
	local function orb(name, d, pos, color)
		return ball(model, name, d, pos, color, { reflectance = 0.1 })
	end
	local by = top + 2.3
	orb("PhoenixBody", 1.25, Vector3.new(0, by, bz), fire)
	orb("PhoenixBelly", 1.0, Vector3.new(0, by - 0.45, bz + 0.12), hex("#C42414"))
	orb("PhoenixNeck", 0.7, Vector3.new(0, by + 0.62, bz - 0.22), flame)
	local head = Vector3.new(0, by + 1.08, bz - 0.42)
	orb("PhoenixHead", 0.74, head, hex("#FF8A1F"))
	wedge(model, "PhoenixBeak", Vector3.new(0.2, 0.26, 0.5), CFrame.new(head + Vector3.new(0, -0.07, -0.5)), P.Gold,
		{ reflectance = 0.2 })
	for _, s in { -1, 1 } do
		ball(model, "PhoenixEye", 0.14, head + Vector3.new(s * 0.21, 0.1, -0.29), ember, neonO())
	end
	for k = -1, 1 do
		spike(model, "PhoenixCrest", 0.2, 0.66 - math.abs(k) * 0.14, 0.06,
			CFrame.new(head + Vector3.new(k * 0.12, 0.25, 0.12)) * CFrame.Angles(math.rad(28), 0, math.rad(-k * 24)), ember, neonO())
	end

	-- the wings: an arm from the shoulder to the wrist and seven feathers
	-- along it, fanning from straight up (inner) to 40 deg (outer, longest);
	-- each feather is red flame round an orange one round a yellow core
	for _, s in { -1, 1 } do
		local A = Vector3.new(s * 0.45, by + 0.2, bz + 0.06)
		local B = Vector3.new(s * 1.4, by + 1.1, bz + 0.12)
		rod(model, "WingArm", A, B, 0.36, fire, { reflectance = 0.1 })
		for i = 0, 6 do
			local root = A:Lerp(B, i / 6) + Vector3.new(0, 0, i * 0.02)
			local theta = math.rad(115 - 12.5 * i)
			local len = 1.15 + 0.2 * i
			local cf = CFrame.new(root) * CFrame.Angles(0, 0, s * (theta - math.pi / 2))
			spike(model, "Feather", 0.5, len, 0.08, cf, blaze, neonO())
			spike(model, "FeatherMid", 0.34, len * 0.74, 0.08, cf * CFrame.new(0, 0, -0.05), flame, neonO())
			spike(model, "FeatherCore", 0.18, len * 0.44, 0.08, cf * CFrame.new(0, 0, -0.1), ember, neonO())
		end
	end
	-- three long tail feathers over the cabinet's back
	for k = -1, 1 do
		spike(model, "TailFeather", 0.42, 2.3 - math.abs(k) * 0.4, 0.08,
			CFrame.new(k * 0.18, by - 0.4, bz + 0.45) * CFrame.Angles(math.rad(146), 0, math.rad(k * 16)),
			k == 0 and ember or flame, neonO())
	end

	-- flame tongues along the plinth front, either side of the coin tray
	local pz = -1.6 * S
	for _, s in { -1, 1 } do
		for i, x in { 1.22, 1.58, 1.94 } do
			spike(model, "FlameTongue", 0.34, 0.32 + ((i + (s > 0 and 1 or 0)) % 3) * 0.14, 0.06,
				CFrame.new(s * x, 0.45 * S, pz), (i % 2 == 0) and ember or flame, neonO())
		end
	end
	particles(model, "EmberFX", Vector3.new(1.6, 0.1, 0.9), Vector3.new(0, by + 0.7, bz + 0.1), "sparks", ember, 6, 3.5)
	return model
end

------------------------------------------------------------------
-- THUNDER WHEEL (rebirth 1, Wheel): an indigo prize wheel between two tesla
-- coils (copper secondaries, chrome toroids, plasma orbs) under a storm
-- cloud; bolts jump from the orbs to the cloud
------------------------------------------------------------------
local function thunderWheel(def)
	local S = 1.15
	local storm, stormLight, plasma, zap = hex("#33406B"), hex("#56648F"), hex("#BFF4FF"), hex("#FFF27A")
	local model = scaled(fortuneWheel(def, { body = hex("#1E2A8C"), title = "THUNDER", icon = "star", glow = hex("#5CC8FF"),
		signFill = hex("#13206B") }), S)
	local pointer = model:FindFirstChild("Pointer")
	if pointer and pointer:IsA("BasePart") then pointer.Color = zap end

	-- the tesla coils
	local cz = 0.35
	local orbs = {}
	for _, s in { -1, 1 } do
		local x = s * 3.6
		cylY(model, "CoilBase", 1.0, 0.45, Vector3.new(x, 0.225, cz), P.Ink, { solid = true })
		cylY(model, "CoilBaseLip", 1.1, 0.1, Vector3.new(x, 0.45, cz), P.Gold, { reflectance = 0.15 })
		cylY(model, "CoilPost", 0.36, 0.6, Vector3.new(x, 0.8, cz), P.Chrome, metalO())
		cylY(model, "Coil", 0.62, 4.2, Vector3.new(x, 3.2, cz), hex("#C8763A"), metalO(0.2))
		for k = 0, 11 do
			cylY(model, "CoilBand", 0.64, 0.05, Vector3.new(x, 1.3 + k * 0.33, cz), hex("#5A2E12"), { shadow = false })
		end
		cylY(model, "CoilCap", 0.5, 0.25, Vector3.new(x, 5.42, cz), P.Chrome, metalO())
		for k = 0, 7 do
			local a = k * math.pi / 4
			ball(model, "Toroid", 0.42, Vector3.new(x + math.cos(a) * 0.5, 5.9, cz + math.sin(a) * 0.5), P.Chrome, metalO(0.3))
		end
		local orb = Vector3.new(x, 6.05, cz)
		ball(model, "Plasma", 0.62, orb, plasma, neonO())
		orbs[s] = orb
	end

	-- the storm cloud behind the THUNDER sign
	local cloud = {
		{ 0, 9.95, 1.5 }, { -1.0, 9.75, 1.3 }, { 1.0, 9.8, 1.35 }, { -2.0, 9.35, 1.1 }, { 2.0, 9.35, 1.15 },
		{ -2.75, 9.05, 0.85 }, { 2.75, 9.05, 0.85 }, { 0.55, 10.3, 1.0 }, { -0.6, 10.25, 0.9 },
	}
	for i, c in cloud do
		ball(model, "Cloud", c[3], Vector3.new(c[1], c[2], 0.75), (i % 2 == 0) and stormLight or storm)
	end
	-- bolts from the plasma orbs up to the cloud, two forks under it
	for _, s in { -1, 1 } do
		local o = orbs[s]
		bolt(model, "Bolt", {
			o + Vector3.new(0, 0.3, 0), Vector3.new(s * 3.2, 7.0, cz), Vector3.new(s * 3.55, 7.45, cz),
			Vector3.new(s * 2.95, 8.25, cz), Vector3.new(s * 3.2, 8.55, cz), Vector3.new(s * 2.7, 9.0, 0.6),
		}, 0.12, zap)
		bolt(model, "Bolt", {
			Vector3.new(s * 1.45, 8.95, 0.6), Vector3.new(s * 1.25, 8.6, 0.45), Vector3.new(s * 1.55, 8.35, 0.4),
			Vector3.new(s * 1.35, 8.05, 0.35),
		}, 0.09, zap)
	end
	particles(model, "SparkFX", Vector3.new(0.5, 0.1, 0.5), orbs[1] + Vector3.new(0, 0.35, 0), "sparks", plasma, 4, 2.5)
	particles(model, "SparkFX", Vector3.new(0.5, 0.1, 0.5), orbs[-1] + Vector3.new(0, 0.35, 0), "sparks", plasma, 4, 2.5)
	return model
end

------------------------------------------------------------------
-- CRYSTAL CAVERN (rebirth 2, Dice): a violet pedestal in lilac rock, three
-- ice dice in a clear orb, crystal clusters bursting up round it
------------------------------------------------------------------
local function crystalCavern(def)
	local model = new("Model", { Name = def.name })
	local bulbs = new("Folder", { Name = "Bulbs" }, model)
	local ice, lilac, pink = hex("#7FE3FF"), hex("#C79BFF"), hex("#FFB8F0")
	local violet, violetDeep, rock, rockLight = hex("#3B2A6B"), hex("#241848"), hex("#4B3C7A"), hex("#5E4E92")
	local h0 = plinth(model, 5.4, 4.2, ice)

	-- the pedestal (Body / PrimaryPart), its sign, gold edges and deck
	local body = part(model, "Body", Vector3.new(3.0, 2.2, 2.6), CFrame.new(0, h0 + 1.1, 0.1), violet,
		{ solid = true, reflectance = 0.05 })
	model.PrimaryPart = body
	local fp = part(model, "FrontPanel", Vector3.new(2.5, 0.9, 0.06), CFrame.new(0, h0 + 1.0, -1.23), violetDeep)
	guiText(signPlate(surface(fp, Enum.NormalId.Front, 100, 0.1), hex("#5B2BB0")), "CRYSTAL DICE", {
		size = UDim2.fromScale(0.86, 0.6), position = UDim2.fromScale(0.07, 0.2), gradient = { P.GoldTop, P.Gold },
		strokeThickness = 6 })
	for _, sx in { -1, 1 } do
		gold(model, "EdgeTrim", Vector3.new(0.14, 2.2, 0.14), CFrame.new(sx * 1.5, h0 + 1.1, -1.2))
	end
	gold(model, "Deck", Vector3.new(3.1, 0.16, 2.7), CFrame.new(0, h0 + 2.28, 0.1))

	-- the orb: gold ring, felt pad, a clear bubble over three ice dice
	local padY, oz = h0 + 2.36, 0.1
	cylY(model, "DomeRing", 2.8, 0.22, Vector3.new(0, padY + 0.11, oz), P.Gold, { reflectance = 0.15 })
	cylY(model, "Pad", 2.45, 0.06, Vector3.new(0, padY + 0.25, oz), violetDeep, { material = Enum.Material.Fabric })
	ball(model, "Dome", 2.6, Vector3.new(0, padY + 0.28, oz), hex("#DFF8FF"), { transparency = 0.82, reflectance = 0.3, shadow = false })
	local ds, dy = 0.62, padY + 0.28 + 0.31
	local pip = hex("#5B2BB0")
	for _, d in {
		die(model, "Die1", ds, CFrame.new(-0.46, dy, oz + 0.14) * CFrame.Angles(0, math.rad(22), 0), pip),
		die(model, "Die2", ds, CFrame.new(0.48, dy, oz + 0.22) * CFrame.Angles(0, math.rad(-28), 0), pip),
		die(model, "Die3", ds, CFrame.new(0.02, dy, oz - 0.42) * CFrame.Angles(0, math.rad(38), 0), pip),
	} do
		d.Color = hex("#E8FBFF")
		d.Reflectance = 0.2
	end
	model:SetAttribute("DiceHop", 0.5) -- MachineFX: they stay in the orb
	bulbArc(bulbs, CFrame.new(0, padY + 0.11, oz) * CFrame.Angles(math.rad(90), 0, 0), 1.5, 0, 2 * math.pi, 18, 0.15)

	-- dark amethyst rock: an outcrop behind the orb, low mounds at the sides
	local rocks = {
		{ 0, h0 + 2.55, 1.6, 2.6, 1.2, 1.0, 8, 0 }, { -0.85, h0 + 2.9, 1.75, 1.0, 0.75, 0.8, 25, 12 },
		{ 0.9, h0 + 2.85, 1.7, 0.95, 0.7, 0.8, -20, -10 }, { 2.05, h0 + 0.3, 0.45, 1.1, 0.75, 1.5, 15, 6 },
		{ -2.05, h0 + 0.3, 0.4, 1.1, 0.7, 1.5, -12, -8 }, { 2.15, h0 + 0.2, -1.45, 0.6, 0.45, 0.6, 30, 10 },
		{ -2.15, h0 + 0.2, -1.4, 0.6, 0.45, 0.6, -25, -6 },
	}
	for i, r in rocks do
		part(model, "Rock", Vector3.new(r[4], r[5], r[6]),
			CFrame.new(r[1], r[2], r[3]) * CFrame.Angles(math.rad(r[8]), math.rad(r[7]), math.rad(r[8] * 0.5)),
			(i % 2 == 0) and rockLight or rock, { material = Enum.Material.Slate })
	end

	-- the crystals: x, base y, z, height, width, lean x / z (deg), colour
	local shards = {
		{ 0, h0 + 3.0, 1.75, 3.4, 0.74, 6, 0, ice }, { -0.8, h0 + 3.0, 1.8, 2.3, 0.52, 8, 18, lilac },
		{ 0.82, h0 + 3.0, 1.75, 2.45, 0.52, 6, -15, pink }, { -1.45, h0 + 2.6, 1.6, 1.5, 0.42, 4, 34, ice },
		{ 1.5, h0 + 2.6, 1.6, 1.4, 0.4, 4, -36, lilac },
		{ 2.05, h0 + 0.9, 0.5, 2.1, 0.5, -8, -24, ice }, { 2.25, h0 + 0.8, -0.2, 1.4, 0.4, -18, -38, pink },
		{ 1.9, h0 + 0.8, 1.15, 1.6, 0.42, 14, -18, lilac },
		{ -2.05, h0 + 0.9, 0.45, 2.2, 0.5, -6, 24, lilac }, { -2.25, h0 + 0.8, -0.25, 1.3, 0.4, -18, 36, ice },
		{ -1.9, h0 + 0.8, 1.1, 1.7, 0.42, 14, 20, pink },
		{ 2.2, h0 + 0.5, -1.45, 0.9, 0.32, -14, -26, ice }, { -2.2, h0 + 0.5, -1.4, 0.95, 0.32, -14, 26, lilac },
	}
	for _, c in shards do
		crystal(model, "Crystal", Vector3.new(c[1], c[2], c[3]), c[4], c[5], CFrame.Angles(math.rad(c[6]), 0, math.rad(c[7])), c[8])
	end

	-- the sign over the orb, on gold posts in the outcrop
	for _, sx in { -1, 1 } do
		gold(model, "SignPost", Vector3.new(0.12, 1.2, 0.12), CFrame.new(sx * 1.3, h0 + 3.55, 1.28))
	end
	boardSign(model, "Topper", Vector3.new(3.9, 0.82, 0.22), CFrame.new(0, h0 + 4.55, 1.25), "CRYSTAL CAVERN",
		{ icon = "gem", fill = hex("#3B1E7A") })
	bulbsAlong(bulbs, Vector3.new(-1.85, h0 + 5.02, 1.12), Vector3.new(1.85, h0 + 5.02, 1.12), 10)
	particles(model, "SparkleFX", Vector3.new(1.4, 0.1, 1.4), Vector3.new(0, padY + 0.7, oz), "sparks", ice, 3, 1.5)
	return model
end

------------------------------------------------------------------
-- GALAXY DROP (rebirth 2, Plinko): an indigo arcade cabinet, a starfield
-- behind glowing star pins, a ringed planet up top with two moons orbiting it
------------------------------------------------------------------
local function starfield(gui, top: Color3, bottom: Color3, n: number)
	local bg = new("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = P.White, BorderSizePixel = 0 }, gui)
	new("UIGradient", { Rotation = 90, Color = ColorSequence.new(top, bottom) }, bg)
	for k = 1, n do
		local x = (k * 0.6180339) % 1
		local y = (k * 0.3819660 + (k * k) * 0.0137) % 1
		local s = 0.012 + (k % 4) * 0.005
		local dot = new("Frame", { BackgroundColor3 = (k % 5 == 0) and hex("#FFE9A8") or P.White, BorderSizePixel = 0,
			AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(x, y), Size = UDim2.fromScale(s, s),
			SizeConstraint = Enum.SizeConstraint.RelativeXX, ZIndex = 2 }, gui)
		new("UICorner", { CornerRadius = UDim.new(0.5, 0) }, dot)
	end
	return bg
end

local function galaxyDrop(def)
	local model = new("Model", { Name = def.name })
	local bulbs = new("Folder", { Name = "Bulbs" }, model)
	local indigo, deep, magenta, cyan, star = hex("#2A1466"), hex("#120A33"), hex("#FF4FD8"), hex("#5CE1FF"), hex("#FFF6D8")
	local h0 = plinth(model, 5.0, 2.9, magenta)

	-- lower cabinet (Body / PrimaryPart), belly sign, gold edges
	local body = part(model, "Body", Vector3.new(4.6, 2.0, 2.6), CFrame.new(0, h0 + 1.0, 0), indigo,
		{ solid = true, reflectance = 0.06 })
	model.PrimaryPart = body
	local belly = part(model, "Belly", Vector3.new(3.8, 1.15, 0.08), CFrame.new(0, h0 + 0.95, -1.34), deep)
	guiText(signPlate(surface(belly, Enum.NormalId.Front, 100, 0.1), hex("#3A1A8C")), "STAR DROP!", {
		size = UDim2.fromScale(0.86, 0.58), position = UDim2.fromScale(0.07, 0.21), gradient = { P.GoldTop, P.Gold },
		strokeThickness = 6 })
	for _, sx in { -1, 1 } do
		gold(model, "EdgeTrim", Vector3.new(0.14, 2.0, 0.14), CFrame.new(sx * 2.3, h0 + 1.0, -1.3))
	end
	local deckY = h0 + 2.0
	gold(model, "Deck", Vector3.new(4.7, 0.2, 0.7), CFrame.new(0, deckY + 0.1, -1.1))
	cylY(model, "DropButton", 0.62, 0.14, Vector3.new(-1.3, deckY + 0.27, -1.12), cyan, neonO())
	for i, c in { magenta, P.Amber } do
		cylY(model, "Button" .. i, 0.3, 0.1, Vector3.new(0.9 + (i - 1) * 0.5, deckY + 0.25, -1.12), c, neonO())
	end

	-- the board: a starfield back between indigo pillars (neon edges), a
	-- header bar, glass
	local boardTop = deckY + 4.9
	local by, bh = (deckY + boardTop) / 2, boardTop - deckY
	local back = part(model, "BoardBack", Vector3.new(4.3, bh, 0.2), CFrame.new(0, by, 0.65), deep, { solid = true })
	local sg = surface(back, Enum.NormalId.Front, 40, 0)
	pcall(function() sg.Brightness = 1.4 end)
	starfield(sg, hex("#3A1470"), hex("#0B0830"), 46)
	for i, c in { { 0.3, 0.3, 0.45, magenta }, { 0.72, 0.62, 0.38, cyan } } do
		local neb = new("Frame", { BackgroundColor3 = c[4], BackgroundTransparency = 0.84, BorderSizePixel = 0,
			AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(c[1], c[2]), Size = UDim2.fromScale(c[3], c[3]),
			SizeConstraint = Enum.SizeConstraint.RelativeXX, ZIndex = 1 + i }, sg)
		new("UICorner", { CornerRadius = UDim.new(0.5, 0) }, neb)
	end
	for _, sx in { -1, 1 } do
		part(model, "Pillar", Vector3.new(0.3, bh, 1.0), CFrame.new(sx * 2.3, by, 0.3), indigo, { solid = true })
		gold(model, "PillarTrim", Vector3.new(0.12, bh, 0.12), CFrame.new(sx * 2.3, by, -0.22))
		neon(model, "PillarNeon", Vector3.new(0.06, bh - 0.4, 0.06), CFrame.new(sx * 2.12, by, -0.18), magenta)
		neon(model, "PillarNeon", Vector3.new(0.06, bh - 0.4, 0.06), CFrame.new(sx * 2.48, by, -0.18), cyan)
	end
	part(model, "Header", Vector3.new(4.9, 0.25, 1.0), CFrame.new(0, boardTop + 0.125, 0.3), indigo, { solid = true })
	gold(model, "HeaderTrim", Vector3.new(4.9, 0.08, 0.1), CFrame.new(0, boardTop + 0.02, -0.22))
	part(model, "Glass", Vector3.new(4.3, bh - 0.3, 0.04), CFrame.new(0, by - 0.1, 0.18), hex("#E2D8FF"),
		{ transparency = 0.88, reflectance = 0.15, shadow = false })

	-- the pins glow like stars; the ball is a comet
	local top = Vector3.new(0, deckY + 4.06, 0.4)
	plinkoBoard(model, top, { dx = 0.44, dy = 0.4, pegD = 0.14, pegLen = 0.3, ballD = 0.3, pocketH = 0.6, labelH = 0.28,
		startUp = 0.5, ballColor = hex("#FFF2A0") })
	local pegs = model:FindFirstChild("Pegs")
	for i, p in (pegs and pegs:GetChildren() or {}) do
		if p:IsA("BasePart") then
			p.Material = Enum.Material.Neon
			p.Color = (i % 3 == 0) and cyan or star
		end
	end
	local chuteY = top.Y + 0.5
	cylY(model, "Chute", 0.7, 0.1, Vector3.new(0, chuteY + 0.22, top.Z), P.Chrome, metalO(0.3))

	-- the topper sign, and over it a ringed planet with two orbiting moons
	local signY = boardTop + 0.25 + 0.38
	boardSign(model, "Topper", Vector3.new(4.4, 0.76, 0.3), CFrame.new(0, signY, 0.35), "GALAXY DROP",
		{ icon = "star", fill = hex("#2A0F66") })
	bulbFrame(bulbs, 0, signY, 4.5, 0.86, 0.15, 10)
	for _, sx in { -1, 1 } do
		bulbsAlong(bulbs, Vector3.new(sx * 2.3, deckY + 0.45, -0.36), Vector3.new(sx * 2.3, boardTop - 0.35, -0.36), 8)
	end
	local pc = Vector3.new(0, signY + 1.45, 0.4)
	ball(model, "Planet", 1.9, pc, hex("#9B3DFF"), { reflectance = 0.12 })
	ball(model, "PlanetCap", 1.2, pc + Vector3.new(-0.32, 0.38, -0.3), hex("#C77DFF"), { reflectance = 0.12 })
	local tilt = CFrame.new(pc) * CFrame.Angles(0, 0, math.rad(-16)) * CFrame.Angles(math.rad(72), 0, 0)
	hoop(model, "PlanetRing", tilt, 1.62, 26, 0.15, hex("#FFE9A8"), neonO())
	hoop(model, "PlanetRing", tilt, 1.34, 24, 0.09, magenta, neonO())
	local moons = spinnerAt(model, "Moons", 28, pc)
	ball(moons, "Moon", 0.42, pc + Vector3.new(2.2, 0.3, 0), cyan, neonO())
	ball(moons, "Moon", 0.3, pc + Vector3.new(-1.95, -0.45, 0.5), star, neonO())
	for _, t in { { 2.35, signY + 2.55, 0.2, 0.55 }, { -2.3, signY + 2.3, 0.3, 0.45 }, { 1.4, signY + 2.85, 0.6, 0.35 } } do
		twinkle(model, Vector3.new(t[1], t[2], t[3]), t[4], star)
	end
	return model
end

------------------------------------------------------------------
-- PHARAOH'S FORTUNE (rebirth 3, Roulette): the roulette table in lapis felt
-- on sandstone, a temple pylon behind it with a winged sun and the PHARAOH
-- sign, two obelisks with gold pyramidions and glowing sun tips
------------------------------------------------------------------
-- a column of simple glyphs (sun, eye, ankh, water, diamond, reed) drawn in
-- frames, top to bottom
local function hieroglyphs(gui, ink: Color3)
	local function f(props)
		props.BorderSizePixel = 0
		props.BackgroundColor3 = props.BackgroundColor3 or ink
		return new("Frame", props, gui)
	end
	local function ring(x, y, s, thick)
		local r = f({ BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(x, y),
			Size = UDim2.fromScale(s, s), SizeConstraint = Enum.SizeConstraint.RelativeXX })
		new("UICorner", { CornerRadius = UDim.new(0.5, 0) }, r)
		new("UIStroke", { Color = ink, Thickness = thick or 3, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, r)
		return r
	end
	local n = 6
	for i = 0, n - 1 do
		local y = (i + 0.5) / n
		local kind = i % 6
		if kind == 0 then
			ring(0.5, y, 0.5, 4)
			local dot = f({ AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, y), Size = UDim2.fromScale(0.14, 0.14),
				SizeConstraint = Enum.SizeConstraint.RelativeXX })
			new("UICorner", { CornerRadius = UDim.new(0.5, 0) }, dot)
		elseif kind == 1 then
			local eye = f({ BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, y),
				Size = UDim2.fromScale(0.66, 0.3), SizeConstraint = Enum.SizeConstraint.RelativeXX })
			new("UICorner", { CornerRadius = UDim.new(0.5, 0) }, eye)
			new("UIStroke", { Color = ink, Thickness = 3, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, eye)
			local pupil = f({ AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, y), Size = UDim2.fromScale(0.16, 0.16),
				SizeConstraint = Enum.SizeConstraint.RelativeXX })
			new("UICorner", { CornerRadius = UDim.new(0.5, 0) }, pupil)
		elseif kind == 2 then
			ring(0.5, y - 0.035, 0.3, 4)
			f({ AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, y + 0.012), Size = UDim2.fromScale(0.56, 0.012) })
			f({ AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromScale(0.5, y + 0.012), Size = UDim2.fromScale(0.08, 0.05) })
		elseif kind == 3 then
			for k = -1, 1 do
				f({ AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, y + k * 0.022), Size = UDim2.fromScale(0.6, 0.008) })
			end
		elseif kind == 4 then
			f({ AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, y), Size = UDim2.fromScale(0.34, 0.34),
				SizeConstraint = Enum.SizeConstraint.RelativeXX, Rotation = 45 })
		else
			f({ AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, y), Size = UDim2.fromScale(0.08, 0.1) })
			f({ AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.6, y - 0.03), Size = UDim2.fromScale(0.26, 0.012),
				Rotation = -35 })
		end
	end
end

local function pharaohRoulette(def)
	local S = 1.1
	local sand, sandDeep, lapis, turq = hex("#D9B77A"), hex("#A98448"), hex("#1E3F9E"), hex("#1FA6A0")
	local model = scaled(rouletteTable(def, {
		felt = lapis, body = sandDeep, rail = hex("#16307A"), glow = P.Amber, pedestal = sand, bowl = hex("#7A4E22"),
		ballColor = P.GoldTop, limitFill = lapis,
		layout = { line = P.Gold, text = P.GoldTop, zero = turq, red = hex("#A3192B"), black = hex("#14183A") },
	}), S)
	local bulbs = model:FindFirstChild("Bulbs")
	local stone = { material = Enum.Material.Sandstone, solid = true }

	-- the pylon behind the table: sandstone, a lapis-and-gold banded top,
	-- a cornice, the winged sun, the sign on top
	local pz, pw, ph = 3.15, 3.8, 6.0
	local pylon = part(model, "Pylon", Vector3.new(pw, ph, 0.6), CFrame.new(0, ph / 2, pz), sand, table.clone(stone))
	local pg = surface(pylon, Enum.NormalId.Front, 30, 0.2)
	for i = 0, 6 do
		new("Frame", { BackgroundColor3 = (i % 2 == 0) and lapis or P.Gold, BorderSizePixel = 0,
			Position = UDim2.fromScale(0.04 + i * 0.137, 0.06), Size = UDim2.fromScale(0.137, 0.2) }, pg)
	end
	new("Frame", { BackgroundColor3 = P.Gold, BorderSizePixel = 0, Position = UDim2.fromScale(0.04, 0.26),
		Size = UDim2.fromScale(0.92, 0.012) }, pg)
	for _, x in { 0.1, 0.9 } do
		local col = new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromScale(x, 0.3),
			Size = UDim2.fromScale(0.13, 0.68) }, pg)
		hieroglyphs(col, lapis)
	end
	gold(model, "PylonBand", Vector3.new(pw + 0.16, 0.14, 0.72), CFrame.new(0, ph + 0.07, pz))
	part(model, "PylonCornice", Vector3.new(pw + 0.5, 0.34, 0.86), CFrame.new(0, ph + 0.31, pz), sandDeep, table.clone(stone))
	gold(model, "PylonCap", Vector3.new(pw + 0.56, 0.08, 0.92), CFrame.new(0, ph + 0.52, pz))
	-- the winged sun: a gold disc with a red heart, three tiers of feathers a side
	local sy, sz = 5.1, pz - 0.32
	cylZ(model, "SunDisc", 1.05, 0.12, Vector3.new(0, sy, sz), P.Gold, { reflectance = 0.2 })
	cylZ(model, "SunCore", 0.62, 0.14, Vector3.new(0, sy, sz - 0.01), hex("#FF5A2A"), neonO())
	for _, s in { -1, 1 } do
		for k = 0, 2 do
			spike(model, "SunWing", 0.34 - k * 0.06, 1.45 - k * 0.3, 0.06,
				CFrame.new(s * 0.48, sy + 0.12 - k * 0.15, sz - 0.02 * k) * CFrame.Angles(0, 0, -s * math.pi / 2),
				({ P.Gold, turq, lapis })[k + 1], { reflectance = k == 0 and 0.2 or 0 })
		end
	end
	boardSign(model, "Sign", Vector3.new(3.5, 0.82, 0.25), CFrame.new(0, ph + 0.97, pz), "PHARAOH",
		{ icon = "crown", fill = hex("#1A2F7A") })
	bulbsAlong(bulbs, Vector3.new(-(pw + 0.4) / 2, ph + 0.42, pz - 0.48), Vector3.new((pw + 0.4) / 2, ph + 0.42, pz - 0.48), 11)

	-- the obelisks: stepped base, a hieroglyph shaft, gold bands, a gold
	-- pyramidion with a glowing sun on its point
	for _, s in { -1, 1 } do
		local x, z = s * 4.65, 2.3
		part(model, "ObeliskStep", Vector3.new(1.4, 0.25, 1.4), CFrame.new(x, 0.125, z), sandDeep, table.clone(stone))
		part(model, "ObeliskStep", Vector3.new(1.12, 0.25, 1.12), CFrame.new(x, 0.375, z), sand, table.clone(stone))
		gold(model, "ObeliskBand", Vector3.new(0.92, 0.12, 0.92), CFrame.new(x, 0.56, z))
		local shaft = part(model, "Obelisk", Vector3.new(0.8, 5.4, 0.8), CFrame.new(x, 0.62 + 2.7, z), sand, table.clone(stone))
		hieroglyphs(surface(shaft, Enum.NormalId.Front, 40, 0.2), lapis)
		gold(model, "ObeliskBand", Vector3.new(0.86, 0.12, 0.86), CFrame.new(x, 5.96, z))
		part(model, "Pyramidion", Vector3.new(0.68, 0.68, 0.68),
			CFrame.new(x, 6.02, z) * CFrame.Angles(0, 0, math.rad(54.7356)) * CFrame.Angles(0, math.rad(45), 0), P.Gold,
			{ reflectance = 0.22 })
		ball(model, "ObeliskSun", 0.34, Vector3.new(x, 6.72, z), P.GoldTop, neonO())
	end
	return model
end

------------------------------------------------------------------
-- POT O' GOLD (rebirth 3, Slots): an emerald cabinet with four-leaf clovers
-- on its sides, a neon rainbow arching over it from cloud to cloud, a black
-- pot brimming with gold coins under the arch
------------------------------------------------------------------
local function clover(gui, color: Color3, cx: number, cy: number, s: number)
	for _, o in { { 0, -1 }, { 1, 0 }, { 0, 1 }, { -1, 0 } } do
		local leaf = new("Frame", { BackgroundColor3 = color, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(cx + o[1] * s * 0.5, cy + o[2] * s * 0.5), Size = UDim2.fromScale(s, s),
			SizeConstraint = Enum.SizeConstraint.RelativeYY }, gui)
		new("UICorner", { CornerRadius = UDim.new(0.5, 0) }, leaf)
		new("UIStroke", { Color = P.Ink, Thickness = 3, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, leaf)
	end
	new("Frame", { BackgroundColor3 = color, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0), Rotation = 20,
		Position = UDim2.fromScale(cx + s * 0.25, cy + s * 0.55), Size = UDim2.fromScale(s * 0.18, s * 1.1),
		SizeConstraint = Enum.SizeConstraint.RelativeYY, ZIndex = 0 }, gui)
end

local function potOGold(def)
	local S = 1.15
	local model = scaled(slotMachine(def, { color = hex("#11905A"), accent = P.NeonGreen, title = "POT O' GOLD", icon = "coin" }), S)
	dropCandle(model)
	local top = 5.15 * S
	-- four-leaf clovers on the cabinet's sides
	local body = model:FindFirstChild("Body")
	if body then
		for _, face in { Enum.NormalId.Left, Enum.NormalId.Right } do
			clover(surface(body, face, 60, 0.15), hex("#3DFF6E"), 0.5, 0.45, 0.3)
		end
	end

	-- the rainbow: six neon bands from cloud to cloud, arching over the top
	local rc = CFrame.new(0, top + 1.1, 0.55)
	local bands = { hex("#FF3B55"), hex("#FF8A1F"), hex("#FFE14D"), hex("#3DFF6E"), hex("#3FC8FF"), hex("#9B5CFF") }
	for i, c in bands do
		arcRods(model, "Rainbow", rc, 3.0 - (i - 1) * 0.19, 0, math.pi, 12, 0.21, c, neonO())
	end
	for _, s in { -1, 1 } do
		for _, c in { { 0, 0, 1.0 }, { 0.45, 0.18, 0.72 }, { -0.42, 0.12, 0.78 }, { 0.1, 0.45, 0.7 }, { 0.3, -0.2, 0.6 } } do
			ball(model, "Cloud", c[3], rc:PointToWorldSpace(Vector3.new(s * (2.52 + c[1]), c[2], 0.08)), P.White, { shadow = false })
		end
	end

	-- the pot of gold under the arch, on three stubby legs
	local pc = Vector3.new(0, top + 1.7, 0.55)
	for k = 0, 2 do
		local a = k * 2 * math.pi / 3 + math.pi / 2
		cylY(model, "PotLeg", 0.18, 1.05, Vector3.new(math.cos(a) * 0.45, top + 0.52, 0.55 + math.sin(a) * 0.45), P.Ink)
	end
	ball(model, "Pot", 1.5, pc, hex("#1C1C22"), { reflectance = 0.2 })
	cylY(model, "PotRim", 1.42, 0.16, pc + Vector3.new(0, 0.5, 0), hex("#2A2A33"), { reflectance = 0.2 })
	cylY(model, "PotGold", 1.28, 0.1, pc + Vector3.new(0, 0.6, 0), P.Gold, { reflectance = 0.3 })
	for _, c in { { 0, 0.74, 0, 0.62 }, { 0.32, 0.68, 0.15, 0.45 }, { -0.3, 0.7, -0.1, 0.48 }, { 0.06, 0.98, 0.05, 0.4 } } do
		ball(model, "GoldHeap", c[4], pc + Vector3.new(c[1], c[2], c[3]), P.Gold, { reflectance = 0.3 })
	end
	for i, c in { { -0.5, 0.85, -0.3, 30, 10 }, { 0.45, 0.95, -0.35, -25, 20 }, { 0.1, 1.2, -0.25, 50, -15 },
		{ -0.62, 0.62, 0.2, 70, 30 }, { 0.66, 0.58, 0.15, -60, 25 }, { -0.25, 1.1, 0.3, -35, 40 } } do
		coin(model, pc + Vector3.new(c[1], c[2], c[3]), 0.38 + (i % 2) * 0.06, CFrame.Angles(math.rad(c[4]), math.rad(c[5] * 3), math.rad(c[5])))
	end
	particles(model, "GoldFX", Vector3.new(1.0, 0.1, 1.0), pc + Vector3.new(0, 1.0, 0), "sparks", P.GoldTop, 4, 2.5)
	return model
end

------------------------------------------------------------------
-- ROYAL CROWN 21 (rebirth 4, Blackjack): royal purple felt and a velvet
-- rail; behind the dealer a tufted velvet throne back with an ermine edge,
-- crowned by a jewelled gold crown; royal banners hang either side
------------------------------------------------------------------
local function royalCrown21(def)
	local purple, velvet, ermine = hex("#3B145E"), hex("#5B1F8F"), hex("#F4F1EA")
	local model = blackjackTable(def, { felt = purple, glow = hex("#C9A0FF") })
	local bulbs = model:FindFirstChild("Bulbs")
	local rail = model:FindFirstChild("Rail")
	if rail and rail:IsA("BasePart") then
		rail.Color = velvet
		rail.Material = Enum.Material.Fabric
	end
	local fabric = { material = Enum.Material.Fabric }

	-- the throne back: a velvet panel (tufted) whose round top rises over
	-- its shoulders, framed in gold, an ermine roll on the shoulders
	-- (it starts behind the dealer counter: under the table only the gold
	-- frame posts reach the floor, as the throne's legs)
	local tz, tw, ty0, ty1 = 2.35, 3.4, 2.5, 5.6
	local panel = part(model, "ThroneBack", Vector3.new(tw, ty1 - ty0, 0.45), CFrame.new(0, (ty1 + ty0) / 2, tz), velvet,
		{ solid = true, material = Enum.Material.Fabric })
	local crestC = Vector3.new(0, ty1 - 0.95, tz)
	local crest = cylZ(model, "ThroneCrest", tw, 0.45, crestC, velvet, table.clone(fabric))
	for _, p in { panel, crest } do
		local g = surface(p, p == crest and Enum.NormalId.Right or Enum.NormalId.Front, 24, 0.3)
		for r = 0, (p == crest and 6 or 5) do
			for c = 0, 5 do
				local dot = new("Frame", { BackgroundColor3 = P.Gold, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5),
					Position = UDim2.fromScale((c + 0.25 + (r % 2) * 0.5) / 6, (r + 0.5) / ((p == crest and 7 or 6))),
					Size = UDim2.fromScale(0.035, 0.035), SizeConstraint = Enum.SizeConstraint.RelativeXX }, g)
				new("UICorner", { CornerRadius = UDim.new(0.5, 0) }, dot)
			end
		end
	end
	for _, s in { -1, 1 } do
		gold(model, "ThroneFrame", Vector3.new(0.2, ty1, 0.55), CFrame.new(s * (tw / 2 + 0.05), ty1 / 2, tz))
		ball(model, "ThroneFinial", 0.36, Vector3.new(s * (tw / 2 + 0.05), ty1 + 0.15, tz), P.GoldTop, { reflectance = 0.25 })
	end
	local a0 = math.asin(0.95 / (tw / 2))
	arcRods(model, "ThroneFrame", CFrame.new(crestC + Vector3.new(0, 0, -0.24)), tw / 2 + 0.02, a0, math.pi - a0, 10, 0.16, P.Gold,
		{ reflectance = 0.2 })
	bulbArc(bulbs, CFrame.new(crestC + Vector3.new(0, 0, -0.34)), tw / 2 + 0.12, a0, math.pi - a0, 11, 0.15)
	for _, s in { -1, 1 } do
		local x0 = s * (tw / 2 - 0.05)
		local x1 = s * (tw / 2 - 0.95 + 0.25)
		rod(model, "Ermine", Vector3.new(x0, ty1 + 0.02, tz - 0.12), Vector3.new(x1, ty1 + 0.02, tz - 0.12), 0.3, ermine,
			table.clone(fabric))
		for k = 0, 1 do
			ball(model, "ErmineSpot", 0.09, Vector3.new(x0 + (x1 - x0) * (0.3 + k * 0.4), ty1 + 0.06, tz - 0.27), P.Ink, { shadow = false })
		end
	end
	boardSign(model, "Plaque", Vector3.new(2.5, 0.62, 0.18), CFrame.new(0, 4.75, tz - 0.31), "ROYAL 21",
		{ icon = "crown", fill = purple })

	-- the crown: gold band with jewels, velvet cap, eight points with
	-- pearls, two arches and an orb with a cross
	local cy = ty1 + 0.75 + 0.62
	local C = Vector3.new(0, cy, tz)
	cylY(model, "CrownBand", 1.8, 0.5, C, P.Gold, { reflectance = 0.25 })
	cylY(model, "CrownRim", 1.88, 0.08, C - Vector3.new(0, 0.23, 0), P.GoldTop, { reflectance = 0.25 })
	cylY(model, "CrownRim", 1.88, 0.08, C + Vector3.new(0, 0.23, 0), P.GoldTop, { reflectance = 0.25 })
	ball(model, "CrownCap", 1.5, C + Vector3.new(0, 0.25, 0), P.Crimson, table.clone(fabric))
	local jewels = { P.NeonRed, P.NeonBlue, P.NeonGreen, P.NeonBlue, P.NeonRed }
	for i, a in { -64, -32, 0, 32, 64 } do
		local r = math.rad(a)
		ball(model, "CrownJewel", 0.22, C + Vector3.new(0.92 * math.sin(r), 0, -0.92 * math.cos(r)), jewels[i], neonO())
	end
	for k = 0, 7 do
		local a = k * math.pi / 4 + math.pi / 8
		local p = C + Vector3.new(math.cos(a) * 0.82, 0.25, math.sin(a) * 0.82)
		local cf = CFrame.new(p) * CFrame.Angles(0, math.pi / 2 - a, 0) * CFrame.Angles(math.rad(-12), 0, 0)
		spike(model, "CrownPoint", 0.5, 0.55, 0.07, cf, P.Gold, { reflectance = 0.25 })
		ball(model, "CrownPearl", 0.15, (cf * CFrame.new(0, 0.58, 0)).Position, P.White, { reflectance = 0.2 })
	end
	arcRods(model, "CrownArch", CFrame.new(C + Vector3.new(0, 0.25, 0)), 0.84, 0, math.pi, 8, 0.1, P.Gold, { reflectance = 0.25 })
	arcRods(model, "CrownArch", CFrame.new(C + Vector3.new(0, 0.25, 0)) * CFrame.Angles(0, math.pi / 2, 0), 0.84, 0, math.pi, 8, 0.1,
		P.Gold, { reflectance = 0.25 })
	ball(model, "CrownOrb", 0.34, C + Vector3.new(0, 1.24, 0), P.Gold, { reflectance = 0.3 })
	part(model, "CrownCross", Vector3.new(0.09, 0.42, 0.09), CFrame.new(C + Vector3.new(0, 1.58, 0)), P.Gold, { reflectance = 0.3 })
	part(model, "CrownCross", Vector3.new(0.3, 0.09, 0.09), CFrame.new(C + Vector3.new(0, 1.63, 0)), P.Gold, { reflectance = 0.3 })

	-- the banners: gold poles at the counter's ends, an arm each, swallow-tailed
	-- velvet pennants with the crown
	for _, s in { -1, 1 } do
		local x, z = s * 4.3, 1.6
		cylY(model, "BannerFoot", 0.5, 0.12, Vector3.new(x, 0.06, z), P.Gold, { reflectance = 0.2 })
		cylY(model, "BannerPole", 0.18, 7.0, Vector3.new(x, 3.5, z), P.Gold, { reflectance = 0.2 })
		ball(model, "BannerFinial", 0.34, Vector3.new(x, 7.12, z), P.GoldTop, { reflectance = 0.25 })
		rod(model, "BannerArm", Vector3.new(x, 6.55, z), Vector3.new(x - s * 1.25, 6.55, z), 0.08, P.Gold, { reflectance = 0.2 })
		local bx = x - s * 0.66
		local banner = part(model, "Banner", Vector3.new(1.05, 2.1, 0.05), CFrame.new(bx, 5.45, z), velvet, table.clone(fabric))
		for _, face in { Enum.NormalId.Front, Enum.NormalId.Back } do
			local g = surface(banner, face, 60, 0.3)
			local f = new("Frame", { BackgroundColor3 = P.White, Size = UDim2.new(1, -6, 1, -6), Position = UDim2.fromOffset(3, 3) }, g)
			new("UIGradient", { Rotation = 90, Color = ColorSequence.new(hex("#7A2BD9"), hex("#3B145E")) }, f)
			new("UIStroke", { Color = P.Gold, Thickness = 5, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, f)
			guiImage(f, "crown", { size = UDim2.fromScale(0.86, 0.5), position = UDim2.fromScale(0.5, 0.42) })
		end
		for _, e in { -1, 1 } do
			spike(model, "BannerTail", 0.52, 0.42, 0.05, CFrame.new(bx + e * 0.26, 4.4, z) * CFrame.Angles(0, 0, math.pi), velvet,
				table.clone(fabric))
		end
	end
	return model
end

------------------------------------------------------------------
-- NEPTUNE'S TREASURE (rebirth 5, Plinko): a teal cabinet, a deep-sea board
-- of pearl pins (the ball is a pearl), a scallop-shell crest, a gold trident
-- standing at the player's right, coral and bubbles at the left
------------------------------------------------------------------
local function neptuneTreasure(def)
	local model = new("Model", { Name = def.name })
	local bulbs = new("Folder", { Name = "Bulbs" }, model)
	local teal, tealDeep, coral, pearl, aqua = hex("#1FBFB0"), hex("#0B6E78"), hex("#FF7A8A"), hex("#FFF1F5"), hex("#5CFFE9")
	local h0 = plinth(model, 5.4, 3.0, aqua)

	-- lower cabinet (Body / PrimaryPart), belly sign, gold edges, deck
	local body = part(model, "Body", Vector3.new(4.8, 1.8, 2.7), CFrame.new(0, h0 + 0.9, 0), teal, { solid = true, reflectance = 0.06 })
	model.PrimaryPart = body
	local belly = part(model, "Belly", Vector3.new(3.8, 1.05, 0.08), CFrame.new(0, h0 + 0.85, -1.39), tealDeep)
	guiText(signPlate(surface(belly, Enum.NormalId.Front, 100, 0.1), hex("#0B4F6C")), "DIVE & WIN!", {
		size = UDim2.fromScale(0.86, 0.58), position = UDim2.fromScale(0.07, 0.21), gradient = { P.GoldTop, P.Gold },
		strokeThickness = 6 })
	for _, sx in { -1, 1 } do
		gold(model, "EdgeTrim", Vector3.new(0.14, 1.8, 0.14), CFrame.new(sx * 2.4, h0 + 0.9, -1.35))
	end
	local deckY = h0 + 1.8
	gold(model, "Deck", Vector3.new(4.9, 0.2, 0.7), CFrame.new(0, deckY + 0.1, -1.15))
	cylY(model, "DropButton", 0.62, 0.14, Vector3.new(-1.3, deckY + 0.27, -1.17), aqua, neonO())
	for i, c in { coral, P.Amber } do
		cylY(model, "Button" .. i, 0.3, 0.1, Vector3.new(0.9 + (i - 1) * 0.5, deckY + 0.25, -1.17), c, neonO())
	end

	-- the board: a deep-sea back with light rays and bubbles, teal pillars
	local boardTop = deckY + 4.8
	local by, bh = (deckY + boardTop) / 2, boardTop - deckY
	local back = part(model, "BoardBack", Vector3.new(4.3, bh, 0.2), CFrame.new(0, by, 0.65), hex("#0B3A5C"), { solid = true })
	local sg = surface(back, Enum.NormalId.Front, 40, 0)
	pcall(function() sg.Brightness = 1.3 end)
	local sea = new("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = P.White, BorderSizePixel = 0 }, sg)
	new("UIGradient", { Rotation = 90, Color = ColorSequence.new(hex("#2FD8C8"), hex("#082B4A")) }, sea)
	for i, x in { 0.18, 0.5, 0.8 } do
		new("Frame", { BackgroundColor3 = P.White, BackgroundTransparency = 0.86, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.fromScale(x, -0.1), Size = UDim2.fromScale(0.09 + i * 0.02, 1.2), Rotation = 14, ZIndex = 2 }, sg)
	end
	for k = 1, 14 do
		local s = 0.025 + (k % 3) * 0.015
		local b = new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), ZIndex = 3,
			Position = UDim2.fromScale((k * 0.6180339) % 1, (k * 0.271 + 0.05) % 1), Size = UDim2.fromScale(s, s),
			SizeConstraint = Enum.SizeConstraint.RelativeXX }, sg)
		new("UICorner", { CornerRadius = UDim.new(0.5, 0) }, b)
		new("UIStroke", { Color = P.White, Thickness = 2, Transparency = 0.3, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, b)
	end
	for _, sx in { -1, 1 } do
		part(model, "Pillar", Vector3.new(0.3, bh, 1.0), CFrame.new(sx * 2.3, by, 0.3), teal, { solid = true })
		gold(model, "PillarTrim", Vector3.new(0.12, bh, 0.12), CFrame.new(sx * 2.3, by, -0.22))
		neon(model, "PillarNeon", Vector3.new(0.06, bh - 0.4, 0.06), CFrame.new(sx * 2.12, by, -0.18), aqua)
	end
	part(model, "Header", Vector3.new(4.9, 0.25, 1.0), CFrame.new(0, boardTop + 0.125, 0.3), teal, { solid = true })
	gold(model, "HeaderTrim", Vector3.new(4.9, 0.08, 0.1), CFrame.new(0, boardTop + 0.02, -0.22))
	part(model, "Glass", Vector3.new(4.3, bh - 0.3, 0.04), CFrame.new(0, by - 0.1, 0.18), hex("#D8FFFA"),
		{ transparency = 0.88, reflectance = 0.15, shadow = false })

	-- pins of pearl, a pearl for the ball
	local top = Vector3.new(0, deckY + 3.85, 0.4)
	plinkoBoard(model, top, { dx = 0.44, dy = 0.37, pegD = 0.14, pegLen = 0.3, ballD = 0.3, pocketH = 0.6, labelH = 0.28,
		startUp = 0.5, ballColor = pearl })
	local pegs = model:FindFirstChild("Pegs")
	for _, p in (pegs and pegs:GetChildren() or {}) do
		if p:IsA("BasePart") then
			p.Shape = Enum.PartType.Ball
			p.Size = Vector3.new(0.2, 0.2, 0.2)
			p.Color = pearl
			p.Reflectance = 0.35
		end
	end
	cylY(model, "Chute", 0.7, 0.1, Vector3.new(0, top.Y + 0.72, top.Z), P.Chrome, metalO(0.3))

	-- the sign, the scallop-shell crest (coral and pearl ribs, a scalloped
	-- rim) and a glowing pearl at its hinge
	local signY = boardTop + 0.25 + 0.38
	boardSign(model, "Topper", Vector3.new(4.4, 0.76, 0.3), CFrame.new(0, signY, 0.35), "NEPTUNE",
		{ icon = "gem", fill = hex("#0B4F6C") })
	bulbFrame(bulbs, 0, signY, 4.5, 0.86, 0.15, 10)
	for _, sx in { -1, 1 } do
		bulbsAlong(bulbs, Vector3.new(sx * 2.3, deckY + 0.45, -0.36), Vector3.new(sx * 2.3, boardTop - 0.35, -0.36), 7)
	end
	local H = Vector3.new(0, boardTop + 1.12, 0.6)
	local R = 2.2
	for k = 0, 8 do
		local a = math.rad(10 + 20 * k)
		local dir = Vector3.new(math.cos(a), math.sin(a), 0)
		local col = (k % 2 == 0) and coral or hex("#FFB3C1")
		spike(model, "ShellRib", 0.92, R - 0.15, 0.12, CFrame.new(H + dir * R) * CFrame.Angles(0, 0, a + math.pi / 2), col)
		spike(model, "ShellRidge", 0.32, R - 0.45, 0.12, CFrame.new(H + dir * (R - 0.1) + Vector3.new(0, 0, -0.07))
			* CFrame.Angles(0, 0, a + math.pi / 2), pearl)
		ball(model, "Scallop", 0.86, H + dir * (R + 0.05), col, { reflectance = 0.05 })
	end
	ball(model, "ShellPearl", 0.7, H + Vector3.new(0, 0.05, -0.25), pearl, neonO())

	-- the trident at the player's right (model -X)
	local tx, tzz = -2.95, -0.25
	cylY(model, "TridentFoot", 0.6, 0.45, Vector3.new(tx, 0.225, tzz), P.Ink, { solid = true })
	cylY(model, "TridentShaft", 0.16, 8.6, Vector3.new(tx, 0.45 + 4.3, tzz), P.Gold, { reflectance = 0.25 })
	cylY(model, "TridentGrip", 0.24, 0.6, Vector3.new(tx, 4.3, tzz), hex("#0B6E78"), { material = Enum.Material.Fabric })
	local hy = 9.05
	rod(model, "TridentBar", Vector3.new(tx - 0.46, hy, tzz), Vector3.new(tx + 0.46, hy, tzz), 0.12, P.Gold, { reflectance = 0.25 })
	spike(model, "TridentProng", 0.3, 0.95, 0.1, CFrame.new(tx, hy, tzz), P.Gold, { reflectance = 0.25 })
	for _, s in { -1, 1 } do
		rod(model, "TridentProng", Vector3.new(tx + s * 0.46, hy - 0.06, tzz), Vector3.new(tx + s * 0.46, hy + 0.4, tzz), 0.11, P.Gold,
			{ reflectance = 0.25 })
		spike(model, "TridentProng", 0.22, 0.5, 0.1, CFrame.new(tx + s * 0.46, hy + 0.38, tzz), P.Gold, { reflectance = 0.25 })
	end
	ball(model, "TridentGem", 0.26, Vector3.new(tx, hy - 0.2, tzz - 0.05), aqua, neonO())

	-- coral and bubbles at the player's left (model +X)
	local function coralTree(base: Vector3, color: Color3, s: number)
		local trunkTop = base + Vector3.new(0, 1.5 * s, 0)
		rod(model, "Coral", base, trunkTop, 0.2 * s, color)
		for _, br in { { 0.45, 0.75, 0.6 }, { -0.4, 0.95, 0.45 }, { 0.2, 1.25, 0.35 }, { -0.15, 0.4, 0.55 } } do
			local from = base + Vector3.new(0, br[3] * 1.5 * s, 0)
			local to = from + Vector3.new(br[1] * s, br[2] * s, 0)
			rod(model, "Coral", from, to, 0.14 * s, color)
			ball(model, "CoralTip", 0.2 * s, to, color:Lerp(P.White, 0.35), neonO())
		end
		ball(model, "CoralTip", 0.22 * s, trunkTop, color:Lerp(P.White, 0.35), neonO())
	end
	cylY(model, "CoralRock", 0.9, 0.45, Vector3.new(2.95, 0.225, -0.1), P.Ink, { solid = true })
	coralTree(Vector3.new(2.95, 0.45, -0.1), coral, 1.3)
	coralTree(Vector3.new(2.85, 0.45, 0.25), hex("#B98CFF"), 0.95)
	for _, b in { { 2.7, 3.6, 0.1, 0.32 }, { 3.0, 4.6, 0.0, 0.24 }, { 2.75, 5.5, 0.2, 0.36 }, { 3.05, 6.6, 0.0, 0.22 }, { 2.8, 7.4, 0.15, 0.28 } } do
		ball(model, "Bubble", b[4], Vector3.new(b[1], b[2], b[3]), hex("#CFFBFF"), { transparency = 0.5, reflectance = 0.3, shadow = false })
	end
	return model
end

------------------------------------------------------------------
-- VOLCANO ERUPTION (rebirth 6, Dice): a basalt cone of sloped facets with
-- lava rivers and glowing cracks; three dice wait in the crater and erupt
-- on every roll (DiceHop); a lava ring round its foot, smoke and embers,
-- the sign on basalt pillars behind it, bulbs round the plinth
------------------------------------------------------------------
local function volcanoEruption(def)
	local model = new("Model", { Name = def.name })
	local bulbs = new("Folder", { Name = "Bulbs" }, model)
	local basalt, basaltLight, lava, lavaHot = hex("#2B1D1A"), hex("#4A3029"), hex("#FF4A12"), hex("#FFB21E")
	cylY(model, "Plinth", 7.2, 0.4, Vector3.new(0, 0.2, 0), P.Ink, { solid = true })
	cylY(model, "PlinthLip", 7.34, 0.1, Vector3.new(0, 0.37, 0), P.Gold, { reflectance = 0.12 })
	cylY(model, "Underglow", 7.42, 0.06, Vector3.new(0, 0.14, 0), lava, neonO())
	bulbArc(bulbs, CFrame.new(0, 0.47, 0) * CFrame.Angles(math.rad(90), 0, 0), 3.58, 0, 2 * math.pi, 28, 0.16)

	local y0, y1, Rb, Rt, N = 0.42, 5.6, 3.3, 1.25, 14
	local H = y1 - y0
	local ap = math.cos(math.pi / N)
	local run = (Rb - Rt) * ap
	local rc = (Rb + Rt) / 2 * ap
	local floorY = y1 - 0.35
	-- the core (Body / PrimaryPart: upright, facing -Z) hides in the cone
	local body = part(model, "Body", Vector3.new(1.6, floorY - 0.06 - y0, 1.6), CFrame.new(0, (y0 + floorY - 0.06) / 2, 0), basalt,
		{ solid = true })
	model.PrimaryPart = body
	-- the cone: N sloped wedge facets in two tones round the crater
	local facets = {}
	for k = 1, N do
		local a = (k - 0.5) * 2 * math.pi / N
		local u = Vector3.new(math.cos(a), 0, math.sin(a))
		local pos = Vector3.new(0, y0 + H / 2, 0) + u * rc
		facets[k] = CFrame.lookAt(pos, pos + u)
		wedge(model, "Cone", Vector3.new(2 * Rb * math.sin(math.pi / N) + 0.06, H, run), facets[k],
			(k % 2 == 0) and basalt or basaltLight, { material = Enum.Material.Basalt, solid = true })
	end
	-- lava on the slopes: rivers from the rim (a hot core in each) and cracks
	local L = math.sqrt(H * H + run * run)
	local n = Vector3.new(0, run, -H).Unit -- a facet's outward slope normal
	local tilt = math.atan2(run, H)
	local function onSlope(k: number, f: number, len: number, w: number, color: Color3, lift: number)
		local p = Vector3.new(0, -H / 2 + f * H, -run / 2 + f * run) + n * lift
		part(model, "Lava", Vector3.new(w, len, 0.05), facets[k] * CFrame.new(p) * CFrame.Angles(tilt, 0, 0), color, neonO())
	end
	for _, k in { 11, 8, 14, 4 } do
		onSlope(k, 0.62, L * 0.7, 0.44, lava, 0.03)
		onSlope(k, 0.66, L * 0.6, 0.16, lavaHot, 0.06)
	end
	for _, c in { { 9, 0.35, 1.4 }, { 10, 0.62, 1.0 }, { 12, 0.3, 1.6 }, { 13, 0.55, 1.2 }, { 2, 0.4, 1.3 }, { 6, 0.5, 1.5 } } do
		onSlope(c[1], c[2], c[3], 0.1, lava, 0.03)
	end
	hoop(model, "LavaPool", CFrame.new(0, y0 + 0.05, 0) * CFrame.Angles(math.rad(90), 0, 0), Rb * ap + 0.14, 28, 0.22, lava, neonO())
	for i = 0, 6 do
		local a = math.rad(i * 51 + 20)
		local s = 0.5 + (i % 3) * 0.14
		part(model, "LavaRock", Vector3.new(s, s * 0.8, s * 1.1),
			CFrame.new(math.cos(a) * 3.3, y0 + s * 0.3, math.sin(a) * 3.3) * CFrame.Angles(math.rad(i * 23), math.rad(i * 47), math.rad(i * 31)),
			(i % 2 == 0) and basalt or basaltLight, { material = Enum.Material.Basalt })
	end

	-- the crater: a lava floor, a glowing rim, three dice
	cylY(model, "LavaFloor", 2 * Rt * ap + 0.1, 0.12, Vector3.new(0, floorY, 0), lava, neonO())
	hoop(model, "RimGlow", CFrame.new(0, y1 + 0.03, 0) * CFrame.Angles(math.rad(90), 0, 0), Rt * ap + 0.05, N, 0.14, lavaHot, neonO())
	local ds = 0.6
	local dy = floorY + 0.06 + ds / 2
	die(model, "Die1", ds, CFrame.new(-0.38, dy, 0.12) * CFrame.Angles(0, math.rad(18), 0))
	die(model, "Die2", ds, CFrame.new(0.4, dy, 0.2) * CFrame.Angles(0, math.rad(-30), 0))
	die(model, "Die3", ds, CFrame.new(0.0, dy, -0.42) * CFrame.Angles(0, math.rad(40), 0))
	model:SetAttribute("DiceHop", 2.6) -- MachineFX: the dice erupt out of the crater and fall back in...
	model:SetAttribute("BurstOnPlay", true) -- ...in a burst of embers on every roll
	particles(model, "SmokeFX", Vector3.new(1.6, 0.1, 1.6), Vector3.new(0, floorY + 0.25, 0), "smoke", hex("#6B5A55"), 3, 2.5)
	particles(model, "EmberFX", Vector3.new(1.2, 0.1, 1.2), Vector3.new(0, floorY + 0.3, 0), "sparks", lavaHot, 6, 5)

	-- the sign on two basalt pillars behind the cone
	for _, sx in { -1, 1 } do
		part(model, "SignPillar", Vector3.new(0.45, 5.6, 0.45), CFrame.new(sx * 1.85, y0 + 2.8, 2.85), basaltLight,
			{ material = Enum.Material.Basalt, solid = true })
		neon(model, "PillarLava", Vector3.new(0.08, 4.6, 0.05), CFrame.new(sx * 1.85, y0 + 2.6, 2.6), lava)
	end
	boardSign(model, "Sign", Vector3.new(3.6, 0.85, 0.25), CFrame.new(0, y0 + 6.0, 2.85), "VOLCANO",
		{ icon = "star", fill = hex("#7A0F08") })
	bulbsAlong(bulbs, Vector3.new(-1.7, y0 + 5.48, 2.7), Vector3.new(1.7, y0 + 5.48, 2.7), 9)
	return model
end

------------------------------------------------------------------
-- EMPEROR'S WHEEL (rebirth 7, Wheel): a red-lacquer prize wheel set in an
-- imperial gate: red columns on marble drums, a beam with the sign, a golden
-- tiled roof with up-turned eaves, ridge horns and a flaming pearl, red
-- lanterns hanging either side
------------------------------------------------------------------
local function emperorWheel(def)
	local S = 1.22
	local red, redDeep, roofGold, roofLine, marble = hex("#B5121B"), hex("#6E0A10"), hex("#F2B705"), hex("#B88400"), hex("#F4F1EA")
	local model = scaled(fortuneWheel(def, { body = red, title = "EMPEROR", icon = "crown", glow = hex("#FFB13D"),
		signFill = redDeep }), S)
	local bulbs = model:FindFirstChild("Bulbs")
	local topper = model:FindFirstChild("Topper")
	if topper then topper:Destroy() end
	local gz, colX, beamY = 0.55, 3.7, 10.1

	-- the columns and the beam with the sign
	for _, s in { -1, 1 } do
		local x = s * colX
		cylY(model, "ColumnBase", 1.0, 0.5, Vector3.new(x, 0.25, gz), marble, { solid = true, material = Enum.Material.Marble })
		cylY(model, "ColumnFoot", 0.8, 0.16, Vector3.new(x, 0.58, gz), P.Gold, { reflectance = 0.2 })
		local h = beamY - 0.3 - 0.66
		cylY(model, "Column", 0.6, h, Vector3.new(x, 0.66 + h / 2, gz), red, { solid = true, reflectance = 0.06 })
		for _, y in { 1.3, beamY - 1.05 } do
			cylY(model, "ColumnBand", 0.66, 0.14, Vector3.new(x, y, gz), P.Gold, { reflectance = 0.2 })
		end
		gold(model, "ColumnCap", Vector3.new(0.86, 0.3, 0.86), CFrame.new(x, beamY - 0.45, gz))
	end
	part(model, "Beam", Vector3.new(2 * colX + 1.0, 0.6, 0.7), CFrame.new(0, beamY, gz), red, { solid = true, reflectance = 0.05 })
	for _, dy in { -0.33, 0.33 } do
		gold(model, "BeamTrim", Vector3.new(2 * colX + 1.04, 0.08, 0.74), CFrame.new(0, beamY + dy, gz))
	end
	boardSign(model, "Sign", Vector3.new(3.2, 0.8, 0.2), CFrame.new(0, beamY, gz - 0.46), "EMPEROR", { icon = "crown", fill = redDeep })

	-- the golden roof: two tiled slopes to a ridge
	local eaveY, ridgeY, rw = beamY + 0.42, beamY + 1.25, 2 * colX + 1.0
	local zF, zB = gz - 1.75, gz + 1.75
	local function slope(z0: number)
		local len = math.sqrt((gz - z0) ^ 2 + (ridgeY - eaveY) ^ 2)
		local p = part(model, "Roof", Vector3.new(rw, 0.2, len + 0.14),
			CFrame.new(0, (eaveY + ridgeY) / 2, (z0 + gz) / 2) * CFrame.Angles(-math.atan2(ridgeY - eaveY, gz - z0), 0, 0), roofGold,
			{ reflectance = 0.12 })
		local g = surface(p, Enum.NormalId.Top, 20, 0.3)
		for i = 1, 21 do
			new("Frame", { BackgroundColor3 = roofLine, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, i / 22), Size = UDim2.new(1, 0, 0, 3) }, g)
		end
	end
	slope(zF)
	slope(zB)
	rod(model, "Ridge", Vector3.new(-rw / 2 - 0.1, ridgeY + 0.12, gz), Vector3.new(rw / 2 + 0.1, ridgeY + 0.12, gz), 0.26, P.Gold,
		{ reflectance = 0.25 })
	for _, z in { zF, zB } do
		rod(model, "Eave", Vector3.new(-rw / 2, eaveY - 0.02, z), Vector3.new(rw / 2, eaveY - 0.02, z), 0.16, P.Gold, { reflectance = 0.2 })
	end
	for _, s in { -1, 1 } do
		for _, z in { zF, zB } do
			spike(model, "EaveTip", 0.32, 0.62, 0.12, CFrame.new(s * rw / 2, eaveY - 0.05, z) * CFrame.Angles(0, 0, -s * math.rad(34)),
				P.Gold, { reflectance = 0.25 })
		end
		local hx = s * (rw / 2 - 0.15)
		spike(model, "RidgeHorn", 0.42, 0.85, 0.14, CFrame.new(hx, ridgeY + 0.15, gz) * CFrame.Angles(0, 0, s * math.rad(18)), P.Gold,
			{ reflectance = 0.25 })
		ball(model, "RidgePearl", 0.26, Vector3.new(hx - s * 0.27, ridgeY + 0.98, gz), P.NeonRed, neonO())
	end
	-- the flaming pearl on the ridge
	local fp = Vector3.new(0, ridgeY + 0.55, gz)
	ball(model, "FlamingPearl", 0.46, fp, hex("#FFD23F"), neonO())
	for k = 0, 5 do
		local a = k * math.pi / 3 + math.pi / 6
		spike(model, "PearlFlame", 0.2, 0.34, 0.05,
			CFrame.new(fp + Vector3.new(math.cos(a) * 0.22, math.sin(a) * 0.22, -0.03)) * CFrame.Angles(0, 0, a - math.pi / 2),
			hex("#FF6A1A"), neonO())
	end
	bulbsAlong(bulbs, Vector3.new(-rw / 2 + 0.35, eaveY - 0.2, zF - 0.06), Vector3.new(rw / 2 - 0.35, eaveY - 0.2, zF - 0.06), 15)

	-- red lanterns under the beam
	for _, s in { -1, 1 } do
		local lp = Vector3.new(s * 2.5, beamY - 1.2, gz - 0.1)
		cylY(model, "LanternCord", 0.04, 0.5, lp + Vector3.new(0, 0.66, 0), P.Ink)
		cylY(model, "LanternCap", 0.38, 0.1, lp + Vector3.new(0, 0.4, 0), P.Gold, { reflectance = 0.2 })
		ball(model, "Lantern", 0.72, lp, P.NeonRed, neonO())
		cylY(model, "LanternCap", 0.38, 0.1, lp - Vector3.new(0, 0.4, 0), P.Gold, { reflectance = 0.2 })
		cylY(model, "Tassel", 0.1, 0.36, lp - Vector3.new(0, 0.62, 0), P.Gold)
	end
	return model
end

------------------------------------------------------------------
-- DIAMOND VAULT (rebirth 8, Slots): a black-and-gold cabinet before a steel
-- vault door (bolts, hinges, a gold hub; its spoked handle turns slowly),
-- gold-bar pyramids topped with diamonds either side behind red laser beams
------------------------------------------------------------------
local function diamondVault(def)
	local S = 1.1
	local onyx, steel, steelDark, steelLight, ice = hex("#1C1F26"), hex("#8E98A4"), hex("#4F5763"), hex("#BCC5CF"), hex("#7DF4FF")
	local model = scaled(slotMachine(def, { color = onyx, accent = ice, title = "DIAMOND VAULT", icon = "gem" }), S)
	dropCandle(model)
	local h0 = 0.45 * S

	-- the wings: gold-bar pyramids, diamonds, lasers
	for _, s in { -1, 1 } do
		local x, wh = s * 3.18, h0 - 0.1
		part(model, "Wing", Vector3.new(1.7, wh, 3.0), CFrame.new(x, wh / 2, 0), P.Ink, { solid = true })
		gold(model, "WingLip", Vector3.new(1.74, 0.1, 3.04), CFrame.new(x, wh - 0.02, 0))
		neon(model, "WingGlow", Vector3.new(1.5, 0.07, 0.05), CFrame.new(x, 0.15, -1.525), ice)
		local barY = wh + 0.03
		for row = 0, 2 do
			for i = 0, 2 - row do
				local bx = x + (i - (2 - row) / 2) * 0.5
				local y = barY + 0.14 + row * 0.28
				part(model, "GoldBar", Vector3.new(0.46, 0.28, 0.95), CFrame.new(bx, y, -0.25), P.Gold, { reflectance = 0.3 })
				part(model, "GoldBarTop", Vector3.new(0.36, 0.03, 0.85), CFrame.new(bx, y + 0.15, -0.25), P.GoldTop,
					{ reflectance = 0.3, shadow = false })
			end
		end
		cutGem(model, 0.42, Vector3.new(x, barY + 1.18, -0.25), ice)
		cutGem(model, 0.34, Vector3.new(x - s * 0.35, barY + 0.3, 0.95), hex("#FFB8F0"))
		cutGem(model, 0.3, Vector3.new(x + s * 0.3, barY + 0.27, 0.85), P.White)
		local xa, xb, lz = s * 2.42, s * 3.95, -1.38
		for _, px in { xa, xb } do
			cylY(model, "LaserPost", 0.16, 1.9, Vector3.new(px, wh + 0.95, lz), P.Ink)
			ball(model, "LaserEye", 0.18, Vector3.new(px, wh + 1.95, lz), P.NeonRed, neonO())
		end
		rod(model, "Laser", Vector3.new(xa, wh + 0.3, lz), Vector3.new(xb, wh + 1.75, lz), 0.05, P.NeonRed, neonO())
		rod(model, "Laser", Vector3.new(xa, wh + 1.75, lz), Vector3.new(xb, wh + 0.3, lz), 0.05, P.NeonRed, neonO())
	end

	-- the vault door behind the marquee
	local vc = Vector3.new(0, 7.95, 0)
	cylZ(model, "VaultRing", 5.5, 0.4, vc + Vector3.new(0, 0, 1.38), steelDark, metalO(0.15))
	cylZ(model, "VaultDoor", 4.9, 0.5, vc + Vector3.new(0, 0, 1.05), steel, metalO(0.2))
	cylZ(model, "VaultFace", 4.0, 0.52, vc + Vector3.new(0, 0, 1.04), steelLight, metalO(0.25))
	hoop(model, "VaultGroove", CFrame.new(vc + Vector3.new(0, 0, 0.77)), 1.6, 20, 0.07, steelDark, metalO(0.1))
	for k = 0, 15 do
		local a = k * math.pi / 8
		ball(model, "VaultBolt", 0.3, vc + Vector3.new(math.cos(a) * 2.25, math.sin(a) * 2.25, 0.8), P.Chrome, metalO(0.35))
	end
	for _, dy in { -1.35, 1.35 } do
		part(model, "VaultHinge", Vector3.new(0.5, 0.8, 0.6), CFrame.new(vc + Vector3.new(-2.5, dy, 1.05)), steelDark, metalO(0.2))
	end
	cylZ(model, "VaultHub", 1.1, 0.3, vc + Vector3.new(0, 0, 0.68), P.Gold, { reflectance = 0.25 })
	local handle = spinnerAt(model, "VaultHandle", 22, vc + Vector3.new(0, 0, 0.45), Vector3.new(0, 0, -1))
	for k = 0, 5 do
		local a = k * math.pi / 3
		local tip = vc + Vector3.new(math.cos(a) * 1.4, math.sin(a) * 1.4, 0.45)
		rod(handle, "Spoke", vc + Vector3.new(0, 0, 0.45), tip, 0.14, P.Gold, { reflectance = 0.25 })
		ball(handle, "SpokeKnob", 0.28, tip, P.GoldTop, { reflectance = 0.25 })
	end
	hoop(handle, "HandleRim", CFrame.new(vc + Vector3.new(0, 0, 0.45)), 1.0, 16, 0.1, P.Gold, { reflectance = 0.25 })
	ball(model, "VaultLight", 0.26, vc + Vector3.new(0, 2.86, 1.2), P.NeonRed, neonO())
	particles(model, "GlintFX", Vector3.new(3.4, 0.1, 0.6), Vector3.new(0, h0 + 1.6, -0.25), "sparks", ice, 3, 1.5)
	return model
end

------------------------------------------------------------------
-- CELESTIAL ROULETTE (rebirth 10, Roulette): the table in midnight blue
-- printed in gold, a golden armillary sphere over it on two arms (the
-- inner rings turn slowly round a glowing sun), stars and a crescent moon
------------------------------------------------------------------
local function celestialRoulette(def)
	local S = 1.12
	local night, navy, deep, starC = hex("#101A4A"), hex("#1B2366"), hex("#0B1030"), hex("#FFF3C4")
	local model = scaled(rouletteTable(def, {
		felt = night, body = deep, rail = navy, glow = hex("#7AA2FF"), pedestal = deep, bowl = deep,
		ballColor = P.GoldTop, ballMaterial = Enum.Material.Neon, limitFill = navy,
		layout = { line = P.Gold, text = P.GoldTop, zero = hex("#1E8C7A"), red = hex("#7A1530"), black = hex("#0A0E26") },
	}), S)
	local C = Vector3.new(0, 7.55, 1.15)
	local R0 = 2.08

	-- two gold arms from round bases behind the table hold the horizon ring;
	-- a bar between them carries the sign
	for _, s in { -1, 1 } do
		local p0 = Vector3.new(s * 3.15, 0.45, 2.95)
		local p1 = Vector3.new(s * 3.15, 4.3, 2.95)
		local p2 = Vector3.new(s * 2.75, 6.1, 2.2)
		local p3 = Vector3.new(s * R0, C.Y, C.Z)
		cylY(model, "ArmBase", 0.75, 0.45, Vector3.new(s * 3.15, 0.225, 2.95), P.Ink, { solid = true })
		cylY(model, "ArmBaseLip", 0.85, 0.1, Vector3.new(s * 3.15, 0.45, 2.95), P.Gold, { reflectance = 0.15 })
		for _, seg in { { p0, p1, 0.22 }, { p1, p2, 0.2 }, { p2, p3, 0.18 } } do
			rod(model, "Arm", seg[1], seg[2], seg[3], P.Gold, { reflectance = 0.22 })
		end
		ball(model, "ArmJoint", 0.32, p1, P.GoldTop, { reflectance = 0.25 })
		ball(model, "ArmJoint", 0.28, p2, P.GoldTop, { reflectance = 0.25 })
	end
	rod(model, "SignBar", Vector3.new(-3.15, 4.3, 2.95), Vector3.new(3.15, 4.3, 2.95), 0.12, P.Gold, { reflectance = 0.2 })
	boardSign(model, "Sign", Vector3.new(3.6, 0.78, 0.22), CFrame.new(0, 4.75, 2.95), "CELESTIAL", { icon = "star", fill = navy })

	-- the armillary: a fixed horizon and meridian, the turning rings inside
	hoop(model, "Horizon", CFrame.new(C) * CFrame.Angles(math.rad(90), 0, 0), R0, 28, 0.16, P.Gold, { reflectance = 0.22 })
	hoop(model, "Meridian", CFrame.new(C) * CFrame.Angles(0, math.rad(-35), 0), R0, 28, 0.13, P.Gold, { reflectance = 0.22 })
	for _, sy in { -1, 1 } do
		ball(model, "Pole", 0.26, C + Vector3.new(0, sy * R0, 0), P.GoldTop, { reflectance = 0.25 })
	end
	local sph = spinnerAt(model, "Armillary", 14, C)
	hoop(sph, "Equator", CFrame.new(C) * CFrame.Angles(math.rad(90 - 23.5), 0, 0), 1.7, 24, 0.12, P.GoldTop, { reflectance = 0.25 })
	local ecl = CFrame.new(C) * CFrame.Angles(0, 0, math.rad(28)) * CFrame.Angles(math.rad(70), 0, 0)
	hoop(sph, "Ecliptic", ecl, 1.82, 24, 0.17, hex("#5C7CFF"), neonO())
	for k = 0, 11 do
		local a = k * math.pi / 6
		ball(sph, "Zodiac", 0.2, ecl:PointToWorldSpace(Vector3.new(math.cos(a) * 1.82, math.sin(a) * 1.82, 0)), P.GoldTop, neonO())
	end
	local orbit = CFrame.new(C) * CFrame.Angles(0, 0, math.rad(-40)) * CFrame.Angles(math.rad(35), 0, 0)
	hoop(sph, "Orbit", orbit, 1.25, 18, 0.08, P.Chrome, metalO(0.3))
	ball(sph, "OrbitPlanet", 0.32, orbit:PointToWorldSpace(Vector3.new(1.25, 0, 0)), P.NeonPink, neonO())
	ball(sph, "OrbitPlanet", 0.26, orbit:PointToWorldSpace(Vector3.new(-0.88, 0.88, 0)), P.NeonBlue, neonO())
	ball(model, "Sun", 0.95, C, hex("#FFD23F"), neonO())

	-- stars and a crescent moon round the sphere
	for _, t in { { 3.0, 9.0, 1.0, 0.6 }, { -3.1, 8.4, 1.3, 0.5 }, { 1.6, 9.9, 1.4, 0.4 }, { -1.5, 9.85, 0.9, 0.45 },
		{ 3.45, 6.9, 1.6, 0.35 }, { -3.5, 7.2, 0.9, 0.4 } } do
		twinkle(model, Vector3.new(t[1], t[2], t[3]), t[4], starC)
	end
	ball(model, "Moon", 0.72, Vector3.new(-3.05, 9.45, 1.5), starC, neonO())
	ball(model, "MoonShade", 0.64, Vector3.new(-2.86, 9.53, 1.37), deep)
	return model
end

------------------------------------------------------------------
-- MIDAS TOUCH (rebirth 12, Slots): the ultimate machine. A giant pearl-and-
-- gold slot on a white-marble dais, a great golden sunburst blazing behind
-- it, a $100,000,000 meter with a big diamond turning on top, marble columns
-- crowned with coins and gems, gold coins strewn on the steps
------------------------------------------------------------------
local function midasTouch(def)
	local model = new("Model", { Name = def.name })
	local bulbs = new("Folder", { Name = "Bulbs" }, model)
	local marble, ruby, emerald = hex("#F4F1EA"), hex("#FF3B55"), hex("#3DFF6E")
	local function stone() return { material = Enum.Material.Marble, solid = true } end
	-- the dais: two marble steps with gold nosings
	part(model, "Dais", Vector3.new(9.2, 0.3, 5.6), CFrame.new(0, 0.15, 0), marble, stone())
	part(model, "Dais", Vector3.new(6.8, 0.3, 4.6), CFrame.new(0, 0.45, 0.1), marble, stone())
	gold(model, "DaisNose", Vector3.new(9.24, 0.07, 0.07), CFrame.new(0, 0.3, -2.8))
	gold(model, "DaisNose", Vector3.new(6.84, 0.07, 0.07), CFrame.new(0, 0.6, -2.2))

	-- the cabinet: a giant pearl-white slot machine dressed in gold
	local slot = scaled(slotMachine(def, { color = hex("#FFF3DE"), accent = P.GoldTop, title = "MIDAS TOUCH",
		bellyText = "JACKPOT", meter = "$100,000,000" }), 1.2)
	mergeInto(slot, model, bulbs, CFrame.new(0, 0.6, 0))
	model.PrimaryPart = model:FindFirstChild("Body")
	for _, n in { "Body", "Upper" } do
		local p = model:FindFirstChild(n)
		if p and p:IsA("BasePart") then p.Reflectance = 0.12 end
	end

	-- the sunburst behind the cabinet: a gold disc ringed with bulbs and
	-- sixteen rays, long and short
	local Hc = Vector3.new(0, 7.3, 2.3)
	cylZ(model, "SunDisc", 4.8, 0.2, Hc, P.Gold, { reflectance = 0.25 })
	cylZ(model, "SunDiscFace", 4.2, 0.22, Hc, P.GoldTop, { reflectance = 0.2 })
	for k = 0, 15 do
		local a = k * math.pi / 8
		local long = k % 2 == 0
		spike(model, "SunRay", long and 0.7 or 0.5, long and 2.2 or 1.5, 0.14,
			CFrame.new(Hc + Vector3.new(math.cos(a), math.sin(a), 0) * 2.25) * CFrame.Angles(0, 0, a - math.pi / 2), P.Gold,
			{ reflectance = 0.25 })
	end
	bulbArc(bulbs, CFrame.new(Hc + Vector3.new(0, 0, -0.14)), 2.42, 0, 2 * math.pi, 26, 0.18)
	-- the diamond, turning on a gold cup on the meter
	cylY(model, "GemCup", 0.56, 0.12, Vector3.new(0, 9.72, -0.8), P.Gold, { reflectance = 0.3 })
	local gem = spinnerAt(model, "DiamondSpinner", 35, Vector3.new(0, 10.52, -0.8))
	cutGem(gem, 0.85, Vector3.new(0, 10.52, -0.8), hex("#BFF8FF"))
	particles(model, "GoldFX", Vector3.new(3.0, 0.1, 0.5), Vector3.new(0, 9.9, 1.6), "sparks", P.GoldTop, 4, 2)

	-- marble columns at the front corners, crowned with coin stacks and gems
	for _, s in { -1, 1 } do
		local x, z = s * 4.05, -1.6
		cylY(model, "ColumnFoot", 0.95, 0.2, Vector3.new(x, 0.4, z), P.Gold, { reflectance = 0.2 })
		cylY(model, "Column", 0.62, 5.8, Vector3.new(x, 0.5 + 2.9, z), marble, stone())
		for _, y in { 1.0, 5.8 } do
			cylY(model, "ColumnRing", 0.68, 0.1, Vector3.new(x, y, z), P.Gold, { reflectance = 0.2 })
		end
		cylY(model, "Capital", 0.92, 0.28, Vector3.new(x, 6.44, z), P.Gold, { reflectance = 0.25 })
		gold(model, "Abacus", Vector3.new(1.0, 0.12, 1.0), CFrame.new(x, 6.64, z))
		for k = 0, 6 do
			cylY(model, "CoinStack", 0.78, 0.09, Vector3.new(x + ((k * 37) % 5 - 2) * 0.02, 6.75 + k * 0.095, z + ((k * 53) % 5 - 2) * 0.02),
				P.Gold, { reflectance = 0.3 })
		end
		cutGem(model, 0.42, Vector3.new(x, 7.73, z), s > 0 and ruby or emerald)
	end
	-- gold coins scattered on the steps
	for i, c in { { -3.3, 0.3, -2.3 }, { -2.7, 0.3, -2.55 }, { 2.9, 0.3, -2.4 }, { 3.5, 0.3, -2.0 }, { -2.0, 0.6, -2.05 },
		{ 2.3, 0.6, -2.05 }, { 3.6, 0.3, 1.6 }, { -3.7, 0.3, 1.2 } } do
		coin(model, Vector3.new(c[1], c[2] + 0.035, c[3]), 0.36, CFrame.Angles(0, math.rad(i * 40), 0))
	end
	return model
end

------------------------------------------------------------------
-- PROPS (not catalog items)
------------------------------------------------------------------
-- the showroom's concessions & staff desk: a service counter with a menu board
local function servicesDesk()
	local model = new("Model", { Name = "ServicesDesk" })
	local bulbs = new("Folder", { Name = "Bulbs" }, model)
	local blue = hex("#1E9BEA")
	local h0 = plinth(model, 7.4, 3.2, P.NeonBlue)
	-- counter (PrimaryPart: the prompt lives here)
	local counter = part(model, "Counter", Vector3.new(7.0, 1.9, 1.3), CFrame.new(0, h0 + 0.95, -0.75), P.Crimson,
		{ solid = true })
	model.PrimaryPart = counter
	gold(model, "CounterTop", Vector3.new(7.2, 0.16, 1.5), CFrame.new(0, h0 + 1.98, -0.75))
	neon(model, "CounterGlow", Vector3.new(6.8, 0.08, 0.05), CFrame.new(0, h0 + 1.78, -1.42), P.NeonBlue)
	for _, sx in { -1, 1 } do
		gold(model, "EdgeTrim", Vector3.new(0.14, 1.9, 0.14), CFrame.new(sx * 3.5, h0 + 0.95, -1.4))
	end
	local fp = part(model, "FrontPanel", Vector3.new(5.4, 1.05, 0.06), CFrame.new(0, h0 + 0.9, -1.42), P.CrimsonDeep)
	local fg = surface(fp, Enum.NormalId.Front, 100, 0.1)
	local plate = signPlate(fg, P.CrimsonDeep)
	guiText(plate, "CONCESSIONS & STAFF", { size = UDim2.fromScale(0.9, 0.56), position = UDim2.fromScale(0.05, 0.22),
		gradient = { P.GoldTop, P.Gold }, strokeThickness = 6 })
	-- service bell + a popcorn bucket on the counter
	local topY = h0 + 2.06
	cylY(model, "BellBase", 0.5, 0.08, Vector3.new(2.3, topY + 0.04, -0.85), P.Ink)
	ball(model, "Bell", 0.42, Vector3.new(2.3, topY + 0.1, -0.85), P.Gold, { reflectance = 0.3 })
	cylY(model, "Bucket", 0.45, 0.55, Vector3.new(-2.4, topY + 0.28, -0.8), P.Crimson)
	ball(model, "BucketTop", 0.42, Vector3.new(-2.4, topY + 0.6, -0.8), hex("#FFF1B8"), { shadow = false })
	-- back wall with two menu boards (sized so the canopy edge clears them)
	part(model, "BackWall", Vector3.new(7.0, 4.6, 0.4), CFrame.new(0, h0 + 2.3, 1.2), P.WoodDark, { solid = true })
	-- STAFF on the player's left (model +X), SNACKS on the right
	for i, m in { { 1.75, "STAFF", "staff", hex("#0F5A99") }, { -1.75, "SNACKS", "popcorn", P.CrimsonDeep } } do
		boardSign(model, "Menu" .. i, Vector3.new(3.1, 1.3, 0.15), CFrame.new(m[1], h0 + 2.95, 0.93), m[2],
			{ icon = m[3], fill = m[4], ppu = 90 })
	end
	-- posts + blue/white canopy + header sign
	for _, sx in { -1, 1 } do
		cylY(model, "Post", 0.16, 2.0, Vector3.new(sx * 3.35, topY + 1.0, -1.3), P.Gold, { reflectance = 0.15 })
	end
	canopy(model, 7.4, h0 + 4.6, 1.4, -1.55, 0.5, { blue, P.White })
	boardSign(model, "Header", Vector3.new(4.2, 1.05, 0.3), CFrame.new(0, h0 + 5.2, 1.2), "SERVICES",
		{ icon = "shop", bothSides = true })
	bulbsAlong(bulbs, Vector3.new(-3.6, h0 + 4.0, -1.62), Vector3.new(3.6, h0 + 4.0, -1.62), 14)
	return model
end

-- the showroom's marquee board ringed with bulbs (wall size, or the big one
-- on the building's facade). perSide / bulbD: bulbs along a long side and
-- their diameter (default: 1.5 per stud at 0.16)
local function showroomSign(w: number?, h: number?, perSide: number?, bulbD: number?)
	w, h = w or 20, h or 3.1
	local model = new("Model", { Name = "ShowroomSign" })
	local bulbs = new("Folder", { Name = "Bulbs" }, model)
	local board = boardSign(model, "Board", Vector3.new(w, h, 0.4), CFrame.new(0, h / 2, 0), "MACHINE SHOWROOM",
		{ icon = "slot", ppu = math.floor(720 / w), stroke = 5 })
	model.PrimaryPart = board
	bulbFrame(bulbs, 0, h / 2, w + 0.2, h + 0.2, -0.25, perSide or math.floor(w * 1.5), bulbD)
	return model
end

-- the Rebirth Wing's marquee: a royal-purple board, REBIRTH WING and the
-- rebirth icon on both faces, bulbs round both (it hangs mid-hall over the
-- wing's threshold, seen from either side). Origin: the board's bottom centre.
local function rebirthWingSign()
	local w, h = 30, 3.4
	local model = new("Model", { Name = "RebirthWingSign" })
	local bulbs = new("Folder", { Name = "Bulbs" }, model)
	local board = boardSign(model, "Board", Vector3.new(w, h, 0.4), CFrame.new(0, h / 2, 0), "REBIRTH WING",
		{ icon = UIAssets.icon("rebirth"), fill = hex("#3A1466"), ppu = 24, stroke = 5, bothSides = true })
	model.PrimaryPart = board
	for _, z in { -0.25, 0.25 } do
		bulbFrame(bulbs, 0, h / 2, w + 0.2, h + 0.2, z, 40, 0.3)
	end
	return model
end

local PROPS = {
	ServicesDesk = servicesDesk,
	ShowroomSign = function() return showroomSign() end,
	ShowroomFacadeSign = function() return showroomSign(40, 5.6) end,
	-- the showroom's back feature wall, above the back-row machines: fewer,
	-- bigger bulbs that still read across the hall
	ShowroomWallSign = function() return showroomSign(34, 3.6, 26, 0.3) end,
	RebirthWingSign = rebirthWingSign,
}

------------------------------------------------------------------
-- registry
------------------------------------------------------------------
local BUILDERS = {
	LuckySevens = function(def)
		return slotMachine(def, { color = P.Crimson, accent = P.NeonRed, title = "LUCKY 7s", belly = "777" })
	end,
	DiamondSlots = function(def)
		return slotMachine(def, { color = hex("#8A4DE8"), accent = P.NeonPink, title = "DIAMOND", icon = "gem",
			topIcon = true })
	end,
	Roulette = rouletteTable,
	Blackjack = blackjackTable,
	Dice = diceGame,
	FortuneWheel = fortuneWheel,
	SnackStand = snackStand,
	DrinkBar = drinkBar,
	SouvenirCart = souvenirCart,
	Vending = vendingMachine,
	-- high-tier machines: variants of the classics + new designs
	GoldenSevens = function(def)
		return scaled(slotMachine(def, { color = hex("#B9780A"), accent = P.Amber, title = "GOLDEN 7s", belly = "777",
			icon = "crown", topIcon = true }), 1.1)
	end,
	MegaJackpot = function(def)
		return scaled(slotMachine(def, { color = hex("#A8206E"), accent = P.NeonPink, title = "MEGA JACKPOT",
			bellyText = "JACKPOT", meter = "$1,000,000" }), 1.3)
	end,
	VIPRoulette = function(def)
		return rouletteTable(def, { felt = hex("#4A1A7A"), rail = hex("#1A1420"), body = P.Ink, glow = P.NeonPink })
	end,
	HighRollerBlackjack = function(def)
		return blackjackTable(def, { felt = hex("#7A0F2A"), glow = P.NeonRed })
	end,
	MegaWheel = function(def)
		return scaled(fortuneWheel(def, { body = hex("#5B1FA0"), title = "MEGA WHEEL", icon = "crown", glow = P.NeonPink,
			signFill = hex("#3A0F6A") }), 1.3)
	end,
	Craps = crapsTable,
	IceCreamCart = iceCreamCart,
	BurgerGrill = burgerGrill,
	ATM = atmMachine,
	GiftBoutique = giftBoutique,
	-- the economy patch: seven machines (Plinko is a new game type) + three stands
	PlinkoBoard = plinkoMachine,
	VideoPoker = videoPoker,
	SicBoDome = sicBoDome,
	Baccarat = baccaratTable,
	PachinkoPalace = pachinkoPalace,
	DiamondDragon = dragonSlots,
	BillionaireRoulette = billionaireRoulette,
	BubbleTeaBar = bubbleTeaBar,
	SushiBar = sushiBar,
	JewelryBoutique = jewelryBoutique,
	-- the Rebirth Wing (each needs rebirths: Config.Catalog `rebirth`)
	PhoenixFire = phoenixFire,
	ThunderWheel = thunderWheel,
	CrystalCavern = crystalCavern,
	GalaxyDrop = galaxyDrop,
	PharaohRoulette = pharaohRoulette,
	PotOGold = potOGold,
	RoyalCrown21 = royalCrown21,
	NeptuneTreasure = neptuneTreasure,
	VolcanoEruption = volcanoEruption,
	EmperorWheel = emperorWheel,
	DiamondVault = diamondVault,
	CelestialRoulette = celestialRoulette,
	MidasTouch = midasTouch,
}

function MachineModels.has(name: string?): boolean
	return name ~= nil and BUILDERS[name] ~= nil
end

-- Pivot a freshly built model (still at the model-space origin) on the ground
-- and note how far in front of its PrimaryPart a visitor should stand.
local function finalize(model: Model)
	model.WorldPivot = CFrame.new() -- model space origin = centre of the footprint on the ground
	-- with a PrimaryPart the model's pivot is that part's pivot (WorldPivot is
	-- ignored), so aim the part's PivotOffset at the same ground origin
	local primary = model.PrimaryPart
	if primary then
		primary.PivotOffset = primary.CFrame:Inverse()
		-- the front edge is the lowest Z of the bounding box (front faces -Z);
		-- NPCs stand this far out along the PrimaryPart's LookVector
		local bbCF, bbSize = model:GetBoundingBox()
		local frontZ = bbCF.Position.Z - bbSize.Z / 2
		model:SetAttribute("ApproachDistance", math.floor(((primary.Position.Z - frontZ) + 1.4) * 10 + 0.5) / 10)
	end
	model:SetAttribute("GroundPivot", true) -- PivotTo(groundCF) seats it; see MachineVisuals.seat
end

-- Built models are cached per catalog id: the first build of a type may yield
-- (half-moon tables use CSG), every later one is a cheap clone.
local cache: {[string]: Model} = {}

-- Build (or clone) the model for a catalog def (def.model names the builder).
function MachineModels.build(def): Model?
	local fn = def and def.model and BUILDERS[def.model]
	if not fn then return nil end
	local key = tostring(def.id or def.model)
	local cached = cache[key]
	if cached then return cached:Clone() end
	local ok, model = pcall(fn, def)
	if not ok then
		warn("[MachineModels] building " .. tostring(def.model) .. " failed: " .. tostring(model))
		return nil
	end
	finalize(model)
	cache[key] = model
	return model:Clone()
end

-- the shared building kit, reused by the map tools (ServerStorage.MapTools)
MachineModels.Kit = {
	new = new, part = part, neon = neon, gold = gold, cylX = cylX, cylY = cylY, cylZ = cylZ, ball = ball,
	stadium = stadium, surface = surface, flatPrint = flatPrint, guiText = guiText, guiImage = guiImage,
	signPlate = signPlate, bulbsAlong = bulbsAlong, bulbFrame = bulbFrame, plinth = plinth,
	boardSign = boardSign, canopy = canopy, dieIcon = dieIcon, chipStack = chipStack, hex = hex,
	finalize = finalize,
	wedge = wedge, spike = spike, rod = rod, spinner = spinner, cutGem = cutGem,
}

-- Build a non-catalog prop (e.g. "ServicesDesk"), pivoted like the machines.
function MachineModels.buildProp(name: string): Model?
	local fn = PROPS[name]
	if not fn then return nil end
	local key = "prop:" .. name
	if cache[key] then return cache[key]:Clone() end
	local ok, model = pcall(fn)
	if not ok then
		warn("[MachineModels] building prop " .. name .. " failed: " .. tostring(model))
		return nil
	end
	finalize(model)
	cache[key] = model
	return model:Clone()
end

return MachineModels
