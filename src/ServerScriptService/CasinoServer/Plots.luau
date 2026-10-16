--!nonstrict
-- Plots.luau — discovers existing plot models in the world and assigns them to
-- players. The user builds their own plot objects (anywhere in workspace) — we
-- don't generate buildings. A plot is any Model whose name starts with "Plot"
-- inside workspace, or any child of a folder/model named "Plots".
--
-- Each plot model SHOULD contain:
--   * a BasePart named "Base"   — defines the plot's floor (size/center/Y)
--   * (optional) a BasePart or Attachment named "Entrance" — spawn/exit point
--   * (optional) a BillboardGui named "OwnerSign" with a TextLabel — gets the
--     owner's name written to it
--
-- If "Base" is missing we fall back to the model's PrimaryPart, then to the
-- largest BasePart in the model. If "Entrance" is missing we place it just
-- outside the +Z edge of the base.

local Workspace = game:GetService("Workspace")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Config = require(Common:WaitForChild("Config"))

local Plots = {}

local plots = {}                          -- index -> record
local playerToPlot: {[number]: number} = {}

-- Kept for backwards compat (NPCs reference it as a fallback). It auto-updates
-- to the average of all discovered plot centers once start() runs.
Plots.PlazaCenter = Vector3.new(0, 5, 0)

local function findBase(inst: Instance): BasePart?
	if inst:IsA("BasePart") then return inst end
	local named = inst:FindFirstChild("Base")
	if named and named:IsA("BasePart") then return named end
	if inst:IsA("Model") and inst.PrimaryPart then return inst.PrimaryPart end
	local biggest, biggestVol = nil, -1
	for _, d in inst:GetDescendants() do
		if d:IsA("BasePart") then
			local v = d.Size.X * d.Size.Y * d.Size.Z
			if v > biggestVol then biggest, biggestVol = d, v end
		end
	end
	return biggest
end

local function findEntrancePos(inst: Instance, base: BasePart): Vector3
	if not inst:IsA("BasePart") then
		local e = inst:FindFirstChild("Entrance", true)
		if e then
			if e:IsA("BasePart") then return e.Position end
			if e:IsA("Attachment") then return e.WorldPosition end
		end
	end
	-- default: 6 studs above +Z edge of the base
	local top = base.Position + Vector3.new(0, base.Size.Y/2 + 4, 0)
	return top + base.CFrame.LookVector * (base.Size.Z/2 + 6)
end

-- every BillboardGui/SurfaceGui named "OwnerSign" in the plot (the Strip's
-- casino pylon has one on each face); writes go to its "OwnerText" label
local function findSignLabels(inst: Instance): {TextLabel}
	local out = {}
	if inst:IsA("BasePart") then return out end
	for _, d in inst:GetDescendants() do
		if d.Name == "OwnerSign" and (d:IsA("BillboardGui") or d:IsA("SurfaceGui")) then
			local label = d:FindFirstChild("OwnerText", true) or d:FindFirstChildWhichIsA("TextLabel", true)
			if label and label:IsA("TextLabel") then table.insert(out, label) end
		end
	end
	return out
end

local function setSign(rec, text: string)
	for _, label in rec.signLabels or {} do label.Text = text end
end

-- the building (Buildings.luau) writes the casino name through this
function Plots.setSignText(rec, text: string)
	setSign(rec, text)
end

-- optional hooks, set by Buildings.start: rebuild a plot's building when it
-- gets an owner / is freed again
Plots.onAssigned = nil :: ((any) -> ())?
Plots.onReleased = nil :: ((any) -> ())?

------------------------------------------------------------------
-- neon rim + corner glow for BARE plots (no casino building): warm stone
-- while a plot is open, champagne gold once it's someone's casino. Built from
-- code each boot so it survives the physical map drifting out of Rojo.
-- Strip plots (they carry a "Frontage") get no rim: Buildings.luau builds the
-- casino, its entrance and its night lighting there, and a neon rim would
-- only read as a glowing baseboard through the doorway.
------------------------------------------------------------------
local TRIM_FREE = Color3.fromRGB(130, 112, 92)
local TRIM_OWNED = Color3.fromRGB(255, 196, 90)

