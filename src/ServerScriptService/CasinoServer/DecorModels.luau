--!nonstrict
-- DecorModels.luau — every decor piece (Config.Decor) built FROM CODE in the
-- "Showtime" style of the machines: glossy lacquer, gold trims, velvet,
-- neon accents. Same conventions as MachineModels: model space, ground at
-- y = 0, centred on x/z, FRONT = -Z (a viewer in front: their right = -X).
-- The model's pivot is the centre of its footprint on the ground, so
-- PivotTo(groundCF) seats it (Decor.luau, the build-mode ghost).
--
-- Flat pieces (def.flat) are a few studs of floor: every part CanCollide off
-- and their top faces at the heights of their `layer` (1 floors 0.06-0.08,
-- 2 paths 0.14-0.17, 3 rugs 0.20-0.28), so a rug lying on a tile floor never
-- z-fights with it. Solid pieces collide with their main body only (pots,
-- trunks, bases): NPC pathfinding walks round them, fronds overhang.
--
-- Optional rigs (client MachineFX runs them when the model is also tagged
-- CasinoProp, which Decor.luau does for models with the "Animated" attribute):
--   Bulbs      folder of neon balls that chase (Phase 0 / 1)
--   SpinRate   sub-models that turn slowly about their PrimaryPart (a star, a gem)
-- Named parts Decor.luau fills in: OwnerName (TextLabel, the Walk of Fame star).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Materials = require(Common:WaitForChild("Materials"))
local MachineModels = require(script.Parent:WaitForChild("MachineModels"))

local DecorModels = {}

local K = MachineModels.Kit
local P = MachineModels.Palette
local hex = K.hex
local new, part, neon, gold = K.new, K.part, K.neon, K.gold
local cylX, cylY, cylZ, ball, rod, spike = K.cylX, K.cylY, K.cylZ, K.ball, K.rod, K.spike

local rad = math.rad
local SOLID = { solid = true }

