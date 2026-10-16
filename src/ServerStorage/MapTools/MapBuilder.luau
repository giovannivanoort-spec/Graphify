--!nonstrict
-- MapBuilder.luau — builds the city INTO THE PLACE. Edit-time tool: the
-- running game never requires it. Run it from the command bar:
--
--   require(game.ServerStorage.MapTools.MapBuilder:Clone()).build()
--
-- It moves the old flat map into ServerStorage.LegacyMap (once), then rebuilds
-- Workspace.Map and Workspace.Plots from scratch and returns a short report
-- (and prints the part count per Map folder).
--
-- Every position comes from CasinoCommon.CityLayout (the runtime reads the
-- same plan, so plots, curb stops, lanes and the showroom all line up):
--   centre : the plaza (spawn, the three leaderboards, kiosks, the services
--            desk, the Jackpot Fountain) inside a one-way ring road with
--            round corners
--   arms   : four boulevards N / E / S / W, two carriageways round a palm
--            median, three casinos a side (23 plots + the Machine Showroom's
--            slot on the south arm), a taxi bay at every casino's curb and a
--            tunnel into the valley wall at the far end
--   around : a red-rock valley wall; between the arms four open blocks with
--            resort towers, the observation wheel, the LED sphere, parking
--            lots and gardens; mountains beyond
-- Every world colour comes from CasinoCommon.WorldPalette (WP); surfaces with
-- a PBR material are painted through Materials.paint so they render as it.