local function buildTrim(rec)
	local base = rec.base
	-- clear leftovers first: the map contains some duplicate stacked plot
	-- parts, and two records sharing one base must not double the rim
	for _, child in base:GetChildren() do
		if child.Name == "PlotTrim" or child.Name == "PlotGlow" then child:Destroy() end
	end
	rec.trims = {}
	rec.trimLights = {}
	if rec.model:FindFirstChild("Frontage") then return end

	local sx, sy, sz = base.Size.X, base.Size.Y, base.Size.Z
	local specs = {
		{ Vector3.new(0, sy / 2 + 0.15, sz / 2), Vector3.new(sx + 0.4, 0.3, 0.4) },
		{ Vector3.new(0, sy / 2 + 0.15, -sz / 2), Vector3.new(sx + 0.4, 0.3, 0.4) },
		{ Vector3.new(sx / 2, sy / 2 + 0.15, 0), Vector3.new(0.4, 0.3, sz + 0.4) },
		{ Vector3.new(-sx / 2, sy / 2 + 0.15, 0), Vector3.new(0.4, 0.3, sz + 0.4) },
	}
	for _, spec in specs do
		local p = Instance.new("Part")
		p.Name = "PlotTrim"
		p.Anchored = true
		-- invisible to physics AND raycasts so placement ghosts never snag on it
		p.CanCollide = false; p.CanQuery = false; p.CanTouch = false
		p.Material = Enum.Material.Neon
		p.Color = TRIM_FREE
		p.Size = spec[2]
		p.CFrame = base.CFrame * CFrame.new(spec[1])
		p.Parent = base
		table.insert(rec.trims, p)
	end

	-- corner spill so the rim actually lights the carpet after dark
	for _, cx in { -sx / 2 + 2, sx / 2 - 2 } do
		for _, cz in { -sz / 2 + 2, sz / 2 - 2 } do
			local a = Instance.new("Attachment")
			a.Name = "PlotGlow"
			a.CFrame = CFrame.new(cx, sy / 2 + 2, cz)
			a.Parent = base
			local l = Instance.new("PointLight")
			l.Color = TRIM_FREE
			l.Brightness = 0.7
			l.Range = 16
			l.Shadows = false
			l.Parent = a
			table.insert(rec.trimLights, l)
		end
	end
end

local function setTrimState(rec, owned: boolean)
	local color = owned and TRIM_OWNED or TRIM_FREE
	for _, p in rec.trims or {} do p.Color = color end
	for _, l in rec.trimLights or {} do
		l.Color = color
		l.Brightness = owned and 1.6 or 0.7
	end
end

local function isPlotCandidate(inst: Instance): boolean
	return inst:IsA("Model") or inst:IsA("Folder") or inst:IsA("BasePart")
end

-- a plot's place in the assignment order: its PlotIndex attribute (MapBuilder
-- numbers them in CityLayout.Plots order, nearest the plaza first), else the
-- number in its name
local function plotOrder(inst: Instance): number
	local idx = inst:GetAttribute("PlotIndex")
	if type(idx) == "number" then return idx end
	return tonumber(string.match(inst.Name, "%d+")) or math.huge
end

local function collectPlotModels(): {Instance}
	local out = {}
	local folder = Workspace:FindFirstChild("Plots")
	if folder then
		for _, child in folder:GetChildren() do
			if isPlotCandidate(child) then table.insert(out, child) end
		end
	end
	if #out == 0 then
		for _, child in Workspace:GetChildren() do
			if isPlotCandidate(child)
				and string.sub(child.Name, 1, 4):lower() == "plot" then
				table.insert(out, child)
			end
		end
	end
	-- the middle of town fills up first, whatever order the instances load in
	table.sort(out, function(a, b)
		local ia, ib = plotOrder(a), plotOrder(b)
		if ia ~= ib then return ia < ib end
		return a.Name < b.Name
	end)
	return out
end

local function buildRecord(inst: Instance)
	local base = findBase(inst)
	if not base then
		warn("[Plots] plot '" .. inst:GetFullName() .. "' has no BasePart; skipping.")
		return nil
	end
	local center = base.Position
	local size = base.Size
	local entrance = findEntrancePos(inst, base)
	local signLabels = findSignLabels(inst)
	if inst:IsA("Model") and not inst.PrimaryPart then
		inst.PrimaryPart = base
	end
	return {
		model = inst, base = base, center = center, size = size,
		surfaceY = center.Y + size.Y/2,
		entrance = entrance, signLabels = signLabels,
		ownerId = nil, machines = {},
	}
end

-- Called by init.server after the profile is loaded. Returns the plot record.
function Plots.assign(player: Player)
	for i, rec in plots do
		if rec.ownerId == nil then
			rec.ownerId = player.UserId
			playerToPlot[player.UserId] = i
			rec.model:SetAttribute("OwnerId", player.UserId)
			setSign(rec, player.DisplayName .. "'s Casino")
			setTrimState(rec, true)
			if Plots.onAssigned then
				local ok, err = pcall(Plots.onAssigned, rec)
				if not ok then warn("[Plots] onAssigned: " .. tostring(err)) end
			end
			task.defer(function()
				local char = player.Character or player.CharacterAdded:Wait()
				local root = char:WaitForChild("HumanoidRootPart", 5)
				if root then root.CFrame = CFrame.new(rec.entrance + Vector3.new(0, 5, 0)) end
			end)
			return rec
		end
	end
	warn("[Plots] No free plot for " .. player.Name)
	return nil
end

