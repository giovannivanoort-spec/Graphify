--!nonstrict
-- Showroom.luau — the physical machine shop, a "Vegas flagship" closing the
-- west end of the Strip.
--
-- Builds a bright ivory dealership hall with a podium per machine in the
-- Catalog, each carrying a live display model (the real machine, cloned from
-- ReplicatedStorage.Machines, or a procedural box), a floating info card (name /
-- type / bet range / max win / price) that renders when you get close, and a
-- "Press E to buy" prompt that adds the machine to your inventory
-- (BuyToInventory checks you can afford it).
--
-- The building: cream stone walls, a plum ceiling with a key spot over every
-- machine plus soft light troughs, a wine wainscot, and a back wall of plum
-- niches glowing in the back-row machines' colours. Out front: a crimson
-- lacquer portal (open doorway, bulb canopy) between two glass showcase wings,
-- crowned by a giant prize wheel (it spins every Config.Showroom.WheelSpinEvery
-- seconds) and a bulb-ringed MACHINE SHOWROOM sign. Street-front neon and the
-- facade washes only run after dark (NightLight); signs and bulbs always do.
--
-- Concessions & staff aren't gambling machines, so they live at a single
-- Services desk that opens the small menu panel instead.
--
-- Everything here is built FROM CODE so it lives in src/ and survives a Rojo
-- sync (the room is not part of the saved .rbxl).
--
-- Room-local coordinates, `at(x, y, z)`: y = 0 is Config.Showroom.Center.Y and
-- the floor top is y 0.5; the street is room +Z (the front line is z = 18, the
-- forecourt paving sits at y 0.3 out to the road at z 26). Everything else is
-- derived from the row plan (floorW / floorD / back / midZ / front / H / rows,
-- see planRows): the displays stand in tiers, starters by the entrance and the
-- top tier on the raised back row; more catalog machines add rows, the back
-- wall moves back, the front never moves.
--
-- Rank locks: every display carries a hidden LockBadge ("RANK X") and
-- NewBadge; ShowroomUI switches them on per player from their Casino Rank.
--
-- THE REBIRTH WING: the catalog machines that need rebirths (def.rebirth)
-- fill the back rows, behind the rank machines, by rebirth level (the most
-- expensive one, the hero, in the middle of the back row). The wing has its
-- own look: royal-purple podiums with pearl decks and a "REBIRTH N" plaque,
-- purple runners and a rebirth medallion in the floor, lilac light troughs,
-- purple neon on its pilasters, and a double-sided REBIRTH WING marquee
-- hanging over its threshold. Its displays carry a hidden RebirthBadge
-- ("REBIRTH N", purple and gold) and the attribute ShopRebirth.

local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Config = require(Common:WaitForChild("Config"))
local GameLogic = require(Common:WaitForChild("GameLogic"))
local Materials = require(Common:WaitForChild("Materials"))
local WP = require(Common:WaitForChild("WorldPalette"))
local UIAssets = require(Common:WaitForChild("UIAssets"))
local MachineVisuals = require(script.Parent:WaitForChild("MachineVisuals"))
local MachineModels = require(script.Parent:WaitForChild("MachineModels"))

local Showroom = {}

local K = MachineModels.Kit
local P = MachineModels.Palette -- Showtime colours: only signs, bulbs and the prize wheel

local NIGHT_TAG = "NightLight" -- DayNightFX: on after dark only
local FACE_OUT = CFrame.Angles(0, math.pi, 0) -- model-space front (-Z) -> the street (room +Z)
local BLACK = Color3.new(0, 0, 0)

-- UI colours (the services-desk fallback and the wall-sign fallback); the
-- building itself takes every colour from WorldPalette
local C = {
	Accent  = Color3.fromRGB(245, 197, 24),
	Title   = Color3.fromRGB(245, 245, 250),
	Services= Color3.fromRGB(45, 156, 219),
}

-- the room's light: warm, never yellow
local DRUM = WP.Ink                                -- podium bodies
local PANEL = WP.Interior:Lerp(WP.DeepStone, 0.25) -- light-panel faces (soft bloom)
local KEY_LIGHT = WP.Soffit                        -- per-machine key spots
local FILL_LIGHT = WP.Interior                     -- troughs, canopy soffit
local UPLIGHT = WP.WarmNeon                        -- facade washes

-- the Rebirth Wing's own palette (royal purple, pearl, lilac light)
local WING = {
	Drum = Color3.fromHex("#2A1048"),   -- podium bodies
	Deck = Color3.fromHex("#EFE6FF"),   -- pearl podium decks
	Runner = Color3.fromHex("#3A1466"), -- floor runners
	Neon = Color3.fromHex("#B36BFF"),   -- pilaster strips, podium glow
	Light = Color3.fromHex("#E6D6FF"),  -- the light troughs over the wing
	PlateTop = Color3.fromHex("#6A2BC2"), PlateBottom = Color3.fromHex("#2E0F5E"),
}

local function rebirthOf(def): number
	return math.max(0, math.floor(tonumber(def and def.rebirth) or 0))
end

-- the street front's fixed bays (studs, room x / y): the open doorway |x| < 10
-- between crimson portal piers |x| 10..15; the wheel hangs on the portal attic
local PIER_IN, PIER_OUT = 10, 15
local DOOR_TOP = 14 -- the attic soffit (the brass head bar hangs just under it)
local PORTAL_RISE = 10 -- the portal stands this far above the walls (H)
local WHEEL_R = 7.5
local WHEEL_Y = DOOR_TOP + 8.5

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

-- the card's stats line (CasinoCommon/MachineStats: a fresh machine in a fresh casino,
-- incl. a rebirth machine's perks): "Guests win 5.9% • 1.0 XP/game"; nil without the module
local function statsLineFor(def): string?
	local mod = Common:FindFirstChild("MachineStats")
	local ok, MS = pcall(function() return mod and require(mod) end)
	local s = ok and type(MS) == "table" and MS.compute(def) or nil
	if not s then return nil end
	return ("Guests win %s • %s XP/game"):format(MS.percent(s.guestWinChance), MS.xp(s.xpPerGame))
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
	local stats = statsLineFor(def)
	if stats then lbl("Stats", stats, 13, brown, Enum.Font.GothamBold, 4) end
	-- Price starts neutral; ShowroomUI recolors it gold (affordable) or red (not)
	-- as soon as it reads your cash, so it never falsely flashes "affordable".
	local price = lbl("Price", ("$%s   [E] Buy"):format(commas(def.cost)), 17, brown, Enum.Font.FredokaOne, 5)
	local ps = Instance.new("UIStroke")
	ps.Color = ink; ps.Thickness = 1.5; ps.Parent = price
end

------------------------------------------------------------------
-- badges over a display, switched on per player by the client (ShowroomUI):
-- a lock + "RANK X" while the display is above your Casino Rank, a NEW! burst
-- once your rank-up unlocks it. Sized in studs, so they read across the hall.
------------------------------------------------------------------
local function rankName(r: number?): string?
	local prog = (Config :: any).Progression
	local def = prog and prog.Ranks and r and prog.Ranks[r]
	return def and def.name or nil
end