local ServerStorage = game:GetService("ServerStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MaterialService = game:GetService("MaterialService")
local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")

local MapBuilder = {}

-- the command bar / plugin VM caches required modules: require a clone for a
-- fresh copy. The clone sits in a scratch folder with clones of its sibling
-- modules, so requires through script.Parent inside it (Materials ->
-- MaterialIds) still resolve, to fresh copies as well.
local function fresh(module: ModuleScript)
	local scratch = Instance.new("Folder")
	for _, sibling in module.Parent:GetChildren() do
		if sibling:IsA("ModuleScript") then sibling:Clone().Parent = scratch end
	end
	return require(scratch:FindFirstChild(module.Name))
end

-- the city plan and its tables (CityLayout.Arm / .Ring / .Y), set in build()
local CL, ARM, RING, Y

-- the pools' water has no WorldPalette entry (water is its own thing)
local POOL_WATER = Color3.fromRGB(28, 92, 124)
local POOL_FLOOR = Color3.fromRGB(14, 42, 54)
local BLACK = Color3.new(0, 0, 0)

-- walking lines: every arm's sidewalks (|t| 23..35) line up with a zebra over
-- the ring and a straight path across the plaza (|t| 25..33)
local CROSS_T, CROSS_HALF = 29, 4
local ARM_CROSS_S0, ARM_CROSS_S1 = 119, 125      -- the zebra over each arm, just outside the ring
local LINE_S0, LINE_S1 = 126, 478                -- lane paint: from the zebra into the tunnel (none in the turn mouths)
local MEDIAN_S0, MEDIAN_S1 = 126, 431.9          -- the median: its nose to the portal's central wall
local POOL_ARM, POOL_S0, POOL_S1 = "N", 154, 278 -- the main street keeps a fountain pool in its median
local MEDIAN_PALMS = { 135, 154, 177, 255, 278, 356, 379 } -- none near the portal: its sign stays in view
local MEDIAN_LAMPS = { 145, 216, 317, 405 }      -- the alley lines carry a lamp across the whole street
local MEDIAN_HEDGES = { { 188, 206 }, { 226, 246 }, { 289, 308 }, { 326, 346 } }
local WALK_PROPS_S = { 216, 317, 419 }           -- sidewalk lamps, bins, benches: between the casinos

-- the plaza: the hall of fame (spawn + the three boards) south of the fountain
local HALL_Z, HALL_R = 45, 21.5

-- the tunnels, arm frame: twin bores either side of a central wall
local BORE_IN, BORE_OUT, BORE_TOP = 5, 25, 17 -- each bore spans |t| 5..25, 17 high
local HEADWALL = 4                             -- the portal face: s 432..436
local TUNNEL_WALL = 26.5                       -- the bores' outer walls end here
local GATE_NAMES = { N = "NORTH GATE", E = "EAST GATE", S = "SOUTH GATE", W = "WEST GATE" }

-- curbs stand 0.06 proud of the walks (a hair wider than 0.5, so their road
-- face never z-fights the paving's side)
local CURB_TOP = 0.86

local K, Props, UIAssets, Mats, WP

local function decor() return { shadow = false } end
local function solid() return { solid = true, shadow = false } end

-- give a built part one of the PBR materials (Materials.luau), tinted so it
-- renders as the WorldPalette colour `target` (nil = the texture's own colours)
local function mat(part: BasePart, key: string, target: Color3?): BasePart
	return Mats.paint(part, key, target)
end

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

local function newModel(name: string, parent: Instance): Model
	local m = Instance.new("Model")
	m.Name = name
	m.Parent = parent
	return m
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

local function slim(model: Model)
	pcall(function() model.LevelOfDetail = Enum.ModelLevelOfDetail.SLIM end)
	return model
end

local function countParts(root: Instance): number
	local n = 0
	for _, d in root:GetDescendants() do
		if d:IsA("BasePart") then n += 1 end
	end
	return n
end

------------------------------------------------------------------
-- geometry helpers
------------------------------------------------------------------
-- the frame of arm `arm` at (s, t, y): X along the arm (out), Z along lat
local function armCF(arm: string, s: number, t: number, y: number): CFrame
	return CFrame.fromMatrix(CL.toWorld(arm, s, t, y), CL.Arms[arm].out, Vector3.yAxis)
end

-- a box over an arm-frame block (s0..s1, t0..t1, y0..y1, either order)
local function armBox(parent, name, arm: string, s0, s1, t0, t1, y0, y1, color: Color3, opts)
	return K.part(parent, name, Vector3.new(math.abs(s1 - s0), math.abs(y1 - y0), math.abs(t1 - t0)),
		armCF(arm, (s0 + s1) / 2, (t0 + t1) / 2, (y0 + y1) / 2), color, opts)
end

-- the world rectangle x0, x1, z0, z1 of an arm-frame one
local function armRect(arm: string, s0, s1, t0, t1)
	local p, q = CL.toWorld(arm, s0, t0), CL.toWorld(arm, s1, t1)
	return math.min(p.X, q.X), math.max(p.X, q.X), math.min(p.Z, q.Z), math.max(p.Z, q.Z)
end

-- a frame at `pos` whose +X points along `dir` (lamp arms reach along +X)
local function along(pos: Vector3, dir: Vector3): CFrame
	return CFrame.fromMatrix(pos, Vector3.new(dir.X, 0, dir.Z).Unit, Vector3.yAxis)
end

-- a frame at `pos` whose front (-Z) looks along `dir`
local function facing(pos: Vector3, dir: Vector3): CFrame
	return CFrame.lookAt(pos, pos + Vector3.new(dir.X, 0, dir.Z))
end

-- a flat bar from a to b (their y is ignored), `width` across, its top at
-- `top`; `extra` lengthens it (closes the joints of a polyline)
local function seg(parent, name, a: Vector3, b: Vector3, width: number, top: number, thick: number, color: Color3, opts,
	extra: number?)
	local flat = Vector3.new(b.X - a.X, 0, b.Z - a.Z)
	local mid = Vector3.new((a.X + b.X) / 2, top - thick / 2, (a.Z + b.Z) / 2)
	return K.part(parent, name, Vector3.new(width, thick, flat.Magnitude + (extra or 0)), CFrame.lookAt(mid, mid + flat),
		color, opts)
end

-- road paint from a to b (0.05 proud of the asphalt)
local function paint(parent, name, a: Vector3, b: Vector3, width: number, color: Color3, extra: number?)
	return seg(parent, name, a, b, width, Y.Road + 0.05, 0.05, color, decor(), extra)
end

-- a right-angled wedge: `right` is its square corner, `up` the corner along
-- the wedge's +Y leg, `front` the one along its -Z leg, `thick` along its X
local function wedge(parent, name, right: Vector3, up: Vector3, front: Vector3, thick: number, color: Color3, opts)
	local yv, zv = up - right, right - front
	if yv.Magnitude < 0.01 or zv.Magnitude < 0.01 then return nil end
	local w = Instance.new("WedgePart")
	w.Name = name
	w.Anchored = true
	w.Size = Vector3.new(thick, yv.Magnitude, zv.Magnitude)
	w.CFrame = CFrame.fromMatrix((up + front) / 2, yv.Unit:Cross(zv.Unit), yv.Unit, zv.Unit)
	w.Color = color
	w.Material = opts.material or Enum.Material.SmoothPlastic
	w.CanCollide = opts.solid == true
	w.CanQuery = opts.solid == true
	w.CanTouch = false
	w.CastShadow = opts.shadow ~= false
	w.TopSurface = Enum.SurfaceType.Smooth
	w.BottomSurface = Enum.SurfaceType.Smooth
	w.Parent = parent
	return w
end

-- a flat triangle (two wedges) on a, b, c (their y is ignored), top at `top`
local function triangle(parent, name, a: Vector3, b: Vector3, c: Vector3, top: number, thick: number, color: Color3, opts)
	local y = top - thick / 2
	a, b, c = Vector3.new(a.X, y, a.Z), Vector3.new(b.X, y, b.Z), Vector3.new(c.X, y, c.Z)
	-- make a-b the longest side; the altitude from c meets it at f
	local ab, bc, ca = (b - a).Magnitude, (c - b).Magnitude, (a - c).Magnitude
	if bc > ab and bc >= ca then
		a, b, c = b, c, a
	elseif ca > ab and ca > bc then
		a, b, c = c, a, b
	end
	local axis = (b - a).Unit
	local f = a + axis * (c - a):Dot(axis)
	wedge(parent, name, f, c, a, thick, color, opts)
	wedge(parent, name, f, c, b, thick, color, opts)
end

-- the ring's rounded square: a point on the straight side facing `arm` at
-- distance d (t along that arm's lat), and one on the corner that follows it
-- (radius r round the corner centre, phi 0 .. pi/2 toward the next arm)
local function sidePoint(arm: string, d: number, t: number): Vector3
	local a = CL.Arms[arm]
	return a.out * d + a.lat * t
end
local function cornerPoint(arm: string, r: number, phi: number): Vector3
	local a = CL.Arms[arm]
	local nextOut = -a.lat
	return (a.out + nextOut) * RING.CornerC + (a.out * math.cos(phi) + nextOut * math.sin(phi)) * r
end
local function nextArm(arm: string): string
	return CL.RingOrder[table.find(CL.RingOrder, arm) % 4 + 1]
end

-- the showroom's footprint in its arm frame (room + facade + canopy, and a
-- stud of margin): nothing else may stand in it. Its depth follows its rows
-- of machines (Showroom.luau: the back wall is at t = 71 + 16 x (rows - 1),
-- the cornice 1.3 behind it): five rows now (three of rank machines, two of
-- the Rebirth Wing), so t ~136.3. More rows: raise SHOWROOM_BACK_T and re-run.
local SHOWROOM_BACK_T = 138
local function inShowroom(arm: string, s0: number, s1: number, t0: number, t1: number): boolean
	local sl = CL.ShowroomSlot
	if arm ~= sl.arm then return false end
	local s = CL.slotS(sl.k)
	local lo, hi = math.min(t0, t1) * sl.side, math.max(t0, t1) * sl.side
	lo, hi = math.min(lo, hi), math.max(lo, hi)
	return math.max(s0, s1) > s - 51 and math.min(s0, s1) < s + 51 and hi > 26.5 and lo < SHOWROOM_BACK_T
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
-- 1) materials: tower windows. Each tower variant comes in two: "CM_TowerX"
-- glows through an emissive mask (night), "CM_TowerXDay" has no mask (stone
-- mullions + dark glass by day). Tower shafts swap between them (NightLight).
-- Uses the generated stone/bronze maps (Materials.Images) when uploaded, else
-- the old UIAssets.Windows pair. Returns { [variant] = true } for each
-- variant that got the new maps (their colour is baked in: shafts stay white).
------------------------------------------------------------------
local function windowVariants(): { [string]: boolean }
	local img, W = Mats.Images or {}, UIAssets.Windows
	local function pick(color, emit, night, oldColor, oldEmit)
		-- colour map and mask must come from the same set (same window grid); the
		-- night variant shows the lit rooms baked into its own colour map
		if color and color ~= "" and emit and emit ~= "" then
			return { color, emit, (night and night ~= "") and night or color }, true
		end
		return { oldColor, oldEmit, oldColor }, false
	end
	local warm, warmNew = pick(img.TowerWarmColor, img.TowerWarmEmit, img.TowerWarmNightColor, W.WarmColor, W.WarmEmit)
	local cool, coolNew = pick(img.TowerCoolColor, img.TowerCoolEmit, img.TowerCoolNightColor, W.CoolColor, W.CoolEmit)
	for _, spec in {
		{ "CM_TowerWarm", warm, WP.WarmNeon },
		{ "CM_TowerCool", cool, WP.Cyan:Lerp(Color3.new(1, 1, 1), 0.55) },
	} do
		for _, day in { false, true } do
			local name = spec[1] .. (day and "Day" or "")
			local mv = MaterialService:FindFirstChild(name) or Instance.new("MaterialVariant")
			mv.Name = name
			mv.BaseMaterial = Enum.Material.Plastic
			mv.ColorMap = day and spec[2][1] or spec[2][3]
			mv.StudsPerTile = 36
			if day then
				pcall(function() mv.EmissiveMaskContent = Content.none end)
				pcall(function() mv.EmissiveStrength = 0 end)
			else
				local uri = spec[2][2]
				local ok = pcall(function() mv.EmissiveMaskContent = Content.fromUri(uri) end)
				if not ok then pcall(function() (mv :: any).EmissiveMaskContent = uri end) end
				mv.EmissiveStrength = 4
				mv.EmissiveTint = spec[3]
			end
			mv.Parent = MaterialService
		end
	end
	return { CM_TowerWarm = warmNew, CM_TowerCool = coolNew }
end

------------------------------------------------------------------
-- 2) ground: desert to the mountains, city paving on the valley floor
------------------------------------------------------------------
local function buildGround(map)
	local g = folder("Ground", map)
	-- desert all the way to the mountains (3x3 tiles of the 2048 part limit)
	for i = -1, 1 do
		for j = -1, 1 do
			K.part(g, "Desert", Vector3.new(2048, 2, 2048), CFrame.new(i * 2048, -1, j * 2048), WP.Sand,
				{ material = Enum.Material.Sand, solid = (i == 0 and j == 0), shadow = false })
		end
	end
	-- the valley floor, wall to wall: 8-stud concrete slabs (the zoning, the
	-- roads and the plots break it up)
	local V = CL.ValleyHalf
	mat(slab(g, "CityPaving", -V, V, -V, V, Y.City, 0.4, WP.Lot, Enum.Material.Concrete, solid()), "ConcreteSlab", WP.Lot)
end

------------------------------------------------------------------
-- 3) the ring road: one-way, two lanes (88..110 from the centre), round
-- corners centred on (±75, ±75); its outer sidewalk (110..122) is broken by
-- the four arm mouths, and a little garden fills each outer corner between
-- the curved curb and the square paving
------------------------------------------------------------------
local function buildRing(map)
	local ring = folder("Ring", map)
	local d0, d1, cc = RING.PlazaHalf, RING.RoadOuter, RING.CornerC -- 88, 110, 75
	-- one square of asphalt: the plaza covers its middle, the corner paving
	-- and gardens its square corners
	mat(slab(ring, "RingRoad", -d1, d1, -d1, d1, Y.Road, 0.4, WP.Asphalt, Enum.Material.Asphalt, solid()), "Asphalt", WP.Asphalt)

	local curbs = folder("Curbs", ring)
	local walks = folder("Sidewalks", ring)
	local gardens = folder("Gardens", ring)
	local seed = 70
	for _, arm in CL.RingOrder do
		local a = CL.Arms[arm]
		local b = nextArm(arm)
		-- outer curb: the straight runs either side of this arm's mouth (a hair
		-- wider than 0.5 so its road face never z-fights the paving's) ...
		for _, sgn in { -1, 1 } do
			local x0, x1, z0, z1 = armRect(arm, d1 - 0.02, d1 + 0.52, sgn * ARM.RoadHalf, sgn * cc)
			mat(slab(curbs, "Curb", x0, x1, z0, z1, CURB_TOP, CURB_TOP, WP.Curb, Enum.Material.Concrete, solid()), "SmoothConcrete", WP.Curb)
			-- the darker paver border against it (stops where the arm's border runs)
			x0, x1, z0, z1 = armRect(arm, d1 + 0.52, d1 + 2.52, sgn * (ARM.RoadHalf + 2.52), sgn * cc)
			mat(slab(walks, "WalkBorder", x0, x1, z0, z1, Y.Walk + 0.05, 0.08, WP.WalkBorder, Enum.Material.Pavement, decor()),
				"Pavers", WP.WalkBorder)
		end
		-- ... and round the corner that follows: 12 chords on radius 35.25
		local r = d1 + 0.25 - cc
		for k = 0, 11 do
			mat(seg(curbs, "Curb", cornerPoint(arm, r, math.pi / 24 * k), cornerPoint(arm, r, math.pi / 24 * (k + 1)), 0.54,
				CURB_TOP, CURB_TOP, WP.Curb, { material = Enum.Material.Concrete, solid = true, shadow = false }, 0.06),
				"SmoothConcrete", WP.Curb)
		end
		-- the L of paving round that corner: this side's run (out to the square
		-- corner) and the next side's
		local x0, x1, z0, z1 = armRect(arm, d1, RING.WalkOuter, -RING.WalkOuter, -ARM.RoadHalf)
		mat(slab(walks, "Sidewalk", x0, x1, z0, z1, Y.Walk, 0.8, WP.Sidewalk, Enum.Material.Pavement, solid()), "Pavers", WP.Sidewalk)
		x0, x1, z0, z1 = armRect(b, d1, RING.WalkOuter, ARM.RoadHalf, d1)
		mat(slab(walks, "Sidewalk", x0, x1, z0, z1, Y.Walk, 0.8, WP.Sidewalk, Enum.Material.Pavement, solid()), "Pavers", WP.Sidewalk)
		-- the garden between the curved curb and the L's inner corner: a fan of
		-- flat lawn triangles. Its arc vertices sit on r 35.3 (r 35 at the ends),
		-- so every chord stays under the curb (r 34.9 .. 35.5)
		local Q = sidePoint(arm, d1, -d1)
		local pts = {}
		for k = 0, 6 do
			local rr = (k == 0 or k == 6) and (d1 - cc) or (d1 - cc) / math.cos(math.pi / 24)
			table.insert(pts, cornerPoint(arm, rr, math.pi / 12 * k))
		end
		for k = 1, 6 do
			triangle(gardens, "Lawn", Q, pts[k], pts[k + 1], Y.Walk, 0.6, WP.Lawn,
				{ material = Enum.Material.Grass, solid = true, shadow = false })
		end
		-- a palm with an up-light, and the lamp that lights the curve
		local palmAt = sidePoint(arm, 104, -104)
		local palm = place(Props.palm(seed, 22 + (seed % 3) * 2, { bare = true }), gardens, CFrame.new(palmAt + Vector3.new(0, Y.Walk, 0)))
		local up = K.part(palm, "Uplight", Vector3.new(0.6, 0.2, 0.6), CFrame.new(palmAt - palmAt.Unit * 1.6 + Vector3.new(0, Y.Walk + 0.1, 0)),
			WP.DarkMetal, decor())
		Props.night(K.new("SpotLight", { Face = Enum.NormalId.Top, Angle = 40, Range = 30, Brightness = 2.4, Shadows = false,
			Color = (seed % 2 == 0) and WP.Magenta or WP.Cyan }, up))
		seed += 1
		local lampAt = cornerPoint(arm, d1 - cc + 1.8, math.pi / 4)
		local centre = (a.out - a.lat) * cc
		place(Props.lamp(false), gardens, along(lampAt + Vector3.new(0, Y.Walk, 0), centre - lampAt))
	end

	-- markings: white edge lines (broken at the zebras and the arm mouths),
	-- the zebras themselves, and the yellow dashed divider round the corners
	local marks = folder("Markings", ring)
	local inner, outer = d0 + 0.8, d1 - 0.8 -- 88.8, 109.2
	local c0, c1 = CROSS_T - CROSS_HALF - 0.5, CROSS_T + CROSS_HALF + 0.5
	for _, arm in CL.RingOrder do
		for _, run in { { c1, cc }, { -c0, c0 }, { -cc, -c1 } } do
			paint(marks, "EdgeLine", sidePoint(arm, inner, run[1]), sidePoint(arm, inner, run[2]), 0.35, WP.LaneWhite)
		end
		for _, run in { { c1, cc }, { -cc, -c1 } } do
			paint(marks, "EdgeLine", sidePoint(arm, outer, run[1]), sidePoint(arm, outer, run[2]), 0.35, WP.LaneWhite)
		end
		for _, spec in { { inner, 6 }, { outer, 12 } } do
			local r, n = spec[1] - cc, spec[2]
			for k = 0, n - 1 do
				paint(marks, "EdgeLine", cornerPoint(arm, r, math.pi / 2 * k / n), cornerPoint(arm, r, math.pi / 2 * (k + 1) / n),
					0.35, WP.LaneWhite, 0.05)
			end
		end
		-- zebras over the ring on this arm's two sidewalk lines: 1.6 bars, 3.2 apart
		for _, sgn in { -1, 1 } do
			for k = 0, 6 do
				local d = d0 + 1.6 + k * 3.2
				paint(marks, "Crosswalk", sidePoint(arm, d, sgn * (CROSS_T - CROSS_HALF)), sidePoint(arm, d, sgn * (CROSS_T + CROSS_HALF)),
					1.6, WP.LaneWhite)
			end
		end
	end
	-- the divider: 5-stud dashes on CityLayout's polyline at d 99 (corner r 24),
	-- none touching a zebra (a dash's middle stays 2.5 + 1 clear of the bars)
	local function onZebra(p: Vector3): boolean
		for _, a in CL.Arms do
			local s, t = p:Dot(a.out), p:Dot(a.lat)
			if s > d0 - 2 and s < d1 + 2 and math.abs(math.abs(t) - CROSS_T) < CROSS_HALF + 3.5 then return true end
		end
		return false
	end
	local pts = CL.ringPolyline(RING.Divider, 2.5)
	for i = 1, #pts - 2, 4 do
		local p, q = pts[i], pts[i + 2]
		if not onZebra((p + q) / 2) then paint(marks, "Divider", p, q, 0.3, WP.LaneYellow) end
	end

	-- lamps: on the plaza's edge band over the inner lane, on the outer border
	-- over the outer lane (clear of the zebras and the corner planters)
	local lamps = folder("Lamps", ring)
	for _, arm in CL.RingOrder do
		local a = CL.Arms[arm]
		for _, t in { -52, 52 } do
			place(Props.lamp(false), lamps, along(sidePoint(arm, d0 - 2, t) + Vector3.new(0, Y.Walk, 0), a.out))
			place(Props.lamp(false), lamps, along(sidePoint(arm, d1 + 1.6, t) + Vector3.new(0, Y.Walk, 0), -a.out))
		end
	end
end

------------------------------------------------------------------
-- 4) the four boulevards: road, median, sidewalks, paint, taxi bays,
-- street furniture; the far ends run into the tunnels (section 8)
------------------------------------------------------------------
-- a red carpet runner: plain Fabric (no texture) with a brass edge rod along
-- each long side. `cf` is the runner's centre on the walk, its length along Z.
-- 0.1 thick: its top clears the curb-side WalkBorder (walk + 0.05) by 0.05.
local function redCarpet(parent, width: number, length: number, cf: CFrame)
	K.part(parent, "RedCarpet", Vector3.new(width, 0.1, length), cf * CFrame.new(0, 0.05, 0), WP.Lacquer,
		{ material = Enum.Material.Fabric, shadow = false })
	for _, sx in { -1, 1 } do
		Props.gold(parent, "CarpetEdge", Vector3.new(0.25, 0.12, length), cf * CFrame.new(sx * (width / 2 + 0.125), 0.06, 0), decor())
	end
