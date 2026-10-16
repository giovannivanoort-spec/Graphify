--!nonstrict
-- PlacementController.luau — BUILD MODE: place machines, stands and decor from
-- your inventory and move what's already placed, in one session that lasts
-- until DONE / Esc.
--   * the build bar (bottom centre, Showtime style): a status pill, the actions
--     (PLACE, ROTATE, the floor picker, GRID, MOVE / STORE, DONE) and a tray
--     with everything in your inventory (machines, stands, decor) as 3D-icon
--     tiles with counts; a tile switches the ghost to that item
--   * after a place the session goes on: the next copy of the same item, else
--     the next tile (rotation, floor and grid stay). Item ids just placed stay
--     out of the tray until the server's snapshot catches up.
--   * MOVE (M): click / tap one of your machines or decor pieces, then where it
--     goes; STORE puts it back in your inventory. A move started from the
--     machine popup (ManageUI) ends the session once it's done.
--   * the ghost is the real model (ReplicatedStorage.MachinePreviews /
--     DecorPreviews): green when the spot is free, red with the reason when it
--     isn't (the server's own rules: machine checks + CasinoCommon/DecorRules;
--     the server has the last word). A ring marks the footprint (an outline
--     for flat decor).
--   * the cursor is projected onto the floor you build on; the camera follows
--     that floor (Humanoid.CameraOffset, eased) and the stories above are cut
--     away (BuildingView.setForced), so UP / DOWN show the floor you build on.
--     A floor change drops the old target; riding the elevator mid-session
--     takes the build floor along.
--   * a 1-stud grid in the plot's frame; flat decor also clicks edge to edge onto
--     a neighbour of its own layer (rows of tiles / paths join up). G toggles
--     free placement. R rotates 45° (Shift+R back), PageUp / PageDown switch
--     floors, Esc ends the session.
--   * touch: tap where it should go, then PLACE (no key hints)
--   * starting far from your casino hops you home first (HudUI.travelTo)
--   * juice (UXFX through UILib.fx, a no-op without it): the piece drops in
--     with a thud and a dust ring, the ghost shakes its head at a bad spot,
--     ticks on R / floor / grid
-- API: begin(item), beginDecor(decorId), beginMove(model), enterSelectMode(),
-- cancel(), isBusy(), defFromItem(item), decorInfo(decorId)

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local TweenService = game:GetService("TweenService")

local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Remotes = require(Common:WaitForChild("Remotes"))
local Config = require(Common:WaitForChild("Config"))
local UILib = require(script.Parent:WaitForChild("UILib"))
local BuildingView = require(script.Parent:WaitForChild("BuildingView"))
local C = UILib.Colors
local F = UILib.Fonts
local A = UILib.Assets

local player = Players.LocalPlayer

local PlacementController = {}

local H = Config.Building.StoryHeight
local E = Config.Building.Elevator
local CLEAR = Config.WallClearance or 0.6
local GAP = Config.MachineGap or 1.2
local TOUCH = UILib.IsTouch
local MACHINE_TAG, DECOR_TAG = "CasinoMachine", "CasinoDecor"

local session = nil       -- the running build session (nil = not building)
local opening = false     -- a session is on its way (hopping home first)
local camTween = nil      -- the camera easing back after a session
local lastPanelClose = 0  -- an Esc that just closed a panel doesn't also end the session
UILib.onFx(function(event)
	if event == "panelClose" then lastPanelClose = os.clock() end
end)

------------------------------------------------------------------
-- plot helpers
------------------------------------------------------------------
local function findOwnPlot(): Model?
	local plots = Workspace:FindFirstChild("Plots")
	if plots then
		for _, m in plots:GetChildren() do
			if m:GetAttribute("OwnerId") == player.UserId and m:FindFirstChild("Base") then return m end
		end
	end
	return nil
end

local function storiesOf(plot: Model): number
	local b = plot and plot:FindFirstChild("Building")
	return b and b:GetAttribute("Stories") or 1
end

-- the VIP floor's story (Building attribute VipStory; nil without one): the floor
-- picker calls it "VIP"
local function vipStoryOf(plot: Model): number?
	local b = plot and plot:FindFirstChild("Building")
	local v = b and b:GetAttribute("VipStory")
	return type(v) == "number" and v or nil
end

local function storyY(plot: Model, story: number): number
	local base = plot.Base
	return base.Position.Y + base.Size.Y / 2 + (story - 1) * H
end

-- the story the player is standing on in their own casino (1 outside)
local function playerStory(plot: Model): number
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not root then return 1 end
	local base = plot.Base
	local feet = root.Position.Y - 3 - (base.Position.Y - base.Size.Y / 2)
	return math.clamp(math.floor((feet - 1) / H + 0.25) + 1, 1, storiesOf(plot))
end

-- a placed model's story: its Story attribute, else its height
local function storyOfModel(plot: Model, m: Instance): number
	local s = m:GetAttribute("Story")
	if type(s) == "number" then return s end
	local base = plot.Base
	local y = (m :: Model):GetPivot().Position.Y - (base.Position.Y - base.Size.Y / 2)
	return math.max(1, math.floor((y - 1) / H + 0.25) + 1)
end

-- the way the casino faces (the street): new pieces start out facing it
local function plotYaw(plot: Model): number
	local _, ry = plot.Base.CFrame:ToOrientation()
	return math.deg(ry)
end

local function farFrom(plot: Model): boolean
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not root then return false end
	local base = plot.Base
	local rel = base.CFrame:PointToObjectSpace(root.Position)
	return math.abs(rel.X) > base.Size.X / 2 + 50 or math.abs(rel.Z) > base.Size.Z / 2 + 50
end

------------------------------------------------------------------
-- catalog: machines (Config.Catalog) and decor (Config.Decor, owned by DECOR:
-- a list of { id, name, category, cost, size, flat, appeal, ... } or an
-- id -> def map; Config.getDecorDef is used when it exists)
------------------------------------------------------------------
local decorIndex, decorRank = nil, nil
local function indexDecor()
	if decorIndex then return end
	decorIndex, decorRank = {}, {}
	local list = Config.Decor
	if type(list) ~= "table" then return end
	local n = 0
	for k, d in list do
		if type(d) == "table" then
			local id = (type(d.id) == "string" and d.id) or (type(k) == "string" and k) or nil
			if id then
				n += 1
				decorIndex[id] = d
				decorRank[id] = type(k) == "number" and k or n
			end
		end
	end
end

local function decorDef(decorId: any)
	if type(decorId) ~= "string" then return nil end
	if type(Config.getDecorDef) == "function" then
		local ok, d = pcall(Config.getDecorDef, decorId)
		if ok and type(d) == "table" then return d end
	end
	indexDecor()
	return decorIndex[decorId]
end

-- a decor def's footprint (size may be a Vector3 like the machines', or x/z)
local function decorSize(d): Vector3
	local s = d and (d.size or d.footprint)
	if typeof(s) == "Vector3" then return s end
	if typeof(s) == "Vector2" then return Vector3.new(s.X, 1, s.Y) end
	if type(s) == "number" then return Vector3.new(s, 1, s) end
	if type(s) == "table" then
		local x = tonumber(s.X or s.x or s[1]) or 4
		return Vector3.new(x, tonumber(s.Y or s.y) or 1, tonumber(s.Z or s.z or s[3] or s[2]) or x)
	end
	return Vector3.new(4, 4, 4)
end

-- icon + tone of a decor piece: its own `icon` / `tone`, else by category
local DECOR_LOOKS = {
	{ "plant", "plant", "Green" }, { "tree", "plant", "Green" }, { "flower", "plant", "Green" },
	{ "garden", "plant", "Green" }, { "hedge", "plant", "Green" }, { "topiary", "plant", "Green" },
	{ "path", "path", "Orange" }, { "floor", "path", "Orange" }, { "rug", "path", "Orange" },
	{ "carpet", "path", "Orange" }, { "tile", "path", "Orange" },
	{ "light", "lamp", "Purple" }, { "lamp", "lamp", "Purple" }, { "neon", "lamp", "Purple" },
	{ "statue", "statue", "Gold" }, { "fountain", "statue", "Gold" }, { "art", "statue", "Gold" },
	{ "furniture", "star", "Pink" }, { "seat", "star", "Pink" }, { "bench", "star", "Pink" },
	{ "sofa", "star", "Pink" }, { "rope", "star", "Red" }, { "barrier", "star", "Red" },
	{ "balloon", "sparkles", "Pink" }, { "party", "sparkles", "Pink" },
}
local function decorLook(d): (string, string)
	if type(d) ~= "table" then return "sparkles", "Blue" end
	local key = string.lower(tostring(d.category or "") .. " " .. tostring(d.id or ""))
	local icon, tone = nil, nil
	for _, row in DECOR_LOOKS do
		if string.find(key, row[1], 1, true) then
			icon, tone = row[2], row[3]
			break
		end
	end
	return (type(d.icon) == "string" and d.icon) or icon or "sparkles", (type(d.tone) == "string" and d.tone) or tone or "Blue"
end

-- what a decor piece looks like in the UIs (InventoryUI, the build tray)
function PlacementController.decorInfo(decorId: string)
	local d = decorDef(decorId)
	local icon, tone = decorLook(d)
	return { def = d, name = (d and d.name) or tostring(decorId), icon = icon, tone = tone,
		flat = d ~= nil and d.flat == true }
end

