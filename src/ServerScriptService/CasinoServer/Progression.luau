--!nonstrict
-- Progression.luau — the Casino Rank (economy_spec 6.1, XP since the Rebirth &
-- Rewards update) and the owner's income rate.
--   * rank = the highest r with profile.Stats.XP >= Config.Progression.Ranks[r].xp.
--     XP comes from every game round a guest plays at one of your machines
--     (Progression.addXP, called by Gambling: Config.machineXP(def) x the guest
--     weight W, x (1 + xpMult)): better machines are worth more per game. Stands,
--     tips and offline income give no XP. A rebirth keeps the XP (and the rank).
--     Old saves got XP that keeps their rank in the v6 migration (Data.luau).
--   * clientele (Ranks[r].clientele) multiplies every guest's wallet (NPCs.runPatron).
--   * gates only block BUYING (owned machines / levels / floors are never taken away):
--       BuyToInventory   def.unlockRank      "Unlocks at Rank X (Name)"
--       Upgrades.buy     track.gates[L]      "Level N unlocks at Rank X"
--       Buildings.buyStory StoryRanks[S]     "Floor N unlocks at Rank X (Name)"
--       Staff.hire       def.unlockRank      "Unlocks at Rank X (Name)"
--     (items with `rebirth = N` also need N rebirths: Rebirth.allows)
--   * rank-up: addXP marks the owner (Progression.touch does too); a loop checks
--     marked owners at most once per Config.Progression.CheckInterval and on a
--     rank-up fires Remotes.RankUp { rank, name, from, clientele, xp, unlocks = {
--     machines, levels, floor?, staff, decor } } to that player (items still waiting
--     for a rebirth left out), then pushes a fresh snapshot.
--   * Stats.IncomeRate: EMA of the owner's unboosted net casino income ($/min), updated
--     once per online minute (rate += IncomeRateAlpha x (last minute - rate)). Offline
--     income, the daily reward and the ticket Cash Bundle scale with it.
--   * telemetry (economy_spec 12): Config.Progression.MinuteLog prints one line per
--     casino per minute and mirrors it to the plot's "FlowLog" attribute.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Config = require(Common:WaitForChild("Config"))
local Remotes = require(Common:WaitForChild("Remotes"))

local Progression = {}
local PC = Config.Progression
local Data, pushData, flowFor, recordFor, Upgrades

local lastRank: {[number]: number} = {}   -- userId -> the rank the owner was last told about
local dirty: {[number]: boolean} = {}     -- userId -> XP grew since the last check
local xpShown: {[number]: number} = {}    -- userId -> os.clock() of the last XP attribute write
local xpMultCache: {[number]: any} = {}   -- userId -> { t, mult }: (1 + xpMult), re-read every XP_MULT_TTL s
local minute: {[number]: any} = {}        -- userId -> { t0, net, gross }: casino income this minute
local started = false

local XP_ATTRIBUTE_EVERY = 0.5   -- seconds between writes of the Player attribute "XP" (HUD rank bar)
local XP_MULT_TTL = 2            -- addXP runs for every round: the effect sum is cached this long

------------------------------------------------------------------
-- rank queries
------------------------------------------------------------------
-- the XP a rank starts at
local function xpOf(def): number
	return def and tonumber(def.xp or def.threshold) or 0
end

function Progression.rankOf(xp: number?): number
	local v = tonumber(xp) or 0
	local r = 1
	for i, def in PC.Ranks do
		if v >= xpOf(def) then r = i end
	end
	return r
end

