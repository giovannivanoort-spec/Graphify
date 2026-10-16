--!nonstrict
-- Quests.luau — daily + weekly quests (Config.Quests; client QuestsUI.luau).
--
-- profile.Quests = {
--   day, week      the UTC day (os.time() // 86400) and Monday-based week ((day + 3) // 7)
--                  the sets below belong to
--   daily          this day's quests (a dense array, one per Config.Quests.DailyGroups)
--   weekly         this week's quest (nil until generated)
--   rerolls        rerolls made today (the first FreeRerolls are free)
--   seq            the quest id counter ("q17")
--   total          quests ever claimed
--   pace           { games, xp, n }: games (W-weighted rounds) and XP per online minute,
--                  an EMA over the n minutes measured so far (targets scale with it)
-- }
-- quest = { id, key (pool entry id), kind, target, progress, done, claimed, jit? }
--
-- Progress is server-side only: GameEvents (KIND_OF below) add to every open quest of
-- that kind. The Player attribute QuestProgress ("q17:3400|q18:2|...", written at most
-- once a second) feeds the client's live bars; a finished quest fires
-- Remotes.QuestDone { id, slot, key, title, icon, tone, reward } once and pushes a
-- snapshot. ClaimQuest(id) pays its reward (Rewards.grant) and emits the GameEvent
-- questClaimed; RerollQuest(id) swaps an open quest for another one (free / Tickets).
-- A new UTC day (week) pays out the finished-but-unclaimed old quests, then deals a
-- new set. A rebirth rescales the open pace quests (the bar keeps its fill) and
-- restarts the pace measurement.
-- Studio: ServerStorage attribute CasinoTestQuests (a number, e.g. 0.02) scales new
-- targets so a whole set can be finished in a test session; CasinoTestQuestsRedeal =
-- true deals everyone a fresh set (and clears itself).

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Config = require(Common:WaitForChild("Config"))

local Quests = {}

local DAY = 86400
local ATTR = "QuestProgress"
local PACE_KINDS = { games = true, xp = true, cash = true }
-- GameEvents name -> the quest kind it moves
local KIND_OF = {
	gameHosted = "games", cashEarned = "cash", xpEarned = "xp",
	machineUpgraded = "upgradeMachine", upgradeBought = "upgradeTrack", staffHired = "staff",
	decorPlaced = "decor", machineBought = "buyMachine",
	cheaterKicked = "cheaters", cheaterCaught = "cheaters",
	wheelSpun = "wheel", potionUsed = "potion", playtimeClaimed = "playtime", eventJoined = "events",
}

local deps = {}
local Data, Rewards, Progression, Remotes, GameEvents, pushData
local started = false

local acc: {[Player]: any} = {}            -- this minute's pace sample { games, xp, t0 }
local dirty: {[Player]: boolean} = {}      -- progress moved since the attribute was written
local pushWanted: {[Player]: boolean} = {} -- push a snapshot on the next tick
local notices: {[Player]: any} = {}        -- { id, text }: rewards paid out at a rollover
local noticeSeq = 0

------------------------------------------------------------------
-- config + small helpers
------------------------------------------------------------------
local function cfg()
	return Config.Quests
end

local function num(v, default: number): number
	local n = tonumber(v)
	if n == nil or n ~= n or n == math.huge or n == -math.huge then return default end
	return n
end

-- pool entry id -> { def, slot = "daily" | "weekly" }
local defIndex = nil
local function defOf(key)
	if not defIndex then
		local idx = {}
		local qc = cfg()
		if type(qc) == "table" then
			for _, d in qc.Daily or {} do idx[d.id] = { def = d, slot = "daily" } end
			for _, d in qc.Weekly or {} do idx[d.id] = { def = d, slot = "weekly" } end
		end
		defIndex = idx
	end
	local e = type(key) == "string" and defIndex[key] or nil
	if not e then return nil, nil end
	return e.def, e.slot
end

local function today(): number
	return os.time() // DAY
end

-- weeks start on Monday 00:00 UTC (day 0, 1970-01-01, was a Thursday)
local function weekOf(day: number): number
	return (day + 3) // 7
end

local function weekEndsAt(week: number): number
	return (week * 7 + 4) * DAY
end

local function gameEvent(player: Player, name: string, amount: number?)
	if GameEvents and GameEvents.emit then pcall(GameEvents.emit, player, name, amount) end
end

local function commas(n: number): string
	local s = ("%.0f"):format(math.floor(n))
	local k
	repeat s, k = s:gsub("^(-?%d+)(%d%d%d)", "%1,%2") until k == 0
	return s
end

-- "1,234" below 10K, then "12.5K" / "1.25M" (rounded down)
local UNITS = { "K", "M", "B", "T", "Qa", "Qi" }
local function short(n: number): string
	local v = math.max(0, math.floor(num(n, 0)))
	if v < 10_000 then return commas(v) end
	local i = 0
	while v >= 1000 and i < #UNITS do
		v /= 1000
		i += 1
	end
	local digits = v >= 100 and 0 or (v >= 10 and 1 or 2)
	local m = 10 ^ digits
	local s = ("%." .. digits .. "f"):format(math.floor(v * m) / m)
	if digits > 0 then
		s = (s:gsub("0+$", ""))
		s = (s:gsub("%.$", ""))
	end
	return s .. UNITS[i]
end

local function amountText(kind: string?, n: number): string
	if kind == "cash" then return "$" .. short(n) end
	return short(n)
end
Quests.amountText = amountText

local function titleOf(def, target: number): string
	if not def then return "Quest" end
	if target == 1 and type(def.one) == "string" then return def.one end
	local t = tostring(def.title or def.id)
	if t:find("%%s") then return (t:format(amountText(def.kind, target))) end
	return t
end
Quests.titleOf = titleOf

-- round to 2 significant digits (5s below 100)
local function nice(v: number): number
	v = num(v, 1)
	if v <= 1 then return 1 end
	if v < 20 then return math.floor(v + 0.5) end
	if v < 100 then return math.floor(v / 5 + 0.5) * 5 end
	local mag = 10 ^ (math.floor(math.log10(v)) - 1)
	return math.floor(v / mag + 0.5) * mag
end
Quests.nice = nice

local function rewardOf(q)
	local def, slot = defOf(q and q.key)
	local qc = cfg()
	if def and type(def.reward) == "table" then return def.reward end
	if slot == "weekly" and type(qc) == "table" and type(qc.WeeklyReward) == "table" then return qc.WeeklyReward end
	return {}
end

------------------------------------------------------------------
-- profile state
------------------------------------------------------------------
-- a quest table from the save, repaired; false when it can't be used any more
-- (its pool entry is gone)
local function validQuest(q, slot: string): boolean
	if type(q) ~= "table" or type(q.id) ~= "string" or type(q.key) ~= "string" then return false end
	local def, defSlot = defOf(q.key)
	if not def or defSlot ~= slot then return false end
	q.kind = def.kind
	q.target = math.max(1, math.floor(num(q.target, 1)))
	q.progress = math.clamp(num(q.progress, 0), 0, q.target)
	q.done = q.done == true or q.progress >= q.target
	q.claimed = q.claimed == true and q.done
	if q.jit ~= nil then q.jit = math.clamp(num(q.jit, 1), 0.5, 1.5) end
	return true
end

local function ensure(p)
	local st = p.Quests
	if type(st) ~= "table" then
		st = {}
		p.Quests = st
	end
	st.day = math.floor(num(st.day, 0))
	st.week = math.floor(num(st.week, 0))
	st.seq = math.max(0, math.floor(num(st.seq, 0)))
	st.rerolls = math.max(0, math.floor(num(st.rerolls, 0)))
	st.total = math.max(0, math.floor(num(st.total, 0)))
	local list = {}
	if type(st.daily) == "table" then
		for _, q in st.daily do
			if validQuest(q, "daily") then table.insert(list, q) end
		end
	end
	st.daily = list
	if st.weekly ~= nil and not validQuest(st.weekly, "weekly") then st.weekly = nil end
	local pace = type(st.pace) == "table" and st.pace or {}
	st.pace = {
		games = math.max(0, num(pace.games, 0)),
		xp = math.max(0, num(pace.xp, 0)),
		n = math.max(0, math.floor(num(pace.n, 0))),
	}
	return st
end

local function rankOf(p): number
	if Progression and Progression.rank then
		local ok, r = pcall(Progression.rank, p)
		if ok and type(r) == "number" then return math.max(1, math.floor(r)) end
	end
	return 1
end

local function rebirthsOf(p): number
	local rb = type(p.Rebirth) == "table" and p.Rebirth.count or 0
	return math.max(0, math.floor(num(rb, 0)))
end

-- what the generator needs to know. fresh = right after a rebirth: ignore the
-- measured pace and the income rate (both belong to the casino that's gone)
local function context(player: Player, p, st, fresh: boolean?)
	local qc = cfg()
	local rank = rankOf(p)
	local rebirths = rebirthsOf(p)
	local unmeasured = st.pace.n < num(qc.PaceMinMinutes, 5)
	local paceRank = rank
	if fresh or (unmeasured and rebirths > 0) then
		paceRank = math.min(rank, math.max(1, math.floor(num(qc.RebirthPaceRank, 3))))
	end
	local income = 0
	if Progression and Progression.incomeRate then
		local ok, v = pcall(Progression.incomeRate, p)
		if ok then income = math.max(0, num(v, 0)) end
	end
	-- the share of this week still ahead (a weekly dealt on Saturday asks less)
	local weekLeft = math.clamp((weekEndsAt(weekOf(today())) - os.time()) / (7 * DAY), 0, 1)
	return { player = player, profile = p, rank = rank, rebirths = rebirths, paceRank = paceRank,
		pace = st.pace, income = income, fresh = fresh == true, weekLeft = weekLeft }
end

------------------------------------------------------------------
-- what's left to do (count kinds): a quest asks at most this much
------------------------------------------------------------------
local function machineLevelsLeft(p): number
	local maxL = math.floor(num(Config.MachineUpgradeMaxLevel, 5))
	local left = 0
	for _, e in (type(p.Placed) == "table" and p.Placed or {}) do
		local def = type(e) == "table" and Config.getMachineDef(e.machineId) or nil
		if def and def.kind ~= "concession" then
			local u = type(e.upgrades) == "table" and e.upgrades or {}
			for kind in Config.MachineUpgrades do
				left += math.max(0, maxL - math.floor(num(u[kind], 0)))
			end
		end
	end
	return left
end

local function trackLevelsLeft(p, rank: number): number
	local levels = type(p.UpgradeLevels) == "table" and p.UpgradeLevels or {}
	local left = 0
	for _, t in Config.UpgradeTracks do
		for level = math.floor(num(levels[t.id], 0)) + 1, #t.values do
			if num(t.gates and t.gates[level], 1) <= rank then left += 1 end
		end
	end
	return left
end

local function staffLevelsLeft(p, rank: number): number
	local staff = type(p.Staff) == "table" and p.Staff or {}
	local left = 0
	for _, def in (Config.Staff or {}) do
		for level = math.floor(num(staff[def.id], 0)) + 1, #def.values do
			if num(def.gates and def.gates[level], 1) <= rank then left += 1 end
		end
	end
	return left
end

local function potionsOwned(p): number
	local n = 0
	for _, c in (type(p.Potions) == "table" and p.Potions or {}) do
		n += math.max(0, math.floor(num(c, 0)))
	end
	return n
end

local function playtimeLeft(p): number
	local list = (Config.Playtime and Config.Playtime.Rewards) or {}
	local pt = p.Playtime
	if type(pt) ~= "table" or num(pt.day, 0) < today() then return #list end
	local claimed = type(pt.claimed) == "table" and pt.claimed or {}
	local left = 0
	for i in list do
		if claimed[i] ~= true then left += 1 end
	end
	return left
end

-- nil = no limit
local function roomFor(kind: string, p, rank: number): number?
	if kind == "upgradeMachine" then return machineLevelsLeft(p) end
	if kind == "upgradeTrack" then return trackLevelsLeft(p, rank) end
	if kind == "staff" then return staffLevelsLeft(p, rank) end
	if kind == "potion" then return potionsOwned(p) end
	if kind == "playtime" then return playtimeLeft(p) end
	if kind == "buyMachine" then
		return math.max(0, math.floor(num(Config.MaxInventory, 60)) - #(type(p.Inventory) == "table" and p.Inventory or {}))
	end
	return nil
end

-- can the player do this quest now?
local function available(def, ctx): boolean
	if def.need and deps[def.need] == nil then return false end
	local minRank = math.floor(num(def.minRank, 1))
	if def.kind == "cheaters" then
		local cc = (Config :: any).Cheaters
		minRank = math.max(minRank, math.floor(num(type(cc) == "table" and cc.MinRank or nil, 2)))
	end
	if ctx.rank < minRank then return false end
	local room = roomFor(def.kind, ctx.profile, ctx.rank)
	if room and room < 1 then return false end
	return true
end

------------------------------------------------------------------
-- targets
------------------------------------------------------------------
local function testScale(): number
	if not RunService:IsStudio() then return 1 end
	local v = tonumber(ServerStorage:GetAttribute("CasinoTestQuests"))
	return (v and v > 0) and v or 1
end

local function countOf(def, rank: number): number
	local list = def.count
	if type(list) ~= "table" or #list == 0 then return 1 end
	return math.max(1, math.floor(num(list[math.clamp(rank, 1, #list)], 1)))
end

-- the rank table's pace (x BaselineShare)
local function baseline(kind: string, rank: number): number
	local qc = cfg()
	local tbl = (kind == "games" and qc.PaceGames) or (kind == "xp" and qc.PaceXP) or qc.PaceCash
	if type(tbl) ~= "table" or #tbl == 0 then return 0 end
	return num(tbl[math.clamp(rank, 1, #tbl)], 0) * num(qc.BaselineShare, 0.75)
end

-- the owner's pace (per online minute) of a pace kind. ahead > 0 (weekly quests: a
-- casino grows during a week): at least the rank table `ahead` ranks further on
local function paceOf(ctx, kind: string, ahead: number?): number
	local own = nil
	if not ctx.fresh then
		if kind == "cash" then
			if ctx.income > 0 then own = ctx.income end
		elseif ctx.pace.n >= num(cfg().PaceMinMinutes, 5) then
			own = kind == "games" and ctx.pace.games or ctx.pace.xp
		end
	end
	local a = math.max(0, math.floor(num(ahead, 0)))
	if own and a == 0 then return own end
	local base = baseline(kind, ctx.paceRank + a)
	return own and math.max(own, base) or base
end

local function targetFor(def, ctx, jit: number?): number
	local qc = cfg()
	local scale = testScale()
	local _, slot = defOf(def.id)
	local weekly = slot == "weekly"
	-- a weekly dealt late in the week: the days left (at least WeeklyMinShare)
	local share = weekly and math.max(math.clamp(num(qc.WeeklyMinShare, 0.4), 0, 1), num(ctx.weekLeft, 1)) or 1
	if PACE_KINDS[def.kind] then
		local ahead = weekly and num(qc.WeeklyRankAhead, 1) or 0
		local v = num(def.minutes, 20) * paceOf(ctx, def.kind, ahead) * (jit or 1) * share
		return nice(math.max(num(def.min, 1), v) * scale)
	end
	local n = math.ceil(countOf(def, ctx.rank) * share - 1e-9)
	local room = roomFor(def.kind, ctx.profile, ctx.rank)
	if room then n = math.min(n, room) end
	return math.max(1, math.floor(n * scale + 0.5))
end

------------------------------------------------------------------
-- dealing quests
------------------------------------------------------------------
local function rngFor(player: Player, st)
	local seed = (math.floor(num(player.UserId, 0)) % 1_000_003) * 7919 + st.day * 31 + st.seq
	return Random.new(seed)
end

local function weightedPick(rng, list)
	local total = 0
	for _, d in list do total += math.max(0, num(d.weight, 1)) end
	if total <= 0 then return list[1] end
	local r = rng:NextNumber() * total
	for _, d in list do
		r -= math.max(0, num(d.weight, 1))
		if r <= 0 then return d end
	end
	return list[#list]
end

local function newQuest(st, def, ctx, rng)
	st.seq += 1
	local jit = nil
	if PACE_KINDS[def.kind] then
		local j = num(cfg().Jitter, 0.15)
		jit = math.floor((1 + (rng:NextNumber() * 2 - 1) * j) * 1000 + 0.5) / 1000
	end
	return { id = "q" .. st.seq, key = def.id, kind = def.kind, target = targetFor(def, ctx, jit),
		progress = 0, done = false, claimed = false, jit = jit }
end

-- a daily pool entry of `group` (nil = any) whose kind isn't `taken` yet
local function pickDaily(ctx, rng, taken, group: string?)
	local pool = {}
	for _, d in cfg().Daily or {} do
		if (group == nil or d.group == group) and not taken[d.kind] and available(d, ctx) then
			table.insert(pool, d)
		end
	end
	if #pool == 0 then return nil end
	return weightedPick(rng, pool)
end

local function pickWeekly(ctx, rng, notKind: string?)
	local pool = {}
	for _, d in cfg().Weekly or {} do
		if d.kind ~= notKind and available(d, ctx) then table.insert(pool, d) end
	end
	if #pool == 0 then return nil end
	return weightedPick(rng, pool)
end

local function dealDaily(player: Player, st, ctx)
	local rng = rngFor(player, st)
	local taken, list, missing = {}, {}, 0
	for _, group in cfg().DailyGroups or { "core", "build", "fun" } do
		local def = pickDaily(ctx, rng, taken, group)
		if def then
			taken[def.kind] = true
			table.insert(list, newQuest(st, def, ctx, rng))
		else
			missing += 1
		end
	end
	for _ = 1, missing do -- an empty group lends its slot to the others
		local def = pickDaily(ctx, rng, taken, nil)
		if not def then break end
		taken[def.kind] = true
		table.insert(list, newQuest(st, def, ctx, rng))
	end
	st.daily = list
end

local function dealWeekly(player: Player, st, ctx)
	local rng = rngFor(player, st)
	local def = pickWeekly(ctx, rng, nil)
	st.weekly = def and newQuest(st, def, ctx, rng) or nil
end

------------------------------------------------------------------
-- progress
------------------------------------------------------------------
local function complete(player: Player, q, slot: string)
	q.done = true
	q.progress = q.target
	pushWanted[player] = true
	local def = defOf(q.key)
	local payload = { id = q.id, slot = slot, key = q.key, title = titleOf(def, q.target),
		icon = def and def.icon or nil, tone = def and def.tone or nil, reward = rewardOf(q) }
	local ok, err = pcall(function() Remotes.QuestDone():FireClient(player, payload) end)
	if not ok then warn("[Quests] QuestDone: " .. tostring(err)) end
end

local function bump(player: Player, q, slot: string, amount: number)
	if q.done or q.claimed then return end
	q.progress = math.min(q.target, num(q.progress, 0) + amount)
	dirty[player] = true
	if q.progress >= q.target then complete(player, q, slot) end
end

-- a player did `amount` of `kind` (GameEvents); hot path: runs for every game round
function Quests.progress(player: Player, kind: string, amount: number?)
	local a = tonumber(amount)
	if not a or a <= 0 or a ~= a or a == math.huge then return end
	local p = Data and Data.get(player)
	local st = p and p.Quests
	if type(st) ~= "table" or num(st.day, 0) < os.time() // DAY then return end -- (the set is being replaced)
	if type(st.daily) == "table" then
		for _, q in st.daily do
			if type(q) == "table" and q.kind == kind then bump(player, q, "daily", a) end
		end
	end
	local w = st.weekly
	if type(w) == "table" and w.kind == kind then bump(player, w, "weekly", a) end
end

-- a daily quest was claimed: the weekly "complete N dailies" moves
local function bumpDailies(player: Player, st)
	local w = st.weekly
	if type(w) == "table" and w.kind == "dailies" then bump(player, w, "weekly", 1) end
end

------------------------------------------------------------------
-- claim / pay out
------------------------------------------------------------------
local function pay(player: Player, st, q, slot: string)
	q.claimed = true -- first: a second claim racing this one is refused
	local got = { parts = {} }
	if Rewards and Rewards.grant then
		local ok, res = pcall(Rewards.grant, player, rewardOf(q))
		if ok and type(res) == "table" then
			got = res
		else
			warn("[Quests] reward: " .. tostring(res))
		end
	end
	st.total += 1
	if slot == "daily" then bumpDailies(player, st) end
	dirty[player] = true
	gameEvent(player, "questClaimed", 1)
	return got
end

-- a new day / week: pay the finished-but-unclaimed old quests, deal new ones.
-- true when anything changed. (A server whose clock runs behind another's never
-- rolls a set back.)
local function refresh(player: Player, p, st): boolean
	local d = today()
	local w = weekOf(d)
	local changed = false
	local paid = {}
	if d > st.day then
		for _, q in st.daily do
			if q.done and not q.claimed then
				for _, s in (pay(player, st, q, "daily").parts or {}) do table.insert(paid, s) end
			end
		end
		st.day = d
		st.rerolls = 0
		st.daily = {}
		changed = true
	end
	if w > st.week then
		local q = st.weekly
		if type(q) == "table" and q.done and not q.claimed then
			for _, s in (pay(player, st, q, "weekly").parts or {}) do table.insert(paid, s) end
		end
		st.week = w
		st.weekly = nil
		changed = true
	end
	local ctx = nil
	if #st.daily == 0 and st.day == d then
		ctx = context(player, p, st)
		dealDaily(player, st, ctx)
		changed = true
	end
	if st.weekly == nil and st.week == w then
		ctx = ctx or context(player, p, st)
		dealWeekly(player, st, ctx)
		changed = changed or st.weekly ~= nil
	end
	if #paid > 0 then
		noticeSeq += 1
		notices[player] = { id = noticeSeq, text = "Finished quests paid out: " .. table.concat(paid, " + ") }
	end
	if changed then
		dirty[player] = true
		pushWanted[player] = true -- (a snapshot being built right now has the old Cash / Tickets)
	end
	return changed
end

local function findQuest(st, id)
	if type(id) ~= "string" then return nil, nil end
	for i, q in st.daily do
		if q.id == id then return q, "daily", i end
	end
	if type(st.weekly) == "table" and st.weekly.id == id then return st.weekly, "weekly", nil end
	return nil, nil
end

local function stateOf(player: Player)
	local p = Data and Data.get(player)
	if not (p and cfg()) then return nil, nil end
	local st = ensure(p)
	refresh(player, p, st)
	return p, st
end

-- ClaimQuest(id) -> { ok, message, id, slot, title, parts, cash?, tickets?, potion?, rcoins?, boostSeconds? }
function Quests.claim(player: Player, id: any)
	local p, st = stateOf(player)
	if not st then return { ok = false, message = "Data not ready." } end
	if not Rewards then return { ok = false, message = "Rewards are offline right now." } end
	local q, slot = findQuest(st, id)
	if not q then return { ok = false, message = "That quest is gone - check your new quests!" } end
	if q.claimed then return { ok = false, message = "Already claimed." } end
	if not q.done then
		return { ok = false, message = ("Not done yet: %s / %s"):format(amountText(q.kind, q.progress),
			amountText(q.kind, q.target)) }
	end
	local got = pay(player, st, q, slot)
	local parts = got.parts or {}
	return { ok = true, id = q.id, slot = slot, title = titleOf(defOf(q.key), q.target), parts = parts,
		cash = got.cash, tickets = got.tickets, potion = got.potion, potionCount = got.potionCount,
		rcoins = got.rcoins, boostSeconds = got.boostSeconds,
		message = #parts > 0 and (table.concat(parts, " + ") .. "!") or "Claimed!" }
end

-- Tickets the next reroll of a `slot` quest costs (0 = free)
local function rerollCost(st, slot: string): number
	local qc = cfg()
	if slot == "weekly" then return math.max(0, math.floor(num(qc.WeeklyRerollTickets, 60))) end
	local free = math.max(0, math.floor(num(qc.FreeRerolls, 1)))
	if st.rerolls < free then return 0 end
	return math.max(0, math.floor(num(qc.RerollTickets, 20) + num(qc.RerollStep, 10) * (st.rerolls - free)))
end

-- RerollQuest(id) -> { ok, message, id (the new quest), old, slot, cost, title }
function Quests.reroll(player: Player, id: any)
	local p, st = stateOf(player)
	if not st then return { ok = false, message = "Data not ready." } end
	local q, slot, index = findQuest(st, id)
	if not q then return { ok = false, message = "That quest is gone - check your new quests!" } end
	if q.done then
		return { ok = false, message = q.claimed and "Already claimed." or "It's done - claim it instead!" }
	end
	local ctx = context(player, p, st)
	local rng = rngFor(player, st)
	local def
	if slot == "daily" then
		local taken = {}
		for _, o in st.daily do taken[o.kind] = true end
		local old = defOf(q.key)
		def = pickDaily(ctx, rng, taken, old and old.group or nil) or pickDaily(ctx, rng, taken, nil)
	else
		def = pickWeekly(ctx, rng, q.kind)
	end
	if not def then return { ok = false, message = "No other quest to swap in right now." } end
	local cost = rerollCost(st, slot)
	if cost > 0 then
		local have = math.max(0, math.floor(num(p.Tickets, 0)))
		if have < cost then
			return { ok = false, cost = cost,
				message = ("You need %d more %s."):format(cost - have, Config.TicketName or "Tickets") }
		end
		p.Tickets = have - cost
	end
	if slot == "daily" then st.rerolls += 1 end
	local nq = newQuest(st, def, ctx, rng)
	if slot == "daily" then
		st.daily[index] = nq
	else
		st.weekly = nq
	end
	dirty[player] = true
	local title = titleOf(def, nq.target)
	return { ok = true, id = nq.id, old = q.id, slot = slot, cost = cost, title = title,
		message = cost > 0 and ("New quest: %s (-%d %s)"):format(title, cost, Config.TicketName or "Tickets")
			or ("New quest: %s"):format(title) }
end

------------------------------------------------------------------
-- rebirth: the casino the pace quests were scaled to is gone
------------------------------------------------------------------
function Quests.onRebirth(player: Player)
	local p = Data and Data.get(player)
	if not (p and cfg()) then return end
	local st = ensure(p)
	st.pace = { games = 0, xp = 0, n = 0 }
	acc[player] = { games = 0, xp = 0, t0 = os.clock() }
	local ctx = context(player, p, st, true)
	local list = table.clone(st.daily)
	if type(st.weekly) == "table" then table.insert(list, st.weekly) end
	for _, q in list do
		if not q.done and PACE_KINDS[q.kind] then
			local t = targetFor(defOf(q.key), ctx, q.jit)
			if t < q.target then
				q.progress = q.progress / q.target * t -- the bar keeps its fill
				q.target = t
			end
		end
	end
	dirty[player] = true
	pushWanted[player] = true
end

------------------------------------------------------------------
-- pace measurement (games / XP per online minute)
------------------------------------------------------------------
local function samplePace(player: Player, st, now: number)
	local a = acc[player]
	if not a then
		acc[player] = { games = 0, xp = 0, t0 = now }
		return
	end
	local span = now - a.t0
	if span < 60 then return end
	local qc = cfg()
	local alpha = math.clamp(num(qc.PaceAlpha, 0.06), 0.001, 1)
	local warm = math.max(1, math.floor(1 / alpha + 0.5))
	local pace = st.pace
	local g, x = a.games * 60 / span, a.xp * 60 / span
	if pace.n < warm then -- a plain running mean until the EMA has its span
		pace.games += (g - pace.games) / (pace.n + 1)
		pace.xp += (x - pace.xp) / (pace.n + 1)
	else
		pace.games += alpha * (g - pace.games)
		pace.xp += alpha * (x - pace.xp)
	end
	pace.n = math.min(pace.n + 1, 1_000_000)
	a.games, a.xp, a.t0 = 0, 0, now
end

------------------------------------------------------------------
-- the 1 Hz step: rollovers, pace, the progress attribute, finished-quest pushes
------------------------------------------------------------------
local function progressString(st): string
	local parts = {}
	for _, q in st.daily do
		table.insert(parts, q.id .. ":" .. ("%.0f"):format(math.floor(q.progress)))
	end
	if type(st.weekly) == "table" then
		table.insert(parts, st.weekly.id .. ":" .. ("%.0f"):format(math.floor(st.weekly.progress)))
	end
	return table.concat(parts, "|")
end

local function step(player: Player, now: number)
	local p = Data and Data.get(player)
	if not p then return end
	local st = ensure(p)
	if refresh(player, p, st) then pushWanted[player] = true end
	samplePace(player, st, now)
	if dirty[player] then
		dirty[player] = nil
		player:SetAttribute(ATTR, progressString(st))
	end
	if pushWanted[player] then
		pushWanted[player] = nil
		if pushData then pushData(player) end
	end
end

function Quests.tick()
	-- Studio: ServerStorage attribute CasinoTestQuestsRedeal = true deals everyone a new
	-- daily set + weekly (with CasinoTestQuests' scale), once
	local redeal = false
	if RunService:IsStudio() and ServerStorage:GetAttribute("CasinoTestQuestsRedeal") == true then
		ServerStorage:SetAttribute("CasinoTestQuestsRedeal", nil)
		redeal = true
	end
	local now = os.clock()
	for _, player in Players:GetPlayers() do
		if redeal then
			local p = Data and Data.get(player)
			if p and type(p.Quests) == "table" then
				p.Quests.daily = {}
				p.Quests.weekly = nil
			end
		end
		local ok, err = pcall(step, player, now)
		if not ok then warn(("[Quests] %s: %s"):format(player.Name, tostring(err))) end
	end
end

------------------------------------------------------------------
-- snapshot key `quests`:
--   { day, week, resetIn (s to 00:00 UTC), weekResetIn (s to Monday 00:00 UTC),
--     daily = { quest... }, weekly = quest?, ready (claimable count), total,
--     rerolls = { used, free (left today), cost (Tickets of the next daily reroll) },
--     weeklyRerollCost, notice = { id, text }? }
--   quest = { id, key, slot, kind, group, title, desc, icon, tone, target, progress,
--             done, claimed, reward (Rewards.grant keys), cash (what its Cash pays now) }
------------------------------------------------------------------
function Quests.snapshot(player: Player, profile)
	local p = profile or (Data and Data.get(player))
	if not (p and cfg()) then return nil end
	local st = ensure(p)
	refresh(player, p, st)
	local function pack(q, slot: string)
		local def = defOf(q.key)
		local reward = rewardOf(q)
		local cash = nil
		if reward.cash and Rewards and Rewards.dailyCash then
			local ok, v = pcall(Rewards.dailyCash, player, reward)
			if ok then cash = v end
		end
		return {
			id = q.id, key = q.key, slot = slot, kind = q.kind, group = def.group,
			title = titleOf(def, q.target), desc = def.desc, icon = def.icon, tone = def.tone,
			target = q.target, progress = math.floor(q.progress), done = q.done, claimed = q.claimed,
			reward = table.clone(reward), cash = cash,
		}
	end
	local daily, ready = {}, 0
	for _, q in st.daily do
		table.insert(daily, pack(q, "daily"))
		if q.done and not q.claimed then ready += 1 end
	end
	local weekly = nil
	if type(st.weekly) == "table" then
		weekly = pack(st.weekly, "weekly")
		if st.weekly.done and not st.weekly.claimed then ready += 1 end
	end
	local now = os.time()
	local free = math.max(0, math.floor(num(cfg().FreeRerolls, 1)))
	return {
		day = st.day, week = st.week,
		resetIn = DAY - now % DAY,
		weekResetIn = math.max(0, weekEndsAt(weekOf(now // DAY)) - now),
		daily = daily, weekly = weekly, ready = ready, total = st.total,
		rerolls = { used = st.rerolls, free = math.max(0, free - st.rerolls), cost = rerollCost(st, "daily") },
		weeklyRerollCost = rerollCost(st, "weekly"),
		notice = notices[player],
	}
end

------------------------------------------------------------------
-- join / leave / start
------------------------------------------------------------------
function Quests.join(player: Player)
	local p = Data and Data.get(player)
	if not (p and cfg()) then return end
	local st = ensure(p)
	refresh(player, p, st)
	acc[player] = { games = 0, xp = 0, t0 = os.clock() }
	dirty[player] = nil
	pushWanted[player] = nil -- (init.server pushes the first snapshot right after the joins)
	player:SetAttribute(ATTR, progressString(st))
end

function Quests.leave(player: Player)
	acc[player] = nil
	dirty[player] = nil
	pushWanted[player] = nil
	notices[player] = nil
end

local function remote(name: string, fn)
	return function(player, id)
		local ok, res = pcall(fn, player, id)
		if not ok then
			warn(("[Quests] %s failed: %s"):format(name, tostring(res)))
			return { ok = false, message = "Something went wrong - try again." }
		end
		if type(res) == "table" and res.ok then
			pushWanted[player] = nil
			if pushData then pushData(player) end
			local p = Data and Data.get(player)
			if p and type(p.Quests) == "table" then
				dirty[player] = nil
				player:SetAttribute(ATTR, progressString(p.Quests))
			end
		end
		return res
	end
end

function Quests.start(d)
	deps = d or {}
	Data = deps.Data
	Rewards = deps.Rewards
	Progression = deps.Progression
	GameEvents = deps.GameEvents
	pushData = deps.pushData
	Remotes = deps.Remotes or require(Common:WaitForChild("Remotes"))
	if type(cfg()) ~= "table" then
		warn("[Quests] Config.Quests is missing: quests are off.")
		return
	end
	if started then return end
	started = true
	if GameEvents and GameEvents.on then
		for name, kind in KIND_OF do
			GameEvents.on(name, function(player, amount) Quests.progress(player, kind, amount) end)
		end
		-- the pace sample (targets scale with what the casino really does)
		GameEvents.on("gameHosted", function(player, amount)
			local a = acc[player]
			if a then a.games += num(amount, 0) end
		end)
		GameEvents.on("xpEarned", function(player, amount)
			local a = acc[player]
			if a then a.xp += num(amount, 0) end
		end)
		GameEvents.on("rebirth", function(player) Quests.onRebirth(player) end)
	else
		warn("[Quests] GameEvents is missing: quest progress can't be tracked.")
	end
	Remotes.ClaimQuest().OnServerInvoke = remote("claim", Quests.claim)
	Remotes.RerollQuest().OnServerInvoke = remote("reroll", Quests.reroll)
	task.spawn(function()
		while true do
			task.wait(1)
			local ok, err = pcall(Quests.tick)
			if not ok then warn("[Quests] tick: " .. tostring(err)) end
		end
	end)
end

return Quests
