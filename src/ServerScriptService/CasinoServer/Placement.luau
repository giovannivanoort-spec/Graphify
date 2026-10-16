--!nonstrict
-- Placement.luau — builds machines, places them FROM INVENTORY (free move),
-- picks them back up, sells them, and rebuilds the saved layout on join.
-- Buying is handled at the shop (adds to inventory); placing never charges.
-- Copies bought since the economy pass carry `paid` (the price paid) on their
-- inventory item / placed entry; copies without it are pre-patch ("legacy")
-- and refund at most their old price (Config.LegacyCost). Per-machine upgrade
-- levels bought at today's prices are recorded on the placed entry
-- (upgSpent = Cash spent, upgNew = levels per kind) so a refund never pays
-- back more than was spent.

local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local Workspace = game:GetService("Workspace")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Config = require(Common:WaitForChild("Config"))

-- report to GameEvents (quests & co. listen); never in the way of the action
local function gameEvent(player, name: string, amount: number?)
	local m = script.Parent:FindFirstChild("GameEvents")
	if not m then return end
	local ok, GE = pcall(require, m)
	if ok and type(GE) == "table" and GE.emit then pcall(GE.emit, player, name, amount) end
end

local Placement = {}
local Economy, Plots, Inventory, Data, Monetization
local MachineVisuals = require(script.Parent:WaitForChild("MachineVisuals"))
local Buildings = require(script.Parent:WaitForChild("Buildings"))

local STORY_H = Config.Building.StoryHeight

-- machines are treated as circles for spacing: half their longest side
local function footprintRadius(def): number
	return math.max(def.size.X, def.size.Z) * 0.5
end

-- a requested rotation in degrees (anything odd counts as 0)
local function cleanRotation(rotationY: any): number
	local r = tonumber(rotationY) or 0
	if r ~= r or math.abs(r) > 1e6 then return 0 end
	return r
end

-- validate a requested spot; returns the world ground position or nil + why
local function validateSpot(player: Player, def, posX: any, posZ: any, rotationY: number, story: any, ignore: Instance?)
	local rec = Plots.getRecordForOwner(player.UserId)
	if not rec then return nil, "You don't own a casino." end
	posX, posZ = tonumber(posX), tonumber(posZ)
	if not posX or not posZ or posX ~= posX or posZ ~= posZ then return nil, "Bad position." end
	story = math.floor(tonumber(story) or 1)
	if story < 1 or story > Buildings.stories(player) then return nil, "You don't own that floor yet." end
	local y = Plots.surfaceY(player.UserId) + (story - 1) * STORY_H
	local pos = Vector3.new(posX, y, posZ)
	-- the whole footprint, turned the way it'll stand, stays on the carpet and
	-- clear of the building's walls
	local rel = rec.base.CFrame:ToObjectSpace(CFrame.new(pos) * CFrame.Angles(0, math.rad(rotationY), 0))
	local _, yaw = rel:ToOrientation()
	local c, s = math.abs(math.cos(yaw)), math.abs(math.sin(yaw))
	local hx = (c * def.size.X + s * def.size.Z) / 2
	local hz = (s * def.size.X + c * def.size.Z) / 2
	local halfX, halfZ = rec.size.X / 2, rec.size.Z / 2
	if math.abs(rel.X) > halfX or math.abs(rel.Z) > halfZ then
		return nil, "Place it inside your casino."
	end
	local clear = Config.WallClearance or 0.6
	if math.abs(rel.X) + hx > halfX - clear or math.abs(rel.Z) + hz > halfZ - clear then
		return nil, "Too close to the wall."
	end
	local radius = footprintRadius(def)
	if Buildings.blocksElevator(rec, pos, radius) then
		return nil, "Keep the elevator clear."
	end
	if Plots.overlapsMachine(player.UserId, pos, radius, ignore) then
		return nil, "Too close to another machine."
	end
	-- solid decor (Decor.luau sets this hook) blocks machines and their front lane
	if Placement.decorCheck then
		local ran, okDecor, whyDecor = pcall(Placement.decorCheck, player, def, pos, rotationY, ignore)
		if ran and okDecor == false then return nil, whyDecor or "Your decor is in the way." end
	end
	return pos, nil, story
end