function Plots.release(player: Player)
	local idx = playerToPlot[player.UserId]
	if not idx then return end
	local rec = plots[idx]
	for _, m in rec.machines do if m and m.Parent then m:Destroy() end end
	rec.machines = {}
	rec.ownerId = nil
	rec.model:SetAttribute("OwnerId", nil)
	setSign(rec, "Open Plot")
	setTrimState(rec, false)
	playerToPlot[player.UserId] = nil
	if Plots.onReleased then
		local ok, err = pcall(Plots.onReleased, rec)
		if not ok then warn("[Plots] onReleased: " .. tostring(err)) end
	end
end

function Plots.allRecords()
	return plots
end

-- Public helpers ------------------------------------------------

function Plots.getRecordForOwner(userId: number)
	local idx = playerToPlot[userId]
	return idx and plots[idx] or nil
end

function Plots.getOwnedPlotsWithMachines()
	local out = {}
	for _, rec in plots do
		if rec.ownerId and #rec.machines > 0 then table.insert(out, rec) end
	end
	return out
end

-- plot-relative <-> world CFrame
function Plots.relativeFromWorld(userId: number, worldCF: CFrame): CFrame?
	local rec = Plots.getRecordForOwner(userId)
	if not rec then return nil end
	return rec.base.CFrame:ToObjectSpace(worldCF)
end
function Plots.worldFromRelative(userId: number, relCF: CFrame): CFrame?
	local rec = Plots.getRecordForOwner(userId)
	if not rec then return nil end
	return rec.base.CFrame:ToWorldSpace(relCF)
end

function Plots.isInsideOwnerPlot(userId: number, pos: Vector3): boolean
	local rec = Plots.getRecordForOwner(userId)
	if not rec then return false end
	local half = (rec.size / 2) - Vector3.new(Config.PlacementMargin, 0, Config.PlacementMargin)
	local rel = rec.base.CFrame:PointToObjectSpace(pos)
	return math.abs(rel.X) <= half.X and math.abs(rel.Z) <= half.Z
end

function Plots.tooCloseToMachine(userId: number, pos: Vector3, ignore: Instance?): boolean
	local rec = Plots.getRecordForOwner(userId)
	if not rec then return true end
	for _, m in rec.machines do
		if m ~= ignore then
			local part = m.PrimaryPart or m:FindFirstChildWhichIsA("BasePart")
			if part then
				local d = (Vector3.new(part.Position.X, 0, part.Position.Z) - Vector3.new(pos.X, 0, pos.Z)).Magnitude
				if d < Config.MachineSpacing then return true end
			end
		end
	end
	return false
end

-- footprint overlap on the same story: machines are treated as circles
-- (attribute "FootprintRadius", set by Placement) with Config.MachineGap of
-- free floor between them. Machines more than half a story apart don't clash.
function Plots.overlapsMachine(userId: number, pos: Vector3, radius: number, ignore: Instance?): boolean
	local rec = Plots.getRecordForOwner(userId)
	if not rec then return true end
	local halfStory = (Config.Building and Config.Building.StoryHeight or 16) / 2
	for _, m in rec.machines do
		if m ~= ignore and m.Parent then
			local pivot = m:GetPivot().Position
			if math.abs(pivot.Y - pos.Y) < halfStory then
				local r = m:GetAttribute("FootprintRadius") or 2.5
				local d = (Vector3.new(pivot.X, 0, pivot.Z) - Vector3.new(pos.X, 0, pos.Z)).Magnitude
				if d < r + radius + (Config.MachineGap or 1) then return true end
			end
		end
	end
	return false
end

function Plots.surfaceY(userId: number): number
	local rec = Plots.getRecordForOwner(userId)
	return rec and rec.surfaceY or 1
end

function Plots.machineCount(userId: number): number
	local rec = Plots.getRecordForOwner(userId)
	return rec and #rec.machines or 0
end

function Plots.registerMachine(userId: number, machine: Instance)
	local rec = Plots.getRecordForOwner(userId)
	if rec then table.insert(rec.machines, machine) end
end

function Plots.unregisterMachine(userId: number, machine: Instance)
	local rec = Plots.getRecordForOwner(userId)
	if not rec then return end
	for i, m in rec.machines do
		if m == machine then table.remove(rec.machines, i) break end
	end
end

function Plots.start()
	local models = collectPlotModels()
	if #models == 0 then
		warn("[Plots] No plot models found. Add a 'Plots' folder under Workspace "
			.. "(or rename your plot models to start with 'Plot'). Each plot needs a 'Base' part.")
		return
	end
	local sumX, sumY, sumZ, n = 0, 0, 0, 0
	for _, m in models do
		local rec = buildRecord(m)
		if rec then
			table.insert(plots, rec)
			buildTrim(rec)
			sumX += rec.center.X; sumY += rec.center.Y; sumZ += rec.center.Z; n += 1
		end
	end
	if n > 0 then
		Plots.PlazaCenter = Vector3.new(sumX/n, sumY/n + 5, sumZ/n)
	end
	print(("[Plots] Discovered %d plot(s)."):format(#plots))
end

return Plots