local function buildBadges(body: BasePart, def, topOffset: number)
	local function billboard(name: string, w: number, h: number)
		local bb = Instance.new("BillboardGui")
		bb.Name = name
		bb.Size = UDim2.fromScale(w, h)
		bb.StudsOffset = Vector3.new(0, topOffset + 0.35 + h / 2, 0)
		bb.AlwaysOnTop = false
		bb.LightInfluence = 0
		bb.MaxDistance = 150
		bb.Enabled = false
		bb.Parent = body
		return bb
	end
	local ink, gold, crimson = P.Ink, P.Gold, P.Crimson

	-- LOCK: an ink pill, gold rim, the lock icon, "RANK X" + the rank's name
	local lock = billboard("LockBadge", 5.2, 1.7)
	local pill = K.new("Frame", { Size = UDim2.fromScale(1, 0.78), BackgroundColor3 = ink, BackgroundTransparency = 0.08 }, lock)
	K.new("UICorner", { CornerRadius = UDim.new(0.5, 0) }, pill)
	K.new("UIStroke", { Color = gold, Thickness = 3, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, pill)
	K.guiImage(pill, "lock", { size = UDim2.fromScale(0.3, 1.25), position = UDim2.fromScale(0.13, 0.46) })
	K.guiText(pill, ("RANK %d"):format(def.unlockRank or 1), { size = UDim2.fromScale(0.66, 0.74),
		position = UDim2.fromScale(0.29, 0.13), gradient = { P.GoldTop, P.Gold }, strokeThickness = 3 }).Name = "Rank"
	local nameLabel = K.guiText(lock, rankName(def.unlockRank) or "Rank up to unlock", { size = UDim2.fromScale(0.9, 0.24),
		position = UDim2.fromScale(0.05, 0.77), color = P.Cream, font = Enum.Font.GothamBlack, strokeThickness = 2 })
	nameLabel.Name = "RankName"

	-- NEW: a gold pill with crimson type and a star
	local newB = billboard("NewBadge", 3.6, 1.3)
	local np = K.new("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = P.White }, newB)
	K.new("UICorner", { CornerRadius = UDim.new(0.5, 0) }, np)
	K.new("UIGradient", { Rotation = 90, Color = ColorSequence.new(P.GoldTop, P.Gold) }, np)
	K.new("UIStroke", { Color = ink, Thickness = 3, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, np)
	K.guiImage(np, "star", { size = UDim2.fromScale(0.36, 1.3), position = UDim2.fromScale(0.16, 0.45) })
	K.guiText(np, "NEW!", { size = UDim2.fromScale(0.6, 0.7), position = UDim2.fromScale(0.34, 0.15), color = crimson,
		strokeColor = P.White, strokeThickness = 3 })

	-- REBIRTH LOCK (rebirth machines): the lock pill in royal purple with a
	-- gold rim, the rebirth icon, "REBIRTH N" and a hint under it
	local need = rebirthOf(def)
	if need > 0 then
		local rb = billboard("RebirthBadge", 5.8, 1.7)
		local pillR = K.new("Frame", { Size = UDim2.fromScale(1, 0.78), BackgroundColor3 = P.White, BackgroundTransparency = 0.04 }, rb)
		K.new("UICorner", { CornerRadius = UDim.new(0.5, 0) }, pillR)
		K.new("UIGradient", { Rotation = 90, Color = ColorSequence.new(WING.PlateTop, WING.PlateBottom) }, pillR)
		K.new("UIStroke", { Color = gold, Thickness = 3, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, pillR)
		K.guiImage(pillR, UIAssets.icon("rebirth"), { size = UDim2.fromScale(0.3, 1.25), position = UDim2.fromScale(0.13, 0.46) })
		K.guiText(pillR, ("REBIRTH %d"):format(need), { size = UDim2.fromScale(0.68, 0.74),
			position = UDim2.fromScale(0.28, 0.13), gradient = { P.GoldTop, P.Gold }, strokeThickness = 3 }).Name = "Rebirth"
		K.guiText(rb, "Rebirth to unlock", { size = UDim2.fromScale(0.9, 0.24), position = UDim2.fromScale(0.05, 0.77),
			color = P.Cream, font = Enum.Font.GothamBlack, strokeThickness = 2 }).Name = "Hint"
	end
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
	local okBadges, errBadges = pcall(buildBadges, body, def, topOffset)
	if not okBadges then warn("[Showroom] badges for " .. tostring(def.id) .. ": " .. tostring(errBadges)) end

	-- the prompt's text is the base price; ShowroomUI shows each player their
	-- own (the next copy costs more, locked displays say so)
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
	model:SetAttribute("ShopUnlockRank", def.unlockRank or 1)
	model:SetAttribute("ShopRebirth", rebirthOf(def)) -- rebirths needed to buy it (0 = none)
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

------------------------------------------------------------------
-- material + light helpers
------------------------------------------------------------------
local function brass(p: BasePart): BasePart return Materials.paint(p, "Brass", WP.Brass) end
local function granite(p: BasePart): BasePart return Materials.paint(p, "HonedStone", WP.Granite) end
local function stucco(p: BasePart): BasePart return Materials.paint(p, "Stucco", WP.Stone) end
-- 4x2-stud stone blocks: only on faces at least 4 x 4 studs
local function ashlar(p: BasePart, target: Color3?): BasePart return Materials.paint(p, "Ashlar", target or WP.Stone) end
local function fabric(p: BasePart): BasePart
	p.Material = Enum.Material.Fabric
	return p
end

-- street-front neon is decoration: lit after dark only. By day DayNightFX shows
-- a plain strip (`day`, default: the hue sunk 55% toward ink). Built in its day
-- state, since servers boot in the afternoon.
local function nightNeon(p: BasePart, color: Color3, day: Color3?): BasePart
	local dayColor = day or color:Lerp(WP.Ink, 0.55)
	p:SetAttribute("DayMaterial", "SmoothPlastic")
	p:SetAttribute("NightMaterial", "Neon")
	p:SetAttribute("DayColor", dayColor)
	p:SetAttribute("NightColor", color)
	p.Material = Enum.Material.SmoothPlastic
	p.Color = dayColor
	CollectionService:AddTag(p, NIGHT_TAG)
	return p
end

-- a light that only runs after dark (DayNightFX switches Enabled)
local function nightLight(light: Light): Light
	light.Enabled = false
	CollectionService:AddTag(light, NIGHT_TAG)
	return light
end

-- signs and niches are always lit
local function brighten(root: Instance, brightness: number)
	local guis = root:IsA("SurfaceGui") and { root } or root:GetDescendants()
	for _, g in guis do
		if g:IsA("SurfaceGui") then pcall(function() g.Brightness = brightness end) end
	end
end

-- a cylinder lying from a to b (world positions)
local function rod(parent, name, a: Vector3, b: Vector3, d: number, color, opts)
	opts = table.clone(opts or {})
	opts.shape = Enum.PartType.Cylinder
	return K.part(parent, name, Vector3.new((b - a).Magnitude, d, d),
		CFrame.lookAt((a + b) / 2, b) * CFrame.Angles(0, math.rad(90), 0), color, opts)
end

-- a lamp body at `from` aimed at `to` (world positions): a short cylinder whose
-- Right face (the SpotLight's face) points at the target
local function aimed(parent, name, from: Vector3, to: Vector3, size: Vector3, color, opts)
	opts = table.clone(opts or {})
	opts.shape = Enum.PartType.Cylinder
	return K.part(parent, name, size, CFrame.lookAt(from, to) * CFrame.Angles(0, math.rad(90), 0), color, opts)
end

-- a sub-assembly built in model space (origin = its pivot, front = -Z), turned
-- to face the street and placed at a room CFrame
local function place(m: Model, parent: Instance, cf: CFrame): Model
	m.WorldPivot = CFrame.new()
	m.Parent = parent
	m:PivotTo(cf * FACE_OUT)
	return m
end

-- small animated props stream as one piece so client FX find all their parts
local function atomic(m: Model): Model
	pcall(function() m.ModelStreamingMode = Enum.ModelStreamingMode.Atomic end)
	return m
end

local function folder(name: string, parent: Instance): Folder
	local f = Instance.new("Folder")
	f.Name = name
	f.Parent = parent
	return f
end

-- bulbs round a rectangle in a model-space XY plane at depth z, about `step`
-- apart; the corners belong to the long rows (no doubled-up bulbs)
local function bulbRect(bulbs: Instance, cx, cy, w, h, z, step: number, d: number)
	local x0, x1, y0, y1 = cx - w / 2, cx + w / 2, cy - h / 2, cy + h / 2
	local n = math.max(2, math.floor(w / step + 0.5) + 1)
	K.bulbsAlong(bulbs, Vector3.new(x0, y1, z), Vector3.new(x1, y1, z), n, d)
	K.bulbsAlong(bulbs, Vector3.new(x0, y0, z), Vector3.new(x1, y0, z), n, d)
	local segs = math.max(1, math.floor(h / step + 0.5))
	if segs >= 2 then
		local dy = h / segs
		for _, x in { x0, x1 } do
			K.bulbsAlong(bulbs, Vector3.new(x, y0 + dy, z), Vector3.new(x, y1 - dy, z), segs - 1, d)
		end
	end
end

------------------------------------------------------------------
-- display podiums
------------------------------------------------------------------
-- one podium per machine, sized to it: a granite shadow plinth on a thin glow
-- of the machine's colour, a dark drum, a brass band and an ivory deck (top at
-- hP above the floor). Round for compact machines, a stadium (box + round ends)
-- for the long tables. The display is parented to `parent`, the podium parts
-- to `podiums`.
local function podiumWidth(def): number
	return math.clamp(def.size.X + 1.8, 6.4, 12.4)
end

local function buildPedestal(parent: Instance, podiums: Instance, def, L, px: number, rowZ: number, hP: number)
	local at, floorTop = L.at, L.floorTop
	local w = podiumWidth(def)
	local d = math.clamp(def.size.Z + 2, 6.4, 7.6)
	local round = w - d < 1.2
	local len = w - d

	-- one layer, `grow` studs bigger than the footprint (negative = inset), from
	-- y0 to y1 above the floor; `finish` dresses each of its parts
	local function layer(name: string, grow: number, y0: number, y1: number, color: Color3, opts, finish)
		local h = y1 - y0
		local y = floorTop + y0 + h / 2
		local parts = {}
		if round then
			table.insert(parts, K.cylY(podiums, name, math.max(w, d) + grow, h, at(px, y, rowZ).Position, color,
				table.clone(opts)))
		else
			table.insert(parts, K.part(podiums, name, Vector3.new(len, h, d + grow), at(px, y, rowZ), color, table.clone(opts)))
			-- the round ends sit a hair lower so their tops never z-fight the core's
			for _, sx in { -1, 1 } do
				table.insert(parts, K.cylY(podiums, name .. "End", d + grow, h - 0.05,
					at(px + sx * len / 2, y - 0.025, rowZ).Position, color, table.clone(opts)))
			end
		end
		if finish then
			for _, p in parts do finish(p) end
		end
		return parts[1]
	end

	-- the drum overhangs the plinth, so the colour ring glows out from under it
	-- (rebirth machines: a royal-purple drum, a pearl deck, a REBIRTH N plaque)
	local rebirth = rebirthOf(def)
	layer("Plinth", -0.8, 0, 0.3, WP.Granite, { solid = true }, granite)
	local glowRing = layer("Underglow", -0.5, 0.12, 0.2, def.color:Lerp(BLACK, 0.2),
		{ material = Enum.Material.Neon, shadow = false })
	-- (the drum runs 0.05 up into the band, so a stadium's lowered round ends
	-- still meet the band: no see-through slit under it)
	layer("Drum", 0, 0.3, hP - 0.15, rebirth > 0 and WING.Drum or DRUM, { solid = true })
	layer("Band", 0.12, hP - 0.2, hP - 0.05, WP.Brass, { shadow = false }, brass)
	layer("Deck", -0.3, hP - 0.2, hP, rebirth > 0 and WING.Deck or WP.Ivory, { solid = true })
	-- a small pool of the machine's colour on the floor (wide pools read as an arcade)
	K.new("PointLight", { Color = def.color, Brightness = 0.8, Range = 7, Shadows = false }, glowRing)
	if rebirth > 0 then
		-- the plaque on the drum's front (room +Z: its Back face looks at the aisle)
		local front = round and math.max(w, d) / 2 or d / 2
		local plaque = K.part(podiums, "RebirthPlaque", Vector3.new(2.6, math.min(0.66, hP - 0.55), 0.08),
			at(px, floorTop + (0.3 + hP - 0.15) / 2, rowZ + front + 0.04), WING.PlateBottom, { shadow = false })
		local g = K.surface(plaque, Enum.NormalId.Back, 60, 0)
		brighten(g, 1.2)
		local f = K.new("Frame", { BackgroundColor3 = P.White, Size = UDim2.fromScale(1, 1), BorderSizePixel = 0 }, g)
		K.new("UIGradient", { Rotation = 90, Color = ColorSequence.new(WING.PlateTop, WING.PlateBottom) }, f)
		K.new("UIStroke", { Color = P.Gold, Thickness = 4, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, f)
		K.guiImage(f, UIAssets.icon("rebirth"), { size = UDim2.fromScale(0.2, 1.1), position = UDim2.fromScale(0.12, 0.5) })
		K.guiText(f, ("REBIRTH %d"):format(rebirth), { size = UDim2.fromScale(0.72, 0.7), position = UDim2.fromScale(0.24, 0.15),
			gradient = { P.GoldTop, P.Gold }, strokeThickness = 3 })
	end

	-- face the display toward the aisle (the player approaches from room +Z)
	local slotCF = at(px, floorTop + hP, rowZ) * CFrame.Angles(0, math.rad(180), 0)
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
-- signs
------------------------------------------------------------------
-- a marquee board (ShowroomSign / ShowroomWallSign prop) at a CFrame
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

-- a crimson lightbox with gold lettering (always lit); `cf` faces the street
local function lightbox(parent: Instance, cf: CFrame, w: number, text: string)
	local box = K.part(parent, "Lightbox", Vector3.new(w, 2.8, 0.35), cf, P.CrimsonDeep, { shadow = false })
	local g = K.surface(box, Enum.NormalId.Front, 30, 0.1)
	brighten(g, 1.4)
	local plate = K.signPlate(g, P.CrimsonDeep)
	K.guiText(plate, text, { size = UDim2.fromScale(0.92, 0.6), position = UDim2.fromScale(0.04, 0.2),
		gradient = { P.GoldTop, P.Gold }, strokeThickness = 4 })
	return box
end

------------------------------------------------------------------
-- the hall: shell, roof edge, floor inlays, light rig, walls
------------------------------------------------------------------
-- outer walls (ashlar stone outside, stucco stone skin inside), plum ceiling,
-- the membrane roof and a granite kick base. Returns the back wall + roof.
local function buildShell(model: Model, L)
	local at, H, halfW, floorW, floorD = L.at, L.H, L.halfW, L.floorW, L.floorD
	local back, front, midZ, floorTop = L.back, L.front, L.midZ, L.floorTop

	-- the back wall fits between the side walls, and the side walls stop where
	-- the end piers start, so no two stone faces share a plane
	local wall = ashlar(K.part(model, "BackWall", Vector3.new(floorW - 2, H, 1), at(0, H / 2, back + 0.5), WP.Stone,
		{ solid = true }))
	local sideLen = (front - 1.5) - back
	for _, sx in { -1, 1 } do
		ashlar(K.part(model, "SideWall", Vector3.new(1, H, sideLen), at(sx * (halfW - 0.5), H / 2, back + sideLen / 2),
			WP.Stone, { solid = true }))
	end
	-- the inner skin (the niches and wainscot stand off it)
	local skinH = H - 0.2 - floorTop
	local skinY = floorTop + skinH / 2
	stucco(K.part(model, "InnerSkin", Vector3.new(floorW - 2, skinH, 0.2), at(0, skinY, back + 1.1), WP.Stone,
		{ shadow = false }))
	local skinLen = (front - 1.5) - (back + 1.2)
	for _, sx in { -1, 1 } do
		stucco(K.part(model, "InnerSkin", Vector3.new(0.2, skinH, skinLen),
			at(sx * (halfW - 1.1), skinY, back + 1.2 + skinLen / 2), WP.Stone, { shadow = false }))
	end
	-- plum ceiling just under the roof, from the back skin to the fascias
	local ceilLen = (front - 0.5) - (back + 1.2)
	K.part(model, "Ceiling", Vector3.new(floorW - 2.4, 0.2, ceilLen), at(0, H - 0.1, back + 1.2 + ceilLen / 2),
		WP.Plum, { shadow = false })
	-- the roof keeps its name: the sky beam's attachments live on it
	local roof = Materials.paint(K.part(model, "Roof", Vector3.new(floorW + 2, 1.2, floorD + 2), at(0, H + 0.6, midZ),
		WP.Roof, { solid = true }), "RoofMembrane", WP.Roof)
	-- granite kick base round the sides and back (the ground outside is y -0.3)
	granite(K.part(model, "KickBase", Vector3.new(floorW, 1.8, 0.3), at(0, 0.6, back - 0.15), WP.Granite,
		{ solid = true }))
	local kz0, kz1 = back - 0.3, front - 1.7
	for _, sx in { -1, 1 } do
		granite(K.part(model, "KickBase", Vector3.new(0.3, 1.8, kz1 - kz0), at(sx * (halfW + 0.15), 0.6, (kz0 + kz1) / 2),
			WP.Granite, { solid = true }))
	end
	return wall, roof
end

-- the roof edge round the sides and back (the wings get theirs with the
-- facade): brass cornice over the roof slab, stucco-stone parapet, brass
-- coping; plus dark rooftop plant for the aerial view
local function buildRoofKit(parent: Instance, L)
	local at, H, halfW, floorW, back, front = L.at, L.H, L.halfW, L.floorW, L.back, L.front
	local top = H + 1.3                     -- cornice top: a hair over the roof's (H + 1.2)
	-- ...and its underside a hair under the roof's (H): the roof's 1-stud
	-- overhang past the walls would otherwise share that face and flicker
	local cY, cH = H + 0.625, 1.35
	local zA, zB = back - 1.3, front + 2.5  -- side runs end flush with the end piers' fronts
	for _, sx in { -1, 1 } do
		local x = sx * (halfW + 0.65)
		brass(K.part(parent, "Cornice", Vector3.new(1.3, cH, zB - zA), at(x, cY, (zA + zB) / 2), WP.Brass))
		stucco(K.part(parent, "Parapet", Vector3.new(1, 2.2, zB - zA - 0.3), at(x, top + 1.1, (zA + zB) / 2), WP.Stone))
		brass(K.part(parent, "Coping", Vector3.new(1.3, 0.3, zB - zA), at(x, top + 2.35, (zA + zB) / 2), WP.Brass,
			{ shadow = false }))
	end
	brass(K.part(parent, "Cornice", Vector3.new(floorW, cH, 1.3), at(0, cY, back - 0.65), WP.Brass))
	stucco(K.part(parent, "Parapet", Vector3.new(floorW + 0.3, 2.2, 1), at(0, top + 1.1, back - 0.65), WP.Stone))
	brass(K.part(parent, "Coping", Vector3.new(floorW, 0.3, 1.3), at(0, top + 2.35, back - 0.65), WP.Brass,
		{ shadow = false }))
	-- rooftop plant toward the back (clear of the sky-beam lamp at midZ)
	for _, u in { { -0.3, 10 }, { -0.18, 8 }, { 0.28, 12 } } do
		local x, z = floorW * u[1], back + u[2]
		K.part(parent, "HVAC", Vector3.new(6, 3, 4), at(x, H + 2.7, z), WP.DarkMetal)
		K.cylY(parent, "HVACFan", 2.6, 0.2, at(x, H + 4.3, z).Position, WP.Ink, { shadow = false })
	end
end

-- a flat inlay from (x0, z0) to (x1, z1), 0.1 thick, sunk into the floor with
-- its top at `top` (decoration: no collision, query or shadow)
local function inlay(parent, at, name, x0, x1, z0, z1, top, color, finish)
	local p = K.part(parent, name, Vector3.new(math.abs(x1 - x0), 0.1, math.abs(z1 - z0)),
		at((x0 + x1) / 2, top - 0.05, (z0 + z1) / 2), color, { shadow = false })
	if finish then finish(p) end
	return p
end

-- four non-overlapping inlay strips `wid` wide whose outer edges are x = ±xOut,
-- z = zb (back) and z = zf (front)
local function inlayRing(parent, at, name, xOut, zb, zf, wid, top, color, finish)
	local xIn = xOut - wid
	for _, sx in { -1, 1 } do
		inlay(parent, at, name, sx * xIn, sx * xOut, zb, zf, top, color, finish)
	end
	inlay(parent, at, name, -xIn, xIn, zb, zb + wid, top, color, finish)
	inlay(parent, at, name, -xIn, xIn, zf - wid, zf, top, color, finish)
end

-- the floor: a granite border band and a brass pinstripe round the hall, a wine
-- runner down every aisle, and a medallion in the lobby. Inlay tops are 0.05
-- over the tile (the medallion field 0.05 more); the lobby stays walkable.
local function buildInlays(parent: Instance, L)
	local at, halfW, back, front = L.at, L.halfW, L.back, L.front
	local top = L.floorTop + 0.05
	inlayRing(parent, at, "Border", halfW - 2.6, back + 2.6, front - 1.5, 1.5, top, WP.Granite, granite)
	inlayRing(parent, at, "Pinstripe", halfW - 4.7, back + 4.7, front - 3.6, 0.2, top, WP.Brass, brass)
	-- (the Rebirth Wing's runners, its threshold included, are royal purple)
	local wingRows = L.wingRows or 0
	for r = 0, L.rows - 2 do
		local z = L.rowZ(r) + L.rowGap / 2
		local x = halfW - 6
		local inWing = r < wingRows
		inlay(parent, at, inWing and "WingRunner" or "Runner", -x, x, z - 3, z + 3, top, inWing and WING.Runner or WP.Wine, fabric)
		inlay(parent, at, "RunnerEdge", -x, x, z - 3.2, z - 3, top, WP.Brass, brass)
		inlay(parent, at, "RunnerEdge", -x, x, z + 3, z + 3.2, top, WP.Brass, brass)
	end
	-- the wing's medallion on the runner between its rows: a brass ring, a
	-- purple field, a gold star and the rebirth emblem (a hair above the runner)
	if wingRows >= 2 then
		local wz = L.rowZ(0) + L.rowGap / 2
		brass(K.cylY(parent, "WingMedallion", 8, 0.1, at(0, top - 0.03, wz).Position, WP.Brass, { shadow = false }))
		Materials.paint(K.cylY(parent, "WingMedallionField", 7.3, 0.1, at(0, top + 0.02, wz).Position, WING.Runner, { shadow = false }),
			"HonedStone", WING.Runner)
		local star = K.flatPrint(parent, "WingMedallionStar", 6, 6, at(0, top + 0.09, wz), WP.Brass)
		local g = K.surface(star, Enum.NormalId.Top, 40, 0.6)
		for _, rot in { 0, 45 } do
			K.new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.6, 0.6),
				Rotation = rot, BackgroundColor3 = WP.Brass, BorderSizePixel = 0, ZIndex = 1 }, g)
		end
		local core = K.new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(0.36, 0.36), BackgroundColor3 = WING.Runner, BorderSizePixel = 0, ZIndex = 2 }, g)
		K.new("UICorner", { CornerRadius = UDim.new(0.5, 0) }, core)
		K.guiImage(core, UIAssets.icon("rebirth"), { size = UDim2.fromScale(0.86, 0.86), z = 3 })
	end
	-- the lobby medallion: brass ring, wine stone field, an eight-point brass star
	local mz = front - 11
	brass(K.cylY(parent, "Medallion", 14, 0.1, at(0, top - 0.05, mz).Position, WP.Brass, { shadow = false }))
	Materials.paint(K.cylY(parent, "MedallionField", 13, 0.1, at(0, top, mz).Position, WP.Wine, { shadow = false }),
		"HonedStone", WP.Wine)
	local star = K.flatPrint(parent, "MedallionStar", 9, 9, at(0, top + 0.07, mz), WP.Brass)
	local g = K.surface(star, Enum.NormalId.Top, 40, 0.6)
	local function shape(size: number, color: Color3, rotation: number, z: number, round: boolean)
		local f = K.new("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(size, size),
			Rotation = rotation, BackgroundColor3 = color, BorderSizePixel = 0, ZIndex = z,
		}, g)
		if round then K.new("UICorner", { CornerRadius = UDim.new(0.5, 0) }, f) end
	end
	shape(0.62, WP.Brass, 0, 1, false)  -- two squares, one turned 45°: the star
	shape(0.62, WP.Brass, 45, 1, false)
	shape(0.3, WP.Wine, 0, 2, true)
	shape(0.1, WP.Ivory, 0, 3, true)
