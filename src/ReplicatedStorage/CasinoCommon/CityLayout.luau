--!nonstrict
-- CityLayout.luau — the city plan in one place. A plaza in the middle, a
-- one-way ring road (a roundabout) around it, and four boulevards ("arms")
-- running out N / E / S / W to tunnels in the valley walls. Casinos line both
-- sides of every arm, three per side; one slot on the south arm holds the
-- Machine Showroom instead (23 casinos in all).
--
-- MapBuilder builds the world from this; Plots, Showroom, Traffic and the NPCs
-- use it to find plots, curb stops and lanes, so everything lines up.
--
-- Frames:
--   * world: y up, the map's "north" is world -Z (the top of the design
--     sketch), east is +X.
--   * arm frame: s = distance from the centre along the arm (`out`),
--     t = sideways offset along `lat`, the right-hand side when facing out.
--     Traffic keeps right: outbound cars use +t, inbound cars -t.
--   * plot frame (plotCFrame): the plot's ground centre, y = 0 at the bottom
--     of its 1-stud base, front (-Z) facing the boulevard — the same frame
--     Buildings.luau / Facade.luau build in.

local CityLayout = {}

-- surface heights (tops)
local Y = { City = 0.2, Lot = 0.35, Road = 0.4, Bed = 0.5, Walk = 0.8, PlotTop = 1.0 }
CityLayout.Y = Y

-- one boulevard, measured in its arm frame
local ARM = {
	MedianHalf = 5,   -- planted median, |t| <= 5
	TravelLane = 9.5, -- lane centres: cars drive here ...
	StopLane = 18.5,  -- ... and pull into this curb lane to stop at a casino
	RoadHalf = 23,    -- curb line (|t| = 23)
	WalkOuter = 35,   -- sidewalk 23..35; casino fronts stand on this line
	PlotW = 79,       -- plot base (unchanged, so saved machine layouts fit)
	PlotD = 81,
	PlotStart = 126,  -- the first plot's near edge (clear of the ring's sidewalk)
	SlotPitch = 101,  -- plot centre to plot centre along the arm (22-stud alleys)
	SlotsPerSide = 3,
	PortalS = 432,    -- tunnel mouth in the valley wall
	SpawnS = 470,     -- cars appear / vanish here, deep in the dark tunnel
	TunnelEndS = 480,
}
CityLayout.Arm = ARM

-- the plaza + ring road, measured from the centre (the same on every side)
local RING = {
	PlazaHalf = 88,   -- the plaza: |x|, |z| <= 88, corners rounded (r 13)
	RoadOuter = 110,  -- the ring road: 88..110, two lanes, one way
	WalkOuter = 122,  -- its outer sidewalk: 110..122 (square outer edge)
	CornerC = 75,     -- every rounded corner is centred on (±75, ±75)
	Lane = 104.5,     -- cars circulate in the outer lane (corner radius 29.5)
	InnerLane = 93.5,
	Divider = 99,     -- the yellow dashed divider between the lanes (corner radius 24)
	MouthS = 116,     -- arm lanes end / start here and turn onto / off the ring
	TurnR = 11.5,     -- radius of those right turns
}
CityLayout.Ring = RING

-- the arms, and the order the ring's (anticlockwise from above, keep-right)
-- traffic passes them
local ARMS = {
	E = { name = "E", out = Vector3.new(1, 0, 0) },
	N = { name = "N", out = Vector3.new(0, 0, -1) },
	W = { name = "W", out = Vector3.new(-1, 0, 0) },
	S = { name = "S", out = Vector3.new(0, 0, 1) },
}
for _, a in ARMS do
	a.lat = a.out:Cross(Vector3.yAxis) -- the right-hand side when facing out
end
CityLayout.Arms = ARMS
CityLayout.RingOrder = { "E", "N", "W", "S" } -- the next arm's `out` is always -lat of this one

------------------------------------------------------------------
-- frames
------------------------------------------------------------------
function CityLayout.toWorld(arm: string, s: number, t: number, y: number?): Vector3
	local a = ARMS[arm]
	return a.out * s + a.lat * t + Vector3.new(0, y or 0, 0)
end

-- a CFrame at (s, t, y) in an arm, looking along the arm (out or back in)
function CityLayout.armCFrame(arm: string, s: number, t: number, y: number?, facingOut: boolean?): CFrame
	local p = CityLayout.toWorld(arm, s, t, y)
	local dir = ARMS[arm].out * (facingOut == false and -1 or 1)
	return CFrame.lookAt(p, p + dir)