function Progression.rankDef(r: number)
	return PC.Ranks[math.clamp(math.floor(r or 1), 1, #PC.Ranks)]
end

-- (rank, rank def, threshold of the next rank or nil at the top) of a profile
function Progression.rank(profile)
	local stats = profile and profile.Stats
	local r = Progression.rankOf(type(stats) == "table" and stats.XP or 0)
	local nextDef = PC.Ranks[r + 1]
	return r, PC.Ranks[r], nextDef and xpOf(nextDef) or nil
end

-- (1 + xpMult) for an owner: rebirth upgrades, the XP potion, the 2x XP pass
local function xpMultFor(player: Player, profile): number
	local uid = player.UserId
	local now = os.clock()
	local c = xpMultCache[uid]
	if c and now - c.t < XP_MULT_TTL then return c.mult end
	local mult = 1
	if Upgrades then
		local ok, v = pcall(Upgrades.effect, profile, "xpMult")
		if ok and type(v) == "number" then mult += math.max(-0.9, v) end
	end
	xpMultCache[uid] = { t = now, mult = mult }
	return mult
end

-- the owner earned XP (a game round at one of their machines): x (1 + xpMult),
-- marks the rank check, and mirrors Stats.XP to the Player attribute "XP" (at most
-- 2x a second) so the HUD's rank bar moves live between snapshots
function Progression.addXP(player: Player?, amount: number?)
	if not (player and Data) then return end
	local a = tonumber(amount) or 0
	if a <= 0 or a ~= a then return end
	local profile = Data.get(player)
	local stats = profile and profile.Stats
	if type(stats) ~= "table" then return end
	local gained = a * xpMultFor(player, profile)
	stats.XP = (tonumber(stats.XP) or 0) + gained
	local GEm = script.Parent:FindFirstChild("GameEvents")
	if GEm then
		local okGE, GE = pcall(require, GEm)
		if okGE and type(GE) == "table" then pcall(GE.emit, player, "xpEarned", gained) end
	end
	local uid = player.UserId
	dirty[uid] = true
	local now = os.clock()
	if now - (xpShown[uid] or -math.huge) >= XP_ATTRIBUTE_EVERY then
		xpShown[uid] = now
		player:SetAttribute("XP", math.floor(stats.XP))
	end
end

-- "12.4K XP" (server messages / the minute log)
function Progression.xpText(xp: number?): string
	local v = math.max(0, math.floor(tonumber(xp) or 0))
	if v < 1e4 then
		local s = tostring(v)
		local k
		repeat s, k = s:gsub("^(%d+)(%d%d%d)", "%1,%2") until k == 0
		return s .. " XP"
	end
	local unit, div = "K", 1e3
	if v >= 1e9 then unit, div = "B", 1e9 elseif v >= 1e6 then unit, div = "M", 1e6 end
	local num = ("%.1f"):format(math.floor(v / div * 10) / 10)
	num = (num:gsub("%.0$", ""))
	return num .. unit .. " XP"
end

function Progression.rankOfPlayer(player: Player?): number
	if not (player and Data) then return 1 end
	return (Progression.rank(Data.get(player)))
end

-- a casino owner's rank by userId (1 while they aren't on the server)
function Progression.rankForUser(userId: number?): number
	local player = userId and Players:GetPlayerByUserId(userId) or nil
	return Progression.rankOfPlayer(player)
end

-- the owner's clientele: how much richer their guests are (wallet multiplier)
function Progression.clientele(userId: number?): number
	return Progression.rankDef(Progression.rankForUser(userId)).clientele or 1
end

-- true when the player may buy something that needs rank `need` (nil = no gate)
function Progression.allows(player: Player?, need: number?): boolean
	return (need or 1) <= Progression.rankOfPlayer(player)
end

------------------------------------------------------------------
-- refusal messages (economy_spec 6.1)
------------------------------------------------------------------
function Progression.lockedMessage(need: number): string
	return ("Unlocks at Rank %d (%s)"):format(need, Progression.rankDef(need).name)
end

function Progression.levelLockedMessage(level: number, need: number): string
	return ("Level %d unlocks at Rank %d"):format(level, need)
end

function Progression.floorLockedMessage(story: number, need: number): string
	return ("Floor %d unlocks at Rank %d (%s)"):format(story, need, Progression.rankDef(need).name)
end

------------------------------------------------------------------
-- what a rank-up unlocks: ranks (from, to]. Catalog / decor items that also
-- need more rebirths than `rebirths` (nil = 0) are left out: they're news when
-- the rebirth comes (RebirthUI), not now.
------------------------------------------------------------------
local function rebirthOk(def, rebirths: number): boolean
	return (tonumber(def.rebirth) or 0) <= rebirths
end

function Progression.unlocksBetween(from: number, to: number, rebirths: number?)
	local rb = tonumber(rebirths) or 0
	local machines, levels, staff, decor, floor = {}, {}, {}, {}, nil
	local function inRange(u): boolean
		local n = tonumber(u) or 1
		return n > from and n <= to
	end
	for _, def in Config.Catalog do
		if inRange(def.unlockRank) and rebirthOk(def, rb) then table.insert(machines, def.id) end
	end
	for _, track in Config.UpgradeTracks do
		for level, need in (track.gates or {}) do
			if inRange(need) then table.insert(levels, { track = track.id, level = level }) end
		end
	end
	for story, need in PC.StoryRanks do
		if story >= 2 and inRange(need) then floor = math.max(floor or 0, story) end
	end
	for _, def in (Config.Staff or {}) do
		if type(def) == "table" and def.id and inRange(def.unlockRank) then table.insert(staff, def.id) end
	end
	if type(Config.Decor) == "table" then
		for _, def in Config.Decor do
			if type(def) == "table" and def.id and def.unlockRank ~= nil and inRange(def.unlockRank)
				and rebirthOk(def, rb) then
				table.insert(decor, def.id)
			end
		end
	end
	return { machines = machines, levels = levels, floor = floor, staff = staff, decor = decor }
end

------------------------------------------------------------------
-- snapshot fields (init.server buildSnapshot)
------------------------------------------------------------------
function Progression.snapshotFields(profile)
	local r, def, nextThreshold = Progression.rank(profile)
	return {
		rank = r,
		rankName = def.name,
		rankProgress = math.floor((profile and profile.Stats and tonumber(profile.Stats.XP)) or 0),
		rankNext = nextThreshold,
		rankFloor = xpOf(def),
		clientele = def.clientele,
		storyRanks = table.clone(PC.StoryRanks),
	}
end

-- the owner's income rate ($/min, EMA of unboosted net casino income)
function Progression.incomeRate(profile): number
	local stats = profile and profile.Stats
	return math.max(0, tonumber(type(stats) == "table" and stats.IncomeRate or 0) or 0)
end

------------------------------------------------------------------
-- rank-up detection
------------------------------------------------------------------
local function check(player: Player)
	local profile = Data and Data.get(player)
	if not profile then return end
	local uid = player.UserId
	local r = Progression.rankOf(profile.Stats.XP)
	local was = lastRank[uid]
	if was == nil or r <= was then
		lastRank[uid] = math.max(r, was or 0)
		return
	end
	lastRank[uid] = r
	local def = PC.Ranks[r]
	local rebirths = type(profile.Rebirth) == "table" and tonumber(profile.Rebirth.count) or 0
	local payload = {
		rank = r, name = def.name, from = was, clientele = def.clientele,
		xp = math.floor(tonumber(profile.Stats.XP) or 0),
		unlocks = Progression.unlocksBetween(was, r, rebirths),
	}
	local ok, err = pcall(function() Remotes.RankUp():FireClient(player, payload) end)
	if not ok then warn("[Progression] RankUp: " .. tostring(err)) end
	print(("[CasinoTycoon] %s reached Rank %d (%s)."):format(player.Name, r, def.name))
	if pushData then
		local okPush, errPush = pcall(pushData, player)
		if not okPush then warn("[Progression] pushData: " .. tostring(errPush)) end
	end
end

-- XP grew: check the owner's rank on the next pass (at most once a CheckInterval)
function Progression.touch(player: Player?)
	if player then dirty[player.UserId] = true end
end

-- a player's profile is loaded: remember their rank (no fanfare for the rank they join with)
function Progression.join(player: Player)
	local profile = Data and Data.get(player)
	lastRank[player.UserId] = Progression.rankOf(profile and profile.Stats and profile.Stats.XP)
	if profile and profile.Stats then player:SetAttribute("XP", math.floor(tonumber(profile.Stats.XP) or 0)) end
	-- warm: an unmeasured save (new, or from before ranks) averages its first
	-- minutes instead of climbing from 0 (see minuteTick)
	local measured = Progression.incomeRate(profile) > 0
	minute[player.UserId] = { t0 = os.clock(), net = 0, gross = 0, warm = (not measured) and 0 or nil }
end

function Progression.leave(player: Player)
	local uid = player.UserId
	lastRank[uid] = nil
	dirty[uid] = nil
	minute[uid] = nil
	xpShown[uid] = nil
	xpMultCache[uid] = nil
end

-- restart the income-rate warm-up (a rebirth zeroes Stats.IncomeRate)
function Progression.resetIncome(player: Player)
	minute[player.UserId] = { t0 = os.clock(), net = 0, gross = 0, warm = 0 }
end

------------------------------------------------------------------
-- income rate + the per-minute telemetry line
------------------------------------------------------------------
-- Casino income for the owner's income rate and the minute log. `base` = the net
-- owner income before the earnings multiplier (gamepasses / ticket boost), already x
-- the guest weight; it may be negative (a guest's big win). `gross` = the positive
-- Cash actually paid out to the owner.
function Progression.noteIncome(player: Player?, base: number?, gross: number?)
	if not player then return end
	local m = minute[player.UserId]
	if not m then
		m = { t0 = os.clock(), net = 0, gross = 0 }
		minute[player.UserId] = m
	end
	m.net += base or 0
	if gross and gross > 0 then m.gross += gross end
end

local function money(n: number): string
	local a = math.abs(n)
	if a < 1e3 then return ("$%d"):format(math.floor(n + 0.5)) end
	local s, unit = n / 1e3, "K"
	if a >= 1e9 then s, unit = n / 1e9, "B" elseif a >= 1e6 then s, unit = n / 1e6, "M" end
	return ("$%.2f%s"):format(s, unit)
end

local function logMinute(player: Player, profile, net: number, gross: number)
	local f = flowFor and flowFor(player.UserId)
	local r, def = Progression.rank(profile)
	local flowText = "no guests (no machines)"
	if f then
		flowText = ("rate %.1f/min (demand %.1f, lobby %.1f: %s) W %.2f hold %.0fs (nominal %.0fs) visible %.1f, inside %d")
			:format(f.rate, f.demand, f.lobby, f.bottleneck, f.weight, f.hold, f.nominalHold, f.visible, f.inside)
	end
	local line = ("%s | net %s/min, +%s/min | R%d %s, %s, TotalEarned %s, IncomeRate %s/min"):format(
		flowText, money(net), money(gross), r, def.name, Progression.xpText(profile.Stats.XP),
		money(profile.Stats.TotalEarned or 0), money(Progression.incomeRate(profile)))
	print("[Flow] " .. player.Name .. ": " .. line)
	local rec = recordFor and recordFor(player.UserId)
	if rec and rec.model then rec.model:SetAttribute("FlowLog", line) end
end

local function minuteTick()
	local now = os.clock()
	local alpha = Config.IncomeRateAlpha or 0.1
	local warmMinutes = math.max(1, math.floor(1 / alpha + 0.5))
	for _, player in Players:GetPlayers() do
		local m = minute[player.UserId]
		local profile = Data and Data.get(player)
		if m and profile and type(profile.Stats) == "table" and now - m.t0 >= 60 then
			local span = now - m.t0
			local net = m.net * 60 / span
			local gross = m.gross * 60 / span
			local rate = tonumber(profile.Stats.IncomeRate) or 0
			if m.warm and m.warm < warmMinutes then
				-- a plain running mean until it has as many minutes as the EMA's span,
				-- so offline / daily / the cash bundle see a real rate after one minute
				m.warm += 1
				profile.Stats.IncomeRate = math.max(0, rate + (net - rate) / m.warm)
			else
				profile.Stats.IncomeRate = math.max(0, rate + alpha * (net - rate))
			end
			if PC.MinuteLog then
				local ok, err = pcall(logMinute, player, profile, net, gross)
				if not ok then warn("[Progression] minute log: " .. tostring(err)) end
			end
			m.t0, m.net, m.gross = now, 0, 0
		end
	end
end

-- deps: Data, pushData (fresh snapshot after a rank-up), flowFor (NPCs.flowFor, for the
-- minute log), recordFor (Plots.getRecordForOwner, for the FlowLog attribute),
-- Upgrades (the xpMult effect)
function Progression.start(deps)
	Data = deps.Data
	pushData = deps.pushData
	flowFor = deps.flowFor
	recordFor = deps.recordFor
	Upgrades = deps.Upgrades
	if started then return end
	started = true
	task.spawn(function()
		local sinceMinute = 0
		while true do
			local step = PC.CheckInterval or 1
			task.wait(step)
			for uid in dirty do
				dirty[uid] = nil
				local player = Players:GetPlayerByUserId(uid)
				if player then
					local ok, err = pcall(check, player)
					if not ok then warn("[Progression] check: " .. tostring(err)) end
				end
			end
			sinceMinute += step
			if sinceMinute >= 5 then
				sinceMinute = 0
				local ok, err = pcall(minuteTick)
				if not ok then warn("[Progression] income rate: " .. tostring(err)) end
			end
		end
	end)
end

return Progression
