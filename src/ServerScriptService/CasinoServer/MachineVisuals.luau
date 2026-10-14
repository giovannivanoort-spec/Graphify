--!nonstrict
-- MachineVisuals.luau — custom machine models + their dynamic display.
--
-- Some machines (currently the Lucky 7s Slots) use a hand-built model stored in
-- ReplicatedStorage.Machines instead of the procedural box. We support two rigs:
--
--   * REEL rig (the new lever machine): three "Spinny1/2/3" parts each holding a
--     Decal, an "LEDs" part, and a lever carrying Sounds named Sound (spin loop),
--     Slots (reel-stop click) and Winner (win jingle). showOutcome() rolls the
--     reels, stops them one by one with a click, and flashes the LEDs on a win —
--     driven by OUR server result, not the free-model's own script.
--
--   * OUTCOME-SCREEN rig (older Lucky7): three "result 1/2/3" parts with a Decal
--     each = lose / win / jackpot screens. Kept as a fallback.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Config = require(Common:WaitForChild("Config"))
local MachineModels = require(script.Parent:WaitForChild("MachineModels"))

local MachineVisuals = {}

local IMAGES = Config.SlotReelImages or { "rbxassetid://47671241" }
local IDLE_LED = Color3.new(1, 0.752941, 0.0117647)  -- amber, matches the source script

------------------------------------------------------------------
-- rig discovery
------------------------------------------------------------------
local function getReelDecals(model)
	local out = {}
	for i = 1, 3 do
		local reel = model:FindFirstChild("Spinny" .. i)
		out[i] = reel and reel:FindFirstChildWhichIsA("Decal", true) or nil
	end
	if out[1] and out[2] and out[3] then return out end
	return nil
end

local function getOutcomeDecals(model)
	local decals, any = {}, false
	for i = 1, 3 do
		local part = model:FindFirstChild("result " .. i) or model:FindFirstChild("result" .. i)
		decals[i] = part and part:FindFirstChildWhichIsA("Decal") or nil
		if decals[i] then any = true end
	end
	return any and decals or nil
end

local function getSounds(model)
	return {
		spin = model:FindFirstChild("Sound", true),
		stop = model:FindFirstChild("Slots", true),
		win  = model:FindFirstChild("Winner", true),
	}
end

local function getLeds(model)
	local l = model:FindFirstChild("LEDs", true)
	return (l and l:IsA("BasePart")) and l or nil
end

