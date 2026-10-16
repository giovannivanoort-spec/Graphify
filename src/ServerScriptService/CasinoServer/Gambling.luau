--!nonstrict
-- Gambling.luau — bankroll model. Owner Cash funds payouts; owner gains on
-- visitor losses, pays on visitor wins. Real players' bets must be covered by
-- the owner's Cash; NPC guests' bets never are limited by it (economy_spec 6.2:
-- a broke new casino keeps earning). The owner's Cash floors at 0.
-- NPC guests carry a guest weight W (NPCs flow): everything they pay the owner
-- (round results, stand sales, tips) counts W times, before the earnings
-- multiplier. Tracks persistent stats on the owner's profile and feeds the
-- Casino Rank: every resolved round earns the owner XP (Config.machineXP x W,
-- Progression.addXP) and the income rate. Positive owner results are multiplied
-- by the earnings multiplier (passes / ticket boost) x (1 + cashMult effect) x the
-- machine's x3 boost (MachineBoost). Used by players and NPCs.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Config = require(Common:WaitForChild("Config"))
local GameLogic = require(Common:WaitForChild("GameLogic"))
local Remotes = require(Common:WaitForChild("Remotes"))
local MachineVisuals = require(script.Parent:WaitForChild("MachineVisuals"))

local Gambling = {}
local Economy, Staff, Data, Monetization, Progression, Upgrades, MachineBoost

local PLAY_COOLDOWN = 0.5      -- seconds between a real player's rounds (no XP farming by spam)
local lastPlay: {[number]: number} = {}

