--!nonstrict
-- LightingSetup.luau — the Strip's night look, applied at runtime.
--
-- "Fake night" (what good-looking Roblox night scenes do): a custom dusk-violet
-- skybox with painted stars and a warm city glow on the horizon, and the sun
-- dressed up as a big low moon. Unlike true night (ClockTime 0) the sky stays
-- visible and the light stays bright enough to read plots on a phone, which is
-- where most players are.
--
-- Everything here is idempotent (find-or-create by name). LightingStyle
-- (Realistic) and PrioritizeLightingQuality are place settings — a running
-- game can't change them — so they live in the place file.

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local UIAssets = require(ReplicatedStorage:WaitForChild("CasinoCommon"):WaitForChild("UIAssets"))

local LightingSetup = {}

-- the "moon" hangs low in the west, right above the showroom at the end of
-- the Strip, and rakes long blue-white light across the casino fronts
local CLOCK_TIME = 16.9

------------------------------------------------------------------
-- find-or-create a child of Lighting, then apply properties
------------------------------------------------------------------
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
	Lighting.ClockTime = CLOCK_TIME
	Lighting.GeographicLatitude = 23
	-- moonlight: modest brightness, shifted cool; violet ambient keeps shadows
	-- readable instead of black
	Lighting.Brightness = 1.6
	Lighting.Ambient = Color3.fromRGB(48, 42, 76)
	Lighting.OutdoorAmbient = Color3.fromRGB(100, 90, 146)
	Lighting.ColorShift_Top = Color3.fromRGB(150, 170, 255)
	Lighting.ColorShift_Bottom = Color3.fromRGB(60, 35, 100)
	Lighting.EnvironmentDiffuseScale = 0.3
	Lighting.EnvironmentSpecularScale = 1
	Lighting.ExposureCompensation = 0.35
	Lighting.GlobalShadows = true
	pcall(function() Lighting.ShadowSoftness = 0.2 end)

	-- dusk-violet skybox (assets/map/sky_*.png); the sun wears the moon texture
	local S = UIAssets.Sky
	ensure("Sky", "CasinoSky", {
		SkyboxUp = S.Up, SkyboxDn = S.Dn, SkyboxFt = S.Ft, SkyboxBk = S.Bk, SkyboxLf = S.Lf, SkyboxRt = S.Rt,
		SunTextureId = "rbxasset://sky/moon.jpg",
		SunAngularSize = 10,
		MoonAngularSize = 0,
		StarCount = 0, -- stars are painted into the skybox
		CelestialBodiesShown = true,
	})

	-- violet haze: distant towers and mountains melt into the sky; no glare so
	-- the fake "sun" reads as a cold moon instead of blooming warm daylight
	ensure("Atmosphere", "CasinoAtmosphere", {
		Density = 0.32,
		Offset = 0.12,
		Color = Color3.fromRGB(90, 70, 140),
		Decay = Color3.fromRGB(40, 30, 70),
		Glare = 0,
		Haze = 0.9,
	})

	-- only genuinely bright things bloom: neon, lit signs, the moon
	ensure("BloomEffect", "CasinoBloom", {
		Intensity = 0.8,
		Size = 32,
		Threshold = 1.25,
	})

	-- subtle grade: a little contrast, a cool-violet tint
	ensure("ColorCorrectionEffect", "CasinoGrade", {
		Brightness = 0,
		Contrast = 0.1,
		Saturation = 0.08,
		TintColor = Color3.fromRGB(245, 240, 255),
	})

	-- a faint halo around the moon; depth of field stays off during play
	ensure("SunRaysEffect", "SunRays", { Intensity = 0.02, Spread = 0.2, Enabled = true })
	local dof = Lighting:FindFirstChildWhichIsA("DepthOfFieldEffect")
	if dof then dof.Enabled = false end

	-- in Studio, a connected sync plugin (or a stale edit-mode value) can stomp
	-- ClockTime shortly after boot — hold the line for the first 30 seconds
	local guard
	guard = Lighting:GetPropertyChangedSignal("ClockTime"):Connect(function()
		if math.abs(Lighting.ClockTime - CLOCK_TIME) > 0.01 then
			Lighting.ClockTime = CLOCK_TIME
		end
	end)
	task.delay(30, function() guard:Disconnect() end)

	print("[CasinoTycoon] LightingSetup: Strip fake-night lighting applied.")
end

return LightingSetup
