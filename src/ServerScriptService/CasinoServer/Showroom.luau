--!nonstrict
-- Showroom.luau — the physical machine shop.
--
-- Builds a room of pedestals, one per machine in the Catalog, each carrying a
-- live display model (the real machine, cloned from ReplicatedStorage.Machines,
-- or a procedural box), a floating info card (name / type / bet range / max win
-- / price) that renders when you get close, and a "Press E to buy" prompt that
-- adds the machine to your inventory (BuyToInventory checks you can afford it).
--
-- Concessions & staff aren't gambling machines, so they live at a single
-- Services desk that opens the small menu panel instead.
--
-- Everything here is built FROM CODE so it lives in src/ and survives a Rojo
-- sync (the room is not part of the saved .rbxl).

local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Config = require(Common:WaitForChild("Config"))
local GameLogic = require(Common:WaitForChild("GameLogic"))
local MachineVisuals = require(script.Parent:WaitForChild("MachineVisuals"))
local MachineModels = require(script.Parent:WaitForChild("MachineModels"))

local Showroom = {}

local C = {
	Floor   = Color3.fromRGB(28, 30, 40),
	Wall    = Color3.fromRGB(58, 20, 36),    -- deep crimson-ink building

	Pedestal= Color3.fromRGB(43, 10, 18),   -- Showtime ink
	Roof    = Color3.fromRGB(30, 12, 22),
	Accent  = Color3.fromRGB(245, 197, 24),
	Win     = Color3.fromRGB(46, 204, 113),
	Title   = Color3.fromRGB(245, 245, 250),
	Sub     = Color3.fromRGB(170, 175, 190),
	Services= Color3.fromRGB(45, 156, 219),
}

local function commas(n: number): string
	local s = tostring(math.floor(n))
	local k
	repeat s, k = s:gsub("^(-?%d+)(%d%d%d)", "%1,%2") until k == 0
	return s
end

local function maxWinFor(def): number
	local mult = GameLogic.maxMultiplier(def.type) or 1
	return math.floor((def.maxBet or 0) * mult)
end

------------------------------------------------------------------
-- floating info card (renders when the camera is within CardDistance)
------------------------------------------------------------------
local function buildInfoCard(body: BasePart, def, topOffset: number)
	local bb = Instance.new("BillboardGui")
	bb.Name = "InfoCard"
	bb.Size = UDim2.fromOffset(248, 152)
	bb.StudsOffset = Vector3.new(0, topOffset + 2, 0)
	bb.AlwaysOnTop = true
	bb.LightInfluence = 0
	bb.MaxDistance = Config.Showroom.CardDistance
	bb.Parent = body

	-- Showtime card: cream panel, ink outline, crimson title (matches the UI)
	local frame = Instance.new("Frame")
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundColor3 = Color3.fromRGB(255, 244, 220)
	frame.BackgroundTransparency = 0.02
	frame.Parent = bb
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 16); corner.Parent = frame
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(43, 10, 18); stroke.Thickness = 4
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border; stroke.Parent = frame
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 10); pad.PaddingBottom = UDim.new(0, 10)
	pad.PaddingLeft = UDim.new(0, 12); pad.PaddingRight = UDim.new(0, 12); pad.Parent = frame
	local list = Instance.new("UIListLayout")
	list.Padding = UDim.new(0, 3); list.SortOrder = Enum.SortOrder.LayoutOrder; list.Parent = frame

	local function lbl(name, text, size, color, font, order)
		local t = Instance.new("TextLabel")
		t.Name = name
		t.BackgroundTransparency = 1
		t.Size = UDim2.new(1, 0, 0, size + 6)
		t.Font = font; t.TextSize = size; t.TextColor3 = color
		t.Text = text
		t.TextXAlignment = Enum.TextXAlignment.Left
		t.TextTruncate = Enum.TextTruncate.AtEnd
		t.LayoutOrder = order
		t.Parent = frame
		return t
	end

	local ink = Color3.fromRGB(43, 10, 18)
	local brown = Color3.fromRGB(90, 42, 18)
	lbl("Name", string.upper(def.name), 22, Color3.fromRGB(215, 38, 61), Enum.Font.LuckiestGuy, 1)
	lbl("Meta", ("%s • bets $%d–$%d"):format(def.type, def.minBet, def.maxBet), 13, brown, Enum.Font.GothamBold, 2)
	lbl("Win", ("Win up to $%s"):format(commas(maxWinFor(def))), 15, Color3.fromRGB(28, 122, 28), Enum.Font.GothamBlack, 3)
	-- Price starts neutral; ShowroomUI recolors it gold (affordable) or red (not)
	-- as soon as it reads your cash, so it never falsely flashes "affordable".
	local price = lbl("Price", ("$%s   [E] Buy"):format(commas(def.cost)), 17, brown, Enum.Font.FredokaOne, 4)
	local ps = Instance.new("UIStroke")
	ps.Color = ink; ps.Thickness = 1.5; ps.Parent = price
