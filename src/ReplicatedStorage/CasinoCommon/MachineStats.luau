--!strict
-- MachineStats.luau — one machine's numbers as its owner sees them: what guests bet,
-- how long a game takes, how often guests win, the house edge, XP and income per game.
-- Pure functions (no services, no yields, no state): the machine popup (ManageUI), the
-- Showroom info cards and any server code read the SAME model the game runs on:
--   bets       Placement: maxBet = floor(def.maxBet x (1 + bets level x 0.25))
--   game time  NPCs.runPatron: one game per think delay U(ThinkDelayMin, ThinkDelayMax)
--              x max(0.2, (1 - speed level x 0.16) x (1 - PerkSpeed)) x max(0.4, 1 - speedBonus)
--   tilt       NPCs + Gambling.npcPlay: a guest's would-be win (payout > bet) is zeroed with
--              probability clamp(ExtraLossChance + tiltBonus + lucky level x 0.03 + PerkTilt, 0, 0.85)
--   XP         Config.machineXP(def) (incl. the perk) x (1 + xpMult)           (Progression.addXP)
--   income     Gambling.earningsMultiplier: passes / ticket boost x (1 + cashMult) x the x3
--              machine boost x IncomeMult (rebirth perk) x the VIP floor (Config.VipFloor, x1.25)
--   stands     NPCs' stand stop: revenuePerVisit x clientele x (1 + concessionBonus)
--
-- API
--   MachineStats.compute(def, levels?, effects?, attrs?) -> Stats?   (nil for stands / unknown types)
--     def      a Config.Catalog entry (a GetCatalog pack works too: its id is looked up)
--     levels   { speed, bets, lucky } (a missing key: attrs SpeedLevel / BetsLevel / LuckyLevel, else 0)
--     effects  the owner's effect totals (snapshot `effects`; Upgrades.effects(profile) on the server):
--              speedBonus, tiltBonus, cashMult, xpMult (+ walletMult, betBonus, vipChance,
--              vipWalletBonus for the average bet)
--     attrs    the machine's attributes (MachineStats.attrsOf(model) or a plain table):
--                IncomeMult / PerkSpeed / PerkTilt  rebirth perks (else def.perks income / speed / edge)
--                VipFloor = true                    on the VIP floor (x Config.VipFloor.IncomeMult)
--                BoostLeft > 0 (or Boost = true)    the x3 machine boost is running
--              and optionally
--                Earnings = { { key, label, mult, icon? } }  owner-wide multipliers (VIP pass, 2X cash)
--                Clientele = n                      the owner's rank clientele -> avgBet
--                Skim = 0.03                        staff skim share of every bet -> ownerTake
--   Stats = { minBet, maxBet, gameSeconds, gamesPerMinute, guestWinChance, houseEdge, maxWinMult,
--             xpPerGame, incomeMult,                                         (the contract fields)
--             gameType, tilt, tiltCapped, rtp, pushChance, maxWinMultAny, ownerTake, avgBet?,
--             levels = { speed, bets, lucky }, income = { { key, label, mult, text, icon } } }
--   MachineStats.nextLevel(def, levels, effects, attrs, kind) -> Stats?   one `kind` level up (nil at max)
--   MachineStats.upgradeLines(kind, now, nxt) -> { { label, now, next? } }  "now -> next" texts
--   MachineStats.stand(def, effects?, ctx?) -> StandStats?
--   MachineStats.attrsOf(instance) -> attrs
--   MachineStats.money / seconds / percent / mult / xp   formatters ("$1.2K", "0.84 s", "29%", "x1.25", "2.6")

local Config = require(script.Parent:WaitForChild("Config"))

local MachineStats = {}