-- decor colours (the machines' palette P covers ink / gold / crimson / neon)
local D = {
	Lacquer = hex("#1E1418"), Leaf = hex("#2FA84F"), LeafLight = hex("#62D36A"), LeafDeep = hex("#1C7A36"),
	Bark = hex("#8A5A2B"), BarkDark = hex("#5E3A1A"), Soil = hex("#3B2416"),
	Terracotta = hex("#C8643B"), TerracottaLight = hex("#DE7C4E"), Turquoise = hex("#1FB5A8"), Sand = hex("#E8C27A"),
	Cactus = hex("#3E9B4F"), CactusDeep = hex("#2C7A3B"),
	Marble = hex("#F1EBE1"), Ivory = hex("#F4EFE6"), Charcoal = hex("#1C1A1E"), Terrazzo = hex("#2E282B"),
	Velvet = hex("#B0142E"), Royal = hex("#5B2A8C"), RoyalLight = hex("#7038AE"),
	Water = hex("#3FC8FF"), WaterLight = hex("#9FE6FF"), Blossom = hex("#FF9ED2"), BlossomLight = hex("#FFD3EA"),
	Coral = hex("#F2879A"), Glass = hex("#E8F6FF"), WarmLight = hex("#FFD9A0"), Porcelain = hex("#1F4E8C"),
}
DecorModels.Colors = D

local GOLD_SHINE = { reflectance = 0.2 }

------------------------------------------------------------------
-- kit
------------------------------------------------------------------
local function model(name: string): Model
	return new("Model", { Name = name })
end

-- a CFrame at `origin` whose +Y points out along `yaw` (radians about Y, 0 =
-- toward -Z, the front) at `el` degrees above the horizontal. A spike / blade
-- built along that +Y lies in the frame's XY plane, its thickness along Z, so a
-- low elevation gives a leaf lying almost flat.
local function outward(origin: Vector3, yaw: number, el: number): CFrame
	return CFrame.new(origin) * CFrame.Angles(0, yaw, 0) * CFrame.Angles(rad(el - 90), 0, 0)
end

-- a two-part leaf / frond: a blade (box) rising at el1, then a pointed tip
-- (spike) bending to el2. Returns the tip's end point.
local function leaf(parent, origin: Vector3, yaw: number, el1: number, len1: number, el2: number, len2: number,
	width: number, color: Color3, opts)
	local cf1 = outward(origin, yaw, el1)
	part(parent, "Leaf", Vector3.new(width, len1, 0.07), cf1 * CFrame.new(0, len1 / 2, 0), color, table.clone(opts or {}))
	local joint = (cf1 * CFrame.new(0, len1, 0)).Position
	spike(parent, "LeafTip", width, len2, 0.07, outward(joint, yaw, el2), color, table.clone(opts or {}))
	return (outward(joint, yaw, el2) * CFrame.new(0, len2, 0)).Position
end

-- a flat five-point star in the XZ plane (centre `c`, top face at c.Y + t/2)
-- pointing its first point at `yaw` (0 = toward -Z): five spikes whose bases
-- (0.65 R wide) cross at the centre and whose edges meet at the inner corners
local function flatStar(parent, name: string, c: Vector3, r: number, t: number, yaw: number, color: Color3, opts)
	for k = 0, 4 do
		local cf = CFrame.new(c) * CFrame.Angles(0, yaw + rad(72 * k), 0) * CFrame.Angles(rad(-90), 0, 0)
		spike(parent, name, r * 0.65, r, t, cf, color, table.clone(opts or {}))
	end
end

-- the same star standing upright in a plane facing the front (-Z): its first
-- point up, thickness t along Z
local function uprightStar(parent, name: string, c: Vector3, r: number, t: number, color: Color3, opts)
	for k = 0, 4 do
		local cf = CFrame.new(c) * CFrame.Angles(0, 0, rad(72 * k))
		spike(parent, name, r * 0.65, r, t, cf, color, table.clone(opts or {}))
	end
end

-- the ten corners of a star (outer / inner alternating) in the XY plane at z
local function starCorners(c: Vector3, r: number): {Vector3}
	local pts = {}
	for k = 0, 9 do
		local a = rad(90 + 36 * k)
		local rr = (k % 2 == 0) and r or r * 0.382
		table.insert(pts, c + Vector3.new(math.cos(a) * rr, math.sin(a) * rr, 0))
	end
	return pts
end

-- a round pot: body + gold rim + gold foot (+ a band); returns the soil height
local function roundPot(parent, d: number, h: number, color: Color3, spec)
	spec = spec or {}
	cylY(parent, "Pot", d, h, Vector3.new(0, h / 2, 0), color, { solid = true, reflectance = spec.gloss or 0.1 })
	cylY(parent, "PotFoot", d + 0.12, 0.16, Vector3.new(0, 0.08, 0), spec.trim or P.Gold, { reflectance = 0.15 })
	if spec.band then
		cylY(parent, "PotBand", d + 0.05, 0.14, Vector3.new(0, h * 0.55, 0), spec.band, { reflectance = 0.15 })
	end
	cylY(parent, "PotRim", d + 0.2, 0.22, Vector3.new(0, h - 0.02, 0), spec.trim or P.Gold, { reflectance = 0.15 })
	cylY(parent, "Soil", d - 0.12, 0.06, Vector3.new(0, h + 0.1, 0), spec.soil or D.Soil)
	return h + 0.13
end

-- a square lacquer planter with gold corner trims; returns the soil height
local function squarePlanter(parent, w: number, d: number, h: number, color: Color3)
	part(parent, "Planter", Vector3.new(w, h, d), CFrame.new(0, h / 2, 0), color, { solid = true, reflectance = 0.14 })
	gold(parent, "PlanterFoot", Vector3.new(w + 0.1, 0.12, d + 0.1), CFrame.new(0, 0.06, 0))
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			gold(parent, "PlanterEdge", Vector3.new(0.1, h - 0.1, 0.1), CFrame.new(sx * w / 2, h / 2, sz * d / 2))
		end
	end
	gold(parent, "PlanterRim", Vector3.new(w + 0.16, 0.14, d + 0.16), CFrame.new(0, h + 0.05, 0))
	part(parent, "Soil", Vector3.new(w - 0.2, 0.06, d - 0.2), CFrame.new(0, h + 0.13, 0), D.Soil)
	return h + 0.16
end

-- a die with round pips on all six faces (opposite faces add up to 7)
local PIPS = {
	[1] = { { 0.5, 0.5 } },
	[2] = { { 0.27, 0.27 }, { 0.73, 0.73 } },
	[3] = { { 0.25, 0.25 }, { 0.5, 0.5 }, { 0.75, 0.75 } },
	[4] = { { 0.27, 0.27 }, { 0.73, 0.27 }, { 0.27, 0.73 }, { 0.73, 0.73 } },
	[5] = { { 0.25, 0.25 }, { 0.75, 0.25 }, { 0.5, 0.5 }, { 0.25, 0.75 }, { 0.75, 0.75 } },
	[6] = { { 0.27, 0.22 }, { 0.73, 0.22 }, { 0.27, 0.5 }, { 0.73, 0.5 }, { 0.27, 0.78 }, { 0.73, 0.78 } },
}
local DIE_FACES = { Top = 1, Bottom = 6, Front = 2, Back = 5, Right = 3, Left = 4 }
local function bigDie(parent, name: string, s: number, cf: CFrame, color: Color3, pipColor: Color3)
	local d = part(parent, name, Vector3.new(s, s, s), cf, color, { solid = true, reflectance = 0.12, transparency = 0.06 })
	for faceName, value in DIE_FACES do
		local g = K.surface(d, Enum.NormalId[faceName], math.floor(160 / s), 0.4)
		for _, xy in PIPS[value] do
			local pip = new("Frame", {
				BackgroundColor3 = pipColor, AnchorPoint = Vector2.new(0.5, 0.5), BorderSizePixel = 0,
				Position = UDim2.fromScale(xy[1], xy[2]), Size = UDim2.fromScale(0.19, 0.19),
			}, g)
			new("UICorner", { CornerRadius = UDim.new(0.5, 0) }, pip)
		end
	end
	return d
end

-- the rotation that stands a cube on one corner (its body diagonal vertical)
local ON_CORNER = CFrame.Angles(0, 0, rad(54.7356)) * CFrame.Angles(0, rad(45), 0)

-- a brilliant-cut gem: a crown (girdle disc + table) over eight pavilion facets
-- meeting at the culet `depth` below the girdle centre `c`
local function brilliant(parent, c: Vector3, r: number, depth: number, color: Color3)
	local opts = { reflectance = 0.3, transparency = 0.12 }
	cylY(parent, "GemCrown", r * 2, r * 0.36, c + Vector3.new(0, r * 0.18, 0), color, table.clone(opts))
	cylY(parent, "GemTable", r * 1.3, r * 0.16, c + Vector3.new(0, r * 0.42, 0), color:Lerp(P.White, 0.35), table.clone(opts))
	local culet = c - Vector3.new(0, depth, 0)
	for k = 0, 7 do
		local p0 = c + Vector3.new(math.cos(rad(k * 45)) * r, 0, math.sin(rad(k * 45)) * r)
		local p1 = c + Vector3.new(math.cos(rad(k * 45 + 45)) * r, 0, math.sin(rad(k * 45 + 45)) * r)
		local mid = (p0 + p1) / 2
		local cf = CFrame.fromMatrix(mid, (p1 - p0).Unit, (culet - mid).Unit)
		spike(parent, "GemFacet", (p1 - p0).Magnitude, (culet - mid).Magnitude, 0.06, cf,
			(k % 2 == 0) and color or color:Lerp(P.White, 0.2), table.clone(opts))
	end
end

------------------------------------------------------------------
-- PLANTS
------------------------------------------------------------------
-- a fern in a black lacquer planter with gold edges: an outer ring of
-- drooping fronds and an inner ring rising out of the heart
local function fernPlanter()
	local m = model("Fern Planter")
	local top = squarePlanter(m, 1.7, 1.7, 1.3, D.Lacquer)
	local c = Vector3.new(0, top + 0.08, 0)
	ball(m, "Heart", 0.6, c + Vector3.new(0, 0.04, 0), D.LeafDeep)
	for i = 0, 7 do
		local yaw = rad(i * 45 + 10)
		local o = c + CFrame.Angles(0, yaw, 0).LookVector * 0.16
		leaf(m, o, yaw, 40, 0.7, -32, 0.74, 0.34, (i % 2 == 0) and D.LeafLight or D.Leaf)
	end
	for i = 0, 4 do
		local yaw = rad(i * 72 + 32)
		local o = c + Vector3.new(0, 0.1, 0) + CFrame.Angles(0, yaw, 0).LookVector * 0.08
		leaf(m, o, yaw, 72, 0.72, 34, 0.66, 0.3, (i % 2 == 0) and D.Leaf or D.LeafDeep)
	end
	return m
end

-- a palm with a gently leaning, ringed trunk (spec: the Golden Palm)
local function palmTree(spec)
	spec = spec or {}
	local m = model(spec.name or "Potted Palm")
	local top = roundPot(m, 1.9, 1.5, spec.pot or P.Crimson, { trim = spec.potTrim, band = spec.band or P.Gold,
		soil = spec.soil })
	-- trunk: six ringed segments along a gentle curve toward +X
	local function at(t: number): Vector3
		return Vector3.new(0.22 * t * t, top - 0.05 + 3.85 * t, 0.05 * t)
	end
	local n = 6
	for i = 0, n - 1 do
		local a, b = at(i / n), at((i + 1) / n)
		local d = 0.62 - 0.035 * i
		rod(m, "Trunk", a, b + (b - a).Unit * 0.06, d, (i % 2 == 0) and (spec.bark or D.Bark) or (spec.barkDark or D.BarkDark),
			{ solid = i < 2, reflectance = spec.trunkGloss or 0 })
		rod(m, "TrunkRing", a - (b - a).Unit * 0.02, a + (b - a).Unit * 0.12, d + 0.09, spec.ring or D.BarkDark,
			{ reflectance = spec.trunkGloss or 0 })
	end
	local crown = at(1)
	ball(m, "Crown", 0.72, crown, spec.hub or D.LeafDeep, { reflectance = spec.leafGloss or 0 })
	local lopts = { reflectance = spec.leafGloss or 0 }
	for i = 0, 8 do
		local yaw = rad(i * 40 + 12 + ((i % 2) * 7))
		local col = (i % 2 == 0) and (spec.leaf or D.Leaf) or (spec.leafLight or D.LeafLight)
		leaf(m, crown + Vector3.new(0, 0.1, 0), yaw, 26 + (i % 3) * 5, 1.12, -50, 1.62, 0.6, col, lopts)
	end
	for i = 0, 3 do
		local yaw = rad(i * 90 + 35)
		leaf(m, crown + Vector3.new(0, 0.22, 0), yaw, 64, 0.8, 18, 0.85, 0.48, spec.leafLight or D.LeafLight, lopts)
	end
	for i = 0, 2 do
		local yaw = rad(i * 120 + 30)
		local p = crown + CFrame.Angles(0, yaw, 0).LookVector * 0.32 - Vector3.new(0, 0.32, 0)
		if spec.gems then
			ball(m, "Coconut", 0.36, p, spec.gems, { material = Enum.Material.Neon, shadow = false })
		else
			ball(m, "Coconut", 0.36, p, hex("#5A3418"))
		end
	end
	if spec.glow then
		cylY(m, "GlowRing", 2.16, 0.06, Vector3.new(0, 0.19, 0), spec.glow, { material = Enum.Material.Neon, shadow = false })
	end
	return m
end

-- a saguaro in a terracotta pot with a turquoise band and a pink bloom
local function desertCactus()
	local m = model("Desert Cactus")
	local top = roundPot(m, 1.6, 1.1, D.Terracotta, { trim = D.TerracottaLight, band = D.Turquoise, soil = D.Sand, gloss = 0.05 })
	local opts = { reflectance = 0.06 }
	local h = 2.55
	cylY(m, "Column", 0.82, h, Vector3.new(0, top + h / 2, 0), D.Cactus, { solid = true, reflectance = 0.06 })
	ball(m, "ColumnTop", 0.82, Vector3.new(0, top + h, 0), D.Cactus, opts)
	for k = 0, 3 do
		local a = rad(k * 90 + 45)
		part(m, "Rib", Vector3.new(0.1, h - 0.15, 0.06),
			CFrame.new(math.cos(a) * 0.4, top + h / 2, math.sin(a) * 0.4) * CFrame.Angles(0, -a, 0), D.CactusDeep)
	end
	-- arms: (side, height out, height up, reach)
	for _, arm in { { -1, 1.15, 0.95, 0.82, 0.5 }, { 1, 0.7, 0.7, 0.72, 0.44 } } do
		local sx, y0, up, reach, d = arm[1], top + arm[2], arm[3], arm[4], arm[5]
		cylX(m, "Arm", d, reach, Vector3.new(sx * reach / 2, y0, 0), D.Cactus, opts)
		ball(m, "Elbow", d, Vector3.new(sx * reach, y0, 0), D.Cactus, opts)
		cylY(m, "ArmUp", d, up, Vector3.new(sx * reach, y0 + up / 2, 0), D.Cactus, opts)
		ball(m, "ArmTop", d, Vector3.new(sx * reach, y0 + up, 0), D.Cactus, opts)
	end
	ball(m, "Bloom", 0.34, Vector3.new(0.08, top + h + 0.36, -0.05), hex("#FF5FA2"))
	ball(m, "BloomHeart", 0.15, Vector3.new(0.08, top + h + 0.48, -0.1), hex("#FFD23F"))
	ball(m, "Bloom", 0.24, Vector3.new(-0.82, top + 1.15 + 0.95 + 0.3, -0.02), hex("#FF8FC8"))
	return m
end

-- a long crimson planter bursting with blooms
local function flowerBed()
	local m = model("Flower Bed")
	local W, Dp, H = 4.0, 1.6, 0.85
	part(m, "Box", Vector3.new(W, H, Dp), CFrame.new(0, H / 2, 0), P.Crimson, { solid = true, reflectance = 0.12 })
	for _, sz in { -1, 1 } do
		gold(m, "Rim", Vector3.new(W + 0.12, 0.13, 0.13), CFrame.new(0, H + 0.02, sz * Dp / 2))
	end
	for _, sx in { -1, 1 } do
		gold(m, "Rim", Vector3.new(0.13, 0.13, Dp + 0.12), CFrame.new(sx * W / 2, H + 0.02, 0))
		for _, sz in { -1, 1 } do
			gold(m, "Post", Vector3.new(0.17, H, 0.17), CFrame.new(sx * W / 2, H / 2, sz * Dp / 2))
			ball(m, "Finial", 0.26, Vector3.new(sx * W / 2, H + 0.16, sz * Dp / 2), P.Gold, GOLD_SHINE)
		end
	end
	gold(m, "Foot", Vector3.new(W + 0.1, 0.1, Dp + 0.1), CFrame.new(0, 0.05, 0))
	part(m, "Soil", Vector3.new(W - 0.16, 0.06, Dp - 0.16), CFrame.new(0, H - 0.02, 0), D.Soil)
	for i = 0, 4 do
		ball(m, "Bush", 0.92, Vector3.new(-1.56 + i * 0.78, H + 0.1, (i % 2 == 0) and 0.12 or -0.12),
			(i % 2 == 0) and D.LeafDeep or D.Leaf)
	end
	local blooms = { hex("#FF5FA2"), hex("#FFD23F"), hex("#E8314A"), hex("#9B5DE5"), D.Ivory, hex("#FF8C42") }
	for i = 0, 11 do
		local x = -1.72 + i * 0.313
		local z = (i % 2 == 0) and -0.34 or 0.3
		local y = H + 0.42 + ((i % 3) * 0.07)
		ball(m, "Bloom", 0.34, Vector3.new(x, y, z), blooms[i % #blooms + 1])
	end
	return m
end

-- a boxwood hedge on a black planter, two ball topiaries on top
local function topiaryHedge()
	local m = model("Topiary Hedge")
	local W, Dp = 4.0, 1.5
	part(m, "Planter", Vector3.new(W, 0.6, Dp), CFrame.new(0, 0.3, 0), D.Lacquer, { solid = true, reflectance = 0.14 })
	gold(m, "PlanterLip", Vector3.new(W + 0.08, 0.1, Dp + 0.08), CFrame.new(0, 0.62, 0))
	gold(m, "PlanterFoot", Vector3.new(W + 0.06, 0.08, Dp + 0.06), CFrame.new(0, 0.04, 0))
	local hedge = part(m, "Hedge", Vector3.new(W - 0.2, 1.95, Dp - 0.12), CFrame.new(0, 0.67 + 0.975, 0), D.Leaf, SOLID)
	Materials.paint(hedge, "Hedge")
	for _, sx in { -1, 1 } do
		local b = ball(m, "Topiary", 0.98, Vector3.new(sx * 1.35, 2.62 + 0.36, 0), D.Leaf)
		Materials.paint(b, "Hedge")
		ball(m, "Finial", 0.2, Vector3.new(sx * 1.35, 3.5, 0), P.Gold, GOLD_SHINE)
	end
	return m
end

-- a cherry-blossom bonsai in a blue porcelain tray on a little stand
local function cherryBonsai()
	local m = model("Cherry Bonsai")
	part(m, "Stand", Vector3.new(2.2, 0.18, 1.5), CFrame.new(0, 0.62, 0), P.WoodDark, { solid = true, reflectance = 0.1 })
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			part(m, "Leg", Vector3.new(0.18, 0.54, 0.18), CFrame.new(sx * 0.92, 0.27, sz * 0.58), P.WoodDark, SOLID)
		end
	end
	gold(m, "StandTrim", Vector3.new(2.24, 0.05, 1.54), CFrame.new(0, 0.7, 0))
	part(m, "Tray", Vector3.new(1.9, 0.34, 1.22), CFrame.new(0, 0.9, 0), D.Porcelain, { solid = true, reflectance = 0.22 })
	gold(m, "TrayRim", Vector3.new(1.98, 0.06, 1.3), CFrame.new(0, 1.07, 0))
	part(m, "Moss", Vector3.new(1.76, 0.05, 1.08), CFrame.new(0, 1.1, 0), D.LeafDeep)
	ball(m, "MossMound", 0.62, Vector3.new(0.18, 1.02, 0.05), D.Leaf)
	local bark = hex("#5A3A22")
	local a, b, c = Vector3.new(0.1, 1.05, 0), Vector3.new(-0.18, 1.62, 0.05), Vector3.new(0.2, 2.06, -0.04)
	rod(m, "Trunk", a, b, 0.32, bark, SOLID)
	rod(m, "Trunk", b, c, 0.26, bark)
	rod(m, "Trunk", c, Vector3.new(0.05, 2.5, 0), 0.18, bark)
	rod(m, "Branch", c, Vector3.new(0.78, 2.3, 0.1), 0.13, bark)
	rod(m, "Branch", b, Vector3.new(-0.78, 1.96, -0.05), 0.13, bark)
	ball(m, "Knot", 0.3, b, bark)
	ball(m, "Knot", 0.27, c, bark)
	local clouds = {
		{ Vector3.new(0.86, 2.42, 0.1), 0.62 }, { Vector3.new(-0.86, 2.08, -0.05), 0.6 },
		{ Vector3.new(0.05, 2.72, 0), 0.7 }, { Vector3.new(0.42, 2.5, -0.3), 0.5 },
	}
	for i, cl in clouds do
		local p, s = cl[1], cl[2]
		ball(m, "Blossom", s, p, D.Blossom)
		ball(m, "Blossom", s * 0.8, p + Vector3.new(s * 0.45, -0.05, 0.12), (i % 2 == 0) and D.BlossomLight or D.Blossom)
		ball(m, "Blossom", s * 0.78, p + Vector3.new(-s * 0.42, 0.02, -0.1), D.BlossomLight)
	end
	for _, p in { Vector3.new(-0.5, 1.13, -0.3), Vector3.new(0.62, 1.13, 0.25), Vector3.new(-0.2, 1.13, 0.38) } do
		cylY(m, "Petal", 0.12, 0.02, p, D.Blossom, { shadow = false })
	end
	return m
end

------------------------------------------------------------------
-- FLOORS & PATHS (flat; layer heights: see the header)
------------------------------------------------------------------
-- a crimson velvet runner with gold borders; the ends are open so runners
-- chain into one long carpet
local function redCarpet()
	local m = model("Red Carpet")
	local body = part(m, "Carpet", Vector3.new(3.5, 0.14, 8), CFrame.new(0, 0.07, 0), P.Crimson,
		{ material = Enum.Material.Fabric })
	m.PrimaryPart = body
	for _, sx in { -1, 1 } do
		gold(m, "Border", Vector3.new(0.25, 0.17, 8), CFrame.new(sx * 1.875, 0.085, 0))
		gold(m, "Pinstripe", Vector3.new(0.06, 0.15, 8), CFrame.new(sx * 1.48, 0.075, 0))
	end
	for i = -1, 1 do
		gold(m, "Diamond", Vector3.new(0.52, 0.155, 0.52), CFrame.new(0, 0.0775, i * 8 / 3) * CFrame.Angles(0, rad(45), 0))
	end
	return m
end

-- a polished marble slab with a gold inlay (tiles into a grand floor)
local function marbleTile()
	local m = model("Marble Floor")
	local slab = part(m, "Slab", Vector3.new(4, 0.06, 4), CFrame.new(0, 0.03, 0), D.Marble,
		{ material = Enum.Material.Marble, reflectance = 0.08 })
	m.PrimaryPart = slab
	for _, s in { -1, 1 } do
		gold(m, "Inlay", Vector3.new(3.36, 0.07, 0.08), CFrame.new(0, 0.035, s * 1.64))
		gold(m, "Inlay", Vector3.new(0.08, 0.07, 3.36), CFrame.new(s * 1.64, 0.035, 0))
	end
	gold(m, "Rosette", Vector3.new(0.66, 0.075, 0.66), CFrame.new(0, 0.0375, 0) * CFrame.Angles(0, rad(45), 0))
	part(m, "RosetteCore", Vector3.new(0.34, 0.08, 0.34), CFrame.new(0, 0.04, 0) * CFrame.Angles(0, rad(45), 0), D.Charcoal,
		{ reflectance = 0.12 })
	return m
end

-- a glossy black-and-white checker floor (4 x 4 squares; tiles seamlessly)
local function checkerTile()
	local m = model("Checker Floor")
	local base = part(m, "Base", Vector3.new(4, 0.06, 4), CFrame.new(0, 0.03, 0), D.Charcoal, { reflectance = 0.14 })
	m.PrimaryPart = base
	for i = 0, 3 do
		for j = 0, 3 do
			if (i + j) % 2 == 0 then
				part(m, "Square", Vector3.new(0.96, 0.07, 0.96), CFrame.new(-1.5 + i, 0.035, -1.5 + j), D.Ivory,
					{ reflectance = 0.14 })
			end
		end
	end
	return m
end

-- a round royal-purple rug with gold rings and a gold star
local function royalRug()
	local m = model("Royal Rug")
	local fabric = { material = Enum.Material.Fabric }
	local outer = cylY(m, "RugEdge", 6.0, 0.2, Vector3.new(0, 0.1, 0), P.CrimsonDeep, table.clone(fabric))
	m.PrimaryPart = outer
	cylY(m, "RugRing", 5.62, 0.21, Vector3.new(0, 0.105, 0), P.Gold, { reflectance = 0.1 })
	cylY(m, "RugField", 5.3, 0.22, Vector3.new(0, 0.11, 0), D.Royal, table.clone(fabric))
	cylY(m, "RugRing", 2.7, 0.23, Vector3.new(0, 0.115, 0), P.Gold, { reflectance = 0.1 })
	cylY(m, "RugCentre", 2.42, 0.24, Vector3.new(0, 0.12, 0), P.Crimson, table.clone(fabric))
	flatStar(m, "RugStar", Vector3.new(0, 0.125, 0), 1.08, 0.25, math.pi, P.Gold, { reflectance = 0.1 })
	for k = 0, 11 do
		local a = rad(k * 30 + 15)
		cylY(m, "RugDot", 0.26, 0.23, Vector3.new(math.cos(a) * 2.0, 0.115, math.sin(a) * 2.0), P.Gold, { shadow = false })
	end
	return m
end

-- a glossy black walkway with neon edges and chevrons pointing the way (-Z)
local function neonWalkway()
	local m = model("Neon Walkway")
	local base = part(m, "Walk", Vector3.new(3, 0.14, 8), CFrame.new(0, 0.07, 0), hex("#140A12"), { reflectance = 0.28 })
	m.PrimaryPart = base
	for _, sx in { -1, 1 } do
		neon(m, "Edge", Vector3.new(0.14, 0.16, 8), CFrame.new(sx * 1.36, 0.08, 0), P.NeonPink)
	end
	for i = -1, 1 do
		local z0 = i * 8 / 3
		for _, sx in { -1, 1 } do
			-- each chevron arm runs from the tip (0, z0 - 0.38) back to (sx 0.62, z0 + 0.38)
			local a = Vector3.new(0, 0.0775, z0 - 0.38)
			local b = Vector3.new(sx * 0.62, 0.0775, z0 + 0.38)
			local mid = (a + b) / 2
			neon(m, "Chevron", Vector3.new(0.16, 0.155, (b - a).Magnitude + 0.12), CFrame.lookAt(mid, b), P.NeonBlue)
		end
	end
	return m
end

-- a coral Walk of Fame star on a charcoal terrazzo tile, the owner's name on it
local function fameStar()
	local m = model("Walk of Fame Star")
	local tile = part(m, "Tile", Vector3.new(4, 0.14, 4), CFrame.new(0, 0.07, 0), D.Terrazzo,
		{ material = Enum.Material.Marble, reflectance = 0.1 })
	m.PrimaryPart = tile
	flatStar(m, "StarRim", Vector3.new(0, 0.075, 0), 1.82, 0.15, math.pi, P.Gold, { reflectance = 0.15 })
	flatStar(m, "Star", Vector3.new(0, 0.0785, 0), 1.6, 0.157, math.pi, D.Coral, { reflectance = 0.06 })
	-- the name across the upper part of the star (reads upright from the front)
	local carrier = K.flatPrint(m, "NamePlate", 2.6, 0.62, CFrame.new(0, 0.162, 0.18))
	local g = K.surface(carrier, Enum.NormalId.Top, 90, 0.3)
	local label = K.guiText(g, "YOUR NAME", { color = P.GoldTop, strokeThickness = 4, max = 60 })
	label.Name = "OwnerName"
	-- the emblem: a gold disc with a star
	cylY(m, "Emblem", 0.86, 0.163, Vector3.new(0, 0.0815, -0.62), P.Gold, { reflectance = 0.15 })
	cylY(m, "EmblemFace", 0.66, 0.168, Vector3.new(0, 0.084, -0.62), P.CrimsonDeep)
	flatStar(m, "EmblemStar", Vector3.new(0, 0.086, -0.62), 0.28, 0.172, math.pi, P.GoldTop)
	return m
end

------------------------------------------------------------------
-- LIGHTS
------------------------------------------------------------------
-- an art deco torchiere: stepped ink + gold base, a gold pole, a glowing bowl
local function decoLamp()
	local m = model("Deco Lamp")
	cylY(m, "Base", 1.3, 0.2, Vector3.new(0, 0.1, 0), D.Lacquer, { solid = true, reflectance = 0.15 })
	cylY(m, "BaseStep", 0.95, 0.14, Vector3.new(0, 0.27, 0), P.Gold, GOLD_SHINE)
	cylY(m, "Pole", 0.16, 4.3, Vector3.new(0, 0.34 + 2.15, 0), P.Gold, { solid = true, reflectance = 0.2 })
	ball(m, "Knot", 0.34, Vector3.new(0, 1.9, 0), P.Gold, GOLD_SHINE)
	cylY(m, "Collar", 0.26, 0.12, Vector3.new(0, 3.4, 0), D.Lacquer)
	cylY(m, "ShadeStep", 0.55, 0.18, Vector3.new(0, 4.7, 0), D.Lacquer, { reflectance = 0.15 })
	cylY(m, "ShadeLow", 0.95, 0.22, Vector3.new(0, 4.88, 0), P.Gold, GOLD_SHINE)
	cylY(m, "ShadeTop", 1.45, 0.22, Vector3.new(0, 5.08, 0), P.Gold, GOLD_SHINE)
	local glow = cylY(m, "Glow", 1.25, 0.06, Vector3.new(0, 5.22, 0), D.WarmLight, { material = Enum.Material.Neon, shadow = false })
	new("PointLight", { Name = "LampLight", Color = D.WarmLight, Range = 14, Brightness = 1.4, Shadows = false }, glow)
	return m
end

-- a big neon star on a pole that turns slowly
local function neonStarSign()
	local m = model("Neon Star")
	local h0 = K.plinth(m, 1.8, 1.0, P.NeonPink, 0.45)
	cylY(m, "Pole", 0.2, 2.2, Vector3.new(0, h0 + 1.1, 0), P.Gold, { solid = true, reflectance = 0.2 })
	cylY(m, "PoleCap", 0.34, 0.16, Vector3.new(0, h0 + 2.2, 0), D.Lacquer)
	local R = 1.4
	local c = Vector3.new(0, h0 + 2.2 + R * 0.95, 0)
	local spin = K.spinner(m, "Star", 32)
	local core = part(spin, "Core", Vector3.new(0.3, 0.3, 0.3), CFrame.new(c), P.White, { transparency = 1, shadow = false })
	spin.PrimaryPart = core
	uprightStar(spin, "StarFace", c, R, 0.18, hex("#3A0F6A"), { reflectance = 0.12 })
	local pts = starCorners(c, R)
	for k = 1, 10 do
		local a, b = pts[k], pts[k % 10 + 1]
		rod(spin, "StarNeon", a, b, 0.14, P.NeonPink, { material = Enum.Material.Neon, shadow = false })
	end
	for k = 1, 10, 2 do
		ball(spin, "StarTip", 0.2, pts[k], P.GoldTop, { material = Enum.Material.Neon, shadow = false })
	end
	cylZ(spin, "StarHub", 0.56, 0.3, c, P.Gold, GOLD_SHINE)
	new("PointLight", { Name = "StarLight", Color = P.NeonPink, Range = 12, Brightness = 1.2, Shadows = false }, core)
	return m
end

-- a Hollywood premiere searchlight: a big drum on a yoke, aimed up and out
local function searchlight()
	local m = model("Hollywood Spotlight")
	local h0 = K.plinth(m, 2.6, 2.6, P.Amber, 0.5)
	cylY(m, "Turntable", 2.0, 0.28, Vector3.new(0, h0 + 0.14, 0), D.Lacquer, { solid = true, reflectance = 0.15 })
	cylY(m, "TurntableRim", 2.1, 0.08, Vector3.new(0, h0 + 0.3, 0), P.Gold, GOLD_SHINE)
	local pivot = Vector3.new(0, h0 + 1.9, 0)
	for _, sx in { -1, 1 } do
		gold(m, "Yoke", Vector3.new(0.24, 1.75, 0.5), CFrame.new(sx * 1.18, h0 + 1.2, 0))
	end
	cylX(m, "Axle", 0.32, 2.62, pivot, P.Chrome, { reflectance = 0.3, material = Enum.Material.Metal })
	local dir = Vector3.new(0, math.sin(rad(52)), -math.cos(rad(52)))
	local back, front = pivot - dir * 1.0, pivot + dir * 1.35
	rod(m, "Drum", back, front, 1.9, hex("#2E2A30"), { solid = true, reflectance = 0.12, material = Enum.Material.Metal })
	for _, p in { back, front - dir * 0.05 } do
		rod(m, "DrumBand", p - dir * 0.08, p + dir * 0.08, 2.02, P.Chrome, { reflectance = 0.3, material = Enum.Material.Metal })
	end
	rod(m, "DrumCap", back - dir * 0.25, back, 1.2, hex("#2E2A30"), { material = Enum.Material.Metal })
	local lens = rod(m, "Lens", front, front + dir * 0.06, 1.72, P.Cream, { material = Enum.Material.Neon, shadow = false })
	new("SpotLight", { Name = "Beam", Face = Enum.NormalId.Right, Angle = 38, Range = 40, Brightness = 3.5,
		Color = D.WarmLight, Shadows = false }, lens)
	-- the light shaft: a soft beam fading out toward the ceiling
	local a0 = new("Attachment", { Name = "ShaftStart", CFrame = CFrame.new(0.05, 0, 0) }, lens)
	local a1 = new("Attachment", { Name = "ShaftEnd", CFrame = CFrame.new(13, 0, 0) }, lens)
	new("Beam", {
		Name = "Shaft", Attachment0 = a0, Attachment1 = a1, Width0 = 1.6, Width1 = 5.5, FaceCamera = true,
		LightEmission = 1, LightInfluence = 0, Segments = 1, Color = ColorSequence.new(D.WarmLight),
		Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.55), NumberSequenceKeypoint.new(1, 1) }),
	}, lens)
	return m
