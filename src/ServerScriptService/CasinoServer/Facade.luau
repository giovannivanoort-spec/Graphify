--!nonstrict
-- Facade.luau — the LOOK of a casino building, "Grand Palace" style.
-- Buildings.luau builds the shell (walls with their glass band, floors,
-- ceilings, the elevator, interior lights, the roof deck) and owns the
-- gameplay; it calls Facade.build(b, at, ctx) once per rebuild to dress it:
--
--   base   story 1: dark granite plinth, storefronts, a brass-lined 20-wide
--          door, the porte-cochère (brass columns, bulb fascia, lit soffit,
--          the name sign) and a belt course (the owner's darker shade) with a
--          cove light under it
--   shaft  stories 2..S: owner-coloured stucco walls, framed windows (brass
--          sills + mullions, stone hoods), a balconette over the entrance,
--          stucco pilasters and stone string courses
--   crown  story S+1: stone cornice with a brass crown-moulding lip, stucco
--          parapet with a slim brass coping (from the air the roof edge
--          reads stone, not a gold rim), corner pier tops with brass
--          finials, the pavilion attic carrying the roof name sign + crown,
--          and a roof kit (glass lantern, elevator penthouse, HVAC, walkway)
--          that grows with the building: a pool deck from 3 stories, a
--          helipad + searchlights at 5
--   VIP    the VIP lounge (ctx.vipStory, always the top story; VipFloor.luau):
--          a penthouse look: gold glass (Buildings), brass hoods / sills /
--          balustrade, gold pier neon and a purple "VIP LOUNGE" sign with
--          crowns and chase bulbs over the centre window
-- Ashlar piers run up both corners and both sides of the entrance.
--
-- Plot-local frame (the shell's): front = -Z, y = 0 at the bottom of the
-- base, story s floor at 1 + 16(s-1), roof deck at 16S + 1; wall outer faces
-- at x = ±40.5, z = ±41.5. Nothing below the roof comes inside the carpet
-- (|x| <= 39.5, |z| <= 40.5).
-- Every part carries:
--   * "Story" (the cutaway hides stories above you; crown + roof are S+1)
--   * "ThemeSlot" where the owner's colours apply (walls, wallsDark, frame,
--     trim, neon): Buildings.applyTheme paints those
-- Decorative neon is NightLight (plain plastic by day) and only on the street
-- front: the cove lines (story 1 + top story), the pavilion pier reveals,
-- the crown line (front + short returns), the porte-cochère edge and the
-- penthouse door strip. Signs and chase bulbs always stay on.
-- Decor doesn't collide or take raycasts (K.part default) except what you can
-- walk into on the street (story-1 piers, pilasters, plinth and bases, the
-- porte-cochère columns); the porte-cochère deck never blocks the camera.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Config = require(Common:WaitForChild("Config"))
local Materials = require(Common:WaitForChild("Materials"))
local WP = require(Common:WaitForChild("WorldPalette"))
local UIAssets = require(Common:WaitForChild("UIAssets"))
local MachineModels = require(script.Parent:WaitForChild("MachineModels"))

local Facade = {}

local K = MachineModels.Kit
local P = MachineModels.Palette
local H = Config.Building.StoryHeight
local E = Config.Building.Elevator

local NAME_TAG = "CasinoNameLabel"
local NIGHT_TAG = "NightLight"
local BULB_CAP = 130    -- chase bulbs per building (MachineFX recolours them all)
local WASH_BEAMS = true -- story-1 light scallops up the piers after dark

-- colours with no WorldPalette entry (they aren't architecture)
local LANTERN_GLASS = Color3.fromRGB(214, 196, 160)
local LANTERN_DAY = Color3.fromRGB(122, 106, 90) -- the glow panel, seen through the glass by day
local LANTERN_NIGHT = Color3.fromRGB(150, 100, 48)
local DECK_WOOD = Color3.fromRGB(138, 90, 58)
local POOL_WATER = Color3.fromRGB(63, 200, 255)
local PALM_TRUNK = Color3.fromRGB(122, 90, 62)
local PALM_FROND = Color3.fromRGB(47, 143, 62)
-- the VIP lounge: gold neon (whatever the owner's neon colour) + a purple velvet sign
local VIP_NEON = Color3.fromRGB(255, 204, 92)
local VIP_NEON_DAY = Color3.fromRGB(150, 114, 52)
local VIP_PLATE = Color3.fromRGB(96, 30, 140)

-- front x datums, mirrored about x = 0 (the rest derive from the plot size)
local DOOR = 10                 -- clear entrance |x| < 10, y 1 .. 11.5
local PAV0, PAV1 = 10.25, 15.25 -- pavilion piers flanking the entrance
local PIL_W = 3                 -- front pilasters
local WIN_W, SHOP_W = 6.5, 7.75 -- shaft windows / story-1 storefronts
local CENTRE = 7.5              -- half width of the shaft's centre window
local SIDE_PILASTERS = { -19, 0, 19 }
-- how far each member stands proud of its wall face. Members that meet never
-- share a value, so no two faces are coplanar.
local PROUD = {
	pav = 1.4, corner = 1.3, belt = 1.2, course = 1.0, pil = 0.8, corona = 1.8, mould = 2.0,
	cornerSide = 0.7, sideCourse = 0.6, sidePil = 0.5, sidePlinth = 0.4, sideSill = 0.3,
}

-- what each kind of decor is made of: a Materials key + the ThemeSlot that
-- colours it (applyTheme), or a fixed WorldPalette paint
local KINDS = {
	walls = { mat = "Stucco", slot = "walls" },             -- the owner's colour
	dark = { mat = "Stucco", slot = "wallsDark" },          -- the owner's colour, darker
	stone = { mat = "Stucco", slot = "frame" },             -- courses, cornice, hoods (joint-free)
	ashlar = { mat = "Ashlar", slot = "frame" },            -- the big piers only (faces >= 4x4)
	trim = { mat = "Brass", slot = "trim" },                -- the owner's metal
	granite = { paint = "HonedStone", color = WP.Granite }, -- the base
	gold = { paint = "Brass", color = WP.Brass },           -- the VIP lounge: gold whatever the owner's trim
}

local SOLID = { solid = true }
local FLAT = { shadow = false } -- thin decor casts no shadow

------------------------------------------------------------------
-- helpers
------------------------------------------------------------------
local function tag(p: Instance, story: number, slot: string?)
	p:SetAttribute("Story", story)
	if slot then p:SetAttribute("ThemeSlot", slot) end
	return p
end

local function brassify(p: BasePart): BasePart
	Materials.apply(p, "Brass")
	p.Reflectance = 0
	return p
end

-- a box from its plot-local extents (either order)
local function box(c, parent, story: number, slot: string?, name: string, x0, x1, y0, y1, z0, z1, color: Color3, opts)
	local size = Vector3.new(math.abs(x1 - x0), math.abs(y1 - y0), math.abs(z1 - z0))
	local p = K.part(parent, name, size, c.at((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2), color, opts)
	return tag(p, story, slot)
end

-- a box of one of the KINDS
local function piece(c, parent, story: number, kind: string, name: string, x0, x1, y0, y1, z0, z1, opts)
	local k = KINDS[kind]
	local p = box(c, parent, story, k.slot, name, x0, x1, y0, y1, z0, z1, k.color or WP.Stone, opts)
	if k.paint then
		Materials.paint(p, k.paint, k.color)
	else
		Materials.apply(p, k.mat)
	end
	return p
end

-- decorative neon in the owner's colour: a dim plain strip by day
-- (applyTheme writes its DayColor / NightColor)
local function neonBox(c, parent, story: number, name: string, x0, x1, y0, y1, z0, z1)
	local p = box(c, parent, story, "neon", name, x0, x1, y0, y1, z0, z1, WP.Magenta, FLAT)
	p.Material = Enum.Material.Neon
	p:SetAttribute("DayMaterial", "SmoothPlastic")
	p:SetAttribute("NightMaterial", "Neon")
	CollectionService:AddTag(p, NIGHT_TAG)
	return p
end

-- a lamp lens / glow panel with fixed colours: Neon `night` after dark,
-- plain `day` plastic by day (built in the current state)
local function lamp(p: BasePart, night: Color3, day: Color3, lit: boolean): BasePart
	p:SetAttribute("DayMaterial", "SmoothPlastic")
	p:SetAttribute("NightMaterial", "Neon")
	p:SetAttribute("DayColor", day)
	p:SetAttribute("NightColor", night)
	p.Material = lit and Enum.Material.Neon or Enum.Material.SmoothPlastic
	p.Color = lit and night or day
	CollectionService:AddTag(p, NIGHT_TAG)
	return p
end

-- the VIP lounge's decorative neon: gold, a dim strip by day
local function vipNeonBox(c, parent, story: number, name: string, x0, x1, y0, y1, z0, z1)
	return lamp(box(c, parent, story, nil, name, x0, x1, y0, y1, z0, z1, VIP_NEON, FLAT), VIP_NEON, VIP_NEON_DAY, c.lit)
end

-- a light / beam that only runs after dark (DayNightFX switches it)
local function nightOnly(inst: Instance, lit: boolean)
	(inst :: any).Enabled = lit
	CollectionService:AddTag(inst, NIGHT_TAG)
	return inst
end

-- a row of chase bulbs between two plot-local points, into the building's
-- Bulbs folder (MachineFX chases them); never more than BULB_CAP in all
local function bulbRow(c, story: number, a: Vector3, b: Vector3, count: number, d: number)
	count = math.min(count, BULB_CAP - c.bulbCount)
	if count < 1 then return end
	c.bulbCount += count
	K.bulbsAlong(c.bulbs, c.at(a.X, a.Y, a.Z).Position, c.at(b.X, b.Y, b.Z).Position, count, d)
	for _, bulb in c.bulbs:GetChildren() do
		if bulb:GetAttribute("Story") == nil then bulb:SetAttribute("Story", story) end
	end
end

-- the casino's name on a crimson brand plate with gold letters, on the
-- part's front face (Buildings.refreshName writes every CasinoNameLabel)
local function nameSign(part: BasePart, ppu: number, brightness: number)
	local g = K.surface(part, Enum.NormalId.Front, ppu, 0)
	pcall(function() g.Brightness = brightness end)
	local plate = K.signPlate(g, P.CrimsonDeep)
	local label = K.guiText(plate, "OPEN PLOT", { size = UDim2.fromScale(0.92, 0.7), position = UDim2.fromScale(0.04, 0.15),
		gradient = { P.GoldTop, P.Gold }, strokeThickness = 4 })
	CollectionService:AddTag(label, NAME_TAG)
	return label
end

-- a soft scallop of light up a pier's street face after dark: a Beam between
-- two attachments 0.05 off the face. The attachments' X axis is the face
-- normal, so the ribbon lies flat on the face (if it ever shows edge-on,
-- swap the axis or set WASH_BEAMS = false). Lives in the pier part, so the
-- cutaway hides it with that part.
local function wash(part: BasePart, ya: number, yb: number, cy: number, lit: boolean)
	local function anchor(name: string, y: number)
		return K.new("Attachment", {
			Name = name,
			CFrame = CFrame.fromMatrix(Vector3.new(0, y - cy, -part.Size.Z / 2 - 0.05), Vector3.new(0, 0, -1), Vector3.yAxis),
		}, part)
	end
	local w = part.Size.X
	local beam = K.new("Beam", {
		Name = "Wash", Attachment0 = anchor("WashFrom", ya), Attachment1 = anchor("WashTo", yb),
		Width0 = w * 0.7, Width1 = w, FaceCamera = false, Segments = 1, Texture = "",
		LightEmission = 1, LightInfluence = 0, Color = ColorSequence.new(WP.Sodium),
		Transparency = NumberSequence.new(0.45, 1),
	}, part)
	beam:SetAttribute("Story", part:GetAttribute("Story"))
	return nightOnly(beam, lit)
end

-- pivot a model built around its origin, parent it, place it
local function placeModel(m: Model, parent: Instance, cf: CFrame): Model
	m.WorldPivot = CFrame.new()
	local primary = m.PrimaryPart
	if primary then primary.PivotOffset = primary.CFrame:Inverse() end
	m.Parent = parent
	m:PivotTo(cf)
	return m
end

------------------------------------------------------------------
-- one story's facade: the street front, both sides and the back
------------------------------------------------------------------
local function buildStory(c, s: number)
	local f = c.folder(s)
	local base = s == 1
	local fy = 1 + H * (s - 1)        -- this story's floor
	local y0 = base and 0 or fy       -- story-1 members start at the ground
	local top = fy + H                -- the next floor (or the roof deck)
	local solid = base and SOLID or nil
	local fx, fz, zF = c.fx, c.fz, -c.fz
	local wy0, wy1 = fy + 3, fy + 10  -- the shell's glass band
	local half = (base and SHOP_W or WIN_W) / 2
	local py0, py1 = base and 3.2 or fy, base and 14.5 or fy + 14.7 -- pilasters stop under the course
	-- the VIP lounge (never story 1): brass where the shaft has stone, gold pier neon
	local vip = s == c.vip
	local dress = vip and "gold" or "stone"
	local metal = vip and "gold" or "trim"

	for _, sx in { -1, 1 } do
		-- corner pier: a block on the front + a return on the side
		local corner = piece(c, f, s, "ashlar", "CornerPier", sx * c.cor0, sx * c.cor1, y0, top, zF - PROUD.corner, zF, solid)
		piece(c, f, s, "ashlar", "CornerPierSide", sx * fx, sx * c.cor1, y0, top, zF, zF + 5, solid)
		-- pavilion pier beside the entrance, with a neon reveal up its face
		local pav = piece(c, f, s, "ashlar", "PavilionPier", sx * PAV0, sx * PAV1, y0, top, zF - PROUD.pav, zF, solid)
		local nx, nz0, nz1 = sx * (PAV0 + PAV1) / 2, zF - PROUD.pav - 0.15, zF - PROUD.pav + 0.05
		if base then
			-- under the porte-cochère, then on above its deck
			neonBox(c, f, s, "PierNeon", nx - 0.2, nx + 0.2, 3.6, 12.3, nz0, nz1)
			neonBox(c, f, s, "PierNeon", nx - 0.2, nx + 0.2, 14.8, top, nz0, nz1)
			if WASH_BEAMS then
				wash(pav, 3.4, 12.3, top / 2, c.lit)
				wash(corner, 3.4, 16.8, top / 2, c.lit)
			end
		else
			local glow = vip and vipNeonBox or neonBox
			glow(c, f, s, "PierNeon", nx - 0.2, nx + 0.2, fy, top, nz0, nz1)
		end

		-- stucco pilaster with a brass capital
		piece(c, f, s, "walls", "Pilaster", sx * c.pil0, sx * c.pil1, py0, py1, zF - PROUD.pil, zF, solid)
		piece(c, f, s, "trim", "Capital", sx * (c.pil0 - 0.3), sx * (c.pil1 + 0.3), py1, py1 + 0.5, zF - 0.95, zF, FLAT)

		-- the shell's glass band is one long pane: owner stucco fills it flush
		-- between the windows (running on behind the piers)
		for _, span in { { base and DOOR or CENTRE, c.aMid - half }, { c.aMid + half, c.bMid - half }, { c.bMid + half, fx } } do
			piece(c, f, s, "walls", "WindowJamb", sx * span[1], sx * span[2], wy0, wy1, zF, zF + 0.45)
		end
		for _, mx in { c.aMid, c.bMid } do
			local wx = sx * mx
			piece(c, f, s, metal, "Mullion", wx - 0.2, wx + 0.2, wy0, wy1, zF + 0.1, zF + 0.4, FLAT)
			if not base then
				-- brass sill under, stone hood over every shaft window
				piece(c, f, s, metal, "Sill", wx - half - 0.4, wx + half + 0.4, fy + 2.65, fy + 3.05, zF - 0.45, zF + 0.35, FLAT)
				piece(c, f, s, dress, "Hood", wx - half - 0.6, wx + half + 0.6, wy1, wy1 + 0.6, zF - 0.6, zF, FLAT)
			end
		end

		-- side elevation: stucco pilasters, a sill band, the course wrapping round
		local x0 = sx * fx
		for _, pz in SIDE_PILASTERS do
			piece(c, f, s, "walls", "SidePilaster", x0, sx * (fx + PROUD.sidePil), base and 3.2 or fy, base and 15 or fy + 15.2,
				pz - 1.5, pz + 1.5, solid)
		end
		if base then
			piece(c, f, s, "granite", "SidePlinth", x0, sx * (fx + PROUD.sidePlinth), 0, 3.2, -(fz - 5.3), fz - 4.9, SOLID)
		else
			piece(c, f, s, dress, "SideSill", x0, sx * (fx + PROUD.sideSill), fy + 2.6, fy + 3, -(fz - 5), fz - 5, FLAT)
		end
		piece(c, f, s, base and "dark" or "stone", "SideCourse", x0, sx * (fx + PROUD.sideCourse), base and 15 or fy + 15.2, top,
			-fz, fz)
		-- back corner pier
		piece(c, f, s, "ashlar", "CornerPier", sx * c.cor0, sx * c.cor1, y0, top, fz, fz + PROUD.cornerSide, solid)
		piece(c, f, s, "ashlar", "CornerPierSide", x0, sx * c.cor1, y0, top, fz - 5, fz, solid)
	end

	-- the shaft's centre bay over the entrance: a 15-wide window of 4 lights
	-- under a stone hood, and a balconette with a brass rail
	if not base then
		for _, mx in { -CENTRE / 2, 0, CENTRE / 2 } do
			piece(c, f, s, metal, "Mullion", mx - 0.2, mx + 0.2, wy0, wy1, zF + 0.1, zF + 0.4, FLAT)
		end
		piece(c, f, s, dress, "Hood", -(CENTRE + 0.9), CENTRE + 0.9, wy1, wy1 + 0.6, zF - 0.6, zF, FLAT)
		piece(c, f, s, "stone", "Balcony", -(PAV0 + 0.05), PAV0 + 0.05, fy, fy + 0.5, zF - 2, zF)
		piece(c, f, s, vip and "gold" or "walls", "Balustrade", -(PAV0 + 0.05), PAV0 + 0.05, fy + 0.5, fy + 2.6, zF - 2, zF - 1.7)
		piece(c, f, s, "trim", "BalconyRail", -(PAV0 + 0.05), PAV0 + 0.05, fy + 2.6, fy + 2.85, zF - 2.05, zF - 1.65, FLAT)
	end

	-- the course that tops the story, a drip lip along its front edge, and on
	-- story 1 / the top story a cove light tucked behind that lip so it washes
	-- the wall instead of reading as a line from across the street. Story 1
	-- gets the deeper belt course in the owner's darker shade (so a 1-story
	-- casino still wears its colour under the stone cornice); above, stone.
	local xc = fx + 0.6
	local cy0 = base and 15 or fy + 15.2
	local p = base and PROUD.belt or PROUD.course
	local courseKind = base and "dark" or "stone"
	piece(c, f, s, courseKind, base and "BeltCourse" or "StringCourse", -xc, xc, cy0, top, zF - p, zF)
	piece(c, f, s, courseKind, "CourseLip", -xc, xc, cy0 - (base and 0.4 or 0.35), cy0, zF - p, zF - p + 0.2, FLAT)
	piece(c, f, s, courseKind, "BackCourse", -xc, xc, cy0, top, fz, fz + PROUD.sideCourse)
	if base or s == c.S then
		local cove = vip and vipNeonBox or neonBox -- (gold under the VIP lounge's cornice)
		cove(c, f, s, "CoveNeon", -(c.cor0 + 0.05), c.cor0 + 0.05, cy0 - 0.25, cy0, zF - 0.45, zF - 0.25)
	end
	if base then
		piece(c, f, s, "granite", "BackPlinth", -(c.cor0 + 0.1), c.cor0 + 0.1, 0, 3.2, fz, fz + PROUD.sidePlinth, SOLID)
	end
end

------------------------------------------------------------------
-- story 1: plinth, door, uplights
------------------------------------------------------------------
local function buildBase(c)
	local f = c.folder(1)
	local fx, zF = c.fx, -c.fz
	for _, sx in { -1, 1 } do
		-- dark granite plinth along the storefronts with a brass cap
		piece(c, f, 1, "granite", "Plinth", sx * PAV1, sx * c.cor0, 0, 3.2, zF - 0.6, zF, SOLID)
		piece(c, f, 1, "trim", "PlinthCap", sx * (PAV1 - 0.05), sx * (c.cor0 + 0.05), 3.2, 3.6, zF - 0.85, zF, FLAT)
		-- granite bases, a little prouder and wider than their piers
		piece(c, f, 1, "granite", "PierBase", sx * (PAV0 - 0.25), sx * (PAV1 + 0.3), 0, 3.2, zF - PROUD.pav - 0.2, zF, SOLID)
		piece(c, f, 1, "granite", "PierBase", sx * (c.cor0 - 0.3), sx * (c.cor1 + 0.3), 0, 3.2, zF - PROUD.corner - 0.2, zF, SOLID)
		piece(c, f, 1, "granite", "PierBase", sx * fx, sx * (c.cor1 + 0.2), 0, 3.2, zF, zF + 5.3, SOLID)
		piece(c, f, 1, "granite", "PilasterBase", sx * (c.pil0 - 0.3), sx * (c.pil1 + 0.3), 0, 3.2, zF - PROUD.pil - 0.2, zF, SOLID)
		-- brass band over the storefronts
		piece(c, f, 1, "trim", "HeadBand", sx * (PAV1 - 0.05), sx * (c.cor0 + 0.05), 11, 11.4, zF - 0.3, zF, FLAT)
		-- brass jambs line the door reveal, from the pier face to (just short
		-- of) the inner wall face
		piece(c, f, 1, "trim", "DoorJamb", sx * (DOOR - 0.05), sx * (PAV0 + 0.05), 0.8, 11.45, zF - PROUD.pav - 0.05, zF + 0.95)
	end
	piece(c, f, 1, "trim", "DoorHead", -(PAV0 + 0.05), PAV0 + 0.05, 11.45, 11.95, zF - 0.2, zF + 0.95)
	piece(c, f, 1, "trim", "Threshold", -(DOOR - 0.05), DOOR - 0.05, 0.8, 1, zF, zF + 1, FLAT)

	-- 4 uplights on the walk wash the pavilion + corner piers after dark
	for _, spot in { { (PAV0 + PAV1) / 2, zF - PROUD.pav - 0.9 }, { c.corMid, zF - PROUD.corner - 0.8 } } do
		for _, sx in { -1, 1 } do
			-- tilted 6° toward the wall
			local cf = c.at(sx * spot[1], 1.05, spot[2]) * CFrame.Angles(math.rad(6), 0, 0)
			brassify(tag(K.part(f, "Uplight", Vector3.new(1, 0.5, 0.8), cf, WP.Brass, { shadow = false }), 1, "trim"))
			local lens = tag(K.part(f, "UplightLens", Vector3.new(0.7, 0.06, 0.5), cf * CFrame.new(0, 0.28, 0), WP.WarmNeon,
				{ shadow = false }), 1, nil)
			lamp(lens, WP.WarmNeon, WP.DarkMetal, c.lit)
			nightOnly(K.new("SpotLight", { Face = Enum.NormalId.Top, Angle = 28, Range = 22, Brightness = 2.5,
				Color = WP.Sodium, Shadows = false }, lens), c.lit)
		end
	end
end

------------------------------------------------------------------
-- the porte-cochère over the entrance + the street name sign
------------------------------------------------------------------
local function buildCanopy(c)
	local f, S = c.folder(1), c.S
	local zF = -c.fz
	local zFront = zF - 8 -- the deck's street edge
	-- brass fascia; on a 1-story casino it's taller and carries the name
	local fy0, fy1 = 12.3, 14.9
	if S == 1 then fy0, fy1 = 12.1, 15.5 end

	-- deck + fascia never collide or take raycasts (the camera stays out)
	piece(c, f, 1, "walls", "CanopyDeck", -17, 17, 12.5, 14.7, zFront, zF)
	local fascia = piece(c, f, 1, "trim", "CanopyFascia", -17.4, 17.4, fy0, fy1, zFront - 0.4, zFront)
	for _, sx in { -1, 1 } do
		piece(c, f, 1, "trim", "CanopyFascia", sx * 17, sx * 17.4, fy0, fy1, zFront, zF)
	end
	neonBox(c, f, 1, "CanopyNeon", -17.4, 17.4, fy1, fy1 + 0.25, zFront - 0.35, zFront - 0.1)

	-- warm soffit: brass coffers, pot lights and one always-on light
	local soffit = box(c, f, 1, nil, "CanopySoffit", -16.5, 16.5, 12.4, 12.5, zFront + 0.4, zF - 0.4, WP.Soffit, FLAT)
	K.new("SurfaceLight", { Face = Enum.NormalId.Bottom, Angle = 90, Range = 14, Brightness = 1.4, Color = WP.Interior,
		Shadows = false }, soffit)
	for _, cz in { zFront + 2.8, zFront + 5.2 } do
		piece(c, f, 1, "trim", "Coffer", -16.5, 16.5, 12.1, 12.4, cz - 0.15, cz + 0.15, FLAT)
	end
	for _, cx in { -12, -4, 4, 12 } do
		piece(c, f, 1, "trim", "Coffer", cx - 0.15, cx + 0.15, 12.15, 12.4, zFront + 0.4, zF - 0.4, FLAT)
	end
	for _, spot in { { -14.25, 4 }, { -8, 4 }, { 0, 4 }, { 8, 4 }, { 14.25, 4 }, { -8, 1.6 }, { 0, 1.6 }, { 8, 1.6 } } do
		local dot = K.cylY(f, "PotLight", 0.7, 0.17, c.at(spot[1], 12.335, zFront + spot[2]).Position, WP.WarmNeon, { shadow = false })
		lamp(tag(dot, 1, nil), WP.WarmNeon, WP.Ivory, c.lit)
	end

	-- brass columns on granite bases (these collide)
	for _, sx in { -1, 1 } do
		local cx, cz = sx * 15.5, zFront + 1.5
		piece(c, f, 1, "granite", "ColumnBase", cx - 1.3, cx + 1.3, 0.8, 2, cz - 1.3, cz + 1.3, SOLID)
		brassify(tag(K.cylY(f, "Column", 1.6, 9.8, c.at(cx, 6.9, cz).Position, WP.Brass, { solid = true }), 1, "trim"))
		piece(c, f, 1, "trim", "ColumnCap", cx - 1.2, cx + 1.2, 11.8, 12.4, cz - 1.2, cz + 1.2, FLAT)
	end

	-- the name: flat on the fascia (1 story) or a standing board on the deck
	local bz = zFront - 0.45 -- bulbs on the fascia face
	if S == 1 then
		nameSign(fascia, 25, 1.7)
		for _, y in { fy0 + 0.3, fy1 - 0.3 } do
			bulbRow(c, 1, Vector3.new(-16.8, y, bz), Vector3.new(16.8, y, bz), 22, 0.45)
		end
	else
		piece(c, f, 1, "trim", "NameSignFrame", -14.3, 14.3, 14.4, 19.6, zFront + 0.65, zFront + 1.15)
		local board = box(c, f, 1, nil, "NameSign", -14, 14, 14.7, 19.3, zFront + 0.1, zFront + 0.9, P.CrimsonDeep)
		nameSign(board, 25, 1.7)
		bulbRow(c, 1, Vector3.new(-16.8, 13.6, bz), Vector3.new(16.8, 13.6, bz), 22, 0.45)
		-- straddling the board's top front edge (like the roof sign's bulbs)
		bulbRow(c, 1, Vector3.new(-13.8, 19.3, zFront + 0.05), Vector3.new(13.8, 19.3, zFront + 0.05), 18, 0.45)
	end
	local ym = (fy0 + fy1) / 2
	for _, sx in { -1, 1 } do
		bulbRow(c, 1, Vector3.new(sx * 17.45, ym, zFront + 1), Vector3.new(sx * 17.45, ym, zF - 1.5), 4, 0.45)
	end
end

------------------------------------------------------------------
-- the crown (story S + 1): cornice, parapet, pier tops, attic + roof sign
------------------------------------------------------------------
-- one member round all 4 sides, from p0 to p1 proud of the walls (the
-- front and back runs carry the corners)
local function ring(c, f, s: number, kind: string, name: string, y0: number, y1: number, p0: number, p1: number, opts)
	local fx, fz = c.fx, c.fz
	piece(c, f, s, kind, name, -(fx + p1), fx + p1, y0, y1, -fz - p1, -fz - p0, opts)
	piece(c, f, s, kind, name, -(fx + p1), fx + p1, y0, y1, fz + p0, fz + p1, opts)
	for _, sx in { -1, 1 } do
		piece(c, f, s, kind, name, sx * (fx + p0), sx * (fx + p1), y0, y1, -(fz + p0), fz + p0, opts)
	end
end

local function buildCrown(c)
	local f, s, R = c.roof, c.S + 1, c.roofY
	local fx, fz, zF = c.fx, c.fz, -c.fz

	-- cornice: stone corona, a brass crown moulding along its outer edge (a
	-- lip: from above the roof reads stone, not a gold rim)
	ring(c, f, s, "stone", "Corona", R, R + 1.4, 0, PROUD.corona)
	ring(c, f, s, "trim", "CrownMoulding", R + 1.4, R + 1.8, PROUD.mould - 0.5, PROUD.mould, FLAT)
	-- the crown's neon line: the street face + 6-stud returns, nothing more
	local xn, zn = fx + PROUD.mould - 0.05, zF - PROUD.mould + 0.05
	neonBox(c, f, s, "CrownNeon", -xn, xn, R + 1.8, R + 2.05, zn, zn + 0.25)
	for _, sx in { -1, 1 } do
		neonBox(c, f, s, "CrownNeon", sx * (xn - 0.25), sx * xn, R + 1.8, R + 2.05, zn + 0.25, zn + 6.25)
	end

	-- stucco parapet on the wall line (0.1 proud of the walls), a slim brass
	-- coping
	local px, pz = fx + 0.1, fz + 0.1
	for _, sz in { -1, 1 } do
		piece(c, f, s, "walls", "Parapet", -px, px, R + 1, R + 4.4, sz * pz, sz * (pz - 1.2))
		piece(c, f, s, "trim", "ParapetCap", -(px + 0.1), px + 0.1, R + 4.4, R + 4.8, sz * (pz + 0.1), sz * (pz - 1.3), FLAT)
	end
	for _, sx in { -1, 1 } do
		piece(c, f, s, "walls", "Parapet", sx * px, sx * (px - 1.2), R + 1, R + 4.4, -(pz - 1.2), pz - 1.2)
		piece(c, f, s, "trim", "ParapetCap", sx * (px + 0.1), sx * (px - 1.3), R + 4.4, R + 4.8, -(pz - 1.3), pz - 1.3, FLAT)
	end

	-- the 4 corner piers rise above the parapet: brass cap + ball finial
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			local z0, z1 = zF - PROUD.corner, zF + 5
			if sz > 0 then z0, z1 = fz - 5, fz + PROUD.cornerSide end
			piece(c, f, s, "ashlar", "CornerPierTop", sx * c.cor0, sx * c.cor1, R, R + 6.5, z0, z1)
			piece(c, f, s, "trim", "CornerPierCap", sx * (c.cor0 - 0.3), sx * (c.cor1 + 0.3), R + 6.5, R + 7, z0 - 0.3, z1 + 0.3, FLAT)
			local ball = K.ball(f, "Finial", 1.8, c.at(sx * c.corMid, R + 7.85, (z0 + z1) / 2).Position, WP.Brass, { shadow = false })
			brassify(tag(ball, s, "trim"))
		end
	end

	-- pavilion attic: the entrance piers rise above the roof and carry the
	-- roof sign; a darker attic wall backs it
	for _, sx in { -1, 1 } do
		piece(c, f, s, "ashlar", "AtticPier", sx * PAV0, sx * PAV1, R, R + 12.5, zF - PROUD.pav, zF + 2.6)
		piece(c, f, s, "trim", "AtticPierCap", sx * (PAV0 - 0.3), sx * (PAV1 + 0.3), R + 12.5, R + 13, zF - PROUD.pav - 0.3, zF + 2.9, FLAT)
		local ball = K.ball(f, "Finial", 1.4, c.at(sx * (PAV0 + PAV1) / 2, R + 13.6, zF + 0.6).Position, WP.Brass, { shadow = false })
		brassify(tag(ball, s, "trim"))
	end
	piece(c, f, s, "dark", "AtticWall", -(PAV0 + 0.05), PAV0 + 0.05, R + 1, R + 9.6, zF - 1.3, zF + 1.6)
	piece(c, f, s, "trim", "AtticCap", -(PAV0 + 0.05), PAV0 + 0.05, R + 9.6, R + 10, zF - 1.5, zF + 1.8, FLAT)

	-- the roof name sign: crimson brand plate, gold letters, a bulb frame,
	-- mounted on the attic piers' faces; the crown icon above it
	local sw, sy0, sy1 = PAV1, R + 3.4, R + 10.4
	local sz0, sz1 = zF - 2.6, zF - 1.8
	piece(c, f, s, "trim", "RoofSignFrame", -(sw + 0.4), sw + 0.4, sy0 - 0.4, sy1 + 0.4, sz1 - 0.1, zF - PROUD.pav + 0.05)
	local sign = box(c, f, s, nil, "RoofSign", -sw, sw, sy0, sy1, sz0, sz1, P.CrimsonDeep)
	nameSign(sign, 16, 2)
	-- the bulbs straddle the sign's edges, just proud of its face (about 1.7
	-- apart all round, the corners included)
	local bz = sz0 - 0.05
	bulbRow(c, s, Vector3.new(-sw - 0.15, sy1, bz), Vector3.new(sw + 0.15, sy1, bz), 19, 0.55)
	bulbRow(c, s, Vector3.new(-sw - 0.15, sy0, bz), Vector3.new(sw + 0.15, sy0, bz), 19, 0.55)
	for _, sx in { -1, 1 } do
		bulbRow(c, s, Vector3.new(sx * (sw + 0.15), sy0 + 1.75, bz), Vector3.new(sx * (sw + 0.15), sy1 - 1.75, bz), 3, 0.55)
	end
	local crown = box(c, f, s, nil, "CrownIcon", -2.3, 2.3, R + 11.4, R + 16, zF - 2.25, zF - 2.15, P.White,
		{ transparency = 1, shadow = false })
	local cg = K.surface(crown, Enum.NormalId.Front, 50, 0)
	pcall(function() cg.Brightness = 1.8 end)
	K.guiImage(cg, "crown", { size = UDim2.fromScale(1, 1) })
end

------------------------------------------------------------------
-- the roof kit (story S + 1). Fixed spots, clear of each other:
--   lantern |x|,|z| <= 8.5 · penthouse x 25.5..36.5, z 26.5..37.5 ·
--   HVAC x 1..23, z 30.5..35.5 · walkway x 29.5..32.5, z -10..26.25 ·
--   attic + sign z <= -38.9 · corner pier tops |x| >= 37.2
------------------------------------------------------------------
local function buildRoofKit(c)
	local f, s = c.roof, c.S + 1
	local yR = c.roofY + 1 -- the roof deck's top

	-- atrium lantern: a brass curb and a glass gable with a glow panel inside
	-- (only the panel switches at night)
	piece(c, f, s, "trim", "LanternCurb", -8.5, 8.5, yR, yR + 0.8, -8.5, 8.5)
	for _, sz in { -1, 1 } do
		-- a wedge is full height at its +Z end: the back half is turned round
		local cf = c.at(0, yR + 2.4, sz * 4) * CFrame.Angles(0, sz > 0 and math.pi or 0, 0)
		tag(K.new("WedgePart", {
			Name = "LanternGlass", Anchored = true, Size = Vector3.new(16, 3.2, 8), CFrame = cf, Color = LANTERN_GLASS,
			Material = Enum.Material.SmoothPlastic, Transparency = 0.25, CanCollide = false, CanQuery = false,
			CanTouch = false, CastShadow = false, TopSurface = Enum.SurfaceType.Smooth, BottomSurface = Enum.SurfaceType.Smooth,
		}, f), s, nil)
	end
	piece(c, f, s, "trim", "LanternRidge", -8.2, 8.2, yR + 4, yR + 4.3, -0.3, 0.3, FLAT)
	lamp(box(c, f, s, nil, "LanternGlow", -6.5, 6.5, yR + 0.85, yR + 1.15, -6.5, 6.5, LANTERN_DAY, FLAT), LANTERN_NIGHT, LANTERN_DAY, c.lit)

	-- elevator penthouse over the shaft, its door toward the walkway
	local ex, ez = E.x, E.z
	piece(c, f, s, "dark", "Penthouse", ex - 5.5, ex + 5.5, yR, yR + 6, ez - 5.5, ez + 5.5)
	box(c, f, s, nil, "PenthouseDoor", ex - 1.5, ex + 1.5, yR, yR + 5, ez - 5.7, ez - 5.45, WP.Ink, FLAT)
	neonBox(c, f, s, "PenthouseNeon", ex - 1.8, ex + 1.8, yR + 5.25, yR + 5.55, ez - 5.75, ez - 5.45)
	piece(c, f, s, "stone", "PenthouseCap", ex - 5.8, ex + 5.8, yR + 6, yR + 6.4, ez - 5.8, ez + 5.8, FLAT)

	-- HVAC row behind the lantern, and a paver walkway to the penthouse
	for _, hx in { 4, 12, 20 } do
		box(c, f, s, nil, "HVAC", hx - 3, hx + 3, yR, yR + 3.5, 30.5, 35.5, WP.Curb)
		tag(K.cylY(f, "HVACFan", 3.6, 0.3, c.at(hx, yR + 3.65, 33).Position, WP.DarkMetal, { shadow = false }), s, nil)
	end
	Materials.paint(box(c, f, s, nil, "RoofWalkway", ex - 1.5, ex + 1.5, yR, yR + 0.1, -10, ez - 5.75, WP.Sidewalk, FLAT),
		"Pavers", WP.Sidewalk)
end

------------------------------------------------------------------
-- roof progression: a visible reward for every story bought
------------------------------------------------------------------
local function hedge(p: BasePart): BasePart
	-- the Hedge material has its leaf colours baked in (until its maps exist,
	-- plain Grass tinted lawn green)
	local baked = (Materials.Defs.Hedge or {}).color
	return Materials.paint(p, "Hedge", (baked == nil or baked == "") and WP.Lawn or nil)
end

local function palm(c, f, s: number, x: number, y: number, z: number)
	Materials.paint(tag(K.cylY(f, "PalmPot", 1.6, 1, c.at(x, y + 0.5, z).Position, WP.Granite), s, nil), "HonedStone", WP.Granite)
	tag(K.cylY(f, "PalmTrunk", 0.45, 5, c.at(x, y + 3.5, z).Position, PALM_TRUNK, { material = Enum.Material.Wood }), s, nil)
	local top = y + 6
	tag(K.ball(f, "PalmHeart", 0.9, c.at(x, top, z).Position, PALM_FROND), s, nil)
	for k = 0, 3 do
		-- fronds droop 25° from the crown
		local cf = c.at(x, top, z) * CFrame.Angles(0, math.rad(45 + k * 90), 0) * CFrame.Angles(math.rad(-25), 0, 0)
			* CFrame.new(0, 0, -1.6)
		tag(K.part(f, "PalmFrond", Vector3.new(0.9, 0.15, 3.2), cf, PALM_FROND, { shadow = false }), s, nil)
	end
end

-- 3+ stories: a pool deck on the street half of the roof (x 12..36 or
-- -36..-12, z -32..-16), mirrored on alternate plots
local function poolDeck(c, f, s: number, yR: number)
	local cx = ((c.plotIndex % 2 == 0) and -1 or 1) * 24
	local yD = yR + 0.4 -- the deck's top
	box(c, f, s, nil, "PoolDeck", cx - 12, cx + 12, yR, yD, -32, -16, DECK_WOOD, { material = Enum.Material.WoodPlanks })
	Materials.paint(box(c, f, s, nil, "PoolRim", cx - 9, cx + 9, yD, yD + 0.4, -28.5, -19.5, WP.Ivory), "SmoothConcrete", WP.Ivory)
	box(c, f, s, nil, "PoolWater", cx - 8.5, cx + 8.5, yD + 0.15, yD + 0.45, -28, -20, POOL_WATER,
		{ transparency = 0.15, reflectance = 0.1, shadow = false })
	-- loungers along the back, facing the water
	for _, lx in { -6, -2, 2, 6 } do
		local x = cx + lx
		box(c, f, s, nil, "Lounger", x - 0.7, x + 0.7, yD, yD + 0.6, -19.25, -16.85, WP.Ivory)
		tag(K.part(f, "LoungerBack", Vector3.new(1.4, 0.25, 1.4), c.at(x, yD + 0.95, -16.6) * CFrame.Angles(math.rad(-40), 0, 0),
			WP.Ivory, { shadow = false }), s, nil)
	end
	-- umbrellas + a low hedge on the street side, palms at the back corners
	for _, ux in { -10.5, 10.5 } do
		local x = cx + ux
		local pole = K.cylY(f, "UmbrellaPole", 0.25, 4.2, c.at(x, yD + 2.1, -30.25).Position, WP.Brass, { shadow = false })
		Materials.paint(tag(pole, s, nil), "Brass", WP.Brass)
		tag(K.cylY(f, "Umbrella", 4.2, 0.3, c.at(x, yD + 4.3, -30.25).Position, WP.Lacquer), s, nil)
		palm(c, f, s, x, yD, -17.75)
	end
	Materials.paint(box(c, f, s, nil, "PoolPlanter", cx - 11.5, cx + 11.5, yD, yD + 0.8, -31.9, -31.1, WP.Granite),
		"HonedStone", WP.Granite)
	hedge(box(c, f, s, nil, "PoolHedge", cx - 11.3, cx + 11.3, yD + 0.8, yD + 1.4, -31.8, -31.2, WP.Lawn, FLAT))
end

-- a searchlight: MapProps' (ServerStorage.MapTools, loaded on first use), or
-- the same drum + lamp + sky beam built here if the map tools aren't in place
local mapProps -- false once we know it isn't reachable
local function searchlight(): Model
	if mapProps == nil then
		mapProps = false
		local ok, props = pcall(function()
			local tools = ServerStorage:FindFirstChild("MapTools")
			local module = tools and tools:FindFirstChild("MapProps")
			if not (module and module:IsA("ModuleScript")) then return nil end
			local mod = require(module)
			mod.init(MachineModels, UIAssets, Materials, WP)
			return mod
		end)
		if ok and props then mapProps = props end
	end
	if mapProps then
		local ok, m = pcall(mapProps.searchlight)
		if ok and m then return m end
	end
	local m = K.new("Model", { Name = "Searchlight" })
	K.cylY(m, "Drum", 4, 2.2, Vector3.new(0, 1.1, 0), WP.DarkMetal, { solid = true })
	Materials.paint(K.cylY(m, "DrumBand", 4.2, 0.3, Vector3.new(0, 2.3, 0), WP.Brass, { shadow = false }), "Brass", WP.Brass)
	K.cylY(m, "Lamp", 3, 3.4, Vector3.new(0, 4.1, 0), WP.Ivory, { shadow = false })
	K.cylY(m, "Lens", 2.6, 0.12, Vector3.new(0, 5.85, 0), WP.BulbB, { material = Enum.Material.Neon, shadow = false })
	-- the beam hangs off an unrotated helper so the client can sweep its tip
	local emitter = K.part(m, "Emitter", Vector3.new(0.4, 0.4, 0.4), CFrame.new(0, 5.95, 0), WP.Ivory,
		{ transparency = 1, shadow = false })
	local a0 = K.new("Attachment", { Name = "BeamFrom" }, emitter)
	local a1 = K.new("Attachment", { Name = "BeamTo", Position = Vector3.new(0, 700, 0) }, emitter)
	local beam = K.new("Beam", {
		Name = "Shaft", Attachment0 = a0, Attachment1 = a1, Width0 = 2, Width1 = 22, FaceCamera = true,
		LightEmission = 1, LightInfluence = 0, Segments = 1, Texture = "", Color = ColorSequence.new(WP.BulbB),
		Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.72), NumberSequenceKeypoint.new(0.45, 0.92),
			NumberSequenceKeypoint.new(1, 1) }),
	}, emitter)
	CollectionService:AddTag(beam, NIGHT_TAG)
	return m