end

local function inPool(arm: string, s: number, margin: number): boolean
	return arm == POOL_ARM and s > POOL_S0 - margin and s < POOL_S1 + margin
end

local function buildMedian(f, arm: string)
	local a = CL.Arms[arm]
	local med = folder("Median", f)
	local H = ARM.MedianHalf
	local spans = { { MEDIAN_S0, MEDIAN_S1 } }
	if arm == POOL_ARM then spans = { { MEDIAN_S0, POOL_S0 - 0.7 }, { POOL_S1 + 0.7, MEDIAN_S1 } } end
	-- raised curb strips with grass, low hedges between the trees
	for _, sp in spans do
		mat(armBox(med, "MedianCurb", arm, sp[1], sp[2], -H, H, Y.Road, 1.0, WP.Curb,
			{ material = Enum.Material.Concrete, solid = true, shadow = false }), "SmoothConcrete", WP.Curb)
		armBox(med, "MedianGrass", arm, sp[1] + 0.5, sp[2] - 0.5, -H + 0.5, H - 0.5, 0.96, 1.06, WP.Lawn,
			{ material = Enum.Material.Grass, shadow = false })
	end
	for _, hd in MEDIAN_HEDGES do
		if not inPool(arm, (hd[1] + hd[2]) / 2, 12) then
			local hedge = armBox(med, "Hedge", arm, hd[1], hd[2], -2.2, 2.2, 1.06, 2.3, WP.Lawn, decor())
			local baked = (Mats.Defs.Hedge or {}).color
			mat(hedge, "Hedge", (baked == nil or baked == "") and WP.Lawn or nil)
		end
	end
	-- the main street's fountain pool (jets dance, MapFX)
	if arm == POOL_ARM then
		local s0, s1, rim = POOL_S0, POOL_S1, H - 0.7
		for _, sd in { -1, 1 } do
			mat(armBox(med, "PoolRim", arm, s0 - 0.7, s1 + 0.7, sd * rim, sd * H, Y.Road, 1.0, WP.Curb,
				{ material = Enum.Material.Concrete, solid = true, shadow = false }), "SmoothConcrete", WP.Curb)
			-- underwater light strips, seen through the water (lit after dark)
			Props.nightNeon(armBox(med, "PoolGlow", arm, s0, s1, sd * (rim - 0.36), sd * (rim - 0.22), 0.45, 0.55, WP.Cyan,
				{ material = Enum.Material.Neon, shadow = false }), WP.Cyan)
		end
		for _, s in { s0 - 0.35, s1 + 0.35 } do
			mat(armBox(med, "PoolRim", arm, s - 0.35, s + 0.35, -rim, rim, Y.Road, 1.0, WP.Curb,
				{ material = Enum.Material.Concrete, solid = true, shadow = false }), "SmoothConcrete", WP.Curb)
		end
		armBox(med, "PoolFloor", arm, s0, s1, -rim, rim, Y.Road, 0.45, POOL_FLOOR, decor())
		armBox(med, "PoolWater", arm, s0, s1, -rim, rim, 0.85, 0.9, POOL_WATER, { shadow = false, reflectance = 0.3, transparency = 0.2 })
		local jets = folder("FountainJets", med)
		local first, last = s0 + 8, s1 - 8
		local n = math.floor((last - first) / 9 + 0.5)
		for k = 0, n do
			local s = first + (last - first) * k / n
			local jet = place(Props.fountainJet(10 + (k % 3) * 1.6), jets, CFrame.new(CL.toWorld(arm, s, 0, 0.45)))
			jet:SetAttribute("Order", k / n)
			tagModel(atomic(jet), "MapFountainJet")
		end
	end
	-- palms and double lamps along the strip
	local seed = table.find(CL.RingOrder, arm) * 100
	for _, s in MEDIAN_PALMS do
		if not inPool(arm, s, 4) then
			place(Props.palm(seed, 20 + (seed % 3) * 2.5, { bare = true, lite = true }), med, CFrame.new(CL.toWorld(arm, s, 0, 1.0)))
		end
		seed += 1
	end
	for _, s in MEDIAN_LAMPS do
		if not inPool(arm, s, 4) then
			place(Props.lamp(true), med, along(CL.toWorld(arm, s, 0, 1.0), a.lat))
		end
	end
end

-- the casinos on one side of an arm: { [slot k] = plot entry }
local function plotsOn(arm: string, side: number)
	local out = {}
	for _, p in CL.Plots do
		if p.arm == arm and p.side == side then out[p.k] = p end
	end
	return out
end

local function buildMarkings(f, arm: string)
	local a = CL.Arms[arm]
	local marks = folder("Markings", f)
	local bays = folder("TaxiBays", f)
	local function at(s, t) return CL.toWorld(arm, s, t) end
	local lane, stop = (ARM.TravelLane + ARM.StopLane) / 2, ARM.StopLane -- 14, 18.5
	for _, side in { -1, 1 } do
		-- solid lines: white along the curb, yellow along the median
		paint(marks, "EdgeLine", at(LINE_S0, side * (ARM.RoadHalf - 0.8)), at(LINE_S1, side * (ARM.RoadHalf - 0.8)), 0.35, WP.LaneWhite)
		paint(marks, "MedianLine", at(LINE_S0, side * (ARM.MedianHalf + 0.8)), at(LINE_S1, side * (ARM.MedianHalf + 0.8)), 0.3,
			WP.LaneYellow)
		-- the casinos' curb stops: a yellow box in the stop lane (s ±9 round the
		-- entrance) with TAXI painted in it, reading for the cars that pull in
		local stops = {}
		for k, _ in plotsOn(arm, side) do
			local bay = CL.bay(arm, k, side)
			table.insert(stops, bay.s)
			paint(bays, "BayLine", at(bay.s - 9, side * lane), at(bay.s + 9, side * lane), 0.3, WP.LaneYellow)
			for _, e in { -9, 9 } do
				paint(bays, "BayLine", at(bay.s + e, side * (lane + 0.15)), at(bay.s + e, side * (ARM.RoadHalf - 1.1)), 0.3, WP.LaneYellow)
			end
			local drive = a.out * side -- side +1 bays serve outbound cars, side -1 inbound
			local text = K.part(bays, "BayText", Vector3.new(9, 0.02, 6.6),
				CFrame.fromMatrix(CL.toWorld(arm, bay.s, side * stop, Y.Road + 0.1), -drive, Vector3.yAxis), WP.LaneYellow,
				{ transparency = 1, shadow = false })
			-- a Top SurfaceGui reads "up" toward the part's -X: along the drive
			K.guiText(K.surface(text, Enum.NormalId.Top, 20, 0.4), "TAXI", { color = WP.LaneYellow, stroke = false,
				font = Enum.Font.GothamBlack, size = UDim2.fromScale(1, 0.5), position = UDim2.fromScale(0, 0.25) })
		end
		-- the lane divider: 6-stud dashes, broken where a bay's box takes over
		local s = LINE_S0 + 4
		while s + 6 <= ARM.SpawnS do
			local c = s + 3
			local clear = true
			for _, bs in stops do
				if math.abs(c - bs) < 12.5 then clear = false end
			end
			if clear then paint(marks, "LaneDash", at(s, side * lane), at(s + 6, side * lane), 0.3, WP.LaneWhite) end
			s += 12
		end
	end
	-- the zebra over the whole arm, just outside the ring: 1.6 bars, 3.2 apart
	for j = -6, 7 do
		local t = j * 3.2 - 1.6
		paint(marks, "Crosswalk", at(ARM_CROSS_S0, t), at(ARM_CROSS_S1, t), 1.6, WP.LaneWhite)
	end