end

------------------------------------------------------------------
-- LOUNGE
------------------------------------------------------------------
-- a tufted crimson velvet bench on gold legs
local function velvetBench()
	local m = model("Velvet Bench")
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			cylY(m, "Leg", 0.16, 0.86, Vector3.new(sx * 1.82, 0.43 + 0.08, sz * 0.52), P.Gold, { solid = true, reflectance = 0.2 })
			ball(m, "Foot", 0.24, Vector3.new(sx * 1.82, 0.12, sz * 0.52), P.Gold, GOLD_SHINE)
		end
	end
	gold(m, "Frame", Vector3.new(4.16, 0.14, 1.44), CFrame.new(0, 0.95, 0))
	part(m, "Cushion", Vector3.new(4.06, 0.5, 1.34), CFrame.new(0, 1.27, 0), D.Velvet,
		{ solid = true, material = Enum.Material.Fabric })
	for _, sz in { -1, 1 } do
		gold(m, "Piping", Vector3.new(4.1, 0.06, 0.06), CFrame.new(0, 1.52, sz * 0.67))
	end
	for _, x in { -1.35, 0, 1.35 } do
		for _, z in { -0.3, 0.3 } do
			ball(m, "Button", 0.13, Vector3.new(x + ((z > 0) and 0.45 or 0), 1.52, z), P.Gold, GOLD_SHINE)
		end
	end
	return m