------------------------------------------------------------------
-- ghost defs: { kind ("machine" / "concession" / "decor"), id, name,
-- sizeX, sizeY, sizeZ, radius, flat, color, folder (preview models) }
------------------------------------------------------------------
-- a catalog machine; `item` (a snapshot inventory entry) may carry size + colour
local function machineGhostDef(machineId: string?, item)
	local cat = machineId and Config.getMachineDef(machineId)
	local size = cat and cat.size
	item = type(item) == "table" and item or {}
	local sx = tonumber(item.sizeX) or (size and size.X) or 4
	local sy = tonumber(item.sizeY) or (size and size.Y) or 5
	local sz = tonumber(item.sizeZ) or (size and size.Z) or 3
	local color = (item.r and Color3.new(item.r, item.g or 1, item.b or 1)) or (cat and cat.color) or C.White
	return {
		kind = item.kind or (cat and cat.kind) or "machine", id = machineId,
		name = item.name or (cat and cat.name) or "Machine",
		sizeX = sx, sizeY = sy, sizeZ = sz, radius = math.max(sx, sz) * 0.5, color = color,
		folder = "MachinePreviews",
	}
end

-- an inventory item -> the def a placing ghost needs (the old auto-continue
-- started a session without one and crashed, so build mode always ended)
local function defFromItem(item)
	return machineGhostDef(type(item) == "table" and item.machineId or nil, item)
end
PlacementController.defFromItem = defFromItem

-- flat pieces share a floor only with other layers (1 floors, 2 paths, 3 rugs; DecorRules.layerOf)
local function decorLayer(d): number
	if not (d and d.flat) then return 0 end
	return tonumber(d.layer) or 2
end

local function defFromDecor(decorId: string?)
	local d = decorDef(decorId)
	local size = decorSize(d)
	return {
		kind = "decor", id = decorId, name = (d and d.name) or tostring(decorId),
		sizeX = size.X, sizeY = size.Y, sizeZ = size.Z, radius = math.max(size.X, size.Z) * 0.5,
		flat = d ~= nil and d.flat == true, layer = decorLayer(d),
		color = (d and typeof(d.color) == "Color3" and d.color) or Color3.fromRGB(120, 214, 150),
		folder = "DecorPreviews",
	}
end

-- DECOR's shared placement rules (CasinoCommon/DecorRules: the server's own
-- checks), loaded on first use; nil while it isn't there (own fallback checks)
local decorRules = nil
local function rules()
	if decorRules == nil then
		local mod = Common:FindFirstChild("DecorRules")
		if mod then
			local ok, res = pcall(require, mod)
			decorRules = (ok and type(res) == "table") and res or false
		end
	end
	return decorRules or nil
end

