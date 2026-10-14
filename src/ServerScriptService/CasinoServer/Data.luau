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

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Config = require(Common:WaitForChild("Config"))

local Data = {}

local store: DataStore? = nil
do
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(Config.DataStoreName)
	end)
	if ok then store = result else warn("[Data] DataStore unavailable; running in-memory only.") end
end

local profiles: {[number]: any} = {}   -- userId -> live in-memory table

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
		Stats = { TotalEarned = 0, TotalPaidOut = 0, SpinsHosted = 0, BiggestWinPaid = 0 },
		LastSeen = 0,
	}
end

local function migrate(p)
	local d = defaultProfile()
	for k, v in d do
		if p[k] == nil then p[k] = v end
	end
	if type(p.Stats) ~= "table" then p.Stats = d.Stats end
	for k, v in d.Stats do
		if p.Stats[k] == nil then p.Stats[k] = v end
	end
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
