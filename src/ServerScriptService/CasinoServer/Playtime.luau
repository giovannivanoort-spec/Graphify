--!nonstrict
-- Playtime.luau — the daily PLAYTIME rewards (Config.Playtime).
--
-- profile.Playtime = { day, seconds, claimed }: the UTC day (os.time() // 86400),
-- the seconds played that day (a 1 Hz loop adds the time each player is online)
-- and claimed[i] (true / false) per Config.Playtime.Rewards entry, always kept a
-- dense boolean array so DataStores and remotes never see a sparse table.
-- Entry i unlocks after `at` minutes played today; the remote ClaimPlaytime(i)
-- (or "all") pays it through Rewards.grant (Cash, Tickets, potions, stored x3
-- machine boost, rebirth coins). When the day rolls over (while online, or at the
-- next join) the old day's reached-but-unclaimed rewards are paid out and the
-- counter restarts at 0. Rebirths keep all of it.
--
-- Snapshot key `playtime`:
--   { day, seconds, claimed = {bool...}, cash = {Cash entry i pays now, 0 if none},
--     resetIn = seconds to 00:00 UTC, notice = { id, text }? (rewards paid out on a new day) }

local Players = game:GetService("Players")
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

local Playtime = {}

local DAY = 86400
local MAX_SECONDS = DAY + 3600      -- one day's counter never needs more
local MAX_STEP = 10                 -- seconds one tick may add (a long server hitch doesn't count double)
local Data, Rewards, pushData

local lastTick: {[Player]: number} = {}                       -- os.clock() of the last counted moment
local notices: {[Player]: {id: number, text: string}} = {}     -- the last day-rollover payout, per player
local noticeSeq = 0

local function rewardList()
	return (Config.Playtime and Config.Playtime.Rewards) or {}
end

local function today(): number
	return os.time() // DAY
end

local function clock(seconds: number): string
	seconds = math.max(0, math.ceil(seconds))
	local h, m, s = seconds // 3600, (seconds % 3600) // 60, seconds % 60
	if h > 0 then return ("%d:%02d:%02d"):format(h, m, s) end
	return ("%d:%02d"):format(m, s)
end

-- the profile's Playtime table, well-formed (claimed = one boolean per reward;
-- integer or string keys from an older save are folded in)
local function ensure(p)
	local pt = p.Playtime
	if type(pt) ~= "table" then
		pt = { day = 0, seconds = 0, claimed = {} }
		p.Playtime = pt
	end
	pt.day = math.floor(tonumber(pt.day) or 0)
	pt.seconds = math.clamp(tonumber(pt.seconds) or 0, 0, MAX_SECONDS)
	local n = #rewardList()
	local old = type(pt.claimed) == "table" and pt.claimed or {}
	local keys, dense = 0, true
	for k, v in old do
		keys += 1
		if type(k) ~= "number" or type(v) ~= "boolean" then dense = false end
	end
	if not (dense and keys == n and #old == n) then
		local claimed = table.create(n, false)
		for k, v in old do
			local i = tonumber(k)
			if i and i >= 1 and i <= n and i == math.floor(i) and v == true then claimed[i] = true end
		end
		pt.claimed = claimed
	end
	return pt
end

-- a new UTC day: pay out what the old day reached but nobody claimed, then restart
local function rollover(player: Player, pt, day: number)
	local paid = {}
	if pt.day > 0 and Rewards then
		for i, def in rewardList() do
			if not pt.claimed[i] and pt.seconds >= (def.at or 0) * 60 then
				pt.claimed[i] = true
				local got = Rewards.grant(player, def)
				for _, s in got.parts do table.insert(paid, s) end
			end
		end
	end
	pt.day = day
	pt.seconds = 0
	pt.claimed = table.create(#rewardList(), false)
	if #paid > 0 then
		noticeSeq += 1
		notices[player] = { id = noticeSeq, text = "Unclaimed playtime rewards paid out: " .. table.concat(paid, " + ") }
	end
end

-- (a server whose clock runs a little behind another's never rolls a day back)
local function catchUp(player: Player, pt): boolean
	local day = today()
	if day > pt.day then
		rollover(player, pt, day)
		return true
	end
	return false
end

-- one player's step: the time since their last step; a new day or a reward that
-- just unlocked pushes a fresh snapshot
local function step(player: Player, now: number)
	local p = Data and Data.get(player)
	if not p then return end
	local pt = ensure(p)
	local changed = catchUp(player, pt)
	local last = lastTick[player]
	lastTick[player] = now
	if last then
		local before = pt.seconds
		pt.seconds = math.min(MAX_SECONDS, before + math.clamp(now - last, 0, MAX_STEP))
		for _, def in rewardList() do
			local need = (def.at or 0) * 60
			if before < need and pt.seconds >= need then
				changed = true
				break
			end
		end
	end
	if changed and pushData then pushData(player) end
end

-- the 1 Hz step over every online player with a profile
function Playtime.tick()
	local now = os.clock()
	for _, player in Players:GetPlayers() do
		local ok, err = pcall(step, player, now)
		if not ok then warn(("[Playtime] %s: %s"):format(player.Name, tostring(err))) end
	end
end

local function claimIndex(player: Player, pt, i: number)
	pt.claimed[i] = true -- first: a second claim racing this one (a giver that yields) is refused
	return Rewards.grant(player, rewardList()[i])
end

-- ClaimPlaytime(index): index 1..#Rewards, or "all" (every unlocked, unclaimed one).
-- -> { ok, message, index?, indices?, reward?, parts? } / { ok = false, message, secondsLeft? }
function Playtime.claim(player: Player, index)
	local p = Data and Data.get(player)
	if not p then return { ok = false, message = "Data not ready." } end
	if not Rewards then return { ok = false, message = "Rewards are offline right now." } end
	local pt = ensure(p)
	catchUp(player, pt)
	local list = rewardList()
	local slack = (Config.Playtime and Config.Playtime.ClaimSlack) or 3
	local function unlocked(i: number): boolean
		return pt.seconds + slack >= (list[i].at or 0) * 60
	end

	if index == "all" then
		local parts, indices = {}, {}
		for i in list do
			if not pt.claimed[i] and unlocked(i) then
				local got = claimIndex(player, pt, i)
				table.insert(indices, i)
				for _, s in got.parts do table.insert(parts, s) end
			end
		end
		if #indices == 0 then return { ok = false, message = "Nothing to claim yet - keep playing!" } end
		gameEvent(player, "playtimeClaimed", #indices)
		return { ok = true, indices = indices, parts = parts,
			message = #parts > 0 and (table.concat(parts, " + ") .. "!") or "Claimed!" }
	end

	local i = tonumber(index)
	if not i or i ~= math.floor(i) or not list[i] then return { ok = false, message = "Unknown reward." } end
	if pt.claimed[i] then return { ok = false, message = "Already claimed today." } end
	if not unlocked(i) then
		local left = (list[i].at or 0) * 60 - pt.seconds
		return { ok = false, message = ("Play %s more to unlock it."):format(clock(left)), secondsLeft = left }
	end
	local got = claimIndex(player, pt, i)
	gameEvent(player, "playtimeClaimed", 1)
	return { ok = true, index = i, reward = got, parts = got.parts,
		message = #got.parts > 0 and (table.concat(got.parts, " + ") .. "!") or "Claimed!" }
end

function Playtime.snapshot(player: Player, profile)
	local p = profile or (Data and Data.get(player))
	if not p then return nil end
	local pt = ensure(p)
	local list = rewardList()
	local cash = table.create(#list, 0)
	for i, def in list do
		if def.cash then
			cash[i] = (Rewards and Rewards.dailyCash(player, def)) or def.cash
		end
	end
	return {
		day = pt.day,
		seconds = math.floor(pt.seconds),
		claimed = table.clone(pt.claimed),
		cash = cash,
		resetIn = DAY - os.time() % DAY,
		notice = notices[player],
	}
end

function Playtime.join(player: Player)
	local p = Data and Data.get(player)
	if not p then return end
	catchUp(player, ensure(p))
	lastTick[player] = os.clock()
end

function Playtime.leave(player: Player)
	-- the last part-second still counts (the profile is saved right after)
	local p = Data and Data.get(player)
	local last = lastTick[player]
	if p and last then
		local pt = ensure(p)
		pt.seconds = math.min(MAX_SECONDS, pt.seconds + math.clamp(os.clock() - last, 0, MAX_STEP))
	end
	lastTick[player] = nil
	notices[player] = nil
end

function Playtime.start(deps)
	Data = deps.Data
	Rewards = deps.Rewards
	pushData = deps.pushData
	local Remotes = deps.Remotes or require(Common:WaitForChild("Remotes"))
	Remotes.ClaimPlaytime().OnServerInvoke = function(player, index)
		local ok, res = pcall(Playtime.claim, player, index)
		if not ok then
			warn("[Playtime] claim failed: " .. tostring(res))
			return { ok = false, message = "Something went wrong - try again." }
		end
		if res.ok and pushData then pushData(player) end
		return res
	end
	task.spawn(function()
		while true do
			task.wait(1)
			local ok, err = pcall(Playtime.tick)
			if not ok then warn("[Playtime] tick failed: " .. tostring(err)) end
		end
	end)
end

return Playtime
