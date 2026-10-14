--!nonstrict
-- LightingSetup.luau — the "casino strip at night" look, applied at runtime.
--
-- Everything here is idempotent (find-or-create by name), so it composes with
-- whatever Rojo synced or a Studio edit left behind, and it re-applies cleanly
-- on every server boot even if the place file has drifted. Lighting.Technology
-- is NOT scriptable at runtime — that stays in default.project.json (Future).

local Lighting = game:GetService("Lighting")

local LightingSetup = {}

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
	-- base scene: deep dusk — sun just under the horizon for a warm glow on
	-- one side, sky dark enough for neon, ambient lifted so plots stay readable
	Lighting.ClockTime = 18.35
	Lighting.GeographicLatitude = 21
	Lighting.Brightness = 2.2
	Lighting.Ambient = Color3.fromRGB(52, 48, 70)
	Lighting.OutdoorAmbient = Color3.fromRGB(105, 98, 142)
	Lighting.ColorShift_Top = Color3.fromRGB(255, 205, 160)
	Lighting.ColorShift_Bottom = Color3.fromRGB(120, 110, 190)
	Lighting.EnvironmentDiffuseScale = 0.35
	Lighting.EnvironmentSpecularScale = 0.75
	Lighting.ExposureCompensation = 0.2
	Lighting.GlobalShadows = true
	pcall(function() Lighting.ShadowSoftness = 0.25 end)

	-- starry sky with a big low moon
	ensure("Sky", "CasinoSky", {
		StarCount = 4500,
		MoonAngularSize = 14,
		SunAngularSize = 18,
		CelestialBodiesShown = true,
	})

	-- thin haze: distant neon smears into a glow instead of cutting off hard,
	-- and the below-horizon sun blooms into a warm glare on the skyline
	ensure("Atmosphere", "CasinoAtmosphere", {
		Density = 0.3,
		Offset = 0.25,
		Color = Color3.fromRGB(120, 110, 165),
		Decay = Color3.fromRGB(72, 62, 110),
		Glare = 0.4,
		Haze = 1.9,
	})

	-- bloom tuned so only genuinely bright things (Neon parts, lights, the
	-- moon) glow — the threshold keeps white UI-ish surfaces from smearing
	ensure("BloomEffect", "CasinoBloom", {
		Intensity = 0.95,
		Size = 32,
		Threshold = 1.1,
	})

	-- grade: a touch of contrast + saturation, slightly warm — "vegas postcard"
	ensure("ColorCorrectionEffect", "CasinoGrade", {
		Brightness = 0.015,
		Contrast = 0.08,
		Saturation = 0.12,
		TintColor = Color3.fromRGB(255, 248, 240),
	})

	-- in Studio, a connected sync plugin (or a stale edit-mode value) can stomp
	-- ClockTime shortly after boot — hold the line for the first 30 seconds
	local target = 18.35
	local guard
	guard = Lighting:GetPropertyChangedSignal("ClockTime"):Connect(function()
		if math.abs(Lighting.ClockTime - target) > 0.01 then
			Lighting.ClockTime = target
		end
	end)
	task.delay(30, function() guard:Disconnect() end)

	print("[CasinoTycoon] LightingSetup: night-strip lighting applied.")
end

return LightingSetup
