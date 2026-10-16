--!nonstrict
-- MapProps.luau — the prop kit for the city map (Edit-time tool, see
-- MapBuilder). Every builder works in model space like MachineModels: ground at
-- y = 0, centred on x/z, FRONT = -Z, and returns a Model whose pivot is that
-- ground origin. Styling reuses MachineModels.Kit so the street furniture,
-- signs and casinos share one "Showtime" look (ink + brass + neon bulbs).
-- World colours come from WorldPalette; world metal is the Materials "Brass"
-- (the UI gold P.Gold stays on lettering and bulbs only).

local MapProps = {}

local K, P, hex
local Icons
local Mats, WP

local C = {}
local function palette()
	C.Dark = WP.DarkMetal         -- lamp posts, bins, fixtures
	C.Trunk = hex("#7A5A3E")
	C.TrunkDark = hex("#62472F")
	C.Frond = hex("#2F8F3E")
	C.FrondTip = hex("#3FAE4C")
	C.WarmLight = WP.Sodium
end

-- MapBuilder hands in a fresh MachineModels, UIAssets, Materials and
-- WorldPalette before building (other callers may leave the last two out)
function MapProps.init(machineModels, uiAssets, materials, worldPalette)
	K = machineModels.Kit
	P = machineModels.Palette
	hex = K.hex
	Icons = uiAssets.Icons
	local Common = game:GetService("ReplicatedStorage"):WaitForChild("CasinoCommon")
	Mats = materials or require(Common:WaitForChild("Materials"))
	WP = worldPalette or require(Common:WaitForChild("WorldPalette"))
	palette()
end

-- fresh opts per call: the kit's cylinder/ball helpers write .shape into opts
local function decor() return { shadow = false } end

-- lights (and lamp lenses / beams) that only run after dark: DayNightFX
local function night(inst: Instance)
	game:GetService("CollectionService"):AddTag(inst, "NightLight")
	return inst
end
MapProps.night = night

-- world metal: brushed brass painted WP.Brass (works on any part shape)
local function brass(p: BasePart): BasePart
	return Mats.paint(p, "Brass", WP.Brass)
end
MapProps.brass = brass

-- the map's stand-in for K.gold: same box, but brass instead of UI gold
local function gold(parent, name, size: Vector3, cf: CFrame, opts)
	return brass(K.part(parent, name, size, cf, WP.Brass, opts))
end
MapProps.gold = gold

-- stone plinths, planters and sign bases: honed dark granite
local function granite(p: BasePart): BasePart
	return Mats.paint(p, "HonedStone", WP.Granite)
end
MapProps.granite = granite

-- decorative neon is only lit after dark. By day it shows its hue sunk 60%
-- toward warm charcoal, as painted metal (DayNightFX swaps via attributes).
local NEON_DAY_BASE = Color3.fromRGB(60, 52, 56)
local function dimmed(c: Color3): Color3
	return c:Lerp(NEON_DAY_BASE, 0.6)
end
MapProps.dimmed = dimmed

-- tag a part as night-only neon: Neon `color` after dark, SmoothPlastic `day`
-- (default: dimmed hue) by day. Built in its day state, since servers boot in
-- the afternoon (Config.DayNight.StartClock) and Studio shows it that way too.
local function nightNeon(p: BasePart, color: Color3, day: Color3?, dayT: number?, nightT: number?): BasePart
	local dayColor = day or dimmed(color)
	p:SetAttribute("DayMaterial", "SmoothPlastic")
	p:SetAttribute("NightMaterial", "Neon")
	p:SetAttribute("DayColor", dayColor)
	p:SetAttribute("NightColor", color)
	p:SetAttribute("DayTransparency", dayT or 0)
	p:SetAttribute("NightTransparency", nightT or 0)
	p.Material = Enum.Material.SmoothPlastic
	p.Color = dayColor
	p.Transparency = dayT or 0
	night(p)
	return p
end
MapProps.nightNeon = nightNeon

local function model(name)
	return K.new("Model", { Name = name })
end

-- a part stretched between two points (axis = its local Z)
local function beamPart(parent, name, a: Vector3, b: Vector3, w: number, h: number, color, opts)
	local len = (b - a).Magnitude
	return K.part(parent, name, Vector3.new(w, h, len), CFrame.lookAt((a + b) / 2, b), color, opts)
end

-- a cylinder between two points
local function rod(parent, name, a: Vector3, b: Vector3, d: number, color, opts)
	opts = table.clone(opts or {})
	opts.shape = Enum.PartType.Cylinder
	local len = (b - a).Magnitude
	return K.part(parent, name, Vector3.new(len, d, d),
		CFrame.lookAt((a + b) / 2, b) * CFrame.Angles(0, math.rad(90), 0), color, opts)
end
MapProps.rod = rod

-- SurfaceGui that glows (LightInfluence 0 + Brightness) for signage
local function glowGui(p, face, ppu, brightness)
	local g = K.surface(p, face, ppu or 60, 0)
	pcall(function() g.Brightness = brightness or 1.6 end)
	return g
end
MapProps.glowGui = glowGui

------------------------------------------------------------------
-- PALM TREE (curved tapered trunk, 8 fronds, brass-rim planter)
-- opts.bare: planted straight in a lawn or median bed (no pot; the trunk
-- starts at y = 0). opts.lite: a cheaper tree for groves and medians (4
-- trunk segments, 6 fronds, no coconuts: 17 parts instead of 30).
------------------------------------------------------------------
function MapProps.palm(seed: number?, height: number?, opts)
	opts = opts or {}
	local rng = Random.new(seed or 1)
	local h = height or rng:NextNumber(20, 27)
	local m = model("Palm")
	local base = 0
	if not opts.bare then
		granite(K.cylY(m, "Planter", 3.6, 1.0, Vector3.new(0, 0.5, 0), WP.Granite, { solid = true }))
		brass(K.cylY(m, "PlanterCap", 3.9, 0.2, Vector3.new(0, 1.05, 0), WP.Brass, decor()))
		K.cylY(m, "Soil", 3.3, 0.1, Vector3.new(0, 1.12, 0), hex("#2B1E16"), decor())
		base = 1.1
	end

	local yaw = rng:NextNumber(0, math.pi * 2)
	local dir = Vector3.new(math.cos(yaw), 0, math.sin(yaw))
	local lean = rng:NextNumber(0.05, 0.13)
	local function at(t) return Vector3.new(0, base + t * h, 0) + dir * (lean * h * t * t) end
	local segs = opts.lite and 4 or 7
	for i = 1, segs do
		local a, b = at((i - 1) / segs), at(i / segs)
		local d = 1.45 - (i - 1) * (0.56 / segs)
		rod(m, "Trunk", a - (b - a).Unit * 0.12, b + (b - a).Unit * 0.12, d, (i % 2 == 0) and C.Trunk or C.TrunkDark,
			{ material = Enum.Material.Wood, solid = i <= segs / 3.5 })
	end

	local top = at(1)
	K.ball(m, "Heart", 1.5, top, hex("#3A6E2A"), decor())
	local fronds = opts.lite and 6 or 8
	for k = 0, fronds - 1 do
		local ang = k * math.pi * 2 / fronds + rng:NextNumber(-0.18, 0.18)
		local fd = Vector3.new(math.cos(ang), 0, math.sin(ang))
		local e1, e2 = math.rad(rng:NextNumber(10, 24)), math.rad(-rng:NextNumber(28, 44))
		local p1 = top + (fd * math.cos(e1) + Vector3.yAxis * math.sin(e1)) * rng:NextNumber(4.0, 5.0)
		local p2 = p1 + (fd * math.cos(e2) + Vector3.yAxis * math.sin(e2)) * rng:NextNumber(4.2, 5.4)
		local tint = rng:NextNumber(-0.06, 0.06)
		local function shade(c) return Color3.new(math.clamp(c.R + tint, 0, 1), math.clamp(c.G + tint, 0, 1), math.clamp(c.B + tint, 0, 1)) end
		beamPart(m, "Frond", top, p1, 1.8, 0.16, shade(C.Frond), decor())
		-- tapered tip: a wedge laid flat (its thin end points away from the trunk)
		local mid = (p1 + p2) / 2
		K.new("WedgePart", {
			Name = "FrondTip", Anchored = true, CanCollide = false, CanQuery = false, CanTouch = false, CastShadow = false,
			Size = Vector3.new(0.16, 1.6, (p2 - p1).Magnitude + 0.2), Color = shade(C.FrondTip),
			Material = Enum.Material.SmoothPlastic, CFrame = CFrame.lookAt(mid, p2) * CFrame.Angles(0, 0, math.rad(90)),
		}, m)
	end
	if not opts.lite then
		for k = 0, 2 do
			local a = k * 2.1
			K.ball(m, "Coconut", 0.85, top + Vector3.new(math.cos(a) * 0.7, -0.9, math.sin(a) * 0.7), hex("#5A3B22"), decor())
		end
	end
	return m
