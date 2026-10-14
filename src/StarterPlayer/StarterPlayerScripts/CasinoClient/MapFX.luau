--!nonstrict
-- MapFX.luau — client-side life for the Strip map (all local, never replicated):
--   * searchlights sweep the sky       (tag "MapSearchlight": Emitter.BeamTo)
--   * the LED sphere's bands cycle     (tag "MapSphere": Bands folder, Wave)
--   * the observation wheel turns      (tag "MapWheel": Rotor folder)
--   * the fountain jets dance          (tag "MapFountainJet": Jet, Order 0..1)
--   * sky fallback: if the custom skybox images can't be fetched (e.g. still
--     in moderation) the sky shows a classic star field instead of daylight
-- MapBuilder streams these models atomically, so their parts arrive together.

local CollectionService = game:GetService("CollectionService")
local ContentProvider = game:GetService("ContentProvider")
local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")

local MapFX = {}

local searchlights = {}
local spheres = {}
local wheels = {}
local jets = {}

local SPHERE_COLORS = {
	Color3.fromHex("#9B6BFF"), Color3.fromHex("#4FC3FF"), Color3.fromHex("#FF5FC8"),
	Color3.fromHex("#FFC24A"), Color3.fromHex("#4BE38A"), Color3.fromHex("#FF6A5A"),
}

local FALLBACK_SKY = "rbxassetid://45944972" -- classic star field, always available
local SKY_FACES = { "Up", "Dn", "Ft", "Bk", "Lf", "Rt" }

local function watch(tag: string, add, remove)
	for _, inst in CollectionService:GetTagged(tag) do task.spawn(add, inst) end
	CollectionService:GetInstanceAddedSignal(tag):Connect(function(inst) task.spawn(add, inst) end)
	CollectionService:GetInstanceRemovedSignal(tag):Connect(remove)
end

local function smooth(t: number): number
	return t * t * (3 - 2 * t)
end

------------------------------------------------------------------
-- registration
------------------------------------------------------------------
local function addSearchlight(m)
	local emitter = m:WaitForChild("Emitter", 15)
	local to = emitter and emitter:WaitForChild("BeamTo", 15)
	if to then
		searchlights[m] = { to = to, phase = math.random() * math.pi * 2, speed = 0.18 + math.random() * 0.14 }
	end
end