end

-- the light rig (indoors, so always on): a ceiling can over every machine
-- with a key spot aimed at it, and soft light troughs across the hall on the
-- bay lines
local function buildLightRig(parent: Instance, L, slots)
	local at, H, floorW = L.at, L.H, L.floorW
	local shadows = Config.Showroom.KeyShadows == true
	for _, s in slots do
		local z = s.z + 5.6
		K.cylY(parent, "KeyCan", 1.4, 0.9, at(s.x, H - 0.65, z).Position, WP.Ink, { shadow = false })
		local lens = aimed(parent, "KeyLens", at(s.x, H - 1.15, z).Position,
			at(s.x, L.floorTop + s.hP + s.height * 0.55, s.z).Position, Vector3.new(0.08, 1, 1), KEY_LIGHT,
			{ material = Enum.Material.Neon, shadow = false })
		K.new("SpotLight", { Face = Enum.NormalId.Right, Angle = 38, Range = 30, Brightness = 3.2, Color = KEY_LIGHT,
			Shadows = shadows }, lens)
	end
	for _, z in L.bays do
		-- (over the Rebirth Wing the troughs glow lilac)
		local wing = L.wingFront ~= nil and z <= L.wingFront + 0.01
		K.part(parent, "TroughSoffit", Vector3.new(floorW - 8, 1, 2.6), at(0, H - 0.7, z), WP.Ceiling, { shadow = false })
		local panel = K.part(parent, "TroughPanel", Vector3.new(floorW - 12, 0.1, 1.4), at(0, H - 1.25, z),
			wing and PANEL:Lerp(WING.Light, 0.55) or PANEL, { material = Enum.Material.Neon, shadow = false })
		K.new("SurfaceLight", { Face = Enum.NormalId.Bottom, Brightness = 1.1, Range = 20, Angle = 120,
			Color = wing and FILL_LIGHT:Lerp(WING.Light, 0.5) or FILL_LIGHT, Shadows = false }, panel)
	end
