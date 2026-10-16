--!nonstrict
-- RoadNet.luau — the city's lanes as drivable TRACKS, and car ROUTES over
-- them. Shared by the server (Traffic.luau schedules every car) and every
-- client (TrafficClient.luau drives them), so both compute the same motion
-- from the same small route spec.
--
-- Tracks (CityLayout's geometry, y = 0):
--   in:A / out:A      an arm's travel lanes: inbound t = -9.5 from the tunnel
--                     (s 470) to the ring (s 116), outbound t = +9.5 back out
--   entry:A / exit:A  the right turns onto / off the ring (turnPoints)
--   ring              the ring's outer lane (a closed loop, kept as two laps
--                     so every trip round it is one slice)
--   app / dep         per curb stop ("bay"): the S-curve from the travel lane
--                     into the stop lane, braking to a halt (level with the
--                     casino's entrance, or at one of the extra stops queued
--                     behind it: the casino's valet lane), and back out
-- Every track has a fixed POSITION-BASED speed profile: a speed per vertex
-- and constant acceleration in between (v² runs linearly with distance):
-- cruise on the arms, JunctionSpeed through the turns and past every ring
-- mouth, CornerSpeed round the ring's corners, Accel / Decel in between. A
-- car's speed only depends on where it is, so two cars on the same stretch
-- keep their time gap: the scheduler only has to space cars where streams
-- MERGE (a tunnel mouth, a ring entry, a curb stop's re-entry) and keep each
-- bay to one car at a time. A stop lane is entered braking and left
-- accelerating, within BayRun studs either side of the stop, so no car ever
-- slows down in a travel lane.
--
-- Route specs (all the server replicates besides a start time):
--   { route = "through", from = "E", to = "N" }
--   { route = "bay", arm = "E", k = 1, side = -1, via = "N", dwell = 3.4,
--     bays = 3, slot = 2 }
--     side -1: in through the arm's own tunnel, stop, on round the ring and
--              out by `via`
--     side +1: in through `via`'s tunnel, round the ring, out along the arm,
--              stop, then on out through the arm's tunnel
--     bays = the casino's stops (1-3, default 1), slot = which one (1 = the
--     rearmost .. bays = the base stop at the entrance, the default)
-- RoadNet.build(spec) -> route (nil for a bad spec):
--   route:sample(t)   CFrame of the car's ground origin on the road top, t
--                     seconds after its start, nose (-Z) along its way
--   route:locate(t)   position (y = 0), unit heading, speed
--   route.duration    seconds from the tunnel (s 470) back into a tunnel
--   route.stopTime / route.stopEnd   when it halts at the bay / pulls away
--   route.conflicts   { { id, t, post } }: every merge point it passes and
--                     when (post = after its stop, so it moves with the dwell)
--   route.bay         the stop it halts at (RoadNet.bayInfo)
--   route.zone        { id, arm, tIn, tOut }: when it enters / leaves its
--                     casino's valet lane (tOut without the dwell)

local CityLayout = require(script.Parent:WaitForChild("CityLayout"))
local Config = require(script.Parent:WaitForChild("Config"))

local RoadNet = {}

local ARM, RING, Y = CityLayout.Arm, CityLayout.Ring, CityLayout.Y
local TC = Config.Traffic or {}

local CRUISE = TC.CruiseSpeed or 28
local RING_V = TC.RingSpeed or 22
local CORNER_V = TC.CornerSpeed or 19
local JUNCTION_V = TC.JunctionSpeed or 14
local ACCEL = TC.Accel or 12
local DECEL = TC.Decel or 12

local SPAWN_S = ARM.SpawnS   -- 470: cars appear / vanish here, deep in the dark tunnel
local MOUTH_S = RING.MouthS  -- 116: the lanes turn onto / off the ring here
local LANE_T = ARM.TravelLane
local STOP_T = ARM.StopLane
local ROAD_UP = Vector3.new(0, Y.Road, 0)

-- a stop's run-in (and run-out): long enough to brake from cruise (and to
-- reach it again), short enough that neighbouring stops never overlap
local BAY_RUN = math.clamp(math.max(TC.BayRun or 34, CRUISE * CRUISE / (2 * math.min(ACCEL, DECEL)) + 1),
	16, ARM.SlotPitch / 2 - 2)
