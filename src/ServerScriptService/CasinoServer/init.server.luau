--!nonstrict
-- init.server.luau — boots all systems and orchestrates join/leave + remotes.

local Players = game:GetService("Players")
local PhysicsService = game:GetService("PhysicsService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

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
local DayNight = require(script:WaitForChild("DayNight"))
local Buildings = require(script:WaitForChild("Buildings"))
local Progression = require(script:WaitForChild("Progression"))   -- the Casino Rank
-- the city's cars (they build RoadNet on require): if they fail, the game runs
-- on without them and patrons walk in at the entrances instead
local trafficLoaded, Traffic = pcall(require, script:WaitForChild("Traffic"))
if not trafficLoaded then
	warn("[CasinoTycoon] Traffic failed to load: " .. tostring(Traffic))
	Traffic = nil
end

-- the Rebirth & Rewards systems: each is optional at boot (a missing or broken
-- module must not take the server down). Each may have start(deps),
-- join(player), leave(player) and snapshot(player, profile).
local function optional(name: string)
	local mod = script:FindFirstChild(name)
	if not mod then return nil end
	local ok, res = pcall(require, mod)
	if not ok then
		warn(("[CasinoTycoon] %s failed to load: %s"):format(name, tostring(res)))
		return nil
	end
	return res
end
local Rebirth = optional("Rebirth")            -- rebirths, rebirth coins + the rebirth shop
local Potions = optional("Potions")            -- timed potions (Robux / tickets / rewards)
local MachineBoost = optional("MachineBoost")  -- the x3 per-machine Robux boost
local Playtime = optional("Playtime")          -- daily playtime rewards
local Decor = optional("Decor")                -- plants, paths & co.
local StaffModels = optional("StaffModels")    -- visible staff rig templates
-- the Cheaters & VIP update
local GameEvents = optional("GameEvents")      -- what players did (quests listen)
local Cheaters = optional("Cheaters")          -- cheating guests, kicking, security catches
local VipFloor = optional("VipFloor")          -- the VIP pass's free floor (x1.25 earnings)
local Quests = optional("Quests")              -- daily / weekly quests
local LuckyWheel = optional("LuckyWheel")      -- the lucky wheel (free spin every few hours)
local Events = optional("Events")              -- server-wide casino events
-- start order, and the key each module's snapshot goes under
local EXTRAS = {
	{ name = "StaffModels", mod = StaffModels },
	{ name = "Staff", mod = Staff, snap = "staffInfo" },
	{ name = "Potions", mod = Potions, snap = "potions" },
	{ name = "MachineBoost", mod = MachineBoost, snap = "boosts" },
	{ name = "Decor", mod = Decor, snap = "decor" },
	{ name = "Rebirth", mod = Rebirth, snap = "rebirth" },
	{ name = "Playtime", mod = Playtime, snap = "playtime" },
	{ name = "Leaderboards", mod = Leaderboards },
	{ name = "VipFloor", mod = VipFloor, snap = "vipFloor" },
	{ name = "Cheaters", mod = Cheaters, snap = "cheaters" },
	{ name = "Events", mod = Events, snap = "event" },
	{ name = "Quests", mod = Quests, snap = "quests" },
	{ name = "LuckyWheel", mod = LuckyWheel, snap = "wheel" },
}

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
DayNight.start()                                          -- the sky's clock; nights bring +50% guests
Data.start()
Plots.start()
Inventory.start({ Data = Data })
Upgrades.start({ Economy = Economy, Data = Data, Progression = Progression })
Placement.start({ Economy = Economy, Plots = Plots, Inventory = Inventory, Data = Data, Monetization = Monetization })
Showroom.start()
Gambling.start({ Economy = Economy, Staff = Staff, Data = Data, Monetization = Monetization,
	Progression = Progression, Upgrades = Upgrades, MachineBoost = MachineBoost })
if Traffic then                                           -- cars out of the tunnels; patrons ride them
	local ok, err = pcall(Traffic.start, { Upgrades = Upgrades })
	if not ok then warn("[CasinoTycoon] Traffic.start: " .. tostring(err)) end
end
NPCs.start({ Gambling = Gambling, Plots = Plots, Upgrades = Upgrades, Data = Data, Economy = Economy,
	Traffic = Traffic, Progression = Progression })
Monetization.boostMultiplier = Rewards.boostMultiplier   -- Ticket Shop 2X boost stacks with passes

------------------------------------------------------------------
-- snapshot the client UI reads
------------------------------------------------------------------
-- copies of each machine id the player owns (placed + in inventory): the next
-- copy costs Config.machinePrice(def, owned) (price growth per copy)
local function ownedCopiesOf(p)
	local counts = {}
	for _, item in p.Inventory do counts[item.machineId] = (counts[item.machineId] or 0) + 1 end
	for _, e in p.Placed do counts[e.machineId] = (counts[e.machineId] or 0) + 1 end
	return counts
end

local function copyPrice(def, owned: number, discount: number?): number
	if Config.machinePrice then return Config.machinePrice(def, owned, discount) end
	return def.cost
end

-- the owner's purchase discount (Bargain Hunter rebirth upgrade), 0..0.6
local function discountOf(p): number
	return math.clamp(Upgrades.effect(p, "priceDiscount"), 0, 0.6)
end

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
	-- saved spots are relative to the plot's base centre, so a machine's floor
	-- follows from its height above the base's top surface
	local rec = Plots.getRecordForOwner(player.UserId)
	local baseTop = rec and rec.base.Size.Y / 2 or 0.5
	local placed = {}
	for _, e in p.Placed do
		local def = Config.getMachineDef(e.machineId)
		local rel = Data.decodeCF(e.cf)
		local story = math.max(1, math.floor((rel.Y - baseTop) / Config.Building.StoryHeight + 0.25) + 1)
		local upgradeCosts = {}  -- the next level's price per kind (absent when maxed)
		if def then
			for kind in Config.MachineUpgrades do
				upgradeCosts[kind] = Placement.upgradeCostFor(e, def, kind)
			end
		end
		table.insert(placed, { placedId = e.placedId, machineId = e.machineId,
			name = def and def.name or e.machineId, type = def and def.type or "?",
			kind = (def and def.kind) or "machine", story = story,
			upgrades = e.upgrades or { speed = 0, bets = 0, lucky = 0 },
			upgradeCosts = upgradeCosts, refund = def and Placement.refundFor(e, def) or 0,
			boost = tonumber(e.boost) or 0 })   -- x3 machine boost seconds left (MachineBoost)
	end
	local staff = {}
	for staffId in p.Staff do table.insert(staff, staffId) end
	local snap = { cash = p.Cash, inventory = inv, placed = placed, staff = staff, stats = p.Stats,
		upgradeLevels = p.UpgradeLevels or {}, building = Buildings.snapshot(player),
		vip = Monetization.hasVipBadge(player), maxMachines = Buildings.capacity(player),
		tickets = p.Tickets or 0, daily = Rewards.dailyState(player),
		boostSeconds = Rewards.boostSecondsLeft(player), boostMult = Config.BoostMultiplier,
		-- the Casino Rank: rank, rankName, rankProgress (= TotalEarned), rankNext
		-- (nil at the top), rankFloor, clientele, storyRanks
		ownedCopies = ownedCopiesOf(p),
		flow = NPCs.flowFor(player.UserId),   -- { rate, demand, lobby, weight, bottleneck, ... } (nil before the first tick)
		incomeRate = Progression.incomeRate(p),
		xp = math.floor(tonumber(p.Stats.XP) or 0),     -- the Casino Rank runs on XP
		staffLevels = p.Staff,                           -- staff id -> level
		priceDiscount = discountOf(p),
		effects = Upgrades.effects(p) }                  -- every effect key's total (machine stats, UIs)
	for k, v in Progression.snapshotFields(p) do snap[k] = v end
	-- the Rebirth & Rewards modules' own fields (rebirth, potions, boosts, decor, ...)
	for _, x in EXTRAS do
		if x.snap and x.mod and type(x.mod.snapshot) == "function" then
			local ok, res = pcall(x.mod.snapshot, player, p)
			if ok then
				snap[x.snap] = res
			else
				warn(("[CasinoTycoon] %s.snapshot: %s"):format(x.name, tostring(res)))
			end
		end
	end
	return snap
end

local function pushData(player: Player)
	local snap = buildSnapshot(player)
	if snap then Remotes.DataUpdated():FireClient(player, snap) end
end
Placement.pushData = pushData  -- (handy hook if other modules want it)

-- the Casino Rank: rank-up fanfare (Remotes.RankUp) + a fresh snapshot, the income
-- rate (Stats.IncomeRate) and the per-minute telemetry (Config.Progression.MinuteLog)
Progression.start({ Data = Data, pushData = pushData, flowFor = NPCs.flowFor,
	recordFor = Plots.getRecordForOwner, Upgrades = Upgrades })

-- everything a system may need (the Rebirth & Rewards modules take this whole table)
local deps = {
	Data = Data, Economy = Economy, Plots = Plots, Inventory = Inventory, Placement = Placement,
	Showroom = Showroom, Staff = Staff, Gambling = Gambling, Upgrades = Upgrades, Monetization = Monetization,
	NPCs = NPCs, Rewards = Rewards, Leaderboards = Leaderboards, DayNight = DayNight, Buildings = Buildings,
	Progression = Progression, Traffic = Traffic, Remotes = Remotes, pushData = pushData,
	Rebirth = Rebirth, Potions = Potions, MachineBoost = MachineBoost, Playtime = Playtime, Decor = Decor,
	StaffModels = StaffModels, GameEvents = GameEvents, Cheaters = Cheaters, VipFloor = VipFloor,
	Quests = Quests, LuckyWheel = LuckyWheel, Events = Events,
}

local function gameEvent(player: Player, name: string, amount: number?)
	if GameEvents then pcall(GameEvents.emit, player, name, amount) end
end

-- Robux shop: install ProcessReceipt + gamepass-purchase handling, and push a
-- fresh snapshot whenever a purchase changes a player's benefits.
do
	local mdeps = table.clone(deps)
	mdeps.onChanged = pushData
	Monetization.start(mdeps)
end

-- every plot is a casino building (stories, name sign, colours, elevator);
-- Plots rebuilds a plot's shell through it when the plot changes hands
Buildings.start({ Plots = Plots, Data = Data, Economy = Economy, Upgrades = Upgrades,
	Monetization = Monetization, pushData = pushData, Progression = Progression })

Rewards.start(deps)                                       -- tickets, the daily reward, the ticket shop

-- staff, potions, machine boosts, decor, rebirth, playtime, the global leaderboards
for _, x in EXTRAS do
	if x.mod and type(x.mod.start) == "function" then
		local ok, err = pcall(x.mod.start, deps)
		if not ok then warn(("[CasinoTycoon] %s.start: %s"):format(x.name, tostring(err))) end
	end
end

local function eachExtra(fnName: string, player: Player)
	for _, x in EXTRAS do
		local fn = x.mod and x.mod[fnName]
		if type(fn) == "function" then
			local ok, err = pcall(fn, player)
			if not ok then warn(("[CasinoTycoon] %s.%s: %s"):format(x.name, fnName, tostring(err))) end
		end
	end
end

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
	-- a share of the owner's income rate ($/min, Stats.IncomeRate); until they have
	-- one, the old flat rate per machine is the floor
	local rate = math.max(Progression.incomeRate(p), (Config.OfflineIncomePerMachinePerHour or 80) * machines / 60)
	local income = math.floor(hours * 60 * rate * (Config.OfflineIncomeShare or 0.02)
		* Monetization.getOfflineMultiplier(player) * (1 + Upgrades.effect(p, "offlineBonus")))
	if income > 0 then
		pendingOffline[player.UserId] = income
		Remotes.WelcomeBack():FireClient(player, {
			amount = income, hours = math.floor(hours * 10) / 10, machines = machines,
		})
	end
end

------------------------------------------------------------------
-- one-tap travel (HUD travel bar): your casino, the Showroom, the Plaza
------------------------------------------------------------------
local TRAVEL_COOLDOWN = 3 -- seconds between hops, per player
-- the Showroom forecourt under its canopy (south boulevard), facing west into
-- the portal; used only if the runtime-built room (Showroom.luau) can't be found
local SHOWROOM_FALLBACK = CFrame.new(-29, 4.8, 367.5) * CFrame.Angles(0, math.rad(90), 0)
local lastTravel: {[number]: number} = {}
local travelRng = Random.new()

-- where a hop lands (the character's pivot), or nil if that spot is missing
local function travelTarget(player: Player, dest: string): CFrame?
	if dest == "casino" then
		local rec = Plots.getRecordForOwner(player.UserId)
		if not rec then return nil end
		local pos = rec.entrance + Vector3.new(0, 5, 0)
		local inside = rec.center and Vector3.new(rec.center.X, pos.Y, rec.center.Z)
		if not inside or (inside - pos).Magnitude < 0.1 then return CFrame.new(pos) end
		return CFrame.lookAt(pos, inside)                   -- facing the casino
	elseif dest == "showroom" then
		-- 6 studs out from the room's open front (room +Z), facing in
		local room = Workspace:FindFirstChild("Showroom")
		local floor = room and room:FindFirstChild("Floor")
		if floor and floor:IsA("BasePart") then
			return floor.CFrame * CFrame.new(0, floor.Size.Y / 2 + 4, floor.Size.Z / 2 + 6)
		end
		return SHOWROOM_FALLBACK
	elseif dest == "plaza" then
		local spawn = Workspace:FindFirstChild("StripSpawn")       -- plaza: faces the three leaderboards
		if spawn and spawn:IsA("BasePart") then return spawn.CFrame + Vector3.new(0, 4, 0) end
	end
	return nil
end

------------------------------------------------------------------
-- join / leave flow
------------------------------------------------------------------
local function onPlayerAdded(player: Player)
	local profile = Data.load(player)        -- yields (session-stamped load)
	Economy.setup(player, profile)
	Progression.join(player)                 -- the rank they join with (no fanfare for it)
	Monetization.refreshOwnership(player)    -- yields; cache which gamepasses they own
	Plots.assign(player)
	Placement.restore(player, profile)
	eachExtra("join", player)                -- decor back on the floor, staff roster, potions...
	computeOffline(player)
	pushData(player)

	player.CharacterAdded:Connect(applyPlayerCollisionGroup)
	if player.Character then applyPlayerCollisionGroup(player.Character) end
end

local function onPlayerRemoving(player: Player)
	pendingOffline[player.UserId] = nil
	lastTravel[player.UserId] = nil
	Progression.leave(player)
	eachExtra("leave", player)
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
			unlockRank = def.unlockRank or 1,   -- the Casino Rank that unlocks buying it
			rebirth = def.rebirth or 0,         -- rebirths needed to buy it
			xp = Config.machineXP(def),         -- XP per game a guest plays on it
			sizeX = def.size.X, sizeY = def.size.Y, sizeZ = def.size.Z,
			r = def.color.R, g = def.color.G, b = def.color.B }
		if def.kind == "concession" then table.insert(concessions, pack)
		else table.insert(machines, pack) end
	end
	local staff = {}
	for _, def in Config.Staff do
		table.insert(staff, { id = def.id, name = def.name, cost = def.cost, bonus = def.houseEdgeBonus,
			unlockRank = def.unlockRank or 1 })
	end
	local machineUpgrades = {}
	for key, spec in Config.MachineUpgrades do
		-- a level's price depends on the machine: floor(machine cost x costMult[L])
		-- (snapshot: placed[i].upgradeCosts; machines carry a BaseCost attribute).
		-- `costs` are the old flat prices, kept for older clients only.
		table.insert(machineUpgrades, { key = key, name = spec.name, desc = spec.desc,
			perLevel = spec.perLevel, costs = Config.MachineUpgradeCosts,
			costMult = Config.MachineUpgradeCostMult,
			maxLevel = Config.MachineUpgradeMaxLevel })
	end
	local ranks = {}
	for i, def in Config.Progression.Ranks do
		ranks[i] = { name = def.name, xp = def.xp or def.threshold, threshold = def.xp or def.threshold,
			clientele = def.clientele }
	end
	return { machines = machines, concessions = concessions, staff = staff,
		upgradeTracks = Upgrades.catalog(), machineUpgrades = machineUpgrades,
		ranks = ranks, storyRanks = Config.Progression.StoryRanks, storyCosts = Config.Building.StoryCosts,
		copyPriceGrowth = Config.CopyPriceGrowth or 1 }
end

Remotes.GetData().OnServerInvoke = function(player)
	return buildSnapshot(player)
end

Remotes.GetMonetization().OnServerInvoke = function(player)
	return Monetization.catalogFor(player)
end

Remotes.BuyToInventory().OnServerInvoke = function(player, machineId)
	local def = type(machineId) == "string" and Config.getMachineDef(machineId)
	if not def then return { ok = false, message = "Unknown machine." } end
	local p = Data.get(player)
	if not p then return { ok = false, message = "Data not ready." } end
	-- the rebirth gate (Rebirth Wing machines: def.rebirth rebirths; no Rebirth
	-- module = no rebirths yet)
	local needRebirth = math.max(0, math.floor(tonumber(def.rebirth) or 0))
	if needRebirth > 0 then
		local okCount, have = pcall(function() return Rebirth and Rebirth.count(player) or 0 end)
		if not okCount or (tonumber(have) or 0) < needRebirth then
			local okMsg, msg = pcall(function() return Rebirth and Rebirth.lockedMessage(needRebirth) end)
			return { ok = false, needRebirth = needRebirth,
				message = (okMsg and type(msg) == "string") and msg or ("Unlocks at Rebirth %d"):format(needRebirth) }
		end
	end
	-- the Casino Rank gate (machines you own above your rank keep working)
	local need = def.unlockRank or 1
	if not Progression.allows(player, need) then
		return { ok = false, message = Progression.lockedMessage(need), needRank = need }
	end
	if Inventory.count(player) >= Config.MaxInventory then return { ok = false, message = "Inventory full." } end
	-- every copy you already own (placed + stored) makes the next one dearer
	local price = copyPrice(def, ownedCopiesOf(p)[def.id] or 0, discountOf(p))
	if Economy.getCash(player) < price then return { ok = false, message = "Not enough " .. Config.CurrencyName .. "." } end
	if not Economy.tryWithdraw(player, price) then return { ok = false, message = "Purchase failed." } end
	local item = Inventory.add(player, machineId)
	if item then
		item.paid = price                    -- a post-patch copy (sell refunds: Placement.refundFor)
	else
		Economy.addCash(player, price)       -- (couldn't store it: money back)
		return { ok = false, message = "Inventory full." }
	end
	pushData(player)
	gameEvent(player, "machineBought", 1)
	return { ok = true, message = "Bought " .. def.name .. " — find it in your Inventory.", price = price }
end

Remotes.PlaceFromInventory().OnServerInvoke = function(player, itemId, posX, posZ, rotationY, story)
	local res = Placement.placeFromInventory(player, itemId, posX, posZ, rotationY, story)
	if res.ok then pushData(player) end
	return res
end

Remotes.PickupMachine().OnServerInvoke = function(player, machine)
	local res = Placement.pickup(player, machine)
	if res.ok then pushData(player) end
	return res
end

Remotes.MoveMachine().OnServerInvoke = function(player, machine, posX, posZ, rotationY, story)
	local res = Placement.move(player, machine, posX, posZ, rotationY, story)
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
	if res.ok then
		pushData(player)
		gameEvent(player, "upgradeBought", 1)
	end
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
	if res.ok then
		pushData(player)
		gameEvent(player, "dailyClaimed", 1)
	end
	return res
end

Remotes.BuyTicketItem().OnServerInvoke = function(player, itemId)
	local res = Rewards.buyTicketItem(player, itemId)
	if res.ok then pushData(player) end
	return res
end

-- Placement/move mode is client-only state, so the client refuses those hops itself.
Remotes.TravelTo().OnServerInvoke = function(player, dest)
	if dest ~= "casino" and dest ~= "showroom" and dest ~= "plaza" then
		return { ok = false, message = "Unknown destination." }
	end
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not (hum and root) or hum.Health <= 0 then return { ok = false, message = "Wait until you respawn." } end
	local now = os.clock()
	local left = (lastTravel[player.UserId] or -math.huge) + TRAVEL_COOLDOWN - now
	if left > 0 then return { ok = false, message = ("Travel ready in %ds."):format(math.ceil(left)) } end
	local target = travelTarget(player, dest)
	if not target then
		return { ok = false, message = dest == "casino" and "You don't have a casino yet." or "Can't travel there right now." }
	end
	lastTravel[player.UserId] = now
	if dest ~= "casino" then
		-- shared spots: scatter arrivals so players don't land inside each other
		target += Vector3.new(travelRng:NextNumber(-2.5, 2.5), 0, travelRng:NextNumber(-2.5, 2.5))
	end
	-- StreamingEnabled: get the floor there onto the client before moving it
	pcall(function() player:RequestStreamAroundAsync(target.Position, 2) end)
	if player.Character ~= char or not root.Parent or hum.Health <= 0 then
		return { ok = false, message = "Travel cancelled." }
	end
	char:PivotTo(target)
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
	return { ok = true, cframe = target, cooldown = TRAVEL_COOLDOWN }
end

Remotes.ClaimOffline().OnServerInvoke = function(player)
	local amount = pendingOffline[player.UserId]
	if not amount or amount <= 0 then return { ok = false, amount = 0 } end
	pendingOffline[player.UserId] = nil
	Economy.addCash(player, amount)
	local p = Data.get(player)
	if p then p.Stats.TotalEarned += amount end
	Progression.touch(player)                -- offline income counts toward the Casino Rank
	return { ok = true, amount = amount }
end

print("[CasinoTycoon] Server systems online.")