-- GameEvents (quests & co.): required once, lazily (it's a sibling module)
local GameEvents = nil
local function gameEvent(player, name: string, amount: number?)
	if GameEvents == nil then
		local m = script.Parent:FindFirstChild("GameEvents")
		local ok, res = pcall(function() return m and require(m) end)
		GameEvents = (ok and type(res) == "table") and res or false
	end
	if GameEvents then pcall(GameEvents.emit, player, name, amount) end
end

------------------------------------------------------------------
-- owner-facing effects (CasinoClient/UXFX), purely cosmetic: the owner sees
-- "+$X" pop over each of their machines as the house wins (summed per
-- machine, one batch a second, only machines near the owner), and a JACKPOT
-- moment when a guest hits a big multiplier (throttled per owner).
------------------------------------------------------------------
local FX_FLUSH = 1             -- seconds between income batches per owner
local FX_MAX_ENTRIES = 12      -- the biggest machines per batch
local FX_RANGE = 220           -- studs from the owner's character
local BIG_WIN_MULT = 10        -- a guest win of >= 10x the bet is a big-win moment
local BIG_WIN_COOLDOWN = 4     -- seconds between big-win moments per owner
local fxPending: {[Player]: {[Instance]: number}} = {}
local lastBigWin: {[number]: number} = {}
local fxStarted = false

local function fireFx(owner: Player, payload)
	local ok, err = pcall(function() Remotes.FX():FireClient(owner, payload) end)
	if not ok then warn("[Gambling] fx: " .. tostring(err)) end
end

-- Report owner income made at a machine (gambling does this itself; the
-- concession visit in NPCs can call it too, to get its gold "+$X" pop).
function Gambling.fxIncome(owner: Player?, machine: Instance?, amount: number?)
	if not (owner and machine and amount and amount >= 1) then return end
	local per = fxPending[owner]
	if not per then
		per = {}
		fxPending[owner] = per
	end
	per[machine] = (per[machine] or 0) + amount
end

local function fxBigWin(owner: Player?, machine: Instance, bet: number, payout: number, byPlayer: Player?)
	if not owner or bet <= 0 or payout < bet * BIG_WIN_MULT then return end
	local now = os.clock()
	if now - (lastBigWin[owner.UserId] or -math.huge) < BIG_WIN_COOLDOWN then return end
	lastBigWin[owner.UserId] = now
	local body = (machine:IsA("Model") and machine.PrimaryPart) or machine:FindFirstChild("Body")
	fireFx(owner, {
		kind = "bigwin", machine = machine, pos = (body and body:IsA("BasePart")) and body.Position or nil,
		amount = payout - bet, mult = math.floor(payout / bet + 0.5), name = machine.Name,
		by = byPlayer and byPlayer.DisplayName or nil,
	})
end

local function flushFx()
	for owner, per in fxPending do
		fxPending[owner] = nil
		local char = owner.Parent and owner.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if root then
			local list = {}
			for machine, amount in per do
				local body = machine.Parent
					and ((machine:IsA("Model") and machine.PrimaryPart) or machine:FindFirstChild("Body"))
				if body and body:IsA("BasePart") and (body.Position - root.Position).Magnitude <= FX_RANGE then
					table.insert(list, { m = machine, p = body.Position, a = math.floor(amount),
						c = (machine:GetAttribute("Kind") == "concession") or nil })
				end
			end
			if #list > 0 then
				table.sort(list, function(x, y) return x.a > y.a end)
				for i = #list, FX_MAX_ENTRIES + 1, -1 do list[i] = nil end
				fireFx(owner, { kind = "income", list = list })
			end
		end
	end
end

-- Show a play on the physical machine. Every type bumps PlayTick/LastWin so the
-- clients animate it locally (MachineFX: wheels spin, dice roll, bulbs flash);
-- slot reels/LEDs are additionally driven from here (MachineVisuals).
local function showSlotOutcome(machine, gameType, result)
	if gameType == "Plinko" then MachineVisuals.setPlinkoPath(machine, result) end
	machine:SetAttribute("LastWin", result.won == true)
	machine:SetAttribute("PlayTick", (machine:GetAttribute("PlayTick") or 0) + 1)
	if gameType ~= "Slots" then return end
	local reels = result.detail and result.detail.reels
	MachineVisuals.showOutcome(machine, reels, result.won == true)
end

function Gambling.coverageNeeded(gameType: string, bet: number): number
	return bet * GameLogic.maxMultiplier(gameType)
end

function Gambling.maxCoverableBet(owner: Player, gameType: string, machineMax: number): number
	if not owner then return 0 end
	local byBankroll = math.floor(Economy.getCash(owner) / GameLogic.maxMultiplier(gameType))
	return math.min(machineMax, byBankroll)
end

-- weight: the guest weight W of an NPC guest (1 for real players). The round's
-- result counts W times, before the gamepass / ticket-boost multiplier.
-- what positive owner earnings are multiplied by: passes / ticket boost x
-- (1 + cashMult: rebirth upgrades, potions, staff) x the machine's boost (x3)
-- x the machine's own IncomeMult (rebirth-machine perk) x the VIP floor bonus
local function earningsMultiplier(owner: Player, profile, machine: Instance?): number
	local mult = Monetization and Monetization.getEarningsMultiplier(owner) or 1
	if Upgrades and profile then mult *= 1 + math.max(0, Upgrades.effect(profile, "cashMult")) end
	if MachineBoost and machine then
		local ok, m = pcall(MachineBoost.multiplier, machine)
		if ok and type(m) == "number" and m > 0 then mult *= m end
	end
	if machine then
		local perk = tonumber(machine:GetAttribute("IncomeMult"))
		if perk and perk > 0 then mult *= perk end
		if machine:GetAttribute("VipFloor") == true then
			mult *= (Config.VipFloor and Config.VipFloor.IncomeMult) or 1.25
		end
	end
	return mult
end

local function payOwner(owner: Player, gameType: string, bet: number, result, machine: Instance?, weight: number?)
	local w = math.max(1, weight or 1)
	-- staff skim rounds (a 2% skim of a $20 bet is $0.40 -> $0, of a $30 bet $1)
	local staffSkim = math.floor(bet * Staff.getHouseBonus(owner) + 0.5)
	local base = ((bet - result.payout) + staffSkim) * w
	local ownerDelta = math.floor(base)
	local p = Data.get(owner)
	-- passes / boosts / cashMult multiply positive owner earnings only (never losses)
	if ownerDelta > 0 then
		ownerDelta = math.floor(ownerDelta * earningsMultiplier(owner, p, machine))
	end
	Economy.addCash(owner, ownerDelta)
	if ownerDelta > 0 then Gambling.fxIncome(owner, machine, ownerDelta) end

	if p then
		p.Stats.SpinsHosted += w
		if result.payout > bet then
			local paid = result.payout - bet
			p.Stats.TotalPaidOut += paid * w
			if paid > p.Stats.BiggestWinPaid then p.Stats.BiggestWinPaid = paid end
		end
		if ownerDelta > 0 then p.Stats.TotalEarned += ownerDelta end
	end
	if Progression then
		Progression.noteIncome(owner, base, ownerDelta)
		-- XP: every game a guest plays (better machines are worth more)
		local def = machine and Config.getMachineDef(machine:GetAttribute("MachineId"))
		local xp = def and Config.machineXP(def) or 1
		if xp > 0 and Progression.addXP then Progression.addXP(owner, xp * w) end
	end
	gameEvent(owner, "gameHosted", w)
	if ownerDelta > 0 then gameEvent(owner, "cashEarned", ownerDelta) end
	return ownerDelta
end

-- An NPC guest pays the owner outside a game: a stand sale (machine = the
-- stand) or a Tip Jar tip (machine = the last machine they played, where the
-- "+$" pops). x the guest weight, x the earnings multiplier (VIP pass / ticket
-- boost); counts to TotalEarned and the Casino Rank. Returns the Cash paid.
function Gambling.npcSpend(ownerId: number?, machine: Instance?, amount: number?, weight: number?): number
	local owner = ownerId and Players:GetPlayerByUserId(ownerId)
	if not (owner and amount and amount > 0) then return 0 end
	local base = amount * math.max(1, weight or 1)
	local paid = math.floor(base)
	local p = Data.get(owner)
	-- (no machine boost here: the x3 boost is for game rounds)
	paid = math.floor(paid * earningsMultiplier(owner, p, nil))
	if paid <= 0 then return 0 end
	Economy.addCash(owner, paid)
	if p then p.Stats.TotalEarned += paid end
	if Progression then
		Progression.noteIncome(owner, base, paid)
		Progression.touch(owner)
	end
	gameEvent(owner, "cashEarned", paid)
	Gambling.fxIncome(owner, machine, paid)
	return paid
end

-- A real player gambles.
function Gambling.play(player: Player, machine: Instance?, bet: number, choice: any)
	if typeof(machine) ~= "Instance" or not machine:GetAttribute("GameType") then
		return { ok = false, message = "That isn't a casino machine." }
	end
	local ownerId = machine:GetAttribute("OwnerId")
	local gameType = machine:GetAttribute("GameType")
	local minBet = machine:GetAttribute("MinBet") or 1
	local maxBet = machine:GetAttribute("MaxBet") or 100

	if ownerId == player.UserId then
		return { ok = false, message = "You can't gamble at your own casino!" }
	end
	local now = os.clock()
	if now - (lastPlay[player.UserId] or -math.huge) < PLAY_COOLDOWN then
		return { ok = false, message = "Slow down!" }
	end
	lastPlay[player.UserId] = now
	local owner = ownerId and Players:GetPlayerByUserId(ownerId)
	if not owner then return { ok = false, message = "The casino owner is away." } end

	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	local body = (machine :: Model).PrimaryPart or machine:FindFirstChild("Body")
	if root and body and (root.Position - body.Position).Magnitude > 22 then
		return { ok = false, message = "Too far from the machine." }
	end

	bet = math.floor(tonumber(bet) or 0)
	if bet < minBet or bet > maxBet then
		return { ok = false, message = ("Bet must be %d - %d."):format(minBet, maxBet) }
	end

	local maxCover = Gambling.maxCoverableBet(owner, gameType, maxBet)
	if bet > maxCover then
		if maxCover < minBet then return { ok = false, message = "This casino can't cover bets right now." } end
		return { ok = false, message = ("Casino can only cover up to %d right now."):format(maxCover) }
	end

	if not Economy.tryWithdraw(player, bet) then
		return { ok = false, message = "Not enough " .. Config.CurrencyName .. "." }
	end

	local result = GameLogic.resolve(gameType, bet, choice)
	payOwner(owner, gameType, bet, result, machine)
	if result.payout > 0 then Economy.addCash(player, result.payout) end
	showSlotOutcome(machine, gameType, result)
	pcall(fxBigWin, owner, machine, bet, result.payout, player) -- cosmetic: never in the way of a play

	local net = result.payout - bet
	local message = net > 0 and ("You won %d!"):format(net)
		or (net == 0 and "Push — bet returned." or ("You lost %d."):format(-net))
	return { ok = true, message = message, won = result.won, payout = result.payout,
		net = net, detail = result.detail, balance = Economy.getCash(player) }
end

-- An NPC patron gambles (only the owner's Cash is affected). weight = the
-- guest weight W (the owner's side of the round counts W times).
-- cheat (a cheating guest, Cheaters.luau): { winBoost = n | { [gameType] = n, default = n },
-- tries, maxWeight }: no house tilt, winBoost of the losing rounds re-rolled until
-- they win (a real outcome, so the machine shows it), the round counts at most
-- maxWeight times (a cheater hurts, but can't wipe a busy casino).
local npcTiltRng = Random.new()
function Gambling.npcPlay(machine: Instance, bet: number, choice: any, tiltOverride: number?, weight: number?, cheat: any?)
	if not machine:GetAttribute("GameType") then return nil end
	local ownerId = machine:GetAttribute("OwnerId")
	local owner = ownerId and Players:GetPlayerByUserId(ownerId)
	if not owner then return nil end
	local gameType = machine:GetAttribute("GameType")

	-- (no bankroll coverage for guests: an owner who spent down to $0 keeps
	-- earning; Economy.addCash floors their Cash at 0 on a guest's big win)
	bet = math.floor(bet)
	if bet < (machine:GetAttribute("MinBet") or 1) or bet <= 0 then return nil end

	local result = GameLogic.resolve(gameType, bet, choice)
	if type(cheat) == "table" then
		local boost = cheat.winBoost
		if type(boost) == "table" then boost = boost[gameType] or boost.default end
		if result.payout <= bet and npcTiltRng:NextNumber() < (tonumber(boost) or 0) then
			for _ = 1, tonumber(cheat.tries) or 40 do
				local again = GameLogic.resolve(gameType, bet, choice)
				if again.payout > bet then
					result = again
					break
				end
			end
		end
		weight = math.min(weight or 1, tonumber(cheat.maxWeight) or 1)
	else
		-- House tilt: NPC patrons lose more often than pure RNG so player owners
		-- earn faster. When the NPC would have won, with ExtraLossChance probability
		-- the win is zeroed (counts as a loss instead).
		local tilt = tiltOverride or Config.NPC.ExtraLossChance or 0
		tilt = math.clamp(tilt, 0, 0.85)
		if result.payout > bet and tilt > 0 and npcTiltRng:NextNumber() < tilt then
			result = { won = false, payout = 0, detail = result.detail }
		end
	end
	local ownerDelta = payOwner(owner, gameType, bet, result, machine, weight)
	showSlotOutcome(machine, gameType, result)
	pcall(fxBigWin, owner, machine, bet, result.payout, nil)
	return { bet = bet, payout = result.payout, npcNet = result.payout - bet,
		ownerDelta = ownerDelta, detail = result.detail, gameType = gameType }
end

function Gambling.start(deps)
	Economy = deps.Economy
	Staff = deps.Staff
	Data = deps.Data
	Monetization = deps.Monetization
	Progression = deps.Progression
	Upgrades = deps.Upgrades
	MachineBoost = deps.MachineBoost
	if not fxStarted then
		fxStarted = true
		task.spawn(function()
			while true do
				task.wait(FX_FLUSH)
				local ok, err = pcall(flushFx)
				if not ok then warn("[Gambling] fx flush: " .. tostring(err)) end
			end
		end)
		Players.PlayerRemoving:Connect(function(p)
			fxPending[p] = nil
			lastBigWin[p.UserId] = nil
			lastPlay[p.UserId] = nil
		end)
	end
end

return Gambling