end

-- a high round cocktail table: marble top, drinks, chips and a candle
local function cocktailTable()
	local m = model("Cocktail Table")
	cylY(m, "Base", 1.4, 0.16, Vector3.new(0, 0.08, 0), D.Lacquer, { solid = true, reflectance = 0.15 })
	cylY(m, "BaseRing", 1.5, 0.06, Vector3.new(0, 0.17, 0), P.Gold, GOLD_SHINE)
	cylY(m, "Pedestal", 0.24, 2.72, Vector3.new(0, 0.2 + 1.36, 0), P.Gold, { solid = true, reflectance = 0.2 })
	ball(m, "Knot", 0.4, Vector3.new(0, 1.3, 0), P.Gold, GOLD_SHINE)
	cylY(m, "TopRing", 2.3, 0.1, Vector3.new(0, 2.97, 0), P.Gold, GOLD_SHINE)
	cylY(m, "Top", 2.2, 0.14, Vector3.new(0, 3.0, 0), D.Marble, { solid = true, material = Enum.Material.Marble })
	local y = 3.07
	-- a martini (pink) and a flute (gold)
	local glass = { transparency = 0.45, reflectance = 0.2, shadow = false }
	cylY(m, "Stem", 0.06, 0.32, Vector3.new(0.5, y + 0.16, 0.2), D.Glass, table.clone(glass))
	cylY(m, "Cup", 0.5, 0.07, Vector3.new(0.5, y + 0.35, 0.2), D.Glass, table.clone(glass))
	cylY(m, "Drink", 0.4, 0.075, Vector3.new(0.5, y + 0.35, 0.2), hex("#FF6FB5"), { transparency = 0.1, shadow = false })
	ball(m, "Olive", 0.1, Vector3.new(0.58, y + 0.41, 0.18), hex("#7BBF3A"))
	cylY(m, "Flute", 0.17, 0.52, Vector3.new(-0.35, y + 0.26, 0.45), D.Glass, table.clone(glass))
	cylY(m, "Bubbly", 0.13, 0.34, Vector3.new(-0.35, y + 0.2, 0.45), P.GoldTop, { transparency = 0.2, shadow = false })
	-- poker chips + the candle
	K.chipStack(m, Vector3.new(-0.52, y, -0.32), 3, P.Crimson)
	K.chipStack(m, Vector3.new(-0.2, y, -0.55), 2, D.Charcoal)
	cylY(m, "CandleCup", 0.22, 0.14, Vector3.new(0.38, y + 0.07, -0.45), P.Gold, GOLD_SHINE)
	local flame = ball(m, "Flame", 0.13, Vector3.new(0.38, y + 0.2, -0.45), P.Amber, { material = Enum.Material.Neon, shadow = false })
	new("PointLight", { Name = "CandleLight", Color = P.Amber, Range = 7, Brightness = 0.8, Shadows = false }, flame)
	return m