-- how far in front of a machine its guests stand (as Decor.luau's reachOf)
local function machineReach(def): number
	local previews = ReplicatedStorage:FindFirstChild("MachinePreviews")
	local m = previews and def.id and previews:FindFirstChild(def.id)
	local a = m and m:GetAttribute("ApproachDistance")
	return tonumber(a) or (def.sizeZ / 2 + 1.4)
end

------------------------------------------------------------------
-- the snapshot (UILib.state): decor = { inventory = { id = count },
-- placed = { { placedId, decorId, story } } } plus what this session placed
-- that the next snapshot will list (s.pending: decor, s.used: machine items)
------------------------------------------------------------------
local function decorState(state)
	local d = state and state.decor
	return type(d) == "table" and d or nil
end

local function decorInvCount(state, decorId: string): number
	local d = decorState(state)
	local inv = d and d.inventory
	return type(inv) == "table" and (tonumber(inv[decorId]) or 0) or 0
end

local function decorPlacedListed(state, placedId): boolean
	local d = decorState(state)
	local list = d and d.placed
	if type(list) ~= "table" then return false end
	for _, p in list do
		if type(p) == "table" and tostring(p.placedId) == tostring(placedId) then return true end
	end
	return false
end

local function prunePending(s)
	local state = UILib.state
	for i = #s.pending, 1, -1 do
		local p = s.pending[i]
		local done = os.clock() - p.t > 6
		if not done then
			if p.placedId ~= nil then
				done = decorPlacedListed(state, p.placedId)
			else
				done = decorInvCount(state, p.id) < p.invBefore
			end
		end
		if done then table.remove(s.pending, i) end
	end
end

local function pendingCount(s, decorId: string?, story: number?): number
	local n = 0
	for _, p in s.pending do
		if (decorId == nil or p.id == decorId) and (story == nil or p.story == story) then n += 1 end
	end
	return n
end

-- everything you can place right now, in a stable order: machines, stands, decor.
-- Entry: { key, kind, id, name, icon, tone, count, items (machines: inventory items) }
local function collectEntries(s)
	local state = UILib.state
	local used = s and s.used or {}
	local entries, byKey = {}, {}
	local catRank = {}
	for i, d in Config.Catalog do catRank[d.id] = i end
	for _, item in (state.inventory or {}) do
		if type(item) == "table" and type(item.machineId) == "string" and not used[item.id] then
			local key = "m:" .. item.machineId
			local e = byKey[key]
			if not e then
				local cat = Config.getMachineDef(item.machineId)
				local conc = item.kind == "concession" or (cat ~= nil and cat.kind == "concession")
				local itype = item.type or (cat and cat.type)
				e = {
					key = key, kind = conc and "concession" or "machine", id = item.machineId,
					name = item.name or (cat and cat.name) or item.machineId,
					icon = A.TypeIcon[itype] or "slot", tone = A.TypeTone[itype] or "Blue",
					items = {}, count = 0, rank = (conc and 1000 or 0) + (catRank[item.machineId] or 999),
				}
				byKey[key] = e
				table.insert(entries, e)
			end
			table.insert(e.items, item)
			e.count += 1
		end
	end
	local ds = decorState(state)
	if ds and type(ds.inventory) == "table" then
		indexDecor()
		for decorId, n in ds.inventory do
			if type(decorId) == "string" then
				local count = (tonumber(n) or 0) - (s and pendingCount(s, decorId) or 0)
				if count > 0 then
					local d = decorDef(decorId)
					local icon, tone = decorLook(d)
					local e = {
						key = "d:" .. decorId, kind = "decor", id = decorId, name = (d and d.name) or decorId,
						icon = icon, tone = tone, count = count, rank = 2000 + (decorRank[decorId] or 999),
					}
					byKey[e.key] = e
					table.insert(entries, e)
				end
			end
		end
	end
	table.sort(entries, function(a, b)
		if a.rank ~= b.rank then return a.rank < b.rank end
		return a.name < b.name
	end)
	return entries, byKey
end

local function indexOfKey(entries, key): number
	for i, e in entries do
		if e.key == key then return i end
	end
	return 1
end

-- machines placed: the snapshot plus copies placed that it still lists as unplaced
local function machinesPlaced(s): number
	local state = UILib.state
	local n = #(state.placed or {})
	for _, item in (state.inventory or {}) do
		if type(item) == "table" and s.used[item.id] then n += 1 end
	end
	return n
end

local function decorOnStory(s, story: number): number
	local n = 0
	local ds = decorState(UILib.state)
	if ds and type(ds.placed) == "table" then
		for _, p in ds.placed do
			if type(p) == "table" and tonumber(p.story) == story then n += 1 end
		end
	end
	return n + pendingCount(s, nil, story)
end

------------------------------------------------------------------
-- client-side copy of the server's checks (the server has the last word).
-- Machines: the walls, the elevator, other machines (circles: FootprintRadius,
-- Config.MachineGap apart) and solid decor (DecorRules.machineCheck, as
-- Placement.decorCheck does). Decor: DecorRules.check, the very rules
-- Decor.luau runs (flat pieces may lie under machines and solid pieces, and
-- touch flat pieces of their own layer). Without DecorRules a rough copy of
-- those rules runs below (rectangles).
------------------------------------------------------------------
-- distance from a point to a rectangle { pos, yaw (rad), hx, hz } on the floor
local function rectDistance(px: number, pz: number, b): number
	local dx, dz = px - b.pos.X, pz - b.pos.Z
	local c, sn = math.cos(b.yaw), math.sin(b.yaw)
	local lx, lz = dx * c - dz * sn, dx * sn + dz * c -- into the rectangle's frame
	local qx, qz = math.clamp(lx, -b.hx, b.hx), math.clamp(lz, -b.hz, b.hz)
	return math.sqrt((lx - qx) ^ 2 + (lz - qz) ^ 2)
end

-- two rectangles overlap (separating axes); edge to edge is no overlap
local function rectsOverlap(a, b): boolean
	local ca, sa = math.cos(a.yaw), math.sin(a.yaw)
	local cb, sb = math.cos(b.yaw), math.sin(b.yaw)
	local axes = { { ca, -sa }, { sa, ca }, { cb, -sb }, { sb, cb } } -- each one's local X and Z
	local dx, dz = b.pos.X - a.pos.X, b.pos.Z - a.pos.Z
	for _, ax in axes do
		local ra = a.hx * math.abs(ca * ax[1] - sa * ax[2]) + a.hz * math.abs(sa * ax[1] + ca * ax[2])
		local rb = b.hx * math.abs(cb * ax[1] - sb * ax[2]) + b.hz * math.abs(sb * ax[1] + cb * ax[2])
		if math.abs(dx * ax[1] + dz * ax[2]) >= ra + rb - 0.05 then return false end
	end
	return true
end

-- a world yaw (degrees) relative to the plot: (radians, turned a multiple of 90°?)
local function plotRelativeYaw(base: BasePart, deg: number): (number, boolean)
	local _, ry = base.CFrame:ToObjectSpace(CFrame.Angles(0, math.rad(deg), 0)):ToOrientation()
	local q = math.deg(ry) % 90
	return ry, q < 0.5 or q > 89.5
end

-- my machines and decor pieces, refreshed a few times a second. Decor also
-- carries its box in the plot frame (rx, rz, ehx, ehz) for the magnet.
local function gatherBlockers(s)
	local list = {}
	local me = player.UserId
	local base = s.plot.Base
	for _, m in CollectionService:GetTagged(MACHINE_TAG) do
		if m ~= s.moveModel and m:IsA("Model") and m.Parent and m:GetAttribute("OwnerId") == me then
			table.insert(list, { machine = true, pos = m:GetPivot().Position, r = m:GetAttribute("FootprintRadius") or 2.5,
				name = m.Name })
		end
	end
	for _, m in CollectionService:GetTagged(DECOR_TAG) do
		if m ~= s.moveModel and m:IsA("Model") and m.Parent and m:GetAttribute("OwnerId") == me then
			local d = decorDef(m:GetAttribute("DecorId"))
			local size = decorSize(d)
			local flat = m:GetAttribute("Flat")
			if flat == nil then flat = d ~= nil and d.flat == true end
			local cf = m:GetPivot()
			local _, yaw = cf:ToOrientation()
			local rel = base.CFrame:PointToObjectSpace(cf.Position)
			local ry, aligned = plotRelativeYaw(base, math.deg(yaw))
			local ehx, ehz = size.X / 2, size.Z / 2
			if math.abs(math.sin(ry)) > 0.5 then ehx, ehz = ehz, ehx end
			table.insert(list, { machine = false, pos = cf.Position, yaw = yaw, hx = size.X / 2, hz = size.Z / 2,
				flat = flat == true, layer = flat and (d and decorLayer(d) or 2) or 0, name = (d and d.name) or m.Name,
				rx = rel.X, rz = rel.Z, ehx = ehx, ehz = ehz, aligned = aligned })
		end
	end
	s.blockers = list
	s.blockersAt = os.clock()
end

local function blockersFresh(s)
	if not s.blockers or os.clock() - (s.blockersAt or 0) > 0.3 then gatherBlockers(s) end
	return s.blockers
end

local function checkSpot(s, pos: Vector3): (boolean, string?)
	local def = s.def
	local base = s.plot.Base
	local isDecor = def.kind == "decor"
	-- room left: one more machine in the casino / decor piece on this floor
	if isDecor then
		local cap = tonumber(Config.DecorPerStory)
		local adding = s.state == "place" or s.story ~= s.moveFromStory
		if cap and adding and decorOnStory(s, s.story) >= cap then
			return false, ("THIS FLOOR HAS ALL THE DECOR IT CAN TAKE (%d)"):format(cap)
		end
	elseif s.state == "place" then
		local cap = tonumber(UILib.state.maxMachines)
		if cap and machinesPlaced(s) >= cap then return false, "CASINO FULL - BUILD ANOTHER FLOOR" end
	end
	local R = rules()
	local yawRad = math.rad(s.rotationY)
	local cfg = isDecor and decorDef(def.id) or nil
	if R and cfg and cfg.size and type(R.check) == "function" then
		local ok, why = R.check(base, player.UserId, cfg, CFrame.new(pos) * CFrame.Angles(0, yawRad, 0), s.moveModel)
		if ok then return true, nil end
		return false, string.upper(tostring(why or "Can't place it here."))
	end
	local relCF = base.CFrame:ToObjectSpace(CFrame.new(pos) * CFrame.Angles(0, yawRad, 0))
	local rel = relCF.Position
	local half = base.Size / 2
	if math.abs(rel.X) > half.X or math.abs(rel.Z) > half.Z then return false, "OUTSIDE YOUR CASINO" end
	-- the whole footprint, turned the way it'll stand, stays clear of the walls
	local _, yaw = relCF:ToOrientation()
	local c, sn = math.abs(math.cos(yaw)), math.abs(math.sin(yaw))
	local hx = (c * def.sizeX + sn * def.sizeZ) / 2
	local hz = (sn * def.sizeX + c * def.sizeZ) / 2
	if math.abs(rel.X) + hx > half.X - CLEAR or math.abs(rel.Z) + hz > half.Z - CLEAR then
		return false, "TOO CLOSE TO THE WALL"
	end
	-- elevator booth + landing (Buildings.blocksElevator)
	local eh = E.size / 2
	local cx = math.clamp(rel.X, E.x - eh - 1.6, E.x + eh + 1.6)
	local cz = math.clamp(rel.Z, E.z - eh - 5, E.z + eh)
	if Vector2.new(rel.X - cx, rel.Z - cz).Magnitude < def.radius then return false, "KEEP THE ELEVATOR CLEAR" end
	-- neighbours on this floor
	local me = { pos = pos, yaw = yawRad, hx = def.sizeX / 2, hz = def.sizeZ / 2 }
	for _, b in blockersFresh(s) do
		if math.abs(b.pos.Y - pos.Y) < H / 2 then
			local clash
			if b.machine then
				if isDecor then
					clash = not def.flat and rectDistance(b.pos.X, b.pos.Z, me) < b.r + GAP
				else
					clash = Vector2.new(b.pos.X - pos.X, b.pos.Z - pos.Z).Magnitude < b.r + def.radius + GAP
				end
			elseif isDecor then
				clash = (def.flat == b.flat) and (not def.flat or def.layer == b.layer) and rectsOverlap(me, b)
			else
				clash = not R and not b.flat and rectDistance(pos.X, pos.Z, b) < def.radius
			end
			if clash then return false, "TOO CLOSE TO " .. string.upper(b.name) end
		end
	end
	-- a machine against solid decor (and the lane its guests walk), as the server does
	if not isDecor and R and type(R.machineCheck) == "function" then
		local ok, why = R.machineCheck(base, player.UserId, pos, s.rotationY, def.radius, machineReach(def), s.moveModel)
		if not ok then return false, string.upper(tostring(why or "Your decor is in the way.")) end
	end
	return true, nil
end

-- the grid, in the plot's own frame so rows line up with the walls
local function snapXZ(s, x: number, z: number): (number, number)
	if s.grid <= 0 then return x, z end
	local base = s.plot.Base
	local g = s.grid
	local rel = base.CFrame:PointToObjectSpace(Vector3.new(x, base.Position.Y, z))
	local w = base.CFrame:PointToWorldSpace(Vector3.new(math.round(rel.X / g) * g, rel.Y, math.round(rel.Z / g) * g))
	return w.X, w.Z
end

-- flat decor clicks onto a flat piece of its own layer on this floor: edge to
-- edge, lined up with its centre or one of its edges, when that's within MAGNET
-- studs (rows of tiles and paths join up without a gap). Grid on, square turns.
local MAGNET = 1.6
local function magnet(s, x: number, z: number): (number, number)
	local def = s.def
	if not (def and def.flat) or s.grid <= 0 then return x, z end
	local base = s.plot.Base
	local ry, aligned = plotRelativeYaw(base, s.rotationY)
	if not aligned then return x, z end
	local ghx, ghz = def.sizeX / 2, def.sizeZ / 2
	if math.abs(math.sin(ry)) > 0.5 then ghx, ghz = ghz, ghx end
	local rel = base.CFrame:PointToObjectSpace(Vector3.new(x, base.Position.Y, z))
	local y = storyY(s.plot, s.story)
	-- the nearest of: centres lined up, low edges lined up, high edges lined up
	local function align(c: number, bc: number, bh: number, gh: number): number
		local best, bd = c, MAGNET
		for _, v in { bc, bc - bh + gh, bc + bh - gh } do
			local d = math.abs(v - c)
			if d < bd then best, bd = v, d end
		end
		return best
	end
	local bx, bz, bestD = nil, nil, MAGNET
	for _, b in blockersFresh(s) do
		if b.flat and b.aligned and b.layer == def.layer and math.abs(b.pos.Y - y) < H / 2 then
			for _, side in { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } do
				local cx, cz
				if side[1] ~= 0 then
					cx, cz = b.rx + side[1] * (b.ehx + ghx), align(rel.Z, b.rz, b.ehz, ghz)
				else
					cx, cz = align(rel.X, b.rx, b.ehx, ghx), b.rz + side[2] * (b.ehz + ghz)
				end
				local d = math.sqrt((cx - rel.X) ^ 2 + (cz - rel.Z) ^ 2)
				if d < bestD then bx, bz, bestD = cx, cz, d end
			end
		end
	end
	if not bx then return x, z end
	local w = base.CFrame:PointToWorldSpace(Vector3.new(bx, rel.Y, bz))
	return w.X, w.Z
end

------------------------------------------------------------------
-- the ghost + its footprint
------------------------------------------------------------------
local function buildGhost(def)
	local folder = ReplicatedStorage:FindFirstChild(def.folder)
	local template = folder and def.id and folder:FindFirstChild(def.id)
	local ghost
	if template and template:IsA("Model") then
		ghost = template:Clone()
		for _, d in ghost:GetDescendants() do
			if d:IsA("BasePart") then
				d.Anchored = true; d.CanCollide = false; d.CanQuery = false; d.CanTouch = false; d.CastShadow = false
				d.Transparency = math.max(d.Transparency, 0.3)
			elseif d:IsA("Light") or d:IsA("Sound") or d:IsA("ProximityPrompt") or d:IsA("LuaSourceContainer")
				or d:IsA("ParticleEmitter") then
				d:Destroy()
			end
		end
	else
		-- no preview published (yet): a glowing box of the footprint
		ghost = Instance.new("Model")
		local h = def.flat and 0.2 or def.sizeY
		local body = Instance.new("Part")
		body.Anchored = true; body.CanCollide = false; body.CanQuery = false; body.CanTouch = false; body.CastShadow = false
		body.Size = Vector3.new(def.sizeX, h, def.sizeZ)
		body.Color = def.color
		body.Material = Enum.Material.ForceField
		body.CFrame = CFrame.new(0, h / 2, 0)
		body.Parent = ghost
		ghost.WorldPivot = CFrame.new()
	end
	ghost.Name = "PlacementGhost"
	local hl = Instance.new("Highlight")
	hl.FillTransparency = 0.72
	hl.OutlineTransparency = 0.1
	hl.DepthMode = Enum.HighlightDepthMode.Occluded
	hl.Parent = ghost
	return ghost, hl
end

-- machines (and standing decor): a neon ring of the footprint radius;
-- flat decor: an outline of its rectangle
local function buildFootprint(def): (BasePart, SelectionBox?)
	local p = Instance.new("Part")
	p.Name = "PlacementFootprint"
	p.Anchored = true; p.CanCollide = false; p.CanQuery = false; p.CanTouch = false; p.CastShadow = false
	if def.flat then
		p.Transparency = 1
		p.Size = Vector3.new(def.sizeX, 0.1, def.sizeZ)
		local box = Instance.new("SelectionBox")
		box.LineThickness = 0.07
		box.SurfaceTransparency = 0.82
		box.Adornee = p
		box.Parent = p
		return p, box
	end
	p.Shape = Enum.PartType.Cylinder
	p.Material = Enum.Material.Neon
	p.Transparency = 0.55
	p.Size = Vector3.new(0.08, def.radius * 2, def.radius * 2)
	return p, nil
end

local function clearGhost(s)
	if s.ghost then s.ghost:Destroy() end
	if s.footprint then s.footprint:Destroy() end
	s.ghost, s.highlight, s.footprint, s.outline = nil, nil, nil, nil
	s.ghostShown, s.painted = false, nil
end

local function setDef(s, def)
	local same = s.ghost and s.def and s.def.kind == def.kind and s.def.id == def.id
	s.def = def
	s.blockers = nil
	if same then return end -- the next copy of the same item: keep the ghost
	clearGhost(s)
	s.ghost, s.highlight = buildGhost(def)
	s.footprint, s.outline = buildFootprint(def)
end

local function showGhost(s, on: boolean)
	if not s.ghost or s.ghostShown == on then return end
	s.ghostShown = on
	s.ghost.Parent = on and Workspace or nil
	s.footprint.Parent = on and Workspace or nil
end

local function paintGhost(s, ok: boolean)
	if s.painted == ok or not s.ghost then return end
	s.painted = ok
	local color = ok and C.Green or C.Crimson
	s.highlight.FillColor = color
	s.highlight.OutlineColor = ok and C.GreenTop or C.CrimsonTop
	if s.outline then
		s.outline.Color3 = ok and C.GreenTop or C.CrimsonTop
		s.outline.SurfaceColor3 = color
	else
		s.footprint.Color = color
	end
end

local function placeFootprint(s, cf: CFrame)
	if s.outline then
		s.footprint.CFrame = cf * CFrame.new(0, 0.06, 0)
	else
		s.footprint.CFrame = CFrame.new(cf.Position + Vector3.new(0, 0.06, 0)) * CFrame.Angles(0, 0, math.rad(90))
	end
end

-- the piece being moved hides locally (so it isn't in its own way)
local function hideModel(s, model: Instance)
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") or d:IsA("Decal") or d:IsA("Texture") then
			s.saved[d] = d.LocalTransparencyModifier
			d.LocalTransparencyModifier = 1
		elseif d:IsA("BillboardGui") or d:IsA("SurfaceGui") or d:IsA("Light") or d:IsA("ParticleEmitter") then
			s.saved[d] = d.Enabled
			d.Enabled = false
		end
	end
end

local function restoreSaved(saved)
	for inst, v in saved do
		pcall(function()
			if inst:IsA("BasePart") or inst:IsA("Decal") or inst:IsA("Texture") then
				inst.LocalTransparencyModifier = v
			else
				inst.Enabled = v
			end
		end)
	end
end

local function cancelMove(s)
	if not s.moveModel then return end
	restoreSaved(s.saved)
	s.saved = {}
	s.moveModel, s.moveIsDecor, s.moveFromStory = nil, nil, nil
end

-- the gold outline on the piece under the cursor in move mode. (Disabled when
-- there is none: a Highlight without an Adornee would light up its parent.)
local function setHover(s, m: Instance?)
	local hl = s.hover
	if not hl then return end
	if hl.Adornee ~= m then hl.Adornee = m end
	if hl.Enabled ~= (m ~= nil) then hl.Enabled = m ~= nil end
end

------------------------------------------------------------------
-- screen -> world
------------------------------------------------------------------
-- viewport points (mouse location) vs screen points (input positions: below the top-bar inset)
local function rayAt(point: Vector2, screenSpace: boolean): Ray
	local cam = Workspace.CurrentCamera
	if screenSpace then return cam:ScreenPointToRay(point.X, point.Y) end
	return cam:ViewportPointToRay(point.X, point.Y)
end

local function cursorRay(s): Ray
	if TOUCH then
		if s.touchPoint then return rayAt(s.touchPoint, true) end
		local vp = Workspace.CurrentCamera.ViewportSize
		return rayAt(Vector2.new(vp.X / 2, vp.Y * 0.42), false) -- no tap yet: the middle of the view
	end
	return rayAt(UserInputService:GetMouseLocation(), false)
end

-- the mouse is over the build bar: the ghost stays where it was
local function overBar(s): boolean
	if TOUCH or not s.ui then return false end
	local m = UserInputService:GetMouseLocation() - GuiService:GetGuiInset()
	for _, f in { s.ui.tray, s.ui.row, s.ui.pill } do
		local p, sz = f.AbsolutePosition, f.AbsoluteSize
		if m.X >= p.X and m.X <= p.X + sz.X and m.Y >= p.Y and m.Y <= p.Y + sz.Y then return true end
	end
	return false
end

-- one of my machines / decor pieces on the build floor under a screen point
local function pieceAt(s, point: Vector2, screenSpace: boolean): Instance?
	local ray = rayAt(point, screenSpace)
	local me = player.UserId
	local cands = {}
	for _, tag in { MACHINE_TAG, DECOR_TAG } do
		for _, m in CollectionService:GetTagged(tag) do
			if m:IsA("Model") and m.Parent and m:GetAttribute("OwnerId") == me and storyOfModel(s.plot, m) == s.story then
				table.insert(cands, m)
			end
		end
	end
	if #cands == 0 then return nil end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = cands
	local hit = Workspace:Raycast(ray.Origin, ray.Direction.Unit * 800, params)
	if hit then
		local inst = hit.Instance
		while inst and inst ~= Workspace do
			if table.find(cands, inst) then return inst end
			inst = inst.Parent
		end
	end
	-- nothing solid under the cursor (flat decor may not take rays): the footprint
	-- around the point on the floor
	if math.abs(ray.Direction.Y) < 1e-4 then return nil end
	local t = (storyY(s.plot, s.story) - ray.Origin.Y) / ray.Direction.Y
	if t <= 0 then return nil end
	local p = ray.Origin + ray.Direction * t
	local best, bestD = nil, math.huge
	for _, m in cands do
		local pos = m:GetPivot().Position
		local r = m:GetAttribute("FootprintRadius")
		if not r then
			local size = decorSize(decorDef(m:GetAttribute("DecorId")))
			r = math.max(size.X, size.Z) * 0.5
		end
		local dist = Vector2.new(pos.X - p.X, pos.Z - p.Z).Magnitude
		if dist <= r and dist < bestD then best, bestD = m, dist end
	end
	return best
end

------------------------------------------------------------------
-- the build bar
------------------------------------------------------------------
local closeSession, refreshUI, renderTray, enterSelect, selectEntry, confirm, storeMoved, setFloor

local BAR_H = 228 -- status 36 + 8 + actions 64 + 8 + tray 112

-- a little keycap on a button's corner (desktop only)
local function keycap(parent: Instance, text: string, centred: boolean?)
	if TOUCH then return end
	local k = UILib.make("Frame", {
		Name = "Key", BackgroundColor3 = C.Ink, AnchorPoint = Vector2.new(centred and 0.5 or 1, 0),
		Position = centred and UDim2.new(0.5, 0, 0, -11) or UDim2.new(1, 8, 0, -9),
		Size = UDim2.fromOffset(0, 20), AutomaticSize = Enum.AutomaticSize.X, ZIndex = 8, Parent = parent,
	})
	UILib.corner(k, 7)
	UILib.stroke(k, C.GoldDeep, 2, true)
	UILib.pad(k, 6, 0, 6, 0)
	UILib.body(k, {
		text = text, font = F.Number, size = 13, color = C.GoldTop, autoX = true, z = 8,
		frameSize = UDim2.fromScale(0, 1), xAlign = Enum.TextXAlignment.Center,
	})
end

local function actionButton(s, parent: Instance, o)
	local h = UILib.button({
		parent = parent, name = o.name, tone = o.tone, text = o.text, icon = o.icon,
		textSize = o.textSize or (TOUCH and 20 or 22), iconSize = 30,
		size = UDim2.fromOffset(o.w, 60), order = o.order,
		onClick = function()
			if session == s then o.onClick() end
		end,
	})
	if o.key then keycap(h.Instance, o.key, o.centredKey) end
	return h
end

local TILE = 84
local function makeTile(s, e)
	local tone = UILib.Tones[e.tone] or UILib.Tones.Blue
	local root = UILib.make("Frame", {
		Name = "Tile", BackgroundTransparency = 1, Size = UDim2.fromOffset(TILE, TILE), Parent = s.ui.scroll,
	})
	local scale = UILib.make("UIScale", { Parent = root })
	local body = UILib.make("Frame", {
		Name = "Body", BackgroundColor3 = tone.shadow, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), Parent = root,
	})
	UILib.corner(body, 18)
	local ring = UILib.stroke(body, C.Ink, 3, true)
	local face = UILib.make("Frame", {
		Name = "Face", BackgroundColor3 = C.White, BorderSizePixel = 0, Size = UDim2.new(1, 0, 1, -5), Parent = body,
	})
	UILib.corner(face, 17)
	UILib.gradient(face, tone.top, tone.base)
	UILib.make("Frame", {
		Name = "Shine", BackgroundColor3 = C.White, BackgroundTransparency = 0.7, BorderSizePixel = 0,
		Position = UDim2.fromOffset(6, 4), Size = UDim2.new(1, -12, 0, 22), Parent = face,
	}, { UILib.make("UICorner", { CornerRadius = UDim.new(0, 10) }) })
	UILib.image(face, UILib.Tex.glow, {
		size = UDim2.fromScale(1.1, 1.1), anchor = Vector2.new(0.5, 0.5), position = UDim2.fromScale(0.5, 0.4),
		transparency = 0.55,
	})
	local tileIcon = UILib.image(face, e.icon, {
		size = UDim2.fromOffset(56, 56), anchor = Vector2.new(0.5, 0.5), position = UDim2.new(0.5, 0, 0, 29),
	})
	-- the real model (ModelIcons) standing on the name band, the icon as its fallback
	if e.kind == "decor" or e.kind == "machine" or e.kind == "concession" then
		UILib.modelIcon(face, e.kind == "decor" and "decor" or "machine", e.id, {
			name = "Model", position = UDim2.fromOffset(4, 2), size = UDim2.new(1, -8, 1, -27), z = 3,
			fallback = tileIcon, hover = root, shadow = true, align = "bottom", bottom = 0.06, margin = 0.05,
		})
	end
	local band = UILib.make("Frame", {
		Name = "NameBand", BackgroundColor3 = C.Ink, BackgroundTransparency = 0.35, BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, 25), Parent = face,
	})
	UILib.corner(band, 12)
	local nameFace, nameHolder = UILib.text(band, {
		text = string.upper(e.name), size = 12, wrap = true, stroke = 1.5, shadow = 1,
		frameSize = UDim2.new(1, -6, 1, -2), position = UDim2.fromOffset(3, 1),
	})
	for _, l in { nameFace, nameHolder:FindFirstChild("Shadow") } do
		if l then
			l.TextScaled = true
			UILib.make("UITextSizeConstraint", { MaxTextSize = 12, MinTextSize = 7, Parent = l })
		end
	end
	-- count chip
	local chip = UILib.make("Frame", {
		Name = "Count", BackgroundColor3 = C.White, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -3, 0, 3),
		Size = UDim2.fromOffset(0, 22), AutomaticSize = Enum.AutomaticSize.X, ZIndex = 3, Parent = root,
	})
	UILib.corner(chip, 999)
	UILib.gradient(chip, C.GoldTop, C.GoldDeep)
	UILib.stroke(chip, C.Ink, 2.5, true)
	UILib.pad(chip, 7, 0, 7, 0)
	local count = UILib.text(chip, {
		text = "x" .. e.count, font = F.Number, size = 15, autoX = true, frameSize = UDim2.fromScale(0, 1),
		stroke = 2, shadow = 1, z = 3,
	})
	local click = UILib.make("TextButton", {
		Name = "Click", Text = "", BackgroundTransparency = 1, AutoButtonColor = false,
		Size = UDim2.fromScale(1, 1), ZIndex = 5, Parent = root,
	}) :: TextButton
	UILib.pressJuice(click, scale, face)
	local key = e.key
	click.Activated:Connect(function()
		if session ~= s or s.busy then return end
		local _, byKey = collectEntries(s)
		local fresh = byKey[key]
		if fresh and not (s.state == "place" and s.entryKey == key) then
			selectEntry(s, fresh)
			UILib.fx("sound", "pop", 1.1)
		end
	end)
	local api = { Instance = root }
	function api.setCount(n: number) count.Text = "x" .. n end
	function api.setSelected(on: boolean)
		ring.Color = on and C.GoldTop or C.Ink
		ring.Thickness = on and 5 or 3
	end
	return api