------------------------------------------------------------------
-- image helpers
------------------------------------------------------------------
local function randImg()
	return IMAGES[math.random(1, #IMAGES)]
end

-- Assign a distinct image per distinct result symbol, so equal symbols always
-- show equal images (a real triple looks like a triple) and unequal symbols show
-- different images — works with as few as 3 images for our 5 symbols.
local function finalImages(reels)
	local map, used, out = {}, 0, {}
	for i = 1, 3 do
		local sym = (reels and reels[i]) or ("?" .. i)
		if not map[sym] then
			used += 1
			map[sym] = IMAGES[((used - 1) % #IMAGES) + 1]
		end
		out[i] = map[sym]
	end
	return out
end

local function playSound(snd)
	if snd then pcall(function() snd:Play() end) end
end

------------------------------------------------------------------
-- model build helpers (used by Placement)
------------------------------------------------------------------
local function sanitize(model: Model)
	-- Drop the free model's own prompt + scripts; OUR system drives it instead.
	for _, d in model:GetDescendants() do
		if d:IsA("ProximityPrompt") or d:IsA("LuaSourceContainer") then
			d:Destroy()
		end
	end
end

function MachineVisuals.cloneFor(def): Model?
	if not def or not def.model then return nil end
	-- code-built Showtime models (MachineModels) take precedence over templates
	if MachineModels.has(def.model) then
		return MachineModels.build(def)
	end
	local folder = ReplicatedStorage:FindFirstChild("Machines")
	local template = folder and folder:FindFirstChild(def.model)
	if not template then return nil end
	local ok, clone = pcall(function() return template:Clone() end)
	if ok and clone and clone:IsA("Model") then
		sanitize(clone)
		return clone :: Model
	end
	return nil
end

function MachineVisuals.seat(model: Model, groundCF: CFrame): (BasePart, Vector3)
	-- code-built models carry their pivot at the centre of the footprint on the
	-- ground, so they seat exactly on groundCF (no bounding-box guesswork)
	if model:GetAttribute("GroundPivot") then
		for _, d in model:GetDescendants() do
			if d:IsA("BasePart") then d.Anchored = true end
		end
		model:PivotTo(groundCF)
		local _, size = model:GetBoundingBox()
		return model.PrimaryPart, size
	end
	if not model.PrimaryPart then
		local biggest, biggestVol = nil, -1
		for _, d in model:GetDescendants() do
			if d:IsA("BasePart") then
				local v = d.Size.X * d.Size.Y * d.Size.Z
				if v > biggestVol then biggest, biggestVol = d, v end
			end
		end
		model.PrimaryPart = biggest
	end
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then d.Anchored = true end
	end
	local bbCF, bbSize = model:GetBoundingBox()
	model.WorldPivot = bbCF
	model:PivotTo(groundCF * CFrame.new(0, bbSize.Y / 2, 0))
	return model.PrimaryPart, bbSize
end

-- Idle state on build.
function MachineVisuals.initDisplay(model: Model)
	local reels = getReelDecals(model)
	if reels then
		for i = 1, 3 do reels[i].Texture = IMAGES[((i - 1) % #IMAGES) + 1] end
		local leds = getLeds(model)
		if leds then leds.Color = IDLE_LED end
		return
	end
	local outcome = getOutcomeDecals(model)
	if outcome then
		for i = 1, 3 do if outcome[i] then outcome[i].Transparency = (i == 1) and 0 or 1 end end
	end
end

------------------------------------------------------------------
-- the spin (server-driven, replicates to everyone). Token-guarded so rapid
-- patron spins just supersede each other instead of stacking.
------------------------------------------------------------------
local token: {[Instance]: number} = setmetatable({}, { __mode = "k" }) :: any

local function spinReels(model, decals, reels, won)
	local snd = getSounds(model)
	local leds = getLeds(model)
	local finals = finalImages(reels)

	local t = (token[model] or 0) + 1
	token[model] = t
	local function live() return token[model] == t and model.Parent ~= nil end

	task.spawn(function()
		playSound(snd.spin)
		-- all three reels roll
		for _ = 1, 8 do
			if not live() then return end
			decals[1].Texture = randImg(); decals[2].Texture = randImg(); decals[3].Texture = randImg()
			task.wait(0.07)
		end
		-- stop reels left-to-right with a click each
		decals[1].Texture = finals[1]; playSound(snd.stop)
		for _ = 1, 4 do
			if not live() then return end
			decals[2].Texture = randImg(); decals[3].Texture = randImg()
			task.wait(0.07)
		end
		decals[2].Texture = finals[2]; playSound(snd.stop)
		for _ = 1, 4 do
			if not live() then return end
			decals[3].Texture = randImg()
			task.wait(0.07)
		end
		decals[3].Texture = finals[3]; playSound(snd.stop)
		if snd.spin then pcall(function() snd.spin:Stop() end) end

		if not live() then return end
		if won then
			playSound(snd.win)
			if leds then
				for _ = 1, 6 do
					if not live() then break end
					leds.Color = Color3.new(1, 0.333333, 0); task.wait(0.1)
					if not live() then break end
					leds.Color = Color3.new(1, 0, 0.498039); task.wait(0.1)
					if not live() then break end
					leds.Color = Color3.new(0, 1, 0); task.wait(0.1)
					if not live() then break end
					leds.Color = IDLE_LED; task.wait(0.1)
				end
				if model.Parent then leds.Color = IDLE_LED end
			end
		end
	end)
end

local KIND_INDEX = { lose = 1, win = 2, jackpot = 3 }
local function flashOutcome(model, decals, reels, won)
	local idx = 1
	if won then
		local triple = reels and reels[1] == reels[2] and reels[2] == reels[3]
		idx = triple and KIND_INDEX.jackpot or KIND_INDEX.win
	end
	local t = (token[model] or 0) + 1
	token[model] = t
	task.spawn(function()
		for step = 1, 5 do
			if token[model] ~= t or not model.Parent then return end
			local s = ((step - 1) % 3) + 1
			for i = 1, 3 do if decals[i] then decals[i].Transparency = (i == s) and 0 or 1 end end
			task.wait(0.08)
		end
		if token[model] ~= t or not model.Parent then return end
		for i = 1, 3 do if decals[i] then decals[i].Transparency = (i == idx) and 0 or 1 end end
	end)
end

-- Public: play the result on whatever rig the machine has.
--   reels = result.detail.reels (3 symbol names); won = real net win (triple).
function MachineVisuals.showOutcome(model: Instance, reels, won: boolean)
	if not model or not model.Parent then return end
	local reelDecals = getReelDecals(model)
	if reelDecals then
		spinReels(model, reelDecals, reels, won)
		return
	end
	local outcome = getOutcomeDecals(model)
	if outcome then
		flashOutcome(model, outcome, reels, won)
	end
end

return MachineVisuals