local function applyUpgradesToMachine(model: Instance, def, upgrades)
	local u = upgrades or { speed = 0, bets = 0, lucky = 0 }
	model:SetAttribute("SpeedLevel", u.speed)
	model:SetAttribute("BetsLevel", u.bets)
	model:SetAttribute("LuckyLevel", u.lucky)
	-- effective maxBet scales with bets upgrade
	local mult = 1 + (u.bets * (Config.MachineUpgrades.bets.perLevel))
	model:SetAttribute("MaxBet", math.floor((def.maxBet or 0) * mult))
end

local function buildMachine(def, ownerId: number, groundCF: CFrame, placedId: string, upgrades): Model
	local isConc = Config.isConcession(def)

	local model, body
	local topOffset  -- where the name billboard floats above the body

	-- Prefer a hand-built model (e.g. Lucky7) when the def names one; otherwise
	-- fall back to the simple procedural box.
	local custom = MachineVisuals.cloneFor(def)
	if custom then
		model = custom
		model.Name = def.name
		local primary, _ = MachineVisuals.seat(model, groundCF)
		body = primary
		-- float the name tag just above the model's top, wherever the body sits
		local bbCF, bbSize = model:GetBoundingBox()
		topOffset = (bbCF.Position.Y + bbSize.Y / 2) - body.Position.Y + 1.2
		MachineVisuals.initDisplay(model)       -- reels/LEDs idle state
	else
		model = Instance.new("Model")
		model.Name = def.name

		body = Instance.new("Part")
		body.Name = "Body"; body.Anchored = true
		body.Size = def.size
		body.CFrame = groundCF * CFrame.new(0, def.size.Y/2, 0)
		body.Color = def.color; body.Material = Enum.Material.SmoothPlastic
		body.Parent = model
		model.PrimaryPart = body

		local screen = Instance.new("Part")
		screen.Name = "Screen"; screen.Anchored = true
		screen.Size = Vector3.new(def.size.X * 0.8, def.size.Y * 0.35, 0.2)
		screen.CFrame = body.CFrame * CFrame.new(0, def.size.Y * 0.15, -def.size.Z/2 - 0.05)
		-- tinted toward the machine color: pure-white Neon blows out under bloom
		screen.Material = Enum.Material.Neon
		screen.Color = def.color:Lerp(Color3.new(1, 1, 1), 0.55)
		screen.Parent = model
		local weld = Instance.new("WeldConstraint"); weld.Part0 = body; weld.Part1 = screen; weld.Parent = body

		topOffset = def.size.Y/2 + 1.5
	end

	-- night-strip glow: every machine spills its brand color onto the floor
	local glow = Instance.new("PointLight")
	glow.Name = "MachineGlow"
	glow.Color = def.color
	glow.Brightness = 2.2
	glow.Range = 11
	glow.Shadows = false
	glow.Parent = body

	-- name tag in the UI's display style (Luckiest Guy + ink outline)
	local bb = Instance.new("BillboardGui")
	bb.Name = "NameTag"
	bb.Size = UDim2.fromScale(7, 1.4); bb.StudsOffset = Vector3.new(0, topOffset, 0)
	bb.AlwaysOnTop = true; bb.MaxDistance = 90; bb.LightInfluence = 0; bb.Parent = body
	local lbl = Instance.new("TextLabel")
	lbl.Size = UDim2.fromScale(1, 1); lbl.BackgroundTransparency = 1
	lbl.TextScaled = true; lbl.Font = Enum.Font.LuckiestGuy
	lbl.TextColor3 = Color3.fromRGB(255, 243, 168); lbl.Text = string.upper(def.name); lbl.Parent = bb
	local lblStroke = Instance.new("UIStroke")
	lblStroke.Color = Color3.fromRGB(43, 10, 18); lblStroke.Thickness = 3; lblStroke.Parent = lbl

	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = isConc and "Buy" or "Play"; prompt.ObjectText = def.name
	prompt.HoldDuration = 0; prompt.MaxActivationDistance = 12
	prompt.RequiresLineOfSight = false; prompt.Parent = body

	model:SetAttribute("OwnerId", ownerId)
	model:SetAttribute("GameType", def.type)
	model:SetAttribute("MachineId", def.id)
	model:SetAttribute("PlacedId", placedId)
	model:SetAttribute("FootprintRadius", footprintRadius(def))
	local rec = Plots.getRecordForOwner(ownerId)
	local story = rec and Buildings.storyAt(rec, groundCF.Position.Y) or 1
	model:SetAttribute("Story", story)
	-- the VIP floor (VipFloor.luau): Gambling pays x Config.VipFloor.IncomeMult up there
	local owner = game:GetService("Players"):GetPlayerByUserId(ownerId)
	model:SetAttribute("VipFloor", (owner ~= nil and Buildings.vipStory(owner) == story) or nil)
	model:SetAttribute("MinBet", def.minBet)
	model:SetAttribute("MaxBet", def.maxBet)
	model:SetAttribute("BaseCost", def.cost)  -- per-machine upgrade L costs floor(BaseCost x MachineUpgradeCostMult[L])
	model:SetAttribute("Kind", isConc and "concession" or "machine")
	-- rebirth-machine perks (Config MachineDef.perks): Gambling multiplies owner
	-- earnings by IncomeMult; NPCs play PerkSpeed faster and lose PerkTilt more often
	local perks = type(def.perks) == "table" and def.perks or nil
	model:SetAttribute("IncomeMult", perks and tonumber(perks.income) or nil)
	model:SetAttribute("PerkSpeed", perks and tonumber(perks.speed) or nil)
	model:SetAttribute("PerkTilt", perks and tonumber(perks.edge) or nil)
	if isConc then
		model:SetAttribute("RevenuePerVisit", def.revenuePerVisit or 0)
		CollectionService:AddTag(model, "CasinoConcession")
	else
		applyUpgradesToMachine(model, def, upgrades)
	end
	CollectionService:AddTag(model, "CasinoMachine")
	return model
