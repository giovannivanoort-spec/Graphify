--!nonstrict
-- StaffClient.luau — the hired staff at work in every casino near the camera.
-- Purely local: the server only publishes each plot's "StaffRoster" attribute
-- ("greeter:2,dealer:3", Staff.luau) and the dressed rig templates
-- (ReplicatedStorage.StaffTemplates, StaffModels.luau).
--   * where they work (Config.Staff `post`):
--       entrance  greeters + security flank the velvet ropes under the porte-cochère
--                 (higher levels: one more inside the door / by the elevator)
--       curb      the valet beside his podium at the taxi bay
--       tables    dealers behind your table games (the model's +Z side, facing the
--                 guests); wheels get a host at the side
--       stands    bartenders behind the snack / drink / souvenir counters
--       vip       the VIP host beside your priciest machine
--       pit       the pit boss in the middle of the tables
--       stage     the entertainer on a stage by the back wall, dancing
--       wander    the janitor mops the floor (wet-floor sign while mopping)
--       slots     technicians walk from slot machine to slot machine
--       floor     the floor manager does the rounds
--   * team[level] people per role (a promotion grows the team); tables / stands
--     cap dealers / bartenders. A new hire in YOUR casino pops in with a puff.
--   * light: only casinos within Config.StaffView.Range of the camera get people
--     (MaxCasinos / MaxPerCasino / MaxRigs caps, your own casino first). Roots are
--     anchored; animations and walks are engine tweens (no per-frame Lua). A
--     planner tick (1 s) re-plans a casino only when its roster, floors or machine
--     layout changed (a machine moved / added / removed: dealers follow it).
--   * every person / prop: tag "CasinoStaff" + attribute "Story", so BuildingView
--     cuts them away with the stories above you.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Config = require(Common:WaitForChild("Config"))
local UILib = require(script.Parent:WaitForChild("UILib"))

local StaffClient = {}

local player = Players.LocalPlayer
local SV = Config.StaffView or {}
local RANGE = SV.Range or 240
local MAX_CASINOS = SV.MaxCasinos or 4
local MAX_PER_CASINO = SV.MaxPerCasino or 24
local MAX_OWN = SV.MaxOwn or 32
local MAX_RIGS = SV.MaxRigs or 64
if UILib.IsTouch then -- phones / tablets: half the crowd (your own casino still comes first)
	MAX_CASINOS = math.max(1, math.floor(MAX_CASINOS / 2))
	MAX_OWN = math.min(MAX_OWN, MAX_PER_CASINO)
	MAX_RIGS = math.max(MAX_OWN, math.floor(MAX_RIGS / 2))
end
local TAG_DISTANCE = SV.TagDistance or 60
local WALK_SPEED = SV.WalkSpeed or 6.5
local STORY_H = Config.Building.StoryHeight
local ELEV = Config.Building.Elevator
local TAG = "CasinoStaff"
local GESTURE_RANGE = 140 -- studs: people farther from the camera don't bother waving

local ANIM_IDS = {
	idle = "rbxassetid://507766388", walk = "rbxassetid://913402848",
	wave = "rbxassetid://507770239", point = "rbxassetid://507770453", cheer = "rbxassetid://507770677",
	dance1 = "rbxassetid://507771019", dance2 = "rbxassetid://507776043", dance3 = "rbxassetid://507777268",
}
local GESTURES = { -- what a standing role does now and then
	greeter = { "wave" }, host = { "wave", "point" }, valet = { "wave" }, pit_boss = { "point" },
	security = {}, dealer = { "point" }, bartender = {}, floor_manager = { "point" },
}
local TONES = UILib.Tones
local C = UILib.Colors
local SKIN = { Color3.fromHex("#FFD3A8"), Color3.fromHex("#EDBB91"), Color3.fromHex("#C9956B"),
	Color3.fromHex("#A0704A"), Color3.fromHex("#6E4A30") }
local HAIR = { Color3.fromHex("#2B1B10"), Color3.fromHex("#54331C"), Color3.fromHex("#141014"),
	Color3.fromHex("#9A6332"), Color3.fromHex("#E2C27A") }

local templates: Folder? = nil
local animations: {[string]: Animation} = {}
local casinos = {}       -- plot Model -> casino state
local rigTotal = 0       -- people alive (all casinos)
local root: Folder? = nil
local rng = Random.new()

------------------------------------------------------------------
-- small helpers
------------------------------------------------------------------
local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function animation(name: string): Animation?
	local a = animations[name]
	if a then return a end
	local id = ANIM_IDS[name]
	if not id then return nil end
	a = Instance.new("Animation")
	a.AnimationId = id
	animations[name] = a
	return a
end

-- the roster attribute: "greeter:2,dealer:3" -> { greeter = 2, dealer = 3 }
local function parseRoster(s: any): {[string]: number}
	local out = {}
	if type(s) ~= "string" then return out end
	for id, lvl in s:gmatch("([%w_]+):(%d+)") do
		if Config.getStaffDef(id) then out[id] = tonumber(lvl) end
	end
	return out
end

local function hashOf(...): number
	local s = table.concat({ ... }, "|")
	local h = 7
	for i = 1, #s do h = (h * 31 + s:byte(i)) % 2147483647 end
	return h
end

-- a rotation about Y so -Z (the face) looks along `dir` (plot-local)
local function facing(dir: Vector3): CFrame
	local d = flat(dir)
	if d.Magnitude < 1e-3 then return CFrame.identity end
	d = d.Unit
	return CFrame.lookAt(Vector3.zero, d)
end

------------------------------------------------------------------
-- the floor plan of one casino (plot-local: front / street = -Z)
------------------------------------------------------------------
local function storyFloorY(story: number): number
	return 1 + (story - 1) * STORY_H -- Buildings.storyFloorY
end

local function inElevator(x: number, z: number, r: number): boolean
	local half = ELEV.size / 2
	local x0, x1 = ELEV.x - half - 1.6 - r, ELEV.x + half + 1.6 + r
	local z0, z1 = ELEV.z - half - 5 - r, ELEV.z + half + r
	return x >= x0 and x <= x1 and z >= z0 and z <= z1
end

