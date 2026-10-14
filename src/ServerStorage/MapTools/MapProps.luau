--!nonstrict
-- MapProps.luau — the prop kit for the "Vegas Strip" map (Edit-time tool, see
-- MapBuilder). Every builder works in model space like MachineModels: ground at
-- y = 0, centred on x/z, FRONT = -Z, and returns a Model whose pivot is that
-- ground origin. Styling reuses MachineModels.Kit so the street furniture,
-- signs and casinos share one "Showtime" look (ink + gold + neon bulbs).

local MapProps = {}

local K, P, hex
local Icons

-- MapBuilder hands in a fresh MachineModels (and UIAssets) before building
function MapProps.init(machineModels, uiAssets)
	K = machineModels.Kit
	P = machineModels.Palette
	hex = K.hex
	Icons = uiAssets.Icons
end

local C = {}
local function palette()
	C.Dark = hex("#2A2633")       -- lamp posts, trims
	C.Asphalt = hex("#1F1D26")
	C.Walk = hex("#6C6577")
	C.Trunk = hex("#7A5A3E")
	C.TrunkDark = hex("#62472F")
	C.Frond = hex("#2F8F3E")
	C.FrondTip = hex("#3FAE4C")
	C.Facade = hex("#2B2540")
	C.WarmLight = Color3.fromRGB(255, 196, 140)
end

-- fresh opts per call: the kit's cylinder/ball helpers write .shape into opts
local function decor() return { shadow = false } end

local function model(name)
	if not C.Dark then palette() end
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
-- PALM TREE (curved tapered trunk, 8 fronds, gold-rim planter)
------------------------------------------------------------------
function MapProps.palm(seed: number?, height: number?)
	local rng = Random.new(seed or 1)
	local h = height or rng:NextNumber(20, 27)
	local m = model("Palm")
	K.cylY(m, "Planter", 3.6, 1.0, Vector3.new(0, 0.5, 0), P.Ink, { solid = true })
	K.cylY(m, "PlanterCap", 3.9, 0.2, Vector3.new(0, 1.05, 0), P.Gold, { reflectance = 0.1 })
	K.cylY(m, "Soil", 3.3, 0.1, Vector3.new(0, 1.12, 0), hex("#2B1E16"), decor())

	local yaw = rng:NextNumber(0, math.pi * 2)
	local dir = Vector3.new(math.cos(yaw), 0, math.sin(yaw))
	local lean = rng:NextNumber(0.05, 0.13)
	local function at(t) return Vector3.new(0, 1.1 + t * h, 0) + dir * (lean * h * t * t) end
	local segs = 7
	for i = 1, segs do
		local a, b = at((i - 1) / segs), at(i / segs)
		local d = 1.45 - (i - 1) * 0.08
		rod(m, "Trunk", a - (b - a).Unit * 0.12, b + (b - a).Unit * 0.12, d, (i % 2 == 0) and C.Trunk or C.TrunkDark,
			{ material = Enum.Material.Wood, solid = i <= 2 })
	end

	local top = at(1)
	K.ball(m, "Heart", 1.5, top, hex("#3A6E2A"), decor())
	for k = 0, 7 do
		local ang = k * math.pi / 4 + rng:NextNumber(-0.18, 0.18)
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
	for k = 0, 2 do
		local a = k * 2.1
		K.ball(m, "Coconut", 0.85, top + Vector3.new(math.cos(a) * 0.7, -0.9, math.sin(a) * 0.7), hex("#5A3B22"), decor())
	end
	return m
end

