--!nonstrict
-- VipFloor.luau — the VIP pass's free floor: the VIP LOUNGE (Config.VipFloor).
--   * owning the VIP game pass (Config.VipFloor.PassKey, Monetization.owns) adds a
--     free floor ON TOP of the floors you bought: the building has bought + 1
--     stories. The story math lives in Buildings (this module plugs in through
--     Buildings.vip = { owns, moved, dress }): Buildings.bought(player),
--     Buildings.vipStory(player) (= bought + 1, nil without the lounge) and
--     Buildings.stories(player) (= bought + 1 with it; placing, restoring, riding,
--     the machine slots and the cutaway all count it).
--   * buying a floor moves the lounge up a story; a rebirth (floors -> 1) brings it
--     down to story 2. Its machines, decor and the people up there move along
--     (Placement.shiftStory, Decor.shiftStory, the characters / guests here).
--   * no pass (never bought, or a Studio session without it): no lounge, and what
--     was saved up there is above the floors you have, so Placement.restore /
--     Decor.join send it back to your items. A pass bought in-game opens the lounge
--     within Config.VipFloor.CheckSeconds; a pass that goes away mid-session sends
--     its machines + decor back to your items and the people up there downstairs.
--   * machines up there carry the model attribute VipFloor = true (Placement sets it
--     on build / move / shift): Gambling multiplies their positive owner earnings by
--     Config.VipFloor.IncomeMult (x1.25). The floor adds MachinesPerStory slots
--     (Buildings.capacity counts every story). Guests ride up like to any floor.
--   * the look: dress() builds the lounge interior into the VIP story's folder:
--     a gold inlay border + crown medallion on Buildings' black marble slab, purple
--     velvet walls with gold pilasters, rails and crown moulding over a black
--     skirting, a purple neon cove, 4 crystal chandeliers (they light the room),
--     the glowing VIP LOUNGE sign on the back wall, and a red carpet from the
--     elevator between velvet ropes (kept inside the elevator landing, where
--     nothing can be placed). Gold glass + the VIP elevator are Buildings', the
--     outside (VIP sign with chase bulbs, brass trim, gold pier neon) is Facade's.
--   * the first time a player's lounge appears (on join or right after buying the
--     pass): the Player attribute VipFloorWelcome = its story for
--     Config.VipFloor.WelcomeSeconds (VipFloorUI plays the welcome), and
--     profile.VipFloor.welcomed = os.time() so it never plays twice.
-- API: VipFloor.owns(player) -> boolean, VipFloor.story(player) -> number?,
-- VipFloor.mult() -> number, start(deps), join(player), leave(player),
-- snapshot(player, profile) (init.server key "vipFloor"):
--   { enabled, owned, story, mult, slots, machines, passId }

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Config = require(Common:WaitForChild("Config"))
local Materials = require(Common:WaitForChild("Materials"))
local MachineModels = require(script.Parent:WaitForChild("MachineModels"))

local VipFloor = {}
local Data, Plots, Placement, Buildings, Monetization, Decor, pushData
local started = false

local K = MachineModels.Kit
local P = MachineModels.Palette
local H = Config.Building.StoryHeight
local E = Config.Building.Elevator

-- userId -> { owned = boolean, busy = boolean? } (from join to leave)
local state: {[number]: { owned: boolean, busy: boolean? }} = {}

local function cfg()
	return Config.VipFloor or {}
end

local function enabled(): boolean
	return cfg().Enabled ~= false
end

local function passKey(): string
	return cfg().PassKey or "vip"
end

function VipFloor.mult(): number
	return tonumber(cfg().IncomeMult) or 1.25
end

-- "1.25" / "1.5" / "2"
local function multText(): string
	return (("%.2f"):format(VipFloor.mult()):gsub("0+$", ""):gsub("%.$", ""))
end

-- the pass, straight from Monetization's session cache
local function passOwned(player: Player): boolean
	if not (enabled() and Monetization and player) then return false end
	local ok, res = pcall(Monetization.owns, player, passKey())
	return ok and res == true
