--!nonstrict
-- Monetization.luau — Robux game passes + developer products (Config.Monetization).
--
-- Game passes: ownership is checked server-side (UserOwnsGamePassAsync) on join and
-- cached for the session; a pass bought in-game counts at once. A pass's `effect` is
-- read through the getters below (VIP 2x earnings, 2x offline, + machine slots, the
-- VIP chip); its `perks` (xpMult, rebirthCoinMult, spawnBonus, speedBonus,
-- walletMult, ...) reach the economy through the Upgrades provider "passes".
--
-- Developer products (ProcessReceipt): ONE lookup over every product list
-- (Config.getProductByDevId: cash packs, potions, the machine boost). An id that is
-- in no list, or a grant that fails, returns NotProcessedYet: Roblox never takes
-- Robux for nothing and re-delivers the receipt later. Grants:
--   cashGrant     Cash = max(cashGrant, incomeMinutes x the owner's income rate)
--   potion        `count` potions into the stock (Potions.give)
--   machineBoost  seconds of x3 onto the machine picked with SetBoostTarget, else
--                 onto the stored time (MachineBoost.grantPurchase)
--   wheelSpins    bonus Lucky Wheel spins (profile.Wheel.spins; the wheel panel sells them)
-- Idempotent: a granted PurchaseId stays in profile.Receipts (id -> os.time()) and is
-- only reported PurchaseGranted once the grant is saved (a failed save on a real
-- DataStore = NotProcessedYet; the re-delivery then only saves again). Old receipts
-- are pruned (kept RECEIPT_KEEP_DAYS days, at most RECEIPT_MAX).
--
-- id == 0 means "not set up yet": no web call is made and the store shows SOON.
-- Studio test aid: the ServerStorage attribute CasinoTestPasses = "all" or
-- "xp2x,crowd" makes those passes owned for the session (Studio only, never saved).

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Config = require(Common:WaitForChild("Config"))

local Monetization = {}
local Economy, Data, Upgrades, Progression, Potions, MachineBoost
local onChanged   -- callback(player): the server sets this to push a fresh snapshot
local started = false

local RECEIPT_KEEP_DAYS = 90   -- a granted receipt is remembered this long...
local RECEIPT_MAX = 150        -- ...and at most this many per profile
local PROFILE_WAIT = 15        -- seconds a receipt waits for the buyer's data to load

-- userId -> { [gamepassKey] = boolean }
local owned: {[number]: {[string]: boolean}} = {}
-- userId -> the owned passes' perks summed (the "passes" provider; cached)
local perkCache: {[number]: {[string]: number}} = {}
local processing: {[string]: boolean} = {}   -- PurchaseIds being granted right now
local unsaved: {[string]: number} = {}       -- PurchaseId -> userId: granted in memory, save still due

local function gamepasses()
	return Config.Monetization.Gamepasses
end

local function ownsPass(userId: number, passId: number): boolean
	if not passId or passId == 0 then return false end
	local ok, res = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(userId, passId)
	end)
	return ok and res == true
end

-- Studio only: passes named by ServerStorage.CasinoTestPasses ("all" / "a,b")
local function studioTestPasses(): {[string]: boolean}
	local out = {}
	if not RunService:IsStudio() then return out end
	local spec = ServerStorage:GetAttribute("CasinoTestPasses")
	if type(spec) ~= "string" then return out end
	spec = spec:gsub("%s", "")
	if spec == "" then return out end
	local all = string.lower(spec) == "all"
	for _, gp in gamepasses() do
		if all or string.find("," .. spec .. ",", "," .. gp.key .. ",", 1, true) then out[gp.key] = true end
	end
	return out
end

-- (Re)load which passes a player owns. Yields; safe to call repeatedly.
function Monetization.refreshOwnership(player: Player)
	local map = {}
	for _, gp in gamepasses() do
		map[gp.key] = ownsPass(player.UserId, gp.id)
	end
	for key in studioTestPasses() do map[key] = true end
	-- a pass bought while this ran stays owned
	for key, v in (owned[player.UserId] or {}) do
		if v then map[key] = true end
	end
	owned[player.UserId] = map
	perkCache[player.UserId] = nil
	return map