end

------------------------------------------------------------------
-- the display model (cloned machine or procedural fallback)
------------------------------------------------------------------
-- the simple procedural cabinet (used when a def names no template, or the
-- named template turns out to be unusable)
local function buildProceduralBody(def, slotCF: CFrame): (Model, BasePart, number)
	local model = Instance.new("Model")
	model.Name = def.name .. " Display"

	local body = Instance.new("Part")
	body.Name = "Body"; body.Anchored = true
	body.Size = def.size
	body.CFrame = slotCF * CFrame.new(0, def.size.Y / 2, 0)
	body.Color = def.color; body.Material = Enum.Material.SmoothPlastic
	body.Parent = model
	model.PrimaryPart = body

	local screen = Instance.new("Part")
	screen.Name = "Screen"; screen.Anchored = true
	screen.Size = Vector3.new(def.size.X * 0.8, def.size.Y * 0.35, 0.2)
	screen.CFrame = body.CFrame * CFrame.new(0, def.size.Y * 0.15, -def.size.Z / 2 - 0.05)
	-- tinted toward the machine color: pure-white Neon blows out under bloom
	screen.Material = Enum.Material.Neon
	screen.Color = def.color:Lerp(Color3.new(1, 1, 1), 0.55)
	screen.Parent = model
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = body; weld.Part1 = screen; weld.Parent = body

	return model, body, def.size.Y / 2 + 2
end

local function buildDisplay(def, slotCF: CFrame): Model
	local model = MachineVisuals.cloneFor(def)
	local body: BasePart? = nil
	local topOffset = 0

	if model then
		local primary, _ = MachineVisuals.seat(model, slotCF)
		if primary then
			model.Name = def.name .. " Display"
			body = primary
			-- card floats above the model's top, wherever its body part sits
			local bbCF, bbSize = model:GetBoundingBox()
			topOffset = (bbCF.Position.Y + bbSize.Y / 2) - primary.Position.Y + 0.5
			pcall(MachineVisuals.initDisplay, model)
		else
			-- malformed template (no BaseParts) — drop it and use the box instead
			model:Destroy()
			model = nil
		end
	end

	if not model then
		model, body, topOffset = buildProceduralBody(def, slotCF)
	end

	-- a display you can walk through (never blocks players/NPC paths), and
	-- silence any spin-loop Sound baked into a cloned template — a static
	-- showroom display shouldn't make noise.
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.CanCollide = false
		elseif d:IsA("Sound") then
			d.Looped = false
			pcall(function() d:Stop() end)
		end
	end

	buildInfoCard(body, def, topOffset)

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "BuyPrompt"
	prompt.ActionText = ("Buy  $%s"):format(commas(def.cost))
	prompt.ObjectText = def.name
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = Config.Showroom.RevealDistance
	prompt.RequiresLineOfSight = false
	prompt.Parent = body

	model:SetAttribute("ShopMachineId", def.id)
	model:SetAttribute("ShopCost", def.cost)
	CollectionService:AddTag(model, "CasinoShopDisplay")
	return model
end

-- an anchored block placed in room space (roomCF * cf)
local function block(parent: Instance, name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material?)
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

