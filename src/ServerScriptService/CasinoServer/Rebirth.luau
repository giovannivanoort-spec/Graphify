--!nonstrict
-- Rebirth.luau — rebirths, rebirth coins and the REBIRTH SHOP (Config.Rebirth,
-- Config.RebirthUpgrades).
--   * money based: the n-th rebirth (n = count + 1) needs Config.Rebirth.cost(n)
--     Cash ON HAND. It pays Config.Rebirth.coins(n, cash) rebirth coins (a little
--     more when you bring more Cash than it needs), + the rebirthCoinBonus effect
--     (Coin Magnet), x (1 + rebirthCoinMult) (the 2x Rebirth Coins pass).
--   * a rebirth RESETS: Cash (to max(StartingCash, the startCash effect)), every
--     machine and stand, placed or stored (Placement.clearAll: x3 boost time left on
--     them is kept as stored boost time), the 17 upgrade tracks, the floors (back to
--     1: Decor.onRebirth first takes the decor up there back to your items) and the
--     staff (Staff.resetAll). It KEEPS the Casino Rank + XP, decor, rebirth coins +
--     rebirth upgrades, everything bought with Robux (passes, potions and running
--     potions, stored boost time), Tickets, stats, the casino's name + colours and
--     the daily / playtime progress.
--     The reward is booked first and every reset step runs on its own (pcall): a
--     step that fails leaves the player with a little too much, never with a reset
--     and no rebirth.
--   * the gate other modules use: Rebirth.count(player), Rebirth.allows(player,
--     need) (catalog / decor items carry `rebirth = N`, 0/nil = none),
--     Rebirth.lockedMessage(need), Rebirth.giveCoins(player, n) (rewards; the
--     caller pushes the snapshot).
--   * effect provider "rebirth": each owned rebirth upgrade adds values[level] to
--     its effect key (cashMult, xpMult, startCash, spawnBonus ...).
--   * remotes: Rebirth(expectedN?) -> { ok, message, count, coins, coinsTotal };
--     BuyRebirthUpgrade(id) -> { ok, message, level, coins }. The event RebirthDone
--     { count, coins, coinsTotal, unlocks, startCash } goes to that player (fanfare).
--   * the Player attribute "Rebirths" mirrors the count (HUD rank badge chip).
--   * snapshot (init.server, key "rebirth"): count, coins, upgrades, nextCost,
--     canRebirth, coinsBase / coinsPreview (what the next rebirth pays at its cost /
--     with the Cash you hold now), coinBonus + coinMult (the client recomputes the
--     preview live as Cash changes), startCash, effects (what the rebirth upgrades
--     add now), unlocks of the next rebirth { machines = {ids}, decor = {ids} }.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Config = require(Common:WaitForChild("Config"))
local Remotes = require(Common:WaitForChild("Remotes"))

-- report to GameEvents (quests & co. listen); never in the way of the action
local function gameEvent(player, name: string, amount: number?)
	local m = script.Parent:FindFirstChild("GameEvents")
	if not m then return end
	local ok, GE = pcall(require, m)
	if ok and type(GE) == "table" and GE.emit then pcall(GE.emit, player, name, amount) end
end

local Rebirth = {}
local Data, Economy, Placement, Upgrades, Staff, Buildings, Progression, Decor, pushData
local busy: {[number]: boolean} = {}   -- userId -> a rebirth is running
local started = false

------------------------------------------------------------------
-- helpers
------------------------------------------------------------------
local function money(n: number): string
	n = math.floor(tonumber(n) or 0)
	local a = math.abs(n)
	if a < 1e3 then return "$" .. tostring(n) end
	local units = { { 1e12, "T" }, { 1e9, "B" }, { 1e6, "M" }, { 1e3, "K" } }
	for _, u in units do
		if a >= u[1] then
			local v = n / u[1]
			local s = v >= 100 and ("%.0f"):format(v) or (v >= 10 and ("%.1f"):format(v) or ("%.2f"):format(v))
			if s:find("%.") then
				s = (s:gsub("0+$", ""))   -- 1.50 -> 1.5, 2.00 -> 2.
				s = (s:gsub("%.$", ""))   -- 2. -> 2
			end
			return "$" .. s .. u[2]
		end
	end
	return "$" .. tostring(n)
end

local function rebirthConfig()
	return Config.Rebirth
end

