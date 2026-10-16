--!nonstrict
-- DecorRules.luau — where a decor piece (Config.Decor) may stand. Shared by the
-- server (CasinoServer/Decor.luau has the last word) and the client's build mode
-- (green / red ghost), so both refuse the same spots with the same words.
--
-- Pieces are boxes (def.size X x Z, turned about Y) in the plot's frame:
--   * inside the casino; solid pieces keep Config.WallClearance from the walls,
--     flat ones (floors, paths, rugs) may run right up to them
--   * off the elevator booth; solid pieces also keep its landing clear, and on
--     the ground floor the entrance (the doorway + 6 studs of lobby inside it)
--   * solid pieces keep Config.DecorMachineGap from every machine's footprint
--     (FootprintRadius) and stay out of the lane in front of it that guests walk
--     (ApproachDistance .. + 3, like NPCs.luau); flat pieces may lie under machines
--   * solid pieces don't overlap solid pieces; flat pieces don't overlap flat
--     pieces of the same `layer` (touching is fine: rows of tiles / hedges);
--     solid pieces may stand on flat ones
-- Placed decor = models tagged "CasinoDecor" with attributes OwnerId, DecorId,
-- PlacedId, Story, Flat; machines = models tagged "CasinoMachine" (OwnerId,
-- FootprintRadius, ApproachDistance). Things more than half a story apart
-- never clash.
--
-- API (base = the plot's Base part, cf = the piece's ground CFrame in the world):
--   DecorRules.check(base, ownerId, def, cf, ignore?) -> (ok, why?)
--   DecorRules.machineCheck(base, ownerId, pos, rotY, radius, reach) -> (ok, why?)
--       a machine about to stand at `pos` (world ground point, yaw rotY degrees)
--       against the solid decor: Placement's machine checks call it
--   DecorRules.countOnStory(base, ownerId, y, ignore?) -> number of pieces on that story
--   DecorRules.storyAt(base, y) -> story number (1-based) of a world height

local CollectionService = game:GetService("CollectionService")
local Config = require(script.Parent:WaitForChild("Config"))

local DecorRules = {}

DecorRules.Tag = "CasinoDecor"

local H = Config.Building.StoryHeight
local E = Config.Building.Elevator
local TOUCH = 0.05          -- studs two boxes may overlap and still count as touching
local LANE_CLEAR = 1.2      -- studs a solid piece keeps from the spots guests walk to at a machine
local LANE = { 0, 1, 2, 3 } -- those spots: ApproachDistance + these, in front of the machine
-- the ground floor's entrance (Buildings.luau: the doorway is |x| < 10 in the
-- plot's front wall, local -Z): solid pieces leave it and the lobby just inside free
local DOOR_HALF, DOOR_DEPTH = 10, 6

-- a box in the plot frame: centre (x, z), half sizes (hx, hz) along its own unit
-- axes u (its local X) and v (its local Z), all in the plot frame's XZ plane
local function boxOf(base: BasePart, cf: CFrame, size: Vector3)
	local rel = base.CFrame:ToObjectSpace(cf)
	local r, l = rel.RightVector, rel.LookVector
	local ru = math.sqrt(r.X * r.X + r.Z * r.Z)
	local lu = math.sqrt(l.X * l.X + l.Z * l.Z)
	if ru < 1e-6 then ru = 1 end
	if lu < 1e-6 then lu = 1 end
	return {
		x = rel.X, z = rel.Z, hx = size.X / 2, hz = size.Z / 2,
		ux = r.X / ru, uz = r.Z / ru, vx = -l.X / lu, vz = -l.Z / lu,
	}
end
DecorRules.boxOf = boxOf

-- an axis-aligned box in the plot frame
local function rectBox(x0: number, x1: number, z0: number, z1: number)
	return { x = (x0 + x1) / 2, z = (z0 + z1) / 2, hx = (x1 - x0) / 2, hz = (z1 - z0) / 2, ux = 1, uz = 0, vx = 0, vz = 1 }
