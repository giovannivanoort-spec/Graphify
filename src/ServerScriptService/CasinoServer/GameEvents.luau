--!nonstrict
-- GameEvents.luau — a tiny server-side event bus: systems report what a player
-- did, others (Quests, achievements, events) listen. Listeners run in pcall, so a
-- broken listener never breaks the action that reported.
--   GameEvents.emit(player, name, amount?)      amount defaults to 1
--   GameEvents.on(name, fn(player, amount))     -> disconnect()
--   GameEvents.onAny(fn(player, name, amount))  -> disconnect()
-- Names in use (amount):
--   gameHosted (W of the round)   cashEarned ($ paid to the owner)   xpEarned (XP)
--   machineBought   machinePlaced   machineUpgraded   upgradeBought   staffHired
--   decorBought   decorPlaced   potionUsed   rebirth   dailyClaimed   playtimeClaimed
--   cheaterKicked (by the owner)   cheaterCaught (by security)   wheelSpun   floorBought

local GameEvents = {}

local listeners: {[string]: {any}} = {}
local anyListeners: {any} = {}
local lastWarn: {[string]: number} = {}

local function report(tag: string, err)
	if os.clock() - (lastWarn[tag] or -math.huge) > 30 then
		lastWarn[tag] = os.clock()
		warn(("[GameEvents] %s: %s"):format(tag, tostring(err)))
	end
end

function GameEvents.on(name: string, fn)
	local list = listeners[name]
	if not list then
		list = {}
		listeners[name] = list
	end
	table.insert(list, fn)
	return function()
		local i = table.find(list, fn)
		if i then table.remove(list, i) end
	end
end

function GameEvents.onAny(fn)
	table.insert(anyListeners, fn)
	return function()
		local i = table.find(anyListeners, fn)
		if i then table.remove(anyListeners, i) end
	end
end

function GameEvents.emit(player: Player?, name: string, amount: number?)
	if not player or type(name) ~= "string" then return end
	local a = tonumber(amount) or 1
	if a == 0 then return end
	local list = listeners[name]
	if list then
		for _, fn in list do
			local ok, err = pcall(fn, player, a)
			if not ok then report(name, err) end
		end
	end
	for _, fn in anyListeners do
		local ok, err = pcall(fn, player, name, a)
		if not ok then report("*", err) end
	end
end

return GameEvents