-- what the n-th rebirth costs (Cash on hand); math.huge if the config is missing
local function costOf(n: number): number
	local rc = rebirthConfig()
	if not (rc and type(rc.cost) == "function") then return math.huge end
	local ok, v = pcall(rc.cost, n)
	return (ok and tonumber(v)) or math.huge
end

-- the base coins of the n-th rebirth with `cash` on hand (before the effects)
local function baseCoins(n: number, cash: number): number
	local rc = rebirthConfig()
	if not (rc and type(rc.coins) == "function") then return 0 end
	local ok, v = pcall(rc.coins, n, cash)
	return (ok and math.max(0, math.floor(tonumber(v) or 0))) or 0
end

local function upgradeList()
	return Config.RebirthUpgrades or {}
end

local function upgradeDef(id: string)
	for _, def in upgradeList() do
		if def.id == id then return def end
	end
	return nil
end

-- the profile's rebirth table (Data v6 back-fills it), or nil
local function stateOf(profile)
	local st = profile and profile.Rebirth
	if type(st) ~= "table" then return nil end
	if type(st.upgrades) ~= "table" then st.upgrades = {} end
	return st
end

local function coinsHeld(st): number
	return math.max(0, math.floor(tonumber(st and st.coins) or 0))
end

local function effect(profile, key: string): number
	if not (Upgrades and profile) then return 0 end
	local ok, v = pcall(Upgrades.effect, profile, key)
	return (ok and tonumber(v)) or 0
end

-- Coin Magnet (+coins) and the 2x pass (x coins)
local function coinEffects(profile): (number, number)
	local bonus = math.max(0, math.floor(effect(profile, "rebirthCoinBonus") + 0.5))
	local mult = 1 + math.max(0, effect(profile, "rebirthCoinMult"))
	return bonus, mult
end

local function withEffects(base: number, bonus: number, mult: number): number
	return math.floor((base + bonus) * mult + 1e-9)
end

-- Cash a rebirth leaves you with (Head Start)
local function startCashOf(profile): number
	return math.max(Config.StartingCash or 0, math.floor(effect(profile, "startCash")))
end

-- catalog machines / decor that the k-th rebirth unlocks (`rebirth == k`)
local function unlocksFor(k: number)
	local machines, decor = {}, {}
	for _, def in Config.Catalog do
		if (tonumber(def.rebirth) or 0) == k then table.insert(machines, def.id) end
	end
	if type(Config.Decor) == "table" then
		for _, def in Config.Decor do
			if type(def) == "table" and def.id and (tonumber(def.rebirth) or 0) == k then
				table.insert(decor, def.id)
			end
		end
	end
	return { machines = machines, decor = decor }
end

------------------------------------------------------------------
-- the rebirth gate (MACHINES / DECOR / REWARDS use these)
------------------------------------------------------------------
function Rebirth.countOf(profile): number
	local st = stateOf(profile)
	return st and math.max(0, math.floor(tonumber(st.count) or 0)) or 0
end

function Rebirth.count(player: Player?): number
	if not (player and Data) then return 0 end
	return Rebirth.countOf(Data.get(player))
end

-- true when the player may buy something that needs `need` rebirths (0/nil = no gate)
function Rebirth.allows(player: Player?, need: number?): boolean
	local n = tonumber(need) or 0
	if n <= 0 then return true end
	return Rebirth.count(player) >= n
end

function Rebirth.lockedMessage(need: number?): string
	return ("Unlocks at Rebirth %d"):format(math.max(1, math.floor(tonumber(need) or 1)))
end

-- rebirth coins from a reward (Playtime ...); returns the new total. The caller
-- pushes the snapshot.
function Rebirth.giveCoins(player: Player?, n: number?): number
	local profile = player and Data and Data.get(player)
	local st = stateOf(profile)
	local add = math.floor(tonumber(n) or 0)
	if not st then return 0 end
	if add > 0 then st.coins = coinsHeld(st) + add end
	return coinsHeld(st)
end

-- what the next rebirth costs / pays a profile
function Rebirth.nextCost(profile): number
	return costOf(Rebirth.countOf(profile) + 1)
end

function Rebirth.coinsFor(profile, cash: number?): number
	local n = Rebirth.countOf(profile) + 1
	local bonus, mult = coinEffects(profile)
	local held = tonumber(cash) or tonumber(profile and profile.Cash) or 0
	return withEffects(baseCoins(n, math.max(held, costOf(n))), bonus, mult)
end

