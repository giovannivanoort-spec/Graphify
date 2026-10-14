--!nonstrict
-- MapBuilder.luau — builds the "Vegas Strip" map INTO THE PLACE. Edit-time
-- tool: the running game never requires it. Run it from the command bar:
--
--   require(game.ServerStorage.MapTools.MapBuilder:Clone()).build()
--
-- It moves the old flat map into ServerStorage.LegacyMap (once), then rebuilds
-- Workspace.Map and Workspace.Plots from scratch and returns a short report.
--
-- Layout (x runs along the Strip, the sunset glow sits west):
--   west  : Showroom building (built at runtime by Showroom.luau, x ≈ -176)
--   middle: boulevard with a palm median + fountain pool, 3 casinos on each side
--   east  : Welcome Plaza — spawn, welcome sign, leaderboard, kiosks, services
--   around: back streets, resort towers, observation wheel, LED sphere, mountains

local ServerStorage = game:GetService("ServerStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MaterialService = game:GetService("MaterialService")
local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")

local MapBuilder = {}

-- the command bar / plugin VM caches required modules: clone for a fresh copy
local function fresh(module: ModuleScript)
	return require(module:Clone())
end

local L = {
	StripX0 = -150, StripX1 = 150,  -- road ends: showroom forecourt / plaza
	RoadHalf = 23,                   -- road |z| <= 23 (two lanes each way)
	MedianHalf = 5,
	WalkOuter = 35,                  -- sidewalks 23..35, casino fronts at 35
	PlotW = 79, PlotD = 81,          -- same plot size as before: saved layouts fit
	PlotXs = { 0, 101, -101 },       -- assignment order: centre, east, west
	PoolX = 62,                      -- fountain pool spans |x| <= 62
	PlazaX0 = 150, PlazaX1 = 242, PlazaHalfZ = 64,
	ForecourtX0 = -160,
}
local Y = { City = 0.2, Road = 0.4, Walk = 0.8 }

local K, P, hex, Props, UIAssets

local function decor() return { shadow = false } end

-- pivot a freshly built prop at its model-space origin, parent it, place it
local function place(model: Model, parent: Instance, cf: CFrame): Model
	model.WorldPivot = CFrame.new()
	local primary = model.PrimaryPart
	if primary then primary.PivotOffset = primary.CFrame:Inverse() end
	model.Parent = parent
	model:PivotTo(cf)
	return model
end

local function folder(name: string, parent: Instance): Folder
	local f = Instance.new("Folder")
	f.Name = name
	f.Parent = parent
	return f
end

-- a flat slab from (x0,z0) to (x1,z1) whose top sits at `top`
local function slab(parent, name, x0, x1, z0, z1, top, thick, color, material, opts)
	opts = opts or {}
	opts.material = material
	local p = K.part(parent, name, Vector3.new(math.abs(x1 - x0), thick, math.abs(z1 - z0)),
		CFrame.new((x0 + x1) / 2, top - thick / 2, (z0 + z1) / 2), color, opts)
	return p
end

local function tagModel(model: Instance, tag: string)
	CollectionService:AddTag(model, tag)
	return model
end

-- small animated props stream as one piece so client FX find all their parts
local function atomic(model: Model)
	pcall(function() model.ModelStreamingMode = Enum.ModelStreamingMode.Atomic end)
	return model
end

------------------------------------------------------------------
-- 0) clear the old map
------------------------------------------------------------------
local function moveLegacy(report)
	local legacy = ServerStorage:FindFirstChild("LegacyMap") or folder("LegacyMap", ServerStorage)
	local moved = 0
	for _, child in Workspace:GetChildren() do
		local isOldPart = child:IsA("BasePart") and not child:IsA("Terrain")
			and (child.Name == "Part" or child.Name:lower() == "plot")
		local isJunk = child:IsA("Model") and child.Name:find("^A stylized cartoon") ~= nil
		if isOldPart or isJunk then
			child.Parent = legacy
			moved += 1
		end
	end
	for _, name in { "Map", "Plots" } do
		local old = Workspace:FindFirstChild(name)
		if old and old:GetAttribute("MapBuilder") then old:Destroy() end
	end
	local oldSpawn = Workspace:FindFirstChild("StripSpawn")
	if oldSpawn then oldSpawn:Destroy() end
	report.legacyMoved = moved