end

local function buildArm(map, arm: string)
	local f = folder("Arm" .. arm, map)
	local a = CL.Arms[arm]
	local RH, WO = ARM.RoadHalf, ARM.WalkOuter
	-- the road from the ring to the portal (the tunnel has its own floor)
	mat(armBox(f, "Road", arm, RING.RoadOuter, ARM.PortalS, -RH, RH, 0, Y.Road, WP.Asphalt,
		{ material = Enum.Material.Asphalt, solid = true, shadow = false }), "Asphalt", WP.Asphalt)
	for _, side in { -1, 1 } do
		-- sidewalk (the ring's paving covers s < 122), curb, darker curb-side border
		mat(armBox(f, "Sidewalk", arm, RING.WalkOuter, ARM.PortalS, side * RH, side * WO, 0, Y.Walk, WP.Sidewalk,
			{ material = Enum.Material.Pavement, solid = true, shadow = false }), "Pavers", WP.Sidewalk)
		mat(armBox(f, "Curb", arm, RING.RoadOuter + 0.52, ARM.PortalS, side * (RH - 0.02), side * (RH + 0.52), 0, CURB_TOP, WP.Curb,
			{ material = Enum.Material.Concrete, solid = true, shadow = false }), "SmoothConcrete", WP.Curb)
		mat(armBox(f, "WalkBorder", arm, RING.RoadOuter + 0.52, ARM.PortalS, side * (RH + 0.52), side * (RH + 2.52),
			Y.Walk - 0.03, Y.Walk + 0.05, WP.WalkBorder, { material = Enum.Material.Pavement, shadow = false }), "Pavers", WP.WalkBorder)
		-- the gap between the ring's paving and the first casino's side wall: a
		-- lawn strip with a clipped hedge
		armBox(f, "Verge", arm, RING.WalkOuter, RING.WalkOuter + 2.9, side * WO, side * CL.PlotBack, Y.City, Y.Bed, WP.Lawn,
			{ material = Enum.Material.Grass, solid = true, shadow = false })
		local hedge = armBox(f, "Hedge", arm, RING.WalkOuter + 0.4, RING.WalkOuter + 2.5, side * (WO + 1), side * (CL.PlotBack - 1),
			Y.Bed, Y.Bed + 1.6, WP.Lawn, decor())
		local baked = (Mats.Defs.Hedge or {}).color
		mat(hedge, "Hedge", (baked == nil or baked == "") and WP.Lawn or nil)
		-- the far end, between the last casino and the valley wall: a gravel bed
		local g0 = inShowroom(arm, 409, 418, side * 40, side * 80) and 420 or 409
		armBox(f, "Gravel", arm, g0, ARM.PortalS - 4, side * (WO + 3), side * (CL.PlotBack - 3), Y.City, Y.Bed, WP.Gravel,
			{ material = Enum.Material.Pebble, solid = true, shadow = false })
	end
	buildMedian(f, arm)
	buildMarkings(f, arm)

	-- sidewalk lamps (arm over the road), bins and benches between the casinos
	local furn = folder("StreetFurniture", f)
	for _, side in { -1, 1 } do
		for _, s in WALK_PROPS_S do
			place(Props.lamp(false), furn, along(CL.toWorld(arm, s, side * (RH + 1.6), Y.Walk), -a.lat * side))
			if not inShowroom(arm, s + 3, s + 5, side * 23.6, side * 25.2) then
				place(Props.trashBin(), furn, CFrame.new(CL.toWorld(arm, s + 4, side * (RH + 1.4), Y.Walk)))
			end
			if not inShowroom(arm, s - 7.5, s - 0.5, side * 31.4, side * 34) then
				place(Props.bench(), furn, facing(CL.toWorld(arm, s - 4, side * 32.4, Y.Walk), -a.lat * side))
			end
		end
	end
end

------------------------------------------------------------------
-- 5) the 23 casino plots (Plots.luau discovers Workspace.Plots/*, assigns
-- them in PlotIndex order) and the string-lit alleys between them
------------------------------------------------------------------
local function buildPlot(plotsFolder, entry)
	local plotCF = entry.cframe -- CityLayout's ground frame: front (-Z) to the boulevard
	local function at(lx, ly, lz, yaw) return plotCF * CFrame.new(lx, ly, lz) * CFrame.Angles(0, math.rad(yaw or 0), 0) end

	local m = Instance.new("Model")
	m.Name = "Plot" .. entry.index
	local base = Instance.new("Part")
	base.Name = "Base"
	base.Anchored = true
	base.Size = Vector3.new(ARM.PlotW, 1, ARM.PlotD)
	base.CFrame = at(0, 0.5, 0)
	base.TopSurface = Enum.SurfaceType.Smooth
	base.BottomSurface = Enum.SurfaceType.Smooth
	-- the casino's ground-floor carpet; Buildings.luau swaps in the owner's pick
	mat(base, "CarpetCrimson")
	base.Parent = m
	m.PrimaryPart = base
	local front = -ARM.PlotD / 2 -- local z of the casino front edge
	local ent = Instance.new("Attachment")
	ent.Name = "Entrance"
	ent.Position = Vector3.new(0, Y.Walk - 0.5, front - 8.5) -- on the sidewalk, in front of the carpet
	ent.Parent = base
	-- where it sits in the plan (CityLayout.bayForPlot reads Arm / Slot / Side)
	m:SetAttribute("PlotIndex", entry.index)
	m:SetAttribute("Arm", entry.arm)
	m:SetAttribute("Slot", entry.k)
	m:SetAttribute("Side", entry.side)
	m.Parent = plotsFolder

	-- frontage sits inside the plot model: Plots.luau finds the pylon's
	-- "OwnerSign" there and writes the casino name onto it
	local f = folder("Frontage", m)
	redCarpet(f, 8, 11.4, at(0, Y.Walk, front - 5.7)) -- stops just short of the curb
	-- the casino building itself (walls, entrance, porte-cochère, floors,
	-- lights) is built at runtime by Buildings.luau + Facade.luau; out front:
	-- ropes, the pylon, low hedges. The pylon stands 10 out (its 6-long sign
	-- clears the cornice by 3.75); the 14-long planters sit just off the
	-- facade's granite bases, between the porte-cochère columns (x ±15.5)
	-- and the corner uplights, their hedge top 1.8 above the walk. The curb
	-- lane in front is the taxi bay: no parked car there any more.
	for _, sx in { -1, 1 } do
		place(Props.stanchions(8), f, at(sx * 4.7, Y.Walk, front - 2.6))
	end
	tagModel(place(Props.pylon(), f, at(-33, Y.Walk, front - 10)), "CasinoProp")
	for _, sx in { -1, 1 } do
		place(Props.planter(14, 1.6, 1.0, 0.8), f, at(sx * 26, Y.Walk, front - 3.5))
	end
	tagModel(place(Props.hoarding(ARM.PlotW), f, at(0, Y.City, ARM.PlotD / 2 + 7)), "CasinoProp")
end

local function buildAlleys(map)
	local f = folder("Alleys", map)
	for _, arm in CL.RingOrder do
		for _, side in { -1, 1 } do
			local plots = plotsOn(arm, side)
			for k = 0, ARM.SlotsPerSide - 2 do
				if plots[k] and plots[k + 1] then
					local s = (CL.slotS(k) + CL.slotS(k + 1)) / 2
					local m = newModel("AlleyLights", f)
					local bulbs = folder("Bulbs", m)
					local near = CL.toWorld(arm, s, side * (ARM.WalkOuter + 1), Y.City)
					local far = CL.toWorld(arm, s, side * (CL.PlotBack - 2), Y.City)
					for _, p in { near, far } do
						Props.brass(K.cylY(m, "Post", 0.5, 10, p + Vector3.new(0, 5, 0), WP.Brass, {}))
					end
					Props.stringLights(bulbs, near + Vector3.new(0, 9.6, 0), far + Vector3.new(0, 9.6, 0), 2.2, 18)
					m.WorldPivot = CFrame.new((near + far) / 2) -- MachineFX measures its chase range from here
					tagModel(m, "CasinoProp")
				end
			end
		end
	end
end

------------------------------------------------------------------
-- 6) the Machine Showroom's slot (south arm, west side, farthest out): no
-- plot; Showroom.luau builds the hall at runtime with its front on the plot
-- line, its portal + canopy + wheel reaching out to |t| ~27. Out here: the
-- runner from the curb to its doorway, roped, two tall palms in front of
-- the glass wings (clear of the portal and the wheel), searchlights, and a
-- lawn behind the hall (it reaches past the casinos' back line into the
-- block behind: the Rebirth Wing made it deeper) with a clipped hedge.
------------------------------------------------------------------
local function buildShowroomFront(map)
	local f = folder("ShowroomFront", map)
	local sl = CL.ShowroomSlot
	local arm, side = sl.arm, sl.side
	local a = CL.Arms[arm]
	local s = CL.slotS(sl.k)
	local into = a.lat * side -- from the road toward the hall
	local function at(ss, t, y) return CL.toWorld(arm, ss, side * t, y) end
	local t0, t1 = ARM.RoadHalf + 0.55, ARM.WalkOuter - 0.05
	local mid = at(s, (t0 + t1) / 2, Y.Walk)
	redCarpet(f, 12, t1 - t0, facing(mid, into))
	for _, e in { -1, 1 } do
		place(Props.stanchions(7), f, facing(at(s + e * 6.9, t0 + 0.6, Y.Walk), into))
	end
	local seed = 60
	for _, e in { -1, 1 } do
		local p = at(s + e * 32, ARM.RoadHalf + 2.6, Y.Walk)
		local palm = place(Props.palm(seed, 29), f, CFrame.new(p))
		-- the up-light beside its pot, on the outer side (the walk is narrow here)
		local up = K.part(palm, "Uplight", Vector3.new(0.6, 0.2, 0.6), CFrame.new(p + a.out * (e * 2.6) + Vector3.new(0, 0.1, 0)),
			WP.DarkMetal, decor())
		Props.night(K.new("SpotLight", { Face = Enum.NormalId.Top, Angle = 40, Range = 32, Brightness = 2.6, Shadows = false,
			Color = e > 0 and WP.Magenta or WP.Cyan }, up))
		seed += 1
		tagModel(atomic(place(Props.searchlight(), f, CFrame.new(at(s + e * 18, ARM.RoadHalf + 2.8, Y.Walk)))), "MapSearchlight")
	end
	-- the lawn from the hall's back wall out to t 152 (the block's towers start
	-- past t 160), a clipped hedge along its far edge
	armBox(f, "Lawn", arm, s - 51, s + 51, side * (SHOWROOM_BACK_T - 1.5), side * 152, Y.City, Y.Bed, WP.Lawn,
		{ material = Enum.Material.Grass, solid = true, shadow = false })
	local hedge = armBox(f, "Hedge", arm, s - 50, s + 50, side * 149.8, side * 151.6, Y.Bed, Y.Bed + 1.6, WP.Lawn, decor())
	local baked = (Mats.Defs.Hedge or {}).color
	mat(hedge, "Hedge", (baked == nil or baked == "") and WP.Lawn or nil)
end

------------------------------------------------------------------
-- 7) the plaza: a tiled field in a stone band, a # of walking lines from
-- the eight zebras, round planters with palms + searchlights in the
-- corners. Centre: the Jackpot Fountain. South: the hall of fame (spawn and
-- the three leaderboards facing it). North: the welcome sign. East: the
-- daily-reward and VIP kiosks. West: the services desk (Showroom.luau builds
-- it at Config.Showroom.ServicesCFrame) and two food carts.
------------------------------------------------------------------
local function buildPlaza(map, report)
	local p = folder("Plaza", map)
	local edge, cc = RING.PlazaHalf, RING.CornerC -- 88, 75
	local F = edge - 4 -- the tiled field: 168 = 14 whole 12-stud texture tiles
	local walk = Y.Walk

	mat(slab(p, "PlazaFloor", -F, F, -F, F, walk, 0.8, WP.Plaza, Enum.Material.Pavement, solid()), "PlazaTile", WP.Plaza)
	for _, arm in CL.RingOrder do
		local x0, x1, z0, z1 = armRect(arm, F, edge, -cc, cc)
		mat(slab(p, "PlazaBand", x0, x1, z0, z1, walk, 0.8, WP.PlazaBand, Enum.Material.Concrete, solid()), "SmoothConcrete",
			WP.PlazaBand)
		x0, x1, z0, z1 = armRect(arm, edge - 0.52, edge + 0.02, -cc, cc)
		mat(slab(p, "Curb", x0, x1, z0, z1, CURB_TOP, CURB_TOP, WP.Curb, Enum.Material.Concrete, solid()), "SmoothConcrete", WP.Curb)
	end
	-- the walking lines: a # of darker pavers (north-south ones run through,
	-- east-west ones stop at them)
	local paths = folder("Paths", p)
	local P0, P1 = CROSS_T - CROSS_HALF, CROSS_T + CROSS_HALF -- 25, 33
	for _, sx in { -1, 1 } do
		mat(slab(paths, "Path", sx * P0, sx * P1, -F, F, walk + 0.05, 0.1, WP.PlazaBand, Enum.Material.Pavement, solid()), "Pavers",
			WP.PlazaBand)
		for _, run in { { -F, -P1 }, { -P0, P0 }, { P1, F } } do
			mat(slab(paths, "Path", run[1], run[2], sx * P0, sx * P1, walk + 0.05, 0.1, WP.PlazaBand, Enum.Material.Pavement,
				solid()), "Pavers", WP.PlazaBand)
		end
	end

	-- the round corners are raised planters (r 13: the plaza's own corner
	-- radius, so their kerb is the ring road's inner edge there), each with
	-- two up-lit palms and a searchlight
	local seed = 40
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			local c = Vector3.new(sx * cc, 0, sz * cc)
			local r = edge - cc
			Props.granite(K.cylY(p, "PlanterKerb", r * 2, 1.4, c + Vector3.new(0, 0.7, 0), WP.Granite, solid()))
			Props.brass(K.cylY(p, "PlanterCap", r * 2 + 0.2, 0.1, c + Vector3.new(0, 1.45, 0), WP.Brass, decor()))
			K.cylY(p, "PlanterLawn", r * 2 - 1.6, 0.1, c + Vector3.new(0, 1.5, 0), WP.Lawn, { material = Enum.Material.Grass, shadow = false })
			local perp = Vector3.new(sx, 0, -sz).Unit
			for _, e in { -1, 1 } do
				local pos = c + perp * (e * 5)
				local palm = place(Props.palm(seed, 23 + (seed % 3) * 2, { bare = true }), p, CFrame.new(pos + Vector3.new(0, 1.5, 0)))
				local inward = -c.Unit
				local up = K.part(palm, "Uplight", Vector3.new(0.6, 0.2, 0.6), CFrame.new(pos + inward * 1.6 + Vector3.new(0, 1.6, 0)),
					WP.DarkMetal, decor())
				Props.night(K.new("SpotLight", { Face = Enum.NormalId.Top, Angle = 40, Range = 30, Brightness = 2.6, Shadows = false,
					Color = (seed % 2 == 0) and WP.Magenta or WP.Cyan }, up))
				seed += 1
			end
			tagModel(atomic(place(Props.searchlight(), p, CFrame.new(c + Vector3.new(0, 1.55, 0)))), "MapSearchlight")
		end
	end

	-- the Jackpot Fountain: a brim-full round basin (brass lip, a pool floor
	-- that glows after dark) in a wine-stone inlay with brass rays, the chip
	-- and dice sculpture in the middle, twelve dancing jets round it
	local fountain = folder("Fountain", p)
	local function disc(name, d, y0, y1, color, opts)
		return K.cylY(fountain, name, d, y1 - y0, Vector3.new(0, (y0 + y1) / 2, 0), color, opts)
	end
	-- every disc's top clears the one below by >= 0.05: neon 0.05 < fill 0.1 < rays 0.15
	Props.nightNeon(disc("InlayNeon", 48, walk, walk + 0.05, WP.Magenta, { material = Enum.Material.Neon, shadow = false }), WP.Magenta)
	mat(disc("InlayFill", 46.4, walk, walk + 0.1, WP.Wine, solid()), "HonedStone", WP.Wine)
	for k = 0, 15 do
		local ang = k * math.pi / 8
		local d = Vector3.new(math.cos(ang), 0, math.sin(ang))
		local o = Vector3.new(0, walk + 0.075, 0)
		mat(K.part(fountain, "InlayRay", Vector3.new(0.6, 0.15, 5), CFrame.lookAt(o + d * 19.5, o + d * 25), WP.Brass, solid()),
			"Brass", WP.Brass)
	end
	Props.granite(disc("Basin", 32, walk, 1.6, WP.Granite, solid()))
	Props.brass(disc("BasinLip", 32.6, 1.6, 1.75, WP.Brass, solid()))
	Props.nightNeon(disc("PoolGlow", 30.2, 1.75, 1.8, WP.Cyan, { material = Enum.Material.Neon, shadow = false }), WP.Cyan, POOL_FLOOR)
	disc("Water", 30.8, 1.6, 1.85, POOL_WATER, { shadow = false, reflectance = 0.25, transparency = 0.3 })
	place(Props.jackpotSculpture(), fountain, CFrame.new(0, 1.6, 0) * CFrame.Angles(0, math.rad(12), 0))
	local jets = folder("FountainJets", fountain)
	for k = 0, 11 do
		local ang = k * math.pi / 6 + math.pi / 12
		local jet = place(Props.fountainJet(9 + (k % 3) * 2), jets, CFrame.new(math.cos(ang) * 12.5, 1.8, math.sin(ang) * 12.5))
		jet:SetAttribute("Order", k / 12)
		tagModel(atomic(jet), "MapFountainJet")
	end
	for k = 0, 3 do
		local ang = k * math.pi / 2 + math.pi / 4
		local pos = Vector3.new(math.cos(ang) * 7, 1.85, math.sin(ang) * 7)
		local up = K.part(fountain, "Uplight", Vector3.new(0.8, 0.3, 0.8), CFrame.lookAt(pos, Vector3.new(0, 30, 0)), WP.DarkMetal, decor())
		Props.night(K.new("SpotLight", { Face = Enum.NormalId.Front, Angle = 35, Range = 34, Brightness = 2.4, Shadows = false,
			Color = WP.WarmNeon }, up))
	end

	-- the hall of fame: the spawn medallion (inlay rings) and the three boards
	-- on a circle round it, all facing it; the spawn faces them (south)
	local hall = folder("HallOfFame", p)
	local spawnPos = Vector3.new(0, walk, HALL_Z)
	local function medallion(name, d, top, color, opts)
		return K.cylY(hall, name, d, top, spawnPos + Vector3.new(0, top / 2, 0), color, opts)
	end
	Props.nightNeon(medallion("InlayNeon", 22, 0.05, WP.Magenta, { material = Enum.Material.Neon, shadow = false }), WP.Magenta)
	mat(medallion("InlayFill", 20.4, 0.1, WP.Wine, solid()), "HonedStone", WP.Wine)
	mat(medallion("InlayGold", 13, 0.15, WP.Brass, solid()), "Brass", WP.Brass)
	mat(medallion("InlayCore", 11.6, 0.2, WP.Ivory, solid()), "HonedStone", WP.Ivory)
	for k = 0, 7 do
		local ang = k * math.pi / 4 + math.pi / 8
		local d = Vector3.new(math.cos(ang), 0, math.sin(ang))
		local o = spawnPos + Vector3.new(0, 0.075, 0)
		mat(K.part(hall, "InlayRay", Vector3.new(0.5, 0.15, 2.8), CFrame.lookAt(o + d * 8.3, o + d * 10), WP.Brass, solid()), "Brass", WP.Brass)
	end
	-- spawn medallion: on the walk, its top at walk + 0.3 (0.1 above the core),
	-- so its corners, which reach past the core over the rings, never float
	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "StripSpawn"
	spawn.Anchored = true
	spawn.Size = Vector3.new(10, 0.3, 10)
	spawn.CFrame = CFrame.new(spawnPos + Vector3.new(0, 0.15, 0)) * CFrame.Angles(0, math.pi, 0) -- faces +Z: the boards
	mat(spawn, "Brass", WP.Brass)
	spawn.Neutral = true
	spawn.Duration = 0
	spawn.AllowTeamChangeOnTouch = false
	for _, d in spawn:GetChildren() do if d:IsA("Decal") then d:Destroy() end end
	local sg = K.surface(spawn, Enum.NormalId.Top, 40, 0)
	K.guiImage(sg, UIAssets.Icons.star, { size = UDim2.fromScale(0.8, 0.8) })
	spawn.Parent = Workspace
	report.spawn = spawn:GetFullName()
	-- left to right as seen from the spawn: cash, lifetime earnings, size
	for _, b in {
		{ kind = "cash", title = "HIGH ROLLERS", sub = "THIS SERVER  •  CASH ON HAND", angle = 60 },
		{ kind = "earned", title = "TOP CASINOS", sub = "THIS SERVER  •  TOTAL EARNED", angle = 0 },
		{ kind = "size", title = "BIGGEST CASINOS", sub = "THIS SERVER  •  FLOORS & MACHINES", angle = -60 },
	} do
		local ang = math.rad(b.angle)
		local pos = spawnPos + Vector3.new(math.sin(ang), 0, math.cos(ang)) * HALL_R
		local board = tagModel(place(Props.leaderboard(b.title, b.sub), hall, facing(pos, spawnPos - pos)), "CasinoProp")
		local face = board:FindFirstChild("Board")
		face:SetAttribute("Board", b.kind)
		CollectionService:AddTag(face, "LeaderboardBoard")
	end

	-- north: the welcome sign, facing the fountain
	tagModel(place(Props.welcomeSign(), p, CFrame.new(0, walk, -56) * CFrame.Angles(0, math.pi, 0)), "CasinoProp")

	-- east: the kiosks, facing the fountain
	for _, spec in { { "daily", -9 }, { "store", 9 } } do
		local kiosk = place(Props.kiosk(spec[1]), p, CFrame.new(54, walk, spec[2]) * CFrame.Angles(0, math.pi / 2, 0))
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

	-- west: food carts either side of the services desk (built at runtime)
	for _, spec in { { "hotdog", -16 }, { "popcorn", 16 } } do
		place(Props.foodCart(spec[1]), p, CFrame.new(-50, walk, spec[2]) * CFrame.Angles(0, -math.pi / 2, 0))
	end

	-- festoons round the fountain: double lamps on its four diagonals, bulb
	-- strings from pole to pole
	local fest = folder("Festoons", p)
	local posts = { Vector3.new(21, 0, 21), Vector3.new(-21, 0, 21), Vector3.new(-21, 0, -21), Vector3.new(21, 0, -21) }
	for i, c in posts do
		place(Props.lamp(true), fest, along(c + Vector3.new(0, walk, 0), c))
		local strand = newModel("Festoon", fest)
		local nxt = posts[i % 4 + 1]
		Props.stringLights(folder("Bulbs", strand), c + Vector3.new(0, walk + 12.5, 0), nxt + Vector3.new(0, walk + 12.5, 0), 1.8, 16)
		strand.WorldPivot = CFrame.new((c + nxt) / 2 + Vector3.new(0, walk + 11, 0))
		tagModel(strand, "CasinoProp")
	end

	-- the four corner gardens between the walking lines: benches facing the
	-- fountain, a lamp, and hedge planters along both lines
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			for _, b in { { 44, 58 }, { 58, 44 } } do
				local pos = Vector3.new(sx * b[1], walk, sz * b[2])
				place(Props.bench(), p, facing(pos, -pos))
			end
			place(Props.lamp(true), p, along(Vector3.new(sx * 50, walk, sz * 50), Vector3.new(sx, 0, -sz)))
			place(Props.planter(18, 2.4, 1.2, 1.0), p, CFrame.new(sx * 58, walk, sz * 36.5))
			place(Props.planter(18, 2.4, 1.2, 1.0), p, CFrame.new(sx * 36.5, walk, sz * 58) * CFrame.Angles(0, math.pi / 2, 0))
		end
	end
end

------------------------------------------------------------------
-- 8) the tunnels and the valley wall. Each arm ends in a portal at s 432: a
-- stone headwall with twin bores (|t| 5..25, 17 high) either side of a
-- central wall, the road running on inside to s 480. The bores are dark
-- concrete with a few dim lamps near the mouth; three black veils deeper in
-- and a black end wall hide where the cars appear (s 470). A red-rock wall
-- runs round the whole valley square (432..~480), with rock masses round
-- and over each portal.
------------------------------------------------------------------
local function rockColor(rng): Color3
	return WP.RockA:Lerp(WP.RockB, rng:NextNumber())
end

local function buildTunnel(parent, arm: string)
	local a = CL.Arms[arm]
	local t = newModel("Tunnel" .. arm, parent)
	atomic(t)
	local S0, S1 = ARM.PortalS, ARM.PortalS + HEADWALL -- 432, 436
	local END = ARM.TunnelEndS                        -- 480
	local function box(name, s0, s1, t0, t1, y0, y1, color, opts)
		return armBox(t, name, arm, s0, s1, t0, t1, y0, y1, color, opts)
	end
	local stoneOpts = { material = Enum.Material.Limestone, solid = true, shadow = false }
	local DARK = WP.Ink:Lerp(WP.DarkMetal, 0.5)
	local darkOpts = { material = Enum.Material.Concrete, solid = true, shadow = false }

	-- the floor runs in under the headwall to the end wall
	mat(box("TunnelRoad", S0, END + 1, -TUNNEL_WALL, TUNNEL_WALL, 0, Y.Road, WP.Asphalt, darkOpts), "Asphalt", WP.Asphalt)

	-- headwall: jambs, the central wall's face, the lintel, the coping
	local JAMB = 40
	for _, sd in { -1, 1 } do
		mat(box("Headwall", S0, S1, sd * BORE_OUT, sd * JAMB, 0, BORE_TOP, WP.DeepStone, stoneOpts), "Ashlar", WP.DeepStone)
	end
	mat(box("Headwall", S0, S1, -BORE_IN, BORE_IN, 0, BORE_TOP, WP.DeepStone, stoneOpts), "Ashlar", WP.DeepStone)
	mat(box("Lintel", S0, S1, -JAMB, JAMB, BORE_TOP, 31, WP.DeepStone, stoneOpts), "Ashlar", WP.DeepStone)
	mat(box("Coping", S0 - 0.6, S1 + 0.6, -(JAMB + 1), JAMB + 1, 31, 32.2, WP.Stone, stoneOpts), "SmoothConcrete", WP.Stone)
	-- a pale stone surround round each bore, 0.8 proud of the face, and
	-- chamfered top corners
	for _, sd in { -1, 1 } do
		for _, e in { { BORE_IN - 2, BORE_IN }, { BORE_OUT, BORE_OUT + 2 } } do
			mat(box("Surround", S0 - 0.8, S0, sd * e[1], sd * e[2], 0, BORE_TOP + 2, WP.Stone, stoneOpts), "SmoothConcrete", WP.Stone)
		end
		mat(box("Surround", S0 - 0.8, S0, sd * BORE_IN, sd * BORE_OUT, BORE_TOP, BORE_TOP + 2, WP.Stone, stoneOpts), "SmoothConcrete",
			WP.Stone)
		for _, corner in { BORE_IN, BORE_OUT } do
			local inward = corner == BORE_IN and 1 or -1 -- toward the bore's middle
			local sm = (S0 + S1) / 2
			wedge(t, "Chamfer", CL.toWorld(arm, sm, sd * corner, BORE_TOP), CL.toWorld(arm, sm, sd * corner, BORE_TOP - 3),
				CL.toWorld(arm, sm, sd * (corner + inward * 3), BORE_TOP), HEADWALL, WP.DeepStone, stoneOpts)
		end
	end
	-- the gate sign on the lintel, lit by its own bulbs + glowing plate
	tagModel(place(Props.gateSign(GATE_NAMES[arm] or "CITY GATE", "★ CASINO MASTERS ★"), t,
		facing(CL.toWorld(arm, S0 - 0.65, 0, BORE_TOP + 3), -a.out)), "CasinoProp")

	-- inside: outer walls, the central wall, the ceiling, all dark
	for _, sd in { -1, 1 } do
		box("TunnelWall", S1, END + 1, sd * BORE_OUT, sd * TUNNEL_WALL, 0, BORE_TOP, DARK, darkOpts)
	end
	box("TunnelSpine", S1, END + 1, -BORE_IN, BORE_IN, 0, BORE_TOP, DARK, darkOpts)
	box("TunnelCeiling", S1, END + 1, -TUNNEL_WALL, TUNNEL_WALL, BORE_TOP, BORE_TOP + 1.5, DARK, darkOpts)
	-- black at the end: the end wall renders pure black (black Neon takes no light)
	box("TunnelEnd", END, END + 1, -TUNNEL_WALL, TUNNEL_WALL, Y.Road, BORE_TOP, BLACK,
		{ material = Enum.Material.Neon, solid = true, shadow = false })
	-- veils: each darkens what's behind it, so a car appearing at s 470 is
	-- hidden and emerges out of the dark (no collision, no raycasts)
	for _, s in { 452, 459, 466 } do
		for _, sd in { -1, 1 } do
			box("Veil", s - 0.1, s + 0.1, sd * BORE_IN, sd * BORE_OUT, Y.Road, BORE_TOP, BLACK, { transparency = 0.45, shadow = false })
		end
	end
	-- a few dim sodium lamps near the mouth (always on: it's a tunnel)
	for _, s in { 440, 447 } do
		for _, sd in { -1, 1 } do
			local fix = box("TunnelLamp", s - 0.7, s + 0.7, sd * (BORE_OUT - 0.4), sd * BORE_OUT, 11.5, 12.1, WP.Sodium, { shadow = false })
			K.new("PointLight", { Range = 14, Brightness = 0.7, Color = WP.Sodium, Shadows = false }, fix)
		end
	end
	return t
end

-- the rock round one portal: masses either side of the headwall, rock round
-- the bores behind it, a cap over the top and a plug behind the end wall
local function portalRock(parent, arm: string, rng)
	local function rock(s0, s1, t0, t1, y0, y1)
		armBox(parent, "Rock", arm, s0, s1, t0, t1, y0, y1, rockColor(rng),
			{ material = Enum.Material.Sandstone, solid = true, shadow = false })
	end
	local S1, top = ARM.PortalS + HEADWALL, 32.3 -- just over the coping
	for _, sd in { -1, 1 } do
		rock(ARM.PortalS - 1, 470, sd * 41, sd * 66, 0, rng:NextNumber(44, 54))
		rock(S1, 486, sd * (TUNNEL_WALL + 0.1), sd * 41, 0, top)
	end
	rock(S1 + 0.5, 488, -41, 41, top, rng:NextNumber(46, 52)) -- tucks over the coping's back edge
	rock(ARM.TunnelEndS + 1, 492, -(TUNNEL_WALL + 0.1), TUNNEL_WALL + 0.1, 0, top)
end

local function buildValley(map)
	local tunnels = folder("Tunnels", map)
	for _, arm in CL.RingOrder do buildTunnel(tunnels, arm) end

	-- the wall: per side two rows of big sandstone blocks (a lower front row,
	-- a taller back row) and a few fallen boulders at the foot. Every side
	-- runs t -475 .. 432 of its arm frame, so each corner is built once; the
	-- 44 studs either side of the portal are left to the portal's own rock.
	local wall = folder("ValleyWall", map)
	local rng = Random.new(4321)
	local V = CL.ValleyHalf
	for _, arm in CL.RingOrder do
		local side = newModel("Cliffs" .. arm, wall)
		slim(side)
		portalRock(side, arm, rng)
		local function block(name, s0, depth, t0, t1, h, yaw, material)
			local cf = armCF(arm, s0 + depth / 2, (t0 + t1) / 2, h / 2) * CFrame.Angles(0, math.rad(yaw), 0)
			K.part(side, name, Vector3.new(depth, h, math.abs(t1 - t0)), cf, rockColor(rng), { material = material, solid = true, shadow = false })
		end
		for row = 1, 2 do
			local t = -V - 43
			while t < V do
				local t1 = math.min(t + (row == 1 and rng:NextNumber(36, 58) or rng:NextNumber(50, 78)), V)
				if t < 44 and t1 > -44 then
					-- the portal's own rock covers |t| < 44: stop short of it, then jump past it
					if t >= -44 then
						t, t1 = 44, nil
					else
						t1 = -44
					end
				end
				if t1 then
					if row == 1 then
						block("Cliff", V - 1 + rng:NextNumber(0, 5), rng:NextNumber(24, 32), t, t1, rng:NextNumber(36, 50), rng:NextNumber(-5, 5),
							Enum.Material.Sandstone)
					else
						block("Cliff", V + 16 + rng:NextNumber(0, 8), rng:NextNumber(26, 36), t, t1, rng:NextNumber(48, 66),
							rng:NextNumber(-4, 4), Enum.Material.Sandstone)
					end
					t = t1
				end
			end
		end
		-- fallen boulders at the foot, away from the portal
		for k = 0, 9 do
			local tt = -V + 30 + k * 86 + rng:NextNumber(-12, 12)
			if math.abs(tt) > 70 and tt < V - 10 then
				local size = rng:NextNumber(8, 15)
				local cf = armCF(arm, V - 3 + size * 0.2, tt, size * 0.25) * CFrame.Angles(rng:NextNumber(-0.4, 0.4), rng:NextNumber(0, 6), 0.3)
				K.part(side, "Boulder", Vector3.new(size, size * 0.8, size * 1.1), cf, rockColor(rng),
					{ material = Enum.Material.Rock, solid = true, shadow = false })
			end
		end
	end

	-- distant mountains: clusters of cubes stood on a corner (pyramid peaks),
	-- half buried; the atmosphere haze turns them into soft silhouettes
	local mountains = Instance.new("Model")
	mountains.Name = "Mountains"
	local mrng = Random.new(77)
	local tilt = math.atan(1 / math.sqrt(2)) -- puts a cube's corner straight up
	for k = 0, 23 do
		local ang = k / 24 * math.pi * 2 + mrng:NextNumber(-0.06, 0.06)
		local r = mrng:NextNumber(1100, 1450)
		for _ = 1, mrng:NextInteger(2, 4) do
			local size = mrng:NextNumber(140, 320)
			local alongT = mrng:NextNumber(-140, 140)
			local tangent = Vector3.new(-math.sin(ang), 0, math.cos(ang))
			local pos = Vector3.new(math.cos(ang) * (r + mrng:NextNumber(-60, 60)), 0, math.sin(ang) * r) + tangent * alongT
			local cf = CFrame.new(pos.X, -size * 0.25, pos.Z) * CFrame.Angles(0, mrng:NextNumber(0, math.pi * 2), 0)
				* CFrame.Angles(tilt, 0, math.rad(45))
			K.part(mountains, "Peak", Vector3.new(size, size, size), cf, WP.RockA:Lerp(WP.RockB, mrng:NextNumber()), { shadow = false })
		end
	end
	mountains.Parent = map
	pcall(function() mountains.ModelStreamingMode = Enum.ModelStreamingMode.Persistent end)
end

------------------------------------------------------------------
-- 9) the four open blocks between the arms (CityLayout.Quadrants), behind
-- the casinos' back walls. Each block has a frame (u along its first arm,
-- v along the next arm round the ring); the first 18 studs behind every
-- casino row (the hoardings at 123) stay clear as a service strip, so
-- everything here starts at u, v = 134. Per block: a feature square on the
-- diagonal facing the plaza (the LED sphere / the observation wheel / a
-- palm garden / a parking lot), three resort towers on lawn skirts, two
-- parking lots, a palm grove and a gravel garden.
------------------------------------------------------------------
-- crown = a WorldPalette neon hue (4 on the skyline: Magenta, Cyan, Ruby, Amber)
local TOWERS = {
	AURORA = { w = 46, d = 34, h = 118, v = "CM_TowerWarm", crown = "Magenta" },
	["SILVER MOON"] = { w = 40, d = 40, h = 168, v = "CM_TowerCool", crown = "Cyan", tiers = { { 1, 120 }, { 0.78, 48 } } },
	["NEON OASIS"] = { w = 38, d = 38, h = 150, v = "CM_TowerCool", crown = "Magenta", tiers = { { 1, 100 }, { 0.8, 50 } } },
	["ROYAL FLUSH"] = { w = 48, d = 34, h = 104, v = "CM_TowerWarm", crown = "Ruby" },
	["HIGH CARD"] = { w = 40, d = 40, h = 136, v = "CM_TowerCool", crown = "Cyan" },
	EMERALD = { w = 42, d = 40, h = 140, v = "CM_TowerCool", crown = "Cyan", tiers = { { 1, 96 }, { 0.75, 44 } } },
	["GOLDEN PALM"] = { w = 50, d = 34, h = 98, v = "CM_TowerWarm", crown = "Amber" },
	STARLIGHT = { w = 40, d = 40, h = 176, v = "CM_TowerCool", crown = "Magenta", tiers = { { 1, 112 }, { 0.8, 40 }, { 0.6, 24 } } },
	RUBY = { w = 44, d = 34, h = 106, v = "CM_TowerWarm", crown = "Ruby" },
	JACKPOT = { w = 44, d = 36, h = 116, v = "CM_TowerWarm", crown = "Amber" },
	TITAN = { w = 40, d = 40, h = 158, v = "CM_TowerCool", crown = "Cyan", tiers = { { 1, 110 }, { 0.75, 48 } } },
	ORBIT = { w = 40, d = 40, h = 164, v = "CM_TowerCool", crown = "Cyan", tiers = { { 1, 118 }, { 0.78, 46 } } },
}

-- in CityLayout.Quadrants order (NE, NW, SW, SE): the block between RingOrder[i] and the next arm
local BLOCKS = {
	{ feature = "sphere", towers = { "AURORA", "SILVER MOON", "NEON OASIS" } },
	{ feature = "wheel", towers = { "ROYAL FLUSH", "HIGH CARD", "EMERALD" } },
	{ feature = "garden", towers = { "GOLDEN PALM", "STARLIGHT", "RUBY" } },
	{ feature = "lot", towers = { "JACKPOT", "TITAN", "ORBIT" } },
}
local TOWER_SPOTS = { { 200, 360 }, { 360, 200 }, { 362, 362 } } -- (u, v)
local FEATURE = { 142, 262 }                                     -- the feature square (u and v)
local LOTS = { { 272, 312, 142, 262 }, { 142, 262, 272, 312 } }  -- u0, u1, v0, v1 (40 x 120: one stall module)
local GROVE = { 246, 318, 324, 420 }
local GRAVEL = { 324, 420, 246, 318 }

local function faceCenterYaw(x, z)
	-- front (-Z) toward the origin, snapped to the street grid
	local yaw = math.atan2(x, z)
	return math.round(yaw / (math.pi / 2)) * (math.pi / 2)
end

-- a tower podium's world footprint x0, x1, z0, z1: MapProps.tower builds it
-- (w + 14) x (d + 14), turned by faceCenterYaw (a quarter turn swaps w and d)
local function podiumRect(spec, x, z)
	local pw, pd = spec.w + 14, spec.d + 14
	if math.abs(math.round(math.sin(faceCenterYaw(x, z)))) == 1 then pw, pd = pd, pw end
	return x - pw / 2, x + pw / 2, z - pd / 2, z + pd / 2
end

-- parking stalls: one Top-face Texture per lot, 7.5-stud stalls (U) in a
-- 40-stud double-loaded module (V). A Top face maps V onto the part's local X
-- (a Top SurfaceGui reads "up" toward -X): a lot whose module runs along world
-- Z is turned a quarter. If the stripes come out the wrong way in Studio, set
-- STALL_YAW to 0 (and swap the test below).
local STALL_YAW = math.pi / 2

local function lot(parent, x0, x1, z0, z1, stalls: boolean)
	local cx, cz, sx, sz = (x0 + x1) / 2, (z0 + z1) / 2, x1 - x0, z1 - z0
	-- the module runs across the lot's 40-multiple side (the shorter one if both are)
	local alongX = sx % 40 == 0 and (sz % 40 ~= 0 or sx <= sz)
	local turned = stalls and not alongX and STALL_YAW ~= 0
	local size = turned and Vector3.new(sz, 0.3, sx) or Vector3.new(sx, 0.3, sz)
	local cf = CFrame.new(cx, Y.Lot - 0.15, cz) * CFrame.Angles(0, turned and STALL_YAW or 0, 0)
	local p = mat(K.part(parent, stalls and "Lot" or "Drive", size, cf, WP.LotAsphalt,
		{ material = Enum.Material.Asphalt, solid = true, shadow = false }), "Asphalt", WP.LotAsphalt)
	local img = (Mats.Images or {}).ParkingStalls
	if stalls and img and img ~= "" then
		K.new("Texture", { Name = "Stalls", Texture = img, Face = Enum.NormalId.Top,
			StudsPerTileU = 7.5, StudsPerTileV = 40 }, p)
	end
	return p
end

local function bed(parent, kind: string, x0, x1, z0, z1)
	local lawn = kind == "lawn"
	return slab(parent, lawn and "Lawn" or "Gravel", x0, x1, z0, z1, Y.Bed, 0.45, lawn and WP.Lawn or WP.Gravel,
		lawn and Enum.Material.Grass or Enum.Material.Pebble, solid())
end

local function buildQuadrants(map, report, newWindows: { [string]: boolean })
	local q = folder("Quadrants", map)
	local towers = folder("Towers", q)
	local land = folder("Landmarks", q)
	local groves = folder("Groves", q)
	local zoning = Instance.new("Model")
	zoning.Name = "Zoning"
	local seed = 300
	local nTowers = 0
	for i, block in BLOCKS do
		local U, Vv = CL.Arms[CL.RingOrder[i]], CL.Arms[nextArm(CL.RingOrder[i])]
		local function pt(u, v, y) return U.out * u + Vv.out * v + Vector3.new(0, y or 0, 0) end
		local function rect(u0, u1, v0, v1)
			local p0, p1 = pt(u0, v0), pt(u1, v1)
			return math.min(p0.X, p1.X), math.max(p0.X, p1.X), math.min(p0.Z, p1.Z), math.max(p0.Z, p1.Z)
		end
		local function palmAt(u, v, h)
			place(Props.palm(seed, h or (19 + (seed % 4) * 2), { bare = true, lite = true }), groves, CFrame.new(pt(u, v, Y.Bed)))
			seed += 1
		end

		-- the feature square on the diagonal, in view of the plaza
		local fx0, fx1, fz0, fz1 = rect(FEATURE[1], FEATURE[2], FEATURE[1], FEATURE[2])
		local fc = pt((FEATURE[1] + FEATURE[2]) / 2, (FEATURE[1] + FEATURE[2]) / 2)
		if block.feature == "sphere" then
			bed(zoning, "gravel", fx0, fx1, fz0, fz1)
			local sphere = atomic(place(Props.sphere(80), land, CFrame.new(fc + Vector3.new(0, Y.City, 0))))
			tagModel(slim(sphere), "MapSphere")
			for _, c in { { 150, 150 }, { 254, 150 }, { 150, 254 }, { 254, 254 } } do palmAt(c[1], c[2]) end
		elseif block.feature == "wheel" then
			bed(zoning, "lawn", fx0, fx1, fz0, fz1)
			-- its face toward the plaza (the axle along the line of sight)
			local pos = fc + Vector3.new(0, Y.City, 0)
			local wheel = atomic(place(Props.wheel(), land, CFrame.lookAt(pos, Vector3.new(0, pos.Y, 0))))
			tagModel(slim(wheel), "MapWheel")
		elseif block.feature == "garden" then
			bed(zoning, "lawn", fx0, fx1, fz0, fz1)
			for _, c in { { 170, 172 }, { 205, 158 }, { 238, 180 }, { 168, 214 }, { 214, 206 }, { 182, 244 }, { 240, 236 } } do
				palmAt(c[1], c[2], 18 + (seed % 5) * 2)
			end
		else
			lot(zoning, fx0, fx1, fz0, fz1, true)
		end
		for _, l in LOTS do
			local x0, x1, z0, z1 = rect(l[1], l[2], l[3], l[4])
			lot(zoning, x0, x1, z0, z1, true)
		end
		local gx0, gx1, gz0, gz1 = rect(GROVE[1], GROVE[2], GROVE[3], GROVE[4])
		bed(zoning, "lawn", gx0, gx1, gz0, gz1)
		for _, c in { { 268, 346 }, { 298, 372 }, { 266, 400 } } do palmAt(c[1], c[2]) end
		gx0, gx1, gz0, gz1 = rect(GRAVEL[1], GRAVEL[2], GRAVEL[3], GRAVEL[4])
		bed(zoning, "gravel", gx0, gx1, gz0, gz1)

		-- the towers, each on a lawn skirt that stops at its podium's faces
		for j, name in block.towers do
			local spec = TOWERS[name]
			local spot = pt(TOWER_SPOTS[j][1], TOWER_SPOTS[j][2])
			-- the new window maps carry their own stone colour (untinted); the
			-- old navy fallback set gets the warm ivory tint
			local tint = newWindows[spec.v] and Color3.new(1, 1, 1) or WP.Ivory
			local tower = place(Props.tower({
				w = spec.w, d = spec.d, h = spec.h, variant = spec.v, crown = WP[spec.crown], name = name, tiers = spec.tiers, tint = tint,
			}), towers, CFrame.new(spot.X, Y.City, spot.Z) * CFrame.Angles(0, faceCenterYaw(spot.X, spot.Z), 0))
			slim(tower)
			nTowers += 1
			local x0, x1, z0, z1 = podiumRect(spec, spot.X, spot.Z)
			local m = 8
			bed(zoning, "lawn", x0 - m, x1 + m, z0 - m, z0)
			bed(zoning, "lawn", x0 - m, x1 + m, z1, z1 + m)
			bed(zoning, "lawn", x0 - m, x0, z0, z1)
			bed(zoning, "lawn", x1, x1 + m, z0, z1)
		end
	end
	zoning.Parent = q
	-- flat and cheap: keep it streamed in so the aerial never shows bare slab
	pcall(function() zoning.ModelStreamingMode = Enum.ModelStreamingMode.Persistent end)
	report.towers = nTowers
	report.zoning = countParts(zoning)
end

------------------------------------------------------------------
-- build everything
------------------------------------------------------------------
local MAP_BUDGET = 6000 -- static Map parts (the plots' frontage is counted apart)

function MapBuilder.build()
	local MM = fresh(ServerScriptService.CasinoServer.MachineModels)
	UIAssets = fresh(ReplicatedStorage.CasinoCommon.UIAssets)
	Mats = fresh(ReplicatedStorage.CasinoCommon.Materials)
	WP = fresh(ReplicatedStorage.CasinoCommon.WorldPalette)
	CL = fresh(ReplicatedStorage.CasinoCommon.CityLayout)
	ARM, RING, Y = CL.Arm, CL.Ring, CL.Y
	Props = fresh(ServerStorage.MapTools.MapProps)
	Props.init(MM, UIAssets, Mats, WP)
	K = MM.Kit

	local report = {}
	moveLegacy(report)
	local newWindows = windowVariants()
	report.towerMaps = (newWindows.CM_TowerWarm and newWindows.CM_TowerCool) and "stone (Materials.Images)"
		or ((newWindows.CM_TowerWarm or newWindows.CM_TowerCool) and "mixed: stone + navy fallback"
		or "navy fallback (UIAssets.Windows)")
	report.materials = Mats.ensure()   -- the PBR set, saved with the place

	local map = Instance.new("Folder")
	map.Name = "Map"
	map:SetAttribute("MapBuilder", true)
	local plots = Instance.new("Folder")
	plots.Name = "Plots"
	plots:SetAttribute("MapBuilder", true)

	buildGround(map)
	buildRing(map)
	for _, arm in CL.RingOrder do buildArm(map, arm) end
	for _, entry in CL.Plots do buildPlot(plots, entry) end
	buildAlleys(map)
	buildShowroomFront(map)
	buildPlaza(map, report)
	buildValley(map)
	buildQuadrants(map, report, newWindows)

	map.Parent = Workspace
	plots.Parent = Workspace

	-- the Studio view matches what players see at this clock time (the shared
	-- lighting presets, when that module is in the place)
	local presets = ReplicatedStorage.CasinoCommon:FindFirstChild("LightingPresets")
	if presets then
		report.lighting = pcall(function()
			local LP = fresh(presets)
			LP.apply(LP.sample(Lighting.ClockTime))
		end)
	end

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

	-- part count per Map folder (and the plots), checked against the budget
	report.folders = {}
	local names = {}
	for _, child in map:GetChildren() do
		report.folders[child.Name] = countParts(child)
		table.insert(names, child.Name)
	end
	table.sort(names)
	local counts = {}
	for _, name in names do table.insert(counts, ("%s %d"):format(name, report.folders[name])) end
	report.plotParts = countParts(plots)
	print(("[MapBuilder] Map %d parts (%s) | Plots %d parts | %d lights, %d bulbs"):format(
		parts, table.concat(counts, ", "), report.plotParts, lights, bulbs))
	if parts > MAP_BUDGET then
		warn(("[MapBuilder] Map has %d parts, over the %d budget"):format(parts, MAP_BUDGET))
	end
	return report
end

return MapBuilder
