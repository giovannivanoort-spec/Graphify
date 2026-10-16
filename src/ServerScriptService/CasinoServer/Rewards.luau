--!nonstrict
-- Rewards.luau — Tickets (second currency), the 7-day Daily Reward streak,
-- the Ticket Shop (timed earnings boosts + a cash bundle) and Rewards.grant,
-- the one payout path of the daily and playtime rewards (Cash, Tickets,
-- potions, stored x3 machine boost, rebirth coins).
--
-- Everything lives on the persistent profile (Data): Tickets, Daily.lastClaim,
-- Daily.streak and BoostUntil. All timing uses os.time() on the server, so a
-- client can't skip the cooldown by changing its clock.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Config = require(Common:WaitForChild("Config"))

local Rewards = {}
local Economy, Data
local Deps -- the server's deps table: Potions / MachineBoost / Rebirth (each may be missing)

local function profileOf(player: Player)
	return Data and Data.get(player)
end

local function commas(n: number): string
	local s = tostring(math.floor(n))
	local k
	repeat s, k = s:gsub("^(-?%d+)(%d%d%d)", "%1,%2") until k == 0
	return s
end

-- the owner's income rate ($/min, Stats.IncomeRate: EMA of unboosted net casino income)
local function incomeRate(p): number
	local stats = p and p.Stats
	return math.max(0, tonumber(type(stats) == "table" and stats.IncomeRate or 0) or 0)
end

-- a daily reward's Cash: the flat amount, or `minutes` of the income rate if that's more
function Rewards.dailyCash(player: Player, reward): number?
	if not (reward and reward.cash) then return nil end
	local cash = reward.cash
	if reward.minutes then
		cash = math.max(cash, math.floor(incomeRate(profileOf(player)) * reward.minutes))
	end
	return cash
end

-- the ticket Cash Bundle: max(cashGrant, cashIncomeMinutes x the income rate)
function Rewards.bundleCash(player: Player, def): number
	local cash = def.cashGrant or 0
	if def.cashIncomeMinutes then
		cash = math.max(cash, math.floor(incomeRate(profileOf(player)) * def.cashIncomeMinutes))
	end
	return cash
end

------------------------------------------------------------------
-- tickets
------------------------------------------------------------------
function Rewards.getTickets(player: Player): number
	local p = profileOf(player)
	return p and (p.Tickets or 0) or 0
end

function Rewards.addTickets(player: Player, amount: number)
	local p = profileOf(player)
	if not p then return end
	p.Tickets = math.max(0, math.floor((p.Tickets or 0) + amount))
end

------------------------------------------------------------------
-- reward payout (daily + playtime)
------------------------------------------------------------------
-- an optional module's giver, e.g. tryGive("Potions", "give", player, id, n):
-- false when the module is missing, errors, or answers false / 0 (Rebirth.giveCoins
-- returns the new coin total) / { ok = false }
local function tryGive(moduleName: string, fnName: string, ...): boolean
	local m = Deps and Deps[moduleName]
	local fn = type(m) == "table" and m[fnName]
	if type(fn) ~= "function" then return false end
	local ok, res = pcall(fn, ...)
	if not ok then
		warn(("[Rewards] %s.%s failed: %s"):format(moduleName, fnName, tostring(res)))
		return false
	end
	return res ~= false and res ~= 0 and not (type(res) == "table" and res.ok == false)
end

local function potionName(id: string): string
	for _, part in Config.rewardParts({ potion = id }) do
		if part.kind == "potion" then return part.name end
	end
	return id .. " Potion"
end

-- Pays one reward table (a Config.DailyRewards / Config.Playtime.Rewards entry):
-- Cash (income-scaled, Rewards.dailyCash), Tickets, `potionCount` x potion `potion`
-- (Potions.give), `boostMinutes` of stored x3 machine boost (MachineBoost.give) and
-- `rcoins` rebirth coins (Rebirth.giveCoins). A piece whose module is missing or
-- refuses pays Tickets instead (the potion's Ticket Shop price, else
-- Config.Playtime.FallbackTickets). Returns what was paid:
--   { cash?, tickets?, potion?, potionCount?, boostSeconds?, rcoins?, parts = { "1 Rebirth Coin", "$1,234", ... } }
function Rewards.grant(player: Player, reward)
	local out = { parts = {} }
	if type(reward) ~= "table" or not profileOf(player) then return out end
	local fallback = (Config.Playtime and Config.Playtime.FallbackTickets) or {}
	local extraTickets = 0

	-- rarest first (the order of Config.rewardParts)
	local coins = math.floor(tonumber(reward.rcoins) or 0)
	if coins > 0 then
		if tryGive("Rebirth", "giveCoins", player, coins) then
			out.rcoins = coins
			table.insert(out.parts, coins == 1 and "1 Rebirth Coin" or (coins .. " Rebirth Coins"))
		else
			extraTickets += (fallback.rcoin or 60) * coins
		end
	end
	if type(reward.potion) == "string" then
		local count = math.max(1, math.floor(tonumber(reward.potionCount) or 1))
		local def = Config.rewardPotionDef(reward.potion)
		if tryGive("Potions", "give", player, Config.rewardPotionId(reward.potion), count) then
			out.potion, out.potionCount = reward.potion, count
			local name = potionName(reward.potion)
			table.insert(out.parts, count == 1 and name or (count .. " " .. name .. "s"))
		else
			extraTickets += (tonumber(def and def.tickets) or fallback.potion or 45) * count
		end
	end
	local boostMinutes = tonumber(reward.boostMinutes) or 0
	if boostMinutes > 0 then
		local seconds = math.floor(boostMinutes * 60)
		if tryGive("MachineBoost", "give", player, seconds) then
			out.boostSeconds = seconds
			table.insert(out.parts, ("%d min x3 Machine Boost"):format(math.floor(boostMinutes + 0.5)))
		else
			extraTickets += (fallback.boost or 30) * math.max(1, math.ceil(boostMinutes / 15))
		end
	end
	local cash = Rewards.dailyCash(player, reward)
	if cash and cash > 0 then
		Economy.addCash(player, cash)
		out.cash = cash
		table.insert(out.parts, "$" .. commas(cash))
	end
	local tickets = math.floor(tonumber(reward.tickets) or 0) + extraTickets
	if tickets > 0 then
		Rewards.addTickets(player, tickets)
		out.tickets = tickets
		table.insert(out.parts, commas(tickets) .. " " .. Config.TicketName)
	end
	return out