end

-- Place an owned (inventory) machine in the player's casino, on `story`.
function Placement.placeFromInventory(player: Player, itemId: string, posX: number, posZ: number, rotationY: number, story: number?)
	local item = Inventory.find(player, itemId)
	if not item then return { ok = false, message = "Item not in your inventory." } end
	local def = Config.getMachineDef(item.machineId)
	if not def then return { ok = false, message = "Unknown machine." } end
	if not Plots.getRecordForOwner(player.UserId) then
		return { ok = false, message = "You don't own a casino." }
	end
	if Plots.machineCount(player.UserId) >= Buildings.capacity(player) then
		return { ok = false, message = "Your casino is full - buy another floor!" }
	end

	local rot = cleanRotation(rotationY)
	local pos, why = validateSpot(player, def, posX, posZ, rot, story, nil)
	if not pos then return { ok = false, message = why } end

	local placedId = HttpService:GenerateGUID(false)
	local groundCF = CFrame.new(pos) * CFrame.Angles(0, math.rad(rot), 0)
	local upgrades = { speed = 0, bets = 0, lucky = 0 }
	local model = buildMachine(def, player.UserId, groundCF, placedId, upgrades)
	model.Parent = Workspace
	Plots.registerMachine(player.UserId, model)

	-- move from inventory -> placed (persisted); a post-patch copy keeps its price tag
	Inventory.remove(player, itemId)
	local profile = Data.get(player)
	local relCF = Plots.relativeFromWorld(player.UserId, groundCF)
	table.insert(profile.Placed, { placedId = placedId, machineId = def.id, cf = Data.encodeCF(relCF), upgrades = upgrades,
		paid = item.paid })

	gameEvent(player, "machinePlaced", 1)
	return { ok = true, message = "Placed " .. def.name .. "!" }
end

