--!nonstrict
-- LightingSetup.luau — the base for the day/night cycle, applied at runtime.
--
-- DayNight.luau advances Lighting.ClockTime; every client then blends the
-- night / dawn / day / dusk looks itself (CasinoClient/DayNightFX), so this
-- only makes sure the objects exist with sane starting values: Roblox's
-- default sky (it already does a blue day and a starry night with a moon),
-- an Atmosphere, Bloom, a colour grade and soft sun rays.
--
-- Everything here is idempotent (find-or-create by name). LightingStyle
-- (Realistic) and PrioritizeLightingQuality are place settings — a running
-- game can't change them — so they live in the place file.
--
-- Then the look for the boot clock (CasinoCommon/LightingPresets) is applied
-- ONCE, so the first frames match what the clients blend from. Never per
-- frame here: replicated writes would fight every client's own blend.

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Config = require(Common:WaitForChild("Config"))
local LightingPresets = require(Common:WaitForChild("LightingPresets"))

local LightingSetup = {}

local function ensure(className: string, name: string, props: {[string]: any}): Instance
	local inst = Lighting:FindFirstChild(name)
	if not inst or inst.ClassName ~= className then
		if inst then inst:Destroy() end
		inst = Instance.new(className)
		inst.Name = name
	end
	for k, v in props do
		pcall(function() (inst :: any)[k] = v end)
	end
	inst.Parent = Lighting
	return inst
end

function LightingSetup.start()
	Lighting.GeographicLatitude = 23
	Lighting.GlobalShadows = true
	pcall(function() Lighting.ShadowSoftness = 0.2 end)
	Lighting.EnvironmentSpecularScale = 1

	-- Roblox's own sky: blue with clouds by day, stars and a moon at night
	local sky512 = "rbxasset://textures/sky/sky512_"
	ensure("Sky", "CasinoSky", {
		SkyboxUp = sky512 .. "up.tex", SkyboxDn = sky512 .. "dn.tex", SkyboxFt = sky512 .. "ft.tex",
		SkyboxBk = sky512 .. "bk.tex", SkyboxLf = sky512 .. "lf.tex", SkyboxRt = sky512 .. "rt.tex",
		SunTextureId = "rbxasset://sky/sun.jpg", MoonTextureId = "rbxasset://sky/moon.jpg",
		SunAngularSize = 18, MoonAngularSize = 9, StarCount = 4000, CelestialBodiesShown = true,
	})
	ensure("Atmosphere", "CasinoAtmosphere", { Density = 0.3, Offset = 0.1 })
	ensure("BloomEffect", "CasinoBloom", { Intensity = 0.6, Size = 24, Threshold = 1.5 })
	ensure("ColorCorrectionEffect", "CasinoGrade", { Contrast = 0.08, Saturation = 0.12 })
	ensure("SunRaysEffect", "SunRays", { Intensity = 0.05, Spread = 0.25, Enabled = true })
	local dof = Lighting:FindFirstChildWhichIsA("DepthOfFieldEffect")
	if dof then dof.Enabled = false end

	-- this runs before DayNight.start() sets ClockTime, so sample the boot clock
	-- (the tower window glow is left to the clients, so the variants keep the
	-- place's night strength for the DayVariant/NightVariant fallback)
	local clock = Config.DayNight.StartClock
	local look = LightingPresets.sample(clock)
	look.TowerEmissive = nil
	LightingPresets.apply(look)

	print(("[CasinoTycoon] LightingSetup: day/night base applied (look at %.1f h)."):format(clock))
end

return LightingSetup