end

function Monetization.teardown(player: Player)
	owned[player.UserId] = nil
	perkCache[player.UserId] = nil
	for pid, uid in unsaved do
		if uid == player.UserId then unsaved[pid] = nil end
	end
end

function Monetization.ownedMap(player: Player)
	return owned[player.UserId] or {}
end

function Monetization.owns(player: Player, key: string): boolean
	local m = owned[player.UserId]
	return (m ~= nil and m[key]) == true
end

-- multiply an effect across all owned passes (for *Mult effects)
local function effectProduct(player: Player, effectKey: string): number
	local mult = 1
	local m = owned[player.UserId]
	if not m then return mult end
	for _, gp in gamepasses() do
		local e = gp.effect
		if m[gp.key] and e and e[effectKey] then mult *= e[effectKey] end
	end
	return mult
end

-- sum an effect across all owned passes (for additive effects)
local function effectSum(player: Player, effectKey: string): number
	local total = 0
	local m = owned[player.UserId]
	if not m then return total end
	for _, gp in gamepasses() do
		local e = gp.effect
		if m[gp.key] and e and e[effectKey] then total += e[effectKey] end
	end
	return total
end

-- the owned passes' upgrade-effect perks { [effectKey] = sum } (cached; never mutate it)
function Monetization.perks(player: Player?): {[string]: number}
	local uid = player and player.UserId
	if not uid then return {} end
	local c = perkCache[uid]
	if c then return c end
	c = {}
	local m = owned[uid]
	if m then
		for _, gp in gamepasses() do
			if m[gp.key] and type(gp.perks) == "table" then
				for k, v in gp.perks do
					if type(v) == "number" then c[k] = (c[k] or 0) + v end
				end
			end
		end
	end
	perkCache[uid] = c
	return c
end

-- Optional hook (set by the server boot): extra multiplier from the Ticket Shop boost.
Monetization.boostMultiplier = nil :: ((Player) -> number)?

function Monetization.getEarningsMultiplier(player: Player): number
	local mult = effectProduct(player, "earningsMult")
	if Monetization.boostMultiplier then
		mult *= Monetization.boostMultiplier(player)
	end
	return mult
end
function Monetization.getOfflineMultiplier(player: Player): number
	return effectProduct(player, "offlineMult")
end
function Monetization.getMaxMachines(player: Player): number
	return Config.MaxMachinesPerPlot + effectSum(player, "extraMachines")
end
function Monetization.hasVipBadge(player: Player): boolean
	local m = owned[player.UserId]
	if not m then return false end
	for _, gp in gamepasses() do
		if m[gp.key] and gp.effect and gp.effect.vipBadge then return true end
	end
	return false
end

-- what a cash pack pays this player now: max(cashGrant, incomeMinutes x income rate)
function Monetization.packCash(player: Player?, prod, profile): number
	local cash = math.floor(tonumber(prod and prod.cashGrant) or 0)
	local minutes = tonumber(prod and prod.incomeMinutes)
	if minutes and minutes > 0 then
		profile = profile or (player and Data and Data.get(player))
		local rate
		if Progression and Progression.incomeRate then
			rate = Progression.incomeRate(profile)
		else
			local stats = type(profile) == "table" and profile.Stats
			rate = type(stats) == "table" and tonumber(stats.IncomeRate) or 0
		end
		cash = math.max(cash, math.floor((tonumber(rate) or 0) * minutes))
	end
	return cash
end