end

------------------------------------------------------------------
-- STREET LAMP (single arm toward +X, or double); real light = SpotLight down
------------------------------------------------------------------
function MapProps.lamp(double: boolean?)
	local m = model(double and "DoubleLamp" or "StreetLamp")
	K.cylY(m, "Base", 1.3, 1.2, Vector3.new(0, 0.6, 0), C.Dark, { solid = true, material = Enum.Material.Metal })
	brass(K.cylY(m, "Band", 0.95, 0.3, Vector3.new(0, 1.35, 0), WP.Brass, decor()))
	K.cylY(m, "Pole", 0.5, 14.6, Vector3.new(0, 1.2 + 7.3, 0), C.Dark, { solid = true, material = Enum.Material.Metal })
	brass(K.ball(m, "Finial", 0.65, Vector3.new(0, 16.2, 0), WP.Brass, { shadow = false }))
	for _, s in (double and { -1, 1 } or { 1 }) do
		K.part(m, "Arm", Vector3.new(3.6, 0.25, 0.25), CFrame.new(s * 1.8, 15.3, 0), C.Dark, { material = Enum.Material.Metal })
		K.part(m, "Head", Vector3.new(1.7, 0.5, 1.0), CFrame.new(s * 3.45, 15.0, 0), C.Dark, { material = Enum.Material.Metal })
		local lens = night(K.neon(m, "Lens", Vector3.new(1.35, 0.12, 0.8), CFrame.new(s * 3.45, 14.7, 0), WP.BulbA))
		night(K.new("SpotLight", {
			Face = Enum.NormalId.Bottom, Angle = 95, Range = 46, Brightness = 3.4,
			Color = C.WarmLight, Shadows = false,
		}, lens))
	end
	return m
end

------------------------------------------------------------------
-- CARS (taxi / limo / sport), length along Z, nose at -Z
------------------------------------------------------------------
function MapProps.car(kind: string)
	local m = model(kind == "limo" and "Limo" or (kind == "taxi" and "Taxi" or "Car"))
	local L = (kind == "limo") and 17 or 11
	local W = 5.2
	local body = (kind == "taxi" and hex("#FFC21A")) or (kind == "limo" and hex("#15131A")) or hex("#D7263D")
	K.part(m, "Body", Vector3.new(W, 1.7, L), CFrame.new(0, 1.75, 0), body, { reflectance = 0.25, solid = true })
	K.part(m, "Skirt", Vector3.new(W - 0.1, 0.5, L - 0.6), CFrame.new(0, 0.9, 0), hex("#111016"), decor())
	local cabL = (kind == "limo") and 10.5 or 5.6
	local cabZ = 0.6
	K.part(m, "Cabin", Vector3.new(W - 0.6, 1.5, cabL), CFrame.new(0, 3.3, cabZ), hex("#1A2433"), { reflectance = 0.35 })
	K.part(m, "Roof", Vector3.new(W - 0.7, 0.18, cabL - 0.4), CFrame.new(0, 4.12, cabZ), body, { reflectance = 0.25 })
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			local wp = Vector3.new(sx * (W / 2 - 0.3), 1.1, sz * (L / 2 - 2.2))
			K.cylX(m, "Tire", 2.2, 0.8, wp, hex("#0E0E12"), decor())
			K.cylX(m, "Rim", 1.2, 0.86, wp, P.Chrome, { reflectance = 0.3, material = Enum.Material.Metal, shadow = false })
		end
		K.neon(m, "Headlight", Vector3.new(1.1, 0.45, 0.1), CFrame.new(sx * 1.75, 2.0, -L / 2 - 0.04), hex("#FFF4D6"))
		K.neon(m, "Taillight", Vector3.new(1.1, 0.4, 0.1), CFrame.new(sx * 1.85, 2.05, L / 2 + 0.04), hex("#FF4D63"))
	end
	K.part(m, "Grille", Vector3.new(2.0, 0.6, 0.08), CFrame.new(0, 1.8, -L / 2 - 0.04), P.Chrome,
		{ reflectance = 0.3, material = Enum.Material.Metal, shadow = false })
	if kind == "taxi" then
		local sign = K.part(m, "TaxiSign", Vector3.new(1.8, 0.6, 0.5), CFrame.new(0, 4.5, cabZ), hex("#FFF1C2"), decor())
		for _, face in { Enum.NormalId.Left, Enum.NormalId.Right } do
			local g = glowGui(sign, face, 80, 1.4)
			K.guiText(g, "TAXI", { color = P.Ink, stroke = false, font = Enum.Font.GothamBlack })
		end
		for _, sx in { -1, 1 } do
			local stripe = K.part(m, "Stripe", Vector3.new(0.06, 0.5, L - 1.5), CFrame.new(sx * (W / 2 + 0.02), 2.0, 0), P.Ink, decor())
			local g = K.surface(stripe, sx > 0 and Enum.NormalId.Right or Enum.NormalId.Left, 40, 0.3)
			K.guiText(g, "CASINO MASTERS CAB", { color = P.Gold, stroke = false, font = Enum.Font.GothamBlack })
		end
	elseif kind == "limo" then
		for _, sx in { -1, 1 } do
			K.part(m, "Chrome", Vector3.new(0.06, 0.18, L - 1), CFrame.new(sx * (W / 2 + 0.02), 2.35, 0), P.Chrome,
				{ reflectance = 0.4, material = Enum.Material.Metal, shadow = false })
		end
	end
	return m
end

