--!nonstrict
-- LuckyWheel.luau — the LUCKY WHEEL (Config.LuckyWheel; client WheelUI).
--
-- profile.Wheel = { nextFree, spins, total } (Data v7): nextFree = os.time() of the
-- next free spin (0 = ready now), spins = owned bonus spins, total = spins made.
-- Remote SpinWheel(kind): "free" (one every FreeCooldownHours; the clock restarts
-- when it's used, so free spins never pile up), "tickets" (TicketCost Tickets) or
-- "bonus" (one owned bonus spin). The spin is paid at once; the server picks the
-- segment by weight, fixes its Cash now (income-scaled, so the prize the wheel shows
-- is the prize that's paid) and pays it RevealSeconds later, when the client's
-- wheel stops on it (at once if the player leaves first or the server closes). One
-- spin at a time per player.
--   -> { ok, message, kind, index, serial, revealIn, nextFree, spins, tickets,
--        prize = { id, name, jackpot, parts = Config.rewardParts of what it pays } }
--   -> { ok = false, message, nextFree? / needTickets? }
-- LuckyWheel.give(player, n) -> bonus spins owned (quest rewards & co.; the Robux
-- product `wheel_spins` is granted by Monetization straight into profile.Wheel).
-- Snapshot `wheel` = { nextFree (server os.time), spins, total, ticketCost,
--   cash = { [segment] = Cash it pays now, 0 = no Cash }, canBuy, productId, spinning }
--   canBuy: Robux spins may be offered to this player (PolicyService: paid random
--   items allowed where they live; unknown = no).
-- GameEvents: "wheelSpun" (1) per spin. A MEGA JACKPOT is shouted to the whole
-- server (Events.shout). Studio test aid: ServerStorage attribute
-- CasinoTestWheel = true makes the free spin ready again at once.

local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Config = require(Common:WaitForChild("Config"))

local LuckyWheel = {}

local Data, Rewards, pushData, GameEvents, Events
local rng = Random.new()
local pending: {[Player]: any} = {}       -- player -> the spin whose prize is still on its way
local lastSpin: {[Player]: number} = {}   -- os.clock() of their last accepted spin
local canBuy: {[Player]: boolean} = {}    -- Robux spins allowed (PolicyService)
local serial = 0
local started = false

local function cfg()
	return Config.LuckyWheel or {}
end

local function segments()
	return cfg().Segments or {}
end

local function weightOf(seg): number
	return math.max(0, tonumber(type(seg) == "table" and seg.weight) or 0)
end

local function totalWeight(): number
	local t = 0
	for _, seg in segments() do t += weightOf(seg) end
	return t
end

-- "1:02:03" / "4:05"
local function clock(seconds: number): string
	seconds = math.max(0, math.ceil(seconds))
	local h, m, s = seconds // 3600, (seconds % 3600) // 60, seconds % 60
	if h > 0 then return ("%d:%02d:%02d"):format(h, m, s) end
	return ("%d:%02d"):format(m, s)
end

-- the profile's Wheel table, well-formed
local function wheelOf(p)
	local w = p.Wheel
	if type(w) ~= "table" then
		w = { nextFree = 0, spins = 0, total = 0 }
		p.Wheel = w
	end
	w.nextFree = tonumber(w.nextFree) or 0
	w.spins = math.max(0, math.floor(tonumber(w.spins) or 0))
	w.total = math.max(0, math.floor(tonumber(w.total) or 0))
	return w
end

local function testFree(): boolean
	return RunService:IsStudio() and ServerStorage:GetAttribute("CasinoTestWheel") == true
end

local function gameEvent(player: Player, name: string, amount: number?)
	if GameEvents and GameEvents.emit then pcall(GameEvents.emit, player, name, amount) end
end

-- the segment a uniform roll u (0 <= u < 1) lands on (segments with weight 0 never)
function LuckyWheel.pick(u: number): number
	local list = segments()
	local x = math.clamp(tonumber(u) or 0, 0, 1) * totalWeight()
	local acc = 0
	for i, seg in list do
		local w = weightOf(seg)
		acc += w
		if w > 0 and x < acc then return i end
	end
	for i = #list, 1, -1 do -- (u = 1: the last segment that can win)
		if weightOf(list[i]) > 0 then return i end
	end
	return 1
end

-- every segment's chance per spin (0..1), in segment order
function LuckyWheel.chances(): {number}
	local total = totalWeight()
	local out = {}
	for i, seg in segments() do out[i] = total > 0 and weightOf(seg) / total or 0 end
	return out
end

-- what a segment pays this player: its Cash fixed now (income-scaled)
local function concreteReward(player: Player, seg)
	local reward = table.clone(type(seg.reward) == "table" and seg.reward or {})
	if reward.cash then
		local cash = Rewards and Rewards.dailyCash(player, reward) or reward.cash
		reward.cash = math.max(0, math.floor(tonumber(cash) or 0))
		reward.minutes = nil
	end
	return reward
end

-- pay a spin's prize (the wheel stopped, the player left or the server closes)
local function settle(player: Player, entry)
	if type(entry) ~= "table" or entry.settled then return nil end
	entry.settled = true
	if pending[player] == entry then pending[player] = nil end
	if not (Rewards and Data and Data.get(player)) then return nil end
	local ok, got = pcall(Rewards.grant, player, entry.reward)
	if not ok then
		warn("[LuckyWheel] prize not paid: " .. tostring(got))
		return nil
	end
	if entry.jackpot and Events and type(Events.shout) == "function" then
		pcall(Events.shout, "MEGA JACKPOT!",
			("%s won the Lucky Wheel MEGA JACKPOT!"):format(player.DisplayName or player.Name),
			{ userId = player.UserId, icon = "slot", tone = "Gold" })
	end
	if pushData and player.Parent then pcall(pushData, player) end
	return got
end
LuckyWheel.settle = settle -- (tests)

function LuckyWheel.spin(player: Player, kind: any)
	local p = Data and Data.get(player)
	if not p then return { ok = false, message = "Data not ready." } end
	if not Rewards then return { ok = false, message = "The wheel is closed right now." } end
	if kind ~= "free" and kind ~= "tickets" and kind ~= "bonus" then
		return { ok = false, message = "Unknown spin." }
	end
	if totalWeight() <= 0 then return { ok = false, message = "The wheel is closed right now." } end
	if pending[player] then return { ok = false, message = "The wheel is still spinning!" } end
	local clockNow = os.clock()
	if clockNow - (lastSpin[player] or -math.huge) < (tonumber(cfg().MinSpinGap) or 1) then
		return { ok = false, message = "One spin at a time!" }
	end
	local w = wheelOf(p)
	local now = os.time()

	-- the prize first: nothing below can fail once the spin is paid
	local index = LuckyWheel.pick(rng:NextNumber())
	local seg = segments()[index]
	local reward = concreteReward(player, seg)

	-- pay for the spin
	if kind == "free" then
		if now < w.nextFree and not testFree() then
			return { ok = false, message = ("Your next free spin is in %s."):format(clock(w.nextFree - now)),
				nextFree = w.nextFree }
		end
		w.nextFree = now + math.floor((tonumber(cfg().FreeCooldownHours) or 4) * 3600)
	elseif kind == "tickets" then
		local cost = math.max(0, math.floor(tonumber(cfg().TicketCost) or 35))
		local have = math.max(0, math.floor(tonumber(p.Tickets) or 0))
		if have < cost then
			return { ok = false, needTickets = cost - have,
				message = ("You need %d more %s."):format(cost - have, Config.TicketName or "Tickets") }
		end
		p.Tickets = have - cost
	else
		if w.spins < 1 then return { ok = false, message = "You have no bonus spins." } end
		w.spins -= 1
	end
	lastSpin[player] = clockNow
	w.total += 1

	serial += 1
	local revealIn = math.max(0, tonumber(cfg().RevealSeconds) or 5.5)
	local entry = { serial = serial, index = index, reward = reward, jackpot = seg.jackpot == true }
	pending[player] = entry
	task.delay(revealIn, function() settle(player, entry) end)
	gameEvent(player, "wheelSpun", 1)
	return {
		ok = true, kind = kind, index = index, serial = entry.serial, revealIn = revealIn,
		prize = { id = seg.id, name = seg.name or seg.id, jackpot = entry.jackpot,
			parts = Config.rewardParts(reward, reward.cash) },
		nextFree = w.nextFree, spins = w.spins, tickets = p.Tickets,
		message = "Spinning...",
	}
end

-- bonus spins for a player (quest rewards & co.); -> spins owned (0 = none / no data)
function LuckyWheel.give(player: Player?, n: number?): number
	local p = player and Data and Data.get(player)
	if not p then return 0 end
	local w = wheelOf(p)
	local add = math.floor(tonumber(n) or 0)
	if add > 0 then
		w.spins = math.min(math.floor(tonumber(cfg().MaxBonusSpins) or 999), w.spins + add)
	end
	return w.spins
end

-- seconds until the player's free spin (0 = ready)
function LuckyWheel.freeIn(player: Player): number
	local p = Data and Data.get(player)
	if not p or testFree() then return 0 end
	return math.max(0, wheelOf(p).nextFree - os.time())
end

function LuckyWheel.snapshot(player: Player, profile)
	local p = profile or (Data and Data.get(player))
	if type(p) ~= "table" then return nil end
	local w = wheelOf(p)
	local cash = {}
	for i, seg in segments() do
		local r = type(seg.reward) == "table" and seg.reward or nil
		local v = 0
		if r and r.cash then
			v = Rewards and tonumber(Rewards.dailyCash(player, r)) or tonumber(r.cash) or 0
		end
		cash[i] = math.floor(v)
	end
	local prod = Config.getProductByKey and Config.getProductByKey("wheel_spins")
	return {
		nextFree = testFree() and 0 or w.nextFree,
		spins = w.spins,
		total = w.total,
		ticketCost = math.max(0, math.floor(tonumber(cfg().TicketCost) or 35)),
		cash = cash,
		canBuy = canBuy[player] == true,
		productId = prod and tonumber(prod.id) or 0,
		spinning = pending[player] ~= nil,
	}
end

-- may this player be offered Robux spins? (paid random items: PolicyService; yields)
local function checkPolicy(player: Player)
	local ok, info = pcall(function()
		return game:GetService("PolicyService"):GetPolicyInfoForPlayerAsync(player)
	end)
	local allowed = ok and type(info) == "table" and info.ArePaidRandomItemsRestricted == false
	if allowed and player.Parent then
		canBuy[player] = true
		if pushData then pcall(pushData, player) end
	end
end

function LuckyWheel.join(player: Player)
	canBuy[player] = false
	local p = Data and Data.get(player)
	if p then wheelOf(p) end
	task.spawn(checkPolicy, player)
end

function LuckyWheel.leave(player: Player)
	local entry = pending[player]
	if entry then settle(player, entry) end -- (before the profile's final save)
	pending[player] = nil
	lastSpin[player] = nil
	canBuy[player] = nil
end

function LuckyWheel.start(deps)
	Data = deps.Data
	Rewards = deps.Rewards
	pushData = deps.pushData
	GameEvents = deps.GameEvents
	Events = deps.Events
	if started then return end
	started = true
	local Remotes = deps.Remotes or require(Common:WaitForChild("Remotes"))
	Remotes.SpinWheel().OnServerInvoke = function(player, kind)
		local ok, res = pcall(LuckyWheel.spin, player, kind)
		if not ok then
			warn("[LuckyWheel] spin failed: " .. tostring(res))
			return { ok = false, message = "Something went wrong - try again." }
		end
		if res.ok and pushData then pcall(pushData, player) end
		return res
	end
	-- a closing server pays every prize still on its way (the profiles save after)
	pcall(function()
		game:BindToClose(function()
			for player, entry in pending do settle(player, entry) end
		end)
	end)
end

return LuckyWheel