end

------------------------------------------------------------------
-- casino slots
------------------------------------------------------------------
-- distance along the arm of slot k's centre (k = 0 is next to the plaza)
function CityLayout.slotS(k: number): number
	return ARM.PlotStart + ARM.PlotW / 2 + k * ARM.SlotPitch -- 165.5, 266.5, 367.5
end

-- the plot frame for slot k on `side` (+1 = the arm's +lat side, -1 = -lat)
function CityLayout.plotCFrame(arm: string, k: number, side: number): CFrame
	local a = ARMS[arm]
	local c = CityLayout.toWorld(arm, CityLayout.slotS(k), side * (ARM.WalkOuter + ARM.PlotD / 2), 0)
	return CFrame.lookAt(c, c - a.lat * side) -- front (-Z) to the road
end

-- the pink slot of the design: south arm, west side, farthest out
CityLayout.ShowroomSlot = { arm = "S", k = 2, side = 1 }

-- Config.Showroom.Center / Yaw for that slot: the room's front plane (room
-- z = 18) sits on the plot-front line, its entrance facing the boulevard
function CityLayout.showroomFrame(): (Vector3, number)
	local sl = CityLayout.ShowroomSlot
	local a = ARMS[sl.arm]
	local center = CityLayout.toWorld(sl.arm, CityLayout.slotS(sl.k), sl.side * (ARM.WalkOuter + 18), 0.5)
	local dir = -a.lat * sl.side
	return center, math.deg(math.atan2(dir.X, dir.Z))
end

-- every casino plot, in assignment order: nearest the plaza first, so the
-- middle of town fills up before the far ends
CityLayout.Plots = {}
do
	local sl = CityLayout.ShowroomSlot
	local index = 0
	for k = 0, ARM.SlotsPerSide - 1 do
		for _, arm in { "N", "E", "S", "W" } do
			for _, side in { -1, 1 } do
				if not (arm == sl.arm and k == sl.k and side == sl.side) then
					index += 1
					table.insert(CityLayout.Plots, {
						index = index, arm = arm, k = k, side = side,
						cframe = CityLayout.plotCFrame(arm, k, side),
					})
				end
			end
		end
	end
end

------------------------------------------------------------------
-- curb stops ("bays")
------------------------------------------------------------------
-- where a car stops for the casino in slot (arm, k, side): in the curb lane,
-- level with the entrance. Side -1 casinos are served by inbound cars, side +1
-- casinos by outbound cars (the lane on their side of the road).
function CityLayout.bay(arm: string, k: number, side: number)
	local s = CityLayout.slotS(k)
	return {
		arm = arm, k = k, side = side, s = s,
		t = side * ARM.StopLane,
		dir = side > 0 and "out" or "in",
		stop = CityLayout.toWorld(arm, s, side * ARM.StopLane, Y.Road),          -- the car's centre
		curb = CityLayout.toWorld(arm, s, side * (ARM.RoadHalf + 1.5), Y.Walk),  -- passengers step out here
	}
end

-- the bay for a plot model built by MapBuilder (attributes Arm / Slot / Side)
function CityLayout.bayForPlot(plotModel: Instance)
	local arm, k, side = plotModel:GetAttribute("Arm"), plotModel:GetAttribute("Slot"), plotModel:GetAttribute("Side")
	if not (arm and ARMS[arm] and k and side) then return nil end
	return CityLayout.bay(arm, k, side)
end

------------------------------------------------------------------
-- the ring road
------------------------------------------------------------------
local SIDE_LEN = 2 * RING.CornerC -- 150: the straight run on every side

local function arcLen(d: number): number
	return math.pi / 2 * (d - RING.CornerC)
end

-- total length of the rounded square at distance d from the centre
function CityLayout.ringLength(d: number?): number
	return 4 * (SIDE_LEN + arcLen(d or RING.Lane))
end

-- A point on the ring's rounded square at distance d (default: the car lane),
-- u = arc length in the direction of travel, starting where the E side's
-- straight begins (t = +75). Returns the position (y = 0) and the unit travel
-- direction. Along an arm's side the flow runs along -lat.
function CityLayout.ringPoint(u: number, d: number?): (Vector3, Vector3)
	d = d or RING.Lane
	local seg = SIDE_LEN + arcLen(d)
	u = u % (4 * seg)
	local i = math.floor(u / seg)
	local v = u - i * seg
	local A = ARMS[CityLayout.RingOrder[i + 1]]
	if v <= SIDE_LEN then
		return A.out * d + A.lat * (RING.CornerC - v), -A.lat
	end
	local r = d - RING.CornerC
	local phi = (v - SIDE_LEN) / r
	local nextOut = -A.lat
	local c = A.out * RING.CornerC + nextOut * RING.CornerC
	return c + (A.out * math.cos(phi) + nextOut * math.sin(phi)) * r,
		-A.out * math.sin(phi) + nextOut * math.cos(phi)
