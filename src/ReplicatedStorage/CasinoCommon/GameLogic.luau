--!strict
-- GameLogic.luau — server-side RNG for each game.
-- Each resolver returns { won, payout, detail }. payout is what the PLAYER
-- receives (0 = lost stake, 2*bet = doubled, etc.).

local GameLogic = {}
local rng = Random.new()

export type Result = { won: boolean, payout: number, detail: any }

------------------------------------------------------------------
-- SLOTS  (balanced to ~10.7% house edge — see notes)
------------------------------------------------------------------
local SLOT_SYMBOLS = {
	{ name = "Cherry", weight = 40 },
	{ name = "Lemon",  weight = 30 },
	{ name = "Bell",   weight = 18 },
	{ name = "Bar",    weight = 9 },
	{ name = "Seven",  weight = 3 },
}
local SLOT_TRIPLE = { Cherry = 3, Lemon = 5, Bell = 10, Bar = 18, Seven = 40 }
local SLOT_TWO_MATCH = 0.85
local SLOT_TOTAL = 0
for _, s in SLOT_SYMBOLS do SLOT_TOTAL += s.weight end

function GameLogic.slotSymbols(): {string}
	local out = {}
	for _, s in SLOT_SYMBOLS do table.insert(out, s.name) end
	return out
end

local function spinReel(): string
	local roll = rng:NextNumber(0, SLOT_TOTAL)
	local acc = 0
	for _, s in SLOT_SYMBOLS do
		acc += s.weight
		if roll <= acc then return s.name end
	end
	return SLOT_SYMBOLS[1].name
end

function GameLogic.slots(bet: number): Result
	local reels = { spinReel(), spinReel(), spinReel() }
	local payout = 0
	if reels[1] == reels[2] and reels[2] == reels[3] then
		payout = math.floor(bet * (SLOT_TRIPLE[reels[1]] or 0))
	elseif reels[1] == reels[2] or reels[2] == reels[3] or reels[1] == reels[3] then
		payout = math.floor(bet * SLOT_TWO_MATCH)
	end
	return { won = payout >= bet, payout = payout, detail = { reels = reels } }
end

------------------------------------------------------------------
-- ROULETTE (European single-zero)
------------------------------------------------------------------
local RED = {
	[1]=true,[3]=true,[5]=true,[7]=true,[9]=true,[12]=true,[14]=true,[16]=true,
	[18]=true,[19]=true,[21]=true,[23]=true,[25]=true,[27]=true,[30]=true,
	[32]=true,[34]=true,[36]=true,
}
function GameLogic.roulette(bet: number, choice: {kind: string, value: any}): Result
	local n = rng:NextInteger(0, 36)
	local color = n == 0 and "green" or (RED[n] and "red" or "black")
	local payout = 0
	if choice.kind == "number" then
		if tonumber(choice.value) == n then payout = bet * 36 end
	elseif choice.kind == "color" then
		if choice.value == color and n ~= 0 then payout = bet * 2 end
	elseif choice.kind == "parity" then
		if n ~= 0 and ((choice.value == "even") == (n % 2 == 0)) then payout = bet * 2 end
	end
	return { won = payout > 0, payout = payout, detail = { number = n, color = color } }
end

------------------------------------------------------------------
-- DICE (roll-over, ~1% edge). target clamped 2..90 so max payout stays ~10x.
------------------------------------------------------------------
function GameLogic.dice(bet: number, choice: {target: number}): Result
	local target = math.clamp(math.floor(choice.target or 50), 2, 90)
	local roll = rng:NextInteger(1, 100)
	local chance = (100 - target) / 100
	local mult = (1 / chance) * 0.99
	local won = roll > target
	return { won = won, payout = won and math.floor(bet * mult) or 0, detail = { roll = roll, target = target } }
end

