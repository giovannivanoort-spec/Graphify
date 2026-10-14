--!nonstrict
-- init.server.luau — boots all systems and orchestrates join/leave + remotes.

local Players = game:GetService("Players")
local PhysicsService = game:GetService("PhysicsService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Config = require(Common:WaitForChild("Config"))
local Remotes = require(Common:WaitForChild("Remotes"))

local Data = require(script:WaitForChild("Data"))
local LightingSetup = require(script:WaitForChild("LightingSetup"))
local Economy = require(script:WaitForChild("Economy"))
local Plots = require(script:WaitForChild("Plots"))
local Inventory = require(script:WaitForChild("Inventory"))
local Placement = require(script:WaitForChild("Placement"))
local Showroom = require(script:WaitForChild("Showroom"))
local Staff = require(script:WaitForChild("Staff"))
local Gambling = require(script:WaitForChild("Gambling"))
local Upgrades = require(script:WaitForChild("Upgrades"))
local Monetization = require(script:WaitForChild("Monetization"))
local NPCs = require(script:WaitForChild("NPCs"))
local Rewards = require(script:WaitForChild("Rewards"))
local Leaderboards = require(script:WaitForChild("Leaderboards"))

------------------------------------------------------------------
-- collision groups (NPCs don't shove players or each other)
------------------------------------------------------------------
local NPC_GROUP = Config.CollisionGroups.NPC
local PLAYER_GROUP = Config.CollisionGroups.Player
pcall(function() PhysicsService:RegisterCollisionGroup(NPC_GROUP) end)
pcall(function() PhysicsService:RegisterCollisionGroup(PLAYER_GROUP) end)
pcall(function()
	PhysicsService:CollisionGroupSetCollidable(NPC_GROUP, NPC_GROUP, false)
	PhysicsService:CollisionGroupSetCollidable(NPC_GROUP, PLAYER_GROUP, false)
end)

local function applyPlayerCollisionGroup(character: Model)
	for _, d in character:GetDescendants() do
		if d:IsA("BasePart") then d.CollisionGroup = PLAYER_GROUP end
	end
	character.DescendantAdded:Connect(function(d)
		if d:IsA("BasePart") then d.CollisionGroup = PLAYER_GROUP end
	end)
end

------------------------------------------------------------------
-- start systems
------------------------------------------------------------------
LightingSetup.start()
Data.start()
Plots.start()
Inventory.start({ Data = Data })
Staff.start({ Economy = Economy, Data = Data })
Upgrades.start({ Economy = Economy, Data = Data })
Placement.start({ Economy = Economy, Plots = Plots, Inventory = Inventory, Data = Data, Monetization = Monetization })
Showroom.start()
Gambling.start({ Economy = Economy, Staff = Staff, Data = Data, Monetization = Monetization })
NPCs.start({ Gambling = Gambling, Plots = Plots, Upgrades = Upgrades, Data = Data, Economy = Economy })
Rewards.start({ Economy = Economy, Data = Data })
Monetization.boostMultiplier = Rewards.boostMultiplier   -- Ticket Shop 2X boost stacks with passes
Leaderboards.start({ Data = Data })                       -- the plaza's TOP CASINOS board

------------------------------------------------------------------
-- snapshot the client UI reads
------------------------------------------------------------------
local function buildSnapshot(player: Player)
	local p = Data.get(player)
	if not p then return nil end
	local inv = {}
	for _, item in p.Inventory do
		local def = Config.getMachineDef(item.machineId)
		if def then
			table.insert(inv, { id = item.id, machineId = item.machineId, name = def.name, type = def.type,
				kind = def.kind or "machine",
				sizeX = def.size.X, sizeY = def.size.Y, sizeZ = def.size.Z,
				r = def.color.R, g = def.color.G, b = def.color.B })
		end
	end
	local placed = {}
	for _, e in p.Placed do
		local def = Config.getMachineDef(e.machineId)
		table.insert(placed, { placedId = e.placedId, machineId = e.machineId,
			name = def and def.name or e.machineId, type = def and def.type or "?",
			kind = (def and def.kind) or "machine",
			upgrades = e.upgrades or { speed = 0, bets = 0, lucky = 0 } })
	end
	local staff = {}
	for staffId in p.Staff do table.insert(staff, staffId) end
	local upgrades = {}
	for _, id in (p.Upgrades or {}) do table.insert(upgrades, id) end
	return { cash = p.Cash, inventory = inv, placed = placed, staff = staff, upgrades = upgrades, stats = p.Stats,
		vip = Monetization.hasVipBadge(player), maxMachines = Monetization.getMaxMachines(player),
		tickets = p.Tickets or 0, daily = Rewards.dailyState(player),
		boostSeconds = Rewards.boostSecondsLeft(player), boostMult = Config.BoostMultiplier }
end

local function pushData(player: Player)
	local snap = buildSnapshot(player)
	if snap then Remotes.DataUpdated():FireClient(player, snap) end
end
Placement.pushData = pushData  -- (handy hook if other modules want it)

-- Robux shop: install ProcessReceipt + gamepass-purchase handling, and push a
-- fresh snapshot whenever a purchase changes a player's benefits.
Monetization.start({ Economy = Economy, Data = Data, onChanged = pushData })

------------------------------------------------------------------
-- offline / welcome-back income
------------------------------------------------------------------
local pendingOffline: {[number]: number} = {}

local function computeOffline(player: Player)
	local p = Data.get(player)
	if not p then return end
	local machines = #p.Placed
	if machines == 0 or (p.LastSeen or 0) <= 0 then return end
	local away = os.time() - p.LastSeen
	if away < 60 then return end
	local hours = math.min(away / 3600, Config.OfflineCapHours)
	local income = math.floor(hours * Config.OfflineIncomePerMachinePerHour * machines
		* Monetization.getOfflineMultiplier(player))
	if income > 0 then
		pendingOffline[player.UserId] = income
		Remotes.WelcomeBack():FireClient(player, {
			amount = income, hours = math.floor(hours * 10) / 10, machines = machines,
		})
	end
end

------------------------------------------------------------------
-- join / leave flow
------------------------------------------------------------------
local function onPlayerAdded(player: Player)
	local profile = Data.load(player)        -- yields (session-stamped load)
	Economy.setup(player, profile)
	Monetization.refreshOwnership(player)    -- yields; cache which gamepasses they own
	Plots.assign(player)
	Placement.restore(player, profile)
	computeOffline(player)
	pushData(player)

	player.CharacterAdded:Connect(applyPlayerCollisionGroup)
	if player.Character then applyPlayerCollisionGroup(player.Character) end
end

local function onPlayerRemoving(player: Player)
	pendingOffline[player.UserId] = nil
	Plots.release(player)
	Economy.teardown(player)
	Monetization.teardown(player)
	Data.release(player)                     -- final save + unlock
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)
for _, player in Players:GetPlayers() do task.spawn(onPlayerAdded, player) end

------------------------------------------------------------------
-- remote handlers
------------------------------------------------------------------
Remotes.GetCatalog().OnServerInvoke = function()
	local machines, concessions = {}, {}
	for _, def in Config.Catalog do
		local pack = { id = def.id, name = def.name, type = def.type,
			cost = def.cost, minBet = def.minBet, maxBet = def.maxBet,
			kind = def.kind or "machine",
			revenuePerVisit = def.revenuePerVisit or 0,
			sizeX = def.size.X, sizeY = def.size.Y, sizeZ = def.size.Z,
			r = def.color.R, g = def.color.G, b = def.color.B }
		if def.kind == "concession" then table.insert(concessions, pack)
		else table.insert(machines, pack) end
	end
	local staff = {}
	for _, def in Config.Staff do
		table.insert(staff, { id = def.id, name = def.name, cost = def.cost, bonus = def.houseEdgeBonus })
	end
	local upgrades = {}
	for _, def in Config.Upgrades do
		table.insert(upgrades, { id = def.id, name = def.name, desc = def.desc, cost = def.cost })
	end
	local machineUpgrades = {}
	for key, spec in Config.MachineUpgrades do
		table.insert(machineUpgrades, { key = key, name = spec.name, desc = spec.desc,
			perLevel = spec.perLevel, costs = Config.MachineUpgradeCosts,
			maxLevel = Config.MachineUpgradeMaxLevel })
	end
	return { machines = machines, concessions = concessions, staff = staff,
		upgrades = upgrades, machineUpgrades = machineUpgrades }
end

Remotes.GetData().OnServerInvoke = function(player)
	return buildSnapshot(player)
end

Remotes.GetMonetization().OnServerInvoke = function(player)
	return Monetization.catalogFor(player)
end

Remotes.BuyToInventory().OnServerInvoke = function(player, machineId)
	local def = Config.getMachineDef(machineId)
	if not def then return { ok = false, message = "Unknown machine." } end
	if Inventory.count(player) >= Config.MaxInventory then return { ok = false, message = "Inventory full." } end
	if Economy.getCash(player) < def.cost then return { ok = false, message = "Not enough " .. Config.CurrencyName .. "." } end
	if not Economy.tryWithdraw(player, def.cost) then return { ok = false, message = "Purchase failed." } end
	Inventory.add(player, machineId)
	pushData(player)
	return { ok = true, message = "Bought " .. def.name .. " — find it in your Inventory." }
end

Remotes.PlaceFromInventory().OnServerInvoke = function(player, itemId, posX, posZ, rotationY)
	local res = Placement.placeFromInventory(player, itemId, posX, posZ, rotationY)
	if res.ok then pushData(player) end
	return res
end

Remotes.PickupMachine().OnServerInvoke = function(player, machine)
	local res = Placement.pickup(player, machine)
	if res.ok then pushData(player) end
	return res
end

Remotes.MoveMachine().OnServerInvoke = function(player, machine, posX, posZ, rotationY)
	local res = Placement.move(player, machine, posX, posZ, rotationY)
	if res.ok then pushData(player) end
	return res
end

Remotes.SellMachine().OnServerInvoke = function(player, machine)
	local res = Placement.sell(player, machine)
	if res.ok then pushData(player) end
	return res
end

Remotes.HireStaff().OnServerInvoke = function(player, staffId)
	local res = Staff.hire(player, staffId)
	if res.ok then pushData(player) end
	return res
end

Remotes.BuyUpgrade().OnServerInvoke = function(player, upgradeId)
	local res = Upgrades.buy(player, upgradeId)
	if res.ok then pushData(player) end
	return res
end

Remotes.UpgradeMachine().OnServerInvoke = function(player, machine, kind)
	local res = Placement.upgradeMachine(player, machine, kind)
	if res.ok then pushData(player) end
	return res
end

Remotes.PlayGame().OnServerInvoke = function(player, machine, bet, choice)
	return Gambling.play(player, machine, bet, choice)
end

Remotes.ClaimDaily().OnServerInvoke = function(player)
	local res = Rewards.claimDaily(player)
	if res.ok then pushData(player) end
	return res
end

Remotes.BuyTicketItem().OnServerInvoke = function(player, itemId)
	local res = Rewards.buyTicketItem(player, itemId)
	if res.ok then pushData(player) end
	return res
end

Remotes.ClaimOffline().OnServerInvoke = function(player)
	local amount = pendingOffline[player.UserId]
	if not amount or amount <= 0 then return { ok = false, amount = 0 } end
	pendingOffline[player.UserId] = nil
	Economy.addCash(player, amount)
	local p = Data.get(player)
	if p then p.Stats.TotalEarned += amount end
	return { ok = true, amount = amount }
end

print("[CasinoTycoon] Server systems online.")