-- x3 machine-boost time left on an entry leaving the floor goes to the stored
-- time (MachineBoost: re-applied from any machine's popup)
local function stashBoost(profile, entry)
	local boost = entry and tonumber(entry.boost) or 0
	if boost > 0 then
		profile.StoredBoostSeconds = math.max(0, tonumber(profile.StoredBoostSeconds) or 0) + boost
	end
	if entry then entry.boost = nil end
end

local function removePlacedEntry(profile, placedId: string)
	for i, entry in profile.Placed do
		if entry.placedId == placedId then
			local copy = entry
			table.remove(profile.Placed, i)
			stashBoost(profile, copy)   -- pickup / sell keep the boost time
			return copy
		end
	end
	return nil
end

local function validateOwnedMachine(player: Player, machine: Instance)
	if typeof(machine) ~= "Instance" or not machine:GetAttribute("GameType") then return false end
	if machine:GetAttribute("OwnerId") ~= player.UserId then return false end
	return true
end

-- Move an already-placed machine to a new spot/rotation/story in the casino.
function Placement.move(player: Player, machine: Instance, posX: number, posZ: number, rotationY: number, story: number?)
	if not validateOwnedMachine(player, machine) then
		return { ok = false, message = "That's not your machine." }
	end
	local def = Config.getMachineDef(machine:GetAttribute("MachineId"))
	if not def then return { ok = false, message = "Unknown machine." } end
	local rec = Plots.getRecordForOwner(player.UserId)
	if not rec then return { ok = false, message = "You don't own a casino." } end

	local rot = cleanRotation(rotationY)
	local pos, why, s = validateSpot(player, def, posX, posZ, rot, story, machine)
	if not pos then return { ok = false, message = why } end

	local body = machine.PrimaryPart or machine:FindFirstChild("Body")
	if not (body and body:IsA("BasePart")) then return { ok = false, message = "Broken machine." } end
	local groundCF = CFrame.new(pos) * CFrame.Angles(0, math.rad(rot), 0)
	if machine:GetAttribute("GroundPivot") then
		machine:PivotTo(groundCF)                    -- pivot = footprint centre on the ground
	else
		local sizeY = body.Size.Y
		machine:PivotTo(groundCF * CFrame.new(0, sizeY/2, 0))
	end
	machine:SetAttribute("Story", s)
	machine:SetAttribute("VipFloor", (Buildings.vipStory(player) == s) or nil) -- (x1.25 on the VIP floor)

	-- persist new relative CFrame
	local profile = Data.get(player)
	local placedId = machine:GetAttribute("PlacedId")
	for _, entry in profile.Placed do
		if entry.placedId == placedId then
			local relCF = Plots.relativeFromWorld(player.UserId, groundCF)
			entry.cf = Data.encodeCF(relCF)
			break
		end
	end
	return { ok = true, message = "Moved." }
end

-- Pick a machine back up: returns it to inventory.
function Placement.pickup(player: Player, machine: Instance)
	if not validateOwnedMachine(player, machine) then
		return { ok = false, message = "That's not your machine." }
	end
	local profile = Data.get(player)
	local placedId = machine:GetAttribute("PlacedId")
	local entry = removePlacedEntry(profile, placedId)
	local machineId = (entry and entry.machineId) or machine:GetAttribute("MachineId")
	local item = Inventory.add(player, machineId)
	if item and entry and entry.paid then item.paid = entry.paid end
	Plots.unregisterMachine(player.UserId, machine)
	machine:Destroy()
	return { ok = true, message = "Returned to inventory." }
end

-- What selling a placed entry pays back (economy_spec 7.2):
--   floor(SellRefund x (machine cost + upgrade spend))
-- A pre-patch copy (no `paid`) counts min(cost, Config.LegacyCost[id]) instead of
-- the cost, and its levels bought before the patch at the old flat prices
-- (Config.MachineUpgradeCosts); levels bought since count what they cost
-- (upgSpent). So old machines whose price went up can't be sold for a profit.
function Placement.refundFor(entry, def): number
	if not (entry and def) then return 0 end
	local base = def.cost or 0
	if entry.paid == nil then
		local old = Config.LegacyCost and Config.LegacyCost[def.id]
		if old then base = math.min(base, old) end
	end
	local spent = tonumber(entry.upgSpent) or 0
	local newLevels = type(entry.upgNew) == "table" and entry.upgNew or {}
	local upgrades = type(entry.upgrades) == "table" and entry.upgrades or {}
	for kind in Config.MachineUpgrades do
		local before = math.max(0, (upgrades[kind] or 0) - (newLevels[kind] or 0))
		for level = 1, before do
			spent += Config.MachineUpgradeCosts[level] or 0
		end
	end
	return math.floor((Config.SellRefund or 0.5) * (base + spent))
end

-- the price of a placed entry's next level of `kind` (nil when maxed / unknown)
function Placement.upgradeCostFor(entry, def, kind: string): number?
	if not (entry and def) or Config.isConcession(def) then return nil end
	local lvl = (type(entry.upgrades) == "table" and entry.upgrades[kind]) or 0
	if lvl >= Config.MachineUpgradeMaxLevel then return nil end
	return Config.machineUpgradeCost(def, lvl + 1)
end

-- Sell a placed machine for a partial refund.
function Placement.sell(player: Player, machine: Instance)
	if not validateOwnedMachine(player, machine) then
		return { ok = false, message = "That's not your machine." }
	end
	local profile = Data.get(player)
	local placedId = machine:GetAttribute("PlacedId")
	local entry = removePlacedEntry(profile, placedId)
	local machineId = (entry and entry.machineId) or machine:GetAttribute("MachineId")
	local def = Config.getMachineDef(machineId)
	-- (no saved entry: the cheapest reading, a pre-patch copy without upgrades)
	local refund = def and Placement.refundFor(entry or { upgrades = {} }, def) or 0
	Economy.addCash(player, refund)
	Plots.unregisterMachine(player.UserId, machine)
	machine:Destroy()
	return { ok = true, message = ("Sold for $%d."):format(refund), refund = refund }
end

-- Rebuild the saved layout when a player joins. A machine saved on a floor the
-- casino doesn't have (the VIP floor without the VIP pass) goes back to the
-- inventory instead.
function Placement.restore(player: Player, profile)
	local rec = Plots.getRecordForOwner(player.UserId)
	local stories = Buildings.stories(player)
	for i = #profile.Placed, 1, -1 do
		local entry = profile.Placed[i]
		local def = Config.getMachineDef(entry.machineId)
		if def then
			local relCF = Data.decodeCF(entry.cf)
			local groundCF = Plots.worldFromRelative(player.UserId, relCF) or CFrame.new()
			if rec and Buildings.storyAt(rec, groundCF.Position.Y) > stories then
				table.remove(profile.Placed, i)
				stashBoost(profile, entry)
				local item = Inventory.add(player, entry.machineId)
				if item and entry.paid then item.paid = entry.paid end
			else
				local model = buildMachine(def, player.UserId, groundCF, entry.placedId, entry.upgrades)
				model.Parent = Workspace
				Plots.registerMachine(player.UserId, model)
			end
		end
	end
end

-- Upgrade a single placed machine (kind = "speed" | "bets" | "lucky").
function Placement.upgradeMachine(player: Player, machine: Instance, kind: string)
	if not validateOwnedMachine(player, machine) then
		return { ok = false, message = "That's not your machine." }
	end
	if machine:GetAttribute("Kind") == "concession" then
		return { ok = false, message = "Concessions can't be upgraded." }
	end
	local spec = Config.MachineUpgrades[kind]
	if not spec then return { ok = false, message = "Unknown upgrade." } end

	local profile = Data.get(player)
	local placedId = machine:GetAttribute("PlacedId")
	local entry
	for _, e in profile.Placed do if e.placedId == placedId then entry = e; break end end
	if not entry then return { ok = false, message = "Machine record missing." } end
	entry.upgrades = entry.upgrades or { speed = 0, bets = 0, lucky = 0 }
	local cur = entry.upgrades[kind] or 0
	if cur >= Config.MachineUpgradeMaxLevel then
		return { ok = false, message = "Max level." }
	end
	local def = Config.getMachineDef(entry.machineId)
	if not def then return { ok = false, message = "Unknown machine." } end
	-- priced on the machine: floor(cost x MachineUpgradeCostMult[level])
	local cost = Config.machineUpgradeCost(def, cur + 1)
	if not cost then return { ok = false, message = "Max level." } end
	if Economy.getCash(player) < cost then
		return { ok = false, message = "Not enough " .. Config.CurrencyName .. "." }
	end
	if not Economy.tryWithdraw(player, cost) then
		return { ok = false, message = "Purchase failed." }
	end
	entry.upgrades[kind] = cur + 1
	-- what this level cost, for the sell refund
	entry.upgSpent = (tonumber(entry.upgSpent) or 0) + cost
	if type(entry.upgNew) ~= "table" then entry.upgNew = {} end
	entry.upgNew[kind] = (entry.upgNew[kind] or 0) + 1
	applyUpgradesToMachine(machine, def, entry.upgrades)
	gameEvent(player, "machineUpgraded", 1)
	return { ok = true, message = ("%s -> L%d"):format(spec.name, cur + 1), cost = cost }
end

-- Copies of every machine model for the client's placement ghost
-- (ReplicatedStorage.MachinePreviews/<machineId>): no sounds, prompts or
-- lights, nothing collidable.
local function publishPreviews()
	local folder = ReplicatedStorage:FindFirstChild("MachinePreviews")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "MachinePreviews"
	end
	for _, def in Config.Catalog do
		if not folder:FindFirstChild(def.id) then
			local ok, m = pcall(MachineVisuals.cloneFor, def)
			if ok and m then
				for _, d in m:GetDescendants() do
					if d:IsA("LuaSourceContainer") or d:IsA("Sound") or d:IsA("ProximityPrompt") or d:IsA("Light") then
						d:Destroy()
					elseif d:IsA("BasePart") then
						d.Anchored = true; d.CanCollide = false; d.CanQuery = false; d.CanTouch = false
					end
				end
				m.Name = def.id
				m.Parent = folder
			end
		end
	end
	folder.Parent = ReplicatedStorage
end

function Placement.start(deps)
	Economy = deps.Economy
	Plots = deps.Plots
	Inventory = deps.Inventory
	Data = deps.Data
	Monetization = deps.Monetization
	task.spawn(publishPreviews)
end

-- Rebirth (PROGRESSION): every machine and stand goes, placed and stored. x3
-- boost time left on a placed machine is kept first (profile.StoredBoostSeconds).
-- Destroys the models, unregisters them from the plot, empties profile.Placed and
-- the machine items of profile.Inventory. Returns how many machines it removed.
function Placement.clearAll(player: Player): number
	local profile = Data and Data.get(player)
	if not profile then return 0 end
	local kept = 0
	for _, entry in (profile.Placed or {}) do
		kept += math.max(0, tonumber(entry.boost) or 0)
	end
	if kept > 0 then
		profile.StoredBoostSeconds = math.max(0, tonumber(profile.StoredBoostSeconds) or 0) + kept
	end
	local removed = 0
	local rec = Plots.getRecordForOwner(player.UserId)
	if rec then
		for _, m in table.clone(rec.machines) do
			Plots.unregisterMachine(player.UserId, m)
			if m and m.Parent then
				m:Destroy()
				removed += 1
			end
		end
	end
	-- anything of theirs the plot didn't list (shouldn't happen)
	for _, m in CollectionService:GetTagged("CasinoMachine") do
		if m:GetAttribute("OwnerId") == player.UserId and m.Parent then
			m:Destroy()
			removed += 1
		end
	end
	-- emptied in place (other modules may hold these tables)
	if type(profile.Placed) == "table" then table.clear(profile.Placed) else profile.Placed = {} end
	if type(profile.Inventory) ~= "table" then profile.Inventory = {} end
	for i = #profile.Inventory, 1, -1 do
		local item = profile.Inventory[i]
		if type(item) ~= "table" or item.machineId ~= nil then table.remove(profile.Inventory, i) end
	end
	return removed