------------------------------------------------------------------
-- STREET LAMP (single arm toward +X, or double); real light = SpotLight down
------------------------------------------------------------------
function MapProps.lamp(double: boolean?)
	local m = model(double and "DoubleLamp" or "StreetLamp")
	K.cylY(m, "Base", 1.3, 1.2, Vector3.new(0, 0.6, 0), C.Dark, { solid = true, material = Enum.Material.Metal })
	K.cylY(m, "Band", 0.95, 0.3, Vector3.new(0, 1.35, 0), P.Gold, { reflectance = 0.15 })
	K.cylY(m, "Pole", 0.5, 14.6, Vector3.new(0, 1.2 + 7.3, 0), C.Dark, { solid = true, material = Enum.Material.Metal })
	K.ball(m, "Finial", 0.65, Vector3.new(0, 16.2, 0), P.Gold, { reflectance = 0.2, shadow = false })
	for _, s in (double and { -1, 1 } or { 1 }) do
		K.part(m, "Arm", Vector3.new(3.6, 0.25, 0.25), CFrame.new(s * 1.8, 15.3, 0), C.Dark, { material = Enum.Material.Metal })
		K.part(m, "Head", Vector3.new(1.7, 0.5, 1.0), CFrame.new(s * 3.45, 15.0, 0), C.Dark, { material = Enum.Material.Metal })
		local lens = K.neon(m, "Lens", Vector3.new(1.35, 0.12, 0.8), CFrame.new(s * 3.45, 14.7, 0), hex("#FFE2B0"))
		K.new("SpotLight", {
			Face = Enum.NormalId.Bottom, Angle = 95, Range = 46, Brightness = 3.4,
			Color = C.WarmLight, Shadows = false,
		}, lens)
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
	K.part(m, "Base", Vector3.new(20, 1.2, 6), CFrame.new(0, 0.6, 0), P.Ink, { solid = true })
	K.gold(m, "BaseLip", Vector3.new(20.3, 0.2, 6.3), CFrame.new(0, 1.25, 0))
	K.neon(m, "BaseGlow", Vector3.new(19.6, 0.12, 0.08), CFrame.new(0, 0.3, -3.05), P.NeonPink)
	K.neon(m, "BaseGlowBack", Vector3.new(19.6, 0.12, 0.08), CFrame.new(0, 0.3, 3.05), P.NeonPink)
	for _, sx in { -1, 1 } do
		K.part(m, "Post", Vector3.new(1.3, 9.4, 1.3), CFrame.new(sx * 5, 6.0, 0), P.Cream, { solid = true })
		K.gold(m, "PostBand", Vector3.new(1.5, 0.3, 1.5), CFrame.new(sx * 5, 2.2, 0))
	end
	local cy = 14.2
	local board = K.part(m, "Board", Vector3.new(14, 7.5, 0.9), CFrame.new(0, cy, 0), P.CrimsonDeep, { solid = true })
	for _, sx in { -1, 1 } do
		K.part(m, "BoardTip", Vector3.new(5.3, 5.3, 0.9), CFrame.new(sx * 7, cy, 0) * CFrame.Angles(0, 0, math.rad(45)),
			P.CrimsonDeep, { solid = true })
		K.part(m, "TipTrim", Vector3.new(5.7, 5.7, 0.7), CFrame.new(sx * 7, cy, 0) * CFrame.Angles(0, 0, math.rad(45)),
			P.Gold, { reflectance = 0.12 })
	end
	K.gold(m, "BoardTrim", Vector3.new(14.2, 7.9, 0.7), CFrame.new(0, cy, 0))
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
	K.gold(m, "StarPost", Vector3.new(0.4, 2.2, 0.4), CFrame.new(0, cy + 4.2, 0))
	-- chasing bulbs along the board edges (both faces)
	for _, z in { -0.5, 0.5 } do
		K.bulbsAlong(bulbs, Vector3.new(-6.8, cy + 3.95, z), Vector3.new(6.8, cy + 3.95, z), 16, 0.3)
		K.bulbsAlong(bulbs, Vector3.new(-6.8, cy - 3.95, z), Vector3.new(6.8, cy - 3.95, z), 16, 0.3)
	end
	-- up-light so the sign reads from the plaza
	local lamp = K.part(m, "Uplight", Vector3.new(1, 0.4, 1), CFrame.new(0, 1.5, -4.5), C.Dark, decor())
	K.new("SpotLight", { Face = Enum.NormalId.Top, Angle = 60, Range = 26, Brightness = 2.2,
		Color = Color3.fromRGB(255, 214, 170), Shadows = false }, lamp)
	return m
end