end

-- separating-axis test: true when the boxes overlap by more than `tol`
local function overlaps(a, b, tol: number): boolean
	local dx, dz = b.x - a.x, b.z - a.z
	for _, ax in { { a.ux, a.uz }, { a.vx, a.vz }, { b.ux, b.uz }, { b.vx, b.vz } } do
		local x, z = ax[1], ax[2]
		local ra = a.hx * math.abs(a.ux * x + a.uz * z) + a.hz * math.abs(a.vx * x + a.vz * z)
		local rb = b.hx * math.abs(b.ux * x + b.uz * z) + b.hz * math.abs(b.vx * x + b.vz * z)
		if math.abs(dx * x + dz * z) >= ra + rb - tol then return false end
	end
	return true
end
DecorRules.overlaps = overlaps

-- distance from a point (plot frame) to a box (0 inside it)
local function pointDist(b, px: number, pz: number): number
	local dx, dz = px - b.x, pz - b.z
	local lu = dx * b.ux + dz * b.uz
	local lv = dx * b.vx + dz * b.vz
	local cu = math.clamp(lu, -b.hx, b.hx)
	local cv = math.clamp(lv, -b.hz, b.hz)
	return math.sqrt((lu - cu) ^ 2 + (lv - cv) ^ 2)
end
DecorRules.pointDist = pointDist

-- half extents of a box along the plot's own axes
local function extents(b): (number, number)
	return math.abs(b.ux) * b.hx + math.abs(b.vx) * b.hz, math.abs(b.uz) * b.hx + math.abs(b.vz) * b.hz
end

function DecorRules.layerOf(def): number
	if not (def and def.flat) then return 0 end
	return tonumber(def.layer) or 2
end

-- story number (1-based) of a world height in this plot (as Buildings.storyAt)
function DecorRules.storyAt(base: BasePart, y: number): number
	local localY = y - (base.Position.Y - base.Size.Y / 2)
	return math.max(1, math.floor((localY - 1) / H + 0.25) + 1)
end

local function sameStory(a: number, b: number): boolean
	return math.abs(a - b) < H / 2
end

-- the points (plot frame) a guest walks to in front of a machine model, or nil
local function laneOf(base: BasePart, m: Instance)
	local prim = m:IsA("Model") and m.PrimaryPart
	local reach = m:GetAttribute("ApproachDistance")
	if not (prim and reach) then return nil end
	local pts = {}
	for _, extra in LANE do
		local p = base.CFrame:PointToObjectSpace(prim.Position + prim.CFrame.LookVector * (reach + extra))
		table.insert(pts, { p.X, p.Z })
	end
	return pts
end

local function decorDefOf(m: Instance)
	return Config.getDecorDef(m:GetAttribute("DecorId"))
end