------------------------------------------------------------------
-- WELCOME SIGN (original Strip-style lozenge with letter discs + star)
------------------------------------------------------------------
function MapProps.welcomeSign()
	local m = model("WelcomeSign")
	local bulbs = K.new("Folder", { Name = "Bulbs" }, m)
	granite(K.part(m, "Base", Vector3.new(20, 1.2, 6), CFrame.new(0, 0.6, 0), WP.Granite, { solid = true }))
	gold(m, "BaseLip", Vector3.new(20.3, 0.2, 6.3), CFrame.new(0, 1.25, 0), decor())
	nightNeon(K.neon(m, "BaseGlow", Vector3.new(19.6, 0.12, 0.08), CFrame.new(0, 0.3, -3.05), WP.Magenta), WP.Magenta)
	nightNeon(K.neon(m, "BaseGlowBack", Vector3.new(19.6, 0.12, 0.08), CFrame.new(0, 0.3, 3.05), WP.Magenta), WP.Magenta)
	for _, sx in { -1, 1 } do
		K.part(m, "Post", Vector3.new(1.3, 9.4, 1.3), CFrame.new(sx * 5, 6.0, 0), P.Cream, { solid = true })
		gold(m, "PostBand", Vector3.new(1.5, 0.3, 1.5), CFrame.new(sx * 5, 2.2, 0), decor())
	end
	local cy = 14.2
	local board = K.part(m, "Board", Vector3.new(14, 7.5, 0.9), CFrame.new(0, cy, 0), P.CrimsonDeep, { solid = true })
	for _, sx in { -1, 1 } do
		K.part(m, "BoardTip", Vector3.new(5.3, 5.3, 0.9), CFrame.new(sx * 7, cy, 0) * CFrame.Angles(0, 0, math.rad(45)),
			P.CrimsonDeep, { solid = true })
		gold(m, "TipTrim", Vector3.new(5.7, 5.7, 0.7), CFrame.new(sx * 7, cy, 0) * CFrame.Angles(0, 0, math.rad(45)))
	end
	gold(m, "BoardTrim", Vector3.new(14.2, 7.9, 0.7), CFrame.new(0, cy, 0))
	-- front: "WELCOME" in letter discs + title; back: a farewell
	local front = glowGui(board, Enum.NormalId.Front, 60, 1.5)
	local discs = K.new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(0.9, 0.2),
		Position = UDim2.fromScale(0.05, 0.06) }, front)
	K.new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center,
		Padding = UDim.new(0.012, 0) }, discs)
	for ch in ("WELCOME"):gmatch(".") do
		local d = K.new("Frame", { BackgroundColor3 = P.Cream, Size = UDim2.fromScale(1, 1),
			SizeConstraint = Enum.SizeConstraint.RelativeYY }, discs)
		K.new("UICorner", { CornerRadius = UDim.new(0.5, 0) }, d)
		K.new("UIStroke", { Color = P.Gold, Thickness = 3 }, d)
		K.guiText(d, ch, { color = P.Crimson, stroke = false, font = Enum.Font.LuckiestGuy,
			size = UDim2.fromScale(0.8, 0.8), position = UDim2.fromScale(0.1, 0.12) })
	end
	K.guiText(front, "CASINO MASTERS", { size = UDim2.fromScale(0.94, 0.42), position = UDim2.fromScale(0.03, 0.3),
		gradient = { P.GoldTop, P.Gold }, strokeThickness = 6 })
	K.guiText(front, "★ ON THE STRIP ★", { size = UDim2.fromScale(0.7, 0.17), position = UDim2.fromScale(0.15, 0.76),
		color = P.Cream, strokeThickness = 3 })
	local back = glowGui(board, Enum.NormalId.Back, 60, 1.5)
	K.guiText(back, "GOOD LUCK!", { size = UDim2.fromScale(0.6, 0.22), position = UDim2.fromScale(0.2, 0.08),
		color = P.Cream, strokeThickness = 4 })
	K.guiText(back, "COME BACK SOON", { size = UDim2.fromScale(0.94, 0.4), position = UDim2.fromScale(0.03, 0.33),
		gradient = { P.GoldTop, P.Gold }, strokeThickness = 6 })
	K.guiText(back, "★ CASINO MASTERS ★", { size = UDim2.fromScale(0.7, 0.17), position = UDim2.fromScale(0.15, 0.76),
		color = P.Cream, strokeThickness = 3 })
	-- the star on top
	local star = K.part(m, "Star", Vector3.new(4.4, 4.4, 0.1), CFrame.new(0, cy + 6.0, 0), P.White, { transparency = 1, shadow = false })
	for _, face in { Enum.NormalId.Front, Enum.NormalId.Back } do
		local g = glowGui(star, face, 60, 1.8)
		K.guiImage(g, Icons.star, { size = UDim2.fromScale(1, 1) })
	end
	gold(m, "StarPost", Vector3.new(0.4, 2.2, 0.4), CFrame.new(0, cy + 4.2, 0), decor())
	-- chasing bulbs along the board edges (both faces)
	for _, z in { -0.5, 0.5 } do
		K.bulbsAlong(bulbs, Vector3.new(-6.8, cy + 3.95, z), Vector3.new(6.8, cy + 3.95, z), 16, 0.3)
		K.bulbsAlong(bulbs, Vector3.new(-6.8, cy - 3.95, z), Vector3.new(6.8, cy - 3.95, z), 16, 0.3)
	end
	-- up-light so the sign reads from the plaza
	local lamp = K.part(m, "Uplight", Vector3.new(1, 0.4, 1), CFrame.new(0, 1.5, -4.5), C.Dark, decor())
	night(K.new("SpotLight", { Face = Enum.NormalId.Top, Angle = 60, Range = 26, Brightness = 2.2,
		Color = WP.Interior, Shadows = false }, lamp))
	return m
end

------------------------------------------------------------------
-- CASINO PYLON (tall marquee sign, readable along the street = ±X faces)
-- The two SurfaceGuis are named "OwnerSign"; Plots writes the casino name
-- into their "OwnerText" labels. Parts with a "ThemeSlot" take the casino
-- owner's colours (Buildings.applyTheme): the post = walls, brass = trim.
-- MapBuilder stands it 10 studs out from the casino front: the sign box is
-- 6 long (6.5 with its frame), so it clears the facade's cornice by 3.75
-- studs and overhangs the curb by 1.25 (18+ studs up, over the gutter).
------------------------------------------------------------------
function MapProps.pylon()
	local m = model("CasinoPylon")
	local bulbs = K.new("Folder", { Name = "Bulbs" }, m)
	local function slot(p: BasePart, name: string): BasePart
		p:SetAttribute("ThemeSlot", name)
		return p
	end
	-- 2.9 square: it stands wholly on the walk, clear of the curb
	granite(K.part(m, "Base", Vector3.new(2.9, 2, 2.9), CFrame.new(0, 1, 0), WP.Granite, { solid = true }))
	slot(gold(m, "BaseLip", Vector3.new(3.1, 0.2, 3.1), CFrame.new(0, 2.05, 0), decor()), "trim")
	local post = K.part(m, "Post", Vector3.new(1.6, 16, 1.6), CFrame.new(0, 10, 0), P.Crimson, { solid = true })
	Mats.apply(post, "Stucco")
	slot(post, "walls")
	slot(gold(m, "PostTrim", Vector3.new(1.8, 0.3, 1.8), CFrame.new(0, 17.6, 0), decor()), "trim")
	local cy, len = 21.5, 6
	local box = K.part(m, "SignBox", Vector3.new(1.4, 6.6, len), CFrame.new(0, cy, 0), P.CrimsonDeep, { solid = true })
	slot(gold(m, "SignFrame", Vector3.new(1.2, 7.1, len + 0.5), CFrame.new(0, cy, 0)), "trim")
	for _, face in { Enum.NormalId.Right, Enum.NormalId.Left } do
		local g = glowGui(box, face, 50, 1.6)
		g.Name = "OwnerSign"
		local plate = K.signPlate(g, P.CrimsonDeep)
		-- long names wrap onto a second line instead of shrinking
		local t = K.guiText(plate, "OPEN PLOT", { size = UDim2.fromScale(0.9, 0.54), position = UDim2.fromScale(0.05, 0.1),
			gradient = { P.GoldTop, P.Gold }, strokeThickness = 5 })
		t.TextWrapped = true
		t.Name = "OwnerText"
		K.guiText(plate, "★ ★  CASINO  ★ ★", { size = UDim2.fromScale(0.8, 0.18), position = UDim2.fromScale(0.1, 0.7),
			color = P.Cream, strokeThickness = 3 })
	end
	local zb = len / 2 - 0.1
	for _, x in { -0.78, 0.78 } do
		K.bulbsAlong(bulbs, Vector3.new(x, cy + 3.4, -zb), Vector3.new(x, cy + 3.4, zb), 8, 0.28)
		K.bulbsAlong(bulbs, Vector3.new(x, cy - 3.4, -zb), Vector3.new(x, cy - 3.4, zb), 8, 0.28)
	end
	-- crown on top, readable from both directions
	local crown = K.part(m, "Crown", Vector3.new(0.1, 4.2, 4.2), CFrame.new(0, cy + 5.6, 0), P.White, { transparency = 1, shadow = false })
	for _, face in { Enum.NormalId.Right, Enum.NormalId.Left } do
		local g = glowGui(crown, face, 50, 1.8)
		K.guiImage(g, Icons.crown, { size = UDim2.fromScale(1, 1) })
	end
	-- light the sidewalk under the sign
	local under = K.part(m, "Downlight", Vector3.new(1, 0.3, 1), CFrame.new(0, cy - 3.6, 0), C.Dark, decor())
	night(K.new("SpotLight", { Face = Enum.NormalId.Bottom, Angle = 80, Range = 26, Brightness = 2,
		Color = WP.Sodium, Shadows = false }, under))
	return m
end