end

-- a royal-purple chesterfield sofa with gold tufting and a pink underglow
local function loungeSofa()
	local m = model("VIP Lounge Sofa")
	local royal = { material = Enum.Material.Fabric }
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			cylY(m, "Leg", 0.22, 0.36, Vector3.new(sx * 2.55, 0.18, sz * 0.92), P.Gold, { solid = true, reflectance = 0.2 })
		end
	end
	part(m, "Base", Vector3.new(5.6, 0.7, 2.3), CFrame.new(0, 0.71, 0), D.Royal, { solid = true, material = Enum.Material.Fabric })
	neon(m, "Underglow", Vector3.new(5.2, 0.06, 0.05), CFrame.new(0, 0.42, -1.18), P.NeonPink)
	gold(m, "Piping", Vector3.new(5.64, 0.07, 0.07), CFrame.new(0, 1.06, -1.15))
	for i = -1, 1 do
		part(m, "SeatCushion", Vector3.new(1.62, 0.32, 1.7), CFrame.new(i * 1.66, 1.22, -0.22), D.RoyalLight, table.clone(royal))
	end
	part(m, "Back", Vector3.new(5.0, 1.36, 0.56), CFrame.new(0, 1.74, 0.86), D.Royal, { solid = true, material = Enum.Material.Fabric })
	gold(m, "BackPiping", Vector3.new(5.04, 0.07, 0.07), CFrame.new(0, 2.42, 0.58))
	for _, y in { 1.62, 2.1 } do
		for _, x in { -1.8, -0.6, 0.6, 1.8 } do
			ball(m, "Button", 0.12, Vector3.new(x + ((y > 2) and 0.3 or 0), y, 0.575), P.Gold, GOLD_SHINE)
		end
	end
	for _, sx in { -1, 1 } do
		part(m, "Arm", Vector3.new(0.62, 0.62, 2.3), CFrame.new(sx * 2.62, 1.37, 0), D.Royal, { solid = true, material = Enum.Material.Fabric })
		cylZ(m, "ArmRoll", 0.72, 2.3, Vector3.new(sx * 2.62, 1.68, 0), D.Royal, table.clone(royal))
		cylZ(m, "ArmCap", 0.52, 0.06, Vector3.new(sx * 2.62, 1.68, -1.17), P.Gold, GOLD_SHINE)
	end
	return m