end

-- 5 stories: a helipad on the back half (centre (-22, 26), r 11), a
-- windsock, and 2 searchlights sweeping the sky from the street corners
local function helipad(c, f, s: number, yR: number)
	local hx, hz = -22, 26
	local function disc(name: string, d: number, y0: number, y1: number, color: Color3)
		return tag(K.cylY(f, name, d, y1 - y0, c.at(hx, (y0 + y1) / 2, hz).Position, color, { shadow = false }), s, nil)
	end
	disc("Helipad", 22, yR, yR + 0.3, WP.DarkMetal)
	disc("HelipadRing", 19.6, yR + 0.3, yR + 0.36, WP.LaneWhite)
	disc("HelipadInner", 18.4, yR + 0.36, yR + 0.42, WP.DarkMetal)
	local mark = tag(K.flatPrint(f, "HelipadMark", 10, 10, c.at(hx, yR + 0.47, hz), WP.LaneWhite), s, nil)
	local g = K.surface(mark, Enum.NormalId.Top, 30, 0.6)
	K.guiText(g, "H", { color = WP.LaneWhite, stroke = false })

	local wx, wz = -36, 8
	tag(K.cylY(f, "WindsockPole", 0.25, 5, c.at(wx, yR + 2.5, wz).Position, WP.LaneWhite, { shadow = false }), s, nil)
	tag(K.part(f, "Windsock", Vector3.new(2.4, 0.7, 0.7), c.at(wx + 1.2, yR + 4.6, wz) * CFrame.Angles(0, 0, math.rad(-12)),
		WP.Amber, { shape = Enum.PartType.Cylinder, shadow = false }), s, nil)

	for _, sx in { -1, 1 } do
		local m = searchlight()
		for _, d in m:GetDescendants() do
			if d:IsA("BasePart") then
				tag(d, s, nil)
			elseif d:IsA("Beam") then
				nightOnly(d, c.lit)
			end
		end
		tag(m, s, nil)
		-- streams as one piece: MapFX drops a searchlight whose emitter goes
		pcall(function() m.ModelStreamingMode = Enum.ModelStreamingMode.Atomic end)
		placeModel(m, f, c.at(sx * 33, yR, -35))
		CollectionService:AddTag(m, "MapSearchlight")
	end