end

-- the walls inside: wine wainscot, brass chair rail, deep-stone pilasters on
-- the bay lines, a brass cornice with a warm cove light on top, and the back
-- feature wall: between pilasters a plum niche behind every back-row slot,
-- glowing up from the floor in that machine's colour
local function buildWalls(parent: Instance, L, backRow)
	local at, H, halfW, floorW, front, floorTop = L.at, L.H, L.halfW, L.floorW, L.front, L.floorTop
	local zIn = L.back + 1.2 -- the back skin's face
	local xIn = halfW - 1.2  -- the side skins' faces
	local sideEnd = front - 1.5

	-- a back run plus both side runs, `depth` proud of the skin, `height` tall
	-- centred on y (the side runs start where the back run ends: no overlap)
	local function run(name: string, depth: number, height: number, y: number, color: Color3, opts, finish)
		local parts = { K.part(parent, name, Vector3.new(floorW - 2.4, height, depth), at(0, y, zIn + depth / 2), color, opts) }
		local z0 = zIn + depth
		for _, sx in { -1, 1 } do
			table.insert(parts, K.part(parent, name, Vector3.new(depth, height, sideEnd - z0),
				at(sx * (xIn - depth / 2), y, (z0 + sideEnd) / 2), color, opts))
		end
		if finish then
			for _, p in parts do finish(p) end
		end
	end
	run("Wainscot", 0.3, 4, floorTop + 2, WP.Wine, { material = Enum.Material.Fabric, solid = true }) -- bodies stop at it
	run("ChairRail", 0.4, 0.4, floorTop + 4.2, WP.Brass, { shadow = false }, brass)
	run("Cornice", 0.6, 0.5, H - 1.75, WP.Brass, { shadow = false }, brass)
	-- the cove sits on the cornice against the wall: hidden from the floor, it
	-- glows up toward the ceiling
	run("Cove", 0.15, 0.15, H - 1.425, WP.WarmNeon, { material = Enum.Material.Neon, shadow = false })

	-- pilasters (4-wide ashlar faces) with brass caps
	local pilH = 14.7
	local capY = floorTop + pilH + 0.2
	for _, z in L.bays do
		for _, sx in { -1, 1 } do
			ashlar(K.part(parent, "Pilaster", Vector3.new(1.2, pilH, 4), at(sx * (xIn - 0.6), floorTop + pilH / 2, z),
				WP.DeepStone, { solid = true }), WP.DeepStone)
			brass(K.part(parent, "PilasterCap", Vector3.new(1.4, 0.4, 4.4), at(sx * (xIn - 0.7), capY, z), WP.Brass,
				{ shadow = false }))
			-- the Rebirth Wing's pilasters carry a purple neon strip
			if L.wingFront ~= nil and z <= L.wingFront + 0.01 then
				K.part(parent, "WingNeon", Vector3.new(0.12, pilH - 3, 0.3), at(sx * (xIn - 1.24), floorTop + pilH / 2, z), WING.Neon,
					{ material = Enum.Material.Neon, shadow = false })
			end
		end
	end
	-- each back-row display owns a bay of the wall: from the middle of the gap
	-- on its left to the middle of the gap on its right (podiums have their
	-- own widths now, so the bays do too)
	local gap = L.backGap or 4
	local bounds = {}
	for i, s in backRow do
		local w = s.w or (L.spacing - gap)
		if i == 1 then table.insert(bounds, s.x - w / 2 - gap / 2) end
		local nxt = backRow[i + 1]
		if nxt then
			table.insert(bounds, ((s.x + w / 2) + (nxt.x - (nxt.w or w) / 2)) / 2)
		else
			table.insert(bounds, s.x + w / 2 + gap / 2)
		end
	end
	for _, x in bounds do
		ashlar(K.part(parent, "Pilaster", Vector3.new(4, pilH, 1.2), at(x, floorTop + pilH / 2, zIn + 0.6),
			WP.DeepStone, { solid = true }), WP.DeepStone)
		brass(K.part(parent, "PilasterCap", Vector3.new(4.4, 0.4, 1.4), at(x, capY, zIn + 0.7), WP.Brass,
			{ shadow = false }))
	end
	for i, s in backRow do
		local b0, b1 = bounds[i], bounds[i + 1]
		-- the niche: 0.45 behind the pilaster faces, in front of the wainscot
		local nicheW = math.max(2, (b1 - b0) - 4)
		local niche = K.part(parent, "Niche", Vector3.new(nicheW, 14.5, 0.3), at((b0 + b1) / 2, floorTop + 7.25, zIn + 0.6),
			WP.Plum, { shadow = false, solid = true }) -- solid: a body can't sink into the recess
		brass(K.part(parent, "NicheHead", Vector3.new(nicheW, 0.3, 0.5), at((b0 + b1) / 2, floorTop + 14.65, zIn + 0.7),
			WP.Brass, { shadow = false }))
		if s.def then
			local g = K.surface(niche, Enum.NormalId.Back, 8, 0) -- Back = the room side
			brighten(g, 1.2)
			local fill = K.new("Frame", { Size = UDim2.fromScale(1, 1), BorderSizePixel = 0,
				BackgroundColor3 = s.def.color:Lerp(WP.Plum, 0.35) }, g)
			K.new("UIGradient", { Rotation = -90, Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.15), NumberSequenceKeypoint.new(0.55, 0.75), NumberSequenceKeypoint.new(1, 1),
			}) }, fill)
		end
	end