local function addSphere(m)
	local folder = m:WaitForChild("Bands", 15)
	if not folder then return end
	local bands = {}
	for _, b in folder:GetChildren() do
		if b:IsA("BasePart") then table.insert(bands, { part = b, wave = b:GetAttribute("Wave") or 0 }) end
	end
	spheres[m] = { bands = bands, offset = math.random() * #SPHERE_COLORS }
end

local function addWheel(m)
	local rotor = m:WaitForChild("Rotor", 15)
	if not rotor then return end
	local parts, bases = {}, {}
	for _, p in rotor:GetChildren() do
		if p:IsA("BasePart") then
			table.insert(parts, p)
			table.insert(bases, p.CFrame)
		end
	end
	local pivot = m:GetPivot()
	wheels[m] = {
		parts = parts, bases = bases,
		hub = pivot:PointToWorldSpace(Vector3.new(0, m:GetAttribute("HubHeight") or 62, 0)),
		axis = pivot.LookVector,
	}
end

local function addJet(m)
	local jet = m:WaitForChild("Jet", 15)
	if not jet then return end
	local h = jet.Size.X -- cylinder axis = local X, pointing up
	jets[m] = {
		part = jet,
		tip = jet:FindFirstChild("Tip"),
		bottom = jet.CFrame * CFrame.new(-h / 2, 0, 0),
		base = jet:GetAttribute("BaseHeight") or h,
		order = m:GetAttribute("Order") or 0.5,
		current = h,
	}
end

local function drop(map) return function(m) map[m] = nil end end

------------------------------------------------------------------
-- per-frame update
------------------------------------------------------------------
local function jetTarget(j, now: number): number
	local mode = math.floor(now / 12) % 4
	local f = j.order
	local wave
	if mode == 0 then
		wave = 0.5 + 0.5 * math.sin(now * 2.2 - f * 9)               -- travelling wave
	elseif mode == 1 then
		wave = ((math.floor(now * 1.4) + math.floor(f * 12 + 0.5)) % 2 == 0) and 1 or 0.2 -- alternating pulses
	elseif mode == 2 then
		wave = 0.55 + 0.45 * math.sin(now * 3.1)                     -- everyone together
	else
		wave = 0.5 + 0.5 * math.sin(now * 2.6 - math.abs(f - 0.5) * 14) -- centre-out ripple
	end
	return j.base * (0.25 + 0.95 * wave)
end

local accum = 0
local function step(dt: number)
	local now = os.clock()

	for m, j in jets do
		if not j.part.Parent then
			jets[m] = nil
		else
			j.current += (jetTarget(j, now) - j.current) * math.min(1, dt * 6)
			local h = math.max(0.4, j.current)
			j.part.Size = Vector3.new(h, j.part.Size.Y, j.part.Size.Z)
			j.part.CFrame = j.bottom * CFrame.new(h / 2, 0, 0)
			if j.tip then j.tip.CFrame = CFrame.new(h / 2, 0, 0) * CFrame.Angles(0, 0, -math.pi / 2) end
		end
	end

	-- the rest moves slowly: 30 Hz is plenty
	accum += dt
	if accum < 1 / 30 then return end
	accum = 0

	for m, s in searchlights do
		if not s.to.Parent then
			searchlights[m] = nil
		else
			local t = now * s.speed + s.phase
			local tilt = 0.32 + 0.14 * math.sin(t * 0.63)
			s.to.Position = Vector3.new(math.cos(t) * tilt, 1, math.sin(t) * tilt).Unit * 700
		end
	end

	for m, s in spheres do
		if not m.Parent then
			spheres[m] = nil
		else
			for _, b in s.bands do
				local t = now / 4 + s.offset + b.wave * 1.5
				local i = math.floor(t) % #SPHERE_COLORS + 1
				local k = i % #SPHERE_COLORS + 1
				b.part.Color = SPHERE_COLORS[i]:Lerp(SPHERE_COLORS[k], smooth(t % 1))
			end
		end
	end

	for m, w in wheels do
		if not m.Parent then
			wheels[m] = nil
		else
			local rot = CFrame.new(w.hub) * CFrame.fromAxisAngle(w.axis, now * 0.035) * CFrame.new(-w.hub)
			for i, p in w.parts do
				if p.Parent then p.CFrame = rot * w.bases[i] end
			end
		end
	end
end

-- swap to the star field locally when the custom sky can't be fetched
local checking = false
local function checkSky(sky: Sky)
	if checking or sky.SkyboxUp == FALLBACK_SKY or not sky.SkyboxUp:find("rbxassetid") then return end
	checking = true
	local ids = {}
	for _, f in SKY_FACES do table.insert(ids, sky["Skybox" .. f]) end
	local usable = true
	pcall(function()
		ContentProvider:PreloadAsync(ids, function(_, status)
			if status ~= Enum.AssetFetchStatus.Success then usable = false end
		end)
	end)
	if not usable then
		for _, f in SKY_FACES do sky["Skybox" .. f] = FALLBACK_SKY end
	end
	checking = false
end

local function watchSky()
	local sky = Lighting:FindFirstChildOfClass("Sky")
	while not sky do
		Lighting.ChildAdded:Wait()
		sky = Lighting:FindFirstChildOfClass("Sky")
	end
	sky:GetPropertyChangedSignal("SkyboxUp"):Connect(function() task.spawn(checkSky, sky) end)
	checkSky(sky)
end

function MapFX.start()
	task.spawn(watchSky)
	watch("MapSearchlight", addSearchlight, drop(searchlights))
	watch("MapSphere", addSphere, drop(spheres))
	watch("MapWheel", addWheel, drop(wheels))
	watch("MapFountainJet", addJet, drop(jets))
	RunService.RenderStepped:Connect(step)
end

return MapFX