end

------------------------------------------------------------------
-- daily reward
------------------------------------------------------------------
-- { day = next reward index (1..#DailyRewards), canClaim, secondsLeft, streak }
function Rewards.dailyState(player: Player)
	local p = profileOf(player)
	if not p then return { day = 1, canClaim = false, secondsLeft = 0, streak = 0 } end
	local d = p.Daily or { lastClaim = 0, streak = 0 }
	local now = os.time()
	local since = now - (d.lastClaim or 0)
	local cooldown = Config.DailyCooldownHours * 3600
	local streak = d.streak or 0
	-- a missed day (or a first-ever visit) restarts the streak
	if (d.lastClaim or 0) <= 0 or since >= Config.DailyStreakResetHours * 3600 then
		streak = 0
	end
	local canClaim = (d.lastClaim or 0) <= 0 or since >= cooldown
	local day = (streak % #Config.DailyRewards) + 1
	-- what each cash day pays this player right now (scaled to their income)
	local cashByDay = {}
	for i, reward in Config.DailyRewards do
		cashByDay[i] = Rewards.dailyCash(player, reward) or 0
	end
	return {
		day = day,
		canClaim = canClaim,
		secondsLeft = canClaim and 0 or (cooldown - since),
		streak = streak,
		cash = cashByDay[day],
		cashByDay = cashByDay,
	}
end

function Rewards.claimDaily(player: Player)
	local p = profileOf(player)
	if not p then return { ok = false, message = "Data not ready." } end
	local st = Rewards.dailyState(player)
	if not st.canClaim then
		local h = math.floor(st.secondsLeft / 3600)
		local m = math.floor((st.secondsLeft % 3600) / 60)
		return { ok = false, message = ("Next reward in %dh %02dm."):format(h, m) }
	end
	local reward = Config.DailyRewards[st.day]
	-- the streak moves first: a second claim racing this one (a giver that yields) is refused
	p.Daily = { lastClaim = os.time(), streak = st.streak + 1 }
	local got = Rewards.grant(player, reward)
	return { ok = true, day = st.day, cash = got.cash, tickets = got.tickets, potion = got.potion,
		potionCount = got.potionCount, rcoins = got.rcoins, boostSeconds = got.boostSeconds,
		parts = got.parts, mega = reward.mega == true,
		message = ("Day %d reward: %s!"):format(st.day, table.concat(got.parts, " + ")) }
end

------------------------------------------------------------------
-- ticket shop + boost
------------------------------------------------------------------
function Rewards.boostSecondsLeft(player: Player): number
	local p = profileOf(player)
	return p and math.max(0, (p.BoostUntil or 0) - os.time()) or 0
end

-- multiplier applied to positive machine earnings (see Monetization)
function Rewards.boostMultiplier(player: Player): number
	return Rewards.boostSecondsLeft(player) > 0 and Config.BoostMultiplier or 1
end

function Rewards.buyTicketItem(player: Player, itemId: string)
	local def = type(itemId) == "string" and Config.getTicketItem(itemId)
	if not def then return { ok = false, message = "Unknown item." } end
	local p = profileOf(player)
	if not p then return { ok = false, message = "Data not ready." } end
	if (p.Tickets or 0) < def.cost then
		return { ok = false, message = ("You need %d more %s."):format(def.cost - (p.Tickets or 0), Config.TicketName) }
	end
	-- a potion (Config.Potions): into the potion stock; Tickets are only taken once it's in
	if def.potion then
		local count = math.max(1, math.floor(tonumber(def.count) or 1))
		if not tryGive("Potions", "give", player, def.potion, count) then
			return { ok = false, message = "Potions aren't available right now." }
		end
		p.Tickets -= def.cost
		return { ok = true, potion = def.potion, count = count,
			message = ("%s added to your potions!"):format(def.name) }
	end
	p.Tickets -= def.cost
	if def.boostMinutes then
		p.BoostUntil = math.max(os.time(), p.BoostUntil or 0) + def.boostMinutes * 60
		return { ok = true, message = ("2X Cash active for %d more minutes!"):format(def.boostMinutes) }
	end
	if def.cashGrant then
		local cash = Rewards.bundleCash(player, def)
		Economy.addCash(player, cash)
		return { ok = true, cash = cash, message = ("+$%s added to your bankroll!"):format(commas(cash)) }
	end
	return { ok = true, message = "Purchased!" }
end

function Rewards.start(deps)
	Economy = deps.Economy
	Data = deps.Data
	Deps = deps
end

return Rewards
