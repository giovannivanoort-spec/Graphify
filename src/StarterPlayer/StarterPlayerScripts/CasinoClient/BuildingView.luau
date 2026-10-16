--!nonstrict
-- BuildingView.luau — cut away the stories above you. When your character is
-- inside a casino building, everything belonging to the stories above yours
-- (walls, floors, the roof, machines, decor, staff and patrons up there) is
-- hidden locally, so the camera has a clear view. Hidden parts get
-- LocalTransparencyModifier 1, which also stops them blocking the camera.
-- Build mode forces a story (BuildingView.setForced, applied on the next
-- frame) so you see the floor you're building on.
-- Night lamps (tag "NightLight") up there are hidden even while they're off,
-- and marked in LightGate so DayNightFX's lamp switch leaves them alone; when
-- the cut is undone they come back as the lamps are now (on after dark).
-- Decor (tag "CasinoDecor") and staff (tag "CasinoStaff", client clones that
-- come and go) are re-checked every tick by position + their Story attribute.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("CasinoCommon"):WaitForChild("Config"))
local LightGate = require(script.Parent:WaitForChild("LightGate"))

local BuildingView = {}

local H = Config.Building.StoryHeight
local player = Players.LocalPlayer

local hidden = {}          -- instance -> saved value
local shownPlot, shownStory = nil, nil -- the cut being shown
local forced = nil         -- { plot = Model, story = number }
local dirty = false        -- a forced story changed: apply it on the next frame
local cutModels = {}       -- decor / staff models hidden by the cut (re-checked every tick)
local MOVING_TAGS = { "CasinoDecor", "CasinoStaff" }

-- a light / beam the day-night lamp switch drives (DayNightFX)
local function isLamp(inst: Instance): boolean
	return (inst:IsA("Light") or inst:IsA("Beam")) and CollectionService:HasTag(inst, "NightLight")
end

-- things someone else already hid (e.g. a machine being moved) are left alone,
-- so restoring never un-hides what isn't ours
local function hide(inst: Instance)
	if hidden[inst] ~= nil then return end
	if inst:IsA("BasePart") or inst:IsA("Decal") or inst:IsA("Texture") then
		if inst.LocalTransparencyModifier >= 1 then return end
		hidden[inst] = inst.LocalTransparencyModifier
		inst.LocalTransparencyModifier = 1
	elseif isLamp(inst) then
		-- off by day too: claim it anyway, or dusk would light it behind the cut
		hidden[inst] = inst.Enabled
		LightGate.setHidden(inst, true)
		inst.Enabled = false
	elseif inst:IsA("SurfaceGui") or inst:IsA("BillboardGui") or inst:IsA("Light") or inst:IsA("ParticleEmitter")
		or inst:IsA("Beam") or inst:IsA("ProximityPrompt") then
		if not inst.Enabled then return end
		hidden[inst] = inst.Enabled
		inst.Enabled = false
	end
end

-- restored even while unparented: a pooled staff rig parked in nil must not come
-- back invisible on another floor
local function unhide(inst: Instance)
	local v = hidden[inst]
	if v == nil then return end
	hidden[inst] = nil
	LightGate.setHidden(inst, false)
	pcall(function()
		if inst:IsA("BasePart") or inst:IsA("Decal") or inst:IsA("Texture") then
			inst.LocalTransparencyModifier = v
		elseif isLamp(inst) then
			inst.Enabled = LightGate.lampsOn() -- as the lamps are now, not as they were
		else
			inst.Enabled = v
		end
	end)
end

local function restoreAll()
	for inst in hidden do unhide(inst) end
	table.clear(hidden)
	table.clear(cutModels)
end

local function hideTree(root: Instance)
	hide(root)
	for _, d in root:GetDescendants() do hide(d) end
end

local function unhideTree(root: Instance)
	unhide(root)
	for _, d in root:GetDescendants() do unhide(d) end
end

-- things that left the world (destroyed staff clones, rebuilt decor) get their
-- saved value back and drop out of the table
local function prune()
	for inst in hidden do
		if inst.Parent == nil then unhide(inst) end
	end
	for m in cutModels do
		if m.Parent == nil then cutModels[m] = nil end
	end
end

