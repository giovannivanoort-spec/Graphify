--!nonstrict
-- Events.luau — server-wide CASINO EVENTS (Config.Events; client EventsUI).
--
-- Every ~12-20 min (Config.Events.Interval, start to start) one random event (never
-- the same twice in a row) runs for 2-4 min: VIP RUSH, CHEATER RAID, JACKPOT HOUR,
-- HAPPY HOUR, BUS TOUR. Its `effects` reach every casino through ONE Upgrades
-- provider, "events" (existing keys: vipChance, xpMult, concessionBonus,
-- spawnBonus). CHEATER RAID is read by the Cheaters module:
-- Events.isActive("cheaterRaid"), Events.value("cheaterMult", 1), Events.value("kickMult", 1).
-- No players online = no events (the clock waits until someone is back).
-- Remote CasinoEvent (-> every client):
--   { kind = "incoming", id, name, short, desc, icon, tone, style, startsAt, active = false }
--   { kind = "start", serial, id, name, short, desc, icon, tone, style, startedAt, endsAt,
--     duration, active = true }      (times: server os.time; clients compare them with
--                                       workspace:GetServerTimeNow())
--   { kind = "end", serial, id, name, short, icon, tone, active = false }
--   { kind = "shout", title, text, icon?, tone?, userId? }   (Events.shout: a toast for all)
-- Every player gets a fresh snapshot when an event starts and ends (effects changed).
-- Snapshot `event` = the "start" payload while one runs, else { active = false }.
-- GameEvents: "eventJoined" (1) for everyone online when an event starts, and for a
-- player who joins during one (once per event).
-- API: Events.isActive(id), Events.current() -> { id, name, desc, icon, tone, serial,
-- startedAt, endsAt, effects }?, Events.value(key, default), Events.force(id, seconds?),
-- Events.stop(), Events.shout(title, text, opts?), Events.tick() (the 1 Hz step).
-- Studio test: ServerStorage attribute CasinoTestEvent = "<id>" | "random" starts that
-- event at once (again TestGap seconds after each one ends while it stays set);
-- CasinoTestEventSeconds = n makes forced events last n seconds.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Config = require(Common:WaitForChild("Config"))

local Events = {}

local Deps = {}
local Remotes, pushData, GameEvents
local rng = Random.new()
local current = nil              -- { def, serial, startedAt, endsAt, forced }
local upcoming = nil             -- { def, startsAt, forced }: announced, not started yet
local nextStart: number? = nil   -- os.time() the next event is due (nil = not planned)
local lastId: string? = nil
local serial = 0
local effects = nil              -- the running event's effects: the provider's answer
local joined: {[Player]: number} = {}   -- player -> serial of the last event they joined
local forcedSeen: string? = nil  -- the CasinoTestEvent value already acted on
local started = false

local function cfg()
	return Config.Events or {}
end

local function list()
	return cfg().List or {}
end

-- an event def by id (any case)
local function findDef(id: any)
	if type(id) ~= "string" then return nil end
	local want = string.lower(id)
	for _, def in list() do
		if type(def.id) == "string" and string.lower(def.id) == want then return def end
	end
	return nil
end
Events.def = findDef

-- a whole number of seconds in a { min, max } range (or a plain number)
local function randIn(range, default: number): number
	if type(range) == "number" then return math.floor(range) end
	if type(range) ~= "table" then return default end
	local a = tonumber(range[1])
	local b = tonumber(range[2]) or a
	if not a then return default end
	if b < a then a, b = b, a end
	return math.floor(a + (b - a) * rng:NextNumber() + 0.5)
end

local function eligible(def): boolean
	if type(def) ~= "table" or type(def.id) ~= "string" then return false end
	if (tonumber(def.weight) or 1) <= 0 then return false end
	if type(def.requires) == "string" and not Deps[def.requires] then return false end
	return true
end