end

------------------------------------------------------------------
-- 1) materials: tower windows that glow through an emissive mask
------------------------------------------------------------------
local function windowVariants()
	local W = UIAssets.Windows
	for _, spec in {
		{ "CM_TowerWarm", W.WarmColor, W.WarmEmit, Color3.fromRGB(255, 214, 160), 36 },
		{ "CM_TowerCool", W.CoolColor, W.CoolEmit, Color3.fromRGB(190, 225, 255), 36 },
	} do
		local mv = MaterialService:FindFirstChild(spec[1]) or Instance.new("MaterialVariant")
		mv.Name = spec[1]
		mv.BaseMaterial = Enum.Material.Plastic
		mv.ColorMap = spec[2]
		local ok = pcall(function() mv.EmissiveMaskContent = Content.fromUri(spec[3]) end)
		if not ok then pcall(function() (mv :: any).EmissiveMaskContent = spec[3] end) end
		mv.EmissiveStrength = 4
		mv.EmissiveTint = spec[4]
		mv.StudsPerTile = spec[5]
		mv.Parent = MaterialService
	end
end

------------------------------------------------------------------
-- 2) ground, roads, sidewalks, markings
------------------------------------------------------------------
local function buildGround(map)
	local g = folder("Ground", map)
	-- desert all the way to the mountains (3x3 tiles of the 2048 part limit)
	for i = -1, 1 do
		for j = -1, 1 do
			K.part(g, "Desert", Vector3.new(2048, 2, 2048), CFrame.new(i * 2048, -1, j * 2048), hex("#4A3A33"),
				{ material = Enum.Material.Sand, solid = (i == 0 and j == 0), shadow = false })
		end
	end
	slab(g, "CityPaving", -320, 320, -215, 215, Y.City, 0.4, hex("#3A3542"), Enum.Material.Concrete, { solid = true, shadow = false })
end

local function dashLine(parent, z, x0, x1, dash, gap, width, color, skip)
	local x = x0
	while x + dash <= x1 do
		local cx = x + dash / 2
		if not (skip and skip(cx)) then
			K.part(parent, "Marking", Vector3.new(dash, 0.04, width), CFrame.new(cx, Y.Road + 0.02, z), color, decor())
		end
		x += dash + gap
	end
end

local CROSSWALKS = { -50.5, 50.5, 143 }
local function nearCrosswalk(x) for _, c in CROSSWALKS do if math.abs(x - c) < 6 then return true end end return false end