RoadNet.BayRun = BAY_RUN
RoadNet.SpawnS = SPAWN_S

local ARM_OK = { E = true, N = true, W = true, S = true }

------------------------------------------------------------------
-- tracks
------------------------------------------------------------------
local function newTrack(name: string, pts: { Vector3 }, vlim: { number })
	local n = #pts
	local x = { 0 }
	for i = 2, n do
		x[i] = x[i - 1] + (pts[i] - pts[i - 1]).Magnitude
	end
	return { name = name, pts = pts, x = x, vlim = vlim, n = n, length = x[n], merges = {} }
end

-- the speed at every vertex: never above its limit, reachable from the
-- vertex before (Accel), able to slow down for the one after (Decel). vStart
-- / vEnd pin the ends to the speed of the track they join.
local function setProfile(tr, vStart: number?, vEnd: number?)
	local n, x = tr.n, tr.x
	local v = table.clone(tr.vlim)
	if vStart then v[1] = math.min(v[1], vStart) end
	if vEnd then v[n] = math.min(v[n], vEnd) end
	for i = 2, n do
		v[i] = math.min(v[i], math.sqrt(v[i - 1] * v[i - 1] + 2 * ACCEL * (x[i] - x[i - 1])))
	end
	for i = n - 1, 1, -1 do
		v[i] = math.min(v[i], math.sqrt(v[i + 1] * v[i + 1] + 2 * DECEL * (x[i + 1] - x[i])))
	end
	tr.v = v
end

-- the segment [i, i + 1] of a sorted list that holds value x (clamped)
local function segAt(xs: { number }, n: number, x: number): number
	local lo, hi = 1, n - 1
	while lo < hi do
		local mid = (lo + hi + 1) // 2
		if xs[mid] <= x then lo = mid else hi = mid - 1 end
	end
	return lo
end

-- position and speed at arc length x along a track
local function trackAt(tr, x: number): (Vector3, number)
	local i = segAt(tr.x, tr.n, x)
	local x0, x1 = tr.x[i], tr.x[i + 1]
	local f = x1 > x0 and math.clamp((x - x0) / (x1 - x0), 0, 1) or 0
	local v0, v1 = tr.v[i], tr.v[i + 1]
	return tr.pts[i]:Lerp(tr.pts[i + 1], f), math.sqrt(math.max(0, v0 * v0 + (v1 * v1 - v0 * v0) * f))
end

------------------------------------------------------------------
-- the arms: travel lanes + the turns on and off the ring
------------------------------------------------------------------
local lanes = {} -- [arm] = { ["in"] = track, out = track }
local turns = {} -- [arm] = { entry = track, exit = track }

-- distance along a lane track of the point level with s
local function laneX(tr, s: number): number
	return tr.inbound and SPAWN_S - s or s - MOUTH_S
end

local function buildLane(arm: string, inbound: boolean)
	local pts, vlim = {}, {}
	local len = SPAWN_S - MOUTH_S
	local n = math.ceil(len / 2)
	local t = inbound and -LANE_T or LANE_T
	for i = 0, n do
		local s = inbound and SPAWN_S - len * i / n or MOUTH_S + len * i / n
		pts[i + 1] = CityLayout.toWorld(arm, s, t, 0)
		vlim[i + 1] = CRUISE
	end
	local tr = newTrack((inbound and "in:" or "out:") .. arm, pts, vlim)
	tr.arm, tr.inbound = arm, inbound
	-- out of the tunnel at cruise, slowing for the turn onto the ring; off
	-- the ring at junction speed, speeding up to cruise
	if inbound then setProfile(tr, CRUISE, JUNCTION_V) else setProfile(tr, JUNCTION_V, nil) end
	return tr
end

