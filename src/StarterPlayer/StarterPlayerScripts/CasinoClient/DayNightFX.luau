--!nonstrict
-- DayNightFX.luau — lights the scene from the server's clock (DayNight.luau
-- only advances Lighting.ClockTime). Blends the looks in CasinoCommon/
-- LightingPresets (night, dawn, day, dusk, blue hour) at 10 Hz, and switches
-- everything tagged "NightLight" between its day and night state while the
-- lamps are on (Config.DayNight.LampsOn .. LampsOff):
--   * Lights and Beams: Enabled = lamps on. Lights the story cutaway is hiding
--     (LightGate, set by BuildingView) are left off.
--   * BaseParts switch whatever their attributes name. A missing half (e.g. a
--     DayColor without a NightColor) falls back to the part's own value:
--       DayMaterial / NightMaterial          Enum.Material name: "SmoothPlastic", "Neon"
--       DayColor / NightColor                Color3
--       DayTransparency / NightTransparency  number
--       DayVariant / NightVariant            MaterialVariant name ("" = none)
--     A part with no Day/Night Material or Variant is a lamp lens: Neon at
--     night, Glass by day (its colour / transparency still switch). A part that
--     names a Variant (the tower shafts) keeps its own material.
-- A small badge (top right) shows the time (a moon once the lamps are on), and
-- the NIGHT RUSH (+50% guests) while it runs.

local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Config = require(Common:WaitForChild("Config"))
local LightingPresets = require(Common:WaitForChild("LightingPresets"))
local UILib = require(script.Parent:WaitForChild("UILib"))
local LightGate = require(script.Parent:WaitForChild("LightGate"))

local DayNightFX = {}

local TAG = "NightLight"

------------------------------------------------------------------
-- lamps
------------------------------------------------------------------
-- part property <- { day attribute, night attribute }; `surface` = it names the
-- part's own material, so the lens default (Neon / Glass) stays off
local SWITCHES = {
	{ prop = "Material", day = "DayMaterial", night = "NightMaterial", material = true, surface = true },
	{ prop = "Color", day = "DayColor", night = "NightColor" },
	{ prop = "Transparency", day = "DayTransparency", night = "NightTransparency" },
	{ prop = "MaterialVariant", day = "DayVariant", night = "NightVariant", surface = true },
}
local SWITCH_ATTRS = {}
for _, s in SWITCHES do
	SWITCH_ATTRS[s.day] = true
	SWITCH_ATTRS[s.night] = true
end

local lampsOn: boolean? = nil -- nil until the first tick

