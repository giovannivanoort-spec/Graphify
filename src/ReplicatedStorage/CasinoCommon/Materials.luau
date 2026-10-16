--!nonstrict
-- Materials.luau — the game's PBR materials: MaterialVariants under
-- MaterialService.CasinoMaterials. All but Asphalt are procedural textures from
-- tools/texgen/gen_textures.py: near-white, low-contrast maps whose repeating
-- unit is sized against a 5-stud avatar, so Part.Color decides the colour.
-- The uploaded image IDs (and each colour map's measured mean) live in the
-- generated MaterialIds.luau manifest.
--
-- Materials.ensure() creates/updates the variants. It can only run at edit
-- time (game scripts may not set texture maps): MapBuilder calls it, and the
-- place file keeps the result. Parts use them through:
--   Materials.apply(part, key)          -- material + variant, Color untouched
--   Materials.paint(part, key, target)  -- also tints so the part RENDERS as
--                                          `target` (a WorldPalette colour)

local MaterialService = game:GetService("MaterialService")
local RunService = game:GetService("RunService")

local Ids = require(script.Parent:WaitForChild("MaterialIds"))

local Materials = {}

local FOLDER = "CasinoMaterials"
local M, P = Enum.Material, Enum.MaterialPattern

-- base material, tiling pattern and studs per tile; maps come from Ids
Materials.Defs = {
	-- ground
	Asphalt = { base = M.Asphalt, pattern = P.Organic, spt = 16 },        -- AI-generated aggregate
	Pavers = { base = M.Pavement, pattern = P.Regular, spt = 8 },         -- 2x1-stud pavers, half bond
	PlazaTile = { base = M.Limestone, pattern = P.Regular, spt = 12 },    -- 3x3-stud slabs
	ConcreteSlab = { base = M.Concrete, pattern = P.Regular, spt = 64 },  -- 8x8-stud lot / city slabs
	SmoothConcrete = { base = M.Concrete, pattern = P.Organic, spt = 8 }, -- joint-free: curbs, rims
	-- buildings
	Stucco = { base = M.Plaster, pattern = P.Organic, spt = 8 },          -- wall fields (owner colour)
	Ashlar = { base = M.Limestone, pattern = P.Regular, spt = 16 },       -- 4x2-stud stone blocks
	RoofMembrane = { base = M.Concrete, pattern = P.Regular, spt = 32 },  -- 8-stud sheets
	Brass = { base = M.Metal, pattern = P.Regular, spt = 8 },             -- all world metal / trim
	PolishedTile = { base = M.Marble, pattern = P.Regular, spt = 16 },    -- 4x4-stud tiles, indoor
	HonedStone = { base = M.Granite, pattern = P.Regular, spt = 16 },     -- same tiles, matte: plinths
	Hedge = { base = M.Grass, pattern = P.Organic, spt = 6 },             -- colour baked in
	-- casino carpets (Config.Building.Carpets picks one per casino)
	CarpetCrimson = { base = M.Carpet, pattern = P.Regular, spt = 8 },
	CarpetRoyal = { base = M.Carpet, pattern = P.Regular, spt = 8 },
	CarpetEmerald = { base = M.Carpet, pattern = P.Regular, spt = 8 },
	CarpetBlackGold = { base = M.Carpet, pattern = P.Regular, spt = 8 },
	CarpetMidnight = { base = M.Carpet, pattern = P.Regular, spt = 8 },
	CarpetNeon = { base = M.Carpet, pattern = P.Regular, spt = 8 },
	CarpetChips = { base = M.Carpet, pattern = P.Regular, spt = 8 },
	CarpetRetro = { base = M.Carpet, pattern = P.Regular, spt = 8 },
}

-- loose images from the same generator (parking stalls, zebra crossings, tower
-- window maps ...): MaterialIds.Images[name] = "rbxassetid://..."
Materials.Images = Ids.Images or {}

for key, def in Materials.Defs do
	local ids = Ids[key] or {}
	def.color = ids.color or ""
	def.normal = ids.normal or ""
	def.roughness = ids.roughness or ""
	def.metalness = ids.metalness or ""
	def.mean = ids.mean or { 230, 230, 230 } -- the colour map's mean (0-255)
end

-- the MaterialVariant name for a key ("Pavers" -> "CM_Pavers")
function Materials.variantName(key: string): string
	return "CM_" .. key
end

-- the Part.Color that makes a part with this material render as `target`
-- (the texture multiplies Part.Color, so divide its mean back out)
function Materials.tint(key: string, target: Color3): Color3
	local m = (Materials.Defs[key] or {}).mean or { 255, 255, 255 }
	return Color3.new(
		math.min(1, target.R * 255 / m[1]),
		math.min(1, target.G * 255 / m[2]),
		math.min(1, target.B * 255 / m[3])
	)
end

-- material + variant only (the caller owns Color, e.g. owner theme colours)
function Materials.apply(part: BasePart, key: string)
	local def = Materials.Defs[key]
	if not def then return end
	part.Material = def.base
	part.MaterialVariant = Materials.variantName(key)
end

-- material + variant + the tint that renders as `target` (nil = the texture's
-- own colours, e.g. carpets and hedges)
function Materials.paint(part: BasePart, key: string, target: Color3?): BasePart
	Materials.apply(part, key)
	part.Color = target and Materials.tint(key, target) or Color3.new(1, 1, 1)
	part.Reflectance = 0
	return part
end

-- Create / update every variant (edit time only). Variants in the folder that
-- are no longer defined are removed. Returns how many it wrote.
function Materials.ensure(): number
	local ok, result = pcall(function()
		local folder = MaterialService:FindFirstChild(FOLDER)
		if not folder then
			folder = Instance.new("Folder")
			folder.Name = FOLDER
			folder.Parent = MaterialService
		end
		local keep = {}
		local n = 0
		for key, def in Materials.Defs do
			local name = Materials.variantName(key)
			keep[name] = true
			if def.color ~= "" then
				local mv = folder:FindFirstChild(name)
				if not mv then
					mv = Instance.new("MaterialVariant")
					mv.Name = name
				end
				mv.BaseMaterial = def.base
				mv.MaterialPattern = def.pattern
				mv.StudsPerTile = def.spt
				mv.ColorMap = def.color
				mv.NormalMap = def.normal
				mv.RoughnessMap = def.roughness
				mv.MetalnessMap = def.metalness
				mv.Parent = folder
				n += 1
			end
		end
		if RunService:IsStudio() and not RunService:IsRunning() then
			for _, child in folder:GetChildren() do
				if not keep[child.Name] then child:Destroy() end
			end
		end
		return n
	end)
	if not ok then
		warn("[Materials] couldn't create the variants here (edit time only): " .. tostring(result))
		return 0
	end
	return result
end

return Materials
