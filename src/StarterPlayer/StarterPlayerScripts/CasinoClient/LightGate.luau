--!nonstrict
-- LightGate.luau — the one place the lamp switch (DayNightFX) and the story
-- cutaway (BuildingView) agree on who may turn a light on. Both require this;
-- neither requires the other.
--   * BuildingView marks the lights it hides behind the cut: the lamp switch
--     leaves those alone, so dusk never lights a hidden story.
--   * DayNightFX publishes whether the lamps are on: when the cut is undone, a
--     NightLight light comes back as lampsOn(), not as it was when hidden.

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("CasinoCommon"):WaitForChild("Config"))

local LightGate = {}

local hidden = setmetatable({}, { __mode = "k" }) -- light -> true while the cutaway hides it
local lamps: boolean? = nil                         -- the lamp switch's state (nil until its first tick)

-- the lamps-on window, Config.DayNight.LampsOn .. LampsOff (wraps midnight)
function LightGate.clockSaysOn(clock: number): boolean
	local cfg = Config.DayNight
	return clock >= cfg.LampsOn or clock < cfg.LampsOff
end

function LightGate.setLampsOn(on: boolean)
	lamps = on == true
end

-- are the lamps on? never nil: before the switch's first tick, ask the clock
function LightGate.lampsOn(): boolean
	if lamps ~= nil then return lamps end
	return LightGate.clockSaysOn(Lighting.ClockTime)
end

function LightGate.setHidden(inst: Instance, isHidden: boolean)
	hidden[inst] = isHidden and true or nil
end

function LightGate.isHidden(inst: Instance): boolean
	return hidden[inst] == true
end

return LightGate