end

------------------------------------------------------------------
-- the street front
------------------------------------------------------------------
-- Depth layers (room z, front = the building line): glass front - 0.4, wing
-- fascias to front + 1.2, end piers to front + 2.5, the portal to front + 3,
-- the canopy out to front + 7.6 (the road starts at front + 8). Bays across:
-- the doorway |x| < 10, portal piers 10..15, glass wings 15..halfW - 4, end
-- piers to the corners.
local function buildFacade(parent: Instance, L)
	local at, H, halfW, f = L.at, L.H, L.halfW, L.front
	local function pos(x, y, z) return at(x, y, z).Position end
	local portalTop = H + PORTAL_RISE
	local glassTop = H - 6.7
	local deco = { shadow = false }

	-- PORTAL: crimson lacquer piers and attic round the open doorway, brass
	-- edges, bases, jambs, head and cap, a warm neon line down each pier
	local lacquer = { solid = true, reflectance = 0.05 }
	for _, sx in { -1, 1 } do
		local px = sx * (PIER_IN + PIER_OUT) / 2
		K.part(parent, "PortalPier", Vector3.new(PIER_OUT - PIER_IN, portalTop, 4), at(px, portalTop / 2, f + 1),
			WP.Lacquer, lacquer)
		brass(K.part(parent, "PortalBase", Vector3.new(PIER_OUT - PIER_IN + 0.6, 1.4, 4.6), at(px, 0.7, f + 1), WP.Brass))
		for _, ex in { PIER_IN + 0.225, PIER_OUT - 0.225 } do -- 0.05 in from the pier's sides
			brass(K.part(parent, "PortalEdge", Vector3.new(0.35, portalTop - 1.4, 0.35),
				at(sx * ex, (portalTop + 1.4) / 2, f + 3.075), WP.Brass, deco))
		end
		nightNeon(K.part(parent, "PortalNeon", Vector3.new(0.25, portalTop - 8, 0.1), at(px, portalTop / 2, f + 3.05),
			WP.WarmNeon, deco), WP.WarmNeon)
		brass(K.part(parent, "DoorJamb", Vector3.new(0.6, DOOR_TOP - 0.6, 1.4),
			at(sx * (PIER_IN - 0.3), (DOOR_TOP - 0.6) / 2, f + 2.4), WP.Brass))
	end
	K.part(parent, "PortalAttic", Vector3.new(PIER_IN * 2, portalTop - DOOR_TOP, 4), at(0, (DOOR_TOP + portalTop) / 2, f + 1),
		WP.Lacquer, lacquer)
	brass(K.part(parent, "DoorHead", Vector3.new(PIER_IN * 2, 0.6, 1.4), at(0, DOOR_TOP - 0.3, f + 2.4), WP.Brass))
	brass(K.part(parent, "Threshold", Vector3.new(PIER_IN * 2 - 1.2, 0.1, 0.3), at(0, L.floorTop, f), WP.Brass,
		deco))
	brass(K.part(parent, "PortalCap", Vector3.new(PIER_OUT * 2 + 0.6, 0.55, 4.6), at(0, portalTop + 0.275, f + 1),
		WP.Brass))

	-- GLASS WINGS: granite kick base, one clear pane (Poppercam ignores it),
	-- brass mullions + transom, an ashlar fascia carrying a lightbox with a
	-- light line under it, then cornice, parapet and coping over the roof edge
	local endIn = halfW - 4
	local wingLen = endIn - PIER_OUT
	if wingLen > 4 then
		local lbW = math.min(22, wingLen - 4)
		for _, sx in { -1, 1 } do
			local wx = sx * (PIER_OUT + endIn) / 2
			granite(K.part(parent, "WingKick", Vector3.new(wingLen, 1.8, 1.4), at(wx, 0.6, f - 0.1), WP.Granite,
				{ solid = true }))
			brass(K.part(parent, "WingKickLip", Vector3.new(wingLen, 0.15, 1.5), at(wx, 1.575, f - 0.1), WP.Brass, deco))
			K.part(parent, "WingGlass", Vector3.new(wingLen, glassTop - 1.5, 0.3), at(wx, (glassTop + 1.5) / 2, f - 0.4),
				WP.GlassClear, { transparency = 0.72, reflectance = 0.08, solid = true, shadow = false })
			for k = 1, 3 do
				brass(K.part(parent, "Mullion", Vector3.new(0.5, glassTop - 1.65, 0.7),
					at(sx * (PIER_OUT + wingLen * k / 4), (glassTop + 1.65) / 2, f - 0.4), WP.Brass))
			end
			brass(K.part(parent, "Transom", Vector3.new(wingLen, 0.4, 0.6), at(wx, glassTop - 3, f - 0.4), WP.Brass))
			ashlar(K.part(parent, "Fascia", Vector3.new(wingLen, H - glassTop, 1.7), at(wx, (glassTop + H) / 2, f + 0.35),
				WP.Stone, { solid = true }))
			nightNeon(K.part(parent, "FasciaNeon", Vector3.new(wingLen - 0.4, 0.15, 0.15),
				at(wx, glassTop - 0.075, f + 1.05), WP.WarmNeon, deco), WP.WarmNeon)
			-- the viewer's left wing reads first
			lightbox(parent, at(wx, (glassTop + H) / 2, f + 1.375) * FACE_OUT, lbW, -- back on the fascia face
				sx < 0 and "SLOTS · TABLES · WHEELS" or ((L.wingRows or 0) > 0 and "THE REBIRTH WING" or "BUY · PLACE · PROFIT"))
			brass(K.part(parent, "Cornice", Vector3.new(wingLen, 1.3, 2.3), at(wx, H + 0.65, f + 0.65), WP.Brass))
			stucco(K.part(parent, "Parapet", Vector3.new(wingLen, 2.2, 1), at(wx, H + 2.4, f + 0.5), WP.Stone))
			brass(K.part(parent, "Coping", Vector3.new(wingLen, 0.3, 1.3), at(wx, H + 3.65, f + 0.5), WP.Brass, deco))
		end
	end

	-- END PIERS at the corners (they rise above the parapet line)
	if endIn >= PIER_OUT then
		for _, sx in { -1, 1 } do
			local ex = sx * (halfW - 2)
			ashlar(K.part(parent, "EndPier", Vector3.new(4, H + 4, 4), at(ex, (H + 4) / 2, f + 0.5), WP.Stone,
				{ solid = true }))
			brass(K.part(parent, "EndPierBase", Vector3.new(4.4, 1.2, 4.4), at(ex, 0.6, f + 0.5), WP.Brass))
			brass(K.part(parent, "EndPierCap", Vector3.new(4.6, 0.6, 4.6), at(ex, H + 4.3, f + 0.5), WP.Brass))
			nightNeon(K.part(parent, "EndPierNeon", Vector3.new(0.25, H - 4, 0.1), at(ex, (H + 4) / 2, f + 2.55),
				WP.WarmNeon, deco), WP.WarmNeon)
		end
	end

	-- CANOPY over the doorway, between the jambs (the travel arrival point
	-- stands under it). No collision or query, so the camera never snaps under
	-- it. Its own model: MachineFX chases the bulbs.
	local canopy = atomic(K.new("Model", { Name = "ShowroomCanopy" }))
	local bulbs = K.new("Folder", { Name = "Bulbs" }, canopy)
	local cw = PIER_IN - 0.3              -- half width
	local cz0, cz1 = f + 3.15, f + 7.2    -- deck: just clear of the jambs out to the fascia
	local cz = (cz0 + cz1) / 2
	local sz0 = f + 3.3                   -- the side fascias start clear of the pier edges
	local deckY = DOOR_TOP - 2.9           -- the deck's centre: 11.1
	K.part(canopy, "CanopyDeck", Vector3.new(cw * 2, 1, cz1 - cz0), at(0, deckY, cz), WP.Plum)
	K.part(canopy, "CanopyFascia", Vector3.new(cw * 2 + 0.8, 1.8, 0.4), at(0, deckY, cz1 + 0.2), WP.Lacquer,
		{ reflectance = 0.05 })
	for _, ly in { deckY + 0.99, deckY - 0.99 } do
		brass(K.part(canopy, "CanopyLip", Vector3.new(cw * 2 + 1, 0.18, 0.5), at(0, ly, cz1 + 0.2), WP.Brass, deco))
	end
	for _, sx in { -1, 1 } do
		K.part(canopy, "CanopyFascia", Vector3.new(0.4, 1.8, cz1 - sz0), at(sx * (cw + 0.2), deckY, (sz0 + cz1) / 2),
			WP.Lacquer, { reflectance = 0.05 })
		brass(K.part(canopy, "CanopyLip", Vector3.new(0.5, 0.18, cz1 - 0.05 - sz0),
			at(sx * (cw + 0.2), deckY + 0.99, (sz0 + cz1 - 0.05) / 2), WP.Brass, deco))
		K.bulbsAlong(bulbs, pos(sx * (cw + 0.6), deckY, sz0 + 0.6), pos(sx * (cw + 0.6), deckY, cz1 - 0.3), 4, 0.45)
		-- brass tension rods up to the portal piers
		brass(rod(canopy, "CanopyRod", pos(sx * (cw - 0.5), deckY + 0.6, cz1 - 0.3),
			pos(sx * (PIER_IN + 0.7), portalTop - 10, f + 3), 0.35, WP.Brass, deco))
	end
	K.bulbsAlong(bulbs, pos(-(cw - 0.3), deckY, cz1 + 0.55), pos(cw - 0.3, deckY, cz1 + 0.55), 24, 0.45)
	-- the lit soffit: a cream panel by day, a warm glow after dark
	local soffit = nightNeon(K.part(canopy, "CanopySoffit", Vector3.new(cw * 2 - 1, 0.1, cz1 - cz0 - 0.8),
		at(0, deckY - 0.55, cz), PANEL, deco), PANEL, WP.Soffit)
	nightLight(K.new("SurfaceLight", { Face = Enum.NormalId.Bottom, Brightness = 1.3, Range = 14, Angle = 110,
		Color = FILL_LIGHT, Shadows = false }, soffit))
	-- fixtures on the deck, hidden behind the fascia: a spot on the wheel and a
	-- wash up each portal pier from either front corner
	for _, sx in { -1, 1 } do
		local ws = aimed(canopy, "WheelSpot", pos(sx * (cw - 1.6), deckY + 0.85, cz1 - 0.6), pos(0, WHEEL_Y, f + 3.6),
			Vector3.new(0.6, 0.5, 0.5), WP.DarkMetal, deco)
		nightLight(K.new("SpotLight", { Face = Enum.NormalId.Right, Angle = 50, Range = 24, Brightness = 2.2,
			Color = UPLIGHT, Shadows = false }, ws))
		local pw = aimed(canopy, "PortalWash", pos(sx * (cw - 0.6), deckY + 0.85, cz1 - 1.2),
			pos(sx * (PIER_IN + PIER_OUT) / 2, portalTop - 8, f + 3), Vector3.new(0.6, 0.5, 0.5), WP.DarkMetal, deco)
		nightLight(K.new("SpotLight", { Face = Enum.NormalId.Right, Angle = 40, Range = 26, Brightness = 2.4,
			Color = UPLIGHT, Shadows = false }, pw))
	end
	CollectionService:AddTag(canopy, "CasinoProp")
	canopy.Parent = parent

	-- IN-GROUND UPLIGHTS on the forecourt (top y 0.3): two under each wing's
	-- fascia, one at each end pier
	local ups = { { halfW - 2, f + 3.3 } }
	if wingLen > 4 then
		table.insert(ups, { PIER_OUT + wingLen / 4, f + 2.5 })
		table.insert(ups, { PIER_OUT + wingLen * 3 / 4, f + 2.5 })
	end
	for _, u in ups do
		for _, sx in { -1, 1 } do
			local housing = K.part(parent, "Uplight", Vector3.new(0.9, 0.25, 0.9), at(sx * u[1], 0.3, u[2]), WP.DarkMetal,
				deco)
			nightNeon(K.part(parent, "UplightLens", Vector3.new(0.6, 0.06, 0.6), at(sx * u[1], 0.45, u[2]), UPLIGHT, deco),
				UPLIGHT)
			nightLight(K.new("SpotLight", { Face = Enum.NormalId.Top, Angle = 30, Range = 28, Brightness = 2.4,
				Color = UPLIGHT, Shadows = false }, housing))
		end
	end
