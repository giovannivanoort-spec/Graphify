--!nonstrict
-- LightingPresets.luau — the five looks of the day (DAY, DUSK, BLUE hour,
-- NIGHT, DAWN) and the clock keys they blend between. One module, three users:
--   * CasinoClient/DayNightFX blends them from Lighting.ClockTime (10 Hz, local)
--   * LightingSetup applies the look at the boot clock ONCE on the server
--   * MapBuilder applies the same look at edit time, so Studio matches play
-- Usage: LightingPresets.apply(LightingPresets.sample(Lighting.ClockTime))
--
-- Self-contained on purpose (services only, no script.Parent requires), so the
-- edit-time tools can require a fresh :Clone() of it.
--
-- TowerEmissive drives the tower window glow: EmissiveStrength on the window
-- MaterialVariants (MaterialService.CM_TowerWarm / CM_TowerCool). It is only
-- written in a running game, when it moves by more than 0.05, inside pcall.
-- If a running game can't change it, the towers fall back to the NightLight
-- variant swap (DayVariant / NightVariant attributes, see DayNightFX) — which
-- is why edit time never writes it: the place keeps the night strength that
-- MapBuilder gives the variants.

local Lighting = game:GetService("Lighting")
local MaterialService = game:GetService("MaterialService")
local RunService = game:GetService("RunService")

local LightingPresets = {}

local rgb = Color3.fromRGB

-- warm desert sun, calm, decorative neon off
LightingPresets.DAY = {
	Brightness = 2.8, ExposureCompensation = -0.1, EnvironmentDiffuseScale = 0.45,
	Ambient = rgb(122, 110, 104), OutdoorAmbient = rgb(150, 138, 128), -- lifts the casino row in its own shade
	ColorShift_Top = rgb(255, 236, 208), ColorShift_Bottom = rgb(120, 100, 90),
	AtmoDensity = 0.24, AtmoOffset = 0.22, AtmoColor = rgb(232, 214, 190), AtmoDecay = rgb(176, 150, 128),
	AtmoGlare = 0.25, AtmoHaze = 0.6, BloomIntensity = 0.35, BloomThreshold = 2.1, BloomSize = 18,
	Contrast = 0.12, Saturation = 0.18, Tint = rgb(255, 249, 240), Rays = 0.04, TowerEmissive = 0.4,
}
LightingPresets.DUSK = {
	Brightness = 2.2, ExposureCompensation = 0.05, EnvironmentDiffuseScale = 0.4,
	Ambient = rgb(112, 78, 84), OutdoorAmbient = rgb(148, 104, 108),
	ColorShift_Top = rgb(255, 168, 108), ColorShift_Bottom = rgb(130, 70, 110),
	AtmoDensity = 0.29, AtmoOffset = 0.2, AtmoColor = rgb(255, 180, 140), AtmoDecay = rgb(160, 84, 118),
	AtmoGlare = 1.2, AtmoHaze = 1.6, BloomIntensity = 0.6, BloomThreshold = 1.5, BloomSize = 24,
	Contrast = 0.12, Saturation = 0.22, Tint = rgb(255, 236, 222), Rays = 0.12, TowerEmissive = 1.5,
}
-- blue hour (18.9): violet sky, the neon just switched on
LightingPresets.BLUE = {
	Brightness = 1.5, ExposureCompensation = 0.25, EnvironmentDiffuseScale = 0.35,
	Ambient = rgb(64, 48, 88), OutdoorAmbient = rgb(104, 80, 136),
	ColorShift_Top = rgb(255, 140, 160), ColorShift_Bottom = rgb(80, 50, 120),
	AtmoDensity = 0.3, AtmoOffset = 0.18, AtmoColor = rgb(140, 90, 170), AtmoDecay = rgb(90, 48, 110),
	AtmoGlare = 0.4, AtmoHaze = 1.1, BloomIntensity = 0.85, BloomThreshold = 1.3, BloomSize = 26,
	Contrast = 0.14, Saturation = 0.2, Tint = rgb(250, 238, 255), Rays = 0.02, TowerEmissive = 3,
}
-- the same city with the lights switched on
LightingPresets.NIGHT = {
	Brightness = 1.2, ExposureCompensation = 0.35, EnvironmentDiffuseScale = 0.25,
	Ambient = rgb(40, 34, 62), OutdoorAmbient = rgb(72, 64, 112),
	ColorShift_Top = rgb(170, 185, 255), ColorShift_Bottom = rgb(50, 32, 80),
	AtmoDensity = 0.27, AtmoOffset = 0.18, AtmoColor = rgb(54, 46, 100), AtmoDecay = rgb(64, 34, 78),
	AtmoGlare = 0, AtmoHaze = 0.5, BloomIntensity = 0.9, BloomThreshold = 1.3, BloomSize = 28,
	Contrast = 0.16, Saturation = 0.12, Tint = rgb(240, 238, 255), Rays = 0, TowerEmissive = 4,
}
LightingPresets.DAWN = {
	Brightness = 1.9, ExposureCompensation = 0.1, EnvironmentDiffuseScale = 0.4,
	Ambient = rgb(98, 82, 100), OutdoorAmbient = rgb(140, 118, 132),
	ColorShift_Top = rgb(255, 200, 170), ColorShift_Bottom = rgb(110, 80, 130),
	AtmoDensity = 0.27, AtmoOffset = 0.2, AtmoColor = rgb(242, 196, 186), AtmoDecay = rgb(130, 96, 140),
	AtmoGlare = 0.5, AtmoHaze = 1.2, BloomIntensity = 0.55, BloomThreshold = 1.6, BloomSize = 22,
	Contrast = 0.1, Saturation = 0.16, Tint = rgb(255, 244, 238), Rays = 0.08, TowerEmissive = 1.2,
}