end

-- the status pill: what's in hand + whether it can go here
local function setStatus(s, ok: boolean?, text: string?, gold: boolean?)
	local ui = s.ui
	if not ui then return end
	local name = s.state == "select" and "MOVE MODE" or string.upper(s.def and s.def.name or "")
	local msg = text or (ok and (s.state == "move" and "READY TO MOVE" or "READY TO PLACE") or "CAN'T PLACE HERE")
	local color = gold and C.GoldTop or (ok and C.GreenTop or C.CrimsonTop)
	if ui.nameShown ~= name then
		ui.nameShown = name
		ui.name.Text = name
	end
	if ui.msgShown ~= msg then
		ui.msgShown = msg
		ui.msg.Text = msg
	end
	if ui.msg.TextColor3 ~= color then ui.msg.TextColor3 = color end
end

renderTray = function(s, entries)
	local ui = s.ui
	if not ui then return end
	entries = entries or collectEntries(s)
	local seen = {}
	for i, e in entries do
		seen[e.key] = true
		local tile = ui.tiles[e.key]
		if not tile then
			tile = makeTile(s, e)
			ui.tiles[e.key] = tile
		end
		tile.Instance.LayoutOrder = i
		tile.setCount(e.count)
		tile.setSelected(s.state == "place" and s.entryKey == e.key)
	end
	for key, tile in ui.tiles do
		if not seen[key] then
			tile.Instance:Destroy()
			ui.tiles[key] = nil
		end
	end
	ui.empty.Visible = #entries == 0