local function buildTurn(arm: string, kind: string)
	local pts, vlim = {}, {}
	for i, p in CityLayout.turnPoints(arm, kind, 1) do
		pts[i] = p.pos
		vlim[i] = JUNCTION_V
	end
	local tr = newTrack(kind .. ":" .. arm, pts, vlim)
	setProfile(tr, JUNCTION_V, JUNCTION_V)
	return tr
end

------------------------------------------------------------------
-- the ring's outer lane: straights at RingSpeed, corners at CornerSpeed,
-- JunctionSpeed past every mouth (from an arm's exit to its entry), so the
-- cars that turn off and on drive exactly as the ones going round
------------------------------------------------------------------
local ring        -- two laps, so any trip round is one slice
local ringLapX    -- one lap's length along the track
local ringEntryX = {} -- [arm] = x of the arm's entry (a merge) on the first lap
local ringExitX = {}  -- [arm] = x of the arm's exit (a diverge) on the first lap

local function buildRing()
	local L = CityLayout.ringLength(RING.Lane)
	local seg = L / 4
	local straight = 2 * RING.CornerC
	local us, lim, pins = {}, {}, {}
	local count = 0
	local function add(u: number, v: number, pin: string?)
		count += 1
		us[count], lim[count] = u, v
		if pin then pins[pin] = count end
	end
	for i, arm in CityLayout.RingOrder do
		local u0 = (i - 1) * seg
		local exitU, entryU = CityLayout.mouthU(arm)
		-- the straight from the last corner's end, past the exit and the entry
		-- (a steady junction zone between the two), into the next corner
		-- (vertices ~2 studs apart, ~1 on the corner)
		local marks = {
			{ u = u0, first = CORNER_V, lim = RING_V, step = 2 },
			{ u = exitU, first = JUNCTION_V, lim = JUNCTION_V, step = 2, pin = "x" .. arm },
			{ u = entryU, first = JUNCTION_V, lim = RING_V, step = 2, pin = "e" .. arm },
			{ u = u0 + straight, first = CORNER_V, lim = CORNER_V, step = 1 },
			{ u = u0 + seg },
		}
		for m = 1, 4 do
			local a, b = marks[m], marks[m + 1]
			local n = math.max(1, math.ceil((b.u - a.u) / a.step))
			add(a.u, a.first, a.pin)
			for j = 1, n - 1 do
				add(a.u + (b.u - a.u) * j / n, a.lim)
			end
		end
	end
	local pts = {}
	for k = 1, count do
		pts[k] = (CityLayout.ringPoint(us[k], RING.Lane))
	end

	-- periodic profile: start both passes at a mouth, whose speed is known
	local seglen = {} -- k -> k + 1, wrapping
	for k = 1, count do
		seglen[k] = (pts[k % count + 1] - pts[k]).Magnitude
	end
	local v = table.clone(lim)
	local p0 = pins["e" .. CityLayout.RingOrder[1]]
	for step = 1, count do
		local k = (p0 - 1 + step) % count + 1
		local h = (k - 2) % count + 1
		v[k] = math.min(v[k], math.sqrt(v[h] * v[h] + 2 * ACCEL * seglen[h]))
	end
	for step = 1, count do
		local k = (p0 - 1 - step) % count + 1
		local j = k % count + 1
		v[k] = math.min(v[k], math.sqrt(v[j] * v[j] + 2 * DECEL * seglen[k]))
	end

	local pts2, lim2, v2 = {}, {}, {}
	for lap = 0, 1 do
		for k = 1, count do
			pts2[lap * count + k] = pts[k]
			lim2[lap * count + k] = lim[k]
			v2[lap * count + k] = v[k]
		end
	end
	pts2[2 * count + 1], lim2[2 * count + 1], v2[2 * count + 1] = pts[1], lim[1], v[1]
	ring = newTrack("ring", pts2, lim2)
	ring.v = v2
	ringLapX = ring.x[count + 1]
	for _, arm in CityLayout.RingOrder do
		ringEntryX[arm] = ring.x[pins["e" .. arm]]
		ringExitX[arm] = ring.x[pins["x" .. arm]]
		-- every car going by an entry counts there, whichever lap
		table.insert(ring.merges, { id = "ring:" .. arm, x = ringEntryX[arm] })
		table.insert(ring.merges, { id = "ring:" .. arm, x = ringEntryX[arm] + ringLapX })
	end
end

------------------------------------------------------------------
-- curb stops: side -1 casinos are served from the inbound lane, side +1 from
-- the outbound one. Every casino has a VALET LANE: 1 to 3 stops in a row in
-- the curb lane (the Parking upgrade adds up to 2). The base stop, level with
-- the entrance (CityLayout.bay), is the FRONT one; the extra stops queue up
-- behind it, ValetSpacing apart (just two: LONG_SPACING apart, so two of the
-- long cars, the Party Shuttle van and the limo, fit nose to tail; three
-- can't, the zone has no room). A car swings into the curb lane on an
-- S-curve that ends at its own stop (braking; BayRun long, shorter where the
-- lane begins too close: outbound lanes start at the ring) and leaves along
-- the curb lane past the stops ahead, then on one S-curve back out past the
-- base stop. So a casino's whole zone runs from base - 2 x ValetSpacing -
-- BayRun to base + BayRun along the traffic and two casinos' zones never
-- overlap. In there cars behave like a valet queue (none drives through
-- another one standing at a stop): Traffic keeps them apart; outside it
-- they're lane traffic like any other (they re-enter at the zone's one merge
-- point).
------------------------------------------------------------------
local VALET_SPACING = TC.ValetSpacing or 15
local LONG_SPACING = 18 -- the limo (17) + a parked gap: what 2 stops get
local VALET_V = TC.ValetSpeed or 12
local MAX_BAYS = 1 + (TC.MaxExtraBays or 2)
local LAT_ACCEL = TC.CurbLatAccel or 20
local MIN_RUN = 14

-- the distance between neighbouring stops of an n-stop valet lane: wider
-- when it fits the 2 x ValetSpacing behind the base every zone may use
local function spacingOf(n: number): number
	if n <= 1 then return VALET_SPACING end
	return math.max(VALET_SPACING, math.min(LONG_SPACING, 2 * VALET_SPACING / (n - 1)))
end
RoadNet.valetSpacing = spacingOf

local zones = {} -- [id] = { arm, k, side, lane, dir, sBase, mergeX, mergeId, layouts = { [n] = layout } }

function RoadNet.bayId(arm: string, k: number, side: number): string
	return arm .. tostring(k) .. (side > 0 and "+" or "-")
end

local function smooth(u: number): number
	return u * u * (3 - 2 * u)
end

local function buildZone(arm: string, k: number, side: number)
	local id = RoadNet.bayId(arm, k, side)
	local lane = lanes[arm][side > 0 and "out" or "in"]
	local dir = side > 0 and 1 or -1 -- the way along s that cars pass this casino
	local sBase = CityLayout.slotS(k)
	local z = {
		id = id, arm = arm, k = k, side = side, lane = lane, dir = dir, sBase = sBase,
		mergeX = laneX(lane, sBase + dir * BAY_RUN), mergeId = "m:" .. id, layouts = {},
	}
	-- cars passing on the lane count where this casino's cars pull back in
	table.insert(lane.merges, { id = z.mergeId, x = z.mergeX })
	zones[id] = z
end

-- speed limits along a polyline: never faster than the lane beside it,
-- ValetSpeed along the curb lane (`along`), through the S-curves no harder
-- sideways than CurbLatAccel
local function curbLimits(lane, pts, sAt, along)
	local lim = {}
	for i, p in pts do
		local _, vLane = trackAt(lane, laneX(lane, sAt[i]))
		local v = math.min(CRUISE, vLane)
		if along[i] then v = math.min(v, VALET_V) end
		if i > 1 and i < #pts then
			local a, b = p - pts[i - 1], pts[i + 1] - p
			local turn = math.acos(math.clamp(a.Unit:Dot(b.Unit), -1, 1))
			local kappa = turn / ((a.Magnitude + b.Magnitude) / 2)
			if kappa > 1e-6 then v = math.min(v, math.sqrt(LAT_ACCEL / kappa)) end
		end
		lim[i] = v
	end
	return lim
end

-- a zone's layout for n stops (built on first use): per stop an approach
-- track (its own S-curve straight in, braking to a halt) and a departure
-- track (along the curb lane past the stops ahead, then the S-curve out)
local function layoutOf(z, n: number)
	n = math.clamp(math.floor(n), 1, MAX_BAYS)
	local L = z.layouts[n]
	if L then return L end
	local arm, side, dir, lane = z.arm, z.side, z.dir, z.lane
	local sStops, runs = {}, {}
	local gap = spacingOf(n)
	for j = 1, n do
		sStops[j] = z.sBase - (n - j) * gap * dir
		local room = dir > 0 and sStops[j] - MOUTH_S or SPAWN_S - sStops[j]
		runs[j] = math.min(BAY_RUN, room - 0.5)
	end
	if runs[1] < MIN_RUN and n > 1 then -- no room for that many stops here
		L = layoutOf(z, n - 1)
		z.layouts[n] = L
		return L
	end
	local tLane, tStop = side * LANE_T, side * STOP_T
	local a = CityLayout.Arms[arm]
	local _, vMerge = trackAt(lane, z.mergeX)

	-- out: from the rearmost stop along the curb lane past the others
	-- (1-stud steps), then an S-curve back to the travel lane, eased so the
	-- sideways move comes early, while the car is still slow
	local out, outS, outAlong = {}, {}, {}
	local function addOut(s: number, t: number, valet: boolean)
		table.insert(out, CityLayout.toWorld(arm, s, t, 0))
		table.insert(outS, s)
		table.insert(outAlong, valet)
	end
	local iStop = { 1 }
	addOut(sStops[1], tStop, true)
	local nGap = math.ceil(gap)
	for j = 2, n do
		for q = 1, nGap do
			addOut(sStops[j - 1] + (sStops[j] - sStops[j - 1]) * q / nGap, tStop, true)
		end
		iStop[j] = #out
	end
	local sOut = sStops[n] + BAY_RUN * dir
	local nOut = math.ceil(BAY_RUN)
	for q = 1, nOut do
		local f = q / nOut
		addOut(sStops[n] + (sOut - sStops[n]) * f, tStop + (tLane - tStop) * (1 - smooth((1 - f) ^ 1.5)), false)
	end
	local outLim = curbLimits(lane, out, outS, outAlong)

	L = { n = n, run = runs[1], divX = {}, stops = {}, app = {}, dep = {} }
	for j = 1, n do
		-- in: an S-curve across the 9 studs between the lanes, parallel to them
		-- at both ends, eased so most of the sideways move comes late (car slow)
		local sIn = sStops[j] - runs[j] * dir
		local nIn = math.ceil(runs[j])
		local ap, apS, apAlong = {}, {}, {}
		for q = 0, nIn do
			local f = q / nIn
			local s = sIn + (sStops[j] - sIn) * f
			table.insert(ap, CityLayout.toWorld(arm, s, tLane + (tStop - tLane) * smooth(f ^ 1.5), 0))
			table.insert(apS, s)
			table.insert(apAlong, false)
		end
		local _, vDiv = trackAt(lane, laneX(lane, sIn))
		local app = newTrack("app:" .. z.id .. j, ap, curbLimits(lane, ap, apS, apAlong))
		setProfile(app, vDiv, 0)
		local dp, dl = {}, {}
		for q = iStop[j], #out do
			table.insert(dp, out[q])
			table.insert(dl, outLim[q])
		end
		local dep = newTrack("dep:" .. z.id .. j, dp, dl)
		setProfile(dep, 0, vMerge)
		L.app[j], L.dep[j], L.divX[j] = app, dep, laneX(lane, sIn)
		L.stops[j] = {
			id = z.id, arm = arm, k = z.k, side = side, slot = j, bays = n, base = j == n,
			s = sStops[j],
			stop = CityLayout.toWorld(arm, sStops[j], tStop, 0), -- the car's ground origin when stopped (y = 0)
			heading = a.out * dir,                             -- its nose: on toward the base stop
			curbDir = a.lat * side,                            -- from the car toward the sidewalk
		}
	end
	z.layouts[n] = L
	return L
end

-- the stop `slot` (1 = rearmost .. n = the base, level with the entrance;
-- default the base) of the casino at (arm, k, side) with `bays` stops:
-- { id (the casino's zone), slot, bays, base, s, stop, heading, curbDir }
function RoadNet.bayInfo(arm: string, k: number, side: number, bays: number?, slot: number?)
	local z = zones[RoadNet.bayId(arm, k, side)]
	if not z then return nil end
	local L = layoutOf(z, bays or 1)
	return L.stops[math.clamp(math.floor(slot or L.n), 1, L.n)]
end

-- how many stops a casino really gets when it may have `bays` (fewer where
-- the lane begins too close behind it)
function RoadNet.baysFor(arm: string, k: number, side: number, bays: number): number
	local z = zones[RoadNet.bayId(arm, k, side)]
	return z and layoutOf(z, bays).n or 1
end

------------------------------------------------------------------
-- build the network once (every client and the server build the same one)
------------------------------------------------------------------
for _, arm in CityLayout.RingOrder do
	lanes[arm] = { ["in"] = buildLane(arm, true), out = buildLane(arm, false) }
	turns[arm] = { entry = buildTurn(arm, "entry"), exit = buildTurn(arm, "exit") }
end
buildRing()
for _, arm in CityLayout.RingOrder do
	for k = 0, ARM.SlotsPerSide - 1 do
		for _, side in { -1, 1 } do buildZone(arm, k, side) end
	end
end

------------------------------------------------------------------
-- paths: a route's polyline, vertex speeds and times (without its dwell)
------------------------------------------------------------------
local function push(acc, p: Vector3, v: number)
	local n = acc.n
	if n > 0 then
		local d = (p - acc.P[n]).Magnitude
		if d < 1e-3 then -- the joint between two tracks
			acc.V[n] = math.min(acc.V[n], v)
			return
		end
		acc.X[n + 1] = acc.X[n] + d
	else
		acc.X[1] = 0
	end
	acc.n = n + 1
	acc.P[n + 1], acc.V[n + 1] = p, v
end

local function markHere(acc, id: string)
	table.insert(acc.marks, { id = id, X = acc.X[acc.n] })
end

-- append track `tr` from arc length x0 to x1; merge points passed on the way
-- (x0 < x <= x1) are marked: every car going by counts there
local function appendSlice(acc, tr, x0: number, x1: number)
	local p, v = trackAt(tr, x0)
	push(acc, p, v)
	local X0 = acc.X[acc.n]
	for _, m in tr.merges do
		if m.x > x0 + 1e-6 and m.x <= x1 + 1e-6 then
			table.insert(acc.marks, { id = m.id, X = X0 + (m.x - x0) })
		end
	end
	local i = segAt(tr.x, tr.n, x0) + 1
	while i <= tr.n and tr.x[i] < x1 - 1e-6 do
		push(acc, tr.pts[i], tr.v[i])
		i += 1
	end
	p, v = trackAt(tr, x1)
	push(acc, p, v)
end

local function appendTrack(acc, tr)
	appendSlice(acc, tr, 0, tr.length)
end

-- round the ring from arm a's entry to arm b's exit
local function appendRing(acc, a: string, b: string)
	local x0, x1 = ringEntryX[a], ringExitX[b]
	if x1 <= x0 then x1 += ringLapX end
	appendSlice(acc, ring, x0, x1)
end

local function timeAtX(path, X: number): number
	local i = segAt(path.X, path.n, X)
	local dx = path.X[i + 1] - path.X[i]
	if dx <= 0 then return path.T[i] end
	local d = math.clamp(X - path.X[i], 0, dx)
	local v0, v1 = path.V[i], path.V[i + 1]
	local a = (v1 * v1 - v0 * v0) / (2 * dx)
	local u
	if math.abs(a) < 1e-9 then
		u = v0 > 0 and d / v0 or 0
	else
		u = (math.sqrt(math.max(0, v0 * v0 + 2 * a * d)) - v0) / a
	end
	return path.T[i] + u
end

local function buildPath(spec)
	local acc = { P = {}, V = {}, X = {}, n = 0, marks = {}, iStop = nil }
	local bay, zone, zoneIn, zoneOut
	if spec.route == "through" then
		local a, b = spec.from, spec.to
		appendTrack(acc, lanes[a]["in"])
		table.insert(acc.marks, { id = "spawn:" .. a, X = 0 })
		appendTrack(acc, turns[a].entry)
		markHere(acc, "ring:" .. a)
		appendRing(acc, a, b)
		appendTrack(acc, turns[b].exit)
		appendTrack(acc, lanes[b].out)
	else
		zone = zones[RoadNet.bayId(spec.arm, spec.k, spec.side)]
		local L = layoutOf(zone, spec.bays or 1)
		local j = math.clamp(math.floor(spec.slot or L.n), 1, L.n)
		bay = L.stops[j]
		local arm, via = spec.arm, spec.via
		-- into the casino's valet lane, halt at stop j, out past the base stop
		local function stopHere()
			zoneIn = acc.X[acc.n]
			appendTrack(acc, L.app[j])
			acc.iStop = acc.n
			appendTrack(acc, L.dep[j])
			markHere(acc, zone.mergeId)
			zoneOut = acc.X[acc.n]
		end
		if spec.side < 0 then
			appendSlice(acc, zone.lane, 0, L.divX[j])
			table.insert(acc.marks, { id = "spawn:" .. arm, X = 0 })
			stopHere()
			appendSlice(acc, zone.lane, zone.mergeX, zone.lane.length)
			appendTrack(acc, turns[arm].entry)
			markHere(acc, "ring:" .. arm)
			appendRing(acc, arm, via)
			appendTrack(acc, turns[via].exit)
			appendTrack(acc, lanes[via].out)
		else
			appendTrack(acc, lanes[via]["in"])
			table.insert(acc.marks, { id = "spawn:" .. via, X = 0 })
			appendTrack(acc, turns[via].entry)
			markHere(acc, "ring:" .. via)
			appendRing(acc, via, arm)
			appendTrack(acc, turns[arm].exit)
			appendSlice(acc, zone.lane, 0, L.divX[j])
			stopHere()
			appendSlice(acc, zone.lane, zone.mergeX, zone.lane.length)
		end
	end

	local P, V, X, n = acc.P, acc.V, acc.X, acc.n
	local T = { 0 }
	for i = 1, n - 1 do
		local vs = V[i] + V[i + 1]
		T[i + 1] = T[i] + (vs > 1e-6 and 2 * (X[i + 1] - X[i]) / vs or 0)
	end
	-- a heading per vertex, blended between vertices so turns read smooth
	local D = {}
	for i = 1, n do
		local d = P[math.min(n, i + 1)] - P[math.max(1, i - 1)]
		D[i] = d.Magnitude > 1e-6 and d.Unit or (D[i - 1] or Vector3.new(0, 0, -1))
	end
	local path = { P = P, V = V, X = X, T = T, D = D, n = n, iStop = acc.iStop, bay = bay, length = X[n] }
	path.stopT = acc.iStop and T[acc.iStop] or nil
	path.conflicts = {}
	for _, m in acc.marks do
		table.insert(path.conflicts, {
			id = m.id, t = timeAtX(path, m.X),
			post = acc.iStop ~= nil and m.X > X[acc.iStop] + 1e-6,
		})
	end
	-- the stretch it spends in its casino's valet lane (times without the
	-- dwell; tOut comes after the stop, so it moves with the dwell)
	if zone then
		path.zone = { id = zone.id, arm = zone.arm, tIn = timeAtX(path, zoneIn), tOut = timeAtX(path, zoneOut) }
	end
	return path
end

------------------------------------------------------------------
-- routes
------------------------------------------------------------------
local cache = {} -- spec key -> path (the dwell only shifts the times after the stop)

local function specKey(spec): string?
	if type(spec) ~= "table" then return nil end
	if spec.route == "through" then
		if ARM_OK[spec.from] and ARM_OK[spec.to] and spec.from ~= spec.to then
			return "t" .. spec.from .. spec.to
		end
	elseif spec.route == "bay" then
		local k, side, bays, slot = spec.k, spec.side, spec.bays or 1, spec.slot
		if ARM_OK[spec.arm] and ARM_OK[spec.via] and spec.arm ~= spec.via
			and (k == 0 or k == 1 or k == 2) and (side == 1 or side == -1)
			and type(bays) == "number" and (slot == nil or type(slot) == "number") then
			local id = RoadNet.bayId(spec.arm, k, side)
			local L = layoutOf(zones[id], bays)
			local j = math.clamp(math.floor(slot or L.n), 1, L.n)
			return "b" .. id .. spec.via .. L.n .. "." .. j
		end
	end
	return nil
end

local Route = {}
Route.__index = Route

-- position (y = 0), unit heading and speed, t seconds after the start
function Route:locate(t: number): (Vector3, Vector3, number)
	local path = self.path
	local T, n = path.T, path.n
	if path.iStop then
		local ts = T[path.iStop]
		if t > ts then
			if t <= ts + self.dwell then
				return path.P[path.iStop], path.D[path.iStop], 0
			end
			t -= self.dwell
		end
	end
	if t <= 0 then return path.P[1], path.D[1], path.V[1] end
	if t >= T[n] then return path.P[n], path.D[n], path.V[n] end
	local i = segAt(T, n, t)
	local v0, v1 = path.V[i], path.V[i + 1]
	local dx = path.X[i + 1] - path.X[i]
	local u = t - T[i]
	local d, v = 0, v0
	if dx > 0 then
		local a = (v1 * v1 - v0 * v0) / (2 * dx)
		d = math.clamp(v0 * u + 0.5 * a * u * u, 0, dx)
		v = v0 + a * u
	end
	local f = dx > 0 and d / dx or 0
	local dir = path.D[i]:Lerp(path.D[i + 1], f)
	return path.P[i]:Lerp(path.P[i + 1], f), dir.Magnitude > 1e-6 and dir.Unit or path.D[i], v
end

-- the car's CFrame (ground origin on the road top, nose along its way)
function Route:sample(t: number): CFrame
	local p, dir = self:locate(t)
	local at = p + ROAD_UP
	return CFrame.lookAt(at, at + dir)
end

-- a route for a spec (nil if the spec is bad); cheap after the first build
function RoadNet.build(spec)
	local key = specKey(spec)
	if not key then return nil end
	local path = cache[key]
	if not path then
		path = buildPath(spec)
		cache[key] = path
	end
	local dwell = path.iStop and math.max(0, tonumber(spec.dwell) or 0) or 0
	local route = setmetatable({ path = path, spec = spec, dwell = dwell, bay = path.bay, zone = path.zone }, Route)
	route.duration = path.T[path.n] + dwell
	route.stopTime = path.stopT
	route.stopEnd = path.stopT and path.stopT + dwell or nil
	route.conflicts = {}
	for i, c in path.conflicts do
		route.conflicts[i] = { id = c.id, t = c.t + (c.post and dwell or 0), post = c.post }
	end
	return route
end

-- the arm whose cars reach `arm`'s exit first after joining the ring (the
-- shortest way round to it)
function RoadNet.shortestEntry(arm: string): string
	local order = CityLayout.RingOrder
	local i = table.find(order, arm) or 1
	return order[(i - 2) % #order + 1]
end

return RoadNet
