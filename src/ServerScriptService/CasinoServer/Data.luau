--!nonstrict
-- Data.luau — full per-player persistence.
-- Saves EVERYTHING in one table: Cash, Inventory (owned-unplaced machines),
-- Placed (machine layout as plot-relative CFrames), Staff, Stats, LastSeen.
--
-- Design notes (from research):
--  * UpdateAsync (read-modify-write) instead of SetAsync so two servers can't
--    blindly clobber each other.
--  * pcall + exponential backoff on every call (DataStore calls are network calls).
--  * Respect GetRequestBudgetForRequestType so we don't get throttled.
--  * Autosave loop + save on leave + BindToClose covers crashes/shutdowns.
--  * A lightweight session stamp (__jobId/__sessionTime) flags concurrent edits.
--  * CFrames can't be stored directly -> store the 12 components as numbers.
--
-- For a high-traffic production game, swapping this for ProfileStore (loleris)
-- gives bulletproof session-locking; the schema below is compatible.

local DataStoreService = game:GetService("DataStoreService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Config = require(Common:WaitForChild("Config"))

local Data = {}

-- Studio test store: with ServerStorage attribute CasinoTestStore = true when Play
-- starts, every save goes to a throwaway "<name>_studiotest" store (and the
-- leaderboards use the same suffix), so tests (a rebirth...) never touch real saves.
local STORE_SUFFIX = (RunService:IsStudio() and ServerStorage:GetAttribute("CasinoTestStore") == true)
	and "_studiotest" or ""

local store: DataStore? = nil
do
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(Config.DataStoreName .. STORE_SUFFIX)
	end)
	if ok then store = result else warn("[Data] DataStore unavailable; running in-memory only.") end
	if STORE_SUFFIX ~= "" then warn("[Data] STUDIO TEST STORE: saves go to " .. Config.DataStoreName .. STORE_SUFFIX) end
end

local profiles: {[number]: any} = {}   -- userId -> live in-memory table
local owners: {[any]: Player} = {}     -- live profile -> its player (effect providers)

-- "" normally, "_studiotest" with the Studio test store (append it to any other DataStore name)
function Data.storeSuffix(): string
	return STORE_SUFFIX
end

-- the player a live profile belongs to (nil once they left)
function Data.playerOf(profile): Player?
	return profile and owners[profile] or nil
end

------------------------------------------------------------------
-- CFrame (de)serialization
------------------------------------------------------------------
function Data.encodeCF(cf: CFrame): {number}
	return { cf:GetComponents() }       -- 12 numbers
end
function Data.decodeCF(t: {number}): CFrame
	if type(t) ~= "table" or #t < 12 then return CFrame.new() end
	return CFrame.new(table.unpack(t))
end

------------------------------------------------------------------
-- default profile + migration
------------------------------------------------------------------
local function defaultProfile()
	return {
		__version = Config.DataSchemaVersion,
		Cash = Config.StartingCash,
		Inventory = {},
		Placed = {},
		Staff = {},
		Upgrades = {},
		Receipts = {},   -- granted dev-product PurchaseIds (idempotency for ProcessReceipt)
		-- IncomeRate: EMA of unboosted net casino income ($/min, Progression) for
		-- offline income / daily cash / the ticket Cash Bundle
		-- XP: the Casino Rank (Progression; earned by every game a guest plays)
		Stats = { TotalEarned = 0, TotalPaidOut = 0, SpinsHosted = 0, BiggestWinPaid = 0, IncomeRate = 0, XP = 0 },
		LastSeen = 0,
		Tickets = 0,
		Daily = { lastClaim = 0, streak = 0 },   -- os.time() of last claim, consecutive claims
		BoostUntil = 0,                          -- os.time() until the ticket earnings boost runs
		-- the casino building: owned stories, the (filtered) name and the colour
		-- choices (indices into Config.Building.Palettes)
		Building = { stories = 1, name = "", theme = table.clone(Config.Building.DefaultTheme) },
		UpgradeLevels = {},                      -- track id -> level (Config.UpgradeTracks)
		-- v6 (the Rebirth & Rewards update)
		Rebirth = { count = 0, coins = 0, upgrades = {} },  -- upgrades: rebirth upgrade id -> level
		Potions = {},                            -- potion id -> owned (unused) count
		ActivePotions = {},                      -- potion id -> seconds left (ticks while online)
		StoredBoostSeconds = 0,                  -- x3 machine-boost time not on any machine
		Playtime = { day = 0, seconds = 0, claimed = {} },  -- UTC day, seconds played that day, claimed[i]
		Decor = {},                              -- placed decor: { placedId, decorId, cf }
		DecorInventory = {},                     -- decor id -> count (unplaced)
		-- v7 (the Cheaters & VIP update)
		Quests = {},                             -- Quests.luau: daily / weekly quest state
		Wheel = { nextFree = 0, spins = 0, total = 0 },  -- LuckyWheel: next free spin (os.time), bought spins, spun
		CheaterStats = { kicked = 0, caught = 0, honestKicked = 0 },  -- cheaters you / security threw out
	}
end

