--!nonstrict
-- Gambling.luau — bankroll model. Owner Cash funds payouts; owner gains on
-- visitor losses, pays on visitor wins. Coverage gate + 0 floor protect owners.
-- Tracks persistent stats on the owner's profile. Used by players and NPCs.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Config = require(Common:WaitForChild("Config"))
local GameLogic = require(Common:WaitForChild("GameLogic"))
local MachineVisuals = require(script.Parent:WaitForChild("MachineVisuals"))

local Gambling = {}
local Economy, Staff, Data, Monetization

-- Show a play on the physical machine. Every type bumps PlayTick/LastWin so the
-- clients animate it locally (MachineFX: wheels spin, dice roll, bulbs flash);
-- slot reels/LEDs are additionally driven from here (MachineVisuals).
local function showSlotOutcome(machine, gameType, result)
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

local function payOwner(owner: Player, gameType: string, bet: number, result)
	local staffSkim = math.floor(bet * Staff.getHouseBonus(owner))
	local ownerDelta = (bet - result.payout) + staffSkim
	-- VIP / 2x-cash gamepasses multiply positive owner earnings only (never losses)
	if ownerDelta > 0 and Monetization then
		ownerDelta = math.floor(ownerDelta * Monetization.getEarningsMultiplier(owner))
	end
	Economy.addCash(owner, ownerDelta)

	local p = Data.get(owner)
	if p then
		p.Stats.SpinsHosted += 1
		if result.payout > bet then
			local paid = result.payout - bet
			p.Stats.TotalPaidOut += paid
			if paid > p.Stats.BiggestWinPaid then p.Stats.BiggestWinPaid = paid end
		end
		if ownerDelta > 0 then p.Stats.TotalEarned += ownerDelta end
	end
	return ownerDelta
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
	payOwner(owner, gameType, bet, result)
	if result.payout > 0 then Economy.addCash(player, result.payout) end
	showSlotOutcome(machine, gameType, result)

	local net = result.payout - bet
	local message = net > 0 and ("You won %d!"):format(net)
		or (net == 0 and "Push — bet returned." or ("You lost %d."):format(-net))
	return { ok = true, message = message, won = result.won, payout = result.payout,
		net = net, detail = result.detail, balance = Economy.getCash(player) }
end

-- An NPC patron gambles (only the owner's Cash is affected).
local npcTiltRng = Random.new()
function Gambling.npcPlay(machine: Instance, bet: number, choice: any, tiltOverride: number?)
	if not machine:GetAttribute("GameType") then return nil end
	local ownerId = machine:GetAttribute("OwnerId")
	local owner = ownerId and Players:GetPlayerByUserId(ownerId)
	if not owner then return nil end
	local gameType = machine:GetAttribute("GameType")
	local maxBet = machine:GetAttribute("MaxBet") or 100

	bet = math.floor(bet)
	if bet < (machine:GetAttribute("MinBet") or 1) then return nil end
	local maxCover = Gambling.maxCoverableBet(owner, gameType, maxBet)
	if bet > maxCover then bet = maxCover end
	if bet <= 0 then return nil end

	local result = GameLogic.resolve(gameType, bet, choice)
	-- House tilt: NPC patrons lose more often than pure RNG so player owners
	-- earn faster. When the NPC would have won, with ExtraLossChance probability
	-- the win is zeroed (counts as a loss instead).
	local tilt = tiltOverride or Config.NPC.ExtraLossChance or 0
	tilt = math.clamp(tilt, 0, 0.85)
	if result.payout > bet and tilt > 0 and npcTiltRng:NextNumber() < tilt then
		result = { won = false, payout = 0, detail = result.detail }
	end
	local ownerDelta = payOwner(owner, gameType, bet, result)
	showSlotOutcome(machine, gameType, result)
	return { bet = bet, payout = result.payout, npcNet = result.payout - bet,
		ownerDelta = ownerDelta, detail = result.detail, gameType = gameType }
end

function Gambling.start(deps)
	Economy = deps.Economy
	Staff = deps.Staff
	Data = deps.Data
	Monetization = deps.Monetization
end

return Gambling
