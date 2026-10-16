--!nonstrict
-- DayNight.luau — the server's clock. Advances Lighting.ClockTime through a
-- full day every Config.DayNight.CycleMinutes; each client lights the scene
-- from that clock (CasinoClient/DayNightFX). During the night rush more
-- patrons can come: NPCs asks customerMultiplier(). Lighting's "NightRush"
-- attribute mirrors the rush for anything that wants to show it.

local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("CasinoCommon"):WaitForChild("Config"))

local DayNight = {}
local cfg = Config.DayNight

function DayNight.isNight(): boolean
	local t = Lighting.ClockTime
	return t >= cfg.NightStart or t < cfg.NightEnd
end

-- patron multiplier right now; `extra` adds an owner's Night Life upgrade
function DayNight.customerMultiplier(extra: number?): number
	if not DayNight.isNight() then return 1 end
	return cfg.NightCustomerMult + (extra or 0)
end

function DayNight.start()
	Lighting.ClockTime = cfg.StartClock
	Lighting:SetAttribute("NightRush", DayNight.isNight())
	local hoursPerSecond = 24 / (cfg.CycleMinutes * 60)
	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc < 0.25 then return end -- 4 Hz: the sun's steps are invisible at this speed
		Lighting.ClockTime = (Lighting.ClockTime + acc * hoursPerSecond) % 24
		acc = 0
		local night = DayNight.isNight()
		if Lighting:GetAttribute("NightRush") ~= night then
			Lighting:SetAttribute("NightRush", night)
		end
	end)
	print(("[CasinoTycoon] DayNight: %d-minute days, night rush x%.1f."):format(cfg.CycleMinutes, cfg.NightCustomerMult))
end

return DayNight
