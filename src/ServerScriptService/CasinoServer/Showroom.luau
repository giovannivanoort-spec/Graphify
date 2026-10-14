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

local Showroom = {}

local C = {
	Floor   = Color3.fromRGB(28, 30, 40),
	Wall    = Color3.fromRGB(20, 22, 30),
	Pedestal= Color3.fromRGB(36, 38, 50),
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

	local frame = Instance.new("Frame")
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundColor3 = Color3.fromRGB(22, 24, 32)
	frame.BackgroundTransparency = 0.08
	frame.Parent = bb
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 12); corner.Parent = frame
	local stroke = Instance.new("UIStroke")
	stroke.Color = def.color; stroke.Thickness = 2.5; stroke.Parent = frame
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

	lbl("Name", def.name, 20, C.Title, Enum.Font.GothamBold, 1)
	lbl("Meta", ("%s • bets $%d–$%d"):format(def.type, def.minBet, def.maxBet), 13, C.Sub, Enum.Font.Gotham, 2)
	lbl("Win", ("Win up to $%s"):format(commas(maxWinFor(def))), 15, C.Win, Enum.Font.GothamBold, 3)
	-- Price starts neutral; ShowroomUI recolors it gold (affordable) or red (not)
	-- as soon as it reads your cash, so it never falsely flashes "affordable".
	lbl("Price", ("$%s   [E] Buy"):format(commas(def.cost)), 16, C.Sub, Enum.Font.GothamBold, 4)
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
		local primary, size = MachineVisuals.seat(model, slotCF)
		if primary then
			model.Name = def.name .. " Display"
			body = primary
			topOffset = size.Y / 2 + 2
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

local function buildPedestal(parent: Instance, def, px: number, floorTop: number, rowZ: number)
	local cfg = Config.Showroom

	local ped = Instance.new("Part")
	ped.Name = "Pedestal"; ped.Anchored = true
	ped.Size = Vector3.new(6, cfg.PedestalHeight, 6)
	ped.Position = Vector3.new(px, floorTop + cfg.PedestalHeight / 2, rowZ)
	ped.Material = Enum.Material.Marble; ped.Color = C.Pedestal
	ped.Parent = parent

	local trim = Instance.new("Part")
	trim.Name = "Trim"; trim.Anchored = true; trim.CanCollide = false
	trim.Size = Vector3.new(6.4, 0.3, 6.4)
	trim.Position = ped.Position + Vector3.new(0, cfg.PedestalHeight / 2, 0)
	trim.Material = Enum.Material.Neon; trim.Color = def.color
	trim.Parent = parent

	-- night-tuned: bright enough to pool on the marble after dark, range kept
	-- under Showroom.Spacing (14) so adjacent pedestal pools barely kiss
	local glow = Instance.new("PointLight")
	glow.Color = def.color; glow.Brightness = 2.5; glow.Range = 12
	glow.Shadows = false
	glow.Parent = trim

	-- face the display toward the aisle (player approaches from +Z)
	local topY = floorTop + cfg.PedestalHeight
	local slotCF = CFrame.new(px, topY, rowZ) * CFrame.Angles(0, math.rad(180), 0)
	local display = buildDisplay(def, slotCF)
	display.Parent = parent
end

