--!nonstrict
-- Rewards.luau — Tickets (second currency), the 7-day Daily Reward streak and
-- the Ticket Shop (timed earnings boosts + a cash bundle).
--
-- Everything lives on the persistent profile (Data): Tickets, Daily.lastClaim,
-- Daily.streak and BoostUntil. All timing uses os.time() on the server, so a
-- client can't skip the cooldown by changing its clock.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Config = require(Common:WaitForChild("Config"))

local Rewards = {}
local Economy, Data

local function profileOf(player: Player)
	return Data and Data.get(player)
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
	return {
		day = (streak % #Config.DailyRewards) + 1,
		canClaim = canClaim,
		secondsLeft = canClaim and 0 or (cooldown - since),
		streak = streak,
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
	if reward.cash then Economy.addCash(player, reward.cash) end
	if reward.tickets then Rewards.addTickets(player, reward.tickets) end
	p.Daily = { lastClaim = os.time(), streak = st.streak + 1 }

	local parts = {}
	if reward.cash then table.insert(parts, "$" .. reward.cash) end
	if reward.tickets then table.insert(parts, reward.tickets .. " " .. Config.TicketName) end
	return { ok = true, day = st.day, cash = reward.cash, tickets = reward.tickets, mega = reward.mega == true,
		message = ("Day %d reward: %s!"):format(st.day, table.concat(parts, " + ")) }
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
	p.Tickets -= def.cost
	if def.boostMinutes then
		p.BoostUntil = math.max(os.time(), p.BoostUntil or 0) + def.boostMinutes * 60
		return { ok = true, message = ("2X Cash active for %d more minutes!"):format(def.boostMinutes) }
	end
	if def.cashGrant then
		Economy.addCash(player, def.cashGrant)
		return { ok = true, message = ("+$%d added to your bankroll!"):format(def.cashGrant) }
	end
	return { ok = true, message = "Purchased!" }
end

function Rewards.start(deps)
	Economy = deps.Economy
	Data = deps.Data
end

return Rewards