-- a weighted random event, never `exclude` (the last one) unless it's the only one
local function pick(exclude: string?)
	local pool, total = {}, 0
	for _, def in list() do
		if eligible(def) and def.id ~= exclude then
			table.insert(pool, def)
			total += tonumber(def.weight) or 1
		end
	end
	if #pool == 0 then
		local only = findDef(exclude)
		return (only and eligible(only)) and only or nil
	end
	local x = rng:NextNumber() * total
	for _, def in pool do
		x -= tonumber(def.weight) or 1
		if x < 0 then return def end
	end
	return pool[#pool]
end
Events.pick = pick -- (tests)

-- only numbers, so the provider can hand out the same table every time
local function effectsOf(def)
	local out = {}
	for k, v in (type(def.effects) == "table" and def.effects or {}) do
		if type(k) == "string" and type(v) == "number" then out[k] = v end
	end
	return next(out) ~= nil and out or nil
end

------------------------------------------------------------------
-- Studio test hook
------------------------------------------------------------------
local function testValue(): string?
	if not RunService:IsStudio() then return nil end
	local v = ServerStorage:GetAttribute("CasinoTestEvent")
	if type(v) ~= "string" then return nil end
	v = (v:gsub("%s", ""))
	if v == "" or string.lower(v) == "off" then return nil end
	return v
end

local function testSeconds(): number?
	if not RunService:IsStudio() then return nil end
	local s = tonumber(ServerStorage:GetAttribute("CasinoTestEventSeconds"))
	return (s and s > 0) and math.floor(s) or nil
end

-- the event a test value asks for ("random": a fresh pick; `requires` ignored on purpose)
local function testDef(v: string)
	if string.lower(v) == "random" then return pick(current and current.def.id or lastId) end
	return findDef(v)
end

------------------------------------------------------------------
-- start / end
------------------------------------------------------------------
local function startPayload(ev)
	local def = ev.def
	return {
		kind = "start", serial = ev.serial, id = def.id, name = def.name, short = def.short or def.name,
		desc = def.desc or "", icon = def.icon, tone = def.tone, style = def.style,
		startedAt = ev.startedAt, endsAt = ev.endsAt, duration = ev.endsAt - ev.startedAt, active = true,
	}
end

local function broadcast(msg)
	if not Remotes then return end
	local ok, err = pcall(function() Remotes.CasinoEvent():FireAllClients(msg) end)
	if not ok then warn("[Events] broadcast: " .. tostring(err)) end
end

local function pushAll()
	if not pushData then return end
	for _, player in Players:GetPlayers() do pcall(pushData, player) end
end

local function joinEvent(player: Player)
	if not current or joined[player] == current.serial then return end
	joined[player] = current.serial
	if GameEvents and GameEvents.emit then pcall(GameEvents.emit, player, "eventJoined", 1) end
end

local endEvent

local function startEvent(def, seconds: number?, forced: boolean?)
	if current then endEvent(true) end
	local c = cfg()
	local now = os.time()
	local dur = math.max(5, math.floor(tonumber(seconds) or randIn(def.duration, 180)))
	serial += 1
	current = { def = def, serial = serial, startedAt = now, endsAt = now + dur, forced = forced == true }
	lastId = def.id
	upcoming = nil
	effects = effectsOf(def)
	-- the next one: Interval after this start, never sooner than MinGap after its end
	if forced then
		nextStart = current.endsAt + math.max(1, tonumber(c.TestGap) or 20)
	else
		nextStart = math.max(now + randIn(c.Interval, 16 * 60), current.endsAt + (tonumber(c.MinGap) or 300))
	end
	broadcast(startPayload(current))
	for _, player in Players:GetPlayers() do joinEvent(player) end
	pushAll()
	print(("[Events] %s started (%d s)"):format(def.id, dur))
end

endEvent = function(replaced: boolean?)
	local ev = current
	if not ev then return end
	current = nil
	effects = nil
	local def = ev.def
	broadcast({ kind = "end", serial = ev.serial, id = def.id, name = def.name, short = def.short or def.name,
		icon = def.icon, tone = def.tone, active = false, replaced = replaced == true })
	if not replaced then pushAll() end -- (a replacing start pushes right after)
end

------------------------------------------------------------------
-- the 1 Hz step
------------------------------------------------------------------
function Events.tick()
	local now = os.time()
	local tv = testValue()
	if tv then
		if tv ~= forcedSeen then
			forcedSeen = tv
			local def = testDef(tv)
			if def then
				startEvent(def, testSeconds(), true)
			else
				warn("[Events] CasinoTestEvent: there is no event called " .. tv)
			end
			return
		end
	elseif forcedSeen then
		-- the test attribute was cleared: back to the normal clock
		forcedSeen = nil
		upcoming = nil
		if not current then nextStart = nil end
	end

	if current and now >= current.endsAt then endEvent(false) end
	if current then return end
	if #Players:GetPlayers() == 0 then
		upcoming = nil
		nextStart = nil -- nobody to see one: the clock restarts when someone joins
		return
	end
	local c = cfg()
	if not nextStart then nextStart = now + randIn(c.FirstDelay, 5 * 60) end
	local warnSec = math.max(0, tonumber(c.WarningSeconds) or 20)
	if not upcoming and now >= (nextStart :: number) - warnSec then
		local def = if tv then testDef(tv) else pick(lastId)
		if not def then
			nextStart = now + 60
			return
		end
		upcoming = { def = def, startsAt = math.max(nextStart :: number, now + warnSec), forced = tv ~= nil }
		broadcast({ kind = "incoming", id = def.id, name = def.name, short = def.short or def.name, desc = def.desc or "",
			icon = def.icon, tone = def.tone, style = def.style, startsAt = upcoming.startsAt, active = false })
	end
	if upcoming and now >= upcoming.startsAt then
		local u = upcoming
		startEvent(u.def, u.forced and testSeconds() or nil, u.forced)
	end
end

------------------------------------------------------------------
-- API
------------------------------------------------------------------
function Events.isActive(id: string): boolean
	return current ~= nil and current.def.id == id and os.time() < current.endsAt
end

function Events.current()
	if not current then return nil end
	local def = current.def
	return { id = def.id, name = def.name, desc = def.desc, icon = def.icon, tone = def.tone,
		serial = current.serial, startedAt = current.startedAt, endsAt = current.endsAt,
		effects = effects and table.clone(effects) or {} }
end

-- a field of the running event's def (e.g. "kickMult"), else `default`
function Events.value(key: string, default: any): any
	if not current or os.time() >= current.endsAt then return default end
	local v = current.def[key]
	if v == nil then return default end
	return v
end

-- start an event now (admin / tests); false if there's no such event
function Events.force(id: string, seconds: number?): boolean
	local def = findDef(id)
	if not def then return false end
	startEvent(def, seconds, false)
	return true
end

function Events.stop()
	endEvent(false)
end

-- a toast for everyone (e.g. a Lucky Wheel MEGA JACKPOT); opts = { icon, tone, userId }
function Events.shout(title: string, text: string?, opts)
	if type(title) ~= "string" or title == "" then return end
	local o = type(opts) == "table" and opts or {}
	broadcast({ kind = "shout", title = title, text = type(text) == "string" and text or "",
		icon = o.icon, tone = o.tone, userId = o.userId, active = false })
end

function Events.snapshot(_player: Player?, _profile)
	if current then return startPayload(current) end
	return { active = false }
end

function Events.join(player: Player)
	joinEvent(player)
end

function Events.leave(player: Player)
	joined[player] = nil
end

function Events.start(deps)
	Deps = type(deps) == "table" and deps or {}
	Remotes = Deps.Remotes or require(Common:WaitForChild("Remotes"))
	pushData = Deps.pushData
	GameEvents = Deps.GameEvents
	if started then return end
	started = true
	local Upgrades = Deps.Upgrades
	if Upgrades and Upgrades.addProvider then
		Upgrades.addProvider("events", function() return effects end)
	end
	task.spawn(function()
		while true do
			task.wait(1)
			local ok, err = pcall(Events.tick)
			if not ok then warn("[Events] tick failed: " .. tostring(err)) end
		end
	end)
	if RunService:IsStudio() then -- the test attribute takes effect at once
		pcall(function()
			ServerStorage:GetAttributeChangedSignal("CasinoTestEvent"):Connect(function()
				local ok, err = pcall(Events.tick)
				if not ok then warn("[Events] tick failed: " .. tostring(err)) end
			end)
		end)
	end
end

return Events