------------------------------------------------------------------
-- ENTRANCE ARCH over the red carpet
------------------------------------------------------------------
function MapProps.entranceArch(width: number?)
	local w = width or 12
	local m = model("EntranceArch")
	local bulbs = K.new("Folder", { Name = "Bulbs" }, m)
	for _, sx in { -1, 1 } do
		granite(K.part(m, "PillarBase", Vector3.new(1.9, 1, 1.9), CFrame.new(sx * w / 2, 0.5, 0), WP.Granite, { solid = true }))
		gold(m, "Pillar", Vector3.new(1.3, 11, 1.3), CFrame.new(sx * w / 2, 6.5, 0))
		brass(K.ball(m, "PillarTop", 1.4, Vector3.new(sx * w / 2, 12.4, 0), WP.Brass, { shadow = false }))
	end
	local header = K.part(m, "Header", Vector3.new(w + 2.4, 2.6, 1.2), CFrame.new(0, 13.2, 0), P.CrimsonDeep, { solid = true })
	gold(m, "HeaderTrim", Vector3.new(w + 2.7, 2.9, 1.0), CFrame.new(0, 13.2, 0))
	for face, text in { [Enum.NormalId.Front] = "★ JACKPOTS INSIDE ★", [Enum.NormalId.Back] = "THANKS FOR PLAYING" } do
		local g = glowGui(header, face, 50, 1.5)
		K.guiText(g, text, { size = UDim2.fromScale(0.92, 0.66), position = UDim2.fromScale(0.04, 0.17),
			gradient = { P.GoldTop, P.Gold }, strokeThickness = 4 })
	end
	K.bulbsAlong(bulbs, Vector3.new(-w / 2 - 0.9, 11.75, -0.65), Vector3.new(w / 2 + 0.9, 11.75, -0.65), 13, 0.26)
	K.bulbsAlong(bulbs, Vector3.new(-w / 2 - 0.9, 14.65, -0.65), Vector3.new(w / 2 + 0.9, 14.65, -0.65), 13, 0.26)
	return m
end

------------------------------------------------------------------
-- VELVET ROPES along a line from z = 0 to z = -length (posts every ~3)
------------------------------------------------------------------
function MapProps.stanchions(length: number)
	local m = model("Stanchions")
	local n = math.max(2, math.floor(length / 3) + 1)
	local step = length / (n - 1)
	local prev
	for i = 0, n - 1 do
		local z = -i * step
		brass(K.cylY(m, "PostBase", 0.8, 0.12, Vector3.new(0, 0.06, z), WP.Brass, decor()))
		brass(K.cylY(m, "Post", 0.22, 2.6, Vector3.new(0, 1.3, z), WP.Brass, decor()))
		brass(K.ball(m, "Knob", 0.4, Vector3.new(0, 2.65, z), WP.Brass, decor()))
		local here = Vector3.new(0, 2.3, z)
		if prev then
			local mid = (prev + here) / 2 - Vector3.new(0, 0.35, 0)
			rod(m, "Rope", prev, mid, 0.2, P.Crimson, decor())
			rod(m, "Rope", mid, here, 0.2, P.Crimson, decor())
		end
		prev = here
	end
	return m
end

------------------------------------------------------------------
-- HOARDING: "expansion coming soon" construction fence (width along X)
------------------------------------------------------------------
function MapProps.hoarding(width: number)
	local m = model("Hoarding")
	local bulbs = K.new("Folder", { Name = "Bulbs" }, m)
	local wall = K.part(m, "Fence", Vector3.new(width, 9, 0.4), CFrame.new(0, 4.5, 0), WP.DarkMetal, { solid = true })
	for _, face in { Enum.NormalId.Front, Enum.NormalId.Back } do
		local g = K.surface(wall, face, 12, 0.6)
		local bg = K.new("Frame", { BackgroundColor3 = hex("#2A2236"), Size = UDim2.fromScale(1, 1), BorderSizePixel = 0 }, g)
		-- hazard bands (straight stripes: ClipsDescendants ignores rotated children)
		for _, y in { 0, 0.86 } do
			local band = K.new("Frame", { BackgroundColor3 = hex("#FFC21A"), BorderSizePixel = 0,
				Size = UDim2.fromScale(1, 0.14), Position = UDim2.fromScale(0, y) }, bg)
			for k = 0, math.floor(width / 2) do
				K.new("Frame", { BackgroundColor3 = P.Ink, BorderSizePixel = 0,
					Size = UDim2.new(0, 12, 1, 0), Position = UDim2.new(0, k * 24, 0, 0) }, band)
			end
		end
		K.guiImage(bg, Icons.build, { size = UDim2.fromScale(0.16, 0.62), position = UDim2.fromScale(0.16, 0.5) })
		K.guiText(bg, "THE SKY'S THE LIMIT", { size = UDim2.fromScale(0.6, 0.34), position = UDim2.fromScale(0.27, 0.22),
			gradient = { P.GoldTop, P.Gold }, strokeThickness = 4 })
		K.guiText(bg, "BUILD MORE FLOORS IN MY CASINO", { size = UDim2.fromScale(0.5, 0.16), position = UDim2.fromScale(0.32, 0.6),
			color = P.Cream, stroke = false, font = Enum.Font.GothamBlack })
		K.guiImage(bg, Icons.lock, { size = UDim2.fromScale(0.12, 0.5), position = UDim2.fromScale(0.88, 0.5) })
	end
	for x = -width / 2 + 2, width / 2 - 2, 10 do
		K.part(m, "FencePost", Vector3.new(0.5, 9.6, 0.6), CFrame.new(x, 4.8, 0.5), C.Dark, { material = Enum.Material.Metal })
	end
	-- cones and a blinking amber beacon on each end
	for _, sx in { -1, 1 } do
		local cx = sx * (width / 2 - 3)
		K.cylY(m, "Cone", 0.9, 1.4, Vector3.new(cx, 0.7, -1.4), hex("#FF7A1A"), decor())
		K.cylY(m, "ConeBand", 0.75, 0.25, Vector3.new(cx, 0.95, -1.4), P.White, decor())
		local beacon = K.ball(bulbs, "Beacon", 0.6, Vector3.new(sx * (width / 2 - 0.5), 9.4, 0), P.Amber,
			{ material = Enum.Material.Neon, shadow = false })
		beacon:SetAttribute("Phase", sx > 0 and 1 or 0)
	end
	return m
end

------------------------------------------------------------------
-- KIOSKS on the plaza (daily reward / VIP store). The Counter is the
-- PrimaryPart; MapBuilder puts the ProximityPrompt + tag on it.
------------------------------------------------------------------
function MapProps.kiosk(kind: string)
	local daily = kind == "daily"
	local m = model(daily and "DailyKiosk" or "StoreKiosk")
	local bulbs = K.new("Folder", { Name = "Bulbs" }, m)
	local col = daily and P.Crimson or hex("#8A4DE8")
	local h0 = K.plinth(m, 7.0, 4.6, daily and P.NeonPink or P.NeonBlue)
	local counter = K.part(m, "Counter", Vector3.new(6.4, 2.3, 2.0), CFrame.new(0, h0 + 1.15, -0.9), col, { solid = true })
	m.PrimaryPart = counter
	gold(m, "CounterTop", Vector3.new(6.7, 0.18, 2.3), CFrame.new(0, h0 + 2.39, -0.9), decor())
	local fp = K.part(m, "FrontPanel", Vector3.new(5.4, 1.4, 0.06), CFrame.new(0, h0 + 1.1, -1.93), col:Lerp(P.Ink, 0.3))
	local g = glowGui(fp, Enum.NormalId.Front, 80, 1.3)
	local plate = K.signPlate(g, col:Lerp(P.Ink, 0.25))
	K.guiText(plate, daily and "FREE GIFT EVERY DAY" or "VIP PASSES & CASH", { size = UDim2.fromScale(0.9, 0.56),
		position = UDim2.fromScale(0.05, 0.22), gradient = { P.GoldTop, P.Gold }, strokeThickness = 5 })
	K.part(m, "BackPanel", Vector3.new(6.4, 6.2, 0.4), CFrame.new(0, h0 + 3.1, 1.2), col:Lerp(P.Ink, 0.45), { solid = true })
	-- big 3D icon floating above the counter
	local iconBoard = K.part(m, "Icon", Vector3.new(3.2, 3.2, 0.1), CFrame.new(0, h0 + 4.4, 0.4), P.White,
		{ transparency = 1, shadow = false })
	for _, face in { Enum.NormalId.Front, Enum.NormalId.Back } do
		local ig = glowGui(iconBoard, face, 60, 1.3)
		K.guiImage(ig, daily and Icons.gift or Icons.crown, { size = UDim2.fromScale(1, 1) })
	end
	for _, sx in { -1, 1 } do
		brass(K.cylY(m, "Post", 0.2, 3.3, Vector3.new(sx * 3.05, h0 + 4.05, -1.75), WP.Brass, decor()))
	end
	K.canopy(m, 7.0, h0 + 6.2, 1.4, -2.2, 0.5, { col, P.White })
	K.boardSign(m, "Sign", Vector3.new(5.8, 1.35, 0.3), CFrame.new(0, h0 + 6.95, 1.2),
		daily and "DAILY REWARD" or "VIP STORE", { icon = daily and "gift" or "gem", bothSides = true })
	K.bulbsAlong(bulbs, Vector3.new(-3.3, h0 + 5.55, -2.3), Vector3.new(3.3, h0 + 5.55, -2.3), 10)
	local spot = K.part(m, "Downlight", Vector3.new(0.8, 0.2, 0.8), CFrame.new(0, h0 + 5.6, -1.2), C.Dark, decor())
	night(K.new("SpotLight", { Face = Enum.NormalId.Bottom, Angle = 110, Range = 16, Brightness = 1.6,
		Color = WP.Interior, Shadows = false }, spot))
	-- the shared Kit pieces come out in UI gold / ink: on the map the plinth is
	-- granite, its lip, the canopy trim and the sign board are brass, and the
	-- underglow is night-only neon
	for _, d in m:GetChildren() do
		if d:IsA("BasePart") then
			if d.Name == "Plinth" then
				granite(d)
			elseif d.Name == "PlinthLip" or d.Name == "CanopyTrim" or d.Name == "Sign" then
				brass(d)
			elseif d.Name == "Underglow" then
				nightNeon(d, daily and WP.Magenta or WP.Cyan)
			end
		end
	end
	return m