end

-- The VIP floor moved (VipFloor: a floor bought / a rebirth): every machine on
-- story `from` goes to story `to`, same spot on the plan (no checks: the floors
-- are alike). The saved spots move along; the models carry their new Story and
-- VipFloor attributes. Returns how many placed entries moved.
function Placement.shiftStory(player: Player, from: number, to: number): number
	local profile = Data and Data.get(player)
	if not profile or from == to then return 0 end
	local rec = Plots.getRecordForOwner(player.UserId)
	local baseTop = rec and rec.base.Size.Y / 2 or 0.5
	local lift = Vector3.new(0, (to - from) * STORY_H, 0)
	local moved = 0
	for _, entry in (profile.Placed or {}) do
		local rel = Data.decodeCF(entry.cf)
		if math.max(1, math.floor((rel.Y - baseTop) / STORY_H + 0.25) + 1) == from then
			entry.cf = Data.encodeCF(rel + lift)
			moved += 1
		end
	end
	if rec then
		local vip = Buildings.vipStory(player)
		for _, m in rec.machines do
			if m.Parent and m:GetAttribute("Story") == from then
				m:PivotTo(m:GetPivot() + lift)
				m:SetAttribute("Story", to)
				m:SetAttribute("VipFloor", (vip == to) or nil)
			end
		end
	end
	return moved
end

return Placement