end

refreshUI = function(s)
	local ui = s.ui
	if not ui then return end
	local st = s.state
	local stories = storiesOf(s.plot)
	ui.primary.Instance.Visible = st ~= "select"
	ui.primary.setText(st == "move" and "MOVE HERE" or "PLACE")
	ui.primary.setIcon(st == "place" and "build" or nil)
	ui.rotate.Instance.Visible = st ~= "select"
	ui.grid.Instance.Visible = st ~= "select" and not TOUCH
	ui.grid.setText(s.grid > 0 and "GRID ON" or "GRID OFF")
	ui.grid.setTone(s.grid > 0 and "Orange" or "Blue")
	ui.move.Instance.Visible = st == "place"
	ui.store.Instance.Visible = st == "move"
	ui.done.setText(s.didSomething and "DONE" or "CANCEL")
	ui.floorBox.Visible = stories > 1
	local vip = (s.story or 1) == vipStoryOf(s.plot) -- the VIP floor: a gold plate, purple "VIP"
	ui.floorText.Text = vip and "VIP" or ((s.story or 1) == 1 and "GROUND" or ("FLOOR " .. s.story))
	ui.floorText.TextColor3 = vip and C.PurpleShadow or C.Crimson
	if ui.floorGrad then
		ui.floorGrad.Color = vip and ColorSequence.new(C.GoldTop, C.Gold) or ColorSequence.new(C.Cream, C.CreamRow)
	end
	ui.up.setEnabled((s.story or 1) < stories)
	ui.down.setEnabled((s.story or 1) > 1)
	for key, tile in ui.tiles do tile.setSelected(st == "place" and key == s.entryKey) end
	if st == "select" then
		setStatus(s, nil, TOUCH and "TAP A MACHINE OR DECOR TO MOVE IT" or "CLICK A MACHINE OR DECOR TO MOVE IT", true)
	end
end