end

------------------------------------------------------------------
-- LEADERBOARD wall: "Board" part with a SurfaceGui (rows Row1..Row8 holding
-- Rank / Name / Value labels) that the server fills (Leaderboards.luau; the
-- caller tags the Board part and says which ranking it shows). The brass
-- frame's back carries a HALL OF FAME plate for whoever walks round it.
------------------------------------------------------------------
function MapProps.leaderboard(heading: string?, subtitle: string?)
	local m = model("Leaderboard")
	local bulbs = K.new("Folder", { Name = "Bulbs" }, m)
	local W, H, cy = 22, 13, 10.5
	for _, sx in { -1, 1 } do
		granite(K.part(m, "PostBase", Vector3.new(2.4, 1.2, 2.4), CFrame.new(sx * 8, 0.6, 0.6), WP.Granite, { solid = true }))
		gold(m, "Post", Vector3.new(1.2, 4.5, 1.2), CFrame.new(sx * 8, 3.4, 0.6))
	end
	local frame = gold(m, "Frame", Vector3.new(W + 0.8, H + 0.8, 1.0), CFrame.new(0, cy, 0.25))
	local back = K.signPlate(glowGui(frame, Enum.NormalId.Back, 20, 1.2), P.CrimsonDeep)
	K.guiImage(back, Icons.crown, { size = UDim2.fromScale(0.3, 0.42), position = UDim2.fromScale(0.5, 0.3) })
	K.guiText(back, "HALL OF FAME", { size = UDim2.fromScale(0.86, 0.26), position = UDim2.fromScale(0.07, 0.52),
		gradient = { P.GoldTop, P.Gold }, strokeThickness = 4 })
	K.guiText(back, "★ CASINO MASTERS ★", { size = UDim2.fromScale(0.6, 0.1), position = UDim2.fromScale(0.2, 0.8),
		color = P.Cream, strokeThickness = 2 })
	local board = K.part(m, "Board", Vector3.new(W, H, 1.2), CFrame.new(0, cy, 0), P.Ink, { solid = true })
	local g = glowGui(board, Enum.NormalId.Front, 30, 1.3)
	g.Name = "Board"
	local bg = K.new("Frame", { BackgroundColor3 = hex("#1A0A14"), Size = UDim2.fromScale(1, 1), BorderSizePixel = 0 }, g)
	K.new("UIGradient", { Rotation = 90, Color = ColorSequence.new(hex("#3A0C1E"), hex("#14060E")) }, bg)
	local title = K.new("Frame", { BackgroundColor3 = P.Crimson, BorderSizePixel = 0, Size = UDim2.fromScale(1, 0.19) }, bg)
	K.new("UIGradient", { Rotation = 90, Color = ColorSequence.new(hex("#E23A52"), hex("#8E0F22")) }, title)
	K.guiImage(title, Icons.crown, { size = UDim2.fromScale(0.12, 1.25), position = UDim2.fromScale(0.08, 0.5) })
	K.guiImage(title, Icons.crown, { size = UDim2.fromScale(0.12, 1.25), position = UDim2.fromScale(0.92, 0.5) })
	K.guiText(title, heading or "TOP CASINOS", { size = UDim2.fromScale(0.7, 0.8), position = UDim2.fromScale(0.15, 0.1),
		gradient = { P.GoldTop, P.Gold }, strokeThickness = 4 }).Name = "Title"
	K.guiText(bg, subtitle or "THIS SERVER  •  TOTAL EARNED", { size = UDim2.fromScale(0.8, 0.07),
		position = UDim2.fromScale(0.1, 0.205), color = P.Cream, stroke = false, font = Enum.Font.GothamBlack }).Name = "Subtitle"
	for i = 1, 8 do
		local row = K.new("Frame", { Name = "Row" .. i, BorderSizePixel = 0,
			BackgroundColor3 = (i % 2 == 0) and hex("#2A0E1C") or hex("#200A16"),
			Size = UDim2.fromScale(0.94, 0.075), Position = UDim2.fromScale(0.03, 0.29 + (i - 1) * 0.086) }, bg)
		K.new("UICorner", { CornerRadius = UDim.new(0.3, 0) }, row)
		local rank = K.guiText(row, "#" .. i, { size = UDim2.fromScale(0.1, 0.9), position = UDim2.fromScale(0.01, 0.05),
			color = (i == 1 and P.Gold) or (i == 2 and P.Chrome) or (i == 3 and hex("#E0965A")) or P.Cream, strokeThickness = 2 })
		rank.Name = "Rank"
		local name = K.guiText(row, "—", { size = UDim2.fromScale(0.56, 0.8), position = UDim2.fromScale(0.13, 0.1),
			color = P.White, stroke = false, font = Enum.Font.GothamBlack })
		name.Name = "PlayerName"
		name.TextXAlignment = Enum.TextXAlignment.Left
		local value = K.guiText(row, "", { size = UDim2.fromScale(0.28, 0.8), position = UDim2.fromScale(0.7, 0.1),
			color = P.GoldTop, stroke = false, font = Enum.Font.GothamBlack })
		value.Name = "Value"
		value.TextXAlignment = Enum.TextXAlignment.Right
	end
	K.bulbFrame(bulbs, 0, cy, W + 1.0, H + 1.0, -0.35, 20)
	local spot = K.part(m, "Floodlight", Vector3.new(1, 0.4, 1), CFrame.new(0, 1.2, -6), C.Dark, decor())
	night(K.new("SpotLight", { Face = Enum.NormalId.Top, Angle = 70, Range = 22, Brightness = 1.2,
		Color = WP.Interior, Shadows = false }, spot))
	return m
end