-- v6: the Casino Rank runs on XP. An old save gets the XP that keeps its rank and
-- how far it was into that rank (by TotalEarned on the old money thresholds).
local function xpFromLegacy(totalEarned: number): number
	local prog = Config.Progression
	local money = prog and prog.LegacyMoneyThresholds
	local ranks = prog and prog.Ranks
	if type(money) ~= "table" or type(ranks) ~= "table" or #ranks == 0 then return 0 end
	local te = math.max(0, tonumber(totalEarned) or 0)
	local r = 1
	for i, threshold in money do
		if te >= threshold then r = i end
	end
	r = math.min(r, #ranks)
	local function xpOf(i)
		local def = ranks[i]
		return def and tonumber(def.xp or def.threshold) or 0
	end
	local lo, hi = money[r] or 0, money[r + 1]
	if not hi or not ranks[r + 1] then return xpOf(r) end
	local frac = math.clamp((te - lo) / math.max(1, hi - lo), 0, 0.999)
	return math.floor(xpOf(r) + frac * (xpOf(r + 1) - xpOf(r)))
end
Data.xpFromLegacy = xpFromLegacy

local function tableOr(v, default)
	if type(v) == "table" then return v end
	return default
end

local function migrateV7(p, d)
	p.Quests = tableOr(p.Quests, {})
	p.Wheel = tableOr(p.Wheel, d.Wheel)
	p.Wheel.nextFree = tonumber(p.Wheel.nextFree) or 0
	p.Wheel.spins = math.max(0, math.floor(tonumber(p.Wheel.spins) or 0))
	p.Wheel.total = math.max(0, math.floor(tonumber(p.Wheel.total) or 0))
	p.CheaterStats = tableOr(p.CheaterStats, d.CheaterStats)
	for _, k in { "kicked", "caught", "honestKicked" } do
		p.CheaterStats[k] = math.max(0, math.floor(tonumber(p.CheaterStats[k]) or 0))
	end
end

local function migrateV6(p, d)
	p.Rebirth = tableOr(p.Rebirth, d.Rebirth)
	p.Rebirth.count = math.max(0, math.floor(tonumber(p.Rebirth.count) or 0))
	p.Rebirth.coins = math.max(0, math.floor(tonumber(p.Rebirth.coins) or 0))
	p.Rebirth.upgrades = tableOr(p.Rebirth.upgrades, {})
	p.Potions = tableOr(p.Potions, {})
	p.ActivePotions = tableOr(p.ActivePotions, {})
	p.StoredBoostSeconds = math.max(0, tonumber(p.StoredBoostSeconds) or 0)
	p.Playtime = tableOr(p.Playtime, d.Playtime)
	p.Playtime.day = tonumber(p.Playtime.day) or 0
	p.Playtime.seconds = math.max(0, tonumber(p.Playtime.seconds) or 0)
	p.Playtime.claimed = tableOr(p.Playtime.claimed, {})
	p.Decor = tableOr(p.Decor, {})
	p.DecorInventory = tableOr(p.DecorInventory, {})
	-- staff: hired = true (v5) -> level 1
	p.Staff = tableOr(p.Staff, {})
	for id, v in p.Staff do
		if v == true then
			p.Staff[id] = 1
		elseif type(v) ~= "number" or v < 1 then
			p.Staff[id] = nil
		else
			p.Staff[id] = math.floor(v)
		end
	end
	for _, entry in (p.Placed or {}) do
		if entry.boost ~= nil then entry.boost = math.max(0, tonumber(entry.boost) or 0) end
	end
end

local function migrateBuilding(p, d)
	if type(p.Building) ~= "table" then p.Building = d.Building end
	local b = p.Building
	b.stories = math.clamp(math.floor(tonumber(b.stories) or 1), 1, Config.Building.MaxStories)
	b.name = type(b.name) == "string" and b.name or ""
	if type(b.theme) ~= "table" then b.theme = table.clone(Config.Building.DefaultTheme) end
	for slot, default in Config.Building.DefaultTheme do
		local list = Config.Building.Palettes[slot]
		local i = math.floor(tonumber(b.theme[slot]) or default)
		b.theme[slot] = (i >= 1 and i <= #list) and i or default
	end
end

local function migrateUpgrades(p)
	if type(p.UpgradeLevels) ~= "table" then p.UpgradeLevels = {} end
	-- v4 and older had one-time upgrades: they become levels on the new tracks
	for _, oldId in (type(p.Upgrades) == "table" and p.Upgrades or {}) do
		local map = Config.LegacyUpgradeMap[oldId]
		if map then
			p.UpgradeLevels[map[1]] = math.max(p.UpgradeLevels[map[1]] or 0, map[2])
		end
	end
	p.Upgrades = {}
	for id, level in p.UpgradeLevels do
		local track = Config.getUpgradeTrack(id)
		if not track then
			p.UpgradeLevels[id] = nil
		else
			p.UpgradeLevels[id] = math.clamp(math.floor(tonumber(level) or 0), 0, #track.values)
		end
	end
end

local function migrate(p)
	local d = defaultProfile()
	for k, v in d do
		if p[k] == nil then p[k] = v end
	end
	if type(p.Stats) ~= "table" then p.Stats = d.Stats end
	local hadXP = p.Stats.XP ~= nil
	for k, v in d.Stats do
		if p.Stats[k] == nil then p.Stats[k] = v end
	end
	if not hadXP then
		p.Stats.XP = xpFromLegacy(p.Stats.TotalEarned)
	end
	p.Stats.XP = math.max(0, tonumber(p.Stats.XP) or 0)
	p.Stats.IncomeRate = math.max(0, tonumber(p.Stats.IncomeRate) or 0)
	if type(p.Daily) ~= "table" then p.Daily = d.Daily end
	p.Daily.lastClaim = tonumber(p.Daily.lastClaim) or 0
	p.Daily.streak = tonumber(p.Daily.streak) or 0
	p.Tickets = tonumber(p.Tickets) or 0
	p.BoostUntil = tonumber(p.BoostUntil) or 0
	migrateBuilding(p, d)
	migrateUpgrades(p)
	migrateV6(p, d)
	migrateV7(p, d)
	for _, entry in (p.Placed or {}) do
		if type(entry.upgrades) ~= "table" then
			entry.upgrades = { speed = 0, bets = 0, lucky = 0 }
		else
			entry.upgrades.speed = entry.upgrades.speed or 0
			entry.upgrades.bets = entry.upgrades.bets or 0
			entry.upgrades.lucky = entry.upgrades.lucky or 0
		end
	end
	p.__version = Config.DataSchemaVersion
	return p
end

local function keyFor(userId: number): string
	return "Player_" .. userId
end

------------------------------------------------------------------
-- budget-aware retry wrapper
------------------------------------------------------------------
local function waitForBudget(reqType: Enum.DataStoreRequestType)
	if not store then return end
	local waited = 0
	while DataStoreService:GetRequestBudgetForRequestType(reqType) < 1 and waited < 30 do
		task.wait(1)
		waited += 1
	end
end

local function retry(fn): (boolean, any)
	local attempts, delay = 0, 1
	while attempts < 5 do
		attempts += 1
		local ok, result = pcall(fn)
		if ok then return true, result end
		warn("[Data] attempt " .. attempts .. " failed: " .. tostring(result))
		task.wait(delay)
		delay = math.min(delay * 2, 8)   -- exponential backoff, capped
	end
	return false, nil
end

------------------------------------------------------------------
-- load / save / release
------------------------------------------------------------------
function Data.load(player: Player)
	local userId = player.UserId
	if profiles[userId] then return profiles[userId] end

	if not store then
		local p = defaultProfile()
		profiles[userId] = p
		owners[p] = player
		return p
	end

	waitForBudget(Enum.DataStoreRequestType.UpdateAsync)
	local ok, data = retry(function()
		return store:UpdateAsync(keyFor(userId), function(old)
			old = migrate(old or defaultProfile())
			-- best-effort session stamp
			old.__jobId = game.JobId
			old.__sessionTime = os.time()
			return old
		end)
	end)

	if not ok or type(data) ~= "table" then
		warn("[Data] load failed for " .. player.Name .. "; using fresh profile (will try to save later).")
		data = defaultProfile()
	end
	profiles[userId] = data
	owners[data] = player
	return data
end

function Data.get(player: Player)
	return profiles[player.UserId]
end

-- true when a real DataStore is backing us (false in Studio without API access)
function Data.isPersistent(): boolean
	return store ~= nil
end

function Data.save(player: Player): boolean
	local userId = player.UserId
	local p = profiles[userId]
	if not p or not store then return false end

	waitForBudget(Enum.DataStoreRequestType.UpdateAsync)
	local ok = retry(function()
		return store:UpdateAsync(keyFor(userId), function()
			p.__jobId = game.JobId
			p.__sessionTime = os.time()
			return p
		end)
	end)
	return ok
end

function Data.release(player: Player)
	local userId = player.UserId
	local p = profiles[userId]
	if p then p.LastSeen = os.time() end

	if store and p then
		waitForBudget(Enum.DataStoreRequestType.UpdateAsync)
		retry(function()
			return store:UpdateAsync(keyFor(userId), function()
				p.__jobId = nil          -- release the soft lock so other servers can load
				p.__sessionTime = os.time()
				return p
			end)
		end)
	end
	profiles[userId] = nil
	if p then owners[p] = nil end
end

------------------------------------------------------------------
-- start: autosave loop + shutdown save
------------------------------------------------------------------
function Data.start()
	task.spawn(function()
		while true do
			task.wait(Config.AutosaveInterval)
			for _, player in Players:GetPlayers() do
				if profiles[player.UserId] then
					Data.save(player)
				end
			end
		end
	end)

	game:BindToClose(function()
		-- save everyone in parallel within the ~30s shutdown window
		local pending = 0
		for _, player in Players:GetPlayers() do
			pending += 1
			task.spawn(function()
				Data.release(player)
				pending -= 1
			end)
		end
		local waited = 0
		while pending > 0 and waited < 25 do
			task.wait(0.5)
			waited += 0.5
		end
		if RunService:IsStudio() then task.wait(1) end
	end)
end

return Data