------------------------------------------------------------------
-- per game type, as NPC guests play it (NPCs.choiceFor: roulette = red / black, dice = a
-- target 40..70), from GameLogic.luau:
--   pWin   P(payout > bet)                  (the only results the house tilt zeroes)
--   rtp    E[payout / bet]                  (raw, before the tilt)
--   wpay   E[payout / bet ; payout > bet]   (the part of the RTP the tilt takes away)
--   push   P(payout == bet)                 (wheel x1, blackjack ties)
--   maxMult  the biggest win a guest can hit; maxMultAny = any bet a real player can make
-- Computed EXACTLY offline (scratchpad stats/exact_odds.py: fractions over every outcome;
-- slots 3 independent weighted reels; blackjack by recursion over an infinite deck, both
-- sides drawing to 17, 3:2 naturals, ties push) and checked against a Monte Carlo of the
-- transcribed resolvers + the tilt (stats/mc_check.py, 300k rounds a case: all within noise).
--   Slots      edge 10.6% raw, 26.6% at tilt 0.40;  guests win  9.8% -> 5.9%
--   Roulette   edge  2.7% raw, 41.6% at 0.40;      guests win 48.6% -> 29.2%
--   Dice       edge  1.0% raw, 40.6% at 0.40;      guests win 45.0% -> 27.0%
--   Wheel      edge  8.0% raw, 40.0% at 0.40;      guests win 20.8% -> 12.5%
--   Plinko     edge  2.3% raw, 30.5% at 0.40;      guests win 28.9% -> 17.3%
--   Blackjack  edge  5.8% raw, 39.3% at 0.40;      guests win 40.8% -> 24.5%
-- After a tilt t: guest win chance = pWin (1 - t); house edge = 1 - (rtp - t wpay).
-- (GameLogic floors payouts: only tiny bets lose a little more; ignored here.)
------------------------------------------------------------------
export type Odds = { pWin: number, rtp: number, wpay: number, push: number, maxMult: number, maxMultAny: number }
local ODDS: {[string]: Odds} = {
	Slots     = { pWin = 0.0975880, rtp = 0.8937426, wpay = 0.3995220, push = 0,         maxMult = 40,  maxMultAny = 40 },
	Roulette  = { pWin = 18 / 37,   rtp = 36 / 37,   wpay = 36 / 37,   push = 0,         maxMult = 2,   maxMultAny = 36 },
	Dice      = { pWin = 0.45,      rtp = 0.99,      wpay = 0.99,      push = 0,         maxMult = 3.3, maxMultAny = 9.9 },
	Wheel     = { pWin = 0.208,     rtp = 0.92,      wpay = 0.80,      push = 0.12,      maxMult = 25,  maxMultAny = 25 },
	Plinko    = { pWin = 37 / 128,  rtp = 125 / 128, wpay = 45 / 64,   push = 0,         maxMult = 16,  maxMultAny = 16 },
	Blackjack = { pWin = 0.4077323, rtp = 0.9415323, wpay = 0.8362915, push = 0.1052408, maxMult = 2.5, maxMultAny = 2.5 },
}
MachineStats.Odds = ODDS

local TILT_CAP = 0.85        -- NPCs / Gambling.npcPlay cap the house tilt here
local KINDS = { "speed", "bets", "lucky" }
local LEVEL_ATTR = { speed = "SpeedLevel", bets = "BetsLevel", lucky = "LuckyLevel" }

export type Part = { key: string, label: string, mult: number, text: string, icon: string? }
export type Levels = { speed: number, bets: number, lucky: number }
export type Stats = {
	gameType: string, minBet: number, maxBet: number, gameSeconds: number, gamesPerMinute: number,
	guestWinChance: number, houseEdge: number, maxWinMult: number, xpPerGame: number, incomeMult: number,
	tilt: number, tiltCapped: boolean, rtp: number, pushChance: number, maxWinMultAny: number,
	ownerTake: number, avgBet: number?, levels: Levels, income: {Part},
}
export type StandStats = {
	salePerGuest: number, vipSale: number, stopChance: number, share: number,
	guestsPerMinute: number?, salesPerMinute: number?, incomeMult: number, income: {Part},
}