-- which plot + story is the local player standing in?
local function locate(): (Model?, number?)
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	local plots = Workspace:FindFirstChild("Plots")
	if not (root and plots) then return nil end
	for _, plot in plots:GetChildren() do
		local base = plot:FindFirstChild("Base")
		local building = plot:FindFirstChild("Building")
		if base and building then
			local rel = base.CFrame:PointToObjectSpace(root.Position)
			if math.abs(rel.X) <= base.Size.X / 2 + 1.5 and math.abs(rel.Z) <= base.Size.Z / 2 + 1.5 then
				local stories = building:GetAttribute("Stories") or 1
				local feet = rel.Y + base.Size.Y / 2 - 3 -- HRP sits ~3 studs above the floor
				if feet > -2 and feet < stories * H + 2 then
					local story = math.clamp(math.floor((feet - 1) / H + 0.25) + 1, 1, stories)
					return plot, story
				end
			end
		end
	end
	return nil
end

local function storyOfModel(m: Instance, base: BasePart): number
	local s = m:GetAttribute("Story")
	if s then return s end
	local y = m:IsA("Model") and m:GetPivot().Position.Y or (m :: BasePart).Position.Y
	local localY = y - (base.Position.Y - base.Size.Y / 2)
	return math.floor((localY - 1) / H + 0.25) + 1
end

local function apply(plot: Model, story: number)
	local building = plot:FindFirstChild("Building")
	local base = plot:FindFirstChild("Base")
	if not (building and base) then return end
	for _, d in building:GetDescendants() do
		local s = d:GetAttribute("Story")
		if s and s > story then hideTree(d) end
	end
	-- machines upstairs (owned by this plot's owner)
	local owner = plot:GetAttribute("OwnerId")
	if owner then
		for _, m in CollectionService:GetTagged("CasinoMachine") do
			if m:GetAttribute("OwnerId") == owner and storyOfModel(m, base) > story then hideTree(m) end
		end
	end
	-- patrons upstairs come and go: re-check them every tick
	for _, npc in CollectionService:GetTagged("CasinoPatron") do
		local root = npc:FindFirstChild("HumanoidRootPart")
		if root then
			local rel = base.CFrame:PointToObjectSpace(root.Position)
			local inside = math.abs(rel.X) <= base.Size.X / 2 + 1 and math.abs(rel.Z) <= base.Size.Z / 2 + 1
			local above = inside and (math.floor((rel.Y + base.Size.Y / 2 - 3 - 1) / H + 0.25) + 1) > story
			if above then
				hideTree(npc)
			else
				unhide(npc)
				for _, d in npc:GetDescendants() do unhide(d) end
			end
		end
	end
	-- decor and staff upstairs: staff clones come and go, decor gets placed and
	-- moved between floors (their Story attribute, else their height)
	for _, tag in MOVING_TAGS do
		for _, m in CollectionService:GetTagged(tag) do
			local pos = (m:IsA("Model") and m:GetPivot().Position) or (m:IsA("BasePart") and m.Position) or nil
			local above = false
			if pos then
				local rel = base.CFrame:PointToObjectSpace(pos)
				above = math.abs(rel.X) <= base.Size.X / 2 + 1 and math.abs(rel.Z) <= base.Size.Z / 2 + 1
					and storyOfModel(m, base) > story
			end
			if above then
				cutModels[m] = true
				hideTree(m)
			elseif cutModels[m] then
				cutModels[m] = nil
				unhideTree(m)
			end
		end
	end
end

-- build mode shows the floor being built on, wherever the player stands
-- (applied on the next frame, so UP / DOWN feel instant)
function BuildingView.setForced(plot: Model?, story: number?)
	local was = forced
	forced = (plot and story) and { plot = plot, story = story } or nil
	if (was and was.plot) ~= plot or (was and was.story) ~= story then dirty = true end
end

function BuildingView.start()
	local acc, sincePrune = 0, 0
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		sincePrune += dt
		if acc < 0.25 and not dirty then return end
		acc = 0
		dirty = false
		if sincePrune > 5 then
			sincePrune = 0
			prune()
		end
		local plot, story
		if forced and forced.plot.Parent then
			plot, story = forced.plot, forced.story
		else
			plot, story = locate()
		end
		if plot ~= shownPlot or story ~= shownStory then
			restoreAll()
			shownPlot, shownStory = plot, story
		end
		if plot then apply(plot, story) end
	end)
end

return BuildingView