------------------------------------------------------------------
-- RESORT TOWER (backdrop): stone podium + window shaft + setbacks + crown
-- sign. The shaft swaps MaterialVariant with the lamps (NightLight): by day
-- "<variant>Day" (stone mullions, dark glass), after dark "<variant>" whose
-- emissive mask lights the windows without any lights. MapBuilder creates both.
-- spec = { w, d, h, variant = "CM_TowerWarm", tint, crown, name, tiers }
-- The podium is (w + 14) x 14 x (d + 14); MapBuilder's zoning relies on it.
------------------------------------------------------------------
function MapProps.tower(spec)
	local m = model("Tower_" .. (spec.name or "X"))

	local w, d, h = spec.w, spec.d, spec.h
	local podium = K.part(m, "Podium", Vector3.new(w + 14, 14, d + 14), CFrame.new(0, 7, 0), WP.Stone, { solid = true, shadow = false })
	Mats.paint(podium, "Ashlar", WP.Stone)
	-- the lobby: a dark storefront band all round, a hair proud of the stone
	K.part(m, "Storefront", Vector3.new(w + 14.2, 4, d + 14.2), CFrame.new(0, 2.8, 0), WP.GlassSmoke:Lerp(WP.Ink, 0.5),
		{ shadow = false, reflectance = 0.12 })
	for _, s in { { 0, -(d + 14) / 2 }, { 0, (d + 14) / 2 } } do
		nightNeon(K.neon(m, "PodiumBand", Vector3.new(w + 14.2, 0.5, 0.2), CFrame.new(s[1], 12.5, s[2]), spec.crown), spec.crown)
	end
	for _, s in { -(w + 14) / 2, (w + 14) / 2 } do
		nightNeon(K.neon(m, "PodiumBand", Vector3.new(0.2, 0.5, d + 14.2), CFrame.new(s, 12.5, 0), spec.crown), spec.crown)
	end
	local y = 14
	local tiers = spec.tiers or { { 1, h } }
	local tw, td = w, d
	local variant = spec.variant or "CM_TowerWarm"
	for i, tier in tiers do
		local sx, th = tier[1], tier[2]
		tw, td = w * sx, d * sx
		local shaft = K.part(m, "Shaft" .. i, Vector3.new(tw, th, td), CFrame.new(0, y + th / 2, 0), spec.tint or P.White, { shadow = false })
		shaft.Material = Enum.Material.Plastic
		shaft.MaterialVariant = variant .. "Day" -- built in its day state
		shaft:SetAttribute("DayMaterial", "Plastic")
		shaft:SetAttribute("NightMaterial", "Plastic")
		shaft:SetAttribute("DayVariant", variant .. "Day")
		shaft:SetAttribute("NightVariant", variant)
		night(shaft)
		y += th
		-- slim neon ledge at each setback
		nightNeon(K.neon(m, "Ledge", Vector3.new(tw + 0.6, 0.35, td + 0.6), CFrame.new(0, y + 0.1, 0), spec.crown), spec.crown)
	end
	-- crown: cap, neon edges, name sign on the city-facing (front) face
	local cap = K.part(m, "Cap", Vector3.new(tw * 0.92, 8, td * 0.92), CFrame.new(0, y + 4, 0), WP.DeepStone, { shadow = false })
	Mats.paint(cap, "Ashlar", WP.DeepStone)
	for _, s in { -1, 1 } do
		nightNeon(K.neon(m, "CrownEdge", Vector3.new(0.4, 8, 0.4), CFrame.new(s * tw * 0.46, y + 4, -td * 0.46), spec.crown), spec.crown)
		nightNeon(K.neon(m, "CrownEdge", Vector3.new(0.4, 8, 0.4), CFrame.new(s * tw * 0.46, y + 4, td * 0.46), spec.crown), spec.crown)
	end
	if spec.name then
		local g = glowGui(cap, Enum.NormalId.Front, 10, 2.2)
		K.guiText(g, spec.name, { size = UDim2.fromScale(0.92, 0.8), position = UDim2.fromScale(0.04, 0.1),
			color = spec.crown:Lerp(P.White, 0.45), strokeColor = spec.crown:Lerp(WP.Ink, 0.4), strokeThickness = 3 })
	end
	K.cylY(m, "Spire", 0.8, 14, Vector3.new(0, y + 15, 0), C.Dark, { shadow = false })
	K.ball(m, "AirLight", 1.4, Vector3.new(0, y + 22.5, 0), WP.Ruby, { material = Enum.Material.Neon, shadow = false })
	return m
end

------------------------------------------------------------------
-- OBSERVATION WHEEL: rotor parts live in a "Rotor" folder that the client
-- (MapFX) turns around the hub. Wheel plane = XY, axle along Z.
------------------------------------------------------------------
function MapProps.wheel()
	local m = model("ObservationWheel")
	local rotor = K.new("Folder", { Name = "Rotor" }, m)
	local R, hubY = 52, 62
	local hub = Vector3.new(0, hubY, 0)
	m:SetAttribute("HubHeight", hubY)
	-- station + A-frame legs
	granite(K.part(m, "Platform", Vector3.new(44, 3, 26), CFrame.new(0, 1.5, 0), WP.Granite, { solid = true }))
	nightNeon(K.neon(m, "PlatformGlow", Vector3.new(44.2, 0.4, 0.2), CFrame.new(0, 2.6, -13.05), WP.Magenta), WP.Magenta)
	for _, z in { -7.5, 7.5 } do
		for _, x in { -20, 20 } do
			rod(m, "Leg", Vector3.new(x, 3, z), Vector3.new(0, hubY, z * 0.55), 2.4, P.Chrome,
				{ material = Enum.Material.Metal, shadow = false })
		end
	end
	K.cylZ(m, "Axle", 4.2, 12, hub, P.Chrome, { material = Enum.Material.Metal, shadow = false })
	K.cylZ(rotor, "Hub", 7, 4, hub, C.Dark, { material = Enum.Material.Metal, shadow = false })
	local n = 48
	for k = 0, n - 1 do
		local a0, a1 = k * 2 * math.pi / n, (k + 1) * 2 * math.pi / n
		local p0 = hub + Vector3.new(math.cos(a0) * R, math.sin(a0) * R, 0)
		local p1 = hub + Vector3.new(math.cos(a1) * R, math.sin(a1) * R, 0)
		local hue = (k % 2 == 0) and WP.Magenta or WP.Cyan
		local rim = beamPart(rotor, "Rim", p0, p1, 1.3, 1.3, hue, { material = Enum.Material.Neon, shadow = false })
		rim.Size += Vector3.new(0, 0, 0.3)
		nightNeon(rim, hue)
		local q0 = hub + Vector3.new(math.cos(a0) * (R - 5), math.sin(a0) * (R - 5), 0)
		local q1 = hub + Vector3.new(math.cos(a1) * (R - 5), math.sin(a1) * (R - 5), 0)
		beamPart(rotor, "InnerRim", q0, q1, 0.8, 0.8, P.Chrome, { material = Enum.Material.Metal, shadow = false })
	end
	for k = 0, 23 do
		local a = k * 2 * math.pi / 24
		rod(rotor, "Spoke", hub, hub + Vector3.new(math.cos(a) * (R - 5), math.sin(a) * (R - 5), 0), 0.35, P.Chrome,
			{ material = Enum.Material.Metal, shadow = false })
	end
	for k = 0, 27 do
		local a = k * 2 * math.pi / 28 + 0.05
		K.ball(rotor, "Cabin", 5.4, hub + Vector3.new(math.cos(a) * (R + 3.4), math.sin(a) * (R + 3.4), 0),
			hex("#CFEFFF"), { reflectance = 0.3, shadow = false })
	end
	return m
end

------------------------------------------------------------------
-- LED SPHERE: a dark glossy orb wrapped in glowing latitude/longitude
-- bands (thin discs a hair wider than the orb, so only their rims show).
-- MapFX cycles the band colours in a wave.
------------------------------------------------------------------
function MapProps.sphere(diameter: number?)
	local d = diameter or 80
	local r = d / 2
	local m = model("LEDSphere")
	granite(K.cylY(m, "Base", d * 0.75, 5, Vector3.new(0, 2.5, 0), WP.Granite, { solid = true, shadow = false }))
	brass(K.cylY(m, "BaseLip", d * 0.75 + 1, 0.4, Vector3.new(0, 5.1, 0), WP.Brass, decor()))
	local cy = 5 + r - d * 0.08
	local centre = Vector3.new(0, cy, 0)
	K.ball(m, "Orb", d, centre, WP.Ink, { reflectance = 0.18, shadow = false })
	-- band colours are cycled by MapFX (SPHERE_COLORS); this is the start hue
	local bands = K.new("Folder", { Name = "Bands" }, m)
	for k = -4, 4 do
		local y = k * r * 0.2
		local cross = math.sqrt(r * r - y * y)
		local band = K.cylY(bands, "Band", (cross + 0.45) * 2, 0.8, centre + Vector3.new(0, y, 0), WP.Magenta,
			{ material = Enum.Material.Neon, shadow = false })
		band:SetAttribute("Wave", (k + 4) / 8)
	end
	for k = 0, 5 do
		local band = K.part(bands, "Band", Vector3.new(0.8, d + 0.9, d + 0.9),
			CFrame.new(centre) * CFrame.Angles(0, k * math.pi / 6, 0), WP.Magenta,
			{ material = Enum.Material.Neon, shadow = false, shape = Enum.PartType.Cylinder })
		band:SetAttribute("Wave", k / 6)
	end
	return m
