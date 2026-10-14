--!nonstrict
-- Placement.luau — builds machines, places them FROM INVENTORY (free move),
-- picks them back up, sells them, and rebuilds the saved layout on join.
-- Buying is handled at the shop (adds to inventory); placing never charges.

local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local Workspace = game:GetService("Workspace")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Config = require(Common:WaitForChild("Config"))

local Placement = {}
local Economy, Plots, Inventory, Data, Monetization
local MachineVisuals = require(script.Parent:WaitForChild("MachineVisuals"))

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
	model:SetAttribute("MinBet", def.minBet)
	model:SetAttribute("MaxBet", def.maxBet)
	model:SetAttribute("Kind", isConc and "concession" or "machine")
	if isConc then
		model:SetAttribute("RevenuePerVisit", def.revenuePerVisit or 0)
		CollectionService:AddTag(model, "CasinoConcession")
	else
		applyUpgradesToMachine(model, def, upgrades)
	end
	CollectionService:AddTag(model, "CasinoMachine")
	return model
end

-- Place an owned (inventory) machine on the player's plot.
function Placement.placeFromInventory(player: Player, itemId: string, posX: number, posZ: number, rotationY: number)
	local item = Inventory.find(player, itemId)
	if not item then return { ok = false, message = "Item not in your inventory." } end
	local def = Config.getMachineDef(item.machineId)
	if not def then return { ok = false, message = "Unknown machine." } end
	if not Plots.getRecordForOwner(player.UserId) then
		return { ok = false, message = "You don't own a plot." }
	end
	local cap = (Monetization and Monetization.getMaxMachines(player)) or Config.MaxMachinesPerPlot
	if Plots.machineCount(player.UserId) >= cap then
		return { ok = false, message = "Your casino is full." }
	end

	local y = Plots.surfaceY(player.UserId)
	local pos = Vector3.new(posX, y, posZ)
	if not Plots.isInsideOwnerPlot(player.UserId, pos) then
		return { ok = false, message = "Place it inside your own plot." }
	end
	if Plots.tooCloseToMachine(player.UserId, pos) then
		return { ok = false, message = "Too close to another machine." }
	end

	local placedId = HttpService:GenerateGUID(false)
	local groundCF = CFrame.new(pos) * CFrame.Angles(0, math.rad(rotationY or 0), 0)
	local upgrades = { speed = 0, bets = 0, lucky = 0 }
	local model = buildMachine(def, player.UserId, groundCF, placedId, upgrades)
	model.Parent = Workspace
	Plots.registerMachine(player.UserId, model)

	-- move from inventory -> placed (persisted)
	Inventory.remove(player, itemId)
	local profile = Data.get(player)
	local relCF = Plots.relativeFromWorld(player.UserId, groundCF)
	table.insert(profile.Placed, { placedId = placedId, machineId = def.id, cf = Data.encodeCF(relCF), upgrades = upgrades })

	return { ok = true, message = "Placed " .. def.name .. "!" }
end

local function removePlacedEntry(profile, placedId: string)
	for i, entry in profile.Placed do
		if entry.placedId == placedId then
			local copy = entry
			table.remove(profile.Placed, i)
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

-- Move an already-placed machine to a new spot/rotation on the player's plot.
function Placement.move(player: Player, machine: Instance, posX: number, posZ: number, rotationY: number)
	if not validateOwnedMachine(player, machine) then
		return { ok = false, message = "That's not your machine." }
	end
	local rec = Plots.getRecordForOwner(player.UserId)
	if not rec then return { ok = false, message = "You don't own a plot." } end

	local y = Plots.surfaceY(player.UserId)
	local pos = Vector3.new(posX, y, posZ)
	if not Plots.isInsideOwnerPlot(player.UserId, pos) then
		return { ok = false, message = "Place it inside your own plot." }
	end
	if Plots.tooCloseToMachine(player.UserId, pos, machine) then
		return { ok = false, message = "Too close to another machine." }
	end

	local body = machine.PrimaryPart or machine:FindFirstChild("Body")
	if not (body and body:IsA("BasePart")) then return { ok = false, message = "Broken machine." } end
	local groundCF = CFrame.new(pos) * CFrame.Angles(0, math.rad(rotationY or 0), 0)
	if machine:GetAttribute("GroundPivot") then
		machine:PivotTo(groundCF)                    -- pivot = footprint centre on the ground
	else
		local sizeY = body.Size.Y
		machine:PivotTo(groundCF * CFrame.new(0, sizeY/2, 0))
	end

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
	Inventory.add(player, machineId)
	Plots.unregisterMachine(player.UserId, machine)
	machine:Destroy()
	return { ok = true, message = "Returned to inventory." }
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
	local refund = def and math.floor(def.cost * Config.SellRefund) or 0
	Economy.addCash(player, refund)
	Plots.unregisterMachine(player.UserId, machine)
	machine:Destroy()
	return { ok = true, message = ("Sold for $%d."):format(refund), refund = refund }
end

-- Rebuild the saved layout when a player joins.
function Placement.restore(player: Player, profile)
	for _, entry in profile.Placed do
		local def = Config.getMachineDef(entry.machineId)
		if def then
			local relCF = Data.decodeCF(entry.cf)
			local groundCF = Plots.worldFromRelative(player.UserId, relCF) or CFrame.new()
			local model = buildMachine(def, player.UserId, groundCF, entry.placedId, entry.upgrades)
			model.Parent = Workspace
			Plots.registerMachine(player.UserId, model)
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
	local cost = Config.MachineUpgradeCosts[cur + 1] or 999999
	if Economy.getCash(player) < cost then
		return { ok = false, message = "Not enough " .. Config.CurrencyName .. "." }
	end
	if not Economy.tryWithdraw(player, cost) then
		return { ok = false, message = "Purchase failed." }
	end
	entry.upgrades[kind] = cur + 1
	local def = Config.getMachineDef(entry.machineId)
	if def then applyUpgradesToMachine(machine, def, entry.upgrades) end
	return { ok = true, message = ("%s -> L%d"):format(spec.name, cur + 1) }
end

function Placement.start(deps)
	Economy = deps.Economy
	Plots = deps.Plots
	Inventory = deps.Inventory
	Data = deps.Data
	Monetization = deps.Monetization
end

return Placement