------------------------------------------------------------------
-- the effect provider: what the owned rebirth upgrades add (cheap: no yields)
------------------------------------------------------------------
local function provider(profile)
	local st = profile and profile.Rebirth
	local ups = type(st) == "table" and st.upgrades
	if type(ups) ~= "table" or next(ups) == nil then return nil end
	local out = {}
	for _, def in upgradeList() do
		local lvl = tonumber(ups[def.id]) or 0
		if lvl > 0 and def.values then
			local v = tonumber(def.values[math.min(math.floor(lvl), #def.values)]) or 0
			out[def.effect] = (out[def.effect] or 0) + v
		end
	end
	return out
end
Rebirth.effects = provider

------------------------------------------------------------------
-- the rebirth
------------------------------------------------------------------
local function step(name: string, fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then warn(("[Rebirth] %s: %s"):format(name, tostring(err))) end
	return ok
end

local function doRebirth(player: Player, profile, st, n: number, cash: number, cost: number)
	-- 1. the reward first (coins on what you bring, effects read before the reset)
	local bonus, mult = coinEffects(profile)
	local earned = withEffects(baseCoins(n, cash), bonus, mult)
	st.count = n
	st.coins = coinsHeld(st) + earned
	st.last = os.time()
	player:SetAttribute("Rebirths", n)

	-- 2. the reset: machines + stands (placed and stored)
	step("machines", function()
		if Placement and type(Placement.clearAll) == "function" then
			Placement.clearAll(player)
		else
			profile.Placed = {}
			profile.Inventory = {}
		end
	end)
	-- the 17 cash upgrade tracks
	profile.UpgradeLevels = {}
	-- staff (STAFF's module; plain profile reset if it isn't there)
	step("staff", function()
		if Staff and type(Staff.resetAll) == "function" then
			Staff.resetAll(player)
		else
			profile.Staff = {}
		end
	end)
	-- decor on the floors that are about to go back into your items, then the floors
	if Decor and type(Decor.onRebirth) == "function" then
		step("decor", Decor.onRebirth, player)
	end
	step("floors", function()
		if Buildings and type(Buildings.setStories) == "function" then
			Buildings.setStories(player, 1)
		elseif type(profile.Building) == "table" then
			profile.Building.stories = 1
		end
	end)
	-- Cash: a fresh start (Head Start raises it)
	step("cash", function()
		local target = startCashOf(profile)
		Economy.addCash(player, target - Economy.getCash(player))
	end)
	-- the income rate starts over (its warm-up averages the first minutes again)
	if type(profile.Stats) == "table" then profile.Stats.IncomeRate = 0 end
	if Progression and type(Progression.resetIncome) == "function" then
		step("income rate", Progression.resetIncome, player)
	end

	print(("[Rebirth] %s: rebirth %d with %s (needed %s), +%d coins (%d held)"):format(
		player.Name, n, money(cash), money(cost), earned, st.coins))

	-- 3. tell the player (fanfare), fresh snapshot, save
	local payload = {
		count = n, coins = earned, coinsTotal = st.coins, unlocks = unlocksFor(n),
		startCash = startCashOf(profile),
	}
	step("RebirthDone", function() Remotes.RebirthDone():FireClient(player, payload) end)
	if pushData then step("pushData", pushData, player) end
	task.spawn(function()
		if player.Parent and Data and Data.get(player) == profile then
			step("save", Data.save, player)
		end
	end)
	return {
		ok = true, message = ("Rebirth %d! +%d rebirth coins."):format(n, earned),
		count = n, coins = earned, coinsTotal = st.coins,
	}
end

-- expected: the rebirth number the client showed (a double click can't rebirth twice)
function Rebirth.rebirth(player: Player, expected: any?)
	local profile = Data and Data.get(player)
	local st = stateOf(profile)
	if not st then return { ok = false, message = "Your casino is still loading." } end
	if not rebirthConfig() then return { ok = false, message = "Rebirths aren't open yet." } end
	local uid = player.UserId
	if busy[uid] then return { ok = false, message = "Rebirth in progress..." } end
	local n = Rebirth.countOf(profile) + 1
	if expected ~= nil and tonumber(expected) ~= n then
		return { ok = false, message = "That rebirth already happened.", count = n - 1 }
	end
	local cost = costOf(n)
	local cash = Economy.getCash(player)
	if cash < cost then
		return { ok = false, message = ("Rebirth %d needs %s Cash on hand."):format(n, money(cost)), need = cost }
	end
	busy[uid] = true
	local ok, res = pcall(doRebirth, player, profile, st, n, cash, cost)
	busy[uid] = nil
	if not ok then
		warn("[Rebirth] rebirth failed: " .. tostring(res))
		return { ok = false, message = "Rebirth failed - try again." }
	end
	if type(res) == "table" and res.ok then gameEvent(player, "rebirth", 1) end
	return res
end

------------------------------------------------------------------
-- the REBIRTH SHOP
------------------------------------------------------------------
function Rebirth.buyUpgrade(player: Player, id: any)
	local def = type(id) == "string" and upgradeDef(id) or nil
	if not def then return { ok = false, message = "Unknown upgrade." } end
	local profile = Data and Data.get(player)
	local st = stateOf(profile)
	if not st then return { ok = false, message = "Your casino is still loading." } end
	local lvl = math.max(0, math.floor(tonumber(st.upgrades[def.id]) or 0))
	local max = #(def.values or {})
	if lvl >= max then return { ok = false, message = def.name .. " is maxed out." } end
	local cost = tonumber(def.costs and def.costs[lvl + 1]) or math.huge
	local coins = coinsHeld(st)
	if coins < cost then
		return { ok = false, message = ("Level %d needs %d rebirth coins."):format(lvl + 1, cost), need = cost }
	end
	st.coins = coins - cost
	st.upgrades[def.id] = lvl + 1
	return { ok = true, message = ("%s level %d!"):format(def.name, lvl + 1), level = lvl + 1, coins = st.coins }
end

------------------------------------------------------------------
-- snapshot (init.server buildSnapshot, key "rebirth")
------------------------------------------------------------------
function Rebirth.snapshot(player: Player, profile)
	profile = profile or (Data and Data.get(player))
	local st = stateOf(profile)
	if not st then return nil end
	local n = Rebirth.countOf(profile)
	local nextCost = costOf(n + 1)
	local cash = tonumber(profile.Cash) or 0
	local bonus, mult = coinEffects(profile)
	local coins = coinsHeld(st)
	local canBuy = false
	for _, def in upgradeList() do
		local lvl = tonumber(st.upgrades[def.id]) or 0
		local c = def.costs and def.costs[lvl + 1]
		if c and coins >= c then canBuy = true end
	end
	return {
		count = n,
		coins = coins,
		upgrades = table.clone(st.upgrades),
		nextCost = nextCost,
		canRebirth = cash >= nextCost,
		coinsBase = withEffects(baseCoins(n + 1, nextCost), bonus, mult),
		coinsPreview = withEffects(baseCoins(n + 1, math.max(cash, nextCost)), bonus, mult),
		coinBonus = bonus,
		coinMult = mult,
		canBuyUpgrade = canBuy,
		startCash = startCashOf(profile),
		effects = provider(profile) or {},
		unlocks = unlocksFor(n + 1),
	}
end

------------------------------------------------------------------
-- join / leave / start
------------------------------------------------------------------
function Rebirth.join(player: Player)
	player:SetAttribute("Rebirths", Rebirth.count(player))
end

function Rebirth.leave(player: Player)
	busy[player.UserId] = nil
end

-- deps (init.server): Data, Economy, Placement, Upgrades, Staff, Buildings,
-- Progression, Decor (optional), pushData
function Rebirth.start(deps)
	Data = deps.Data
	Economy = deps.Economy
	Placement = deps.Placement
	Upgrades = deps.Upgrades
	Staff = deps.Staff
	Buildings = deps.Buildings
	Progression = deps.Progression
	Decor = deps.Decor
	pushData = deps.pushData
	if started then return end
	started = true
	if Upgrades and type(Upgrades.addProvider) == "function" then
		Upgrades.addProvider("rebirth", provider)
	end
	Remotes.Rebirth().OnServerInvoke = function(player, expected)
		return Rebirth.rebirth(player, expected)   -- (pushes its own snapshot)
	end
	Remotes.BuyRebirthUpgrade().OnServerInvoke = function(player, id)
		local res = Rebirth.buyUpgrade(player, id)
		if res.ok and pushData then pushData(player) end
		return res
	end
	for _, player in Players:GetPlayers() do
		if Data.get(player) then Rebirth.join(player) end
	end
	print("[CasinoTycoon] Rebirth: rebirths + the rebirth shop are open.")
end

return Rebirth
