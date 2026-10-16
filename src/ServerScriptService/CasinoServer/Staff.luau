--!nonstrict
-- Staff.luau — the casino's staff (Config.Staff): hiring, promotions, their
-- effects and the roster the clients draw.
--   * profile.Staff[id] = level (1 .. #def.values). Staff.hire buys level 1 (remote
--     HireStaff, wired in init.server), Staff.promote the next level (remote
--     PromoteStaff, wired here). Every level has its own Casino Rank gate
--     (def.gates) and price (def.costs). Levels are never taken away, except by a
--     rebirth, which fires everyone (Staff.resetAll).
--   * effects: ONE provider "staff" (Upgrades.addProvider) adds every hired role's
--     effect (def.effect, an upgrade effect key) at its level, so NPCs, Gambling,
--     Traffic, ... see it like any upgrade. "houseSkim" roles (security, pit boss)
--     feed Staff.getHouseBonus instead (Gambling.payOwner: + floor(bet x skim + 0.5)).
--     Cached per profile: NPCs read every casino's effects each flow tick and
--     Gambling reads cashMult + the skim every round.
--   * visible staff: the owner's plot model carries the attribute StaffRoster
--     ("greeter:2,dealer:3", Config.Staff order) that StaffClient turns into people.
--     Kept up to date on join, hire / promote and reset; cleared on leave.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Config = require(Common:WaitForChild("Config"))

-- report to GameEvents (quests & co. listen); never in the way of the action
local function gameEvent(player, name: string, amount: number?)
	local m = script.Parent:FindFirstChild("GameEvents")
	if not m then return end
	local ok, GE = pcall(require, m)
	if ok and type(GE) == "table" and GE.emit then pcall(GE.emit, player, name, amount) end
end

local Staff = {}
local Economy, Data, Progression, Upgrades, Plots, Remotes, pushData

local ROSTER_ATTR = "StaffRoster"

------------------------------------------------------------------
-- levels + the cached effects of a profile
------------------------------------------------------------------
-- profile -> { gen, ref (profile.Staff it was built from), effects, skim, roster }
local cache = setmetatable({}, { __mode = "k" })
local generation = 0 -- bumped on every hire / promotion / reset