------------------------------------------------------------------
-- CASINO PYLON (tall marquee sign, readable along the street = ±X faces)
-- The two SurfaceGuis are named "OwnerSign"; Plots writes the casino name
-- into their "OwnerText" labels.
------------------------------------------------------------------
function MapProps.pylon()
	local m = model("CasinoPylon")
	local bulbs = K.new("Folder", { Name = "Bulbs" }, m)
	K.part(m, "Base", Vector3.new(3.6, 2, 3.6), CFrame.new(0, 1, 0), P.Ink, { solid = true })
	K.gold(m, "BaseLip", Vector3.new(3.8, 0.2, 3.8), CFrame.new(0, 2.05, 0))
	K.part(m, "Post", Vector3.new(1.6, 16, 1.6), CFrame.new(0, 10, 0), P.Crimson, { solid = true })
	K.gold(m, "PostTrim", Vector3.new(1.8, 0.3, 1.8), CFrame.new(0, 17.6, 0))
	local cy = 21.5
	local box = K.part(m, "SignBox", Vector3.new(1.4, 6.6, 12), CFrame.new(0, cy, 0), P.CrimsonDeep, { solid = true })
	K.gold(m, "SignFrame", Vector3.new(1.2, 7.1, 12.5), CFrame.new(0, cy, 0))
	for _, face in { Enum.NormalId.Right, Enum.NormalId.Left } do
		local g = glowGui(box, face, 50, 1.6)
		g.Name = "OwnerSign"
		local plate = K.signPlate(g, P.CrimsonDeep)
		local t = K.guiText(plate, "OPEN PLOT", { size = UDim2.fromScale(0.9, 0.5), position = UDim2.fromScale(0.05, 0.12),
			gradient = { P.GoldTop, P.Gold }, strokeThickness = 5 })
		t.Name = "OwnerText"
		K.guiText(plate, "★ ★ ★  CASINO  ★ ★ ★", { size = UDim2.fromScale(0.8, 0.2), position = UDim2.fromScale(0.1, 0.68),
			color = P.Cream, strokeThickness = 3 })
	end
	for _, x in { -0.78, 0.78 } do
		K.bulbsAlong(bulbs, Vector3.new(x, cy + 3.4, -5.9), Vector3.new(x, cy + 3.4, 5.9), 14, 0.28)
		K.bulbsAlong(bulbs, Vector3.new(x, cy - 3.4, -5.9), Vector3.new(x, cy - 3.4, 5.9), 14, 0.28)
	end
	-- crown on top, readable from both directions
	local crown = K.part(m, "Crown", Vector3.new(0.1, 4.2, 4.2), CFrame.new(0, cy + 5.6, 0), P.White, { transparency = 1, shadow = false })
	for _, face in { Enum.NormalId.Right, Enum.NormalId.Left } do
		local g = glowGui(crown, face, 50, 1.8)
		K.guiImage(g, Icons.crown, { size = UDim2.fromScale(1, 1) })
	end
	-- light the sidewalk under the sign
	local under = K.part(m, "Downlight", Vector3.new(1, 0.3, 1), CFrame.new(0, cy - 3.6, 0), C.Dark, decor())
	K.new("SpotLight", { Face = Enum.NormalId.Bottom, Angle = 80, Range = 26, Brightness = 2,
		Color = Color3.fromRGB(255, 205, 150), Shadows = false }, under)
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
		K.part(m, "PillarBase", Vector3.new(1.9, 1, 1.9), CFrame.new(sx * w / 2, 0.5, 0), P.Ink, { solid = true })
		K.gold(m, "Pillar", Vector3.new(1.3, 11, 1.3), CFrame.new(sx * w / 2, 6.5, 0))
		K.ball(m, "PillarTop", 1.4, Vector3.new(sx * w / 2, 12.4, 0), P.GoldTop, { reflectance = 0.2, shadow = false })
	end
	local header = K.part(m, "Header", Vector3.new(w + 2.4, 2.6, 1.2), CFrame.new(0, 13.2, 0), P.CrimsonDeep, { solid = true })
	K.gold(m, "HeaderTrim", Vector3.new(w + 2.7, 2.9, 1.0), CFrame.new(0, 13.2, 0))
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
		K.cylY(m, "PostBase", 0.8, 0.12, Vector3.new(0, 0.06, z), P.Gold, { reflectance = 0.2, shadow = false })
		K.cylY(m, "Post", 0.22, 2.6, Vector3.new(0, 1.3, z), P.Gold, { reflectance = 0.2, shadow = false })
		K.ball(m, "Knob", 0.4, Vector3.new(0, 2.65, z), P.GoldTop, { reflectance = 0.2, shadow = false })
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
	local wall = K.part(m, "Fence", Vector3.new(width, 9, 0.4), CFrame.new(0, 4.5, 0), hex("#3A3346"), { solid = true })
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
		K.guiText(bg, "EXPANSION COMING SOON", { size = UDim2.fromScale(0.6, 0.34), position = UDim2.fromScale(0.27, 0.22),
			gradient = { P.GoldTop, P.Gold }, strokeThickness = 4 })
		K.guiText(bg, "BIGGER CASINOS ON THE WAY", { size = UDim2.fromScale(0.44, 0.16), position = UDim2.fromScale(0.35, 0.6),
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
	K.gold(m, "CounterTop", Vector3.new(6.7, 0.18, 2.3), CFrame.new(0, h0 + 2.39, -0.9))
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
		K.cylY(m, "Post", 0.2, 3.3, Vector3.new(sx * 3.05, h0 + 4.05, -1.75), P.Gold, { reflectance = 0.15 })
	end
	K.canopy(m, 7.0, h0 + 6.2, 1.4, -2.2, 0.5, { col, P.White })
	K.boardSign(m, "Sign", Vector3.new(5.8, 1.35, 0.3), CFrame.new(0, h0 + 6.95, 1.2),
		daily and "DAILY REWARD" or "VIP STORE", { icon = daily and "gift" or "gem", bothSides = true })
	K.bulbsAlong(bulbs, Vector3.new(-3.3, h0 + 5.55, -2.3), Vector3.new(3.3, h0 + 5.55, -2.3), 10)
	local spot = K.part(m, "Downlight", Vector3.new(0.8, 0.2, 0.8), CFrame.new(0, h0 + 5.6, -1.2), C.Dark, decor())
	K.new("SpotLight", { Face = Enum.NormalId.Bottom, Angle = 110, Range = 16, Brightness = 1.6,
		Color = Color3.fromRGB(255, 214, 170), Shadows = false }, spot)
	return m
end

------------------------------------------------------------------
-- LEADERBOARD wall: "Board" part with a SurfaceGui (rows Row1..Row8 holding
-- Rank / Name / Value labels) that the server fills (Leaderboards.luau)
------------------------------------------------------------------
function MapProps.leaderboard()
	local m = model("Leaderboard")
	local bulbs = K.new("Folder", { Name = "Bulbs" }, m)
	local W, H, cy = 22, 13, 10.5
	for _, sx in { -1, 1 } do
		K.part(m, "PostBase", Vector3.new(2.4, 1.2, 2.4), CFrame.new(sx * 8, 0.6, 0.6), P.Ink, { solid = true })
		K.gold(m, "Post", Vector3.new(1.2, 4.5, 1.2), CFrame.new(sx * 8, 3.4, 0.6))
	end
	K.gold(m, "Frame", Vector3.new(W + 0.8, H + 0.8, 1.0), CFrame.new(0, cy, 0.25))
	local board = K.part(m, "Board", Vector3.new(W, H, 1.2), CFrame.new(0, cy, 0), P.Ink, { solid = true })
	local g = glowGui(board, Enum.NormalId.Front, 30, 1.3)
	g.Name = "Board"
	local bg = K.new("Frame", { BackgroundColor3 = hex("#1A0A14"), Size = UDim2.fromScale(1, 1), BorderSizePixel = 0 }, g)
	K.new("UIGradient", { Rotation = 90, Color = ColorSequence.new(hex("#3A0C1E"), hex("#14060E")) }, bg)
	local title = K.new("Frame", { BackgroundColor3 = P.Crimson, BorderSizePixel = 0, Size = UDim2.fromScale(1, 0.19) }, bg)
	K.new("UIGradient", { Rotation = 90, Color = ColorSequence.new(hex("#E23A52"), hex("#8E0F22")) }, title)
	K.guiImage(title, Icons.crown, { size = UDim2.fromScale(0.12, 1.25), position = UDim2.fromScale(0.08, 0.5) })
	K.guiImage(title, Icons.crown, { size = UDim2.fromScale(0.12, 1.25), position = UDim2.fromScale(0.92, 0.5) })
	K.guiText(title, "TOP CASINOS", { size = UDim2.fromScale(0.7, 0.8), position = UDim2.fromScale(0.15, 0.1),
		gradient = { P.GoldTop, P.Gold }, strokeThickness = 4 })
	K.guiText(bg, "THIS SERVER  •  TOTAL EARNED", { size = UDim2.fromScale(0.8, 0.07), position = UDim2.fromScale(0.1, 0.205),
		color = P.Cream, stroke = false, font = Enum.Font.GothamBlack })
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
	K.new("SpotLight", { Face = Enum.NormalId.Top, Angle = 70, Range = 22, Brightness = 1.2,
		Color = Color3.fromRGB(255, 220, 190), Shadows = false }, spot)
	return m
end

------------------------------------------------------------------
-- RESORT TOWER (backdrop): podium + window shaft (MaterialVariant with an
-- emissive mask, so windows glow without any lights) + setbacks + crown sign
-- spec = { w, d, h, variant = "CM_TowerWarm", tint, crown, name, tiers }
------------------------------------------------------------------
function MapProps.tower(spec)
	local m = model("Tower_" .. (spec.name or "X"))

	local w, d, h = spec.w, spec.d, spec.h
	K.part(m, "Podium", Vector3.new(w + 14, 14, d + 14), CFrame.new(0, 7, 0), hex("#241F31"), { solid = true, shadow = false })
	for _, s in { { 0, -(d + 14) / 2 }, { 0, (d + 14) / 2 } } do
		K.neon(m, "PodiumBand", Vector3.new(w + 14.2, 0.5, 0.2), CFrame.new(s[1], 12.5, s[2]), spec.crown)
	end
	for _, s in { -(w + 14) / 2, (w + 14) / 2 } do
		K.neon(m, "PodiumBand", Vector3.new(0.2, 0.5, d + 14.2), CFrame.new(s, 12.5, 0), spec.crown)
	end
	local y = 14
	local tiers = spec.tiers or { { 1, h } }
	local tw, td = w, d
	for i, tier in tiers do
		local sx, th = tier[1], tier[2]
		tw, td = w * sx, d * sx
		local shaft = K.part(m, "Shaft" .. i, Vector3.new(tw, th, td), CFrame.new(0, y + th / 2, 0), spec.tint or P.White, { shadow = false })
		shaft.Material = Enum.Material.Plastic
		shaft.MaterialVariant = spec.variant or "CM_TowerWarm"
		y += th
		-- slim neon ledge at each setback
		K.neon(m, "Ledge", Vector3.new(tw + 0.6, 0.35, td + 0.6), CFrame.new(0, y + 0.1, 0), spec.crown)
	end
	-- crown: cap, neon edges, name sign on the city-facing (front) face
	local cap = K.part(m, "Cap", Vector3.new(tw * 0.92, 8, td * 0.92), CFrame.new(0, y + 4, 0), hex("#1C1826"), { shadow = false })
	for _, s in { -1, 1 } do
		K.neon(m, "CrownEdge", Vector3.new(0.4, 8, 0.4), CFrame.new(s * tw * 0.46, y + 4, -td * 0.46), spec.crown)
		K.neon(m, "CrownEdge", Vector3.new(0.4, 8, 0.4), CFrame.new(s * tw * 0.46, y + 4, td * 0.46), spec.crown)
	end
	if spec.name then
		local g = glowGui(cap, Enum.NormalId.Front, 10, 2.2)
		K.guiText(g, spec.name, { size = UDim2.fromScale(0.92, 0.8), position = UDim2.fromScale(0.04, 0.1),
			color = spec.crown:Lerp(P.White, 0.45), strokeColor = spec.crown:Lerp(P.Ink, 0.4), strokeThickness = 3 })
	end
	K.cylY(m, "Spire", 0.8, 14, Vector3.new(0, y + 15, 0), C.Dark, { shadow = false })
	K.ball(m, "AirLight", 1.4, Vector3.new(0, y + 22.5, 0), hex("#FF3B55"), { material = Enum.Material.Neon, shadow = false })
	local _ = cap
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
	K.part(m, "Platform", Vector3.new(44, 3, 26), CFrame.new(0, 1.5, 0), hex("#241F31"), { solid = true })
	K.neon(m, "PlatformGlow", Vector3.new(44.2, 0.4, 0.2), CFrame.new(0, 2.6, -13.05), P.NeonPink)
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
		local rim = beamPart(rotor, "Rim", p0, p1, 1.3, 1.3, (k % 2 == 0) and hex("#FF6FD8") or hex("#7FE3FF"),
			{ material = Enum.Material.Neon, shadow = false })
		rim.Size += Vector3.new(0, 0, 0.3)
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
	K.cylY(m, "Base", d * 0.75, 5, Vector3.new(0, 2.5, 0), hex("#241F31"), { solid = true, shadow = false })
	K.cylY(m, "BaseLip", d * 0.75 + 1, 0.4, Vector3.new(0, 5.1, 0), P.Gold, { reflectance = 0.1, shadow = false })
	local cy = 5 + r - d * 0.08
	local centre = Vector3.new(0, cy, 0)
	K.ball(m, "Orb", d, centre, hex("#191428"), { reflectance = 0.18, shadow = false })
	local bands = K.new("Folder", { Name = "Bands" }, m)
	for k = -4, 4 do
		local y = k * r * 0.2
		local cross = math.sqrt(r * r - y * y)
		local band = K.cylY(bands, "Band", (cross + 0.45) * 2, 0.8, centre + Vector3.new(0, y, 0), hex("#4B2A8A"),
			{ material = Enum.Material.Neon, shadow = false })
		band:SetAttribute("Wave", (k + 4) / 8)
	end
	for k = 0, 5 do
		local band = K.part(bands, "Band", Vector3.new(0.8, d + 0.9, d + 0.9),
			CFrame.new(centre) * CFrame.Angles(0, k * math.pi / 6, 0), hex("#4B2A8A"),
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
	K.cylY(m, "DrumBand", 4.2, 0.3, Vector3.new(0, 2.3, 0), P.Gold, { reflectance = 0.15 })
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
	return m
end

------------------------------------------------------------------
-- FOUNTAIN JET: nozzle + glowing water column (MapFX animates its height)
------------------------------------------------------------------
function MapProps.fountainJet(height: number?)
	local h = height or 12
	local m = model("FountainJet")
	K.cylY(m, "Nozzle", 0.9, 0.4, Vector3.new(0, 0.2, 0), P.Chrome, { material = Enum.Material.Metal, shadow = false })
	local jet = K.cylY(m, "Jet", 0.75, h, Vector3.new(0, 0.4 + h / 2, 0), hex("#8FD6FF"),
		{ material = Enum.Material.Neon, transparency = 0.45, shadow = false })
	jet:SetAttribute("BaseHeight", h)
	K.cylY(m, "Ring", 1.6, 0.08, Vector3.new(0, 0.05, 0), hex("#46D8FF"), { material = Enum.Material.Neon, shadow = false })
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

function MapProps.planter(w: number, d: number)
	local m = model("Planter")
	K.part(m, "Box", Vector3.new(w, 1.6, d), CFrame.new(0, 0.8, 0), P.Ink, { solid = true })
	K.gold(m, "Lip", Vector3.new(w + 0.2, 0.2, d + 0.2), CFrame.new(0, 1.65, 0))
	K.part(m, "Hedge", Vector3.new(w - 0.4, 1.4, d - 0.4), CFrame.new(0, 2.3, 0), hex("#2D6B33"),
		{ material = Enum.Material.Grass, shadow = false })
	return m
end

function MapProps.trashBin()
	local m = model("TrashBin")
	K.cylY(m, "Bin", 1.4, 2.4, Vector3.new(0, 1.2, 0), C.Dark, { solid = true, material = Enum.Material.Metal })
	K.cylY(m, "Lid", 1.6, 0.3, Vector3.new(0, 2.5, 0), P.Gold, { reflectance = 0.15 })
	return m
end

-- string lights hanging between two points into a Bulbs folder (catenary)
function MapProps.stringLights(folder: Instance, a: Vector3, b: Vector3, sag: number, count: number)
	local prev
	for i = 0, count - 1 do
		local t = i / (count - 1)
		local p = a:Lerp(b, t) - Vector3.new(0, sag * 4 * t * (1 - t), 0)
		local bulb = K.ball(folder, "Bulb", 0.42, p, (i % 2 == 0) and P.GoldTop or hex("#FFD2E8"),
			{ material = Enum.Material.Neon, shadow = false })
		bulb:SetAttribute("Phase", i % 2)
		if prev then rod(folder, "Wire", prev, p, 0.08, C.Dark, decor()) end
		prev = p
	end
end

return MapProps