local function buildStrip(map)
	local s = folder("Strip", map)
	local white, yellow = hex("#E8E6F0"), hex("#F2C230")
	slab(s, "Road", L.StripX0, L.StripX1, -L.RoadHalf, L.RoadHalf, Y.Road, 0.4, hex("#1F1D26"),
		Enum.Material.Asphalt, { solid = true, shadow = false })
	local marks = folder("Markings", s)
	for _, sz in { -1, 1 } do
		dashLine(marks, sz * 14, L.StripX0 + 4, L.StripX1 - 4, 6, 6, 0.35, white, nearCrosswalk)
		K.part(marks, "EdgeLine", Vector3.new(L.StripX1 - L.StripX0 - 2, 0.04, 0.35),
			CFrame.new(0, Y.Road + 0.02, sz * (L.RoadHalf - 0.8)), white, decor())
		for _, dz in { 0, 0.55 } do
			K.part(marks, "CenterLine", Vector3.new(L.StripX1 - L.StripX0 - 2, 0.04, 0.25),
				CFrame.new(0, Y.Road + 0.02, sz * (L.MedianHalf + 0.6 + dz)), yellow, decor())
		end
	end
	for _, cx in CROSSWALKS do
		for z = -L.RoadHalf + 1.6, L.RoadHalf - 1.6, 3.2 do
			if math.abs(z) > L.MedianHalf + 0.6 then
				K.part(marks, "Crosswalk", Vector3.new(8, 0.04, 1.6), CFrame.new(cx, Y.Road + 0.025, z), white, decor())
			end
		end
	end

	-- sidewalks + curbs (west end meets the showroom forecourt)
	for _, sz in { -1, 1 } do
		local z0, z1 = sz * L.RoadHalf, sz * L.WalkOuter
		slab(s, "Sidewalk", L.StripX0, L.StripX1, math.min(z0, z1), math.max(z0, z1), Y.Walk, 0.8, hex("#6C6577"),
			Enum.Material.Pavement, { solid = true, shadow = false })
		-- a hair wider than 0.5 so its road face never z-fights the sidewalk's
		K.part(s, "Curb", Vector3.new(L.StripX1 - L.StripX0, 0.84, 0.54),
			CFrame.new(0, 0.42, sz * (L.RoadHalf + 0.25)), hex("#A39EAD"), { material = Enum.Material.Concrete, shadow = false })
	end

	-- median: raised planter strips with grass, and a fountain pool in the middle
	local med = folder("Median", s)
	local stone = hex("#8E879A")
	for _, side in { -1, 1 } do
		local a, b = side * (L.PoolX + 1), side * (L.StripX1 - 2)
		slab(med, "MedianCurb", math.min(a, b), math.max(a, b), -L.MedianHalf, L.MedianHalf, 1.0, 0.6, stone,
			Enum.Material.Concrete, { solid = true, shadow = false })
		slab(med, "MedianGrass", math.min(a, b) + 0.5, math.max(a, b) - 0.5, -L.MedianHalf + 0.5, L.MedianHalf - 0.5, 1.06, 0.1,
			hex("#2E5A35"), Enum.Material.Grass, decor())
		-- pool rim: the long sides and this end
		K.part(med, "PoolRim", Vector3.new(0.7, 0.6, L.MedianHalf * 2), CFrame.new(side * (L.PoolX + 0.65), 0.7, 0), stone,
			{ material = Enum.Material.Concrete, solid = true, shadow = false })
		K.part(med, "PoolRim", Vector3.new(L.PoolX * 2 + 0.6, 0.6, 0.7), CFrame.new(0, 0.7, side * (L.MedianHalf - 0.35)), stone,
			{ material = Enum.Material.Concrete, solid = true, shadow = false })
		-- underwater light strips, seen through the water
		K.neon(med, "PoolGlow", Vector3.new(L.PoolX * 2, 0.1, 0.14), CFrame.new(0, 0.5, side * (L.MedianHalf - 0.85)), hex("#46D8FF"))
	end
	slab(med, "PoolFloor", -L.PoolX - 0.3, L.PoolX + 0.3, -L.MedianHalf + 0.7, L.MedianHalf - 0.7, 0.45, 0.05, hex("#10203A"),
		Enum.Material.SmoothPlastic, decor())
	slab(med, "PoolWater", -L.PoolX - 0.3, L.PoolX + 0.3, -L.MedianHalf + 0.7, L.MedianHalf - 0.7, 0.9, 0.05, hex("#1E5F9E"),
		Enum.Material.SmoothPlastic, { shadow = false, reflectance = 0.35, transparency = 0.25 })
	local jets = folder("FountainJets", med)
	for x = -54, 54, 9 do
		local jet = place(Props.fountainJet(10 + (math.abs(x) % 18) * 0.3), jets, CFrame.new(x, 0.45, 0))
		jet:SetAttribute("Order", (x + 54) / 108)
		tagModel(atomic(jet), "MapFountainJet")
	end
	-- palms + double lamps along the median
	local seed = 1
	for _, side in { -1, 1 } do
		for k = 0, 4 do
			local x = side * (L.PoolX + 8 + k * 19)
			place(Props.palm(seed, 21 + (seed % 3) * 2.5), med, CFrame.new(x, 1.0, 0))
			seed += 1
		end
		for _, x in { side * (L.PoolX + 3), side * (L.PoolX + 36.5), side * (L.PoolX + 74.5) } do
			place(Props.lamp(true), med, CFrame.new(x, 1.0, 0) * CFrame.Angles(0, math.rad(90), 0))
		end
	end

	-- sidewalk lamps (arm over the road), bins and benches
	local furn = folder("StreetFurniture", s)
	for _, sz in { -1, 1 } do
		for x = -125, 125, 50 do
			place(Props.lamp(false), furn, CFrame.new(x, Y.Walk, sz * (L.RoadHalf + 1.6)) * CFrame.Angles(0, math.rad(sz > 0 and 90 or -90), 0))
		end
		for _, x in { -100, 0, 100 } do
			place(Props.trashBin(), furn, CFrame.new(x + 14, Y.Walk, sz * (L.RoadHalf + 1.4)))
		end
	end