------------------------------------------------------------------
-- helpers
------------------------------------------------------------------
local function num(v: any, default: number): number
	local n = tonumber(v)
	if n == nil or n ~= n or n == math.huge or n == -math.huge then return default end
	return n
end

local function maxLevel(): number
	return math.max(0, math.floor(num(Config.MachineUpgradeMaxLevel, 5)))
end

local function perLevel(kind: string, default: number): number
	local ups = (Config :: any).MachineUpgrades
	local spec = type(ups) == "table" and ups[kind] or nil
	return num(type(spec) == "table" and spec.perLevel or nil, default)
end

-- a GetCatalog pack (no perks / xpTier) -> the full Config def when the id is known
local function fullDef(def: any): any
	if type(def) ~= "table" then return nil end
	if type(def.id) == "string" and type(Config.getMachineDef) == "function" then
		local full = Config.getMachineDef(def.id)
		if full then return full end
	end
	return def
end

local function levelsOf(levels: any, attrs: any): Levels
	local out = {}
	local top = maxLevel()
	for _, kind in KINDS do
		local v = type(levels) == "table" and levels[kind] or nil
		if v == nil and type(attrs) == "table" then v = attrs[LEVEL_ATTR[kind]] end
		out[kind] = math.clamp(math.floor(num(v, 0)), 0, top)
	end
	return (out :: any) :: Levels
end

-- a perk: the machine attribute wins (Placement.buildMachine sets it from def.perks)
local function perkOf(def: any, attrs: any, attrName: string, perkKey: string, default: number): number
	local v = type(attrs) == "table" and attrs[attrName] or nil
	if v == nil and type(def.perks) == "table" then v = def.perks[perkKey] end
	return num(v, default)
end

local function effect(effects: any, key: string): number
	return num(type(effects) == "table" and effects[key] or nil, 0)
end

-- the average stake: a share U(fracMin, fracMax) of a wallet U(WalletMin, WalletMax) x
-- clientele x (1 + walletMult) (VIPs: x VIPWalletMultiplier x (1 + vipWalletBonus) and the
-- VIP shares), clamped to the machine's limits (NPCs.runPatron). 12 x 12 midpoint grid.
local function averageBet(minBet: number, maxBet: number, effects: any, clientele: number): number
	local cfg = (Config :: any).NPC or {}
	local w0 = num(cfg.WalletMin, 50) * clientele * (1 + effect(effects, "walletMult"))
	local w1 = num(cfg.WalletMax, 600) * clientele * (1 + effect(effects, "walletMult"))
	local bonus = effect(effects, "betBonus")
	local function mean(walletMult: number, f0: number, f1: number): number
		local sum, n = 0, 12
		for i = 1, n do
			local w = (w0 + (w1 - w0) * (i - 0.5) / n) * walletMult
			for j = 1, n do
				local f = f0 + (f1 - f0) * (j - 0.5) / n
				sum += math.clamp(w * f, minBet, maxBet)
			end
		end
		return sum / (n * n)
	end
	local plain = mean(1, num(cfg.BetFractionMin, 0.02) + bonus, num(cfg.BetFractionMax, 0.06) + bonus)
	local vipShare = math.clamp(num(cfg.VIPChance, 0) + effect(effects, "vipChance"), 0, 1)
	if vipShare <= 0 then return plain end
	local vipMult = num(cfg.VIPWalletMultiplier, 5) * (1 + effect(effects, "vipWalletBonus"))
	local vip = mean(vipMult, num(cfg.VIPBetFractionMin, 0.04) + bonus, num(cfg.VIPBetFractionMax, 0.1) + bonus)
	return plain * (1 - vipShare) + vip * vipShare
end

