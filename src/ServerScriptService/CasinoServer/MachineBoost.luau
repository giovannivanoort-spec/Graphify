--!nonstrict
-- MachineBoost.luau — the x3 machine boost (Config.MachineBoost), a Robux product
-- bought from a machine's popup (client ManageUI + BoostFX).
--   * time lives on the placed entry: profile.Placed[i].boost = seconds left. A
--     picked-up / sold / rebirthed machine moves its time to profile.StoredBoostSeconds
--     (Placement), which rewards add to as well (MachineBoost.give).
--   * purchase flow: the client calls SetBoostTarget(placedId), then prompts the
--     `machine_boost` product; ProcessReceipt (Monetization) calls
--     MachineBoost.grantPurchase(player, seconds): the time goes onto the picked
--     machine if it's still placed (and was picked within TargetTTL), else onto the
--     stored time. Buying again ADDS time (the multiplier stays x3).
--     ApplyStoredBoost(placedId, seconds?) moves stored time onto a machine (all of
--     it without `seconds`).
--   * ticks once a second while the owner is online. MachineBoost.multiplier(machine)
--     = Multiplier while the machine has time left (Gambling calls it every round: one
--     table lookup). The model's "BoostLeft" attribute (seconds, refreshed every ~5 s
--     and on every change) drives the clients' aura (BoostFX).
--   * snapshot (init.server key `boosts`): { stored = seconds, mult, seconds (per
--     purchase), max (per machine) }; every placed[i] carries `boost` (init.server).
-- Only gambling machines take a boost (stands earn outside game rounds).
-- Studio test aid: with the Studio test store on (ServerStorage.CasinoTestStore), the
-- ServerStorage attribute CasinoTestBoost = seconds adds that much stored time on join.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Config = require(Common:WaitForChild("Config"))
local Remotes = require(Common:WaitForChild("Remotes"))

local MachineBoost = {}
local Data, Plots, pushData
local started = false

local CFG = Config.MachineBoost or {}
local MULT = tonumber(CFG.Multiplier) or 3
local CHUNK = tonumber(CFG.Seconds) or 900
local MAX_ON_MACHINE = tonumber(CFG.MaxSeconds) or 24 * 3600
local TARGET_TTL = tonumber(CFG.TargetTTL) or 600
local TICK = 1           -- seconds between ticks
local ATTR_EVERY = 5     -- seconds between BoostLeft attribute refreshes
local CALL_COOLDOWN = 0.2

local live: {[Instance]: any} = {}                         -- boosted machine model -> its placed entry
local modelFor = setmetatable({}, { __mode = "k" })        -- placed entry -> its model (cache)
local pending: {[number]: { placedId: string, t: number }} = {}   -- userId -> the machine picked to buy for
local lastCall: {[number]: number} = {}

