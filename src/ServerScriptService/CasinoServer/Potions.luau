--!nonstrict
-- Potions.luau — timed potions (Config.Potions).
--   * stock: profile.Potions[id] = count (unused). Potions.give(player, id, count) adds
--     to it: Robux receipts (Monetization), the Ticket Shop (Rewards), the daily /
--     playtime rewards.
--   * remote UsePotion(potionId): takes one from the stock and ADDS
--     minutes x (1 + potionTime effect) to profile.ActivePotions[id] (seconds left),
--     up to Config.PotionMaxStackMinutes.
--   * the timers tick once a second, only while the owner is online (only online
--     players' profiles are loaded); a potion that runs out pushes a fresh snapshot.
--   * effects: the Upgrades provider "potions" returns the running potions' effects,
--     the largest value per key (two potions sharing a key don't stack; MEGA covers
--     them all), cached per profile (NPCs read it every flow tick, Gambling every round).
--   * snapshot (init.server key `potions`): { owned = { id = count }, active = { id =
--     seconds left }, perUse = { id = seconds one use adds }, maxStack = seconds }
-- Studio test aid: with the Studio test store on (ServerStorage.CasinoTestStore), the
-- ServerStorage attribute CasinoTestPotions = "cash:2,mega:1" gives those potions on join.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
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

local Potions = {}
local Data, Upgrades, pushData
local started = false

local TICK = 1              -- seconds between timer ticks
local USE_COOLDOWN = 0.25   -- seconds between two UsePotion calls of one player

local cache: {[any]: {[string]: number}} = {}   -- profile -> the effects of its running potions
local lastUse: {[number]: number} = {}
local EMPTY = {}

local function defOf(id: any)
	if type(id) ~= "string" then return nil end
	return Config.getPotion(id)
end

local function ensure(profile)
	if type(profile.Potions) ~= "table" then profile.Potions = {} end
	if type(profile.ActivePotions) ~= "table" then profile.ActivePotions = {} end
end

local function clock(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	local h, m, s = seconds // 3600, (seconds % 3600) // 60, seconds % 60
	if h > 0 then return ("%d:%02d:%02d"):format(h, m, s) end
	return ("%d:%02d"):format(m, s)
end

local function maxStack(): number
	return (tonumber(Config.PotionMaxStackMinutes) or 1440) * 60
end

------------------------------------------------------------------
-- effects (the Upgrades provider)
------------------------------------------------------------------
local function computeEffects(profile)
	local out = {}
	local active = profile.ActivePotions
	if type(active) ~= "table" then return out end
	for id, left in active do
		local def = defOf(id)
		if def and (tonumber(left) or 0) > 0 then
			for key, v in def.effects or {} do
				if type(v) == "number" and v > (out[key] or 0) then out[key] = v end
			end
		end
	end
	return out
end

-- { [effectKey] = value } of the potions running on `profile` (cached; never mutate it)
function Potions.effects(profile)
	if type(profile) ~= "table" then return EMPTY end
	local e = cache[profile]
	if e == nil then
		e = computeEffects(profile)
		cache[profile] = e
	end
	return e
end

-- the owner's potion-time bonus (Potion Master rebirth upgrade: potionTime)
local function timeBonus(profile): number
	if not (Upgrades and profile) then return 0 end
	local ok, v = pcall(Upgrades.effect, profile, "potionTime")
	return (ok and type(v) == "number") and math.max(0, v) or 0
end

-- seconds one use of `def` adds for this owner
function Potions.durationFor(profile, def, bonus: number?): number
	local b = bonus or timeBonus(profile)
	return math.floor((tonumber(def and def.minutes) or 15) * 60 * (1 + b) + 0.5)
end

------------------------------------------------------------------
-- stock + use
------------------------------------------------------------------
-- add `count` (default 1) potions of `id` to the player's stock; false if unknown.
-- (no snapshot push: the caller's remote / receipt pushes one)
function Potions.give(player: Player?, id: string, count: number?): boolean
	local def = defOf(id)
	local profile = player and Data and Data.get(player)
	if not (def and profile) then return false end
	local n = math.floor(tonumber(count) or 1)
	if n <= 0 then return false end
	ensure(profile)
	profile.Potions[def.id] = math.max(0, math.floor(tonumber(profile.Potions[def.id]) or 0)) + n
	return true
end

-- unused potions of `id` the player owns
function Potions.count(player: Player?, id: string): number
	local profile = player and Data and Data.get(player)
	local stock = profile and profile.Potions
	return type(stock) == "table" and math.max(0, math.floor(tonumber(stock[id]) or 0)) or 0
end

-- seconds left on the player's `id` potion (0 = not running)
function Potions.secondsLeft(player: Player?, id: string): number
	local profile = player and Data and Data.get(player)
	local active = profile and profile.ActivePotions
	return type(active) == "table" and math.max(0, tonumber(active[id]) or 0) or 0
end

function Potions.use(player: Player, id: any)
	local def = defOf(id)
	if not def then return { ok = false, message = "Unknown potion." } end
	local profile = Data and Data.get(player)
	if not profile then return { ok = false, message = "Data not ready." } end
	ensure(profile)
	local have = math.max(0, math.floor(tonumber(profile.Potions[def.id]) or 0))
	if have <= 0 then
		return { ok = false, message = ("You have no %s."):format(def.name), needPotion = def.id }
	end
	local left = math.max(0, tonumber(profile.ActivePotions[def.id]) or 0)
	local add = Potions.durationFor(profile, def)
	local cap = maxStack()
	if left + add > cap then
		return { ok = false, message = ("A %s stacks up to %s."):format(def.name, clock(cap)) }
	end
	have -= 1
	profile.Potions[def.id] = have > 0 and have or nil
	profile.ActivePotions[def.id] = left + add
	cache[profile] = nil
	local message = left > 0
		and ("%s +%s: %s left!"):format(def.name, clock(add), clock(left + add))
		or ("%s active for %s!"):format(def.name, clock(add))
	gameEvent(player, "potionUsed", 1)
	return { ok = true, potion = def.id, seconds = left + add, added = add, owned = have, message = message }
end

------------------------------------------------------------------
-- timers (only online profiles are loaded, so they only run while you play)
------------------------------------------------------------------
function Potions.tick(dt: number)
	for _, player in Players:GetPlayers() do
		local profile = Data and Data.get(player)
		local active = profile and profile.ActivePotions
		if type(active) == "table" and next(active) ~= nil then
			local ended = false
			for id, left in active do
				local v = (tonumber(left) or 0) - dt
				if v <= 0 or not defOf(id) then
					active[id] = nil
					ended = true
				else
					active[id] = v
				end
			end
			cache[profile] = nil
			if ended and pushData then
				local ok, err = pcall(pushData, player)
				if not ok then warn("[Potions] pushData: " .. tostring(err)) end
			end
		end
	end
end

------------------------------------------------------------------
-- snapshot / join / leave / start
------------------------------------------------------------------
function Potions.snapshot(player: Player, profile)
	profile = profile or (Data and Data.get(player))
	local owned, active, perUse = {}, {}, {}
	if type(profile) == "table" then
		for id, n in (type(profile.Potions) == "table" and profile.Potions or {}) do
			n = math.floor(tonumber(n) or 0)
			if n > 0 and defOf(id) then owned[id] = n end
		end
		for id, s in (type(profile.ActivePotions) == "table" and profile.ActivePotions or {}) do
			s = tonumber(s) or 0
			if s > 0 and defOf(id) then active[id] = math.floor(s * 10) / 10 end
		end
		local bonus = timeBonus(profile)
		for _, def in Config.Potions do perUse[def.id] = Potions.durationFor(profile, def, bonus) end
	end
	return { owned = owned, active = active, perUse = perUse, maxStack = maxStack() }
end

function Potions.join(player: Player)
	local profile = Data and Data.get(player)
	if not profile then return end
	ensure(profile)
	cache[profile] = nil
	-- Studio test aid (only with the throwaway test store)
	if RunService:IsStudio() and Data.storeSuffix and Data.storeSuffix() ~= "" then
		local spec = ServerStorage:GetAttribute("CasinoTestPotions")
		if type(spec) == "string" and spec ~= "" then
			for id, n in spec:gmatch("([%a_]+):?(%d*)") do
				Potions.give(player, id, tonumber(n) or 1)
			end
		end
	end
end

function Potions.leave(player: Player)
	local profile = Data and Data.get(player)
	if profile then cache[profile] = nil end
	lastUse[player.UserId] = nil
end

-- deps: Data, Upgrades (the provider + potionTime), pushData
function Potions.start(deps)
	Data = deps.Data
	Upgrades = deps.Upgrades
	pushData = deps.pushData
	if started then return end
	started = true

	if Upgrades and Upgrades.addProvider then
		Upgrades.addProvider("potions", function(profile) return Potions.effects(profile) end)
	end

	Remotes.UsePotion().OnServerInvoke = function(player: Player, potionId)
		local now = os.clock()
		if now - (lastUse[player.UserId] or -math.huge) < USE_COOLDOWN then
			return { ok = false, message = "Slow down!" }
		end
		lastUse[player.UserId] = now
		local ok, res = pcall(Potions.use, player, potionId)
		if not ok then
			warn("[Potions] use: " .. tostring(res))
			return { ok = false, message = "Couldn't use that potion." }
		end
		if res.ok and pushData then pushData(player) end
		return res
	end

	task.spawn(function()
		local last = os.clock()
		while true do
			task.wait(TICK)
			local now = os.clock()
			local dt = math.clamp(now - last, 0, 5)   -- a server hitch never eats more than 5 s
			last = now
			local ok, err = pcall(Potions.tick, dt)
			if not ok then warn("[Potions] tick: " .. tostring(err)) end
		end
	end)
end

return Potions
