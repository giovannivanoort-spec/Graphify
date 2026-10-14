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
--   Slots     Spinny1..3 (Decal per reel), LEDs, Lever (model), sounds in Body
--   Roulette  Wheel (+ Turret, Ball) spin around Y
--   Wheel     Wheel spins around the Z axis, Pointer at the top
--   Dice      Die1, Die2
--   any       Bulbs (folder of neon balls for the marquee chase)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GeometryService = game:GetService("GeometryService")
local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local UIAssets = require(Common:WaitForChild("UIAssets"))

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
-- bulbs around a rectangle lying in an XY plane at depth z (front frame)
local function bulbFrame(folder, cx, cy, w, h, z, perSide)
	local x0, x1, y0, y1 = cx - w / 2, cx + w / 2, cy - h / 2, cy + h / 2
	bulbsAlong(folder, Vector3.new(x0, y1, z), Vector3.new(x1, y1, z), perSide)
	bulbsAlong(folder, Vector3.new(x0, y0, z), Vector3.new(x1, y0, z), perSide)
	local side = math.max(2, math.floor(perSide * h / w))
	bulbsAlong(folder, Vector3.new(x0, y0, z), Vector3.new(x0, y1, z), side)
	bulbsAlong(folder, Vector3.new(x1, y0, z), Vector3.new(x1, y1, z), side)
end

-- the shared ink plinth with a gold lip and a neon underglow
local function plinth(model, w: number, d: number, glow: Color3, h: number?)
	h = h or 0.45
	part(model, "Plinth", Vector3.new(w, h, d), CFrame.new(0, h / 2, 0), P.Ink, { solid = true })
	gold(model, "PlinthLip", Vector3.new(w + 0.14, 0.12, d + 0.14), CFrame.new(0, h - 0.03, 0))
	neon(model, "Underglow", Vector3.new(w - 0.3, 0.07, 0.05), CFrame.new(0, 0.16, -d / 2 - 0.025), glow)
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
	if spec.belly == "777" then
		guiText(bg, "777", { size = UDim2.new(0.86, 0, 0.8, 0), position = UDim2.fromScale(0.07, 0.1),
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
	if spec.icon and spec.topIcon then
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

local function rouletteLayout(gui)
	local root = new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) }, gui)
	new("UIPadding", { PaddingLeft = UDim.new(0.02, 0), PaddingRight = UDim.new(0.02, 0),
		PaddingTop = UDim.new(0.04, 0), PaddingBottom = UDim.new(0.04, 0) }, root)
	local function cell(parent, text, pos, size, fill)
		local f = new("Frame", { BackgroundColor3 = fill, Position = pos, Size = size, BorderSizePixel = 0 }, parent)
		new("UIStroke", { Color = P.White, Thickness = 3, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, f)
		local l = new("TextLabel", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Text = text,
			Font = Enum.Font.GothamBlack, TextScaled = true, TextColor3 = P.White }, f)
		new("UIPadding", { PaddingTop = UDim.new(0.18, 0), PaddingBottom = UDim.new(0.18, 0) }, l)
		return f
	end
	local felt = P.Felt
	-- zero spans the three number rows on the left
	cell(root, "0", UDim2.fromScale(0, 0), UDim2.fromScale(0.07, 0.72), hex("#24A046"))
	for col = 0, 11 do
		for row = 0, 2 do
			local n = col * 3 + (3 - row)
			cell(root, tostring(n), UDim2.fromScale(0.07 + col * 0.0775, row * 0.24),
				UDim2.fromScale(0.0775, 0.24), REDS[n] and P.Crimson or hex("#231C20"))
		end
	end
	local outside = { "1-18", "EVEN", "RED", "BLACK", "ODD", "19-36" }
	for i, t in outside do
		local fill = (t == "RED" and P.Crimson) or (t == "BLACK" and hex("#231C20")) or felt
		cell(root, t, UDim2.fromScale(0.07 + (i - 1) * 0.155, 0.74), UDim2.fromScale(0.155, 0.26), fill)
	end
end