end

------------------------------------------------------------------
-- SEARCHLIGHT: drum + lamp + a Beam to a sky attachment the client sweeps
------------------------------------------------------------------
function MapProps.searchlight()
	local m = model("Searchlight")
	K.cylY(m, "Drum", 4, 2.2, Vector3.new(0, 1.1, 0), C.Dark, { solid = true, material = Enum.Material.Metal })
	brass(K.cylY(m, "DrumBand", 4.2, 0.3, Vector3.new(0, 2.3, 0), WP.Brass, decor()))
	K.cylY(m, "Lamp", 3, 3.4, Vector3.new(0, 4.1, 0), P.Chrome, { material = Enum.Material.Metal, shadow = false })
	K.cylY(m, "Lens", 2.6, 0.12, Vector3.new(0, 5.85, 0), hex("#E8F2FF"), { material = Enum.Material.Neon, shadow = false })
	-- the beam hangs off an unrotated helper so attachment offsets are world-aligned
	local emitter = K.part(m, "Emitter", Vector3.new(0.4, 0.4, 0.4), CFrame.new(0, 5.95, 0), P.White,
		{ transparency = 1, shadow = false })
	local a0 = K.new("Attachment", { Name = "BeamFrom" }, emitter)
	local a1 = K.new("Attachment", { Name = "BeamTo", Position = Vector3.new(0, 700, 0) }, emitter)
	local beam = K.new("Beam", {
		Name = "Shaft", Attachment0 = a0, Attachment1 = a1, Width0 = 2, Width1 = 22, FaceCamera = true,
		LightEmission = 1, LightInfluence = 0, Segments = 1, Texture = "",
		Color = ColorSequence.new(Color3.fromRGB(220, 232, 255)),
		Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.72), NumberSequenceKeypoint.new(0.45, 0.92),
			NumberSequenceKeypoint.new(1, 1) }),
	}, emitter)
	pcall(function() beam.Brightness = 1.2 end)
	night(beam)
	return m
end

------------------------------------------------------------------
-- FOUNTAIN JET: nozzle + glowing water column (MapFX animates its height)
------------------------------------------------------------------
local JET_DAY = Color3.fromRGB(236, 246, 250)
local JET_NIGHT = Color3.fromRGB(108, 200, 240)
function MapProps.fountainJet(height: number?)
	local h = height or 12
	local m = model("FountainJet")
	K.cylY(m, "Nozzle", 0.9, 0.4, Vector3.new(0, 0.2, 0), P.Chrome, { material = Enum.Material.Metal, shadow = false })
	-- water by day (pale, see-through), a glowing column after dark
	local jet = K.cylY(m, "Jet", 0.75, h, Vector3.new(0, 0.4 + h / 2, 0), JET_NIGHT,
		{ material = Enum.Material.Neon, transparency = 0.45, shadow = false })
	nightNeon(jet, JET_NIGHT, JET_DAY, 0.6, 0.45) -- by day: see-through spray, not a white post
	jet:SetAttribute("BaseHeight", h)
	nightNeon(K.cylY(m, "Ring", 1.6, 0.08, Vector3.new(0, 0.05, 0), WP.Cyan, { material = Enum.Material.Neon, shadow = false }), WP.Cyan)
	-- spray at the top of the column (MapFX keeps the attachment on the tip;
	-- the jet's local +X points up, so the attachment is turned to match)
	local tip = K.new("Attachment", { Name = "Tip", CFrame = CFrame.new(h / 2, 0, 0) * CFrame.Angles(0, 0, -math.pi / 2) }, jet)
	K.new("ParticleEmitter", {
		Name = "Spray", Texture = "rbxasset://textures/particles/smoke_main.dds",
		Color = ColorSequence.new(Color3.fromRGB(205, 238, 255)), LightEmission = 0.5,
		Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.5), NumberSequenceKeypoint.new(1, 1.8) }),
		Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.45), NumberSequenceKeypoint.new(1, 1) }),
		Lifetime = NumberRange.new(0.6, 1.0), Rate = 22, Speed = NumberRange.new(5, 9), SpreadAngle = Vector2.new(25, 25),
		Acceleration = Vector3.new(0, -28, 0), EmissionDirection = Enum.NormalId.Top, Rotation = NumberRange.new(0, 360),
	}, tip)
	return m
end

------------------------------------------------------------------
-- JACKPOT SCULPTURE (the plaza fountain's centrepiece, seen down all four
-- boulevards): a leaning stack of giant casino chips on a granite drum, a
-- die on top and a second die balanced on its corner on that one (~27 tall).
-- Model space: the basin floor at y = 0.
------------------------------------------------------------------
-- a die: an ivory cube with pips drawn on every face (opposite faces add to 7)
local PIPS = {
	[1] = { { 0.5, 0.5 } },
	[2] = { { 0.27, 0.27 }, { 0.73, 0.73 } },
	[3] = { { 0.25, 0.25 }, { 0.5, 0.5 }, { 0.75, 0.75 } },
	[4] = { { 0.27, 0.27 }, { 0.73, 0.27 }, { 0.27, 0.73 }, { 0.73, 0.73 } },
	[5] = { { 0.25, 0.25 }, { 0.75, 0.25 }, { 0.5, 0.5 }, { 0.25, 0.75 }, { 0.75, 0.75 } },
	[6] = { { 0.27, 0.22 }, { 0.73, 0.22 }, { 0.27, 0.5 }, { 0.73, 0.5 }, { 0.27, 0.78 }, { 0.73, 0.78 } },
}
local DIE_FACES = { Top = 1, Bottom = 6, Front = 2, Back = 5, Right = 3, Left = 4 }
local function die(parent, size: number, cf: CFrame)
	local d = K.part(parent, "Die", Vector3.new(size, size, size), cf, WP.Ivory, { solid = true, reflectance = 0.06 })
	for face, value in DIE_FACES do
		local g = K.surface(d, Enum.NormalId[face], 40, 0.4)
		for _, xy in PIPS[value] do
			local pip = K.new("Frame", {
				BackgroundColor3 = value == 1 and WP.Lacquer or WP.Ink, AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(xy[1], xy[2]), Size = UDim2.fromScale(0.18, 0.18), BorderSizePixel = 0,
			}, g)
			K.new("UICorner", { CornerRadius = UDim.new(0.5, 0) }, pip)
		end
	end
	return d
end

function MapProps.jackpotSculpture()
	local m = model("JackpotSculpture")
	granite(K.cylY(m, "Pedestal", 10, 4.4, Vector3.new(0, 2.2, 0), WP.Granite, { solid = true, shadow = false }))
	brass(K.cylY(m, "PedestalCap", 10.6, 0.3, Vector3.new(0, 4.55, 0), WP.Brass, { solid = true }))
	-- six chips, each nudged off the one below; six edge inserts round every chip
	local R, T = 4.5, 1.5
	local y = 4.7
	local chips = {
		{ WP.Lacquer, 0, 0 }, { WP.Ink, 0.45, 0.2 }, { WP.Ivory, 0.15, 0.55 },
		{ WP.Lacquer, -0.35, 0.3 }, { WP.Ink, -0.2, -0.25 }, { WP.Ivory, 0.25, -0.1 },
	}
	for i, c in chips do
		local centre = Vector3.new(c[2], y + T / 2, c[3])
		K.cylY(m, "Chip", R * 2, T, centre, c[1], { solid = true, reflectance = 0.06 })
		local insert = (c[1] == WP.Ivory) and WP.Lacquer or WP.Ivory
		for k = 0, 5 do
			local a = k * math.pi / 3 + i * 0.4
			local d = Vector3.new(math.cos(a), 0, math.sin(a))
			K.part(m, "ChipEdge", Vector3.new(1.3, T - 0.2, 0.2), CFrame.lookAt(centre + d * (R - 0.05), centre + d * (R + 1)),
				insert, { shadow = false })
		end
		y += T
	end
	-- the dice: one flat on the stack, one balanced on its corner on top of it
	local s = 5
	die(m, s, CFrame.new(0.2, y + s / 2, 0) * CFrame.Angles(0, math.rad(20), 0))
	die(m, s, CFrame.new(0.2, y + s + s * math.sqrt(3) / 2, 0) * CFrame.Angles(0, math.rad(35), 0)
		* CFrame.Angles(math.atan(1 / math.sqrt(2)), 0, math.rad(45)))
	return m