end

------------------------------------------------------------------
-- the landmark: a giant prize wheel on the portal and the crown sign over it
------------------------------------------------------------------
-- built in model space round the hub (front = -Z). MachineFX spins it like a
-- Wheel machine: direct children Wheel / Hub / HubCap / Pointer, a Bulbs folder,
-- tagged CasinoProp, DemoType "Wheel" (never GameType: it isn't playable)
local function buildFacadeWheel(): Model
	local m = atomic(K.new("Model", { Name = "ShowroomFacadeWheel" }))
	local bulbs = K.new("Folder", { Name = "Bulbs" }, m)
	local R = WHEEL_R
	K.cylZ(m, "RimBack", R * 2 + 1.8, 0.3, Vector3.new(0, 0, 0.7), P.Ink) -- its face 0.05 off the attic
	K.cylZ(m, "Rim", R * 2 + 1.2, 0.6, Vector3.new(0, 0, 0.3), P.Gold, { reflectance = 0.15 })
	local wheel = K.cylZ(m, "Wheel", R * 2, 0.3, Vector3.new(0, 0, -0.1), P.White)
	K.new("Decal", { Face = Enum.NormalId.Right, Texture = MachineModels.Textures.fortune }, wheel)
	K.cylZ(m, "Hub", 2.4, 0.6, Vector3.new(0, 0, -0.5), P.Gold, { reflectance = 0.2 })
	K.ball(m, "HubCap", 1.5, Vector3.new(0, 0, -0.85), P.GoldTop, { reflectance = 0.2 })
	for k = 0, 31 do
		local a = k * math.pi / 16
		local bulb = K.ball(bulbs, "Bulb", 0.42, Vector3.new(math.cos(a) * (R + 0.3), math.sin(a) * (R + 0.3), -0.05),
			(k % 2 == 0) and P.GoldTop or P.White, { material = Enum.Material.Neon, shadow = false })
		bulb:SetAttribute("Phase", k % 2)
	end
	-- pointer at the top (a red wedge pointing down) on a gold block
	-- (deep enough to reach back to the attic face, level with the rim's back)
	K.part(m, "PointerBase", Vector3.new(1.6, 0.9, 1.6), CFrame.new(0, R + 1.8, -0.2), P.Gold, { reflectance = 0.12 })
	K.new("WedgePart", {
		Name = "Pointer", Anchored = true, Size = Vector3.new(0.54, 2.1, 1.5), Color = P.NeonRed,
		Material = Enum.Material.SmoothPlastic, CanCollide = false, CanQuery = false, CanTouch = false,
		CFrame = CFrame.new(0, R + 0.3, -0.55) * CFrame.Angles(math.rad(180), 0, 0) * CFrame.Angles(0, math.rad(90), 0),
	}, m)
	m:SetAttribute("DemoType", "Wheel")
	CollectionService:AddTag(m, "CasinoProp")
	return m
end

-- the bulb-ringed MACHINE SHOWROOM board standing on the portal, with a brass
-- sunburst crest and a crown rising behind it. Model space: the board's bottom
-- centre is the origin, front = -Z.
local function buildCrownSign(): Model
	local m = atomic(K.new("Model", { Name = "ShowroomCrownSign" }))
	local bulbs = K.new("Folder", { Name = "Bulbs" }, m)
	local W, Hs = 32, 7
	local board = K.boardSign(m, "Board", Vector3.new(W, Hs, 0.8), CFrame.new(0, Hs / 2, 0), "MACHINE SHOWROOM",
		{ ppu = 24, stroke = 5 })
	brighten(board, 1.5)
	bulbRect(bulbs, 0, Hs / 2, W - 0.7, Hs - 0.7, -0.45, 1.2, 0.45)
	-- the crest: a disc (its lower half hides behind the board) and seven rays
	brass(K.cylZ(m, "Crest", 11, 0.5, Vector3.new(0, Hs, 0.75), WP.Brass))
	for k = -3, 3 do
		local a = math.rad(90 + k * 22.5)
		local r = 6.8 -- each ray runs from radius 4.6 to 9
		brass(K.part(m, "CrestRay", Vector3.new(0.5, 4.4, 0.4),
			CFrame.new(math.cos(a) * r, Hs + math.sin(a) * r, 0.75) * CFrame.Angles(0, 0, a - math.pi / 2), WP.Brass,
			{ shadow = false }))
	end
	local icon = K.part(m, "CrownIcon", Vector3.new(5, 3.6, 0.05), CFrame.new(0, Hs + 2.6, 0.45), P.White,
		{ transparency = 1, shadow = false })
	K.guiImage(K.surface(icon, Enum.NormalId.Front, 60, 0.2), "crown")
	CollectionService:AddTag(m, "CasinoProp")
	return m
end

local function buildLandmark(parent: Instance, L)
	local at, H, f = L.at, L.H, L.front
	-- the hub stands 0.6 off the attic face, so nothing that spins touches it
	place(buildFacadeWheel(), parent, at(0, WHEEL_Y, f + 3.6))
	place(buildCrownSign(), parent, at(0, H + PORTAL_RISE + 0.55, f + 2.6)) -- on the portal cap
end

------------------------------------------------------------------
-- the display rows. The catalog runs in rank order, so the rows are tiers:
-- the FRONT row by the entrance holds the starter machines, then up the
-- ranks; behind them the Rebirth Wing's rows (by rebirth level), the BACK row
-- (raised, under the wall sign) holding the top rebirth machines. Every row
-- is laid out from the middle: the front rows of a section put their
-- cheapest machine in the centre (right where you walk in), each section's
-- last row its most expensive one (the hero at the end of the aisle).
-- Podiums keep their own widths with an even gap, so slim cabinets and wide
-- tables pack in. The hall keeps its 98-stud width (its city slot); rows only
-- push the back wall back (MapBuilder.inShowroom keeps the city clear of it:
-- five rows reach t ~136 from the south boulevard).
------------------------------------------------------------------
local MAX_PER_ROW = 7
local ROW_SPAN = 86             -- the widest a row may run (the hall's inside is ~95)
local GAP_MIN, GAP_MAX = 2.6, 6 -- studs between two podiums

-- split the machines into rows, front row first: full rows of MAX_PER_ROW and
-- the remainder at the back (or even rows if the remainder would be tiny)
local function planRows(machines): { { any } }
	local n = #machines
	local rows = math.max(1, math.ceil(n / MAX_PER_ROW))
	local counts = {}
	local backCount = n - (rows - 1) * MAX_PER_ROW
	if rows == 1 or backCount >= 3 then
		for r = 1, rows - 1 do counts[r] = MAX_PER_ROW end
		counts[rows] = backCount
	else
		local base, more = n // rows, n % rows
		for r = 1, rows do counts[r] = base + (r <= more and 1 or 0) end
	end
	local groups, k = {}, 0
	for r = 1, rows do
		local g = {}
		for _ = 1, counts[r] do
			k += 1
			table.insert(g, machines[k])
		end
		groups[r] = g
	end
	return groups
end

-- order a row from the middle out (list[1] in the centre, then left, right,
-- left, ...); returns the defs left to right as seen from the entrance
local function centreOut(list)
	local n = #list
	local out = {}
	local mid = n // 2 + 1
	for i, item in list do
		local offset = (i == 1) and 0 or ((i % 2 == 0) and -(i // 2) or (i // 2))
		out[mid + offset] = item
	end
	return out
end

-- x of each podium centre (left to right), the gap and the row's width
local function rowXs(list): ({ number }, number, number)
	local total = 0
	for _, def in list do total += podiumWidth(def) end
	local n = #list
	local gap = n > 1 and math.clamp((ROW_SPAN - total) / (n - 1), GAP_MIN, GAP_MAX) or 0
	local span = total + gap * (n - 1)
	local xs, x = {}, -span / 2
	for i, def in list do
		local w = podiumWidth(def)
		xs[i] = x + w / 2
		x += w + gap
	end
	return xs, gap, span
end

-- the REBIRTH WING marquee hung over the wing's threshold (double-sided), on
-- brass rods up to the light trough above it
local WING_SIGN_Y, WING_SIGN_H = 14.6, 3.4 -- its bottom over the floor; the board's height (MachineModels)
local function buildWingSign(parent: Instance, L)
	if not L.wingFront then return end
	local at, H, y0 = L.at, L.H, L.floorTop + WING_SIGN_Y
	local sign = placeSign(parent, at(0, y0, L.wingFront) * FACE_OUT, "RebirthWingSign")
	if not sign then return end
	brighten(sign, 1.3)
	for _, sx in { -1, 1 } do
		brass(rod(parent, "WingSignRod", at(sx * 12, y0 + WING_SIGN_H, L.wingFront).Position,
			at(sx * 12, H - 1.2, L.wingFront).Position, 0.18, WP.Brass, { shadow = false }))
	end
end

------------------------------------------------------------------
-- assemble the room
------------------------------------------------------------------
function Showroom.build()
	local cfg = Config.Showroom
	local center = cfg.Center
	local spacing = cfg.Spacing
	local rowGap = cfg.RowGap or 16
	-- the room is laid out in its own frame: the aisle/entrance is room +Z,
	-- the back wall room -Z; Yaw turns the whole building (90 = entrance east)
	local roomCF = CFrame.new(center) * CFrame.Angles(0, math.rad(cfg.Yaw or 0), 0)
	local function at(x, y, z) return roomCF * CFrame.new(x, y, z) end

	-- the rank machines (catalog order) in front, the Rebirth Wing behind them
	-- (by rebirth level, then price)
	local rankMachines, wingMachines = {}, {}
	for _, def in Config.Catalog do
		if not Config.isConcession(def) then
			table.insert(rebirthOf(def) > 0 and wingMachines or rankMachines, def)
		end
	end
	table.sort(wingMachines, function(a, b)
		if rebirthOf(a) ~= rebirthOf(b) then return rebirthOf(a) < rebirthOf(b) end
		if (a.cost or 0) ~= (b.cost or 0) then return (a.cost or 0) < (b.cost or 0) end
		return a.id < b.id
	end)
	local machines = table.clone(rankMachines)
	for _, def in wingMachines do table.insert(machines, def) end
	if #machines == 0 then return end

	local deskInRow = cfg.ServicesCFrame == nil       -- otherwise the desk stands elsewhere (plaza)
	local groups = #rankMachines > 0 and planRows(rankMachines) or {} -- groups[1] = the front row
	local rankRows = #groups
	local wingRows = 0
	if #wingMachines > 0 then
		for _, g in planRows(wingMachines) do
			table.insert(groups, g)
			wingRows += 1
		end
	end
	local rows = #groups
	local floorTop = 0.5                               -- room-local: the floor is 1 thick around y = 0
	-- extra rows push the back wall back; the entrance (room +Z) never moves
	local extra = (rows - 1) * rowGap
	local floorD = 36 + extra
	local midZ = -extra / 2
	local H = cfg.Height or 22                         -- wall height
	local function rowZ(r: number): number return -6 - extra + r * rowGap end -- r = 0: the back row

	-- every display: x, z, its podium width, deck height (the back row stands
	-- taller when there's a row in front of it)
	local lift = rows > 1 and (cfg.BackRowLift or 0) or 0
	local slotInfo, lit, backRow = {}, {}, {}
	local widest, backGap = 0, GAP_MAX
	for gi, group in groups do
		local r = rows - gi                             -- groups run front -> back
		local ranked = group
		if rows > 1 and (r == 0 or (gi == rankRows and wingRows > 0)) then
			-- a section's last row (the hall's back row, the rank machines'
			-- top tier): its most expensive machine takes the centre
			ranked = {}
			for i = #group, 1, -1 do table.insert(ranked, group[i]) end
		end
		local ordered = centreOut(ranked)
		local xs, gap, span = rowXs(ordered)
		widest = math.max(widest, span)
		if r == 0 then backGap = gap end
		for i, def in ordered do
			local s = { x = xs[i], z = rowZ(r), def = def, w = podiumWidth(def), row = r, height = def.size.Y,
				hP = (cfg.PedestalHeight or 1.4) + (r == 0 and lift or 0) }
			slotInfo[def] = s
			table.insert(lit, s)
			if r == 0 then table.insert(backRow, s) end
		end
	end
	-- the hall keeps its slot's width unless a row needs more
	local floorW = math.max(98, math.ceil(widest + 12))

	-- clear any prior build (so re-runs / hot-reloads don't stack rooms)
	local old = Workspace:FindFirstChild("Showroom")
	if old then old:Destroy() end

	local model = Instance.new("Model")
	model.Name = "Showroom"

	-- the floor: polished ivory tile (the travel target reads this part)
	local back = midZ - floorD / 2
	local front = midZ + floorD / 2                    -- 18 for any number of rows
	local floor = block(model, "Floor", Vector3.new(floorW, 1, floorD), at(0, 0, midZ), WP.Ivory)
	Materials.paint(floor, "PolishedTile", WP.Ivory) -- 4x4-stud tiles: the machines pop on a warm light neutral

	-- bay lines (light troughs + side pilasters): between the back wall and the
	-- back row, between every two rows, and over the lobby
	local bays = { rowZ(0) - rowGap / 2 }
	for r = 0, rows - 1 do table.insert(bays, rowZ(r) + rowGap / 2) end
	table.insert(bays, front - 4.5)
	local L = {
		at = at, floorW = floorW, floorD = floorD, halfW = floorW / 2, back = back, front = front, midZ = midZ, H = H,
		floorTop = floorTop, rows = rows, rowGap = rowGap, spacing = spacing, rowZ = rowZ, bays = bays,
		backGap = backGap,
		-- the Rebirth Wing: its rows (r < wingRows) and its threshold (the bay
		-- line between it and the rank machines)
		wingRows = wingRows, wingFront = wingRows > 0 and (rowZ(wingRows - 1) + rowGap / 2) or nil,
	}

	local wall, roof = buildShell(model, L)

	-- decoration: a failure here must never take the shop down
	local function try(label: string, fn, ...)
		local ok, err = pcall(fn, ...)
		if not ok then warn(("[Showroom] %s failed: %s"):format(label, tostring(err))) end
	end
	try("roof", buildRoofKit, folder("RoofKit", model), L)
	try("floor inlays", buildInlays, folder("Inlays", model), L)
	try("light rig", buildLightRig, folder("LightRig", model), L, lit)
	try("walls", buildWalls, folder("Walls", model), L, backRow)
	local facade = folder("Facade", model)
	try("facade", buildFacade, facade, L)
	try("landmark", buildLandmark, facade, L)

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
	beam.Color = ColorSequence.new(WP.Soffit:Lerp(WP.WarmNeon, 0.3))
	beam.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.45), NumberSequenceKeypoint.new(0.45, 0.82),
		NumberSequenceKeypoint.new(1, 1) })
	pcall(function() beam.Brightness = 2.2 end)
	beam.Parent = roof
	CollectionService:AddTag(beam, NIGHT_TAG) -- DayNightFX: the beam only runs after dark
	local lamp = block(model, "BeamLamp", Vector3.new(6, 0.3, 6), at(0, H + 1.35, midZ), WP.Soffit,
		Enum.Material.Neon)
	lamp.Shape = Enum.PartType.Cylinder
	lamp.Size = Vector3.new(0.3, 6, 6)
	lamp.CFrame = at(0, H + 1.35, midZ) * CFrame.Angles(0, 0, math.rad(90)) -- sits on the roof
	lamp:SetAttribute("DayMaterial", "SmoothPlastic") -- a plain disc by day, glowing at night
	CollectionService:AddTag(lamp, NIGHT_TAG)

	model.Parent = Workspace  -- parent the room first so seat()/PivotTo math is stable

	-- the bulb board on the back feature wall, over the back row, facing the aisle
	local sign = placeSign(model, at(0, floorTop + 15.5, back + 1.4) * FACE_OUT, "ShowroomWallSign") -- back on the skin
	if sign then
		brighten(sign, 1.3)
	else
		local signBB = Instance.new("BillboardGui")
		signBB.Size = UDim2.fromOffset(560, 90); signBB.StudsOffset = Vector3.new(0, 6, 0)
		signBB.AlwaysOnTop = false; signBB.Parent = wall
		local signText = Instance.new("TextLabel")
		signText.Size = UDim2.fromScale(1, 1); signText.BackgroundTransparency = 1
		signText.TextScaled = true; signText.Font = Enum.Font.GothamBold
		signText.TextColor3 = C.Accent; signText.Text = "MACHINE SHOWROOM"; signText.Parent = signBB
	end
	try("rebirth wing sign", buildWingSign, model, L)

	local podiums = folder("Podiums", model)
	for _, def in ipairs(machines) do
		local s = slotInfo[def]
		-- isolate each display so one bad one can't take down the whole room
		local ok, err = pcall(buildPedestal, model, podiums, def, L, s.x, s.z, s.hP)
		if not ok then
			warn(("[Showroom] display '%s' failed: %s"):format(def.name, tostring(err)))
		end
	end

	-- the services desk lives on the plaza (Config.Showroom.ServicesCFrame); without
	-- one it stands in the lobby's left corner, facing the entrance
	local deskCF = cfg.ServicesCFrame
		or (at(-(floorW / 2 - 9), floorTop, front - 9) * CFrame.Angles(0, math.rad(180), 0))
	local _ = deskInRow
	pcall(buildServicesDesk, model, deskCF)

	print(("[Showroom] Built with %d machine display(s) in %d row(s) (Rebirth Wing: %d in %d row(s))."):format(#machines, rows,
		#wingMachines, wingRows))
end

-- the facade wheel spins for show: every client animates it (MachineFX) when
-- its PlayTick bumps, exactly like a played Wheel machine
local function spinLoop()
	local rng = Random.new()
	while true do
		task.wait(Config.Showroom.WheelSpinEvery or 12)
		local room = Workspace:FindFirstChild("Showroom")
		local wheel = room and room:FindFirstChild("ShowroomFacadeWheel", true)
		if wheel then
			wheel:SetAttribute("LastWin", rng:NextNumber() < 0.5) -- a "win" flashes its bulbs
			wheel:SetAttribute("PlayTick", (wheel:GetAttribute("PlayTick") or 0) + 1)
		end
	end
end

local spinning = false
function Showroom.start()
	local ok, err = pcall(Showroom.build)
	if not ok then warn("[Showroom] build failed: " .. tostring(err)) end
	if not spinning then
		spinning = true
		task.spawn(spinLoop)
	end
end

return Showroom