end

------------------------------------------------------------------
-- 3) the six casino plots (Plots.luau discovers Workspace.Plots/*)
------------------------------------------------------------------
local function buildPlot(plotsFolder, index, x, north)
	local zc = (north and 1 or -1) * (L.WalkOuter + L.PlotD / 2)
	local plotCF = CFrame.new(x, 0, zc) * CFrame.Angles(0, north and 0 or math.pi, 0) -- ground frame, front = local -Z
	local function at(lx, ly, lz, yaw) return plotCF * CFrame.new(lx, ly, lz) * CFrame.Angles(0, math.rad(yaw or 0), 0) end

	local m = Instance.new("Model")
	m.Name = "Plot" .. index
	local base = Instance.new("Part")
	base.Name = "Base"
	base.Anchored = true
	base.Size = Vector3.new(L.PlotW, 1, L.PlotD)
	base.CFrame = at(0, 0.5, 0)
	base.Material = Enum.Material.Fabric
	base.Color = hex("#1F2024")
	base.TopSurface = Enum.SurfaceType.Smooth
	base.BottomSurface = Enum.SurfaceType.Smooth
	base.Parent = m
	for _, face in { Enum.NormalId.Top, Enum.NormalId.Front, Enum.NormalId.Back, Enum.NormalId.Left, Enum.NormalId.Right } do
		K.new("Texture", { Name = "Carpet", Face = face, Texture = "rbxassetid://5077735191", StudsPerTileU = 4,
			StudsPerTileV = 4, Color3 = hex("#FF7C7C") }, base)
	end
	m.PrimaryPart = base
	local front = -L.PlotD / 2 -- local z of the casino front edge
	local ent = Instance.new("Attachment")
	ent.Name = "Entrance"
	ent.Position = Vector3.new(0, Y.Walk - 0.5, front - 8.5) -- on the sidewalk, in front of the carpet
	ent.Parent = base
	m:SetAttribute("PlotIndex", index)
	m.Parent = plotsFolder

	-- frontage sits inside the plot model: Plots.luau finds the pylon's
	-- "OwnerSign" there and writes the casino name onto it
	local f = folder("Frontage", m)
	local carpet = K.part(f, "RedCarpet", Vector3.new(8, 0.08, 11.6), at(0, Y.Walk + 0.04, front - 5.8), P.Crimson,
		{ material = Enum.Material.Fabric, shadow = false })
	local _ = carpet
	tagModel(place(Props.entranceArch(12), f, at(0, Y.Walk, front - 1.0)), "CasinoProp")
	for _, sx in { -1, 1 } do
		place(Props.stanchions(9), f, at(sx * 4.7, Y.Walk, front - 1.6))
	end
	tagModel(place(Props.pylon(), f, at(-33, Y.Walk, front - 6.5)), "CasinoProp")
	for _, sx in { -1, 1 } do
		place(Props.planter(30, 1.6), f, at(sx * 23.7, Y.Walk, front - 1.0))
	end
	-- low side + back walls (outside the plot so the build area stays clear)
	local wallCol = hex("#2E2838")
	for _, sx in { -1, 1 } do
		K.part(f, "SideWall", Vector3.new(0.8, 2.6, L.PlotD + 1.6), at(sx * (L.PlotW / 2 + 0.4), Y.City + 1.3, 0.8), wallCol,
			{ solid = true })
		K.gold(f, "WallCap", Vector3.new(1.0, 0.2, L.PlotD + 1.8), at(sx * (L.PlotW / 2 + 0.4), Y.City + 2.7, 0.8))
	end
	K.part(f, "BackWall", Vector3.new(L.PlotW + 1.6, 2.6, 0.8), at(0, Y.City + 1.3, L.PlotD / 2 + 1.2), wallCol, { solid = true })
	K.gold(f, "WallCap", Vector3.new(L.PlotW + 1.8, 0.2, 1.0), at(0, Y.City + 2.7, L.PlotD / 2 + 1.2))
	tagModel(place(Props.hoarding(L.PlotW), f, at(0, Y.City, L.PlotD / 2 + 7)), "CasinoProp")
	-- casino-floor wash: two big soft downlights hanging over the carpet
	for _, sx in { -1, 1 } do
		local anchor = K.part(f, "FloorLight", Vector3.new(0.5, 0.5, 0.5), at(sx * 20, 26, 0), P.White,
			{ transparency = 1, shadow = false })
		K.new("SpotLight", { Face = Enum.NormalId.Bottom, Angle = 120, Range = 60, Brightness = 1.25,
			Color = Color3.fromRGB(255, 218, 178), Shadows = false }, anchor)
	end
	-- a cab waiting at the curb
	local kinds = { "taxi", "limo", "taxi", "sport", "limo", "taxi" }
	local kind = kinds[index] or "taxi"
	place(Props.car(kind), f, at(index % 2 == 0 and 16 or -14, Y.Road, front - 12 - 6, 90))
end

local function buildAlleys(map)
	local a = folder("Alleys", map)
	for _, north in { true, false } do
		local sz = north and 1 or -1
		for _, cx in { (L.PlotXs[1] + L.PlotXs[2]) / 2, (L.PlotXs[1] + L.PlotXs[3]) / 2 } do
			local m = Instance.new("Model")
			m.Name = "AlleyLights"
			local bulbs = folder("Bulbs", m)
			local zFront, zBack = sz * (L.WalkOuter + 1), sz * (L.WalkOuter + L.PlotD - 2)
			for _, z in { zFront, zBack } do
				K.cylY(m, "Post", 0.5, 10, Vector3.new(cx, Y.City + 5, z), P.Gold, { reflectance = 0.15 })
			end
			Props.stringLights(bulbs, Vector3.new(cx, Y.City + 9.6, zFront), Vector3.new(cx, Y.City + 9.6, zBack), 2.2, 26)
			m.Parent = a
			tagModel(m, "CasinoProp")
		end
	end
end

------------------------------------------------------------------
-- 4) Welcome Plaza (east): spawn, sign, leaderboard, kiosks
------------------------------------------------------------------
local function buildPlaza(map, report)
	local p = folder("Plaza", map)
	slab(p, "PlazaFloor", L.PlazaX0, L.PlazaX1, -L.PlazaHalfZ, L.PlazaHalfZ, Y.Walk, 0.8, hex("#5B5468"),
		Enum.Material.Pavement, { solid = true, shadow = false })
	local cx = 200
	-- inlaid rings (stacked discs read as rings)
	K.cylY(p, "InlayNeon", 40, 0.05, Vector3.new(cx, Y.Walk + 0.025, 0), P.NeonPink, { material = Enum.Material.Neon, shadow = false })
	K.cylY(p, "InlayFill", 38.4, 0.06, Vector3.new(cx, Y.Walk + 0.03, 0), hex("#4A4357"), { material = Enum.Material.Pavement, shadow = false })
	K.cylY(p, "InlayGold", 22, 0.07, Vector3.new(cx, Y.Walk + 0.035, 0), P.Gold, { reflectance = 0.15, shadow = false })
	K.cylY(p, "InlayCore", 20.6, 0.08, Vector3.new(cx, Y.Walk + 0.04, 0), hex("#3E3849"), { material = Enum.Material.Pavement, shadow = false })
	for k = 0, 7 do
		local a = k * math.pi / 4
		local d = Vector3.new(math.cos(a), 0, math.sin(a))
		K.part(p, "InlayRay", Vector3.new(0.6, 0.06, 7), CFrame.lookAt(Vector3.new(cx, Y.Walk + 0.03, 0) + d * 15,
			Vector3.new(cx, Y.Walk + 0.03, 0) + d * 20), P.Gold, { reflectance = 0.15, shadow = false })
	end

	-- spawn medallion facing west, straight down the Strip
	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "StripSpawn"
	spawn.Anchored = true
	spawn.Size = Vector3.new(12, 0.1, 12)
	spawn.CFrame = CFrame.new(cx + 4, Y.Walk + 0.1, 0) * CFrame.Angles(0, math.rad(90), 0)
	spawn.Color = P.Gold
	spawn.Material = Enum.Material.SmoothPlastic
	spawn.Reflectance = 0.15
	spawn.Neutral = true
	spawn.Duration = 0
	spawn.AllowTeamChangeOnTouch = false
	for _, d in spawn:GetChildren() do if d:IsA("Decal") then d:Destroy() end end
	local sg = K.surface(spawn, Enum.NormalId.Top, 40, 0)
	K.guiImage(sg, UIAssets.Icons.star, { size = UDim2.fromScale(0.8, 0.8) })
	spawn.Parent = Workspace
	report.spawn = spawn:GetFullName()

	tagModel(place(Props.welcomeSign(), p, CFrame.new(L.PlazaX0 + 7, Y.Walk, 0) * CFrame.Angles(0, math.rad(-90), 0)), "CasinoProp")
	local board = tagModel(place(Props.leaderboard(), p, CFrame.new(cx + 4, Y.Walk, L.PlazaHalfZ - 8)), "CasinoProp")
	CollectionService:AddTag(board:FindFirstChild("Board"), "LeaderboardBoard")

	for _, spec in { { "daily", 1 }, { "store", -1 } } do
		local kiosk = place(Props.kiosk(spec[1]), p,
			CFrame.new(176, Y.Walk, spec[2] * (L.PlazaHalfZ - 20)) * CFrame.Angles(0, spec[2] > 0 and 0 or math.pi, 0))
		tagModel(kiosk, "CasinoProp")
		local counter = kiosk.PrimaryPart
		local prompt = Instance.new("ProximityPrompt")
		prompt.Name = "KioskPrompt"
		prompt.ActionText = spec[1] == "daily" and "Claim" or "Open"
		prompt.ObjectText = spec[1] == "daily" and "Daily Reward" or "VIP Store"
		prompt.KeyboardKeyCode = Enum.KeyCode.E
		prompt.HoldDuration = 0
		prompt.MaxActivationDistance = 12
		prompt.RequiresLineOfSight = false
		prompt.Parent = counter
		CollectionService:AddTag(counter, spec[1] == "daily" and "DailyKiosk" or "StoreKiosk")
	end

	-- palms with coloured up-lights, benches, double lamps, searchlights
	local seed = 40
	for _, pos in { Vector3.new(236, 0, 56), Vector3.new(236, 0, -56), Vector3.new(236, 0, 22), Vector3.new(236, 0, -22),
		Vector3.new(158, 0, 56), Vector3.new(158, 0, -56) } do
		local palm = place(Props.palm(seed, 24), p, CFrame.new(pos.X, Y.Walk, pos.Z))
		local up = K.part(palm, "Uplight", Vector3.new(0.6, 0.2, 0.6), CFrame.new(pos.X, Y.Walk + 1.2, pos.Z - 1.6), hex("#2A2633"), decor())
		K.new("SpotLight", { Face = Enum.NormalId.Top, Angle = 40, Range = 30, Brightness = 2.6, Shadows = false,
			Color = (seed % 2 == 0) and Color3.fromRGB(255, 120, 210) or Color3.fromRGB(110, 210, 255) }, up)
		seed += 1
	end
	for _, z in { -24, 24 } do
		place(Props.bench(), p, CFrame.new(186, Y.Walk, z) * CFrame.Angles(0, z > 0 and 0 or math.pi, 0))
		place(Props.bench(), p, CFrame.new(214, Y.Walk, z) * CFrame.Angles(0, z > 0 and 0 or math.pi, 0))
		place(Props.lamp(true), p, CFrame.new(222, Y.Walk, z * 1.5))
	end
	for _, z in { -42, 42 } do
		tagModel(atomic(place(Props.searchlight(), p, CFrame.new(238, Y.Walk, z))), "MapSearchlight")
	end
	-- a taxi rank at the plaza entrance
	place(Props.car("taxi"), p, CFrame.new(168, Y.Walk, -30) * CFrame.Angles(0, math.rad(90), 0))
	place(Props.car("limo"), p, CFrame.new(168, Y.Walk, 30) * CFrame.Angles(0, math.rad(-90), 0))
end

------------------------------------------------------------------
-- 5) Showroom forecourt (west). The building itself is runtime (Showroom.luau).
------------------------------------------------------------------
local function buildForecourt(map)
	local f = folder("ShowroomForecourt", map)
	slab(f, "Forecourt", L.ForecourtX0, L.StripX0, -54, 54, Y.Walk, 0.8, hex("#5B5468"), Enum.Material.Pavement,
		{ solid = true, shadow = false })
	K.part(f, "RedCarpet", Vector3.new(10, 0.08, 10), CFrame.new(L.ForecourtX0 + 5, Y.Walk + 0.04, 0), P.Crimson,
		{ material = Enum.Material.Fabric, shadow = false })
	for _, z in { -16, 16, -42, 42 } do
		place(Props.palm(60 + z, 23), f, CFrame.new(-154, Y.Walk, z))
	end
	for _, z in { -50, 50 } do
		tagModel(atomic(place(Props.searchlight(), f, CFrame.new(-154, Y.Walk, z))), "MapSearchlight")
	end
end

------------------------------------------------------------------
-- 6) backdrop: back streets, resort towers, wheel, sphere, mountains
------------------------------------------------------------------
local TOWERS = {
	-- north row (faces south, toward the Strip)
	{ x = -232, z = 212, w = 46, d = 34, h = 118, v = "CM_TowerWarm", crown = "#FF4FD0", name = "AURORA" },
	{ x = -150, z = 262, w = 40, d = 40, h = 168, v = "CM_TowerCool", crown = "#3FC8FF", name = "SILVER MOON", tiers = { { 1, 120 }, { 0.78, 48 } } },
	{ x = 52, z = 246, w = 38, d = 38, h = 150, v = "CM_TowerCool", crown = "#B36BFF", name = "NEON OASIS", tiers = { { 1, 100 }, { 0.8, 50 } } },
	{ x = 140, z = 205, w = 48, d = 34, h = 104, v = "CM_TowerWarm", crown = "#FF3B55", name = "ROYAL FLUSH" },
	{ x = 232, z = 250, w = 40, d = 40, h = 136, v = "CM_TowerCool", crown = "#3FC8FF", name = "HIGH CARD" },
	-- south row (faces north)
	{ x = -238, z = -232, w = 42, d = 40, h = 140, v = "CM_TowerCool", crown = "#3DFF6E", name = "EMERALD", tiers = { { 1, 96 }, { 0.75, 44 } } },
	{ x = -150, z = -206, w = 50, d = 34, h = 98, v = "CM_TowerWarm", crown = "#FFCB2E", name = "GOLDEN PALM" },
	{ x = -52, z = -252, w = 40, d = 40, h = 176, v = "CM_TowerCool", crown = "#FF4FD0", name = "STARLIGHT", tiers = { { 1, 112 }, { 0.8, 40 }, { 0.6, 24 } } },
	{ x = 30, z = -208, w = 44, d = 34, h = 106, v = "CM_TowerWarm", crown = "#FF3B55", name = "RUBY" },
	{ x = 236, z = -214, w = 44, d = 36, h = 116, v = "CM_TowerWarm", crown = "#FFCB2E", name = "JACKPOT" },
	-- west (silhouettes against the sunset glow) and east (behind the plaza)
	{ x = -300, z = -96, w = 40, d = 40, h = 158, v = "CM_TowerCool", crown = "#3FC8FF", name = "TITAN", tiers = { { 1, 110 }, { 0.75, 48 } } },
	{ x = -318, z = 74, w = 46, d = 36, h = 124, v = "CM_TowerWarm", crown = "#FF4FD0", name = "CRYSTAL" },
	{ x = 318, z = -84, w = 44, d = 36, h = 130, v = "CM_TowerWarm", crown = "#FFCB2E", name = "SUNSET" },
	{ x = 308, z = 104, w = 40, d = 40, h = 164, v = "CM_TowerCool", crown = "#B36BFF", name = "ORBIT", tiers = { { 1, 118 }, { 0.78, 46 } } },
}

local function faceCenterYaw(x, z)
	-- front (-Z) toward the origin, snapped to the street grid
	local yaw = math.atan2(x, z)
	return math.round(yaw / (math.pi / 2)) * (math.pi / 2)
end

local function buildBackdrop(map, report)
	local b = folder("Backdrop", map)
	for _, sz in { -1, 1 } do
		slab(b, "BackStreet", -220, 220, sz > 0 and 126 or -146, sz > 0 and 146 or -126, Y.Road, 0.4, hex("#1F1D26"),
			Enum.Material.Asphalt, { solid = true, shadow = false })
		K.part(b, "BackStreetLine", Vector3.new(436, 0.04, 0.3), CFrame.new(0, Y.Road + 0.02, sz * 136), hex("#F2C230"), decor())
		for x = -180, 180, 72 do
			place(Props.lamp(false), b, CFrame.new(x, Y.Road, sz * 125) * CFrame.Angles(0, math.rad(sz > 0 and -90 or 90), 0))
		end
	end
	local towers = folder("Towers", b)
	for _, t in TOWERS do
		local spec = {
			w = t.w, d = t.d, h = t.h, variant = t.v, crown = hex(t.crown), name = t.name, tiers = t.tiers,
			tint = Color3.fromRGB(235, 228, 245),
		}
		local tower = place(Props.tower(spec), towers, CFrame.new(t.x, Y.City, t.z) * CFrame.Angles(0, faceCenterYaw(t.x, t.z), 0))
		pcall(function() tower.LevelOfDetail = Enum.ModelLevelOfDetail.SLIM end)
	end
	report.towers = #TOWERS

	local land = folder("Landmarks", b)
	local wheel = atomic(place(Props.wheel(), land, CFrame.new(-46, Y.City, 236)))
	tagModel(wheel, "MapWheel")
	pcall(function() wheel.LevelOfDetail = Enum.ModelLevelOfDetail.SLIM end)
	local sphere = atomic(place(Props.sphere(80), land, CFrame.new(122, Y.City, -236)))
	tagModel(sphere, "MapSphere")
	pcall(function() sphere.LevelOfDetail = Enum.ModelLevelOfDetail.SLIM end)

	-- distant mountains: clusters of cubes stood on a corner (pyramid peaks),
	-- half buried; the atmosphere haze turns them into soft silhouettes
	local mountains = Instance.new("Model")
	mountains.Name = "Mountains"
	local rng = Random.new(77)
	local tilt = math.atan(1 / math.sqrt(2)) -- puts a cube's corner straight up
	for k = 0, 23 do
		local ang = k / 24 * math.pi * 2 + rng:NextNumber(-0.06, 0.06)
		local r = rng:NextNumber(1100, 1450)
		for j = 1, rng:NextInteger(2, 4) do
			local size = rng:NextNumber(140, 320)
			local along = rng:NextNumber(-140, 140)
			local tangent = Vector3.new(-math.sin(ang), 0, math.cos(ang))
			local pos = Vector3.new(math.cos(ang) * (r + rng:NextNumber(-60, 60)), 0, math.sin(ang) * r) + tangent * along
			local cf = CFrame.new(pos.X, -size * 0.25, pos.Z) * CFrame.Angles(0, rng:NextNumber(0, math.pi * 2), 0)
				* CFrame.Angles(tilt, 0, math.rad(45))
			K.part(mountains, "Peak", Vector3.new(size, size, size), cf,
				hex("#2E2742"):Lerp(hex("#463A5E"), rng:NextNumber()), { shadow = false })
		end
	end
	mountains.Parent = b
	pcall(function() mountains.ModelStreamingMode = Enum.ModelStreamingMode.Persistent end)
end

------------------------------------------------------------------
-- build everything
------------------------------------------------------------------
function MapBuilder.build()
	local MM = fresh(ServerScriptService.CasinoServer.MachineModels)
	UIAssets = fresh(ReplicatedStorage.CasinoCommon.UIAssets)
	Props = fresh(ServerStorage.MapTools.MapProps)
	Props.init(MM, UIAssets)
	K, P, hex = MM.Kit, MM.Palette, MM.Kit.hex

	local report = {}
	moveLegacy(report)
	windowVariants()

	local map = Instance.new("Folder")
	map.Name = "Map"
	map:SetAttribute("MapBuilder", true)
	local plots = Instance.new("Folder")
	plots.Name = "Plots"
	plots:SetAttribute("MapBuilder", true)

	buildGround(map)
	buildStrip(map)
	local index = 0
	for _, x in L.PlotXs do
		for _, north in { true, false } do
			index += 1
			buildPlot(plots, index, x, north)
		end
	end
	buildAlleys(map)
	buildPlaza(map, report)
	buildForecourt(map)
	buildBackdrop(map, report)

	map.Parent = Workspace
	plots.Parent = Workspace

	local parts, lights, bulbs = 0, 0, 0
	for _, d in map:GetDescendants() do
		if d:IsA("BasePart") then
			parts += 1
			if d.Name == "Bulb" then bulbs += 1 end
		elseif d:IsA("Light") then
			lights += 1
		end
	end
	report.parts = parts
	report.lights = lights
	report.bulbs = bulbs
	report.plots = #plots:GetChildren()
	return report
end

return MapBuilder