local function buildUI(s)
	local screen = UILib.getScreen()
	for _, n in { "PlaceBar", "MoveSelectBanner" } do
		local old = screen:FindFirstChild(n)
		if old then old:Destroy() end
	end
	local maxW = TOUCH and 720 or 960
	local holder = UILib.make("Frame", {
		Name = "PlaceBar", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -8), Size = UDim2.fromOffset(maxW, BAR_H), Parent = screen,
	})
	local sc = UILib.autoScale(holder)
	-- as wide as the screen allows (narrow phones), never wider than maxW
	local function fit()
		local cam = Workspace.CurrentCamera
		local vp = cam and cam.ViewportSize or Vector2.new(1280, 720)
		local w = math.floor(math.min(maxW, vp.X / math.max(sc.Scale, 0.05) - 24))
		holder.Size = UDim2.fromOffset(math.max(360, w), BAR_H)
	end
	fit()
	table.insert(s.conns, sc:GetPropertyChangedSignal("Scale"):Connect(fit))
	if Workspace.CurrentCamera then
		table.insert(s.conns, Workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(fit))
	end
	local ui = { holder = holder, tiles = {} }
	s.ui = ui

	-- status pill: the piece in hand + READY / why not
	local pill = UILib.make("Frame", {
		Name = "Status", BackgroundColor3 = C.Ink, BackgroundTransparency = 0.12, AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0), Size = UDim2.fromOffset(0, 36), AutomaticSize = Enum.AutomaticSize.X,
		Parent = holder,
	})
	UILib.corner(pill, 999)
	UILib.stroke(pill, C.GoldDeep, 3, true)
	UILib.pad(pill, 18, 0, 18, 0)
	UILib.list(pill, "x", 12, nil, Enum.VerticalAlignment.Center)
	ui.pill = pill
	local ts = TOUCH and 18 or 20
	ui.name = UILib.text(pill, {
		text = "", size = ts, autoX = true, frameSize = UDim2.fromScale(0, 1), order = 1,
		gradient = { C.White, C.GoldTop }, stroke = 2.5, shadow = 2,
	})
	ui.msg = UILib.text(pill, {
		text = "", size = ts, autoX = true, frameSize = UDim2.fromScale(0, 1), order = 2, color = C.GreenTop,
		stroke = 2.5, shadow = 2,
	})

	-- actions
	local row = UILib.make("Frame", {
		Name = "Actions", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 44), Size = UDim2.fromOffset(0, 64), AutomaticSize = Enum.AutomaticSize.X,
		Parent = holder,
	})
	UILib.list(row, "x", 8, nil, Enum.VerticalAlignment.Center)
	ui.row = row
	ui.primary = actionButton(s, row, { name = "Primary", tone = "Green", text = "PLACE", icon = "build",
		w = TOUCH and 128 or 150, order = 1, key = "CLICK", onClick = function() confirm(s) end })
	ui.rotate = actionButton(s, row, { name = "Rotate", tone = "Blue", text = "ROTATE", w = TOUCH and 112 or 132,
		order = 2, key = "R", onClick = function()
			s.rotationY = (s.rotationY + 45) % 360
			UILib.fx("sound", "tick")
		end })
	-- floor picker: UP / the floor you build on / DOWN (only with more than one story)
	local floorBox = UILib.make("Frame", {
		Name = "Floor", BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 60), AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = 3, Parent = row,
	})
	UILib.list(floorBox, "x", 4, nil, Enum.VerticalAlignment.Center)
	ui.floorBox = floorBox
	ui.up = actionButton(s, floorBox, { name = "Up", tone = "Purple", text = "UP", textSize = 18, w = TOUCH and 56 or 60, order = 1,
		key = "PG UP", centredKey = true, onClick = function() setFloor(s, s.story + 1) end })
	local plate = UILib.make("Frame", {
		Name = "Plate", BackgroundColor3 = C.White, Size = UDim2.fromOffset(TOUCH and 96 or 104, 56), LayoutOrder = 2, Parent = floorBox,
	})
	UILib.corner(plate, 14)
	ui.floorGrad = UILib.gradient(plate, C.Cream, C.CreamRow) -- (gold on the VIP floor: refreshUI)
	UILib.stroke(plate, C.Ink, 3, true)
	UILib.body(plate, {
		text = "BUILD FLOOR", font = F.Display, size = 11, color = C.Brown, transparency = 0.15,
		frameSize = UDim2.new(1, 0, 0, 14), position = UDim2.fromOffset(0, 6), xAlign = Enum.TextXAlignment.Center,
	})
	ui.floorText = UILib.body(plate, {
		text = "GROUND", font = F.Display, size = 21, color = C.Crimson,
		frameSize = UDim2.new(1, -8, 0, 26), position = UDim2.fromOffset(4, 22), xAlign = Enum.TextXAlignment.Center,
	})
	ui.down = actionButton(s, floorBox, { name = "Down", tone = "Purple", text = "DOWN", textSize = 18, w = TOUCH and 70 or 74,
		order = 3, key = "PG DN", centredKey = true, onClick = function() setFloor(s, s.story - 1) end })
	ui.grid = actionButton(s, row, { name = "Grid", tone = "Orange", text = "GRID ON", w = 132, order = 4, key = "G",
		onClick = function()
			s.grid = s.grid > 0 and 0 or (Config.GridSnap or 1)
			UILib.fx("sound", "tick")
			UILib.toast(s.grid > 0 and "GRID SNAP ON" or "FREE PLACEMENT", "info")
			refreshUI(s)
		end })
	ui.move = actionButton(s, row, { name = "Move", tone = "Pink", text = "MOVE", w = TOUCH and 96 or 112, order = 5,
		key = "M", onClick = function()
			if not s.busy then enterSelect(s) end
		end })
	ui.store = actionButton(s, row, { name = "Store", tone = "Orange", text = "STORE", icon = (not TOUCH) and "items" or nil,
		w = TOUCH and 100 or 134, order = 6, onClick = function() storeMoved(s) end })
	ui.done = actionButton(s, row, { name = "Done", tone = "Red", text = "CANCEL", w = TOUCH and 108 or 128, order = 7,
		key = "ESC", onClick = function() closeSession() end })

	-- the tray: everything in your inventory (velvet frame, cream strip, tiles)
	local tray = UILib.make("Frame", {
		Name = "Tray", BackgroundColor3 = C.White, AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.fromScale(0.5, 1),
		Size = UDim2.new(1, 0, 0, 112), Parent = holder,
	})
	UILib.corner(tray, 26)
	UILib.gradient(tray, C.CrimsonTop, C.CrimsonDeep)
	UILib.stroke(tray, C.Ink, 4, true)
	ui.tray = tray
	local inner = UILib.make("Frame", {
		Name = "Inner", BackgroundColor3 = C.White, Position = UDim2.fromOffset(8, 8), Size = UDim2.new(1, -16, 1, -16),
		Parent = tray,
	})
	UILib.corner(inner, 19)
	UILib.gradient(inner, C.Cream, C.CreamRow)
	UILib.stroke(inner, C.Gold, 3, true)
	local scroll = UILib.make("ScrollingFrame", {
		Name = "Items", BackgroundTransparency = 1, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1),
		CanvasSize = UDim2.fromScale(0, 1), AutomaticCanvasSize = Enum.AutomaticSize.X,
		ScrollingDirection = Enum.ScrollingDirection.X,
		ScrollBarThickness = 5, ScrollBarImageColor3 = C.Crimson, Parent = inner,
	})
	UILib.pad(scroll, 10, 5, 10, 5)
	UILib.list(scroll, "x", 10, nil, Enum.VerticalAlignment.Center)
	ui.scroll = scroll
	ui.empty = UILib.body(inner, {
		text = "NOTHING LEFT TO PLACE  -  BUY MACHINES & DECOR IN THE SHOP", font = F.Display, size = 18,
		color = C.Brown, transparency = 0.2, frameSize = UDim2.new(1, -24, 1, 0), position = UDim2.fromOffset(12, 0),
		xAlign = Enum.TextXAlignment.Center, wrap = true,
	})
	ui.empty.Visible = false

	-- the bar takes the income ticker's spot while it's up
	local ticker = screen:FindFirstChild("HudBottom")
	if ticker then ticker.Visible = false end
end

------------------------------------------------------------------
-- floors, states
------------------------------------------------------------------
setFloor = function(s, story: number, quiet: boolean?)
	story = math.clamp(math.floor(story), 1, storiesOf(s.plot))
	if story == s.story then return end
	s.story = story
	-- the old target was on another floor's plane: never place there
	s.target, s.pos, s.valid, s.why = nil, nil, false, nil
	s.blockers = nil
	BuildingView.setForced(s.plot, story)
	if not quiet then UILib.fx("sound", "tick") end
	refreshUI(s)
end

selectEntry = function(s, e, item)
	cancelMove(s)
	s.state = "place"
	s.chain = false
	s.entryKey = e.key
	setHover(s, nil)
	if e.kind == "decor" then
		s.item = nil
		setDef(s, defFromDecor(e.id))
	else
		s.item = item or e.items[1]
		setDef(s, defFromItem(s.item))
	end
	refreshUI(s)
end

enterSelect = function(s)
	if s.state == "place" then s.lastEntryKey = s.entryKey end
	cancelMove(s)
	clearGhost(s)
	s.state = "select"
	s.def, s.entryKey, s.item, s.chain = nil, nil, nil, false
	s.target, s.pos, s.valid, s.why = nil, nil, false, nil
	refreshUI(s)
end

local function backToPlacing(s)
	local entries, byKey = collectEntries(s)
	local e = (s.lastEntryKey and byKey[s.lastEntryKey]) or entries[1]
	if e then selectEntry(s, e) end
end

-- pick up a placed piece to move it. chain = back to "pick one" afterwards
local function startMove(s, model: Instance, chain: boolean)
	if not (model and model.Parent) then return end
	local isDecor = CollectionService:HasTag(model, DECOR_TAG)
	local def = isDecor and defFromDecor(model:GetAttribute("DecorId")) or machineGhostDef(model:GetAttribute("MachineId"), nil)
	cancelMove(s)
	setHover(s, nil)
	s.state = "move"
	s.chain = chain
	s.entryKey, s.item = nil, nil
	local pivot = (model :: Model):GetPivot()
	local _, ry = pivot:ToOrientation()
	s.rotationY = math.deg(ry) % 360
	s.yaw = s.rotationY
	local from = storyOfModel(s.plot, model)
	setFloor(s, from, true)
	s.moveModel, s.moveIsDecor, s.moveFromStory = model, isDecor, from
	hideModel(s, model)
	setDef(s, def)
	-- the ghost lifts off where the piece stood, then glides to the cursor
	s.target, s.valid = nil, false
	s.pos = Vector3.new(pivot.Position.X, storyY(s.plot, s.story), pivot.Position.Z)
	refreshUI(s)
end

local function pickAt(s, point: Vector2, screenSpace: boolean)
	local m = pieceAt(s, point, screenSpace)
	if m then
		UILib.fx("sound", "pop", 1.1)
		startMove(s, m, true)
	else
		UILib.toast(TOUCH and "Tap one of your machines or decor." or "Click one of your machines or decor.", "error")
	end