------------------------------------------------------------------
-- Services desk — opens the concessions & staff menu
------------------------------------------------------------------
local function buildServicesDesk(parent: Instance, px: number, floorTop: number, rowZ: number)
	local model = Instance.new("Model")
	model.Name = "ServicesDesk"

	local counter = Instance.new("Part")
	counter.Name = "Counter"; counter.Anchored = true
	counter.Size = Vector3.new(8, 4, 2.5)
	counter.Position = Vector3.new(px, floorTop + 2, rowZ)
	counter.Material = Enum.Material.Neon; counter.Color = C.Services
	counter.Parent = model

	-- match the pedestals: the desk casts its blue onto the aisle at night
	local glow = Instance.new("PointLight")
	glow.Color = C.Services; glow.Brightness = 2.2; glow.Range = 12
	glow.Shadows = false
	glow.Parent = counter

	local bb = Instance.new("BillboardGui")
	bb.Size = UDim2.fromOffset(270, 70); bb.StudsOffset = Vector3.new(0, 4, 0)
	bb.AlwaysOnTop = true; bb.MaxDistance = Config.Showroom.CardDistance + 14
	bb.Parent = counter
	local lbl = Instance.new("TextLabel")
	lbl.Size = UDim2.fromScale(1, 1); lbl.BackgroundTransparency = 1
	lbl.TextScaled = true; lbl.Font = Enum.Font.GothamBold
	lbl.TextColor3 = C.Title; lbl.Text = "Concessions & Staff"; lbl.Parent = bb

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
function Showroom.build()
	local cfg = Config.Showroom
	local center = cfg.Center
	local spacing = cfg.Spacing

	local machines = {}
	for _, def in Config.Catalog do
		if not Config.isConcession(def) then table.insert(machines, def) end
	end
	if #machines == 0 then return end

	local slots = #machines + 1                       -- +1 slot for the services desk
	local startX = center.X - (slots - 1) * spacing / 2
	local floorTop = center.Y + 0.5
	local rowZ = center.Z - 6                          -- displays sit toward the back wall
	local floorW = slots * spacing + 14
	local floorD = 36

	-- clear any prior build (so re-runs / hot-reloads don't stack rooms)
	local old = Workspace:FindFirstChild("Showroom")
	if old then old:Destroy() end

	local model = Instance.new("Model")
	model.Name = "Showroom"

	local floor = Instance.new("Part")
	floor.Name = "Floor"; floor.Anchored = true
	floor.Size = Vector3.new(floorW, 1, floorD)
	floor.Position = Vector3.new(center.X, center.Y, center.Z)
	floor.Material = Enum.Material.Marble; floor.Color = C.Floor
	floor.Parent = model

	local wall = Instance.new("Part")
	wall.Name = "BackWall"; wall.Anchored = true
	wall.Size = Vector3.new(floorW, 16, 1)
	wall.Position = Vector3.new(center.X, center.Y + 8, center.Z - floorD / 2 + 0.5)
	wall.Material = Enum.Material.SmoothPlastic; wall.Color = C.Wall
	wall.Parent = model

	-- gold marquee strip along the top of the back wall — reads "casino" from
	-- across the map at night and backlights the showroom sign
	local marquee = Instance.new("Part")
	marquee.Name = "Marquee"; marquee.Anchored = true
	marquee.CanCollide = false; marquee.CanQuery = false; marquee.CanTouch = false
	marquee.Size = Vector3.new(floorW, 0.6, 0.4)
	marquee.Position = wall.Position + Vector3.new(0, 8.5, 0.5)
	marquee.Material = Enum.Material.Neon; marquee.Color = C.Accent
	marquee.Parent = model

	local signBB = Instance.new("BillboardGui")
	signBB.Size = UDim2.fromOffset(560, 90); signBB.StudsOffset = Vector3.new(0, 6, 0)
	signBB.AlwaysOnTop = false; signBB.Parent = wall
	local sign = Instance.new("TextLabel")
	sign.Size = UDim2.fromScale(1, 1); sign.BackgroundTransparency = 1
	sign.TextScaled = true; sign.Font = Enum.Font.GothamBold
	sign.TextColor3 = C.Accent; sign.Text = "MACHINE SHOWROOM"; sign.Parent = signBB

	model.Parent = Workspace  -- parent the room first so seat()/PivotTo math is stable

	for i, def in ipairs(machines) do
		local px = startX + (i - 1) * spacing
		-- isolate each display so one bad one can't take down the whole room
		local ok, err = pcall(buildPedestal, model, def, px, floorTop, rowZ)
		if not ok then
			warn(("[Showroom] display '%s' failed: %s"):format(def.name, tostring(err)))
		end
	end

	pcall(buildServicesDesk, model, startX + #machines * spacing, floorTop, rowZ)

	print(("[Showroom] Built with %d machine display(s)."):format(#machines))
end

function Showroom.start()
	local ok, err = pcall(Showroom.build)
	if not ok then warn("[Showroom] build failed: " .. tostring(err)) end
end

return Showroom