local function clock(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	local h, m, s = seconds // 3600, (seconds % 3600) // 60, seconds % 60
	if h > 0 then return ("%d:%02d:%02d"):format(h, m, s) end
	return ("%d:%02d"):format(m, s)
end

------------------------------------------------------------------
-- the hot path: Gambling.payOwner -> earnings multiplier, every game round
------------------------------------------------------------------
function MachineBoost.multiplier(machine: Instance?): number
	local e = machine and live[machine]
	if e and (tonumber(e.boost) or 0) > 0 then return MULT end
	return 1
end

------------------------------------------------------------------
-- helpers
------------------------------------------------------------------
local function entryOf(profile, placedId)
	if type(placedId) ~= "string" or type(profile) ~= "table" or type(profile.Placed) ~= "table" then return nil end
	for _, e in profile.Placed do
		if e.placedId == placedId then return e end
	end
	return nil
end

-- only gambling machines take a boost
local function isGambling(e): boolean
	local def = e and Config.getMachineDef(e.machineId)
	return def ~= nil and not Config.isConcession(def)
end

local function findModel(player: Player, e): Instance?
	local m = modelFor[e]
	if m and m.Parent and m:GetAttribute("PlacedId") == e.placedId then return m end
	m = nil
	local rec = Plots and Plots.getRecordForOwner(player.UserId)
	if rec then
		for _, inst in rec.machines do
			if inst.Parent and inst:GetAttribute("PlacedId") == e.placedId then
				m = inst
				break
			end
		end
	end
	modelFor[e] = m
	return m
end

-- mirror an entry's time onto its model (the live map + the BoostLeft attribute)
local function sync(player: Player, e)
	local model = findModel(player, e)
	if not model then return end
	local left = tonumber(e.boost) or 0
	if left > 0 then
		live[model] = e
		model:SetAttribute("BoostLeft", math.ceil(left))
	else
		live[model] = nil
		model:SetAttribute("BoostLeft", nil)
	end
end

-- add up to `seconds` onto a placed entry (capped at MaxSeconds); returns what fit
local function addTo(e, seconds: number): number
	local cur = math.max(0, tonumber(e.boost) or 0)
	local fit = math.clamp(math.floor(seconds), 0, math.max(0, math.floor(MAX_ON_MACHINE - cur)))
	if fit > 0 then e.boost = cur + fit end
	return fit
end

local function stored(profile): number
	return math.max(0, tonumber(profile.StoredBoostSeconds) or 0)
end

local function rateLimited(player: Player): boolean
	local now = os.clock()
	if now - (lastCall[player.UserId] or -math.huge) < CALL_COOLDOWN then return true end
	lastCall[player.UserId] = now
	return false
end

------------------------------------------------------------------
-- grants
------------------------------------------------------------------
-- a machine-boost purchase (ProcessReceipt): onto the machine picked with
-- SetBoostTarget (still placed, picked within TargetTTL), else onto the stored time.
-- Returns { placedId?, machineId?, seconds (on that machine now), added, toStored,
-- stored } or nil when the player's data isn't loaded.
function MachineBoost.grantPurchase(player: Player, seconds: number?)
	local profile = Data and Data.get(player)
	if not profile then return nil end
	local s = math.floor(tonumber(seconds) or CHUNK)
	if s <= 0 then return nil end
	local target = pending[player.UserId]
	local e = nil
	if target and os.clock() - target.t <= TARGET_TTL then
		e = entryOf(profile, target.placedId)
		if e and not isGambling(e) then e = nil end
	end
	local added = 0
	if e then
		added = addTo(e, s)
		sync(player, e)
	end
	local rest = s - added
	if rest > 0 then profile.StoredBoostSeconds = stored(profile) + rest end
	return {
		placedId = e and e.placedId or nil, machineId = e and e.machineId or nil,
		seconds = e and (tonumber(e.boost) or 0) or 0, added = added, toStored = rest, stored = stored(profile),
	}
end

-- reward: `seconds` of x3 onto the stored time (applied from any machine's popup)
function MachineBoost.give(player: Player?, seconds: number?): boolean
	local profile = player and Data and Data.get(player)
	local s = math.floor(tonumber(seconds) or 0)
	if not profile or s <= 0 then return false end
	profile.StoredBoostSeconds = stored(profile) + s
	return true
end

-- move stored time onto a placed gambling machine (all of it when `seconds` is nil)
function MachineBoost.applyStored(player: Player, placedId: any, seconds: any)
	local profile = Data and Data.get(player)
	if not profile then return { ok = false, message = "Data not ready." } end
	local have = math.floor(stored(profile))
	if have <= 0 then return { ok = false, message = "You have no stored boost time." } end
	local e = entryOf(profile, placedId)
	if not e then return { ok = false, message = "That machine isn't placed in your casino." } end
	if not isGambling(e) then return { ok = false, message = "Only game machines can be boosted." } end
	local want = have
	if seconds ~= nil then want = math.clamp(math.floor(tonumber(seconds) or 0), 0, have) end
	if want <= 0 then return { ok = false, message = "Nothing to apply." } end
	local fit = addTo(e, want)
	if fit <= 0 then return { ok = false, message = "This machine is boosted to the max." } end
	profile.StoredBoostSeconds = math.max(0, stored(profile) - fit)
	sync(player, e)
	return {
		ok = true, seconds = tonumber(e.boost) or 0, added = fit, stored = stored(profile),
		message = ("x%d BOOST +%s: %s left!"):format(MULT, clock(fit), clock(tonumber(e.boost) or 0)),
	}
end

-- seconds of boost left on a placed machine (by placedId)
function MachineBoost.secondsLeft(player: Player, placedId: string): number
	local e = entryOf(Data and Data.get(player), placedId)
	return e and math.max(0, tonumber(e.boost) or 0) or 0
end

------------------------------------------------------------------
-- the clock: only online owners' machines tick
------------------------------------------------------------------
local sinceAttr = 0
function MachineBoost.tick(dt: number)
	sinceAttr += dt
	local refresh = sinceAttr >= ATTR_EVERY
	if refresh then sinceAttr = 0 end
	for _, player in Players:GetPlayers() do
		local profile = Data and Data.get(player)
		if profile and type(profile.Placed) == "table" then
			local expired = false
			for _, e in profile.Placed do
				local b = tonumber(e.boost)
				if b and b > 0 then
					b -= dt
					if b <= 0 then
						e.boost = nil
						expired = true
						sync(player, e)
					else
						e.boost = b
						local model = findModel(player, e)
						if model then
							if live[model] ~= e then live[model] = e end
							if refresh or model:GetAttribute("BoostLeft") == nil then
								model:SetAttribute("BoostLeft", math.ceil(b))
							end
						end
					end
				elseif e.boost ~= nil then
					e.boost = nil
				end
			end
			if expired and pushData then
				local ok, err = pcall(pushData, player)
				if not ok then warn("[MachineBoost] pushData: " .. tostring(err)) end
			end
		end
	end
	-- machines that are gone, picked up or out of time
	for model, e in live do
		if not model.Parent or (tonumber(e.boost) or 0) <= 0 then
			live[model] = nil
			if model.Parent then model:SetAttribute("BoostLeft", nil) end
		end
	end
end

------------------------------------------------------------------
-- snapshot / join / leave / start
------------------------------------------------------------------
function MachineBoost.snapshot(player: Player, profile)
	profile = profile or (Data and Data.get(player))
	return {
		stored = type(profile) == "table" and math.floor(stored(profile)) or 0,
		mult = MULT, seconds = CHUNK, max = MAX_ON_MACHINE,
	}
end

-- after Placement.restore: put the saved boosts back on the rebuilt models
function MachineBoost.join(player: Player)
	local profile = Data and Data.get(player)
	if not profile then return end
	profile.StoredBoostSeconds = stored(profile)
	for _, e in (type(profile.Placed) == "table" and profile.Placed or {}) do
		if (tonumber(e.boost) or 0) > 0 then sync(player, e) end
	end
	-- Studio test aid (only with the throwaway test store)
	if RunService:IsStudio() and Data.storeSuffix and Data.storeSuffix() ~= "" then
		local s = tonumber(ServerStorage:GetAttribute("CasinoTestBoost"))
		if s and s > 0 then MachineBoost.give(player, s) end
	end
end

function MachineBoost.leave(player: Player)
	pending[player.UserId] = nil
	lastCall[player.UserId] = nil
	-- (Plots.release destroys the models right after; the next tick drops them from `live`)
end

-- deps: Data, Plots, pushData
function MachineBoost.start(deps)
	Data = deps.Data
	Plots = deps.Plots
	pushData = deps.pushData
	if started then return end
	started = true

	-- the machine the next machine-boost purchase is for (nil / "" = the stored time)
	Remotes.SetBoostTarget().OnServerInvoke = function(player: Player, placedId)
		if placedId == nil or placedId == "" then
			pending[player.UserId] = nil
			return { ok = true }
		end
		if type(placedId) ~= "string" then return { ok = false, message = "Unknown machine." } end
		local e = entryOf(Data and Data.get(player), placedId)
		if not e then return { ok = false, message = "That machine isn't placed in your casino." } end
		if not isGambling(e) then return { ok = false, message = "Only game machines can be boosted." } end
		pending[player.UserId] = { placedId = placedId, t = os.clock() }
		return { ok = true, seconds = tonumber(e.boost) or 0 }
	end

	Remotes.ApplyStoredBoost().OnServerInvoke = function(player: Player, placedId, seconds)
		if rateLimited(player) then return { ok = false, message = "Slow down!" } end
		local ok, res = pcall(MachineBoost.applyStored, player, placedId, seconds)
		if not ok then
			warn("[MachineBoost] apply: " .. tostring(res))
			return { ok = false, message = "Couldn't apply the boost." }
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
			local ok, err = pcall(MachineBoost.tick, dt)
			if not ok then warn("[MachineBoost] tick: " .. tostring(err)) end
		end
	end)
end

return MachineBoost