local function rouletteTable(def)
	local model = new("Model", { Name = def.name })
	local bulbs = new("Folder", { Name = "Bulbs" }, model)
	local L, Wd = 4.2, 4.6       -- straight length + width of the stadium top
	local topY = 3.0

	-- ink plinth + two wooden pedestals with gold bands
	part(model, "Plinth", Vector3.new(6.2, 0.4, 3.2), CFrame.new(0, 0.2, 0), P.Ink, { solid = true })
	gold(model, "PlinthLip", Vector3.new(6.34, 0.1, 3.34), CFrame.new(0, 0.38, 0))
	neon(model, "Underglow", Vector3.new(5.9, 0.07, 0.05), CFrame.new(0, 0.14, -1.625), P.NeonGreen)
	for _, sx in { -1, 1 } do
		part(model, "Pedestal", Vector3.new(1.0, 2.1, 2.2), CFrame.new(sx * 2.0, 0.4 + 1.05, 0), P.Wood, { solid = true })
		gold(model, "PedestalBand", Vector3.new(1.1, 0.16, 2.3), CFrame.new(sx * 2.0, 2.25, 0))
	end

	-- table body, padded leather rail, gold trim, felt
	local body = stadium(model, "Body", L, Wd, 0.55, Vector3.new(0, topY - 0.3, 0), P.WoodDark, { solid = true })
	model.PrimaryPart = body
	stadium(model, "Rail", L, Wd + 0.35, 0.36, Vector3.new(0, topY + 0.12, 0), P.Leather, { material = Enum.Material.Leather })
	stadium(model, "FeltTrim", L, Wd - 0.12, 0.04, Vector3.new(0, topY + 0.3, 0), P.Gold, { reflectance = 0.12 })
	stadium(model, "Felt", L, Wd - 0.3, 0.06, Vector3.new(0, topY + 0.32, 0), P.Felt, { material = Enum.Material.Fabric })
	local surfaceY = topY + 0.35

	-- wheel well at the player's left end (model +X): wooden bowl, gold lip,
	-- spinning wheel + turret + ball. The layout's 0 sits next to it.
	local wx = L / 2
	cylY(model, "Bowl", 3.3, 0.36, Vector3.new(wx, surfaceY + 0.16, 0), P.Wood)
	cylY(model, "BowlLip", 3.5, 0.1, Vector3.new(wx, surfaceY + 0.34, 0), P.Gold, { reflectance = 0.15 })
	local wheel = cylY(model, "Wheel", 3.0, 0.06, Vector3.new(wx, surfaceY + 0.4, 0), P.White)
	new("Decal", { Face = Enum.NormalId.Right, Texture = MachineModels.Textures.roulette }, wheel)
	cylY(model, "Turret", 0.34, 0.42, Vector3.new(wx, surfaceY + 0.62, 0), P.Gold, { reflectance = 0.2 })
	ball(model, "TurretKnob", 0.3, Vector3.new(wx, surfaceY + 0.86, 0), P.GoldTop, { reflectance = 0.2 })
	ball(model, "Ball", 0.16, Vector3.new(wx - 1.22, surfaceY + 0.48, 0), P.White, { reflectance = 0.3 })

	-- betting layout printed on the felt (the other half)
	local layout = flatPrint(model, "Layout", 3.6, 2.9, CFrame.new(-1.45, surfaceY + 0.01, 0.05))
	local lg = surface(layout, Enum.NormalId.Top, 100, 0.3)
	rouletteLayout(lg)

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
	local plate = signPlate(sg, P.Felt)
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
local function blackjackTable(def)
	local model = new("Model", { Name = def.name })
	local bulbs = new("Folder", { Name = "Bulbs" }, model)
	local R, zc, topY = 3.7, 1.0, 3.0

	part(model, "Plinth", Vector3.new(6.6, 0.4, 2.6), CFrame.new(0, 0.2, -0.4), P.Ink, { solid = true })
	gold(model, "PlinthLip", Vector3.new(6.74, 0.1, 2.74), CFrame.new(0, 0.38, -0.4))
	neon(model, "Underglow", Vector3.new(6.3, 0.07, 0.05), CFrame.new(0, 0.14, -1.725), P.NeonBlue)
	for _, sx in { -1, 1 } do
		part(model, "Pedestal", Vector3.new(1.0, 2.1, 1.8), CFrame.new(sx * 2.2, 1.45, -0.4), P.Wood, { solid = true })
		gold(model, "PedestalBand", Vector3.new(1.1, 0.16, 1.9), CFrame.new(sx * 2.2, 2.25, -0.4))
	end

	halfDisc(model, "Body", R, 0.55, Vector3.new(0, topY - 0.3, zc), P.WoodDark, { solid = true })
	halfDisc(model, "Rail", R + 0.22, 0.36, Vector3.new(0, topY + 0.12, zc), P.Leather, { material = Enum.Material.Leather })
	halfDisc(model, "FeltTrim", R - 0.12, 0.04, Vector3.new(0, topY + 0.3, zc), P.Gold, { reflectance = 0.12 })
	halfDisc(model, "Felt", R - 0.28, 0.06, Vector3.new(0, topY + 0.32, zc), P.FeltBlue, { material = Enum.Material.Fabric })
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
	local printPart = flatPrint(model, "FeltPrint", 4.4, 1.2, CFrame.new(0, surfaceY + 0.012, zc - 1.0), P.FeltBlue)
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
		cylY(model, "SpotInner", 0.68, 0.025, pos + Vector3.new(0, 0.01, 0), P.FeltBlue,
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
local function fortuneWheel(def)
	local model = new("Model", { Name = def.name })
	local bulbs = new("Folder", { Name = "Bulbs" }, model)
	local h0 = plinth(model, 4.8, 2.6, P.GoldTop)
	local col = hex("#FFCB2E")

	local body = part(model, "Body", Vector3.new(3.6, 1.3, 1.8), CFrame.new(0, h0 + 0.65, 0.2), P.Crimson, { solid = true })
	model.PrimaryPart = body
	gold(model, "BodyTrim", Vector3.new(3.7, 0.12, 1.9), CFrame.new(0, h0 + 1.3, 0.2))
	local fp = part(model, "FrontPanel", Vector3.new(3.0, 0.9, 0.06), CFrame.new(0, h0 + 0.65, -0.72), P.CrimsonDeep)
	local fg = surface(fp, Enum.NormalId.Front, 100, 0.1)
	local plate = signPlate(fg, P.CrimsonDeep)
	guiText(plate, "SPIN TO WIN", { size = UDim2.fromScale(0.86, 0.6), position = UDim2.fromScale(0.07, 0.2),
		gradient = { P.GoldTop, P.Gold }, strokeThickness = 6 })
	-- post holding the wheel
	part(model, "Post", Vector3.new(0.7, 4.2, 0.7), CFrame.new(0, h0 + 1.3 + 2.1, 0.55), P.Crimson, { solid = true })
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
	boardSign(model, "Topper", Vector3.new(3.6, 0.85, 0.3), CFrame.new(0, cy + R + 1.25, 0.15), "LUCKY WHEEL", { icon = "star" })
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
-- on the building's facade)
local function showroomSign(w: number?, h: number?)
	w, h = w or 20, h or 3.1
	local model = new("Model", { Name = "ShowroomSign" })
	local bulbs = new("Folder", { Name = "Bulbs" }, model)
	local board = boardSign(model, "Board", Vector3.new(w, h, 0.4), CFrame.new(0, h / 2, 0), "MACHINE SHOWROOM",
		{ icon = "slot", ppu = math.floor(720 / w), stroke = 5 })
	model.PrimaryPart = board
	bulbFrame(bulbs, 0, h / 2, w + 0.2, h + 0.2, -0.25, math.floor(w * 1.5))
	return model
end

local PROPS = {
	ServicesDesk = servicesDesk,
	ShowroomSign = function() return showroomSign() end,
	ShowroomFacadeSign = function() return showroomSign(40, 5.6) end,
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