-- Can `def` stand at the world ground CFrame `cf` in the casino whose Base is
-- `base`? `ignore`: the piece being moved. Returns (true) or (false, why).
function DecorRules.check(base: BasePart, ownerId: number, def, cf: CFrame, ignore: Instance?): (boolean, string?)
	if not (base and def and def.size) then return false, "Unknown decor." end
	local b = boxOf(base, cf, def.size)
	local half = base.Size / 2
	if math.abs(b.x) > half.X or math.abs(b.z) > half.Z then
		return false, "Place it inside your casino."
	end
	local flat = def.flat == true
	local ex, ez = extents(b)
	local clear = flat and 0 or (Config.WallClearance or 0.6)
	if math.abs(b.x) + ex > half.X - clear + 1e-3 or math.abs(b.z) + ez > half.Z - clear + 1e-3 then
		return false, "Too close to the wall."
	end
	-- the elevator booth (+ its call button); solid pieces keep its landing clear too
	local eh = E.size / 2
	local lift = rectBox(E.x - eh - 1.6, E.x + eh + 1.6, E.z - eh - (flat and 0 or 5), E.z + eh)
	if overlaps(b, lift, 0) then
		return false, "Keep the elevator clear."
	end
	local y = cf.Position.Y
	if not flat and DecorRules.storyAt(base, y) == 1
		and overlaps(b, rectBox(-DOOR_HALF, DOOR_HALF, -half.Z - 1, -half.Z + DOOR_DEPTH), 0) then
		return false, "Keep the entrance clear."
	end
	if not flat then
		local gap = Config.DecorMachineGap or 0.6
		for _, m in CollectionService:GetTagged("CasinoMachine") do
			if m ~= ignore and m.Parent and m:GetAttribute("OwnerId") == ownerId then
				local piv = m:GetPivot().Position
				if sameStory(piv.Y, y) then
					local p = base.CFrame:PointToObjectSpace(piv)
					local r = (m:GetAttribute("FootprintRadius") or 2.5) + gap
					if pointDist(b, p.X, p.Z) < r then
						return false, "Too close to your " .. m.Name .. "."
					end
					local lane = laneOf(base, m)
					if lane then
						for _, q in lane do
							if pointDist(b, q[1], q[2]) < LANE_CLEAR then
								return false, "Keep the front of your " .. m.Name .. " clear."
							end
						end
					end
				end
			end
		end
	end
	local layer = DecorRules.layerOf(def)
	for _, d in CollectionService:GetTagged(DecorRules.Tag) do
		if d ~= ignore and d.Parent and d:GetAttribute("OwnerId") == ownerId then
			local other = decorDefOf(d)
			if other and sameStory(d:GetPivot().Position.Y, y) then
				local otherLayer = DecorRules.layerOf(other)
				-- solid vs solid, or flat vs flat on the same layer
				if (not flat and not other.flat) or (flat and other.flat and otherLayer == layer) then
					if overlaps(b, boxOf(base, d:GetPivot(), other.size), TOUCH) then
						return false, (flat and "Overlaps your " or "Too close to your ") .. other.name .. "."
					end
				end
			end
		end
	end
	return true, nil
end

-- A machine about to stand at the world ground point `pos` (yaw `rotY` degrees,
-- footprint radius `radius`, guests stand `reach` in front of it): is any solid
-- decor in its way? (machines vs machines stays Plots.overlapsMachine's job)
function DecorRules.machineCheck(base: BasePart, ownerId: number, pos: Vector3, rotY: number, radius: number,
	reach: number, ignore: Instance?): (boolean, string?)
	if not base then return true, nil end
	local p = base.CFrame:PointToObjectSpace(pos)
	local look = CFrame.Angles(0, math.rad(tonumber(rotY) or 0), 0).LookVector
	local gap = Config.DecorMachineGap or 0.6
	local lane = {}
	for _, extra in LANE do
		local q = base.CFrame:PointToObjectSpace(pos + look * ((tonumber(reach) or 3) + extra))
		table.insert(lane, { q.X, q.Z })
	end
	for _, d in CollectionService:GetTagged(DecorRules.Tag) do
		if d ~= ignore and d.Parent and d:GetAttribute("OwnerId") == ownerId then
			local def = decorDefOf(d)
			if def and not def.flat and sameStory(d:GetPivot().Position.Y, pos.Y) then
				local b = boxOf(base, d:GetPivot(), def.size)
				if pointDist(b, p.X, p.Z) < radius + gap then
					return false, "Too close to your " .. def.name .. "."
				end
				for _, q in lane do
					if pointDist(b, q[1], q[2]) < LANE_CLEAR then
						return false, "Your " .. def.name .. " blocks its front."
					end
				end
			end
		end
	end
	return true, nil
end

-- pieces this owner has on the story at world height `y`
function DecorRules.countOnStory(base: BasePart, ownerId: number, y: number, ignore: Instance?): number
	local n = 0
	for _, d in CollectionService:GetTagged(DecorRules.Tag) do
		if d ~= ignore and d.Parent and d:GetAttribute("OwnerId") == ownerId and sameStory(d:GetPivot().Position.Y, y) then
			n += 1
		end
	end
	return n
end

return DecorRules