end

-- two gold stanchions with a sagging crimson velvet rope
local function velvetRope()
	local m = model("Velvet Rope")
	for _, sx in { -1, 1 } do
		local x = sx * 1.7
		cylY(m, "PostBase", 0.72, 0.12, Vector3.new(x, 0.06, 0), P.Gold, { solid = true, reflectance = 0.2 })
		ball(m, "PostDome", 0.46, Vector3.new(x, 0.24, 0), P.Gold, GOLD_SHINE)
		cylY(m, "Post", 0.14, 2.0, Vector3.new(x, 1.12, 0), P.Gold, { solid = true, reflectance = 0.25 })
		ball(m, "PostTop", 0.32, Vector3.new(x, 2.24, 0), P.Gold, GOLD_SHINE)
	end
	local pts = {
		Vector3.new(1.62, 1.98, 0), Vector3.new(0.82, 1.7, 0), Vector3.new(0, 1.6, 0),
		Vector3.new(-0.82, 1.7, 0), Vector3.new(-1.62, 1.98, 0),
	}
	for i = 1, 4 do
		rod(m, "Rope", pts[i], pts[i + 1], 0.17, D.Velvet, { solid = true, material = Enum.Material.Fabric })
	end
	for i = 2, 4 do
		ball(m, "RopeJoint", 0.17, pts[i], D.Velvet, { material = Enum.Material.Fabric })
	end
	for _, i in { 1, 5 } do
		ball(m, "RopeEnd", 0.24, pts[i], P.Gold, GOLD_SHINE)
	end
	return m
end

------------------------------------------------------------------
-- SHOWPIECES
------------------------------------------------------------------
-- two big translucent casino dice, the top one balanced on a corner
local function giantDice()
	local m = model("Giant Dice")
	local h0 = K.plinth(m, 2.8, 2.8, P.NeonRed, 0.4)
	local s1, s2 = 1.7, 1.2
	bigDie(m, "Die", s1, CFrame.new(0, h0 + s1 / 2, 0) * CFrame.Angles(0, rad(18), 0), hex("#E8213A"), P.White)
	local top = h0 + s1
	bigDie(m, "Die", s2, CFrame.new(0, top + s2 * math.sqrt(3) / 2, 0) * CFrame.Angles(0, rad(-25), 0) * ON_CORNER,
		hex("#E8213A"), P.White)
	return m
end

-- a two-tier marble wishing fountain with a water jet, coins and a cyan glow
local function miniFountain()
	local m = model("Mini Fountain")
	cylY(m, "Basin", 4.8, 0.8, Vector3.new(0, 0.4, 0), D.Marble, { solid = true, material = Enum.Material.Marble })
	cylY(m, "BasinRim", 5.0, 0.12, Vector3.new(0, 0.86, 0), P.Gold, GOLD_SHINE)
	local water = cylY(m, "Water", 4.5, 0.06, Vector3.new(0, 0.95, 0), D.Water,
		{ transparency = 0.18, reflectance = 0.25, shadow = false })
	new("PointLight", { Name = "PoolLight", Color = D.Water, Range = 10, Brightness = 1.1, Shadows = false }, water)
	for k = 0, 6 do
		local a = rad(k * 51 + 20)
		local r = 1.25 + (k % 3) * 0.3
		cylY(m, "Coin", 0.26, 0.03, Vector3.new(math.cos(a) * r, 0.955, math.sin(a) * r), P.Gold, { shadow = false })
	end
	cylY(m, "Pedestal", 0.9, 1.6, Vector3.new(0, 0.92 + 0.8, 0), D.Marble, { solid = true, material = Enum.Material.Marble })
	cylY(m, "PedestalBand", 0.98, 0.12, Vector3.new(0, 1.62, 0), P.Gold, GOLD_SHINE)
	cylY(m, "Curtain", 2.0, 1.56, Vector3.new(0, 0.98 + 0.78, 0), D.WaterLight, { transparency = 0.72, shadow = false })
	cylY(m, "Bowl", 2.2, 0.3, Vector3.new(0, 2.67, 0), D.Marble, { material = Enum.Material.Marble })
	cylY(m, "BowlRim", 2.34, 0.08, Vector3.new(0, 2.86, 0), P.Gold, GOLD_SHINE)
	cylY(m, "BowlWater", 2.04, 0.05, Vector3.new(0, 2.92, 0), D.Water, { transparency = 0.18, reflectance = 0.25, shadow = false })
	cylY(m, "Stand", 0.36, 0.6, Vector3.new(0, 3.24, 0), P.Gold, GOLD_SHINE)
	ball(m, "Finial", 0.5, Vector3.new(0, 3.72, 0), P.Gold, GOLD_SHINE)
	local spout = cylY(m, "Spout", 0.12, 0.3, Vector3.new(0, 4.06, 0), P.Gold)
	new("ParticleEmitter", {
		Name = "Jet", EmissionDirection = Enum.NormalId.Right, Rate = 38, Speed = NumberRange.new(6.5, 8),
		SpreadAngle = Vector2.new(9, 9), Acceleration = Vector3.new(0, -18, 0), Lifetime = NumberRange.new(0.75, 0.95),
		Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(1, 0.08) }),
		Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.15), NumberSequenceKeypoint.new(1, 0.7) }),
		Color = ColorSequence.new(Color3.new(1, 1, 1), D.WaterLight), LightEmission = 0.5,
	}, spout)
	return m
end