end

-- a closed polyline along the rounded square at distance d (for kerbs,
-- markings, slabs): points every ~step studs, corners included
function CityLayout.ringPolyline(d: number, step: number?): { Vector3 }
	step = step or 2
	local total = CityLayout.ringLength(d)
	local n = math.max(8, math.ceil(total / step))
	local pts = {}
	for i = 0, n - 1 do
		local p = CityLayout.ringPoint(total * i / n, d)
		table.insert(pts, p)
	end
	return pts
end

-- where the car lane leaves the ring for arm `arm` (exit: a diverge) and where
-- that arm's inbound lane joins it (entry: a merge), as ring arc lengths u.
-- On every side the exit comes first (t = +21), then the entry (t = -21).
function CityLayout.mouthU(arm: string): (number, number)
	local i = table.find(CityLayout.RingOrder, arm) - 1
	local u0 = i * (SIDE_LEN + arcLen(RING.Lane))
	local tTurn = ARM.TravelLane + RING.TurnR -- 21
	return u0 + (RING.CornerC - tTurn), u0 + (RING.CornerC + tTurn)
end

-- the right turn from an arm's inbound lane onto the ring ("entry") or from
-- the ring onto its outbound lane ("exit"), sampled every ~step studs; each
-- sample is { pos = Vector3 (y = 0), dir = unit travel direction }
function CityLayout.turnPoints(arm: string, kind: string, step: number?)
	local a = ARMS[arm]
	local R = RING.TurnR
	local n = math.max(4, math.ceil((math.pi / 2 * R) / (step or 1)))
	local pts = {}
	if kind == "entry" then
		-- (MouthS, -9.5) heading -out  ->  (Lane, -21) heading -lat
		local c = CityLayout.toWorld(arm, RING.MouthS, -(ARM.TravelLane + R))
		for i = 0, n do
			local th = (math.pi / 2) * i / n
			table.insert(pts, {
				pos = c + (a.lat * math.cos(th) - a.out * math.sin(th)) * R,
				dir = -a.lat * math.sin(th) - a.out * math.cos(th),
			})
		end
	else
		-- (Lane, +21) heading -lat  ->  (MouthS, +9.5) heading +out
		local c = CityLayout.toWorld(arm, RING.MouthS, ARM.TravelLane + R)
		for i = 0, n do
			local th = (math.pi / 2) * i / n
			table.insert(pts, {
				pos = c + (-a.out * math.cos(th) - a.lat * math.sin(th)) * R,
				dir = a.out * math.sin(th) - a.lat * math.cos(th),
			})
		end
	end
	return pts
end

------------------------------------------------------------------
-- tunnels, open blocks, valley wall
------------------------------------------------------------------
-- the tunnel mouth at the end of an arm (road level, centred on the road),
-- its face looking back at the city
function CityLayout.portalCFrame(arm: string): CFrame
	local a = ARMS[arm]
	local p = CityLayout.toWorld(arm, ARM.PortalS, 0, Y.Road)
	return CFrame.lookAt(p, p - a.out)
end

-- the four open blocks between the arms, behind the casinos' back walls, as
-- world rectangles (x0 < x1, z0 < z1); for resort towers, landmarks, lots
local BACK = ARM.WalkOuter + ARM.PlotD -- 116: the plots' back line
CityLayout.PlotBack = BACK
CityLayout.Quadrants = {
	{ name = "NE", x0 = BACK, x1 = ARM.PortalS, z0 = -ARM.PortalS, z1 = -BACK },
	{ name = "NW", x0 = -ARM.PortalS, x1 = -BACK, z0 = -ARM.PortalS, z1 = -BACK },
	{ name = "SW", x0 = -ARM.PortalS, x1 = -BACK, z0 = BACK, z1 = ARM.PortalS },
	{ name = "SE", x0 = BACK, x1 = ARM.PortalS, z0 = BACK, z1 = ARM.PortalS },
}

-- the valley wall runs round the city on this square (the tunnels pierce it)
CityLayout.ValleyHalf = ARM.PortalS

return CityLayout