------------------------------------------------------------------
-- purchases
------------------------------------------------------------------
local function onGamePassFinished(player: Player, passId: number, wasPurchased: boolean)
	if not wasPurchased then return end
	for _, gp in gamepasses() do
		if gp.id ~= 0 and gp.id == passId then
			local m = owned[player.UserId]
			if not m then m = {}; owned[player.UserId] = m end
			m[gp.key] = true
			perkCache[player.UserId] = nil
			if onChanged then onChanged(player) end
			break
		end
	end
end

local function waitForProfile(player: Player)
	local t0 = os.clock()
	local p = Data.get(player)
	while not p and player.Parent and os.clock() - t0 < PROFILE_WAIT do
		task.wait(0.25)
		p = Data.get(player)
	end
	return p
end

-- keep profile.Receipts small: drop receipts older than RECEIPT_KEEP_DAYS and the
-- oldest past RECEIPT_MAX (old saves stored `true`: those get stamped now)
local function pruneReceipts(receipts)
	local now = os.time()
	local list = {}
	for pid, v in receipts do
		local t = type(v) == "number" and v or nil
		if not t then
			t = now
			receipts[pid] = now
		end
		if now - t > RECEIPT_KEEP_DAYS * 86400 then
			receipts[pid] = nil
		else
			table.insert(list, { pid = pid, t = t })
		end
	end
	if #list > RECEIPT_MAX then
		table.sort(list, function(a, b) return a.t < b.t end)
		for i = 1, #list - RECEIPT_MAX do receipts[list[i].pid] = nil end
	end
end

-- Cash onto the profile (through Economy so the leaderstat follows)
local function addCash(player: Player, profile, amount: number)
	local before = tonumber(profile.Cash) or 0
	if Economy then Economy.addCash(player, amount) end
	if (tonumber(profile.Cash) or 0) == before and amount > 0 then
		profile.Cash = math.max(0, math.floor(before + amount))   -- (no Economy session)
	end
end

-- grant one product; returns a result table, or nil + why (nothing was granted)
local function grant(player: Player, profile, prod)
	if prod.cashGrant then
		local cash = Monetization.packCash(player, prod, profile)
		if cash <= 0 then return nil, "empty cash pack" end
		addCash(player, profile, cash)
		return { cash = cash }
	elseif prod.potion then
		if not (Potions and Potions.give) then return nil, "Potions module unavailable" end
		local count = math.max(1, math.floor(tonumber(prod.count) or 1))
		if not Potions.give(player, prod.potion, count) then return nil, "unknown potion " .. tostring(prod.potion) end
		return { potion = prod.potion, count = count }
	elseif prod.machineBoost then
		if not (MachineBoost and MachineBoost.grantPurchase) then return nil, "MachineBoost module unavailable" end
		local res = MachineBoost.grantPurchase(player, prod.machineBoost)
		if not res then return nil, "machine boost not granted" end
		return res
	elseif prod.wheelSpins then
		-- bonus Lucky Wheel spins (Config.LuckyWheel; profile.Wheel from Data v7)
		local n = math.max(1, math.floor(tonumber(prod.wheelSpins) or 1))
		local w = profile.Wheel
		if type(w) ~= "table" then return nil, "no wheel data" end
		local cap = (Config.LuckyWheel and Config.LuckyWheel.MaxBonusSpins) or 999
		w.spins = math.min(cap, math.max(0, math.floor(tonumber(w.spins) or 0)) + n)
		return { wheelSpins = n, spins = w.spins }
	end
	return nil, "product grants nothing"
end