end

------------------------------------------------------------------
-- FOOD CART (plaza decor): a little wagon with a round umbrella and a sign
-- on its front (-Z). kind = "hotdog" | "popcorn"
------------------------------------------------------------------
function MapProps.foodCart(kind: string?)
	local popcorn = kind == "popcorn"
	local m = model(popcorn and "PopcornCart" or "HotDogCart")
	local body = popcorn and P.Crimson or hex("#E8A33A")
	local canopyColor = popcorn and P.Cream or P.Crimson
	K.part(m, "Cart", Vector3.new(5.2, 2.2, 2.6), CFrame.new(0, 2.2, 0), body, { solid = true, reflectance = 0.08 })
	gold(m, "CartTop", Vector3.new(5.5, 0.2, 2.9), CFrame.new(0, 3.4, 0), decor())
	K.part(m, "Skirt", Vector3.new(4.9, 0.4, 2.3), CFrame.new(0, 0.9, 0), C.Dark, decor())
	for _, sz in { -1, 1 } do
		K.cylZ(m, "Wheel", 2.0, 0.3, Vector3.new(1.4, 1.0, sz * 1.5), C.Dark, decor())
		brass(K.cylY(m, "Leg", 0.25, 1.1, Vector3.new(-2.2, 0.55, sz * 1.0), WP.Brass, decor()))
	end
	K.cylY(m, "Pole", 0.22, 5.2, Vector3.new(0.6, 6.0, 0), C.Dark, decor())
	K.cylY(m, "Umbrella", 6.4, 0.3, Vector3.new(0.6, 8.6, 0), canopyColor, decor())
	K.cylY(m, "UmbrellaTop", 2.6, 0.3, Vector3.new(0.6, 8.9, 0), body, decor())
	brass(K.ball(m, "Finial", 0.5, Vector3.new(0.6, 9.2, 0), WP.Brass, decor()))
	K.boardSign(m, "Sign", Vector3.new(4.4, 1.1, 0.2), CFrame.new(0, 2.3, -1.42), popcorn and "POPCORN" or "HOT DOGS",
		{ icon = popcorn and "popcorn" or "coin", ppu = 80 })
	if popcorn then
		K.part(m, "Popcorn", Vector3.new(1.9, 0.7, 1.7), CFrame.new(-1.1, 3.85, 0), hex("#FFE7A3"), decor())
		K.part(m, "Cabinet", Vector3.new(2.1, 1.8, 1.9), CFrame.new(-1.1, 4.4, 0), WP.GlassClear,
			{ transparency = 0.7, reflectance = 0.1, shadow = false })
	else
		K.cylY(m, "Ketchup", 0.4, 0.9, Vector3.new(-1.6, 3.95, 0.4), P.Crimson, decor())
		K.cylY(m, "Mustard", 0.4, 0.9, Vector3.new(-1.0, 3.95, 0.4), hex("#F2C12E"), decor())
	end
	for _, d in m:GetChildren() do
		if d:IsA("BasePart") and d.Name == "Sign" then brass(d) end
	end
	return m
end

------------------------------------------------------------------
-- GATE SIGN over a tunnel portal: a crimson plate in a brass frame, chase
-- bulbs along its top and bottom. Model space: the board's bottom at y = 0,
-- its face toward -Z, the frame's back at z = 0.6.
------------------------------------------------------------------
function MapProps.gateSign(heading: string, subtitle: string?)
	local m = model("GateSign")
	local bulbs = K.new("Folder", { Name = "Bulbs" }, m)
	local W, H = 30, 6
	gold(m, "Frame", Vector3.new(W + 0.8, H + 0.8, 0.8), CFrame.new(0, H / 2, 0.2))
	local board = K.part(m, "Board", Vector3.new(W, H, 0.6), CFrame.new(0, H / 2, -0.1), P.CrimsonDeep, { solid = true })
	local plate = K.signPlate(glowGui(board, Enum.NormalId.Front, 20, 1.5), P.CrimsonDeep)
	K.guiText(plate, heading, { size = UDim2.fromScale(0.9, subtitle and 0.56 or 0.76), position = UDim2.fromScale(0.05, 0.1),
		gradient = { P.GoldTop, P.Gold }, strokeThickness = 5 })
	if subtitle then
		K.guiText(plate, subtitle, { size = UDim2.fromScale(0.7, 0.2), position = UDim2.fromScale(0.15, 0.7),
			color = P.Cream, strokeThickness = 3 })
	end
	for _, y in { H + 0.15, -0.15 } do
		K.bulbsAlong(bulbs, Vector3.new(-W / 2, y, -0.45), Vector3.new(W / 2, y, -0.45), 24, 0.4)
	end
	return m
end

------------------------------------------------------------------
-- small street furniture
------------------------------------------------------------------
function MapProps.bench()
	local m = model("Bench")
	K.part(m, "Seat", Vector3.new(6, 0.35, 1.8), CFrame.new(0, 1.7, 0), P.Wood, { solid = true, material = Enum.Material.Wood })
	K.part(m, "Back", Vector3.new(6, 1.6, 0.3), CFrame.new(0, 2.9, 0.85) * CFrame.Angles(math.rad(-10), 0, 0), P.Wood,
		{ material = Enum.Material.Wood })
	for _, sx in { -2.6, 2.6 } do
		K.part(m, "Leg", Vector3.new(0.35, 1.6, 1.8), CFrame.new(sx, 0.8, 0), C.Dark, { material = Enum.Material.Metal })
	end
	return m
end

-- granite box (boxH tall, default 1.6) with a brass lip and a hedge
-- (hedgeH tall, default 1.4) on top
function MapProps.planter(w: number, d: number, boxH: number?, hedgeH: number?)
	local bh, hh = boxH or 1.6, hedgeH or 1.4
	local m = model("Planter")
	granite(K.part(m, "Box", Vector3.new(w, bh, d), CFrame.new(0, bh / 2, 0), WP.Granite, { solid = true }))
	gold(m, "Lip", Vector3.new(w + 0.2, 0.2, d + 0.2), CFrame.new(0, bh + 0.05, 0), decor())
	-- the Hedge material has its leaf colours baked in: untinted (until its
	-- maps are uploaded, plain Grass tinted lawn green instead of white)
	local hedge = K.part(m, "Hedge", Vector3.new(w - 0.4, hh, d - 0.4), CFrame.new(0, bh + hh / 2, 0), WP.Lawn, decor())
	local baked = (Mats.Defs.Hedge or {}).color
	Mats.paint(hedge, "Hedge", (baked == nil or baked == "") and WP.Lawn or nil)
	return m
end

function MapProps.trashBin()
	local m = model("TrashBin")
	K.cylY(m, "Bin", 1.4, 2.4, Vector3.new(0, 1.2, 0), C.Dark, { solid = true, material = Enum.Material.Metal })
	brass(K.cylY(m, "Lid", 1.6, 0.3, Vector3.new(0, 2.5, 0), WP.Brass, decor()))
	return m
end

-- string lights hanging between two points into a Bulbs folder (catenary).
-- The wire goes next to the folder (MachineFX recolours everything in it)
function MapProps.stringLights(folder: Instance, a: Vector3, b: Vector3, sag: number, count: number)
	local prev
	for i = 0, count - 1 do
		local t = i / (count - 1)
		local p = a:Lerp(b, t) - Vector3.new(0, sag * 4 * t * (1 - t), 0)
		local bulb = K.ball(folder, "Bulb", 0.42, p, (i % 2 == 0) and P.GoldTop or hex("#FFD2E8"),
			{ material = Enum.Material.Neon, shadow = false })
		bulb:SetAttribute("Phase", i % 2)
		if prev then rod(folder.Parent or folder, "Wire", prev, p, 0.08, C.Dark, decor()) end
		prev = p
	end
end

return MapProps