-- the casino's lucky lion: a sitting golden lion on a black pedestal
local function goldenLion()
	local m = model("Golden Lion")
	local PW, PH, PD = 2.8, 1.4, 4.2
	part(m, "Pedestal", Vector3.new(PW, PH, PD), CFrame.new(0, PH / 2, 0), D.Lacquer,
		{ solid = true, material = Enum.Material.Marble, reflectance = 0.1 })
	gold(m, "PedestalLip", Vector3.new(PW + 0.12, 0.12, PD + 0.12), CFrame.new(0, PH + 0.02, 0))
	gold(m, "PedestalFoot", Vector3.new(PW + 0.12, 0.14, PD + 0.12), CFrame.new(0, 0.07, 0))
	neon(m, "Underglow", Vector3.new(PW - 0.4, 0.06, 0.05), CFrame.new(0, 0.22, -PD / 2 - 0.03), P.Amber)
	K.boardSign(m, "Plaque", Vector3.new(1.9, 0.52, 0.08), CFrame.new(0, 0.78, -PD / 2 - 0.04), "LUCKY LION",
		{ ppu = 110, stroke = 4 })
	local g = { reflectance = 0.22 }
	local mane = { reflectance = 0.18 }
	local y0 = PH + 0.08
	-- body: haunches at the back, the chest up front
	ball(m, "Haunch", 1.6, Vector3.new(0, y0 + 0.62, 0.85), P.Gold, { solid = true, reflectance = 0.22 })
	for _, sx in { -1, 1 } do
		ball(m, "Thigh", 0.95, Vector3.new(sx * 0.56, y0 + 0.42, 0.55), P.Gold, table.clone(g))
		ball(m, "HindPaw", 0.42, Vector3.new(sx * 0.56, y0 + 0.16, -0.05), P.Gold, table.clone(g))
	end
	rod(m, "Torso", Vector3.new(0, y0 + 0.75, 0.75), Vector3.new(0, y0 + 1.55, -0.45), 1.28, P.Gold, table.clone(g))
	ball(m, "Chest", 1.28, Vector3.new(0, y0 + 1.42, -0.55), P.Gold, table.clone(g))
	for _, sx in { -1, 1 } do
		cylY(m, "Foreleg", 0.4, 1.3, Vector3.new(sx * 0.38, y0 + 0.65, -0.88), P.Gold, table.clone(g))
		ball(m, "Paw", 0.48, Vector3.new(sx * 0.38, y0 + 0.2, -1.02), P.Gold, table.clone(g))
	end
	-- the tail curls up beside the haunch, ending in a tuft
	rod(m, "Tail", Vector3.new(0.3, y0 + 0.25, 1.55), Vector3.new(0.85, y0 + 0.2, 1.2), 0.18, P.Gold, table.clone(g))
	rod(m, "Tail", Vector3.new(0.85, y0 + 0.2, 1.2), Vector3.new(1.05, y0 + 0.75, 0.75), 0.16, P.Gold, table.clone(g))
	ball(m, "TailTuft", 0.34, Vector3.new(1.05, y0 + 0.82, 0.72), P.GoldDeep, table.clone(mane))
	-- head + mane
	local H = Vector3.new(0, y0 + 2.42, -0.86)
	ball(m, "Mane", 1.4, H + Vector3.new(0, -0.02, 0.3), P.GoldDeep, table.clone(mane))
	for k = 0, 9 do
		local a = rad(k * 36)
		ball(m, "ManeTuft", 0.62, H + Vector3.new(math.cos(a) * 0.62, math.sin(a) * 0.62, 0.12), P.GoldDeep, table.clone(mane))
	end
	ball(m, "Head", 0.92, H + Vector3.new(0, 0, -0.12), P.Gold, table.clone(g))
	ball(m, "Muzzle", 0.5, H + Vector3.new(0, -0.18, -0.5), P.GoldTop, table.clone(g))
	ball(m, "Nose", 0.2, H + Vector3.new(0, -0.05, -0.72), P.GoldDeep, table.clone(mane))
	for _, sx in { -1, 1 } do
		ball(m, "Cheek", 0.36, H + Vector3.new(sx * 0.17, -0.25, -0.48), P.GoldTop, table.clone(g))
		ball(m, "Eye", 0.12, H + Vector3.new(sx * 0.2, 0.14, -0.53), P.Ink)
		ball(m, "Ear", 0.3, H + Vector3.new(sx * 0.36, 0.42, 0.0), P.Gold, table.clone(g))
	end
	-- a little crown: the king of the casino
	local cy = H.Y + 0.58
	cylY(m, "Crown", 0.62, 0.2, Vector3.new(H.X, cy, H.Z - 0.05), P.Gold, { reflectance = 0.3 })
	for k = 0, 4 do
		local a = rad(k * 72 + 90)
		local p = Vector3.new(H.X + math.cos(a) * 0.26, cy + 0.08, H.Z - 0.05 + math.sin(a) * 0.26)
		spike(m, "CrownPoint", 0.18, 0.24, 0.05, CFrame.lookAt(p, Vector3.new(H.X, cy + 0.08, H.Z - 0.05)) * CFrame.Angles(0, rad(180), 0),
			P.Gold, { reflectance = 0.3 })
	end
	ball(m, "CrownGem", 0.14, Vector3.new(H.X, cy + 0.06, H.Z - 0.37), P.NeonRed, { material = Enum.Material.Neon, shadow = false })
	return m
end