end

------------------------------------------------------------------
-- the VIP lounge's sign (c.vip, the top story): a purple velvet plate in a
-- brass frame over the centre window, between the hood and the string course
-- (clear of the pavilion piers at |x| >= 10.25), crowns at both ends, "VIP
-- LOUNGE" in gold, and chase bulbs straddling its top and bottom edges. Built
-- after the canopy and the roof sign, so their bulbs come first under the cap.
------------------------------------------------------------------
local function buildVipSign(c)
	local s = c.vip
	if not (s and s >= 2 and s <= c.S) then return end
	local f = c.folder(s)
	local fy = 1 + H * (s - 1)
	local zF = -c.fz
	local sw, y0, y1 = 9.4, fy + 10.95, fy + 14.6
	piece(c, f, s, "gold", "VipSignFrame", -(sw + 0.35), sw + 0.35, y0 - 0.3, y1 + 0.2, zF - 0.6, zF)
	local plate = box(c, f, s, nil, "VipSign", -sw, sw, y0, y1, zF - 0.85, zF - 0.6, VIP_PLATE, FLAT)
	local g = K.surface(plate, Enum.NormalId.Front, 20, 0)
	pcall(function() g.Brightness = 1.8 end)
	local back = K.signPlate(g, VIP_PLATE, P.Gold)
	for _, x in { 0.075, 0.925 } do
		K.guiImage(back, "crown", { size = UDim2.fromScale(0.12, 0.84), position = UDim2.fromScale(x, 0.5) })
	end
	K.guiText(back, "VIP LOUNGE", { size = UDim2.fromScale(0.72, 0.8), position = UDim2.fromScale(0.14, 0.1),
		gradient = { P.GoldTop, P.Gold }, strokeThickness = 4 })
	local bz = zF - 0.9
	for _, y in { y0, y1 } do
		bulbRow(c, s, Vector3.new(-sw + 0.3, y, bz), Vector3.new(sw - 0.3, y, bz), 12, 0.5)
	end