-- `at(x, y, z)` maps room-local coordinates (aisle = +Z) into the world
local function buildPedestal(parent: Instance, def, at, px: number, floorTop: number, rowZ: number)
	local cfg = Config.Showroom
	local h = cfg.PedestalHeight

	-- Showtime pedestal (matches the machines' own plinths): ink block, gold
	-- lip on top, a neon band in the machine's colour
	block(parent, "Pedestal", Vector3.new(6, h, 6), at(px, floorTop + h / 2, rowZ), C.Pedestal)
	local lip = block(parent, "Lip", Vector3.new(6.3, 0.2, 6.3), at(px, floorTop + h - 0.1, rowZ), C.Accent)
	lip.CanCollide = false; lip.Reflectance = 0.12
	local trim = block(parent, "Trim", Vector3.new(6.08, 0.14, 6.08), at(px, floorTop + 0.45, rowZ), def.color,
		Enum.Material.Neon)
	trim.CanCollide = false

	-- night-tuned: bright enough to pool on the floor after dark, range kept
	-- under Showroom.Spacing (14) so adjacent pedestal pools barely kiss
	local glow = Instance.new("PointLight")
	glow.Color = def.color; glow.Brightness = 2.5; glow.Range = 12
	glow.Shadows = false
	glow.Parent = trim

	-- face the display toward the aisle (the player approaches from room +Z)
	local slotCF = at(px, floorTop + h, rowZ) * CFrame.Angles(0, math.rad(180), 0)
	local display = buildDisplay(def, slotCF)
	display.Parent = parent
end

------------------------------------------------------------------
-- Services desk — opens the concessions & staff menu
------------------------------------------------------------------
local function buildServicesDesk(parent: Instance, deskCF: CFrame)
	-- the code-built Showtime desk (counter + menu boards + canopy); its front
	-- faces deskCF's LookVector
	local model = MachineModels.buildProp("ServicesDesk")
	local counter, glowAt
	if model and model.PrimaryPart then
		for _, d in model:GetDescendants() do
			if d:IsA("BasePart") then d.Anchored = true end
		end
		model.Parent = parent
		model:PivotTo(deskCF)
		counter = model.PrimaryPart
		-- light from the floor-level underglow so it pools on the aisle instead
		-- of tinting the gold counter top
		glowAt = model:FindFirstChild("Underglow")
		CollectionService:AddTag(model, "CasinoProp") -- client MachineFX chases its bulbs
	else
		-- fallback: the plain glowing counter
		model = Instance.new("Model")
		model.Name = "ServicesDesk"
		counter = block(model, "Counter", Vector3.new(8, 4, 2.5), deskCF * CFrame.new(0, 2, 0), C.Services,
			Enum.Material.Neon)

		local bb = Instance.new("BillboardGui")
		bb.Size = UDim2.fromOffset(270, 70); bb.StudsOffset = Vector3.new(0, 4, 0)
		bb.AlwaysOnTop = true; bb.MaxDistance = Config.Showroom.CardDistance + 14
		bb.Parent = counter
		local lbl = Instance.new("TextLabel")
		lbl.Size = UDim2.fromScale(1, 1); lbl.BackgroundTransparency = 1
		lbl.TextScaled = true; lbl.Font = Enum.Font.GothamBold
		lbl.TextColor3 = C.Title; lbl.Text = "Concessions & Staff"; lbl.Parent = bb
	end

	-- match the pedestals: the desk casts its blue onto the aisle at night
	local glow = Instance.new("PointLight")
	glow.Color = C.Services; glow.Brightness = 2.2; glow.Range = 12
	glow.Shadows = false
	glow.Parent = glowAt or counter

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "ServicesPrompt"
	prompt.ActionText = "Browse"; prompt.ObjectText = "Services"
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = Config.Showroom.RevealDistance
	prompt.RequiresLineOfSight = false
	prompt.Parent = counter
	CollectionService:AddTag(counter, "ServicesKiosk")

	model.Parent = parent
end

------------------------------------------------------------------
-- assemble the room
------------------------------------------------------------------
-- a marquee board (ShowroomSign / ShowroomFacadeSign prop) at a CFrame
local function placeSign(parent: Instance, cf: CFrame, propName: string?)
	local signModel = MachineModels.buildProp(propName or "ShowroomSign")
	if not signModel then return nil end
	for _, d in signModel:GetDescendants() do
		if d:IsA("BasePart") then d.Anchored = true; d.CanCollide = false end
	end
	signModel.Parent = parent
	signModel:PivotTo(cf)
	CollectionService:AddTag(signModel, "CasinoProp")
	return signModel
end

function Showroom.build()
	local cfg = Config.Showroom
	local center = cfg.Center
	local spacing = cfg.Spacing
	-- the room is laid out in its own frame: the aisle/entrance is room +Z,
	-- the back wall room -Z; Yaw turns the whole building (90 = entrance east)
	local roomCF = CFrame.new(center) * CFrame.Angles(0, math.rad(cfg.Yaw or 0), 0)
	local function at(x, y, z) return roomCF * CFrame.new(x, y, z) end

	local machines = {}
	for _, def in Config.Catalog do
		if not Config.isConcession(def) then table.insert(machines, def) end
	end
	if #machines == 0 then return end

	local deskInRow = cfg.ServicesCFrame == nil       -- otherwise the desk stands elsewhere (plaza)
	local slots = #machines + (deskInRow and 1 or 0)
	local startX = -(slots - 1) * spacing / 2
	local floorTop = 0.5                               -- room-local: the floor is 1 thick around y = 0
	local rowZ = -6                                    -- displays sit toward the back wall
	local floorW = slots * spacing + 14
	local floorD = 36
	local H = 16                                       -- wall height

	-- clear any prior build (so re-runs / hot-reloads don't stack rooms)
	local old = Workspace:FindFirstChild("Showroom")
	if old then old:Destroy() end

	local model = Instance.new("Model")
	model.Name = "Showroom"

	-- shell: marble floor, ink-crimson walls + roof, gold trims, open facade
	block(model, "Floor", Vector3.new(floorW, 1, floorD), at(0, 0, 0), C.Floor, Enum.Material.Marble)
	local wall = block(model, "BackWall", Vector3.new(floorW, H, 1), at(0, H / 2, -floorD / 2 + 0.5), C.Wall)
	for _, sx in { -1, 1 } do
		block(model, "SideWall", Vector3.new(1, H, floorD), at(sx * (floorW / 2 - 0.5), H / 2, 0), C.Wall)
	end
	local roof = block(model, "Roof", Vector3.new(floorW + 2, 1.2, floorD + 2), at(0, H + 0.6, 0), C.Roof)
	local trimTop = block(model, "RoofTrim", Vector3.new(floorW + 2.4, 0.5, floorD + 2.4), at(0, H + 1.45, 0), C.Accent)
	trimTop.Reflectance = 0.12
	-- facade: a header over the wide entrance, four pillars, neon band, bulbs
	local front = floorD / 2
	block(model, "FacadeHeader", Vector3.new(floorW, 6.5, 1.2), at(0, H - 3.25, front - 0.6), C.Wall)
	for _, x in { -floorW / 2 + 1.2, -floorW / 4, floorW / 4, floorW / 2 - 1.2 } do
		local pillar = block(model, "Pillar", Vector3.new(2.4, H - 6.5, 2.4), at(x, (H - 6.5) / 2, front - 1.2), C.Accent)
		pillar.Reflectance = 0.12
	end
	local band = block(model, "FacadeNeon", Vector3.new(floorW, 0.5, 0.3), at(0, H - 6.25, front + 0.15), C.Accent,
		Enum.Material.Neon)
	band.CanCollide = false
	local topBand = block(model, "FacadeNeonTop", Vector3.new(floorW, 0.4, 0.3), at(0, H - 0.2, front + 0.15), C.Accent,
		Enum.Material.Neon)
	topBand.CanCollide = false
	placeSign(model, at(0, H - 6.1, front + 0.25) * CFrame.Angles(0, math.rad(180), 0), "ShowroomFacadeSign")
	-- floodlights on the forecourt wash the facade (it faces away from the moon)
	for _, x in { -floorW / 3, -floorW / 8, floorW / 8, floorW / 3 } do
		local flood = block(model, "Floodlight", Vector3.new(1.2, 0.5, 1.2),
			at(x, 0.55, front + 5) * CFrame.Angles(math.rad(-28), 0, 0), Color3.fromRGB(42, 38, 51), Enum.Material.Metal)
		flood.CanCollide = false
		local spot = Instance.new("SpotLight")
		spot.Face = Enum.NormalId.Top; spot.Angle = 55; spot.Range = 26; spot.Brightness = 3
		spot.Color = Color3.fromRGB(255, 206, 150); spot.Shadows = false
		spot.Parent = flood
	end

	-- gold marquee strip along the top of the back wall, inside
	local marquee = block(model, "Marquee", Vector3.new(floorW - 2, 0.6, 0.4), at(0, H - 0.5, -floorD / 2 + 1.2), C.Accent,
		Enum.Material.Neon)
	marquee.CanCollide = false; marquee.CanQuery = false; marquee.CanTouch = false

	-- ceiling wash so the room reads indoors (few big lights, no shadows)
	for _, x in { -floorW / 3, 0, floorW / 3 } do
		local anchor = block(model, "CeilingLight", Vector3.new(1.6, 0.2, 1.6), at(x, H - 0.1, -2), Color3.fromRGB(255, 236, 200),
			Enum.Material.Neon)
		anchor.CanCollide = false
		local spot = Instance.new("SpotLight")
		spot.Face = Enum.NormalId.Bottom; spot.Angle = 120; spot.Range = 32; spot.Brightness = 1.4
		spot.Color = Color3.fromRGB(255, 220, 180); spot.Shadows = false
		spot.Parent = anchor
	end

	-- sky beam from the roof: the landmark at the end of the Strip
	local beamFrom = Instance.new("Attachment")
	beamFrom.Name = "SkyBeamFrom"; beamFrom.Position = Vector3.new(0, 0.7, 0); beamFrom.Parent = roof
	local beamTo = Instance.new("Attachment")
	beamTo.Name = "SkyBeamTo"; beamTo.Position = Vector3.new(0, 900, 0); beamTo.Parent = roof
	local beam = Instance.new("Beam")
	beam.Name = "SkyBeam"
	beam.Attachment0 = beamFrom; beam.Attachment1 = beamTo
	beam.Width0 = 9; beam.Width1 = 26
	beam.FaceCamera = true; beam.Segments = 1; beam.Texture = ""
	beam.LightEmission = 1; beam.LightInfluence = 0
	beam.Color = ColorSequence.new(Color3.fromRGB(255, 236, 190))
	beam.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.45), NumberSequenceKeypoint.new(0.45, 0.82),
		NumberSequenceKeypoint.new(1, 1) })
	pcall(function() beam.Brightness = 2.2 end)
	beam.Parent = roof
	local lamp = block(model, "BeamLamp", Vector3.new(6, 0.3, 6), at(0, H + 1.85, 0), Color3.fromRGB(255, 240, 210),
		Enum.Material.Neon)
	lamp.Shape = Enum.PartType.Cylinder
	lamp.Size = Vector3.new(0.3, 6, 6)
	lamp.CFrame = at(0, H + 1.85, 0) * CFrame.Angles(0, 0, math.rad(90))

	model.Parent = Workspace  -- parent the room first so seat()/PivotTo math is stable

	-- the marquee board inside on the back wall, facing the aisle
	if not placeSign(model, at(0, 11.6, -floorD / 2 + 1.25) * CFrame.Angles(0, math.rad(180), 0)) then
		local signBB = Instance.new("BillboardGui")
		signBB.Size = UDim2.fromOffset(560, 90); signBB.StudsOffset = Vector3.new(0, 6, 0)
		signBB.AlwaysOnTop = false; signBB.Parent = wall
		local sign = Instance.new("TextLabel")
		sign.Size = UDim2.fromScale(1, 1); sign.BackgroundTransparency = 1
		sign.TextScaled = true; sign.Font = Enum.Font.GothamBold
		sign.TextColor3 = C.Accent; sign.Text = "MACHINE SHOWROOM"; sign.Parent = signBB
	end

	for i, def in ipairs(machines) do
		local px = startX + (i - 1) * spacing
		-- isolate each display so one bad one can't take down the whole room
		local ok, err = pcall(buildPedestal, model, def, at, px, floorTop, rowZ)
		if not ok then
			warn(("[Showroom] display '%s' failed: %s"):format(def.name, tostring(err)))
		end
	end

	local deskCF = cfg.ServicesCFrame
		or (at(startX + #machines * spacing, floorTop, rowZ) * CFrame.Angles(0, math.rad(180), 0))
	pcall(buildServicesDesk, model, deskCF)

	print(("[Showroom] Built with %d machine display(s)."):format(#machines))
end

function Showroom.start()
	local ok, err = pcall(Showroom.build)
	if not ok then warn("[Showroom] build failed: " .. tostring(err)) end
end

return Showroom