-- a role's level in a profile (0 = not hired)
function Staff.level(profile, staffId: string): number
	local st = profile and profile.Staff
	local def = Config.getStaffDef(staffId)
	if type(st) ~= "table" or not def then return 0 end
	local v = st[staffId]
	if v == true then return 1 end -- (a v5 save that skipped the migration)
	local lvl = math.floor(tonumber(v) or 0)
	return math.clamp(lvl, 0, def.maxLevel or #def.values)
end

local function compute(profile)
	local effects, skim, parts = {}, 0, {}
	for _, def in Config.Staff do -- Config order: a stable roster string
		local lvl = Staff.level(profile, def.id)
		if lvl > 0 then
			local v = Config.staffValue(def, lvl)
			if def.effect == "houseSkim" then
				skim += v
			else
				effects[def.effect] = (effects[def.effect] or 0) + v
			end
			table.insert(parts, def.id .. ":" .. lvl)
		end
	end
	return { effects = effects, skim = skim, roster = table.concat(parts, ",") }
end

local function stateOf(profile)
	if type(profile) ~= "table" then return nil end
	local c = cache[profile]
	if c and c.gen == generation and c.ref == profile.Staff then return c end
	c = compute(profile)
	c.gen = generation
	c.ref = profile.Staff
	cache[profile] = c
	return c
end

-- every effect key the staff adds ({ [key] = total }); read-only
function Staff.effectsOf(profile)
	local s = stateOf(profile)
	return s and s.effects or {}
end

-- The owner's extra skim (fraction of every bet) from security + the pit boss.
-- Takes the owner Player (Gambling.payOwner calls it every round).
function Staff.getHouseBonus(ownerPlayer: Player): number
	if not (Data and ownerPlayer) then return 0 end
	local s = stateOf(Data.get(ownerPlayer))
	return s and s.skim or 0
end

------------------------------------------------------------------
-- the roster on the plot (StaffClient draws it for everyone)
------------------------------------------------------------------
local function plotModelOf(player: Player)
	local rec = Plots and Plots.getRecordForOwner(player.UserId)
	return rec and rec.model or nil
end

function Staff.roster(profile): string
	local s = stateOf(profile)
	return s and s.roster or ""
end

function Staff.refreshRoster(player: Player)
	local model = plotModelOf(player)
	if not model then return end
	local roster = Data and Staff.roster(Data.get(player)) or ""
	model:SetAttribute(ROSTER_ATTR, roster ~= "" and roster or nil)
end

------------------------------------------------------------------
-- hire / promote
------------------------------------------------------------------
local function refusal(message: string, extra)
	local res = { ok = false, message = message }
	if extra then
		for k, v in extra do res[k] = v end
	end
	return res
end

-- buy level `want` (1 = hire) of a role
local function buyLevel(player: Player, staffId: any, hiring: boolean)
	local def = type(staffId) == "string" and Config.getStaffDef(staffId) or nil
	if not def then return refusal("Unknown staff.") end
	local p = Data.get(player)
	if not p then return refusal("Data not ready.") end
	if type(p.Staff) ~= "table" then p.Staff = {} end
	local lvl = Staff.level(p, def.id)
	if hiring and lvl > 0 then
		return refusal(def.name .. " is already on your team.", { level = lvl })
	end
	local maxLevel = def.maxLevel or #def.values
	if lvl >= maxLevel then
		return refusal(def.name .. " is at the top level!", { level = lvl })
	end
	local nextLevel = lvl + 1
	-- the Casino Rank gate of that level (levels you have are never taken away)
	local need = def.gates[nextLevel]
	if need and Progression and (Progression.rank(p)) < need then
		local msg = nextLevel == 1 and Progression.lockedMessage(need) or Progression.levelLockedMessage(nextLevel, need)
		return refusal(msg, { needRank = need, level = lvl })
	end
	local cost = def.costs[nextLevel] or 0
	if Economy.getCash(player) < cost then
		return refusal("Not enough " .. Config.CurrencyName .. ".", { cost = cost, level = lvl })
	end
	if not Economy.tryWithdraw(player, cost) then
		return refusal("Purchase failed.", { level = lvl })
	end
	p.Staff[def.id] = nextLevel
	generation += 1
	Staff.refreshRoster(player)
	local team = Config.staffTeam(def, nextLevel)
	local message
	if nextLevel == 1 then
		message = ("Hired a %s!"):format(def.name)
	else
		message = ("%s promoted to level %d!"):format(def.name, nextLevel)
	end
	gameEvent(player, "staffHired", 1)
	return { ok = true, message = message, staffId = def.id, level = nextLevel, maxLevel = maxLevel,
		team = team, cost = cost }
end

-- level 1 (the HireStaff remote)
function Staff.hire(player: Player, staffId: string)
	return buyLevel(player, staffId, true)
end

-- the next level (the PromoteStaff remote); not hired yet = hire
function Staff.promote(player: Player, staffId: string)
	local p = Data and Data.get(player)
	if p and type(staffId) == "string" and Staff.level(p, staffId) == 0 then
		return buyLevel(player, staffId, true)
	end
	return buyLevel(player, staffId, false)
end

-- a rebirth fires the whole staff (Rebirth.luau; no refund)
function Staff.resetAll(player: Player)
	local p = Data and Data.get(player)
	if not p then return false end
	p.Staff = {}
	generation += 1
	Staff.refreshRoster(player)
	return true
end

------------------------------------------------------------------
-- join / leave / snapshot (init.server calls these)
------------------------------------------------------------------
function Staff.join(player: Player)
	Staff.refreshRoster(player)
end

function Staff.leave(player: Player)
	local model = plotModelOf(player)
	if model then model:SetAttribute(ROSTER_ATTR, nil) end
end

-- snapshot key `staffInfo` (`staffLevels` = profile.Staff is sent too)
function Staff.snapshot(_player: Player, profile)
	local s = stateOf(profile)
	local levels, team, hired = {}, 0, 0
	for _, def in Config.Staff do
		local lvl = Staff.level(profile, def.id)
		if lvl > 0 then
			levels[def.id] = lvl
			team += Config.staffTeam(def, lvl)
			hired += 1
		end
	end
	return {
		levels = levels,                                  -- id -> level (clamped)
		hired = hired, total = #Config.Staff,              -- roles hired / roles that exist
		team = team,                                       -- people on the floor (before the room caps)
		skim = s and s.skim or 0,                          -- extra share of every bet
		effects = s and table.clone(s.effects) or {},      -- effect key -> total
	}
end

function Staff.start(deps)
	Economy = deps.Economy
	Data = deps.Data
	Progression = deps.Progression
	Upgrades = deps.Upgrades
	Plots = deps.Plots
	Remotes = deps.Remotes
	pushData = deps.pushData

	if Upgrades and Upgrades.addProvider then
		Upgrades.addProvider("staff", function(profile)
			local s = stateOf(profile)
			return s and s.effects or nil
		end)
	end
	if Remotes and Remotes.PromoteStaff then
		Remotes.PromoteStaff().OnServerInvoke = function(player, staffId)
			local res = Staff.promote(player, staffId)
			if res.ok and pushData then pushData(player) end
			return res
		end
	end
end

return Staff