end

------------------------------------------------------------------
-- public
------------------------------------------------------------------
-- does this player have the VIP floor right now? (from their join on: the state
-- the lounge was built for; before that, the pass itself)
function VipFloor.owns(player: Player?): boolean
	if not player then return false end
	local st = state[player.UserId]
	if st then return st.owned end
	return passOwned(player)
end

-- the VIP floor's story (the floors bought + 1), nil without one
function VipFloor.story(player: Player?): number?
	if not (player and Buildings and Buildings.vipStory) then return nil end
	return Buildings.vipStory(player)
end

-- profile.VipFloor: { welcomed = os.time() of the first welcome, owned = last known }
local function memoryOf(profile)
	if type(profile) ~= "table" then return nil end
	if type(profile.VipFloor) ~= "table" then profile.VipFloor = {} end
	return profile.VipFloor
end

------------------------------------------------------------------
-- moving the lounge's contents + people
------------------------------------------------------------------
local function inPlot(rec, pos: Vector3): boolean
	local rel = rec.base.CFrame:PointToObjectSpace(pos)
	return math.abs(rel.X) <= rec.size.X / 2 + 4 and math.abs(rel.Z) <= rec.size.Z / 2 + 4
end

-- characters and guests standing on story `from` of this plot go to `to` (same
-- spot), or down to the ground floor's elevator when `to` is nil. A guest's own
-- floor bookkeeping catches up at its next elevator ride (the exits line up).
local function movePeople(rec, from: number, to: number?)
	local lift = to and Vector3.new(0, (to - from) * H, 0) or nil
	local function move(model: Model, root: BasePart)
		if not (inPlot(rec, root.Position) and Buildings.storyAt(rec, root.Position.Y) == from) then return end
		root.AssemblyLinearVelocity = Vector3.zero
		if lift then
			model:PivotTo(model:GetPivot() + lift)
		else
			model:PivotTo(Buildings.elevatorExit(rec, 1))
		end
	end
	for _, plr in Players:GetPlayers() do
		local char = plr.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then move(char, root) end
	end
	for _, npc in CollectionService:GetTagged("CasinoPatron") do
		local root = npc:IsA("Model") and npc:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then move(npc, root) end
	end
end

-- Buildings.vip.moved: the lounge goes from story `from` to `to` (a floor bought:
-- up one; a rebirth: down to 2). Runs before the shell is rebuilt, same frame.
local function moved(player: Player, from: number, to: number)
	if from == to then return end
	local rec = Plots.getRecordForOwner(player.UserId)
	if rec then movePeople(rec, from, to) end
	if Placement and type(Placement.shiftStory) == "function" then Placement.shiftStory(player, from, to) end
	if Decor and type(Decor.shiftStory) == "function" then Decor.shiftStory(player, from, to) end
end

------------------------------------------------------------------
-- the lounge's interior (Buildings.vip.dress: called while the shell is built)
------------------------------------------------------------------
local LOOK = {
	velvet = Color3.fromRGB(78, 24, 112),    -- the walls: royal purple velvet
	gold = Color3.fromRGB(232, 182, 76),     -- rendered on Brass
	marble = Color3.fromRGB(44, 34, 54),     -- plum-black marble (the medallion's heart; the slab is Buildings')
	skirting = Color3.fromRGB(16, 12, 18),   -- gloss black
	cove = Color3.fromRGB(176, 84, 255),     -- the purple neon cove
	crystal = Color3.fromRGB(226, 238, 255),
	candle = Color3.fromRGB(255, 222, 160),
	light = Color3.fromRGB(255, 214, 165),   -- the chandeliers' warm light
	carpet = Color3.fromRGB(176, 18, 42),    -- the red carpet
	rope = Color3.fromRGB(150, 14, 40),      -- velvet ropes
	plate = Color3.fromRGB(96, 30, 140),     -- the sign
	signGlow = Color3.fromRGB(196, 92, 255),
}