-- "Neon" -> Enum.Material.Neon (nil if it isn't a material)
local materials = {}
local function toMaterial(v)
	if typeof(v) == "EnumItem" then return v end
	if type(v) ~= "string" then return nil end
	local m = materials[v]
	if m == nil then
		local ok, item = pcall(function() return Enum.Material[v] end)
		m = ok and item or false
		materials[v] = m
	end
	return m or nil
end

-- per part: its own values (`base`) and what we last wrote. A value that
-- changed since our write (the server re-themed the part) is the new base.
local looks = setmetatable({}, { __mode = "k" })

local function put(part: BasePart, prop: string, value)
	local l = looks[part]
	if not l then
		l = { base = {}, wrote = {} }
		looks[part] = l
	end
	local cur = part[prop]
	local wrote = l.wrote[prop]
	if l.base[prop] == nil or (wrote ~= nil and cur ~= wrote) then l.base[prop] = cur end
	if value == nil then value = l.base[prop] end
	if cur ~= value then pcall(function() part[prop] = value end) end
	l.wrote[prop] = part[prop] -- read back: Color is stored quantised
end

local function setLamp(inst: Instance, on: boolean)
	if inst:IsA("Light") or inst:IsA("Beam") then
		-- lamps, sign lights, sky beams; a light hidden behind the cutaway stays off
		if not LightGate.isHidden(inst) then inst.Enabled = on end
	elseif inst:IsA("BasePart") then
		local ownSurface = false
		for _, s in SWITCHES do
			local day, night = inst:GetAttribute(s.day), inst:GetAttribute(s.night)
			if day ~= nil or night ~= nil then
				if s.surface then ownSurface = true end
				local v = if on then night else day
				if v ~= nil and s.material then v = toMaterial(v) end
				put(inst, s.prop, v)
			end
		end
		if not ownSurface then
			-- a lamp lens (colour / transparency attributes ride on top): glowing
			-- neon at night, plain glass by day
			put(inst, "Material", on and Enum.Material.Neon or Enum.Material.Glass)
		end
	end
end

local function refreshLamps(on: boolean)
	if on == lampsOn then return end
	lampsOn = on
	LightGate.setLampsOn(on)
	for _, inst in CollectionService:GetTagged(TAG) do setLamp(inst, on) end
end

-- a part whose Day*/Night* attributes change (a re-themed casino) re-applies
local watching = {} -- part -> AttributeChanged connection
local function watch(inst: Instance)
	if watching[inst] or not inst:IsA("BasePart") then return end
	watching[inst] = inst.AttributeChanged:Connect(function(name)
		if not SWITCH_ATTRS[name] then return end
		task.defer(function()
			if lampsOn ~= nil and inst.Parent then setLamp(inst, lampsOn) end
		end)
	end)
end
local function unwatch(inst: Instance)
	local conn = watching[inst]
	if conn then
		conn:Disconnect()
		watching[inst] = nil
	end
end

-- are the street lamps / sign lights on right now? (never nil)
function DayNightFX.lampsOn(): boolean
	return LightGate.lampsOn()
end

------------------------------------------------------------------
-- badge
------------------------------------------------------------------
local function buildBadge()
	local C = UILib.Colors
	local holder = UILib.make("Frame", {
		Name = "DayNightBadge", BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -14, 0, 14), Size = UDim2.fromOffset(250, 44), Parent = UILib.getScreen(),
	})
	UILib.autoScale(holder)
	local pill = UILib.make("Frame", {
		Name = "Pill", BackgroundColor3 = C.Ink, BackgroundTransparency = 0.15, AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0), Size = UDim2.fromOffset(250, 44), Parent = holder,
	})
	UILib.corner(pill, 999)
	local stroke = UILib.stroke(pill, C.Gold, 3, true)
	local label = UILib.make("TextLabel", {
		Name = "Label", BackgroundTransparency = 1, Size = UDim2.new(1, -20, 1, 0), Position = UDim2.fromOffset(10, 0),
		Font = UILib.Fonts.Display, TextScaled = true, TextColor3 = C.GoldTop, Text = "", Parent = pill,
	})
	UILib.make("UITextSizeConstraint", { MaxTextSize = 22, Parent = label })
	UILib.stroke(label, C.Ink, 2)
	return pill, stroke, label
end

local function clockText(clock: number): string
	local h = math.floor(clock)
	local m = math.floor((clock - h) * 60)
	local suffix = h >= 12 and "PM" or "AM"
	local h12 = h % 12
	if h12 == 0 then h12 = 12 end
	return ("%d:%02d %s"):format(h12, m, suffix)
end

function DayNightFX.start()
	for _, inst in CollectionService:GetTagged(TAG) do watch(inst) end
	CollectionService:GetInstanceAddedSignal(TAG):Connect(function(inst)
		watch(inst)
		if lampsOn ~= nil then setLamp(inst, lampsOn) end
	end)
	CollectionService:GetInstanceRemovedSignal(TAG):Connect(unwatch)

	local ok, pill, stroke, label = pcall(buildBadge)
	local cfg = Config.DayNight
	local rushPct = math.floor((cfg.NightCustomerMult - 1) * 100 + 0.5)
	local acc = 1
	local wasRush = nil
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc < 0.1 then return end -- 10 Hz is plenty for slow light changes
		acc = 0
		local clock = Lighting.ClockTime
		LightingPresets.apply(LightingPresets.sample(clock))
		refreshLamps(LightGate.clockSaysOn(clock))
		if ok and label then
			local rush = Lighting:GetAttribute("NightRush") == true
			if rush then
				label.Text = ("🌙 NIGHT RUSH  +%d%% GUESTS"):format(rushPct)
			else
				label.Text = ("%s %s"):format(lampsOn and "🌙" or "☀", clockText(clock))
			end
			if rush ~= wasRush then
				local joined = wasRush == nil -- the first tick: the rush was already on when we joined
				wasRush = rush
				pill.BackgroundColor3 = rush and UILib.Colors.PurpleShadow or UILib.Colors.Ink
				stroke.Color = rush and UILib.Colors.PinkTop or UILib.Colors.Gold
				if rush then
					UILib.toast("NIGHT RUSH!", "info", ("+%d%% more guests until sunrise"):format(rushPct))
					-- the moment it starts: vignette pulse + jingle + sparkles on this badge (UXFX)
					if not joined then UILib.fx("nightRush", pill) end
					TweenService:Create(pill, TweenInfo.new(0.25, Enum.EasingStyle.Back), { Size = UDim2.fromOffset(310, 48) }):Play()
				else
					TweenService:Create(pill, TweenInfo.new(0.25), { Size = UDim2.fromOffset(250, 44) }):Play()
				end
			end
		end
	end)
end

return DayNightFX