-- a walk-through arch of party balloons with a JACKPOT! sign
local function balloonArch()
	local m = model("Balloon Arch")
	local half = 3.25
	for _, sx in { -1, 1 } do
		part(m, "Weight", Vector3.new(0.9, 0.5, 0.9), CFrame.new(sx * half, 0.25, 0), D.Lacquer, { solid = true, reflectance = 0.15 })
		gold(m, "WeightTop", Vector3.new(0.96, 0.08, 0.96), CFrame.new(sx * half, 0.52, 0))
	end
	local cols = { P.Gold, P.Crimson, P.White, hex("#FF5FA2"), P.Gold, hex("#8A4DE8") }
	local n = 13
	for i = 0, n - 1 do
		local th = rad(180 * i / (n - 1))
		local c = Vector3.new(half * math.cos(th), 0.95 + 5.5 * math.sin(th), 0)
		-- the arch's outward normal in the XY plane
		local nrm = Vector3.new(math.cos(th) / half, math.sin(th) / 5.5, 0).Unit
		for k = 0, 2 do
			local phi = rad(120 * k + 60 * i)
			local off = nrm * math.cos(phi) * 0.3 + Vector3.new(0, 0, 1) * math.sin(phi) * 0.3
			ball(m, "Balloon", 0.86, c + off, cols[(i + k) % #cols + 1], { reflectance = 0.18 })
		end
	end
	-- the sign hangs from the top of the arch
	local top = 0.95 + 5.5
	for _, sx in { -1, 1 } do
		cylY(m, "String", 0.04, 0.6, Vector3.new(sx * 0.8, top - 0.75, -0.05), P.GoldTop, { shadow = false })
	end
	K.boardSign(m, "Sign", Vector3.new(2.4, 0.72, 0.14), CFrame.new(0, top - 1.35, -0.05), "JACKPOT!",
		{ bothSides = true, ppu = 100, stroke = 5 })
	return m
end

------------------------------------------------------------------
-- GOLDEN (rebirth rewards)
------------------------------------------------------------------
-- a gold carpet with crimson borders and chasing bulbs (chains like the red carpet)
local function goldenWalkway()
	local m = model("Golden Walkway")
	local bulbs = new("Folder", { Name = "Bulbs" }, m)
	local body = part(m, "Carpet", Vector3.new(3.5, 0.14, 8), CFrame.new(0, 0.07, 0), P.GoldDeep, { reflectance = 0.16 })
	m.PrimaryPart = body
	for _, sx in { -1, 1 } do
		part(m, "Border", Vector3.new(0.25, 0.17, 8), CFrame.new(sx * 1.875, 0.085, 0), P.CrimsonDeep, { reflectance = 0.08 })
		gold(m, "Pinstripe", Vector3.new(0.06, 0.15, 8), CFrame.new(sx * 1.5, 0.075, 0))
		for i = 0, 5 do
			local b = ball(bulbs, "Bulb", 0.18, Vector3.new(sx * 1.875, 0.1, -3.33 + i * 1.333), (i % 2 == 0) and P.GoldTop or P.White,
				{ material = Enum.Material.Neon, shadow = false })
			b:SetAttribute("Phase", i % 2)
		end
	end
	for i = -1, 1 do
		part(m, "Diamond", Vector3.new(0.62, 0.155, 0.62), CFrame.new(0, 0.0775, i * 8 / 3) * CFrame.Angles(0, rad(45), 0),
			P.Crimson, { reflectance = 0.1 })
		gold(m, "DiamondCore", Vector3.new(0.3, 0.16, 0.3), CFrame.new(0, 0.08, i * 8 / 3) * CFrame.Angles(0, rad(45), 0))
	end
	return m
end

-- a giant golden lucky 7 on a two-step plinth ringed with bulbs
local function goldenSeven()
	local m = model("Golden 7")
	local bulbs = new("Folder", { Name = "Bulbs" }, m)
	local h0 = K.plinth(m, 2.8, 2.0, P.NeonRed, 0.6)
	part(m, "Step", Vector3.new(2.2, 0.4, 1.4), CFrame.new(0, h0 + 0.2, 0), D.Lacquer, { solid = true, reflectance = 0.14 })
	gold(m, "StepLip", Vector3.new(2.28, 0.08, 1.48), CFrame.new(0, h0 + 0.42, 0))
	local base = h0 + 0.46
	-- the glyph, front face at z = -0.3; the viewer's right is model -X: the
	-- stem drops from the top bar's right end to the bottom left of centre
	local function seven(parent, grow: number, z: number, depth: number, color: Color3, opts)
		part(parent, "SevenTop", Vector3.new(2.4 + grow, 0.72 + grow, depth), CFrame.new(0, base + 5.0, z), color, table.clone(opts))
		local a = Vector3.new(-0.78, base + 4.95, z)
		local b = Vector3.new(0.32, base + 0.0, z)
		local len = (b - a).Magnitude
		local mid = (a + b) / 2
		local tilt = math.atan2(b.X - a.X, a.Y - b.Y)
		part(parent, "SevenStem", Vector3.new(0.78 + grow, len + grow * 0.5, depth), CFrame.new(mid) * CFrame.Angles(0, 0, tilt),
			color, table.clone(opts))
		part(parent, "SevenSerif", Vector3.new(0.34 + grow, 0.62 + grow, depth), CFrame.new(1.03, base + 4.5, z), color,
			table.clone(opts))
	end
	seven(m, 0.26, 0.12, 0.5, P.Crimson, { reflectance = 0.1, solid = true })
	seven(m, 0, -0.02, 0.6, P.Gold, { reflectance = 0.28 })
	-- bulbs round the plinth's top edge
	K.bulbsAlong(bulbs, Vector3.new(-1.3, h0 + 0.06, -1.06), Vector3.new(1.3, h0 + 0.06, -1.06), 9, 0.18)
	K.bulbsAlong(bulbs, Vector3.new(-1.3, h0 + 0.06, 1.06), Vector3.new(1.3, h0 + 0.06, 1.06), 9, 0.18)
	for _, sx in { -1, 1 } do
		K.bulbsAlong(bulbs, Vector3.new(sx * 1.46, h0 + 0.06, -0.75), Vector3.new(sx * 1.46, h0 + 0.06, 0.75), 5, 0.18)
	end
	local glowAt = part(m, "GlowPoint", Vector3.new(0.2, 0.2, 0.2), CFrame.new(0, base + 3.0, -1.2), P.White,
		{ transparency = 1, shadow = false })
	new("PointLight", { Name = "SevenLight", Color = P.GoldTop, Range = 12, Brightness = 1.3, Shadows = false }, glowAt)
	return m
end

-- a giant glowing diamond turning on a velvet cushion atop a black column
local function megaDiamond()
	local m = model("Mega Diamond")
	local h0 = K.plinth(m, 3.0, 3.0, P.NeonBlue, 0.5)
	cylY(m, "ColumnFoot", 1.7, 0.18, Vector3.new(0, h0 + 0.09, 0), P.Gold, GOLD_SHINE)
	cylY(m, "Column", 1.4, 2.3, Vector3.new(0, h0 + 0.18 + 1.15, 0), D.Lacquer, { solid = true, reflectance = 0.16 })
	cylY(m, "ColumnNeon", 1.46, 0.08, Vector3.new(0, h0 + 1.3, 0), P.NeonBlue, { material = Enum.Material.Neon, shadow = false })
	cylY(m, "ColumnHead", 1.7, 0.18, Vector3.new(0, h0 + 2.48 + 0.09, 0), P.Gold, GOLD_SHINE)
	local cy = h0 + 2.66
	part(m, "Cushion", Vector3.new(1.6, 0.32, 1.6), CFrame.new(0, cy + 0.16, 0), P.Crimson, { material = Enum.Material.Fabric })
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			ball(m, "Tassel", 0.2, Vector3.new(sx * 0.8, cy + 0.12, sz * 0.8), P.Gold, GOLD_SHINE)
		end
	end
	local r, depth = 1.34, 1.48
	local gemC = Vector3.new(0, cy + 0.36 + depth, 0)
	local spin = K.spinner(m, "Gem", 22)
	local core = ball(spin, "GemCore", 0.85, gemC - Vector3.new(0, 0.3, 0), D.WaterLight,
		{ material = Enum.Material.Neon, shadow = false })
	spin.PrimaryPart = core
	brilliant(spin, gemC, r, depth, hex("#8FE9FF"))
	new("PointLight", { Name = "GemLight", Color = P.NeonBlue, Range = 14, Brightness = 1.8, Shadows = false }, core)
	new("ParticleEmitter", {
		Name = "Sparkle", Rate = 5, Lifetime = NumberRange.new(0.8, 1.4), Speed = NumberRange.new(0.4, 1.2),
		SpreadAngle = Vector2.new(180, 180), LightEmission = 1, Color = ColorSequence.new(P.White, D.WaterLight),
		Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.45), NumberSequenceKeypoint.new(1, 0) }),
	}, core)
	return m
end

------------------------------------------------------------------
-- registry (Config.Decor `model` -> builder)
------------------------------------------------------------------
local BUILDERS = {
	FernPlanter = fernPlanter,
	PottedPalm = function() return palmTree() end,
	DesertCactus = desertCactus,
	FlowerBed = flowerBed,
	TopiaryHedge = topiaryHedge,
	CherryBonsai = cherryBonsai,
	RedCarpet = redCarpet,
	MarbleTile = marbleTile,
	CheckerTile = checkerTile,
	RoyalRug = royalRug,
	NeonWalkway = neonWalkway,
	FameStar = fameStar,
	DecoLamp = decoLamp,
	NeonStar = neonStarSign,
	Searchlight = searchlight,
	VelvetBench = velvetBench,
	CocktailTable = cocktailTable,
	LoungeSofa = loungeSofa,
	VelvetRope = velvetRope,
	GiantDice = giantDice,
	MiniFountain = miniFountain,
	GoldenLion = goldenLion,
	BalloonArch = balloonArch,
	GoldenPalm = function()
		return palmTree({
			name = "Golden Palm", pot = D.Lacquer, potTrim = P.Gold, band = P.NeonRed, soil = P.GoldDeep,
			bark = P.Gold, barkDark = P.GoldDeep, ring = P.GoldTop, trunkGloss = 0.25,
			leaf = P.Gold, leafLight = P.GoldTop, hub = P.GoldDeep, leafGloss = 0.25,
			gems = P.NeonRed, glow = P.Amber,
		})
	end,
	GoldenWalkway = goldenWalkway,
	GoldenSeven = goldenSeven,
	MegaDiamond = megaDiamond,
}

function DecorModels.has(name: string?): boolean
	return name ~= nil and BUILDERS[name] ~= nil
end

-- Pivot on the ground origin, make every visible part clickable (build mode
-- picks decor up by clicking it), flat pieces walk-through, and note the rigs.
local function finalize(m: Model, def)
	m.WorldPivot = CFrame.new()
	local primary = m.PrimaryPart
	if not primary then
		for _, c in m:GetChildren() do
			if c:IsA("BasePart") and c.Transparency < 1 then
				primary = c
				break
			end
		end
		m.PrimaryPart = primary
	end
	if primary then primary.PivotOffset = primary.CFrame:Inverse() end
	local animated = m:FindFirstChild("Bulbs") ~= nil
	for _, d in m:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanTouch = false
			if def.flat then d.CanCollide = false end
			d.CanQuery = d.Transparency < 0.95
		elseif d:IsA("Model") and d:GetAttribute("SpinRate") then
			animated = true
		end
	end
	m:SetAttribute("Flat", def.flat == true)
	if animated then m:SetAttribute("Animated", true) end
end

-- built once per decor id, cloned after that
local cache: {[string]: Model} = {}

-- Build (or clone) the model for a Config.Decor def; nil if it has no builder.
function DecorModels.build(def): Model?
	local fn = def and def.model and BUILDERS[def.model]
	if not fn then return nil end
	local key = tostring(def.id or def.model)
	local cached = cache[key]
	if cached then return cached:Clone() end
	local ok, m = pcall(fn, def)
	if not ok or not m then
		warn("[DecorModels] building " .. tostring(def.model) .. " failed: " .. tostring(m))
		return nil
	end
	m.Name = def.name or m.Name
	finalize(m, def)
	cache[key] = m
	return m:Clone()
end

return DecorModels