------------------------------------------------------------------
-- WHEEL OF FORTUNE (92% RTP before the patrons' tilt; same seven segments,
-- the wheel decal is unchanged). The old 30/25/22/12/7/3/1 table paid out
-- 195% and lost the owner money on every spin.
------------------------------------------------------------------
local WHEEL = {
	{ mult = 0, weight = 336 }, { mult = 1, weight = 60 }, { mult = 2, weight = 50 },
	{ mult = 3, weight = 30 }, { mult = 5, weight = 15 }, { mult = 10, weight = 6 },
	{ mult = 25, weight = 3 },
} -- total 500: RTP 92%; at tilt 0.40 the owner keeps ~40% of every bet
local WHEEL_TOTAL = 0
for _, s in WHEEL do WHEEL_TOTAL += s.weight end
function GameLogic.wheel(bet: number): Result
	local roll = rng:NextNumber(0, WHEEL_TOTAL)
	local acc = 0
	local picked = WHEEL[1]
	for _, s in WHEEL do
		acc += s.weight
		if roll <= acc then picked = s break end
	end
	return { won = picked.mult > 0, payout = bet * picked.mult, detail = { multiplier = picked.mult } }
end

------------------------------------------------------------------
-- BLACKJACK (auto-resolved, dealer stands 17, blackjack pays 3:2)
------------------------------------------------------------------
local function draw(): number
	local c = rng:NextInteger(1, 13)
	if c >= 10 then return 10 end
	if c == 1 then return 11 end
	return c
end
local function total(cards: {number}): number
	local t, aces = 0, 0
	for _, c in cards do t += c; if c == 11 then aces += 1 end end
	while t > 21 and aces > 0 do t -= 10; aces -= 1 end
	return t
end
function GameLogic.blackjack(bet: number): Result
	local p, d = { draw(), draw() }, { draw(), draw() }
	while total(p) < 17 do table.insert(p, draw()) end
	local pt = total(p)
	local payout = 0
	if pt <= 21 then
		while total(d) < 17 do table.insert(d, draw()) end
		local dt = total(d)
		if dt > 21 or pt > dt then
			payout = (pt == 21 and #p == 2) and math.floor(bet * 2.5) or bet * 2
		elseif pt == dt then
			payout = bet
		end
	end
	return { won = payout > bet, payout = payout, detail = { player = total(p), dealer = total(d) } }
end

------------------------------------------------------------------
-- PLINKO (8 rows of pins, 9 pockets; 97.7% RTP before the tilt). The ball
-- goes left or right at every row: pocket = 1 + rights, so the pocket odds
-- are C(8, k) / 256. detail.path[row] = true when it went right (the
-- viewer's right, facing the board); MachineFX / PlinkoUI replay it.
-- The tilt only zeroes the 1.5x / 4x / 16x wins (payout > bet): the owner
-- keeps ~30% at tilt 0.40.
------------------------------------------------------------------
local PLINKO_MULTS = { 16, 4, 1.5, 0.5, 0.2, 0.5, 1.5, 4, 16 }
GameLogic.PlinkoMultipliers = PLINKO_MULTS
GameLogic.PlinkoRows = 8

function GameLogic.plinko(bet: number): Result
	local pocket = 1
	local path: {boolean} = {}
	for row = 1, 8 do
		local right = rng:NextInteger(0, 1) == 1
		if right then pocket += 1 end
		path[row] = right
	end
	local mult = PLINKO_MULTS[pocket]
	local payout = math.floor(bet * mult)
	return { won = payout > bet, payout = payout, detail = { pocket = pocket, path = path, multiplier = mult } }
end

------------------------------------------------------------------
-- Max payout multiplier per game — used for the bankroll coverage check.
------------------------------------------------------------------
function GameLogic.maxMultiplier(gameType: string): number
	if gameType == "Slots" then return 40
	elseif gameType == "Roulette" then return 36
	elseif gameType == "Dice" then return 10
	elseif gameType == "Wheel" then return 25
	elseif gameType == "Plinko" then return 16
	elseif gameType == "Blackjack" then return 3 end
	return 36
end

function GameLogic.resolve(gameType: string, bet: number, choice: any): Result
	if gameType == "Slots" then return GameLogic.slots(bet)
	elseif gameType == "Roulette" then return GameLogic.roulette(bet, choice or {kind="color",value="red"})
	elseif gameType == "Dice" then return GameLogic.dice(bet, choice or {target=50})
	elseif gameType == "Wheel" then return GameLogic.wheel(bet)
	elseif gameType == "Plinko" then return GameLogic.plinko(bet)
	elseif gameType == "Blackjack" then return GameLogic.blackjack(bet) end
	return { won = false, payout = 0, detail = { error = "unknown game" } }
end

return GameLogic
