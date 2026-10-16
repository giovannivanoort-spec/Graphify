--!nonstrict
-- Traffic.luau — the city's cars. The SERVER plans every car; each client
-- drives them (CasinoClient/TrafficClient), so no car is ever streamed and
-- none of them touch anything (they're visual only).
--   * a car = a RoadNet route spec + a start time on the server clock: it
--     comes out of a tunnel, drives the lanes and leaves through a tunnel
--   * customers arrive by car (requestDropoff): a taxi / car for up to 4, a
--     Party Shuttle van for bigger groups, the limo for VIPs (van and limo
--     seat 8; a bigger party comes in several cars) pulls into one of the
--     casino's curb stops (drop-offs take turns over them), its passengers
--     step out and walk in. Leaving patrons wait at the curb and ride off
--     (requestPickup), sharing any car that's coming to that curb with a
--     free seat (a drop-off takes riders too)
--   * through traffic between the tunnels keeps the roads alive
--   * the curb only throttles VISIBLE guests (a party is visible guests,
--     whatever guest weight the NPC flow gives them): curbCarsPerMinute /
--     curbCapacityPerMinute / curbBacklog / maxPartySize tell the flow how
--     much it can send
-- Scheduling: RoadNet's speed profiles depend only on position, so cars on
-- the same stretch keep their time gap. Every car books the merge points it
-- passes (tunnel mouths, ring entries, curb re-entries) Headway apart from
-- every other booking there. In a casino's valet lane (its 1-3 curb stops,
-- more with the owner's Parking upgrade) cars move like a queue: each new
-- car is checked against the others in there (boxes in the arm's frame, every
-- 0.1 s), BayGap studs apart bumper to bumper; it takes the stop it reaches
-- first (the front one, at the entrance, on a near tie). A new car's start is
-- searched forward (it waits unseen in its tunnel); a car at a stop may
-- instead wait a little longer at the curb, for a gap or for the cars ahead
-- of it to pull away.
-- Replication: TrafficCar fires { id, spec, t0, kind, color } to everyone;
-- GetTrafficCars hands late joiners the cars still on the road.
-- Templates: ReplicatedStorage.TrafficCars (Taxi / Limo / Sedan / Sport /
-- Van), built at start from MapProps.car (ServerStorage.MapTools, like
-- Facade's searchlights; the van with the machines' kit) or simple stand-ins
-- when those aren't there.
-- Markings: a yellow VALET box per extra stop (the map paints the base stop's
-- TAXI box), Workspace.TrafficBays.<plot>, redrawn when a plot's owner or
-- Parking level changes.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Config = require(Common:WaitForChild("Config"))
local Remotes = require(Common:WaitForChild("Remotes"))
local CityLayout = require(Common:WaitForChild("CityLayout"))
local RoadNet = require(Common:WaitForChild("RoadNet"))
local WP = require(Common:WaitForChild("WorldPalette"))
local DayNight = require(script.Parent:WaitForChild("DayNight"))

local Traffic = {}
local Upgrades -- (Traffic.start deps) the owners' Parking (extra curb stops) and Party Shuttles upgrades

local TC = Config.Traffic
local ARMS = CityLayout.RingOrder
local EMPTY = {}
local rng = Random.new()

local running = false
local cars = {}      -- id -> { id, spec, t0, kind, color, route, tEnd } until it's back in a tunnel
local carCount = 0
local nextId = 0
local booked = {}    -- merge point id -> { server times a car passes it }
local zoneCars = {}  -- casino zone id -> { { t0, dwell, track } }: customer cars in (or due in) its valet lane
local stops = {}     -- casino zone id -> { stop }: customer cars due at / standing at its curb

local function now(): number
	return Workspace:GetServerTimeNow()
end

------------------------------------------------------------------
-- car templates (ReplicatedStorage.TrafficCars), model space: ground origin,
-- nose at -Z
------------------------------------------------------------------
local function templateName(kind: string): string
	return kind:sub(1, 1):upper() .. kind:sub(2)
end

local mapProps -- false once we know the map tools aren't reachable
local function loadMapProps()
	if mapProps == nil then
		mapProps = false
		local ok, props = pcall(function()
			local tools = ServerStorage:FindFirstChild("MapTools")
			local module = tools and tools:FindFirstChild("MapProps")
			if not (module and module:IsA("ModuleScript")) then return nil end
			local mod = require(module)
			mod.init(require(script.Parent:WaitForChild("MachineModels")), require(Common:WaitForChild("UIAssets")),
				require(Common:WaitForChild("Materials")), require(Common:WaitForChild("WorldPalette")))
			return mod
		end)
		if ok and props then mapProps = props end
	end
	return mapProps or nil
end

local function plainPart(m: Model, name: string, size: Vector3, cf: CFrame, color: Color3, material, shape)
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	if shape then p.Shape = shape end
	p.Parent = m
	return p
end

-- the stand-in when MapProps isn't there: same proportions as MapProps.car
local function simpleCar(kind: string): Model
	local m = Instance.new("Model")
	local L, W = kind == "limo" and 17 or 11, 5.2
	local body = (kind == "taxi" and Color3.fromRGB(255, 194, 26)) or (kind == "limo" and Color3.fromRGB(21, 19, 26))
		or Color3.fromRGB(215, 38, 61)
	local cabL = kind == "limo" and 10.5 or 5.6
	plainPart(m, "Body", Vector3.new(W, 1.7, L), CFrame.new(0, 1.75, 0), body)
	plainPart(m, "Cabin", Vector3.new(W - 0.6, 1.5, cabL), CFrame.new(0, 3.3, 0.6), Color3.fromRGB(26, 36, 51))
	plainPart(m, "Roof", Vector3.new(W - 0.7, 0.18, cabL - 0.4), CFrame.new(0, 4.12, 0.6), body)
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			plainPart(m, "Tire", Vector3.new(0.8, 2.2, 2.2), CFrame.new(sx * (W / 2 - 0.3), 1.1, sz * (L / 2 - 2.2)),
				Color3.fromRGB(14, 14, 18), nil, Enum.PartType.Cylinder)
		end
		plainPart(m, "Headlight", Vector3.new(1.1, 0.45, 0.1), CFrame.new(sx * 1.75, 2.0, -L / 2 - 0.04),
			Color3.fromRGB(255, 244, 214), Enum.Material.Neon)
		plainPart(m, "Taillight", Vector3.new(1.1, 0.4, 0.1), CFrame.new(sx * 1.85, 2.05, L / 2 + 0.04),
			Color3.fromRGB(255, 77, 99), Enum.Material.Neon)
	end
	if kind == "taxi" then
		plainPart(m, "TaxiSign", Vector3.new(1.8, 0.6, 0.5), CFrame.new(0, 4.5, 0.6), Color3.fromRGB(255, 241, 194))
	end
	return m
end

-- the sports car: the same car with a low, short glasshouse and a rear wing
local function sportify(m: Model)
	local body, cabin, roof = m:FindFirstChild("Body"), m:FindFirstChild("Cabin"), m:FindFirstChild("Roof")
	if cabin then
		cabin.Size = Vector3.new(cabin.Size.X - 0.2, 1.1, 4.8)
		cabin.CFrame = CFrame.new(0, 3.1, 1.0)
	end
	if roof then
		roof.Size = Vector3.new(roof.Size.X - 0.2, roof.Size.Y, 4.4)
		roof.CFrame = CFrame.new(0, 3.72, 1.0)
	end
	if body then
		local L, W = body.Size.Z, body.Size.X
		plainPart(m, "Spoiler", Vector3.new(W - 0.4, 0.14, 1.1), CFrame.new(0, 3.25, L / 2 - 0.75), body.Color)
		for _, sx in { -1, 1 } do
			plainPart(m, "SpoilerPost", Vector3.new(0.2, 0.62, 0.4), CFrame.new(sx * (W / 2 - 1.1), 2.88, L / 2 - 0.75),
				Color3.fromRGB(17, 16, 22))
		end
	end
end

-- visual only: anchored (the clients move them), no collisions, raycasts or
-- touches; only the body casts a shadow (they move every frame)
local function finishTemplate(m: Model, name: string)
	m.Name = name
	for _, d in m:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.CastShadow = d.Name == "Body"
		end
	end
	m.WorldPivot = CFrame.new()
end

-- the Party Shuttle: a 14-long minibus with 8 seats for the big groups (MapProps
-- has none), built with the machines' kit so it matches MapProps.car: glossy
-- body, a tall passenger box with a smoked glass band, chrome rims, a gold
-- light bar and PARTY SHUTTLE down both flanks
local VAN_L = 14
local function buildVan(): Model
	local MM = require(script.Parent:WaitForChild("MachineModels"))
	local K, P = MM.Kit, MM.Palette
	local m = Instance.new("Model")
	local L, W = VAN_L, 5.2
	local body = K.hex("#5C2C8C")
	K.part(m, "Body", Vector3.new(W, 2.1, L), CFrame.new(0, 1.95, 0), body, { reflectance = 0.25, solid = true })
	K.part(m, "Skirt", Vector3.new(W - 0.1, 0.5, L - 0.6), CFrame.new(0, 0.9, 0), K.hex("#111016"), { shadow = false })
	-- the passenger box, set back behind a short nose
	K.part(m, "Roof", Vector3.new(W - 0.3, 1.9, L - 2.4), CFrame.new(0, 3.95, 1.0), body, { reflectance = 0.25 })
	K.part(m, "Glass", Vector3.new(W - 0.24, 1.0, L - 3.4), CFrame.new(0, 4.05, 1.1), K.hex("#1A2433"), { reflectance = 0.35 })
	K.part(m, "Windshield", Vector3.new(W - 0.5, 1.5, 0.2), CFrame.new(0, 3.95, 1.0 - (L - 2.4) / 2 - 0.1), K.hex("#1A2433"),
		{ reflectance = 0.35, shadow = false })
	K.neon(m, "LightBar", Vector3.new(3.4, 0.25, 0.6), CFrame.new(0, 5.02, -3.6), P.Gold)
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			local wp = Vector3.new(sx * (W / 2 - 0.3), 1.1, sz * (L / 2 - 2.4))
			K.cylX(m, "Tire", 2.2, 0.8, wp, K.hex("#0E0E12"), { shadow = false })
			K.cylX(m, "Rim", 1.2, 0.86, wp, P.Chrome, { reflectance = 0.3, material = Enum.Material.Metal, shadow = false })
		end
		K.neon(m, "Headlight", Vector3.new(1.1, 0.45, 0.1), CFrame.new(sx * 1.75, 2.0, -L / 2 - 0.04), K.hex("#FFF4D6"))
		K.neon(m, "Taillight", Vector3.new(1.0, 0.5, 0.1), CFrame.new(sx * 1.9, 2.4, L / 2 + 0.04), K.hex("#FF4D63"))
		local stripe = K.part(m, "Stripe", Vector3.new(0.06, 0.6, L - 3), CFrame.new(sx * (W / 2 + 0.02), 2.3, 0.4), P.Ink,
			{ shadow = false })
		local g = K.surface(stripe, sx > 0 and Enum.NormalId.Right or Enum.NormalId.Left, 40, 0.3)
		K.guiText(g, "PARTY SHUTTLE", { color = P.Gold, stroke = false, font = Enum.Font.GothamBlack })
	end
	K.part(m, "Grille", Vector3.new(2.2, 0.6, 0.08), CFrame.new(0, 1.8, -L / 2 - 0.04), P.Chrome,
		{ reflectance = 0.3, material = Enum.Material.Metal, shadow = false })
	return m
end

-- (and its stand-in when the kit isn't there)
local function simpleVan(): Model
	local m = Instance.new("Model")
	local L, W = VAN_L, 5.2
	local body = Color3.fromRGB(92, 44, 140)
	plainPart(m, "Body", Vector3.new(W, 2.1, L), CFrame.new(0, 1.95, 0), body)
	plainPart(m, "Roof", Vector3.new(W - 0.3, 1.9, L - 2.4), CFrame.new(0, 3.95, 1.0), body)
	plainPart(m, "Glass", Vector3.new(W - 0.24, 1.0, L - 3.4), CFrame.new(0, 4.05, 1.1), Color3.fromRGB(26, 36, 51))
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			plainPart(m, "Tire", Vector3.new(0.8, 2.2, 2.2), CFrame.new(sx * (W / 2 - 0.3), 1.1, sz * (L / 2 - 2.4)),
				Color3.fromRGB(14, 14, 18), nil, Enum.PartType.Cylinder)
		end
		plainPart(m, "Headlight", Vector3.new(1.1, 0.45, 0.1), CFrame.new(sx * 1.75, 2.0, -L / 2 - 0.04),
			Color3.fromRGB(255, 244, 214), Enum.Material.Neon)
		plainPart(m, "Taillight", Vector3.new(1.0, 0.5, 0.1), CFrame.new(sx * 1.9, 2.4, L / 2 + 0.04),
			Color3.fromRGB(255, 77, 99), Enum.Material.Neon)
	end
	return m
end

local function buildTemplates()
	local old = ReplicatedStorage:FindFirstChild("TrafficCars")
	if old then old:Destroy() end
	local folder = Instance.new("Folder")
	folder.Name = "TrafficCars"
	local props = loadMapProps()
	for _, kind in { "taxi", "limo", "sedan", "sport", "van" } do
		local m
		if kind == "van" then
			local ok, built = pcall(buildVan)
			if ok and built then m = built end
			m = m or simpleVan()
		else
			if props then
				local ok, built = pcall(props.car, kind)
				if ok and built then m = built end
			end
			m = m or simpleCar(kind)
		end
		if kind == "sport" then sportify(m) end
		finishTemplate(m, templateName(kind))
		m.Parent = folder
	end
	folder.Parent = ReplicatedStorage
	return props ~= nil
end

------------------------------------------------------------------
-- kinds and colours
------------------------------------------------------------------
local function pickWeighted(weights): string
	local total = 0
	for _, w in weights do total += w end
	local r = rng:NextNumber() * total
	for kind, w in weights do
		r -= w
		if r <= 0 then return kind end
	end
	return "sedan"
end

-- the Party Shuttles' liveries
local VAN_COLORS = {
	Color3.fromRGB(92, 44, 140),  -- party purple
	Color3.fromRGB(176, 28, 46),  -- casino red
	Color3.fromRGB(20, 108, 118), -- teal
	Color3.fromRGB(188, 152, 96), -- champagne
	Color3.fromRGB(30, 44, 78),   -- midnight blue
}
local AMBIENT_VAN_CHANCE = 0.08 -- of the through traffic

-- the body colour a client paints on (nil = the template's own: taxi yellow,
-- black limo)
local function colorFor(kind: string): Color3?
	if kind == "sedan" or kind == "sport" then
		local list = TC.BodyColors
		return list[rng:NextInteger(1, #list)]
	elseif kind == "van" then
		return VAN_COLORS[rng:NextInteger(1, #VAN_COLORS)]
	elseif kind == "limo" and rng:NextNumber() < (TC.WhiteLimoChance or 0) then
		return Color3.fromRGB(236, 234, 228)
	end
	return nil
end

------------------------------------------------------------------
-- the schedule
------------------------------------------------------------------
local function maxCars(): number
	return DayNight.isNight() and (TC.NightMaxCars or TC.MaxCars) or TC.MaxCars
end

-- forget cars back in their tunnels and bookings nobody can clash with now
local function prune(t: number)
	for id, car in cars do
		if car.tEnd < t then
			cars[id] = nil
			carCount -= 1
		end
	end
	local horizon = t - TC.Headway - 1
	for id, list in booked do
		local keep = {}
		for _, r in list do
			if r >= horizon then table.insert(keep, r) end
		end
		booked[id] = #keep > 0 and keep or nil
	end
	for id, list in zoneCars do
		local keep = {}
		for _, o in list do
			if o.t0 + o.track.tOut + o.dwell >= t then table.insert(keep, o) end
		end
		zoneCars[id] = #keep > 0 and keep or nil
	end
	for id, list in stops do
		local keep = {}
		for _, st in list do
			if st.departAt >= t then table.insert(keep, st) end
		end
		stops[id] = #keep > 0 and keep or nil
	end
end

local CAR_WIDTH = 5.2
local LENGTH = { limo = 17, van = VAN_L } -- (the rest 11)
local function carLength(kind: string): number
	return LENGTH[kind] or 11
end

-- passengers (and leaving riders) a car takes: a party bigger than that comes
-- in several cars. Parties of more than 4 (Party Shuttles) ride a van, VIPs a
-- limo; both have room for MAX_SEATS
local SEATS = { sport = 2, taxi = 4, sedan = 4, limo = 8, van = 8 }
local MAX_SEATS = 8
local function seatsOf(kind: string): number
	return SEATS[kind] or 4
end

------------------------------------------------------------------
-- the valet lanes: a car's stretch in its casino's lane, sampled once per
-- route + car length as boxes in the arm's frame (s along, t across; the
-- half extents of the turned car's footprint), times relative to its start
------------------------------------------------------------------
local TRACK_DT = 0.05 -- sampling of a car's own track
local CHECK_DT = 0.1  -- how finely two cars are compared
local tracks = setmetatable({}, { __mode = "k" }) -- route path -> { [length] = track }

local function zoneTrack(route, len: number)
	local path = route.path
	local byLen = tracks[path]
	if not byLen then
		byLen = {}
		tracks[path] = byLen
	end
	if byLen[len] then return byLen[len] end
	local zone = route.zone
	local a = CityLayout.Arms[zone.arm]
	local spec = table.clone(route.spec)
	spec.dwell = 0
	local free = RoadNet.build(spec) -- the same path without the stop's dwell
	local function sample(list, t: number)
		local p, d, v = free:locate(t)
		local c, s = math.abs(d:Dot(a.out)), math.abs(d:Dot(a.lat))
		table.insert(list.s, p:Dot(a.out))
		table.insert(list.t, p:Dot(a.lat))
		table.insert(list.hl, len / 2 * c + CAR_WIDTH / 2 * s)
		table.insert(list.hw, CAR_WIDTH / 2 * c + len / 2 * s)
		table.insert(list.v, v)
	end
	local tr = { tIn = zone.tIn, stopT = path.stopT, tOut = zone.tOut,
		pre = { s = {}, t = {}, hl = {}, hw = {}, v = {} }, post = { s = {}, t = {}, hl = {}, hw = {}, v = {} },
		stop = { s = {}, t = {}, hl = {}, hw = {}, v = {} } }
	local n = math.max(1, math.ceil((tr.stopT - tr.tIn) / TRACK_DT))
	for i = 0, n do sample(tr.pre, tr.tIn + (tr.stopT - tr.tIn) * i / n) end
	tr.preDt = (tr.stopT - tr.tIn) / n
	sample(tr.stop, tr.stopT)
	local m = math.max(1, math.ceil((tr.tOut - tr.stopT) / TRACK_DT))
	for i = 0, m do sample(tr.post, tr.stopT + (tr.tOut - tr.stopT) * i / m) end
	tr.postDt = (tr.tOut - tr.stopT) / m
	byLen[len] = tr
	return tr
end

-- where a car is in its valet lane at server time T (nil when it isn't in it)
local function stateAt(tr, t0: number, dwell: number, T: number)
	local tau = T - t0
	if tau < tr.tIn or tau > tr.tOut + dwell then return nil end
	local list, i
	if tau <= tr.stopT then
		list, i = tr.pre, math.floor((tau - tr.tIn) / tr.preDt + 0.5) + 1
	elseif tau <= tr.stopT + dwell then
		list, i = tr.stop, 1
	else
		list, i = tr.post, math.floor((tau - tr.stopT - dwell) / tr.postDt + 0.5) + 1
	end
	i = math.clamp(i, 1, #list.s)
	return list.s[i], list.t[i], list.hl[i], list.hw[i], list.v[i]
end

-- does a car on track `tr` (starting t0, waiting `dwell` at its stop) come
-- too close to any of `others` in the valet lane? Says when, as the phase of
-- its own visit: "pre" (pulling in), "stop" (standing) or "post" (pulling out),
-- and for how long the two stay too close from then on. Moving cars keep
-- BayGap (+1 for the 0.1 s comparison steps); creeping into a stop or
-- standing there, cars may come as close as ParkedGap (bumper to bumper)
local GAP_SPEED = 8 -- studs/s: from here on the full gap
local function zoneClash(tr, t0: number, dwell: number, others): (string?, number)
	local moving = (TC.BayGap or 2.5) + 1
	local parked = TC.ParkedGap or 0.8
	local from, to = t0 + tr.tIn, t0 + tr.tOut + dwell
	local function close(o, T: number): boolean
		local s1, t1, l1, w1, v1 = stateAt(tr, t0, dwell, T)
		if s1 == nil then return false end
		local s2, t2, l2, w2, v2 = stateAt(o.track, o.t0, o.dwell, T)
		if s2 == nil then return false end
		local gap = parked + (moving - parked) * math.min(1, math.max(v1, v2) / GAP_SPEED)
		return math.abs(s1 - s2) < l1 + l2 + gap and math.abs(t1 - t2) < w1 + w2 + 0.6
	end
	for _, o in others do
		local T = math.max(from, o.t0 + o.track.tIn)
		local stopAt = math.min(to, o.t0 + o.track.tOut + o.dwell)
		while T <= stopAt do
			if close(o, T) then
				local tau = T - t0
				local phase = (tau <= tr.stopT and "pre") or (tau <= tr.stopT + dwell and "stop") or "post"
				local T2 = T + CHECK_DT
				while T2 <= stopAt and close(o, T2) do T2 += CHECK_DT end
				return phase, T2 - T
			end
			T += CHECK_DT
		end
	end
	return nil, 0
end

-- the earliest start >= `earliest` (and the extra curb wait) at which the
-- route clears every booking and every car in its valet lane; nil if that's
-- later than `latest`. Every step moves the start (or the curb wait) just
-- past one clash, so it only ever goes forward; EPS keeps float rounding from
-- landing a hair short of a gap.
local EPS = 1e-3
local STEP = 0.2 -- (valet-lane clashes: nudge by this much and look again)
local function findStart(route, earliest: number, latest: number?, len: number): (number?, number)
	local H = TC.Headway
	local maxExtra = route.stopTime and (TC.MaxExtraDwell or 0) or 0
	local maxWait = math.max(maxExtra, route.stopTime and (TC.MaxValetWait or 0) or 0)
	local track = route.zone and zoneTrack(route, len)
	local others = route.zone and zoneCars[route.zone.id]
	local t, extra = earliest, 0
	for _ = 1, 1500 do
		if latest and t > latest then return nil, 0 end
		local moved = false
		for _, c in route.conflicts do
			local tc = t + c.t + (c.post and extra or 0)
			for _, r in booked[c.id] or EMPTY do
				if math.abs(tc - r) < H then
					local need = r + H - tc + EPS
					-- (a car already waiting for the queue ahead may wait on for the gap)
					if c.post and extra + need <= (extra > maxExtra and maxWait or maxExtra) then
						extra += need        -- wait at the curb for the gap
					else
						t += need + (c.post and extra or 0)
						extra = 0
					end
					moved = true
					break
				end
			end
			if moved then break end
		end
		if not moved and others then
			local phase, long = zoneClash(track, t, route.dwell + extra, others)
			if phase then
				moved = true
				-- move on by part of the time the two would stay too close (all
				-- of it would overshoot behind a car that's itself moving on)
				local step = math.max(STEP, long * 0.3)
				if phase == "post" and extra + step <= maxWait then
					extra += step -- stay at the curb until the cars ahead have pulled away
				else
					t += step
					extra = 0
				end
			end
		end
		if not moved then return t, extra end
	end
	return nil, 0
end

local function payloadOf(car)
	return { id = car.id, spec = car.spec, t0 = car.t0, kind = car.kind, color = car.color }
end

-- book a car found by findStart: its merge points and its stretch in a valet
-- lane. Nobody hears of it until announce(); unbook() takes it back till then.
local function book(spec, route, t0: number, extra: number, kind: string, color: Color3?)
	if extra > 0 then
		spec.dwell = (spec.dwell or 0) + extra
		route = RoadNet.build(spec)
	end
	local held = {}
	for _, c in route.conflicts do
		local list = booked[c.id]
		if not list then
			list = {}
			booked[c.id] = list
		end
		table.insert(list, t0 + c.t)
		table.insert(held, { list = list, t = t0 + c.t })
	end
	local lane, inLane
	if route.zone then
		lane = zoneCars[route.zone.id]
		if not lane then
			lane = {}
			zoneCars[route.zone.id] = lane
		end
		inLane = { t0 = t0, dwell = route.dwell, track = zoneTrack(route, carLength(kind)) }
		table.insert(lane, inLane)
	end
	nextId += 1
	local car = { id = nextId, spec = spec, t0 = t0, kind = kind, color = color, route = route,
		tEnd = t0 + route.duration, held = held, lane = lane, inLane = inLane }
	cars[car.id] = car
	carCount += 1
	return car
end

local function unbook(car)
	for _, h in car.held do
		local i = table.find(h.list, h.t)
		if i then table.remove(h.list, i) end
	end
	local i = car.lane and table.find(car.lane, car.inLane)
	if i then table.remove(car.lane, i) end
	cars[car.id] = nil
	carCount -= 1
end

-- put a booked car on the road: tell every client
local function announce(car)
	car.held, car.lane, car.inLane = nil, nil, nil
	Remotes.TrafficCar():FireAllClients(payloadOf(car))
end

local function commit(spec, route, t0: number, extra: number, kind: string, color: Color3?)
	local car = book(spec, route, t0, extra, kind, color)
	announce(car)
	return car
end

local function launch(spec, kind: string, earliest: number, latest: number?)
	local route = RoadNet.build(spec)
	if not route then return nil end
	local t0, extra = findStart(route, earliest, latest, carLength(kind))
	if not t0 then return nil end
	return commit(spec, route, t0, extra, kind, colorFor(kind))
end

------------------------------------------------------------------
-- curb stops
------------------------------------------------------------------
-- a route to (and away from) a bay. Inbound (side -1) stops come straight in
-- from the arm's own tunnel and leave round the ring by any other arm;
-- outbound (side +1) stops come round the ring from another tunnel, mostly
-- the nearest one (`nearest`: always it) so patrons aren't long on the way
local function bayRoute(bay, nearest: boolean)
	local via
	local i = table.find(ARMS, bay.arm)
	if bay.side > 0 then
		local back = 1
		if not nearest then
			local r = rng:NextNumber() * 6
			back = r < 4 and 1 or (r < 5 and 2 or 3)
		end
		via = ARMS[(i - 1 - back) % #ARMS + 1]
	else
		via = ARMS[(i - 1 + rng:NextInteger(1, #ARMS - 1)) % #ARMS + 1]
	end
	return { route = "bay", arm = bay.arm, k = bay.k, side = bay.side, via = via }
end

-- where people get out (and in): on the road beside the car's kerb-side
-- doors, facing the sidewalk (or the car); a van or a limo has room for 8
local DOOR_ALONG = {
	default = { 1.6, -1.6, 4.0, -4.0 },
	van = { 1.0, -1.0, 3.0, -3.0, 5.0, -5.0, 6.6, -6.6 },
	limo = { 1.2, -1.2, 3.6, -3.6, 6.0, -6.0, 7.8, -7.8 },
}
local function doorSpots(bay, kind: string, count: number, facingCar: boolean)
	local along = DOOR_ALONG[kind] or DOOR_ALONG.default
	local out = {}
	for i = 1, math.max(1, count) do
		local p = bay.stop + bay.heading * along[(i - 1) % #along + 1] + bay.curbDir * 3.4
			+ Vector3.new(0, CityLayout.Y.Road, 0)
		out[i] = CFrame.lookAt(p, p + (facingCar and -bay.curbDir or bay.curbDir))
	end
	return out
end

-- a customer car's stop: its passengers' callback and the leaving patrons
-- riding it, each called when it halts, with the spots by its doors.
-- `seated` = which of the party's passengers ride in it (their indices in the
-- party): onArrive's spots are keyed by those indices
local function newStop(car, bay, onArrive, seated: { number })
	local st = {
		car = car, bay = bay, riders = {}, arrived = false,
		arriveAt = car.t0 + car.route.stopTime, departAt = car.t0 + car.route.stopEnd,
	}
	local list = stops[bay.id]
	if not list then
		list = {}
		stops[bay.id] = list
	end
	table.insert(list, st)
	task.delay(math.max(0, st.arriveAt - now()), function()
		st.arrived = true
		if onArrive and #seated > 0 then
			local doors, spots = doorSpots(bay, car.kind, #seated, false), {}
			for j, i in seated do spots[i] = doors[j] end
			task.spawn(onArrive, spots,
				{ arriveAt = st.arriveAt, departAt = st.departAt, kind = car.kind, passengers = seated })
		end
		local spots = doorSpots(bay, car.kind, #st.riders, true)
		for seat, fn in st.riders do
			task.spawn(fn, spots, { arriveAt = st.arriveAt, departAt = st.departAt, kind = car.kind, seat = seat })
		end
	end)
	return st
end

-- where a rider waits for a car due at one of the extra stops: on the walk
-- beside it, a few steps on toward the entrance (clear of the casino's pylon
-- behind the last stop; a van's or a limo's 5th to 8th riders one row further
-- in). Riders of the base stop keep the spot they found by the door (nil).
local function curbFor(stop, seat: number): CFrame?
	if stop.base then return nil end
	local row = (seat - 1) // 4
	local p = stop.stop + stop.heading * (4 + ((seat - 1) % 4) * 1.6) + stop.curbDir * (7 + 1.8 * row)
		+ Vector3.new(0, CityLayout.Y.Walk, 0)
	return CFrame.lookAt(p, p - stop.curbDir)
end

local function handleOf(st, seat: number?)
	return { id = st.car.id, arriveAt = st.arriveAt, departAt = st.departAt, kind = st.car.kind, seat = seat,
		stop = st.bay, curb = seat and curbFor(st.bay, seat) or nil }
end

-- a leaving patron takes the next free seat
local function board(st, onArrive)
	table.insert(st.riders, onArrive)
	return handleOf(st, #st.riders)
end

------------------------------------------------------------------
-- the owner's upgrades: Parking (effect "parkingBays": extra curb stops) and
-- Party Shuttles ("partyBonus": bigger groups); 0 while a track isn't there
------------------------------------------------------------------
local function ownerEffect(ownerId: number?, key: string): number
	if not (ownerId and Upgrades and Upgrades.effectForUser) then return 0 end
	local ok, v = pcall(Upgrades.effectForUser, ownerId, key)
	return (ok and type(v) == "number") and v or 0
end

-- how many curb stops a casino has: 1 + its Parking upgrade, fewer where the
-- lane begins too close behind it (RoadNet.baysFor)
local function baysFor(arm: string, k: number, side: number, ownerId: number?): number
	local extra = math.clamp(math.floor(ownerEffect(ownerId, "parkingBays") + 0.5), 0, TC.MaxExtraBays or 2)
	return RoadNet.baysFor(arm, k, side, 1 + extra)
end

-- the car for `n` passengers: the one asked for (a VIP party's limo), a Party
-- Shuttle van for groups of more than 4, otherwise the usual mix of the cars
-- that seat them all (no two-seat sports car for three)
local function kindFor(n: number, forced: string?): string
	if forced then return forced end
	if n > 4 then return "van" end
	local fit = {}
	for kind, w in TC.CustomerKinds do
		if seatsOf(kind) >= n then fit[kind] = w end
	end
	return next(fit) ~= nil and pickWeighted(fit) or "taxi"
end

-- a party in as few cars (of `seats` each) as seat it, as evenly as possible
local function splitLoads(n: number, seats: number): { number }
	local count = math.ceil(n / seats)
	local each, rest = n // count, n % count
	local loads = {}
	for c = 1, count do loads[c] = each + (c <= rest and 1 or 0) end
	return loads
end

local BIG_PARTY_DWELL = 0.15 -- + seconds at the curb for each passenger over 4 (they step out one by one)
local BIG_PICKUP_DWELL = 0.6 -- + seconds for an 8-seater picking up

-- spreading drop-offs: while the curb has room (the car can come as soon as
-- it could anywhere and leave without waiting), they take turns over the
-- stops that are as free, front and rearmost first (one standing at the
-- rearmost stop doesn't hold up a car swinging in to the front). Once it's
-- busy the queue fills from the front again, which moves the most cars.
local SPREAD = { { 1 }, { 2, 1 }, { 3, 1, 2 } }
local spreadTurn = {} -- casino zone id -> whose turn it is
local FREE = 0.05 -- s: "as soon as" / "without waiting"

-- which stop a car prefers, front first. A long car (one that can't stand at
-- a stop next to a limo, ValetSpacing apart: the van, the limo) takes the
-- rearmost of 3 before the middle one, so two of them fit, at either end.
local FRONT_FIRST = { { 1 }, { 2, 1 }, { 3, 2, 1 } }
local function preference(kind: string, n: number): { number }
	local long = (carLength(kind) + LENGTH.limo) / 2 + (TC.ParkedGap or 0.8) > RoadNet.valetSpacing(n)
	return (long and SPREAD or FRONT_FIRST)[n] or FRONT_FIRST[1]
end

-- the stop a car takes, of the casino's stops: one that lets it leave its
-- tunnel within FrontTolerance of the soonest any of them would; the
-- frontmost of those (the base one, at the entrance, then the ones queued
-- behind it: `preference`), or in turns with `spread` when that one's free.
-- A car can't drive past one standing at a stop, so the queue fills from
-- the front: a car squeezed in at the back would hold up everyone headed
-- further up. With its spec, route, start, extra curb wait and arrival (nil
-- if none clears by `latest`).
local function bestStop(bay, base, kind: string, earliest: number, latest: number?, spread: boolean?)
	local tol = TC.FrontTolerance or 3
	local options, soonest = {}, math.huge
	for j = bay.bays, 1, -1 do
		local spec = table.clone(base)
		spec.bays, spec.slot = bay.bays, j
		local route = RoadNet.build(spec)
		if route then
			-- (the same leeway past `latest`, or near it the rearmost stop would
			-- always be the only one left)
			local t0, extra = findStart(route, earliest, latest and latest + tol, carLength(kind))
			if t0 then
				options[j] = { spec = spec, route = route, t0 = t0, extra = extra, arrive = t0 + route.stopTime }
				soonest = math.min(soonest, t0)
			end
		end
	end
	if latest and soonest > latest then return nil end
	local pick
	for _, j in preference(kind, bay.bays) do
		local o = options[j]
		if o and o.t0 <= soonest + tol then
			pick = o
			break
		end
	end
	local function free(o): boolean
		return o ~= nil and o.t0 <= soonest + FREE and o.extra <= FREE
	end
	local order = spread and SPREAD[bay.bays] or nil
	if order and free(pick) then
		local turn = spreadTurn[bay.id] or 0
		for q = 0, #order - 1 do
			local o = options[order[(turn + q) % #order + 1]]
			if free(o) then
				spreadTurn[bay.id] = (turn + q + 1) % #order
				return o
			end
		end
	end
	return pick
end

------------------------------------------------------------------
-- API (NPCs)
------------------------------------------------------------------
-- the base curb stop serving a plot record (RoadNet.bayInfo: id, stop,
-- heading, curbDir, bays ...: level with the entrance), nil when there's
-- none (a plot without Arm / Slot / Side) or traffic is off
function Traffic.bayFor(rec)
	if not (running and rec and rec.model) then return nil end
	local b = CityLayout.bayForPlot(rec.model)
	if not b then return nil end
	return RoadNet.bayInfo(b.arm, b.k, b.side, baysFor(b.arm, b.k, b.side, rec.ownerId))
end

-- send a party of `passengers` visible guests to the plot's curb: one car
-- (a van for more than 4, the limo when opts.kind = "limo"), or several when
-- they don't fit one (more than Traffic.maxPartySize() = 8, or than the seats
-- of the opts.kind asked for), spread over the casino's stops. Whatever guest
-- weight they stand for, they're one car's worth of visible people.
-- When a car halts (server time), onArrive(spots, info) gets
-- a CFrame per passenger in it, beside its doors facing the sidewalk, keyed
-- by the passenger's index in the party (1..passengers when one car takes
-- them all), and { arriveAt, departAt, kind, passengers = those indices }:
-- several cars call it once each. All-or-nothing: returns a handle { id,
-- arriveAt, departAt, kind, stop, cars = one per car } or nil, reason
-- ("nobay" / "busy").
function Traffic.requestDropoff(rec, passengers: number, onArrive, opts)
	opts = opts or {}
	local bay = Traffic.bayFor(rec)
	if not bay then return nil, "nobay" end
	local t = now()
	prune(t)
	local loads = splitLoads(math.max(1, math.floor(tonumber(passengers) or 1)),
		opts.kind and seatsOf(opts.kind) or MAX_SEATS)
	if carCount + #loads > maxCars() + (TC.CustomerExtra or 0) then return nil, "busy" end
	local earliest = t + TC.LeadTime
	local latest = earliest + (opts.maxDelay or TC.MaxDropoffDelay)
	local party, first = {}, 1
	for _, load in loads do
		local kind = kindFor(load, opts.kind)
		local base = bayRoute(bay, false)
		base.dwell = TC.DropoffDwell + BIG_PARTY_DWELL * math.max(0, load - 4)
		local pick = bestStop(bay, base, kind, earliest, latest, true)
		if not pick then
			for _, p in party do unbook(p.car) end
			return nil, "busy"
		end
		local seated = {}
		for i = first, first + load - 1 do table.insert(seated, i) end
		first += load
		table.insert(party, { car = book(pick.spec, pick.route, pick.t0, pick.extra, kind, colorFor(kind)), seated = seated })
	end
	local handles = {}
	for _, p in party do
		announce(p.car)
		table.insert(handles, handleOf(newStop(p.car, p.car.route.bay, onArrive, p.seated), nil))
	end
	handles[1].cars = handles
	return handles[1]
end

-- a ride from the plot's curb for one leaving patron: a seat in a car that's
-- already coming to one of its stops (if the patron can get there in time),
-- unless a fresh car would come clearly sooner. onArrive(spots, info) fires
-- when it halts: spots = CFrames beside its doors, info.seat = which one is
-- yours, info.departAt = when it pulls away. Returns a handle { arriveAt,
-- departAt, seat, stop, curb } (curb: where to wait when the car is due at
-- one of the extra stops, nil at the base stop) or nil, reason.
function Traffic.requestPickup(rec, onArrive)
	local bay = Traffic.bayFor(rec)
	if not bay then return nil, "nobay" end
	local t = now()
	prune(t)
	local shared
	for _, st in stops[bay.id] or EMPTY do
		-- the walk from the door to an extra stop (~10 studs a second, + slack)
		local walk = st.bay.base and 0 or math.abs(st.bay.s - bay.s) / 10 + 1
		if not st.arrived and st.arriveAt > t + 0.75 + walk and #st.riders < seatsOf(st.car.kind)
			and (not shared or st.arriveAt < shared.arriveAt) then
			shared = st
		end
	end
	-- a fresh car: now and then a Party Shuttle van, for casinos with that upgrade
	local kind = rng:NextNumber() < math.min(0.6, 0.2 * ownerEffect(rec.ownerId, "partyBonus")) and "van"
		or pickWeighted(TC.CustomerKinds)
	local pick
	if carCount < maxCars() + (TC.CustomerExtra or 0) then
		local base = bayRoute(bay, true)
		base.dwell = TC.PickupDwell + (seatsOf(kind) >= MAX_SEATS and BIG_PICKUP_DWELL or 0)
		local earliest = t + TC.LeadTime
		pick = bestStop(bay, base, kind, earliest, earliest + (TC.MaxPickupDelay or 60), false)
	end
	if shared and (not pick or shared.arriveAt <= pick.arrive + 4) then
		return board(shared, onArrive)
	end
	if not pick then return nil, "busy" end
	local car = commit(pick.spec, pick.route, pick.t0, pick.extra, kind, colorFor(kind))
	return board(newStop(car, car.route.bay, nil, {}), onArrive)
end

-- cars on the road or waiting in a tunnel
function Traffic.carCount(): number
	prune(now())
	return carCount
end

------------------------------------------------------------------
-- curb capacity, for the NPC flow (functions: they follow each plot's
-- layout and upgrades). The curb only throttles VISIBLE guests: a car brings
-- a party of visible guests, whatever guest weight each of them stands for.
------------------------------------------------------------------
-- cars a minute a curb takes with every stop busy (1 / 2 / 3 stops), as
-- measured in the headless traffic sim (a little under): cars for parties of
-- up to 4 (taxis, sedans, sports cars, a VIP's limo) and the long ones for
-- bigger parties (Party Shuttle vans, VIP limos), which need more curb. The
-- four outbound casinos by the plaza have a short run-in at the back.
local CURB_CARS = { short = { 11, 15, 15.5 }, long = { 10, 12.5, 13.5 } }
local CURB_BY_THE_RING = 0.95

-- guests in each car when a party of n comes (several cars past 8)
local function perCar(n: number): number
	return n / math.ceil(n / MAX_SEATS)
end

-- the biggest party the plot's guests come in: Config.NPC.PartyMax + the
-- owner's Party Shuttles seats
local function biggestParty(rec): number
	local most = (Config.NPC and Config.NPC.PartyMax) or 4
	return math.max(1, math.floor(most + ownerEffect(rec and rec.ownerId, "partyBonus") + 0.5))
end

-- the most passengers one car brings (bigger parties come in several cars)
function Traffic.maxPartySize(): number
	return MAX_SEATS
end

-- passengers (or leaving riders) one car of a kind takes
function Traffic.seatsFor(kind: string): number
	return seatsOf(kind)
end

-- how many curb stops the plot has (0: none, its guests walk in at the door)
function Traffic.curbStops(rec): number
	local bay = Traffic.bayFor(rec)
	return bay and bay.bays or 0
end

-- cars a minute the plot's curb can take when each party has `party` guests
-- (default: its biggest party); 0 without a curb stop
function Traffic.curbCarsPerMinute(rec, party: number?): number
	local bay = Traffic.bayFor(rec)
	if not bay then return 0 end
	local list = perCar(math.max(1, party or biggestParty(rec))) > 4 and CURB_CARS.long or CURB_CARS.short
	local cars = list[bay.bays] or list[1]
	return (bay.side > 0 and bay.k == 0) and cars * CURB_BY_THE_RING or cars
end

-- visible guests a minute the plot's curb lets in when parties of `party`
-- (default: its biggest party) come one after another: ~44 / 60 / 62 for
-- parties of 4 at 1 / 2 / 3 stops, ~80 / 100 / 108 for parties of 8
function Traffic.curbCapacityPerMinute(rec, party: number?): number
	local n = math.max(1, party or biggestParty(rec))
	return Traffic.curbCarsPerMinute(rec, n) * perCar(n)
end

-- seconds until the last customer car due at the plot's curb pulls away
-- again (0: none booked, the curb is free)
function Traffic.curbBacklog(rec): number
	local bay = Traffic.bayFor(rec)
	if not bay then return 0 end
	local t, last = now(), 0
	for _, st in stops[bay.id] or EMPTY do
		last = math.max(last, st.departAt - t)
	end
	return last
end

------------------------------------------------------------------
-- through traffic: tunnel to tunnel round the ring, fewer when it's busy
------------------------------------------------------------------
local function ambientTick()
	local t = now()
	prune(t)
	if carCount >= math.floor(maxCars() * (TC.AmbientShare or 0.6)) then return end
	local i = rng:NextInteger(1, #ARMS)
	local from = ARMS[i]
	local to = ARMS[(i - 1 + rng:NextInteger(1, #ARMS - 1)) % #ARMS + 1]
	local earliest = t + TC.LeadTime
	local kind = rng:NextNumber() < AMBIENT_VAN_CHANCE and "van" or pickWeighted(TC.AmbientKinds)
	launch({ route = "through", from = from, to = to }, kind, earliest, earliest + (TC.AmbientMaxDelay or 6))
end
Traffic._ambientTick = ambientTick -- (the headless traffic simulation drives this)

------------------------------------------------------------------
-- the extra stops' road markings: a yellow box with VALET in it behind the
-- map's TAXI box (s +-9 round the entrance), one per extra stop, painted
-- 0.05 above the map's own lines. Workspace.TrafficBays.<plot name>
------------------------------------------------------------------
local markFolder
local marked = {} -- plot model -> stops marked

local function paintBar(parent, a: Vector3, b: Vector3, width: number)
	local flat = Vector3.new(b.X - a.X, 0, b.Z - a.Z)
	local mid = Vector3.new((a.X + b.X) / 2, CityLayout.Y.Road + 0.075, (a.Z + b.Z) / 2)
	local p = Instance.new("Part")
	p.Name = "ValetLine"
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Color = WP.LaneYellow
	p.Size = Vector3.new(width, 0.05, flat.Magnitude)
	p.CFrame = CFrame.lookAt(mid, mid + flat)
	p.Parent = parent
	return p
end

local function paintWord(parent, at: Vector3, drive: Vector3, word: string)
	local p = Instance.new("Part")
	p.Name = "ValetText"
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Transparency = 1
	p.Size = Vector3.new(8, 0.02, 6.2)
	-- a Top SurfaceGui reads "up" toward the part's -X: along the drive
	p.CFrame = CFrame.fromMatrix(at, -drive, Vector3.yAxis)
	p.Parent = parent
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Top
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 20
	gui.LightInfluence = 0.4
	gui.ClipsDescendants = true
	gui.Parent = p
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 0.5)
	label.Position = UDim2.fromScale(0, 0.25)
	label.Font = Enum.Font.GothamBlack
	label.TextScaled = true
	label.TextColor3 = WP.LaneYellow
	label.Text = word
	label.Parent = gui
end

-- (re)draw one plot's extra stops when its owner or Parking level changed
local function markStops(model: Instance)
	local arm, k, side = model:GetAttribute("Arm"), model:GetAttribute("Slot"), model:GetAttribute("Side")
	if not (arm and CityLayout.Arms[arm] and k and side) then return end
	local n = baysFor(arm, k, side, model:GetAttribute("OwnerId"))
	if marked[model] == n then return end
	marked[model] = n
	local old = markFolder:FindFirstChild(model.Name)
	if old then old:Destroy() end
	if n <= 1 then return end
	local f = Instance.new("Folder")
	f.Name = model.Name
	local a = CityLayout.Arms[arm]
	local drive = a.out * side -- side +1 stops serve outbound cars, side -1 inbound
	local lane = (CityLayout.Arm.TravelLane + CityLayout.Arm.StopLane) / 2 -- 14: the lane line
	local curb = CityLayout.Arm.RoadHalf - 1.1
	-- the first box starts where the TAXI box (s +-9) ends; with 3 stops the
	-- boxes are 3 studs apart, with 2 the one VALET box is as long as TAXI's
	local half = RoadNet.valetSpacing(n) - 9
	local function at(s: number, t: number): Vector3
		return CityLayout.toWorld(arm, s, t, CityLayout.Y.Road)
	end
	for j = 1, n - 1 do
		local st = RoadNet.bayInfo(arm, k, side, n, j)
		paintBar(f, at(st.s - half, side * lane), at(st.s + half, side * lane), 0.3)
		for _, e in { -half, half } do
			paintBar(f, at(st.s + e, side * (lane + 0.15)), at(st.s + e, side * curb), 0.3)
		end
		paintWord(f, at(st.s, side * CityLayout.Arm.StopLane) + Vector3.new(0, 0.1, 0), drive, "VALET")
	end
	f.Parent = markFolder
end

local function refreshMarkings()
	if not markFolder then return end
	for model in marked do
		if not model.Parent then
			marked[model] = nil
			local old = markFolder:FindFirstChild(model.Name)
			if old then old:Destroy() end
		end
	end
	local plots = Workspace:FindFirstChild("Plots")
	if not plots then return end
	for _, model in plots:GetChildren() do
		local ok, err = pcall(markStops, model)
		if not ok then warn("[Traffic] markings: " .. tostring(err)) end
	end
end
Traffic._refreshMarkings = refreshMarkings -- (the headless simulation calls this)

-- deps.Upgrades: the owners' Parking upgrade (Upgrades.effectForUser)
function Traffic.start(deps)
	if TC.Enabled == false then return end
	Upgrades = deps and deps.Upgrades
	running = true
	local ok, res = pcall(buildTemplates)
	if not ok then warn("[Traffic] car templates: " .. tostring(res)) end

	markFolder = Workspace:FindFirstChild("TrafficBays") or Instance.new("Folder")
	markFolder.Name = "TrafficBays"
	markFolder.Parent = Workspace
	task.spawn(function()
		while true do
			refreshMarkings()
			task.wait(2)
		end
	end)

	Remotes.GetTrafficCars().OnServerInvoke = function()
		prune(now())
		local out = {}
		for _, car in cars do table.insert(out, payloadOf(car)) end
		return out
	end

	task.spawn(function()
		while true do
			local every = DayNight.isNight() and (TC.NightAmbientInterval or TC.AmbientInterval) or TC.AmbientInterval
			task.wait(every * rng:NextNumber(0.6, 1.4))
			local fine, err = pcall(ambientTick)
			if not fine then warn("[Traffic] " .. tostring(err)) end
		end
	end)
	print(("[CasinoTycoon] Traffic: cars out of the tunnels (%s car models), up to %d by day / %d at night.")
		:format(ok and res and "MapProps" or "stand-in", TC.MaxCars, TC.NightMaxCars or TC.MaxCars))
end

return Traffic