------------------------------------------------------------------
-- formatters (shared by the client UIs and the server's Showroom cards)
------------------------------------------------------------------
local SUFFIXES = { "", "K", "M", "B", "T", "Qa", "Qi" }
-- 3 significant digits from 1,000 up, rounded down (UILib.short's rule): $75, $1.25K, $67.5K
function MachineStats.money(n: number): string
	local a = math.abs(num(n, 0))
	local sign = num(n, 0) < 0 and "-" or ""
	if a < 1000 then return sign .. "$" .. tostring(math.floor(a)) end
	local i, unit = 1, 1
	while a >= unit * 1000 and i < #SUFFIXES do
		unit *= 1000
		i += 1
	end
	local whole = a / unit
	local digits = whole >= 100 and 0 or (whole >= 10 and 1 or 2)
	local v = math.floor(a / (unit / 10 ^ digits)) / 10 ^ digits
	local s = string.format("%." .. digits .. "f", v)
	if digits > 0 then
		s = (s:gsub("0+$", ""))
		s = (s:gsub("%.$", ""))
	end
	return sign .. "$" .. s .. SUFFIXES[i]
end

-- "1.0 s", "0.84 s", "0.20 s", "12 s"
function MachineStats.seconds(s: number): string
	s = math.max(0, num(s, 0))
	if s >= 9.95 then return ("%d s"):format(math.floor(s + 0.5)) end
	if s >= 0.995 then return ("%.1f s"):format(s) end
	return ("%.2f s"):format(s)
end

-- a 0..1 share: "29%" from 10% up, "5.9%" / "5.0%" below (so "5.3% -> 5.0%" lines up)
function MachineStats.percent(p: number): string
	local v = num(p, 0) * 100
	if math.abs(v) >= 9.95 then return ("%d%%"):format(math.floor(v + 0.5)) end
	return ("%.1f%%"):format(v)
end

-- "x1.25", "x3", "x1.5"
function MachineStats.mult(m: number): string
	local s = ("%.2f"):format(num(m, 1))
	s = (s:gsub("0+$", ""))
	s = (s:gsub("%.$", ""))
	return "x" .. s
end

-- XP per game: "1.0", "2.6", "11.6"; whole numbers from 100 up
function MachineStats.xp(x: number): string
	local v = math.max(0, num(x, 0))
	if v >= 99.95 then return tostring(math.floor(v + 0.5)) end
	return ("%.1f"):format(v)
end

------------------------------------------------------------------
-- income parts (Gambling.earningsMultiplier's factors that are not x1)
------------------------------------------------------------------
local function addPart(list: {Part}, key: string, label: string, mult: number, icon: string?, text: string?)
	if mult > 0 and math.abs(mult - 1) > 1e-6 then
		table.insert(list, { key = key, label = label, mult = mult, icon = icon, text = text or MachineStats.mult(mult) })
	end
end

-- owner-wide multipliers handed in by the caller (VIP pass, the Ticket Shop's 2X cash)
local function addEarnings(list: {Part}, attrs: any)
	local extra = type(attrs) == "table" and attrs.Earnings or nil
	if type(extra) ~= "table" then return end
	for _, e in extra do
		if type(e) == "table" then
			addPart(list, tostring(e.key or "earnings"), tostring(e.label or "BONUS"), num(e.mult, 1),
				type(e.icon) == "string" and e.icon or nil)
		end
	end
end

local function cashPart(list: {Part}, effects: any)
	local cash = math.max(0, effect(effects, "cashMult"))
	if cash > 0 then
		addPart(list, "cash", "CASH", 1 + cash, "cash", ("+%d%%"):format(math.floor(cash * 100 + 0.5)))
	end
end

local function product(list: {Part}): number
	local m = 1
	for _, part in list do m *= part.mult end
	return m
end

------------------------------------------------------------------
-- a gambling machine
------------------------------------------------------------------
function MachineStats.compute(def: any, levels: any?, effects: any?, attrs: any?): Stats?
	local d = fullDef(def)
	if not d or d.kind == "concession" then return nil end
	local odds = ODDS[tostring(d.type)]
	if not odds then return nil end
	local fx = type(effects) == "table" and effects or {}
	local at = type(attrs) == "table" and attrs or {}
	local cfg = (Config :: any).NPC or {}
	local lv = levelsOf(levels, at)

	-- bets: Placement.applyUpgradesToMachine
	local minBet = math.max(0, math.floor(num(d.minBet, 0)))
	local maxBet = math.max(minBet, math.floor(num(d.maxBet, 0) * (1 + lv.bets * perLevel("bets", 0.25))))

	-- game time: NPCs.runPatron (one game per think delay)
	local think = (num(cfg.ThinkDelayMin, 0.6) + num(cfg.ThinkDelayMax, 1.4)) / 2
	local perkSpeed = math.clamp(perkOf(d, at, "PerkSpeed", "speed", 0), 0, 0.95)
	local speedScale = math.max(0.2, (1 - lv.speed * perLevel("speed", 0.16)) * (1 - perkSpeed))
	local thinkScale = math.max(0.4, 1 - effect(fx, "speedBonus"))
	local gameSeconds = math.max(0.01, think * speedScale * thinkScale)

	-- the house tilt: NPCs (patron + machine) and Gambling.npcPlay (clamped)
	local rawTilt = num(cfg.ExtraLossChance, 0) + effect(fx, "tiltBonus")
		+ lv.lucky * perLevel("lucky", 0.03) + perkOf(d, at, "PerkTilt", "edge", 0)
	local tilt = math.clamp(rawTilt, 0, TILT_CAP)
	local rtp = odds.rtp - tilt * odds.wpay
	local houseEdge = 1 - rtp

	-- XP per game: Config.machineXP (+ the xp perk) x (1 + xpMult), Progression's floor -0.9
	local baseXP = type(Config.machineXP) == "function" and num(Config.machineXP(d), 1) or 1
	local xpPerGame = baseXP * (1 + math.max(-0.9, effect(fx, "xpMult")))

	-- income: Gambling.earningsMultiplier (passes x cashMult x boost x perk x VIP floor)
	local income: {Part} = {}
	local vipCfg = (Config :: any).VipFloor
	if at.VipFloor == true then
		addPart(income, "vipFloor", "VIP FLOOR", num(type(vipCfg) == "table" and vipCfg.IncomeMult or nil, 1.25), "crown")
	end
	if num(at.BoostLeft, 0) > 0 or at.Boost == true then
		local boostCfg = (Config :: any).MachineBoost
		addPart(income, "boost", "BOOST", num(type(boostCfg) == "table" and boostCfg.Multiplier or nil, 3), "boost")
	end
	addPart(income, "perk", "REBIRTH", perkOf(d, at, "IncomeMult", "income", 1), "rebirth")
	addEarnings(income, at)
	cashPart(income, fx)

	local skim = math.max(0, num(at.Skim, 0))
	local clientele = tonumber(at.Clientele)
	return {
		gameType = tostring(d.type),
		minBet = minBet,
		maxBet = maxBet,
		gameSeconds = gameSeconds,
		gamesPerMinute = 60 / gameSeconds,
		guestWinChance = odds.pWin * (1 - tilt),
		houseEdge = houseEdge,
		maxWinMult = odds.maxMult,
		xpPerGame = xpPerGame,
		incomeMult = product(income),
		tilt = tilt,
		tiltCapped = rawTilt >= TILT_CAP - 1e-9,
		rtp = rtp,
		pushChance = odds.push,
		maxWinMultAny = odds.maxMultAny,
		ownerTake = houseEdge + skim,
		avgBet = clientele and averageBet(minBet, maxBet, fx, math.max(0, clientele)) or nil,
		levels = lv,
		income = income,
	}
end

-- the stats with one more `kind` level (nil when that kind is maxed)
function MachineStats.nextLevel(def: any, levels: any?, effects: any?, attrs: any?, kind: string): Stats?
	local lv = levelsOf(levels, attrs)
	local nxt: any = { speed = lv.speed, bets = lv.bets, lucky = lv.lucky }
	local cur = nxt[kind]
	if cur == nil or cur >= maxLevel() then return nil end
	nxt[kind] = cur + 1
	return MachineStats.compute(def, nxt, effects, attrs)
end

-- what one upgrade kind changes: { { label, now, next? } } (next = nil at the max level)
--   speed  "Game time 1.0 s -> 0.84 s"   bets "Max bet $75 -> $93"
--   lucky  "Guests win 29% -> 28%", "House edge 42% -> 43%"
function MachineStats.upgradeLines(kind: string, now: Stats, nxt: Stats?): {any}
	if kind == "speed" then
		return { { label = "Game time", now = MachineStats.seconds(now.gameSeconds),
			next = nxt and MachineStats.seconds(nxt.gameSeconds) or nil } }
	elseif kind == "bets" then
		return { { label = "Max bet", now = MachineStats.money(now.maxBet), next = nxt and MachineStats.money(nxt.maxBet) or nil } }
	elseif kind == "lucky" then
		return {
			{ label = "Guests win", now = MachineStats.percent(now.guestWinChance),
				next = nxt and MachineStats.percent(nxt.guestWinChance) or nil },
			{ label = "House edge", now = MachineStats.percent(now.houseEdge),
				next = nxt and MachineStats.percent(nxt.houseEdge) or nil },
		}
	end
	return {}
end

------------------------------------------------------------------
-- a stand (concession): NPCs.runPatron's stop on arrival
--   ctx = { clientele, rate (the casino's guests/min, snapshot flow.rate),
--           kinds (distinct stand types placed), totalRevenue (sum of the placed stands'
--           revenuePerVisit), Earnings = { { key, label, mult, icon? } } }
------------------------------------------------------------------
function MachineStats.stand(def: any, effects: any?, ctx: any?): StandStats?
	local d = fullDef(def)
	if not d then return nil end
	local fx = type(effects) == "table" and effects or {}
	local c = type(ctx) == "table" and ctx or {}
	local cfg = (Config :: any).NPC or {}
	local rev = math.max(0, num(d.revenuePerVisit, 0))
	local clientele = math.max(0, num(c.clientele, 1))
	local sale = math.floor(rev * clientele * (1 + effect(fx, "concessionBonus")))
	local kinds = math.max(1, math.floor(num(c.kinds, 1)))
	local stop = math.min(num(cfg.ConcessionVisitMax, 0.9),
		num(cfg.ConcessionVisitBase, 0.35) + num(cfg.ConcessionVisitPerType, 0.15) * kinds)
	local total = math.max(rev, num(c.totalRevenue, rev))
	local share = total > 0 and rev / total or 1
	-- (stand sales get the passes and cashMult, never the machine boost / perk / VIP floor)
	local income: {Part} = {}
	addEarnings(income, c)
	cashPart(income, fx)
	local mult = product(income)
	local rate = tonumber(c.rate)
	local perMin = rate and math.max(0, rate) * stop * share or nil
	return {
		salePerGuest = sale,
		vipSale = math.floor(sale * num(cfg.ConcessionVIPMultiplier, 1)),
		stopChance = stop,
		share = share,
		guestsPerMinute = perMin,
		salesPerMinute = perMin and perMin * sale * mult or nil,
		incomeMult = mult,
		income = income,
	}
end

-- the attributes compute() reads, off a machine model
function MachineStats.attrsOf(inst: Instance?): {[string]: any}
	local out = {}
	if typeof(inst) ~= "Instance" then return out end
	for _, name in { "SpeedLevel", "BetsLevel", "LuckyLevel", "IncomeMult", "PerkSpeed", "PerkTilt",
		"VipFloor", "BoostLeft", "MinBet", "MaxBet", "MachineId" } do
		out[name] = (inst :: Instance):GetAttribute(name)
	end
	return out
end

return MachineStats