end

------------------------------------------------------------------
-- place / move / store
------------------------------------------------------------------
local function invoke(remote: RemoteFunction, ...)
	local ok, res = pcall(remote.InvokeServer, remote, ...)
	if ok and type(res) == "table" then return res end
	if not ok then warn("[PlacementController] " .. tostring(res)) end
	return nil
end

-- after a place: the same item again if you have more, else the next tile
local function continueAfterPlace(s, oldKey: string, oldIndex: number)
	local entries, byKey = collectEntries(s)
	local e = byKey[oldKey] or entries[math.clamp(oldIndex, 1, math.max(1, #entries))]
	if not e then
		closeSession()
		UILib.toast("ALL PLACED!", "unlock", "Buy more machines and decor in the SHOP.")
		return
	end
	selectEntry(s, e)
	renderTray(s, entries)
end

local function finishMove(s, model: Instance, isDecor: boolean, groundCF: CFrame, def, chain: boolean)
	if s.moveModel ~= model then return end -- the player moved on meanwhile
	local saved = s.saved
	s.saved, s.moveModel, s.moveIsDecor, s.moveFromStory = {}, nil, nil, nil
	local function restore() restoreSaved(saved) end
	if isDecor then
		restore()
		UILib.fx("placeDrop", { cf = groundCF, radius = def.radius })
	elseif UILib.fx("placeDrop", { cf = groundCF, machineId = def.id, radius = def.radius, machine = model,
		restore = restore }) ~= true then
		-- the moved machine shows again once its stand-in has dropped in (straight away without UXFX)
		restore()
	end
	if chain then enterSelect(s) else closeSession() end
end

confirm = function(s)
	if session ~= s or s.busy or s.state == "select" then return end
	if not s.target then
		s.nopeAt = os.clock()
		UILib.toast(TOUCH and "Tap the floor where it should go." or "Point at the floor first.", "error")
		return
	end
	if not s.valid then
		s.nopeAt = os.clock()
		UILib.toast(s.why or "Can't place there.", "error")
		return
	end
	local def = s.def
	local pos, rot, story = s.target, s.rotationY, s.story
	local mode, entryKey = s.state, s.entryKey
	local model, isDecor, chain = s.moveModel, s.moveIsDecor == true, s.chain == true
	local oldIndex = indexOfKey(collectEntries(s), entryKey)
	-- the spot as the server builds it (ground CFrame), for the drop-in
	local groundCF = CFrame.new(pos) * CFrame.Angles(0, math.rad(rot), 0)
	s.busy = true
	local res
	if mode == "place" and def.kind == "decor" then
		local invBefore = decorInvCount(UILib.state, def.id)
		res = invoke(Remotes.PlaceDecor(), def.id, pos.X, pos.Z, rot, story)
		if res and res.ok then
			table.insert(s.pending, { id = def.id, story = story, placedId = res.placedId, invBefore = invBefore, t = os.clock() })
			UILib.fx("placeDrop", { cf = groundCF, radius = def.radius })
		end
	elseif mode == "place" then
		local item = s.item
		if not item then
			s.busy = false
			return
		end
		UILib.fx("expectPlacement", pos) -- the new machine stays hidden until it has dropped in
		res = invoke(Remotes.PlaceFromInventory(), item.id, pos.X, pos.Z, rot, story)
		if res and res.ok then
			s.used[item.id] = true
			UILib.fx("placeDrop", { cf = groundCF, machineId = def.id, radius = def.radius })
		else
			UILib.fx("cancelExpected")
		end
	elseif model and model.Parent then
		if isDecor then
			res = invoke(Remotes.MoveDecor(), model:GetAttribute("PlacedId"), pos.X, pos.Z, rot, story)
		else
			res = invoke(Remotes.MoveMachine(), model, pos.X, pos.Z, rot, story)
		end
	end
	if session ~= s then return end
	s.busy = false
	s.checkKey, s.blockers = nil, nil -- the floor changed (or the server said no): look again
	if not (res and res.ok) then
		s.nopeAt = os.clock()
		UILib.toast(res and res.message or "Can't place there.", "error")
		return
	end
	s.didSomething = true
	-- (building a row fast: the drop-ins speak for themselves, no toast pile-up)
	if os.clock() - (s.toastAt or 0) > 2.5 then
		s.toastAt = os.clock()
		UILib.toast(string.upper(res.message or "Placed!"), "placed")
	end
	if mode == "move" then
		finishMove(s, model, isDecor, groundCF, def, chain)
	elseif s.state == "place" and s.entryKey == entryKey then
		continueAfterPlace(s, entryKey, oldIndex)
	else
		renderTray(s)
		refreshUI(s)
	end
end

-- STORE while moving: the piece goes back to your inventory
storeMoved = function(s)
	if s.state ~= "move" or s.busy or not s.moveModel then return end
	local model, chain = s.moveModel, s.chain
	s.busy = true
	local res
	if s.moveIsDecor then
		res = invoke(Remotes.PickupDecor(), model:GetAttribute("PlacedId"))
	else
		res = invoke(Remotes.PickupMachine(), model)
	end
	if session ~= s then return end
	s.busy = false
	s.checkKey, s.blockers = nil, nil
	if not (res and res.ok) then
		UILib.toast(res and res.message or "Couldn't store that.", "error")
		return
	end
	s.didSomething = true
	UILib.toast(string.upper(res.message or "Stored!"), "info")
	if s.moveModel == model then
		s.saved, s.moveModel, s.moveIsDecor, s.moveFromStory = {}, nil, nil, nil -- (it's gone: nothing to show again)
		if chain then enterSelect(s) else closeSession() end
	end
end

------------------------------------------------------------------
-- the camera follows the build floor
------------------------------------------------------------------
local function followCamera(s, dt: number)
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if s.camHum and s.camHum ~= hum then
		if s.camHum.Parent then s.camHum.CameraOffset = Vector3.zero end -- (respawned)
		s.camHum, s.camOffset = nil, nil
	end
	if not hum then return end
	if not s.camHum then
		s.camHum, s.camOffset = hum, hum.CameraOffset
	end
	local want = Vector3.new(0, (s.story - s.playerStory) * H, 0)
	local cur = s.camOffset
	if cur ~= want then
		cur = cur:Lerp(want, 1 - math.exp(-dt * 9))
		if (cur - want).Magnitude < 0.03 then cur = want end
		s.camOffset = cur
	end
	if hum.CameraOffset ~= cur then hum.CameraOffset = cur end
end

local function releaseCamera(s)
	local hum = s.camHum
	s.camHum = nil
	if not (hum and hum.Parent) then return end
	if camTween then camTween:Cancel() end
	camTween = TweenService:Create(hum, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ CameraOffset = Vector3.zero })
	camTween:Play()
end

------------------------------------------------------------------
-- per frame
------------------------------------------------------------------
local function updateHover(s)
	if TOUCH or not s.hover or os.clock() - (s.hoverAt or 0) < 0.08 then return end
	s.hoverAt = os.clock()
	setHover(s, (not overBar(s)) and pieceAt(s, UserInputService:GetMouseLocation(), false) or nil)
end

local function update(dt: number)
	local s = session
	if not s then return end
	local plot = s.plot
	if not (plot.Parent and plot:GetAttribute("OwnerId") == player.UserId and plot:FindFirstChild("Base")) then
		closeSession()
		return
	end
	-- floors bought (or taken away by a rebirth) mid-session (a shell being rebuilt
	-- has no Building for a moment: not a floor count)
	local building = plot:FindFirstChild("Building")
	local stories = building and building:GetAttribute("Stories")
	if type(stories) == "number" and stories ~= s.stories then
		s.stories = stories
		if s.story > stories then setFloor(s, stories, true) end
		refreshUI(s)
	end
	-- the elevator took you to another floor: build there
	local ps = building and playerStory(plot) or s.playerStory
	if ps ~= s.playerStory then
		s.playerStory = ps
		setFloor(s, ps)
	end
	followCamera(s, dt)
	if s.state == "select" then
		updateHover(s)
		return
	end
	if s.state == "move" and not s.busy and not (s.moveModel and s.moveModel.Parent) then
		-- the piece being moved is gone (stored / sold elsewhere)
		s.saved, s.moveModel = {}, nil
		if s.chain then enterSelect(s) else closeSession() end
		return
	end
	if not s.ghost then return end
	-- the cursor on the build floor's plane
	if not overBar(s) then
		local ray = cursorRay(s)
		local y = storyY(plot, s.story)
		if math.abs(ray.Direction.Y) > 1e-4 then
			local t = (y - ray.Origin.Y) / ray.Direction.Y
			if t > 0 then
				local hit = ray.Origin + ray.Direction * t
				local x, z = magnet(s, snapXZ(s, hit.X, hit.Z))
				s.target = Vector3.new(x, y, z)
			end
		end
	end
	if not s.target then
		showGhost(s, false)
		s.valid = false
		setStatus(s, false, TOUCH and "TAP THE FLOOR WHERE IT GOES" or "POINT AT THE FLOOR")
		return
	end
	showGhost(s, true)
	-- glide
	local alpha = 1 - math.exp(-dt * 18)
	s.pos = s.pos and s.pos:Lerp(s.target, alpha) or s.target
	s.yaw += ((((s.rotationY - s.yaw) + 180) % 360) - 180) * alpha
	-- a refused spot: the ghost shakes its head
	local yaw = s.yaw
	if s.nopeAt then
		local k = (os.clock() - s.nopeAt) / 0.35
		if k < 1 then
			yaw += math.sin(k * math.pi * 5) * 10 * (1 - k)
		else
			s.nopeAt = nil
		end
	end
	local cf = CFrame.new(s.pos) * CFrame.Angles(0, math.rad(yaw), 0)
	s.ghost:PivotTo(cf)
	placeFootprint(s, cf)
	-- the same spot is re-checked a few times a second (pieces come and go), a new one at once
	local key = ("%s|%.2f|%.2f|%.1f|%d|%s"):format(tostring(s.def.id), s.target.X, s.target.Z, s.rotationY, s.story,
		s.state)
	if key ~= s.checkKey or os.clock() - (s.checkAt or 0) > 0.25 then
		s.checkKey, s.checkAt = key, os.clock()
		s.valid, s.why = checkSpot(s, s.target)
	end
	local ok, why = s.valid, s.why
	paintGhost(s, ok)
	if s.busy then return end
	if TOUCH and not s.touchPoint then
		setStatus(s, ok, "TAP THE FLOOR WHERE IT GOES", true) -- (the ghost's colour tells this spot apart)
	else
		setStatus(s, ok, why)
	end
end

------------------------------------------------------------------
-- input
------------------------------------------------------------------
local function onInputBegan(s, input: InputObject, gp: boolean)
	if session ~= s then return end
	local k = input.KeyCode
	if k == Enum.KeyCode.Escape or k == Enum.KeyCode.ButtonB then
		-- (that Esc closed a panel on top: leave the session alone)
		if os.clock() - lastPanelClose < 0.2 or UILib.hasOpenPanel() then return end
		closeSession()
		return
	end
	if input.UserInputType == Enum.UserInputType.Touch then
		if not gp then
			s.touchStart = { pos = input.Position, t = os.clock() }
			if s.state ~= "select" then s.touchPoint = Vector2.new(input.Position.X, input.Position.Y) end
		end
		return
	end
	if gp or UILib.hasOpenPanel() then return end
	if k == Enum.KeyCode.R then
		if s.state ~= "select" then
			s.rotationY = (s.rotationY + 45 * (UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) and -1 or 1)) % 360
			UILib.fx("sound", "tick")
		end
	elseif k == Enum.KeyCode.PageUp then
		setFloor(s, s.story + 1)
	elseif k == Enum.KeyCode.PageDown then
		setFloor(s, s.story - 1)
	elseif k == Enum.KeyCode.G then
		if s.state ~= "select" then
			s.grid = s.grid > 0 and 0 or (Config.GridSnap or 1)
			UILib.fx("sound", "tick")
			refreshUI(s)
		end
	elseif k == Enum.KeyCode.M then
		if s.busy then return end
		if s.state == "select" then backToPlacing(s) else enterSelect(s) end
	elseif input.UserInputType == Enum.UserInputType.MouseButton1 then
		if s.state == "select" then
			if not s.busy then pickAt(s, UserInputService:GetMouseLocation(), false) end
		else
			confirm(s)
		end
	end
end

-- touch: a short tap (not a camera drag) picks a piece in move mode
local function onInputEnded(s, input: InputObject, gp: boolean)
	if session ~= s or input.UserInputType ~= Enum.UserInputType.Touch then return end
	local st = s.touchStart
	s.touchStart = nil
	if gp or not st or s.state ~= "select" or s.busy or UILib.hasOpenPanel() then return end
	if os.clock() - st.t < 0.4 and (input.Position - st.pos).Magnitude < 16 then
		pickAt(s, Vector2.new(input.Position.X, input.Position.Y), true)
	end
end

------------------------------------------------------------------
-- session lifecycle
------------------------------------------------------------------
local function onState(s)
	if session ~= s then return end
	prunePending(s)
	local entries, byKey = collectEntries(s)
	if s.state == "place" and not s.busy then
		local e = byKey[s.entryKey]
		if not e then
			-- what was in hand went away (sold, stored, a rebirth...)
			if not entries[1] then
				closeSession()
				UILib.toast("NOTHING LEFT TO PLACE", "info")
				return
			end
			selectEntry(s, entries[1])
		elseif e.kind ~= "decor" then
			local have = false
			for _, it in e.items do
				if s.item and it.id == s.item.id then
					have = true
					break
				end
			end
			if not have then s.item = e.items[1] end
		end
	end
	renderTray(s, entries)
	refreshUI(s)
end

local function hopHome()
	local mod = script.Parent:FindFirstChild("HudUI")
	if not mod then return end
	local HudUI = require(mod)
	if type(HudUI) == "table" and type(HudUI.travelTo) == "function" then HudUI.travelTo("casino") end
end

local function openSession()
	if session then return session end
	if opening then return nil end
	local plot = findOwnPlot()
	if not plot then
		UILib.toast("You don't own a casino yet.", "error")
		return nil
	end
	if farFrom(plot) then
		-- building starts at home: hop there first (the travel bar refuses hops mid-build)
		opening = true
		local ok, err = pcall(hopHome)
		opening = false
		if not ok then warn("[PlacementController] " .. tostring(err)) end
		if session then return session end
		plot = findOwnPlot()
		if not plot then return nil end
		if farFrom(plot) then
			UILib.toast("Head to your casino to build!", "info")
			return nil
		end
	end
	if camTween then
		camTween:Cancel()
		camTween = nil
	end
	local yaw = plotYaw(plot)
	local s = {
		plot = plot, state = "select", grid = Config.GridSnap or 1, rotationY = yaw, yaw = yaw,
		used = {}, pending = {}, saved = {}, conns = {}, didSomething = false,
		stories = storiesOf(plot), playerStory = playerStory(plot),
	}
	session = s
	buildUI(s)
	setFloor(s, s.playerStory, true)
	local hover = Instance.new("Highlight")
	hover.Name = "BuildHover"
	hover.FillColor = C.GoldTop
	hover.FillTransparency = 0.8
	hover.OutlineColor = C.GoldTop
	hover.DepthMode = Enum.HighlightDepthMode.Occluded
	hover.Enabled = false
	hover.Parent = Workspace
	s.hover = hover
	table.insert(s.conns, RunService.RenderStepped:Connect(update))
	table.insert(s.conns, UserInputService.InputBegan:Connect(function(input, gp) onInputBegan(s, input, gp) end))
	table.insert(s.conns, UserInputService.InputEnded:Connect(function(input, gp) onInputEnded(s, input, gp) end))
	table.insert(s.conns, UserInputService.TouchMoved:Connect(function(touch, gp)
		if session == s and not gp and s.state ~= "select" then
			s.touchPoint = Vector2.new(touch.Position.X, touch.Position.Y)
		end
	end))
	s.unsub = UILib.subscribe(function() onState(s) end)
	UILib.fx("sound", "pop", 1.1)
	return s
end

closeSession = function()
	local s = session
	if not s then return end
	session = nil
	BuildingView.setForced(nil)
	for _, c in s.conns do c:Disconnect() end
	if s.unsub then s.unsub() end
	cancelMove(s) -- a piece hidden mid-move shows again
	clearGhost(s)
	if s.hover then s.hover:Destroy() end
	if s.ui and s.ui.holder then s.ui.holder:Destroy() end
	releaseCamera(s)
	local ticker = UILib.getScreen():FindFirstChild("HudBottom")
	if ticker then ticker.Visible = true end
end

------------------------------------------------------------------
-- API
------------------------------------------------------------------
-- place a machine / stand from the inventory (an item of the snapshot's `inventory`);
-- a decor-shaped item ({ kind = "decor", decorId }) goes to beginDecor
function PlacementController.begin(item)
	if type(item) == "table" and item.kind == "decor" then
		local decorId = item.decorId or item.id
		if type(decorId) == "string" then PlacementController.beginDecor(decorId) end
		return
	end
	if type(item) ~= "table" or type(item.machineId) ~= "string" then return end
	local fresh = session == nil
	local s = openSession()
	if not s or s.busy then return end
	local _, byKey = collectEntries(s)
	local e = byKey["m:" .. item.machineId]
	if not e then
		if fresh then closeSession() end
		UILib.toast("That's already placed.", "info")
		return
	end
	selectEntry(s, e, (not s.used[item.id]) and item or nil)
end

-- place a decor piece from the decor inventory
function PlacementController.beginDecor(decorId: string)
	if type(decorId) ~= "string" then return end
	local fresh = session == nil
	local s = openSession()
	if not s or s.busy then return end
	local _, byKey = collectEntries(s)
	local e = byKey["d:" .. decorId]
	if not e then
		if fresh then closeSession() end
		UILib.toast("You don't have that decor yet.", "info")
		return
	end
	selectEntry(s, e)
end

-- move a placed machine (or decor piece) of yours (ManageUI's MOVE)
function PlacementController.beginMove(model: Instance)
	if typeof(model) ~= "Instance" or not model.Parent or model:GetAttribute("OwnerId") ~= player.UserId then return end
	local fresh = session == nil
	local s = openSession()
	if not s or s.busy then return end
	-- started on its own: the session ends after this move; inside a build session: back to picking
	startMove(s, model, not fresh)
end

-- "pick something to move" (the old BUILD tile; ITEMS > MOVE and the bar's MOVE)
function PlacementController.enterSelectMode()
	local s = openSession()
	if s and not s.busy then enterSelect(s) end
end

function PlacementController.cancel()
	closeSession()
end

-- true while build mode is up (the HUD travel bar and the rank-up card wait)
function PlacementController.isBusy(): boolean
	return session ~= nil
end

return PlacementController