local function processReceipt(receiptInfo)
	local Decision = Enum.ProductPurchaseDecision
	local prod = Config.getProductByDevId(receiptInfo.ProductId)
	if not prod then
		-- never take Robux for a product we don't know (an id not pasted into Config yet)
		warn(("[Monetization] receipt for unknown product %s (user %s): not granted"):format(
			tostring(receiptInfo.ProductId), tostring(receiptInfo.PlayerId)))
		return Decision.NotProcessedYet
	end
	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	if not player or not Data then return Decision.NotProcessedYet end
	local profile = waitForProfile(player)
	if not profile then return Decision.NotProcessedYet end
	if type(profile.Receipts) ~= "table" then profile.Receipts = {} end
	local pid = tostring(receiptInfo.PurchaseId)

	if profile.Receipts[pid] ~= nil then
		-- granted before: done once that grant is saved
		if unsaved[pid] then
			if Data.isPersistent() and not Data.save(player) then return Decision.NotProcessedYet end
			unsaved[pid] = nil
		end
		return Decision.PurchaseGranted
	end
	if processing[pid] then return Decision.NotProcessedYet end
	processing[pid] = true
	local ok, res, why = pcall(grant, player, profile, prod)
	processing[pid] = nil
	if not ok or not res then
		warn(("[Monetization] %s for %s not granted: %s"):format(tostring(prod.key), player.Name,
			tostring(ok and why or res)))
		return Decision.NotProcessedYet
	end
	profile.Receipts[pid] = os.time()
	pruneReceipts(profile.Receipts)
	print(("[Monetization] %s bought %s"):format(player.Name, tostring(prod.key)))
	if onChanged then
		local okPush, err = pcall(onChanged, player)
		if not okPush then warn("[Monetization] onChanged: " .. tostring(err)) end
	end

	-- Persist the grant before telling Roblox it's done. A failed save on a real
	-- DataStore = NotProcessedYet (the re-delivery finds the receipt and only saves
	-- again). In-memory (Studio without API access) there is nothing to save.
	if Data.isPersistent() and not Data.save(player) then
		unsaved[pid] = player.UserId
		return Decision.NotProcessedYet
	end
	return Decision.PurchaseGranted
end
Monetization.processReceipt = processReceipt   -- (exposed for tests)

-- deps: Data, Economy, Upgrades (the "passes" provider), Progression (income rate for
-- the cash packs), Potions, MachineBoost, onChanged (= pushData)
function Monetization.start(deps)
	Economy = deps.Economy
	Data = deps.Data
	Upgrades = deps.Upgrades
	Progression = deps.Progression
	Potions = deps.Potions
	MachineBoost = deps.MachineBoost
	onChanged = deps.onChanged or deps.pushData
	if started then return end
	started = true
	MarketplaceService.ProcessReceipt = processReceipt
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(onGamePassFinished)
	if Upgrades and Upgrades.addProvider then
		Upgrades.addProvider("passes", function(_profile, player)
			return player and Monetization.perks(player) or nil
		end)
	end
end

-- The catalog the client renders (ids + names + descs + looks; the client pulls live
-- Robux prices from MarketplaceService). Includes this player's owned passes and what
-- each cash pack pays them right now.
function Monetization.catalogFor(player: Player)
	local passes = {}
	for _, gp in gamepasses() do
		table.insert(passes, { key = gp.key, id = gp.id, name = gp.name, desc = gp.desc, icon = gp.icon,
			tone = gp.tone, badge = gp.badge, robux = gp.robux, owned = Monetization.owns(player, gp.key) })
	end
	local profile = Data and Data.get(player)
	local products = {}
	for _, p in Config.Monetization.Products do
		if p.cashGrant then -- the CASH PACKS tab (wheel_spins lives in the wheel panel)
			table.insert(products, { key = p.key, id = p.id, name = p.name, robux = p.robux, badge = p.badge,
				cashGrant = Monetization.packCash(player, p, profile), incomeMinutes = p.incomeMinutes })
		end
	end
	local potions = {}
	for _, p in (Config.Monetization.PotionProducts or {}) do
		table.insert(potions, { key = p.key, id = p.id, potion = p.potion, count = p.count or 1,
			robux = p.robux, badge = p.badge })
	end
	local boosts = {}
	for _, p in (Config.Monetization.BoostProducts or {}) do
		table.insert(boosts, { key = p.key, id = p.id, seconds = p.machineBoost, robux = p.robux })
	end
	return { gamepasses = passes, products = products, potions = potions, boosts = boosts }
end

return Monetization