end

------------------------------------------------------------------
-- entry point
------------------------------------------------------------------
-- b: the Building model (its Story1..StoryS + Roof folders and the Bulbs
-- folder already made by Buildings). at(x, y, z): plot-local -> world CFrame.
-- ctx: { S, W, D, plotIndex, bulbs, roof, lit, vipStory } (lit = the lamps are
-- on now; vipStory = the VIP lounge's story, nil without one)
function Facade.build(b: Model, at, ctx)
	local S = ctx.S
	local fx, fz = ctx.W / 2 + 1, ctx.D / 2 + 1 -- wall outer faces
	local cor0, cor1 = fx - 3.3, fx + 0.7         -- corner piers: 4 wide on the front, 0.7 past the side wall
	local bay = (cor0 - PAV1 - PIL_W) / 2         -- the two window bays each side
	local c = {
		at = at, S = S, fx = fx, fz = fz, cor0 = cor0, cor1 = cor1, corMid = (cor0 + cor1) / 2,
		pil0 = PAV1 + bay, pil1 = PAV1 + bay + PIL_W,
		aMid = PAV1 + bay / 2, bMid = cor0 - bay / 2,
		roofY = S * H + 1, plotIndex = ctx.plotIndex or 1,
		bulbs = ctx.bulbs, bulbCount = 0, roof = ctx.roof or b, lit = ctx.lit == true,
		vip = tonumber(ctx.vipStory),
	}
	c.bulbCount = #ctx.bulbs:GetChildren()
	function c.folder(s: number): Instance
		return b:FindFirstChild("Story" .. s) or b
	end

	for s = 1, S do buildStory(c, s) end
	buildBase(c)
	buildCanopy(c)
	buildCrown(c)
	buildRoofKit(c)
	buildVipSign(c)
	local yR = c.roofY + 1
	if S >= 3 then poolDeck(c, c.roof, S + 1, yR) end
	if S >= 5 then helipad(c, c.roof, S + 1, yR) end

	-- the cutaway needs a story on every part: anything still without one
	-- takes the story its height falls in
	local frame = at(0, 0, 0)
	for _, d in b:GetDescendants() do
		if d:IsA("BasePart") and d:GetAttribute("Story") == nil then
			local y = frame:PointToObjectSpace(d.Position).Y
			d:SetAttribute("Story", math.clamp(math.floor((y - 1) / H) + 1, 1, S + 1))
		end
	end
end

return Facade