-- folder: the VIP story's folder; at(x, y, z): plot-local -> world CFrame (y = 0
-- at the base's bottom, front = -Z); ctx: { story, yFloor, W, D, S }. Every part
-- carries Story (the cutaway); nothing collides or takes raycasts (K.part's
-- default), so guests, the camera and prompts never notice it. Flat pieces sit
-- below the decor layers (DecorModels: 0.06+), so a rug on top never flickers.
local function dress(folder: Instance, at, ctx): boolean
	local s, fy = ctx.story, ctx.yFloor
	local hx, hz = ctx.W / 2, ctx.D / 2               -- the walls' inner faces
	local top = (ctx.story == ctx.S) and (fy + H - 0.2) or (fy + H - 1.2) -- under the ceiling
	local L = 0.2                                     -- the velvet lining's depth

	local function tag(p: BasePart): BasePart
		p:SetAttribute("Story", s)
		return p
	end
	-- a box from its plot-local extents (either order)
	local function box(name: string, x0, x1, y0, y1, z0, z1, color: Color3, opts): BasePart
		local size = Vector3.new(math.abs(x1 - x0), math.abs(y1 - y0), math.abs(z1 - z0))
		return tag(K.part(folder, name, size, at((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2), color, opts))
	end
	local function gold(p: BasePart): BasePart
		return Materials.paint(p, "Brass", LOOK.gold)
	end
	local function fabric(): any return { material = Enum.Material.Fabric } end
	local function flat(): any return { shadow = false } end
	local function pos(x, y, z): Vector3 return at(x, y, z).Position end
	-- one member along all four walls, from `d0` (default 0: on the wall) to `depth`
	-- out from them (front + back run the full width, the sides fit in between).
	-- Rails start 0.1 off the wall so their back faces never share the pilasters'
	-- plane (seen through the gold glass)
	local function ring(name: string, y0: number, y1: number, depth: number, color: Color3, opts, sides: {string}?,
		d0: number?)
		local out = {}
		local want = {}
		local a = d0 or 0
		for _, k in (sides or { "front", "back", "left", "right" }) do want[k] = true end
		if want.front then table.insert(out, box(name, -hx + a, hx - a, y0, y1, -hz + a, -hz + depth, color, opts)) end
		if want.back then table.insert(out, box(name, -hx + a, hx - a, y0, y1, hz - depth, hz - a, color, opts)) end
		if want.left then table.insert(out, box(name, -hx + a, -hx + depth, y0, y1, -hz + depth, hz - depth, color, opts)) end
		if want.right then table.insert(out, box(name, hx - depth, hx - a, y0, y1, -hz + depth, hz - depth, color, opts)) end
		return out
	end

	-- the walls: purple velvet under and over the gold glass band (fy + 3 .. fy + 10
	-- on the glass walls; the back is solid), black skirting, gold chair + picture
	-- rails, gold pilasters, a purple neon cove under a gold crown moulding
	for _, y in { { fy, fy + 3 }, { fy + 10, top } } do
		ring("Velvet", y[1], y[2], L, LOOK.velvet, fabric(), { "front", "left", "right" })
	end
	box("Velvet", -hx, hx, fy, top, hz - L, hz, LOOK.velvet, fabric()) -- the solid back: one panel
	ring("Skirting", fy, fy + 0.6, 0.32, LOOK.skirting, { reflectance = 0.12 })
	for _, p in ring("ChairRail", fy + 2.8, fy + 3.1, 0.35, LOOK.gold, flat(), nil, 0.1) do gold(p) end
	for _, p in ring("PictureRail", fy + 9.9, fy + 10.2, 0.35, LOOK.gold, flat(), { "front", "left", "right" }, 0.1) do
		gold(p)
	end
	for _, p in ring("CrownMoulding", top - 0.6, top - 0.1, 0.5, LOOK.gold, flat()) do gold(p) end
	-- the cove: a neon line on the velvet under the moulding (always on: it's inside)
	local cy0, cy1 = top - 0.9, top - 0.65
	box("CoveNeon", -hx + 0.45, hx - 0.45, cy0, cy1, -hz + L, -hz + 0.45, LOOK.cove, { material = Enum.Material.Neon, shadow = false })
	box("CoveNeon", -hx + 0.45, hx - 0.45, cy0, cy1, hz - 0.45, hz - L, LOOK.cove, { material = Enum.Material.Neon, shadow = false })
	for _, sx in { -1, 1 } do
		box("CoveNeon", sx * (hx - L), sx * (hx - 0.45), cy0, cy1, -hz + 0.45, hz - 0.45, LOOK.cove,
			{ material = Enum.Material.Neon, shadow = false })
	end
	-- pilasters: 4 on the front and each side, 3 on the back (the sign sits between
	-- the middle pair); they stop under the cove
	local py0, py1, pd = fy + 0.6, top - 0.95, 0.45
	for _, x in { -24, -8, 8, 24 } do gold(box("Pilaster", x - 0.5, x + 0.5, py0, py1, -hz, -hz + pd, LOOK.gold)) end
	for _, x in { -27, -15, 15 } do gold(box("Pilaster", x - 0.5, x + 0.5, py0, py1, hz - pd, hz, LOOK.gold)) end
	for _, sx in { -1, 1 } do
		for _, z in { -24, -8, 8, 24 } do
			gold(box("Pilaster", sx * hx, sx * (hx - pd), py0, py1, z - 0.5, z + 0.5, LOOK.gold))
		end
	end

	-- the floor: a gold inlay border 2.5 in from the walls and a crown medallion in
	-- the middle (on Buildings' black marble slab)
	local inset, w = 2.5, 0.35
	for _, p in {
		box("Inlay", -hx + inset, hx - inset, fy, fy + 0.02, -hz + inset, -hz + inset + w, LOOK.gold, flat()),
		box("Inlay", -hx + inset, hx - inset, fy, fy + 0.02, hz - inset - w, hz - inset, LOOK.gold, flat()),
		box("Inlay", -hx + inset, -hx + inset + w, fy, fy + 0.02, -hz + inset + w, hz - inset - w, LOOK.gold, flat()),
		box("Inlay", hx - inset - w, hx - inset, fy, fy + 0.02, -hz + inset + w, hz - inset - w, LOOK.gold, flat()),
	} do gold(p) end
	-- big marble tiles: thin gold joints every 8 studs inside the border (they catch
	-- the chandelier light, so the floor reads as polished marble even at night)
	local jw, step = 0.12, 8
	local ix0, ix1, iz0, iz1 = -hx + inset + w, hx - inset - w, -hz + inset + w, hz - inset - w
	for x = math.ceil(ix0 / step) * step, ix1, step do
		if x > ix0 + 1 and x < ix1 - 1 then
			gold(box("Joint", x - jw / 2, x + jw / 2, fy, fy + 0.012, iz0, iz1, LOOK.gold, flat()))
		end
	end
	for z = math.ceil(iz0 / step) * step, iz1, step do
		if z > iz0 + 1 and z < iz1 - 1 then
			gold(box("Joint", ix0, ix1, fy, fy + 0.012, z - jw / 2, z + jw / 2, LOOK.gold, flat()))
		end
	end
	gold(tag(K.cylY(folder, "Medallion", 13, 0.02, pos(0, fy + 0.01, 0), LOOK.gold, { shadow = false })))
	Materials.paint(tag(K.cylY(folder, "MedallionHeart", 12, 0.035, pos(0, fy + 0.0175, 0), LOOK.marble, { shadow = false })),
		"PolishedTile", LOOK.marble)
	-- the crown + VIP print reads upright walking in from the elevator (toward -Z)
	local stamp = tag(K.flatPrint(folder, "MedallionCrown", 9, 9, at(0, fy + 0.045, 0) * CFrame.Angles(0, math.pi, 0)))
	local pg = K.surface(stamp, Enum.NormalId.Top, 30, 0)
	K.guiImage(pg, "crown", { size = UDim2.fromScale(0.62, 0.55), position = UDim2.fromScale(0.5, 0.36) })
	K.guiText(pg, "VIP", { size = UDim2.fromScale(0.6, 0.3), position = UDim2.fromScale(0.2, 0.64),
		gradient = { P.GoldTop, P.Gold }, strokeThickness = 4 })

	-- the red carpet from the elevator doors toward the room, gold-edged
	local ex, zDoor = E.x, E.z - E.size / 2
	local z0 = zDoor - 15
	box("RedCarpet", ex - 2.2, ex + 2.2, fy, fy + 0.03, z0, zDoor, LOOK.carpet,
		{ material = Enum.Material.Carpet, shadow = false })
	for _, sx in { -1, 1 } do
		gold(box("CarpetEdge", ex + sx * 2.2, ex + sx * 2.5, fy, fy + 0.04, z0, zDoor, LOOK.gold, flat()))
	end
	gold(box("CarpetEdge", ex - 2.5, ex + 2.5, fy, fy + 0.04, z0 - 0.3, z0, LOOK.gold, flat()))

	-- velvet ropes on brass stanchions line the aisle out of the elevator (inside
	-- its landing: Buildings.blocksElevator keeps machines + solid decor out of it)
	for _, sx in { -1, 1 } do
		local x = ex + sx * 4.6
		local zs = { zDoor - 1, zDoor - 4.6 }
		for _, z in zs do
			gold(tag(K.cylY(folder, "StanchionBase", 1.1, 0.16, pos(x, fy + 0.08, z), LOOK.gold, { shadow = false })))
			gold(tag(K.cylY(folder, "Stanchion", 0.24, 2.9, pos(x, fy + 1.61, z), LOOK.gold, {})))
			gold(tag(K.ball(folder, "StanchionTop", 0.55, pos(x, fy + 3.25, z), LOOK.gold, { shadow = false })))
		end
		local a, b = pos(x, fy + 2.9, zs[1]), pos(x, fy + 2.9, zs[2])
		local sag = pos(x, fy + 2.35, (zs[1] + zs[2]) / 2)
		for _, seg in { { a, sag }, { sag, b } } do
			tag(K.rod(folder, "VelvetRope", seg[1], seg[2], 0.3, LOOK.rope, { material = Enum.Material.Fabric, shadow = false }))
		end
	end

	-- the VIP LOUNGE sign on the back wall (between the middle pilasters): a purple
	-- plate in a neon halo, crowns, gold letters; it washes the floor purple
	local sy0, sy1 = fy + 8.2, fy + 13.6
	box("SignHalo", -12.45, 12.45, sy0 - 0.45, sy1 + 0.45, hz - 0.5, hz - 0.45, LOOK.signGlow,
		{ material = Enum.Material.Neon, shadow = false })
	local plate = box("LoungeSign", -12, 12, sy0, sy1, hz - 0.8, hz - 0.5, LOOK.plate, flat())
	local g = K.surface(plate, Enum.NormalId.Front, 40, 0)
	pcall(function() g.Brightness = 2 end)
	local back = K.signPlate(g, LOOK.plate, P.Gold)
	for _, x in { 0.09, 0.91 } do
		K.guiImage(back, "crown", { size = UDim2.fromScale(0.14, 0.78), position = UDim2.fromScale(x, 0.5) })
	end
	K.guiText(back, "VIP LOUNGE", { size = UDim2.fromScale(0.66, 0.6), position = UDim2.fromScale(0.17, 0.07),
		gradient = { P.GoldTop, P.Gold }, strokeThickness = 6 })
	K.guiText(back, ("EVERY MACHINE EARNS x%s"):format(multText()), { size = UDim2.fromScale(0.56, 0.2),
		position = UDim2.fromScale(0.22, 0.71), color = P.White, strokeThickness = 3 })
	K.new("SurfaceLight", { Face = Enum.NormalId.Front, Angle = 110, Range = 16, Brightness = 1.2, Color = LOOK.signGlow,
		Shadows = false }, plate)

	-- 4 crystal chandeliers where the other floors have their ceiling lights: a gold
	-- rod + crown, a crystal column in a ring of 6 candles, 3 crystal pendants and a
	-- crystal drop that holds the light
	local glass = function(t: number) return { material = Enum.Material.Glass, transparency = t, reflectance = 0.3, shadow = false } end
	for _, cx in { -hx / 2, hx / 2 } do
		for _, cz in { -hz / 2, hz / 2 } do
			local yc = top
			gold(tag(K.cylY(folder, "ChandelierRod", 0.22, 2.2, pos(cx, yc - 1.1, cz), LOOK.gold, { shadow = false })))
			gold(tag(K.cylY(folder, "ChandelierCrown", 3.6, 0.26, pos(cx, yc - 2.3, cz), LOOK.gold, { shadow = false })))
			tag(K.cylY(folder, "ChandelierCrystal", 1.3, 2, pos(cx, yc - 3.3, cz), LOOK.crystal, glass(0.2)))
			gold(tag(K.cylY(folder, "ChandelierRing", 6, 0.3, pos(cx, yc - 3.7, cz), LOOK.gold, { shadow = false })))
			for k = 0, 5 do
				local a = math.rad(30 + 60 * k)
				tag(K.ball(folder, "ChandelierCandle", 0.55, pos(cx + math.cos(a) * 2.75, yc - 3.27, cz + math.sin(a) * 2.75),
					LOOK.candle, { material = Enum.Material.Neon, shadow = false }))
			end
			for k = 0, 2 do
				local a = math.rad(120 * k)
				tag(K.part(folder, "ChandelierPendant", Vector3.new(0.32, 1.2, 0.32),
					at(cx + math.cos(a) * 2.35, yc - 4.5, cz + math.sin(a) * 2.35) * CFrame.Angles(0, a + math.rad(45), 0),
					LOOK.crystal, glass(0.15)))
			end
			local drop = tag(K.ball(folder, "ChandelierDrop", 1.1, pos(cx, yc - 4.8, cz), LOOK.crystal, glass(0.15)))
			K.new("SpotLight", { Face = Enum.NormalId.Bottom, Angle = 120, Range = 40, Brightness = 1.8, Color = LOOK.light,
				Shadows = false }, drop)
		end
	end
	return true
end
VipFloor.dress = dress -- (exposed for tests)

------------------------------------------------------------------
-- the pass coming / going mid-session
------------------------------------------------------------------
-- the first time a player's lounge appears: VipFloorUI's welcome (once per profile)
local function welcome(player: Player)
	local mem = memoryOf(Data.get(player))
	local story = Buildings.vipStory(player)
	if not (mem and story) or mem.welcomed then return end
	mem.welcomed = os.time()
	player:SetAttribute("VipFloorWelcome", story)
	task.delay(tonumber(cfg().WelcomeSeconds) or 90, function()
		if player.Parent and player:GetAttribute("VipFloorWelcome") == story then
			player:SetAttribute("VipFloorWelcome", nil)
		end
	end)
end

local function rebuild(player: Player)
	local rec = Plots.getRecordForOwner(player.UserId)
	if rec then Buildings.rebuild(rec) end
end

-- the pass was bought: the lounge opens on top (nothing up there yet)
local function gain(player: Player, st)
	st.owned = true
	rebuild(player)
	local mem = memoryOf(Data.get(player))
	if mem then mem.owned = true end
	welcome(player)
	print(("[VipFloor] %s's VIP Lounge opened on floor %s."):format(player.Name, tostring(Buildings.vipStory(player))))
end

-- the pass is gone: what stood up there goes back to the items, the people
-- up there downstairs, then the floor goes
local function lose(player: Player, st)
	local story = Buildings.vipStory(player)
	local rec = Plots.getRecordForOwner(player.UserId)
	if story and rec then
		for _, m in table.clone(rec.machines) do
			if m.Parent and m:GetAttribute("Story") == story then
				local ok, err = pcall(Placement.pickup, player, m)
				if not ok then warn("[VipFloor] pickup: " .. tostring(err)) end
			end
		end
		if Decor and type(Decor.returnStory) == "function" then Decor.returnStory(player, story) end
		movePeople(rec, story, nil)
	end
	st.owned = false
	rebuild(player)
	local mem = memoryOf(Data.get(player))
	if mem then mem.owned = false end
end

-- Picks up a pass bought (or gone) since the lounge was built: opens / closes it.
-- The poll loop runs this for everyone every CheckSeconds; call it right after a
-- purchase for an instant response. Returns true when something changed.
function VipFloor.check(player: Player): boolean
	local st = state[player.UserId]
	if not (st and not st.busy and Data.get(player)) then return false end
	local now = passOwned(player)
	if now == st.owned then return false end
	st.busy = true
	local ok, err = pcall(now and gain or lose, player, st)
	st.busy = nil
	if not ok then warn("[VipFloor] " .. tostring(err)) end
	if pushData then pcall(pushData, player) end
	return true
end

local function poll()
	for _, player in Players:GetPlayers() do
		VipFloor.check(player)
	end
end

------------------------------------------------------------------
-- join / leave / snapshot / start
------------------------------------------------------------------
-- after Plots.assign (the shell already has the lounge), Placement.restore and
-- Decor.join (what was saved up there is back on it). The state starts as the
-- shell was built; check() opens / closes the lounge if the pass says otherwise.
function VipFloor.join(player: Player)
	local owned = passOwned(player)
	local rec = Plots.getRecordForOwner(player.UserId)
	local shell = rec and rec.model:FindFirstChild("Building")
	local built = owned
	if shell then built = shell:GetAttribute("VipStory") ~= nil end
	state[player.UserId] = { owned = built }
	local mem = memoryOf(Data.get(player))
	if mem then mem.owned = owned end
	if not VipFloor.check(player) and owned then welcome(player) end
end

function VipFloor.leave(player: Player)
	state[player.UserId] = nil
end

function VipFloor.snapshot(player: Player, profile)
	local story = Buildings and Buildings.vipStory(player) or nil
	local machines = 0
	local rec = story and Plots.getRecordForOwner(player.UserId)
	if rec then
		for _, m in rec.machines do
			if m.Parent and m:GetAttribute("Story") == story and m:GetAttribute("Kind") ~= "concession" then
				machines += 1
			end
		end
	end
	local gp = Config.getGamepass and Config.getGamepass(passKey())
	local _ = profile
	return {
		enabled = enabled() and started,
		owned = story ~= nil,
		story = story,
		mult = VipFloor.mult(),
		slots = Config.Building.MachinesPerStory,
		machines = machines,
		passId = gp and gp.id or 0,
	}
end

-- deps (init.server): Data, Plots, Placement, Buildings, Monetization, Decor, pushData
function VipFloor.start(deps)
	Data = deps.Data
	Plots = deps.Plots
	Placement = deps.Placement
	Buildings = deps.Buildings
	Monetization = deps.Monetization
	Decor = deps.Decor
	pushData = deps.pushData
	if started then return end
	if not enabled() then
		print("[CasinoTycoon] VipFloor: switched off (Config.VipFloor.Enabled).")
		return
	end
	if not (Buildings and Plots and Data and Monetization) then
		warn("[VipFloor] missing deps: no VIP floors this session.")
		return
	end
	started = true
	Buildings.vip = { owns = VipFloor.owns, moved = moved, dress = dress }
	task.spawn(function()
		while true do
			task.wait(math.max(0.25, tonumber(cfg().CheckSeconds) or 1))
			local ok, err = pcall(poll)
			if not ok then warn("[VipFloor] poll: " .. tostring(err)) end
		end
	end)
	print(("[CasinoTycoon] VipFloor: VIP Lounges open (machines up there earn x%s)."):format(multText()))
end

return VipFloor