-- is a spot of radius r on `story` free of walls, the elevator, machines (except
-- `ignore`) and the people already placed?
local function isFree(st, story: number, x: number, z: number, r: number, ignore): boolean
	if math.abs(x) > st.W / 2 - 1 - r * 0.5 or math.abs(z) > st.D / 2 - 1 - r * 0.5 then return false end
	if inElevator(x, z, r) then return false end
	for _, c in (st.circles[story] or {}) do
		if c.rec ~= ignore then
			local dx, dz = c.x - x, c.z - z
			if dx * dx + dz * dz < (c.r + r + 0.25) ^ 2 then return false end
		end
	end
	for _, t in (st.taken[story] or {}) do
		local dx, dz = t.x - x, t.z - z
		if dx * dx + dz * dz < (t.r + r) ^ 2 then return false end
	end
	return true
end

local function take(st, story: number, x: number, z: number, r: number)
	st.taken[story] = st.taken[story] or {}
	table.insert(st.taken[story], { x = x, z = z, r = r })
end

-- does the straight walk a -> b on `story` stay clear of the machines? (the
-- machines the walk starts or ends at don't count)
local function clearPath(st, story: number, a: Vector3, b: Vector3): boolean
	local ab = b - a
	local len2 = ab.X * ab.X + ab.Z * ab.Z
	for _, c in (st.circles[story] or {}) do
		local p = Vector3.new(c.x, 0, c.z)
		local near = (flat(a) - p).Magnitude < c.r + 1.6 or (flat(b) - p).Magnitude < c.r + 1.6
		if not near then
			local t = len2 > 0 and math.clamp(((p.X - a.X) * ab.X + (p.Z - a.Z) * ab.Z) / len2, 0, 1) or 0
			local q = Vector3.new(a.X + ab.X * t, 0, a.Z + ab.Z * t)
			if (q - p).Magnitude < c.r + 0.7 then return false end
		end
	end
	if inElevator(b.X, b.Z, 0) then return false end
	return true
end

-- a spot next to a machine, in machine space (front = -Z), on the plot
local function machineSpot(st, rec, mx: number, mz: number, face: Vector3): (number, number, CFrame)
	local cf = rec.lcf * CFrame.new(mx, 0, mz)
	local look = rec.lcf:VectorToWorldSpace(face)
	return cf.X, cf.Z, facing(look)
end

-- the first free spot among machine-space candidates { {x, z, faceDir} }
local function spotBy(st, rec, candidates, r: number)
	for _, c in candidates do
		local x, z, rot = machineSpot(st, rec, c[1], c[2], c[3])
		if isFree(st, rec.story, x, z, r, rec) then return x, z, rot end
	end
	return nil
end

-- a free spot near (x, z): rings of 8 directions out to `maxR`
local function spiral(st, story: number, x: number, z: number, r: number, maxR: number?)
	if isFree(st, story, x, z, r) then return x, z end
	for ring = 1.5, maxR or 14, 1.5 do
		for k = 0, 7 do
			local a = k * math.pi / 4 + ring * 0.37
			local px, pz = x + math.cos(a) * ring, z + math.sin(a) * ring
			if isFree(st, story, px, pz, r) then return px, pz end
		end
	end
	return nil
end

-- any free spot on a story (random tries)
local function randomFree(st, story: number, r: number)
	for _ = 1, 30 do
		local x = rng:NextNumber(-st.W / 2 + 3, st.W / 2 - 3)
		local z = rng:NextNumber(-st.D / 2 + 3, st.D / 2 - 3)
		if isFree(st, story, x, z, r) then return x, z end
	end
	return nil
end

------------------------------------------------------------------
-- machines per owner (a snapshot each planner tick)
------------------------------------------------------------------
local TABLE_TYPES = { Roulette = true, Blackjack = true }
local COUNTER_TYPES = { Snacks = true, Drinks = true, Souvenirs = true }

local function machineRecord(m: Instance)
	if not m:IsA("Model") or not m.Parent then return nil end
	local pp = m.PrimaryPart
	if not pp then return nil end -- not streamed in yet
	local def = Config.getMachineDef(m:GetAttribute("MachineId"))
	local pivot
	if m:GetAttribute("GroundPivot") then
		pivot = m:GetPivot()
	else
		pivot = pp.CFrame * CFrame.new(0, -pp.Size.Y / 2, 0)
	end
	local size = def and def.size or pp.Size
	return {
		m = m, def = def, pivot = pivot, size = size,
		story = m:GetAttribute("Story") or 1,
		r = m:GetAttribute("FootprintRadius") or math.max(size.X, size.Z) / 2,
		kind = m:GetAttribute("Kind") or "machine",
		gameType = m:GetAttribute("GameType"),
		cost = def and def.cost or 0,
		placedId = tostring(m:GetAttribute("PlacedId") or m:GetFullName()),
	}
end

local function gatherMachines(owners: {[number]: boolean})
	local by = {}
	for _, m in CollectionService:GetTagged("CasinoMachine") do
		local owner = m:GetAttribute("OwnerId")
		if owner and owners[owner] then
			local rec = machineRecord(m)
			if rec then
				local list = by[owner]
				if not list then
					list = {}
					by[owner] = list
				end
				table.insert(list, rec)
			end
		end
	end
	for _, list in by do
		table.sort(list, function(a, b) return a.placedId < b.placedId end)
	end
	return by
end

local function isTable(rec): boolean
	if rec.kind == "concession" then return false end
	if TABLE_TYPES[rec.gameType] then return true end
	-- dice tables (craps, sic bo) and other low, wide games; cabinets are tall / narrow
	return rec.gameType == "Dice" and rec.size.X >= 6 and rec.size.Y <= 6
end

local function isWheel(rec): boolean
	return rec.kind ~= "concession" and rec.gameType == "Wheel"
end

local function isSlotLike(rec): boolean
	return rec.kind ~= "concession" and (rec.gameType == "Slots" or rec.gameType == "Plinko"
		or (rec.gameType == "Dice" and not isTable(rec)))
end

------------------------------------------------------------------
-- people
------------------------------------------------------------------
local function tone(name: string?)
	return TONES[name or "Gold"] or TONES.Gold
end

-- the floating "DEALER  LV3" tag
local function nameTag(rig: Model, def, level: number)
	local head = rig:FindFirstChild("Head")
	if not (head and head:IsA("BasePart")) then return end
	local t = tone(def.tone)
	local tall = rig:FindFirstChild("HatCrown", true) ~= nil or rig:FindFirstChild("HardHat", true) ~= nil
	local bb = Instance.new("BillboardGui")
	bb.Name = "StaffTag"
	bb.Adornee = head
	bb.Size = UDim2.fromScale(4.6, 0.9)
	bb.StudsOffset = Vector3.new(0, tall and 2.6 or 1.9, 0)
	bb.MaxDistance = TAG_DISTANCE
	bb.LightInfluence = 0
	bb.AlwaysOnTop = false
	local pill = Instance.new("Frame")
	pill.AnchorPoint = Vector2.new(0.5, 0.5)
	pill.Position = UDim2.fromScale(0.5, 0.5)
	pill.Size = UDim2.fromScale(0.86, 0.8)
	pill.BackgroundColor3 = Color3.new(1, 1, 1)
	pill.Parent = bb
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = pill
	local grad = Instance.new("UIGradient")
	grad.Rotation = 90
	grad.Color = ColorSequence.new(t.top, t.base)
	grad.Parent = pill
	local stroke = Instance.new("UIStroke")
	stroke.Color = C.Ink
	stroke.Thickness = 2
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = pill
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Position = UDim2.fromScale(0.07, 0.08)
	label.Size = UDim2.fromScale(0.62, 0.84)
	label.Font = Enum.Font.LuckiestGuy
	label.TextScaled = true
	label.TextColor3 = Color3.new(1, 1, 1)
	label.Text = string.upper(def.name)
	label.Parent = pill
	local ls = Instance.new("UIStroke")
	ls.Color = C.Ink
	ls.Thickness = 1.5
	ls.Parent = label
	local chip = Instance.new("TextLabel")
	chip.AnchorPoint = Vector2.new(1, 0.5)
	chip.Position = UDim2.fromScale(0.97, 0.5)
	chip.Size = UDim2.fromScale(0.26, 0.74)
	chip.BackgroundColor3 = C.Ink
	chip.Font = Enum.Font.FredokaOne
	chip.TextScaled = true
	chip.TextColor3 = C.GoldTop
	chip.Text = "LV" .. level
	chip.Parent = pill
	local cc = Instance.new("UICorner")
	cc.CornerRadius = UDim.new(0.5, 0)
	cc.Parent = chip
	bb.Parent = head
	return bb
end

local function setTagLevel(person, level: number)
	local head = person.rig and person.rig:FindFirstChild("Head")
	local bb = head and head:FindFirstChild("StaffTag")
	local pill = bb and bb:FindFirstChildOfClass("Frame")
	if not pill then return end
	for _, l in pill:GetChildren() do
		if l:IsA("TextLabel") and l.Text:sub(1, 2) == "LV" then l.Text = "LV" .. level end
	end
end

-- skin / hair tones vary per person (stable for the same casino + role + slot)
local function individualize(rig: Model, seed: number)
	local skin = SKIN[seed % #SKIN + 1]
	local hair = HAIR[(seed // 7) % #HAIR + 1]
	for _, d in rig:GetDescendants() do
		if d:IsA("BasePart") then
			if d:GetAttribute("Skin") then
				d.Color = skin
			elseif d:GetAttribute("Hair") then
				d.Color = hair
			end
		end
	end
end

local function play(person, name: string, opts)
	local track = person.tracks[name]
	if not track then
		local anim = animation(name)
		if not (anim and person.animator) then return nil end
		local ok, res = pcall(function() return person.animator:LoadAnimation(anim) end)
		if not ok or not res then return nil end
		track = res
		person.tracks[name] = track
		if name == "idle" then
			track.Priority = Enum.AnimationPriority.Idle
			track.Looped = true
		elseif name == "walk" then
			track.Priority = Enum.AnimationPriority.Movement
			track.Looped = true
		elseif name:sub(1, 5) == "dance" then
			track.Priority = Enum.AnimationPriority.Action
			track.Looped = true
		else
			track.Priority = Enum.AnimationPriority.Action
			track.Looped = false
		end
	end
	opts = opts or {}
	pcall(function() track:Play(opts.fade or 0.2, 1, opts.speed or 1) end)
	return track
end

local function stop(person, name: string, fade: number?)
	local track = person.tracks[name]
	if track and track.IsPlaying then pcall(function() track:Stop(fade or 0.2) end) end
end

local function destroyPerson(st, person)
	if person.dead then return end
	person.dead = true
	if person.tween then person.tween:Cancel() end
	if person.prop then person.prop:Destroy() end
	if person.sign then person.sign:Destroy() end
	if person.rig then person.rig:Destroy() end
	st.people[person.key] = nil
	rigTotal -= 1
end

-- clone the role's template into the casino (standing at `cf`, a ground CFrame)
local function spawnPerson(st, key: string, id: string, index: number, level: number, story: number, cf: CFrame)
	local tpl = templates and templates:FindFirstChild(id)
	local def = Config.getStaffDef(id)
	if not (tpl and def) then return nil end
	local rig = tpl:Clone()
	local rootPart = rig.PrimaryPart or rig:FindFirstChild("HumanoidRootPart")
	if not (rootPart and rootPart:IsA("BasePart")) then
		rig:Destroy()
		return nil
	end
	rootPart.Anchored = true
	-- players walk through staff: the NPC collision group (a Humanoid forces its
	-- torso and head collidable, so CanCollide alone isn't enough)
	local npcGroup = Config.CollisionGroups and Config.CollisionGroups.NPC
	for _, d in rig:GetDescendants() do
		if d:IsA("BasePart") then
			d.CanCollide = false
			if npcGroup then pcall(function() d.CollisionGroup = npcGroup end) end
		end
	end
	individualize(rig, hashOf(st.ownerId, id, index))
	local lift = tonumber(rig:GetAttribute("GroundOffset")) or 3
	rig:PivotTo(cf * CFrame.new(0, lift, 0))
	rig:SetAttribute("Story", story)
	rig:SetAttribute("OwnerId", st.ownerId)
	CollectionService:AddTag(rig, TAG)
	nameTag(rig, def, level)
	rig.Parent = st.folder
	local hum = rig:FindFirstChildOfClass("Humanoid")
	local person = {
		key = key, id = id, def = def, index = index, level = level, story = story,
		rig = rig, root = rootPart, lift = lift, animator = hum and hum:FindFirstChildOfClass("Animator"),
		tracks = {}, nextGesture = os.clock() + rng:NextNumber(3, 12),
	}
	st.people[key] = person
	rigTotal += 1
	play(person, "idle", { fade = 0, speed = rng:NextNumber(0.85, 1.1) })
	return person
end

-- stand a person somewhere else (a machine moved under them)
local function placePerson(person, cf: CFrame, story: number)
	if person.tween then person.tween:Cancel() end
	person.rig:PivotTo(cf * CFrame.new(0, person.lift, 0))
	if person.story ~= story then
		person.story = story
		person.rig:SetAttribute("Story", story)
	end
end

local function spawnProp(st, name: string, cf: CFrame, story: number): Model?
	local props = templates and templates:FindFirstChild("Props")
	local tpl = props and props:FindFirstChild(name)
	if not tpl then return nil end
	local m = tpl:Clone()
	m:PivotTo(cf)
	m:SetAttribute("Story", story)
	CollectionService:AddTag(m, TAG)
	if m:FindFirstChild("Bulbs") then CollectionService:AddTag(m, "CasinoProp") end -- MachineFX chases them
	m.Parent = st.folder
	return m
end

-- a new hire walks in: smoke puff + "NEW DEALER!" (your own casino only)
local function hireFx(person)
	local cam = Workspace.CurrentCamera
	if not (cam and person.root) then return end
	if (cam.CFrame.Position - person.root.Position).Magnitude > 160 then return end
	UILib.fx("puff", person.root.Position - Vector3.new(0, person.lift - 0.5, 0), 2.6)
	UILib.fx("worldText", person.rig, "NEW " .. string.upper(person.def.name) .. "!", C.GoldTop, 26)
end

------------------------------------------------------------------
-- walkers (janitor, technicians, floor manager)
------------------------------------------------------------------
local function groundCF(st, story: number, x: number, z: number, rot: CFrame?): CFrame
	return st.frame * CFrame.new(x, storyFloorY(story), z) * (rot or CFrame.identity)
end

-- walk `person` to plot-local (x, z) on its story; yields; false if interrupted
local function walkTo(st, person, x: number, z: number): boolean
	if person.dead or not st.alive then return false end
	local from = st.frame:PointToObjectSpace(person.root.Position)
	local delta = Vector3.new(x - from.X, 0, z - from.Z)
	local dist = delta.Magnitude
	if dist < 0.3 then return true end
	local rot = facing(delta)
	local target = groundCF(st, person.story, x, z, rot) * CFrame.new(0, person.lift, 0)
	-- turn first, then glide (an anchored root: the engine tweens the whole rig)
	person.rig:PivotTo(groundCF(st, person.story, from.X, from.Z, rot) * CFrame.new(0, person.lift, 0))
	local walk = play(person, "walk", { fade = 0.15 })
	if walk then pcall(function() walk:AdjustSpeed(WALK_SPEED / 12) end) end
	stop(person, "idle", 0.15)
	local tween = TweenService:Create(person.root, TweenInfo.new(dist / WALK_SPEED, Enum.EasingStyle.Linear), { CFrame = target })
	person.tween = tween
	tween:Play()
	local done = false
	local conn = tween.Completed:Connect(function() done = true end)
	local deadline = os.clock() + dist / WALK_SPEED + 1
	while not done and not person.dead and st.alive and os.clock() < deadline do task.wait(0.25) end
	conn:Disconnect()
	person.tween = nil
	if person.dead or not st.alive then return false end
	stop(person, "walk", 0.2)
	play(person, "idle", { fade = 0.2 })
	return true
end

-- walk there, round a machine if the straight line is blocked (an L-shaped detour)
local function routeTo(st, person, x: number, z: number): boolean
	local here = st.frame:PointToObjectSpace(person.root.Position)
	local a, b = Vector3.new(here.X, 0, here.Z), Vector3.new(x, 0, z)
	if clearPath(st, person.story, a, b) then return walkTo(st, person, x, z) end
	for _, mid in { Vector3.new(b.X, 0, a.Z), Vector3.new(a.X, 0, b.Z) } do
		if isFree(st, person.story, mid.X, mid.Z, 0.6) and clearPath(st, person.story, a, mid)
			and clearPath(st, person.story, mid, b) then
			return walkTo(st, person, mid.X, mid.Z) and walkTo(st, person, x, z)
		end
	end
	return false
end

local function faceTowards(st, person, x: number, z: number)
	local here = st.frame:PointToObjectSpace(person.root.Position)
	local d = Vector3.new(x - here.X, 0, z - here.Z)
	if d.Magnitude < 0.1 or person.dead then return end
	person.rig:PivotTo(groundCF(st, person.story, here.X, here.Z, facing(d)) * CFrame.new(0, person.lift, 0))
end

-- what a walker heads for next: x, z (+ the spot to face, + what to do there)
local function nextStop(st, person)
	local story = person.story
	local recs = st.byStory[story] or {}
	if person.id == "technician" then
		local slots = {}
		for _, rec in recs do
			if isSlotLike(rec) then table.insert(slots, rec) end
		end
		if #slots == 0 then slots = recs end
		for _ = 1, 6 do
			local rec = slots[rng:NextInteger(1, math.max(1, #slots))]
			if not rec then break end
			local side = rng:NextNumber() < 0.5 and -1 or 1
			local sx = side * (rec.size.X / 2 + 0.9)
			local x, z = machineSpot(st, rec, sx, -rec.size.Z * 0.15, Vector3.new(-side, 0, 0))
			if isFree(st, story, x, z, 0.6, rec) then
				local c = rec.lcf.Position
				return x, z, c.X, c.Z, "service"
			end
		end
	elseif person.id == "floor_manager" then
		if #recs > 0 and rng:NextNumber() < 0.7 then
			for _ = 1, 6 do
				local rec = recs[rng:NextInteger(1, #recs)]
				local x, z = machineSpot(st, rec, rng:NextNumber(-1.5, 1.5), -(rec.size.Z / 2 + 3.2), Vector3.new(0, 0, 1))
				if isFree(st, story, x, z, 0.6, rec) then
					local c = rec.lcf.Position
					return x, z, c.X, c.Z, "inspect"
				end
			end
		end
	end
	local x, z = randomFree(st, story, 0.8)
	if x then return x, z, nil, nil, person.id == "janitor" and "mop" or "pause" end
	return nil
end

local function walkerLoop(st, person)
	task.wait(rng:NextNumber(0.5, 3))
	while not person.dead and st.alive do
		local x, z, fx, fz, job = nextStop(st, person)
		if not x then
			task.wait(3)
			continue
		end
		local cam = Workspace.CurrentCamera
		local far = cam and (cam.CFrame.Position - person.root.Position).Magnitude > RANGE
		if far then
			task.wait(4) -- nobody's watching: no walking about
			continue
		end
		if routeTo(st, person, x, z) then
			if fx then faceTowards(st, person, fx, fz) end
			if job == "mop" then
				-- the wet-floor sign beside them while they mop (a little sway of the mop)
				local here = st.frame:PointToObjectSpace(person.root.Position)
				local look = st.frame:VectorToObjectSpace(person.root.CFrame.LookVector)
				local sx, sz = here.X + look.Z * 1.6, here.Z - look.X * 1.6 -- at their left side
				if isFree(st, person.story, sx, sz, 0.5) then
					local signCF = groundCF(st, person.story, sx, sz, facing(Vector3.new(-look.X, 0, -look.Z)))
					person.sign = spawnProp(st, "WetFloorSign", signCF, person.story)
				end
				local base = person.root.CFrame
				for _ = 1, 4 do
					if person.dead or not st.alive then break end
					local tw = TweenService:Create(person.root, TweenInfo.new(0.7, Enum.EasingStyle.Sine,
						Enum.EasingDirection.InOut, 0, true), { CFrame = base * CFrame.Angles(0, math.rad(22), 0) })
					person.tween = tw
					tw:Play()
					task.wait(1.45)
				end
				person.tween = nil
				if person.sign then
					person.sign:Destroy()
					person.sign = nil
				end
				if not person.dead then person.root.CFrame = base end
				task.wait(rng:NextNumber(1, 3))
			elseif job == "service" then
				play(person, "point", { fade = 0.2 })
				task.wait(rng:NextNumber(5, 9))
			elseif job == "inspect" then
				if rng:NextNumber() < 0.5 then play(person, "point") end
				task.wait(rng:NextNumber(3, 6))
			else
				task.wait(rng:NextNumber(2, 5))
			end
		else
			task.wait(1)
		end
	end
end

------------------------------------------------------------------
-- the plan: who stands where
------------------------------------------------------------------
-- want = { key, id, index, level, story, cf (ground CFrame) | walker = true, prop = { name, cf } }
local function planCasino(st, levels, machines, allowed: number)
	st.taken = {}
	st.circles = {}
	st.byStory = {}
	local frame = st.frame
	for _, rec in machines do
		rec.lcf = frame:ToObjectSpace(rec.pivot)
		local p = rec.lcf.Position
		st.circles[rec.story] = st.circles[rec.story] or {}
		table.insert(st.circles[rec.story], { x = p.X, z = p.Z, r = rec.r, rec = rec })
		st.byStory[rec.story] = st.byStory[rec.story] or {}
		table.insert(st.byStory[rec.story], rec)
	end

	local wants = {}
	local function want(id: string, index: number, story: number, cf: CFrame?, extra)
		if #wants >= allowed then return false end
		local w = { key = id .. "#" .. index, id = id, index = index, level = levels[id], story = story, cf = cf }
		if extra then
			for k, v in extra do w[k] = v end
		end
		table.insert(wants, w)
		return true
	end
	local function teamOf(id: string): number
		return Config.staffTeam(Config.getStaffDef(id), levels[id])
	end
	local D, W = st.D, st.W
	local z0 = -D / 2 -- the casino's street edge

	-- inside spots near the door / the elevator (higher levels add people there)
	local function insideSpot(x: number, z: number, look: Vector3)
		local px, pz = spiral(st, 1, x, z, 0.8, 6)
		if not px then return nil end
		take(st, 1, px, pz, 0.9)
		return groundCF(st, 1, px, pz, facing(look))
	end

	-- ENTRANCE: greeters left of the ropes, security right (outside, on the walk)
	local outsideY = st.outsideY
	local function outside(x: number, z: number, look: Vector3): CFrame
		return frame * CFrame.new(x, outsideY, z) * facing(look)
	end
	local greeters, guards = teamOf("greeter"), teamOf("security")
	if greeters > 0 then
		want("greeter", 1, 1, outside(-6.6, z0 - 3.6, Vector3.new(0.34, 0, -0.94)))
		if greeters > 1 then
			local cf = insideSpot(-7.5, z0 + 3.5, Vector3.new(0.2, 0, -1))
			if cf then want("greeter", 2, 1, cf) end
		end
	end
	if guards > 0 then
		want("security", 1, 1, outside(6.6, z0 - 3.6, Vector3.new(-0.34, 0, -0.94)))
		if guards > 1 then
			local cf = insideSpot(7.5, z0 + 3.5, Vector3.new(-0.3, 0, 1))
			if cf then want("security", 2, 1, cf) end
		end
		if guards > 2 then
			local cf = insideSpot(ELEV.x - ELEV.size / 2 - 3, ELEV.z - ELEV.size / 2 - 7, Vector3.new(-0.7, 0, -1))
			if cf then want("security", 3, 1, cf) end
		end
	end

	-- CURB: the valet by his podium at the taxi bay
	local valets = teamOf("valet")
	for i = 1, valets do
		local sx = i == 1 and 1 or -1
		local cf = outside(sx * 9.8, z0 - 9.6, Vector3.new(0, 0, -1))
		local podium = i == 1 and { name = "ValetPodium", cf = outside(sx * 11.7, z0 - 9.2, Vector3.new(0, 0, -1)) } or nil
		want("valet", i, 1, cf, { prop = podium })
	end

	-- TABLES: dealers behind the best tables first (a host beside each big wheel)
	local dealers = teamOf("dealer")
	if dealers > 0 then
		local tables = {}
		for _, rec in machines do
			if isTable(rec) or isWheel(rec) then table.insert(tables, rec) end
		end
		table.sort(tables, function(a, b)
			if a.story ~= b.story then return a.story < b.story end
			return a.cost > b.cost
		end)
		local n = 0
		for _, rec in tables do
			if n >= dealers then break end
			local sx, sz = rec.size.X, rec.size.Z
			local cands
			if isWheel(rec) then
				cands = { { sx / 2 + 1.0, -sz / 2 + 0.4, Vector3.new(-0.5, 0, -1) },
					{ -(sx / 2 + 1.0), -sz / 2 + 0.4, Vector3.new(0.5, 0, -1) } }
			else
				cands = { { 0, sz / 2 + 0.95, Vector3.new(0, 0, -1) },
					{ sx * 0.25, sz / 2 + 0.95, Vector3.new(0, 0, -1) }, { -sx * 0.25, sz / 2 + 0.95, Vector3.new(0, 0, -1) },
					{ sx / 2 + 0.95, 0, Vector3.new(-1, 0, 0) }, { -(sx / 2 + 0.95), 0, Vector3.new(1, 0, 0) } }
			end
			local x, z, rot = spotBy(st, rec, cands, 0.7)
			if x then
				take(st, rec.story, x, z, 0.8)
				n += 1
				want("dealer", n, rec.story, groundCF(st, rec.story, x, z, rot))
			end
		end
		if n == 0 then
			-- no tables yet: the dealer waits by your priciest game
			local best
			for _, rec in machines do
				if rec.kind ~= "concession" and (not best or rec.cost > best.cost) then best = rec end
			end
			local x, z, rot
			if best then
				x, z, rot = spotBy(st, best, { { best.size.X / 2 + 1.0, -best.size.Z / 2 + 0.3, Vector3.new(-0.4, 0, -1) },
					{ -(best.size.X / 2 + 1.0), -best.size.Z / 2 + 0.3, Vector3.new(0.4, 0, -1) } }, 0.7)
				if x then
					take(st, best.story, x, z, 0.8)
					want("dealer", 1, best.story, groundCF(st, best.story, x, z, rot))
				end
			end
			if not x then
				local cf = insideSpot(-13, z0 + 6, Vector3.new(0, 0, -1))
				if cf then want("dealer", 1, 1, cf) end
			end
		end
	end

	-- STANDS: bartenders behind the counters (best sellers first)
	local barkeeps = teamOf("bartender")
	if barkeeps > 0 then
		local counters = {}
		for _, rec in machines do
			if rec.kind == "concession" and COUNTER_TYPES[rec.gameType] then table.insert(counters, rec) end
		end
		table.sort(counters, function(a, b) return a.cost > b.cost end)
		local n = 0
		for _, rec in counters do
			if n >= barkeeps then break end
			local sx, sz = rec.size.X, rec.size.Z
			local x, z, rot = spotBy(st, rec, { { 0, sz / 2 + 0.85, Vector3.new(0, 0, -1) },
				{ sx * 0.3, sz / 2 + 0.85, Vector3.new(0, 0, -1) }, { -sx * 0.3, sz / 2 + 0.85, Vector3.new(0, 0, -1) },
				{ sx / 2 + 0.9, 0, Vector3.new(-1, 0, 0) }, { -(sx / 2 + 0.9), 0, Vector3.new(1, 0, 0) } }, 0.7)
			if x then
				take(st, rec.story, x, z, 0.8)
				n += 1
				want("bartender", n, rec.story, groundCF(st, rec.story, x, z, rot))
			end
		end
		if n == 0 then
			local cf = insideSpot(-12, z0 + 9, Vector3.new(0.5, 0, -1))
			if cf then want("bartender", 1, 1, cf) end
		end
	end

	-- VIP: the host beside your priciest machine
	if teamOf("host") > 0 then
		local best
		for _, rec in machines do
			if rec.kind ~= "concession" and (not best or rec.cost > best.cost) then best = rec end
		end
		local x, z, rot, story
		if best then
			local sx, sz = best.size.X, best.size.Z
			x, z, rot = spotBy(st, best, { { -(sx / 2 + 1.1), -sz / 2 + 0.2, Vector3.new(0.6, 0, -1) },
				{ sx / 2 + 1.1, -sz / 2 + 0.2, Vector3.new(-0.6, 0, -1) },
				{ -(sx / 2 + 1.1), sz * 0.25, Vector3.new(0.3, 0, -1) }, { sx / 2 + 1.1, sz * 0.25, Vector3.new(-0.3, 0, -1) } }, 0.7)
			story = best.story
		end
		if x then
			take(st, story, x, z, 0.8)
			want("host", 1, story, groundCF(st, story, x, z, rot))
		else
			local cf = insideSpot(12, z0 + 7, Vector3.new(-0.4, 0, -1))
			if cf then want("host", 1, 1, cf) end
		end
	end

	-- PIT: the pit boss in the middle of the tables (the floor with the most)
	if teamOf("pit_boss") > 0 then
		local count, sums = {}, {}
		for _, rec in machines do
			if isTable(rec) then
				local p = rec.lcf.Position
				count[rec.story] = (count[rec.story] or 0) + 1
				local s = sums[rec.story] or { x = 0, z = 0 }
				s.x += p.X
				s.z += p.Z
				sums[rec.story] = s
			end
		end
		local story, best = 1, 0
		for s, n in count do
			if n > best then story, best = s, n end
		end
		local cx, cz
		if best > 0 then
			cx, cz = sums[story].x / best, sums[story].z / best
		else
			cx, cz = 14, z0 + 14 -- no tables yet: off the aisle from the door
		end
		local x, z = spiral(st, story, cx, cz, 0.8, 16)
		if x then
			-- facing the nearest table
			local look = Vector3.new(0, 0, -1)
			local nearest = math.huge
			for _, c in (st.circles[story] or {}) do
				if isTable(c.rec) then
					local d = (Vector3.new(c.x - x, 0, c.z - z)).Magnitude
					if d < nearest then
						nearest = d
						look = Vector3.new(c.x - x, 0, c.z - z)
					end
				end
			end
			take(st, story, x, z, 0.9)
			want("pit_boss", 1, story, groundCF(st, story, x, z, facing(look)))
		end
	end

	-- STAGE: the entertainer's stage against the back wall (else a side wall)
	local acts = teamOf("entertainer")
	if acts > 0 then
		local stageCF, stageStory
		for story = 1, st.stories do
			local zb = D / 2 - 4.6
			local xs = { 0 }
			for k = 1, 12 do
				local dx = k * 3
				if dx > W / 2 - 5 then break end
				table.insert(xs, -dx)
				table.insert(xs, dx)
			end
			for _, x in xs do
				if isFree(st, story, x, zb, 3.9) then
					stageCF, stageStory = groundCF(st, story, x, zb), story
					break
				end
			end
			if not stageCF then
				for _, side in { -1, 1 } do
					local xw = side * (W / 2 - 4.6)
					for k = 0, 8 do
						local z = (k % 2 == 0 and 1 or -1) * math.floor((k + 1) / 2) * 3
						if isFree(st, story, xw, z, 3.9) then
							stageCF = groundCF(st, story, xw, z, CFrame.Angles(0, math.rad(side < 0 and -90 or 90), 0))
							stageStory = story
							break
						end
					end
					if stageCF then break end
				end
			end
			if stageCF then break end
		end
		if stageCF then
			local p = st.frame:PointToObjectSpace(stageCF.Position)
			take(st, stageStory, p.X, p.Z, 4.0)
			want("entertainer", 1, stageStory, stageCF * CFrame.new(-1.0, 0.64, 0.1),
				{ prop = { name = "Stage", cf = stageCF }, dance = true })
			if acts > 1 then
				want("entertainer", 2, stageStory, stageCF * CFrame.new(1.5, 0.64, 0.7) * CFrame.Angles(0, math.rad(-12), 0),
					{ dance = true })
			end
		else
			local cf = insideSpot(-14, z0 + 12, Vector3.new(0, 0, -1))
			if cf then want("entertainer", 1, 1, cf, { dance = true }) end
		end
	end

	-- WALKERS: the floor manager, technicians (the floors with the most slots), janitors
	if teamOf("floor_manager") > 0 then want("floor_manager", 1, 1, nil, { walker = true }) end
	local techs = teamOf("technician")
	if techs > 0 then
		local floors = {}
		for s = 1, st.stories do
			local n = 0
			for _, rec in (st.byStory[s] or {}) do
				if isSlotLike(rec) then n += 1 end
			end
			table.insert(floors, { s = s, n = n })
		end
		table.sort(floors, function(a, b) return a.n > b.n or (a.n == b.n and a.s < b.s) end)
		for i = 1, techs do
			local f = floors[(i - 1) % #floors + 1]
			want("technician", i, f and f.s or 1, nil, { walker = true })
		end
	end
	local sweepers = teamOf("janitor")
	for i = 1, sweepers do
		want("janitor", i, ((i - 1) % st.stories) + 1, nil, { walker = true })
	end
	return wants
end

------------------------------------------------------------------
-- casinos
------------------------------------------------------------------
local function teardown(st)
	st.alive = false
	for _, person in st.people do destroyPerson(st, person) end
	for _, prop in st.props do prop:Destroy() end
	table.clear(st.props)
	if st.folder then st.folder:Destroy() end
	casinos[st.plot] = nil
end

-- the sidewalk height out front (plot-local y), from a ray at the door
local function outsideHeight(st): number
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local ignore = { st.folder }
	for _, p in Players:GetPlayers() do
		if p.Character then table.insert(ignore, p.Character) end
	end
	params.FilterDescendantsInstances = ignore
	params.IgnoreWater = true
	local probe = st.frame * CFrame.new(-6.6, 12, -st.D / 2 - 3.6)
	local hit = Workspace:Raycast(probe.Position, Vector3.new(0, -30, 0), params)
	if hit then
		local y = st.frame:PointToObjectSpace(hit.Position).Y
		if y > -3 and y < 4 then return y end
	end
	return 0.8
end

local function newCasino(plot: Model, ownerId: number)
	local base = plot:FindFirstChild("Base")
	local folder = Instance.new("Folder")
	folder.Name = "Staff_" .. tostring(ownerId)
	folder.Parent = root
	local st = {
		plot = plot, ownerId = ownerId, alive = true, folder = folder,
		people = {}, props = {}, sig = nil, prevLevels = nil,
		frame = base.CFrame * CFrame.new(0, -base.Size.Y / 2, 0),
		W = base.Size.X, D = base.Size.Z, stories = 1,
		taken = {}, circles = {}, byStory = {},
	}
	st.outsideY = outsideHeight(st)
	casinos[plot] = st
	-- one thread per casino for the little gestures (waves, points, dance changes)
	task.spawn(function()
		while st.alive do
			task.wait(1.5)
			local cam = Workspace.CurrentCamera
			local camPos = cam and cam.CFrame.Position
			local now = os.clock()
			for _, person in st.people do
				if person.dead or person.walker or not camPos then continue end
				if now < person.nextGesture then continue end
				if (camPos - person.root.Position).Magnitude > GESTURE_RANGE then
					person.nextGesture = now + 6
					continue
				end
				if person.dance then
					local pick = ({ "dance1", "dance2", "dance3" })[rng:NextInteger(1, 3)]
					if person.danceTrack ~= pick then
						if person.danceTrack then stop(person, person.danceTrack, 0.4) end
						person.danceTrack = pick
						play(person, pick, { fade = 0.4 })
					end
					person.nextGesture = now + rng:NextNumber(9, 16)
				else
					local list = GESTURES[person.id] or {}
					if #list > 0 then play(person, list[rng:NextInteger(1, #list)]) end
					person.nextGesture = now + rng:NextNumber(7, 16)
				end
			end
		end
	end)
	return st
end

local function layoutSignature(roster: string, stories: number, machines, allowed: number): string
	local parts = { roster, tostring(stories), tostring(allowed) }
	for _, rec in machines or {} do
		local p = rec.pivot.Position
		local _, yaw = rec.pivot:ToOrientation()
		table.insert(parts, ("%s@%d,%d,%d,%d"):format(rec.placedId, math.floor(p.X * 2 + 0.5), math.floor(p.Y + 0.5),
			math.floor(p.Z * 2 + 0.5), math.floor(math.deg(yaw) + 0.5)))
	end
	return table.concat(parts, ";")
end

local function sync(st, levels, machines, allowed: number)
	local wants = planCasino(st, levels, machines, allowed)
	local wanted = {}
	for _, w in wants do wanted[w.key] = w end
	-- gone: not on the roster / no room any more / a walker whose floor is gone
	for key, person in st.people do
		local w = wanted[key]
		if not w or (person.walker and person.story ~= w.story) then destroyPerson(st, person) end
	end
	for key, prop in st.props do
		local w = wanted[key]
		if not (w and w.prop and w.prop.name == prop.Name) then
			prop:Destroy()
			st.props[key] = nil
		end
	end
	local fresh = {}
	for _, w in wants do
		local person = st.people[w.key]
		local cf = w.cf
		if not cf then
			-- a walker starts somewhere free on its floor
			local x, z = randomFree(st, w.story, 0.8)
			cf = groundCF(st, w.story, x or 0, z or (-st.D / 2 + 6))
		end
		if person then
			if person.borrowed then
				person.home = cf * CFrame.new(0, person.lift, 0) -- (escorting: their post moved)
			elseif not person.walker then
				placePerson(person, cf, w.story)
			end
			if person.level ~= w.level then
				person.level = w.level
				setTagLevel(person, w.level)
			end
		else
			person = spawnPerson(st, w.key, w.id, w.index, w.level or 1, w.story, cf)
			if person then
				person.walker = w.walker == true
				person.dance = w.dance == true
				if person.walker then task.spawn(walkerLoop, st, person) end
				if person.dance then person.nextGesture = os.clock() + rng:NextNumber(0.2, 1.5) end
				table.insert(fresh, person)
			end
		end
		if w.prop then
			local prop = st.props[w.key]
			if prop then
				prop:PivotTo(w.prop.cf)
				prop:SetAttribute("Story", w.story)
			else
				st.props[w.key] = spawnProp(st, w.prop.name, w.prop.cf, w.story)
			end
		end
	end
	-- a hire / promotion in your own casino: the people it adds pop in (not the
	-- ones that just came into view or whose look arrived late)
	local prev = st.prevLevels
	if prev and st.ownerId == player.UserId then
		for _, person in fresh do
			if (levels[person.id] or 0) > (prev[person.id] or 0) then hireFx(person) end
		end
	end
	st.prevLevels = levels
end

------------------------------------------------------------------
-- the planner tick
------------------------------------------------------------------
local function step()
	local plots = Workspace:FindFirstChild("Plots")
	local cam = Workspace.CurrentCamera
	if not (plots and cam and templates) then return end
	local camPos = cam.CFrame.Position
	local list = {}
	for _, plot in plots:GetChildren() do
		local ownerId = plot:GetAttribute("OwnerId")
		local roster = plot:GetAttribute("StaffRoster")
		local base = plot:FindFirstChild("Base")
		if type(ownerId) == "number" and type(roster) == "string" and roster ~= "" and base and base:IsA("BasePart") then
			local st = casinos[plot]
			local range = st and RANGE + 40 or RANGE
			local d = (flat(base.Position) - flat(camPos)).Magnitude - math.max(base.Size.X, base.Size.Z) / 2
			if d <= range then
				table.insert(list, { plot = plot, d = d, own = ownerId == player.UserId, ownerId = ownerId, roster = roster })
			end
		end
	end
	table.sort(list, function(a, b)
		if a.own ~= b.own then return a.own end
		return a.d < b.d
	end)
	local keep, owners = {}, {}
	for i, c in list do
		if i > MAX_CASINOS then break end
		keep[c.plot] = c
		owners[c.ownerId] = true
	end
	for plot, st in casinos do
		local c = keep[plot]
		if not c or c.ownerId ~= st.ownerId then teardown(st) end
	end
	local machinesBy = gatherMachines(owners)
	local budget = MAX_RIGS
	for i, c in list do
		if i > MAX_CASINOS then break end
		local st = casinos[c.plot] or newCasino(c.plot, c.ownerId)
		local allowed = math.max(0, math.min(c.own and MAX_OWN or MAX_PER_CASINO, budget))
		local building = c.plot:FindFirstChild("Building")
		st.stories = building and building:GetAttribute("Stories") or 1
		local machines = machinesBy[c.ownerId] or {}
		local sig = layoutSignature(c.roster, st.stories, machines, allowed)
		if sig ~= st.sig then
			st.sig = sig
			local ok, err = pcall(sync, st, parseRoster(c.roster), machines, allowed)
			if not ok then warn("[StaffClient] " .. tostring(err)) end
		end
		local mine = 0
		for _ in st.people do mine += 1 end
		budget -= mine
	end
end

------------------------------------------------------------------
-- a guard on loan (CheatersUI: Security walks a caught cheater out)
------------------------------------------------------------------
-- The security guard of `ownerId`'s casino nearest to `near` (world), for a scripted
-- walk; nil when that casino has no free guard on this client. Handle: { rig, root,
-- lift, frame (the plot's floor CFrame), W, D (plot size), home() (their post: a pivot
-- CFrame), play(name, opts), stop(name, fade), alive(), release() }. While on loan the
-- planner leaves them alone (a re-plan only moves their post); release() stands them
-- back on it.
function StaffClient.borrowGuard(ownerId: number, near: Vector3)
	local st = nil
	for _, s in casinos do
		if s.ownerId == ownerId and s.alive then
			st = s
			break
		end
	end
	if not st then return nil end
	local person, best = nil, math.huge
	for _, p in st.people do
		if p.id == "security" and not p.dead and not p.borrowed and p.root then
			local d = (p.root.Position - near).Magnitude
			if d < best then person, best = p, d end
		end
	end
	if not person then return nil end
	if person.tween then
		person.tween:Cancel()
		person.tween = nil
	end
	person.borrowed = true
	person.home = person.rig:GetPivot()
	local handle = { rig = person.rig, root = person.root, lift = person.lift, frame = st.frame, W = st.W, D = st.D }
	function handle.home(): CFrame return person.home end
	function handle.alive(): boolean return person.borrowed == true and not person.dead and st.alive end
	function handle.play(name: string, opts) return play(person, name, opts) end
	function handle.stop(name: string, fade: number?) stop(person, name, fade) end
	function handle.release()
		if not person.borrowed then return end
		person.borrowed = nil
		if person.dead then return end
		stop(person, "walk", 0.2)
		if person.home then person.rig:PivotTo(person.home) end
		play(person, "idle", { fade = 0.2 })
	end
	return handle
end

-- (headless tests drive one planner tick without the loop)
StaffClient._debug = {
	step = function() step() end,
	casinos = casinos,
	setup = function(templateFolder, rootFolder)
		templates = templateFolder
		root = rootFolder
	end,
}

function StaffClient.start(_deps)
	root = Workspace:FindFirstChild("CasinoStaffLocal")
	if not root then
		root = Instance.new("Folder")
		root.Name = "CasinoStaffLocal"
		root.Parent = Workspace
	end
	task.spawn(function()
		templates = ReplicatedStorage:WaitForChild("StaffTemplates", 60)
		if not templates then
			warn("[StaffClient] no StaffTemplates: staff stay invisible")
			return
		end
		-- a role whose look lands later re-plans the casinos (its people appear)
		templates.ChildAdded:Connect(function()
			for _, st in casinos do st.sig = nil end
		end)
		while true do
			local ok, err = pcall(step)
			if not ok then warn("[StaffClient] " .. tostring(err)) end
			task.wait(1)
		end
	end)
end

return StaffClient