local DAY, DUSK, BLUE, NIGHT, DAWN =
	LightingPresets.DAY, LightingPresets.DUSK, LightingPresets.BLUE, LightingPresets.NIGHT, LightingPresets.DAWN

-- { clock, look }: smooth-stepped between neighbours
LightingPresets.KEYS = {
	{ 0, NIGHT }, { 5.0, NIGHT }, { 6.0, DAWN }, { 7.5, DAY }, { 16.5, DAY },
	{ 17.8, DUSK }, { 18.9, BLUE }, { 19.8, NIGHT }, { 24, NIGHT },
}

-- window MaterialVariants whose glow follows the look (TowerEmissive)
LightingPresets.EmissiveVariants = { "CM_TowerWarm", "CM_TowerCool" }
local EMISSIVE_STEP = 0.05 -- skip smaller changes: every write re-uploads the material

function LightingPresets.lerp(a, b, t: number)
	if typeof(a) == "Color3" then return a:Lerp(b, t) end
	return a + (b - a) * t
end
local lerp = LightingPresets.lerp

-- the blended look at a clock time (0-24); a new table, safe to keep
function LightingPresets.sample(clock: number)
	local keys = LightingPresets.KEYS
	for i = 1, #keys - 1 do
		local k0, k1 = keys[i], keys[i + 1]
		if clock >= k0[1] and clock <= k1[1] then
			local t = (clock - k0[1]) / math.max(1e-3, k1[1] - k0[1])
			t = t * t * (3 - 2 * t)
			local out = {}
			for key, v in k0[2] do
				local w = k1[2][key]
				out[key] = if w ~= nil then lerp(v, w, t) else v
			end
			return out
		end
	end
	return table.clone(NIGHT)
end

-- the post effect by name (LightingSetup's), else the first of its class
local function find(name: string, className: string)
	local inst = Lighting:FindFirstChild(name)
	if inst and inst:IsA(className) then return inst end
	return Lighting:FindFirstChildWhichIsA(className)
end

local function variant(name: string)
	local mv = MaterialService:FindFirstChild(name)
	if not mv then
		local folder = MaterialService:FindFirstChild("CasinoMaterials")
		mv = folder and folder:FindFirstChild(name)
	end
	return (mv and mv:IsA("MaterialVariant")) and mv or nil
end

-- the window glow (running game only; see the header)
function LightingPresets.setEmissive(strength: number)
	if not RunService:IsRunning() then return end
	for _, name in LightingPresets.EmissiveVariants do
		local mv = variant(name)
		if mv then
			pcall(function()
				if math.abs(mv.EmissiveStrength - strength) > EMISSIVE_STEP then
					mv.EmissiveStrength = strength
				end
			end)
		end
	end
end

-- write a look (from sample, or one of the presets) to Lighting + its effects
function LightingPresets.apply(look)
	Lighting.Brightness = look.Brightness
	Lighting.ExposureCompensation = look.ExposureCompensation
	Lighting.EnvironmentDiffuseScale = look.EnvironmentDiffuseScale
	Lighting.Ambient = look.Ambient
	Lighting.OutdoorAmbient = look.OutdoorAmbient
	Lighting.ColorShift_Top = look.ColorShift_Top
	Lighting.ColorShift_Bottom = look.ColorShift_Bottom
	local atmo = find("CasinoAtmosphere", "Atmosphere")
	if atmo then
		atmo.Density = look.AtmoDensity; atmo.Offset = look.AtmoOffset
		atmo.Color = look.AtmoColor; atmo.Decay = look.AtmoDecay
		atmo.Glare = look.AtmoGlare; atmo.Haze = look.AtmoHaze
	end
	local bloom = find("CasinoBloom", "BloomEffect")
	if bloom then
		bloom.Intensity = look.BloomIntensity; bloom.Threshold = look.BloomThreshold
		if look.BloomSize then bloom.Size = look.BloomSize end
	end
	local grade = find("CasinoGrade", "ColorCorrectionEffect")
	if grade then grade.Contrast = look.Contrast; grade.Saturation = look.Saturation; grade.TintColor = look.Tint end
	local rays = find("SunRays", "SunRaysEffect")
	if rays then rays.Intensity = look.Rays end
	if look.TowerEmissive then LightingPresets.setEmissive(look.TowerEmissive) end
end

return LightingPresets
