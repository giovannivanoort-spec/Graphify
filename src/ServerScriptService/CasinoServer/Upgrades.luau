--!nonstrict
-- Upgrades.luau — levelled owner upgrade tracks (Config.UpgradeTracks).
-- profile.UpgradeLevels[trackId] = level. Each track drives one effect key;
-- Upgrades.effect sums the tracks' values at their current levels. Every level
-- has a Casino Rank gate (track.gates): it only blocks buying that level, owned
-- levels above the owner's rank keep working.
-- Other systems add to the same effect keys through providers
-- (Upgrades.addProvider: rebirth upgrades, potions, staff, game passes, decor),
-- so every reader of Upgrades.effect(s) sees the total.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Config = require(Common:WaitForChild("Config"))

local Upgrades = {}
local Economy, Data, Progression

------------------------------------------------------------------
-- effect providers: name -> fn(profile, player?) -> { [effectKey] = number }
-- (one per module, registered in its start(); cheap, no yields: NPCs read
-- every casino's effects each flow tick)
------------------------------------------------------------------
local providers: {[string]: (any, Player?) -> any} = {}
local providerOrder: {string} = {}
local lastWarn: {[string]: number} = {}

function Upgrades.addProvider(name: string, fn)
	if type(name) ~= "string" or type(fn) ~= "function" then return end
	if not providers[name] then table.insert(providerOrder, name) end
	providers[name] = fn
end

local function playerOf(profile): Player?
	return Data and Data.playerOf and Data.playerOf(profile) or nil
end

-- add every provider's values into `out` (only `key` when given)
local function addProviders(profile, out, key: string?)
	if #providerOrder == 0 then return out end
	local player = playerOf(profile)
	for _, name in providerOrder do
		local ok, res = pcall(providers[name], profile, player)
		if ok then
			if type(res) == "table" then
				if key then
					local v = res[key]
					if type(v) == "number" then out[key] = (out[key] or 0) + v end
				else
					for k, v in res do
						if type(v) == "number" then out[k] = (out[k] or 0) + v end
					end
				end
			end
		elseif os.clock() - (lastWarn[name] or -math.huge) > 30 then
			lastWarn[name] = os.clock()
			warn(("[Upgrades] effect provider %s: %s"):format(name, tostring(res)))
		end
	end
	return out
end

function Upgrades.level(profile, id: string): number
	if not profile or type(profile.UpgradeLevels) ~= "table" then return 0 end
	return profile.UpgradeLevels[id] or 0
end

-- kept for older callers: "owns" a track once it has at least one level
function Upgrades.has(profile, id: string): boolean
	return Upgrades.level(profile, id) > 0
end

-- Sum the named effect key across every track the owner has levels in, plus
-- what the providers add.
function Upgrades.effect(profile, key: string): number
	if not profile then return 0 end
	local total = 0
	if type(profile.UpgradeLevels) == "table" then
		for _, track in Config.UpgradeTracks do
			if track.effect == key then
				local lvl = profile.UpgradeLevels[track.id] or 0
				if lvl > 0 then total += track.values[math.min(lvl, #track.values)] end
			end
		end
	end
	local extra = addProviders(profile, {}, key)
	return total + (extra[key] or 0)
end

-- Every effect key at once ({ [effect] = total }, keys without levels absent):
-- one pass over the tracks for callers that need many (NPCs, each tick).
function Upgrades.effects(profile)
	local out = {}
	if not profile then return out end
	if type(profile.UpgradeLevels) == "table" then
		for _, track in Config.UpgradeTracks do
			local lvl = profile.UpgradeLevels[track.id] or 0
			if lvl > 0 then
				out[track.effect] = (out[track.effect] or 0) + track.values[math.min(lvl, #track.values)]
			end
		end
	end
	return addProviders(profile, out, nil)
end

-- Same, but looked up by userId (used by NPCs / Traffic for casino owners).
function Upgrades.effectForUser(userId: number, key: string): number
	local player = Players:GetPlayerByUserId(userId)
	if not player then return 0 end
	return Upgrades.effect(Data.get(player), key)
end

-- the Casino Rank level `level` of a track needs (nil = no gate)
function Upgrades.gateFor(track, level: number): number?
	return track and track.gates and track.gates[level] or nil
end

-- Buy the next level of a track.
function Upgrades.buy(player: Player, id: string)
	local track = Config.getUpgradeTrack(id)
	if not track then return { ok = false, message = "Unknown upgrade." } end
	local profile = Data.get(player)
	if not profile then return { ok = false, message = "Profile not loaded." } end
	profile.UpgradeLevels = profile.UpgradeLevels or {}
	local lvl = profile.UpgradeLevels[id] or 0
	if lvl >= #track.values then
		return { ok = false, message = track.name .. " is maxed out." }
	end
	local need = Upgrades.gateFor(track, lvl + 1)
	if need and Progression and (Progression.rank(profile)) < need then
		return { ok = false, message = Progression.levelLockedMessage(lvl + 1, need), needRank = need }
	end
	local cost = track.costs[lvl + 1]
	if Economy.getCash(player) < cost then
		return { ok = false, message = "Not enough " .. Config.CurrencyName .. "." }
	end
	if not Economy.tryWithdraw(player, cost) then
		return { ok = false, message = "Purchase failed." }
	end
	profile.UpgradeLevels[id] = lvl + 1
	return { ok = true, message = ("%s level %d!"):format(track.name, lvl + 1), level = lvl + 1 }
end

-- what the client needs to draw the upgrade cards (gates[L] = the rank level L needs)
function Upgrades.catalog()
	local out = {}
	for _, t in Config.UpgradeTracks do
		table.insert(out, { id = t.id, name = t.name, desc = t.desc, icon = t.icon, tone = t.tone,
			effect = t.effect, values = t.values, costs = t.costs, format = t.format,
			gates = t.gates or {}, group = t.group })
	end
	return out
end

function Upgrades.start(deps)
	Economy = deps.Economy
	Data = deps.Data
	Progression = deps.Progression
end

return Upgrades
