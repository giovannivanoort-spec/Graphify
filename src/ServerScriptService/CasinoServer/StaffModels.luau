--!nonstrict
-- StaffModels.luau — the look of every staff role, built ONCE at boot into
-- ReplicatedStorage.StaffTemplates (clients clone them; nothing here runs per
-- casino or per frame):
--   StaffTemplates/<staffId>   an R15 rig (Players:CreateHumanoidModelFromDescription,
--                              classic proportions, body colours = the uniform; a
--                              code-built R15 block rig if that call fails) dressed
--                              in code-built uniform pieces welded to the body parts
--                              (vest, lapels, bow tie, top hat, visor, badge, apron,
--                              hard hat, headset, mop, clipboard, mic ...), so each
--                              role reads at a glance. Attributes: StaffId,
--                              RoleName, Tone. Skin parts carry Skin = true and hair
--                              pieces Hair = true (the client varies them per person).
--   StaffTemplates/Props/<name> ValetPodium, Stage, WetFloorSign (pivot = ground
--                              centre, front = -Z)
-- Everything is non-colliding, non-queryable and massless; welds (not
-- anchoring) hold the uniform, so the R15 walk / idle animations move it along.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Config = require(Common:WaitForChild("Config"))

local StaffModels = {}

local FOLDER_NAME = "StaffTemplates"
local hex = Color3.fromHex
local rad = math.rad

local C = {
	Ink = hex("#2B0A12"), Black = hex("#1C1A21"), Jet = hex("#0E0D12"), Shoe = hex("#16131A"),
	Shirt = hex("#F6F2EA"), White = hex("#FBFAF7"), Gold = hex("#FFCB2E"), GoldDeep = hex("#E89A0C"),
	Crimson = hex("#D7263D"), CrimsonDeep = hex("#8E0F22"), Magenta = hex("#C2185B"), MagentaDeep = hex("#7E0F3B"),
	Pink = hex("#FF6FB5"), Navy = hex("#1F2A48"), NavyDeep = hex("#141C33"), Charcoal = hex("#3B3B47"),
	CharcoalDeep = hex("#26262F"), Burgundy = hex("#7A1E2C"), ValetRed = hex("#C9252E"), Overall = hex("#2C4F86"),
	ShirtBlue = hex("#9CC3E6"), HiVis = hex("#FF7A12"), Reflect = hex("#E3E8EE"), HardHat = hex("#FFD21F"),
	Purple = hex("#7B35C9"), Jeans = hex("#2F4C7E"), Leather = hex("#5A3218"), Chrome = hex("#D6DCE4"),
	Visor = hex("#2FBF71"), Rubber = hex("#F2C230"), MopGrey = hex("#C9C3B6"), Wood = hex("#8A5A2E"),
	SequinGold = hex("#E9B530"), Silver = hex("#A9ADB6"), Lacquer = hex("#2A0F16"),
}
local SKIN = { hex("#FFD3A8"), hex("#EDBB91"), hex("#C9956B"), hex("#A0704A"), hex("#6E4A30") }
local HAIR = { hex("#2B1B10"), hex("#54331C"), hex("#141014"), hex("#9A6332"), hex("#E2C27A"), hex("#9E9EA6") }

------------------------------------------------------------------
-- tiny kit
------------------------------------------------------------------
local function setPart(p: BasePart, color: Color3, opts)
	opts = opts or {}
	p.Color = color
	p.Material = opts.material or Enum.Material.SmoothPlastic
	p.Reflectance = opts.reflectance or 0
	p.Transparency = opts.transparency or 0
	p.Anchored = false
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Massless = true
	p.CastShadow = opts.shadow == true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
end

-- a uniform piece welded to one of the rig's parts (`offset` in that part's space)
local function piece(rig: Model, hostName: string, name: string, size: Vector3, offset: CFrame, color: Color3, opts)
	local host = rig:FindFirstChild(hostName)
	if not (host and host:IsA("BasePart")) then return nil end
	opts = opts or {}
	local p = Instance.new("Part")
	p.Name = name
	if opts.shape then p.Shape = opts.shape end
	p.Size = size
	setPart(p, color, opts)
	if opts.mesh then
		local m = Instance.new("SpecialMesh")
		m.MeshType = opts.mesh
		m.Parent = p
	end
	p.CFrame = host.CFrame * offset
	local w = Instance.new("Weld")
	w.Name = "UniformWeld"
	w.Part0 = host
	w.Part1 = p
	w.C0 = offset
	w.Parent = p
	if opts.hair then p:SetAttribute("Hair", true) end
	if opts.skin then p:SetAttribute("Skin", true) end
	p.Parent = rig:FindFirstChild("Uniform") or rig
	return p
end

-- a vertical cylinder piece (axis = the host's Y)
local function cylY(rig, hostName, name, diameter: number, height: number, offset: CFrame, color, opts)
	opts = table.clone(opts or {})
	opts.shape = Enum.PartType.Cylinder
	return piece(rig, hostName, name, Vector3.new(height, diameter, diameter), offset * CFrame.Angles(0, 0, rad(90)),
		color, opts)
end

local function ballPiece(rig, hostName, name, d: number, offset: CFrame, color, opts)
	opts = table.clone(opts or {})
	opts.shape = Enum.PartType.Ball
	return piece(rig, hostName, name, Vector3.new(d, d, d), offset, color, opts)
end

-- an ellipsoid (sphere mesh stretched to the part's size)
local function blob(rig, hostName, name, size: Vector3, offset: CFrame, color, opts)
	opts = table.clone(opts or {})
	opts.mesh = Enum.MeshType.Sphere
	return piece(rig, hostName, name, size, offset, color, opts)
end

local GOLD = { reflectance = 0.15 }
local CHROME = { reflectance = 0.25 }

------------------------------------------------------------------
-- body measurements (R15 mesh parts or the block fallback)
------------------------------------------------------------------
local function sizeOf(rig, name: string): Vector3
	local p = rig:FindFirstChild(name)
	return (p and p:IsA("BasePart")) and p.Size or Vector3.new(1, 1, 1)
end

-- the head's visible size: a MeshPart's size, or the classic head mesh (~1.2 studs)
local function headSize(rig): Vector3
	local head = rig:FindFirstChild("Head")
	if not (head and head:IsA("BasePart")) then return Vector3.new(1.2, 1.2, 1.2) end
	local mesh = head:FindFirstChildOfClass("SpecialMesh")
	if mesh and not head:IsA("MeshPart") then
		local s = mesh.Scale.Y / 1.25
		return Vector3.new(1.2, 1.2, 1.2) * math.clamp(s, 0.6, 1.6)
	end
	return head.Size
end

------------------------------------------------------------------
-- uniform pieces (torso space: front = -Z, the wearer's right = +X)
------------------------------------------------------------------
local function torsoFront(rig): (number, number, number)
	local t = sizeOf(rig, "UpperTorso")
	return t.X, t.Y, t.Z
end

local function shirtFront(rig, color: Color3, width: number?)
	local W, H, D = torsoFront(rig)
	local w = width or W * 0.24
	piece(rig, "UpperTorso", "ShirtFront", Vector3.new(w, H * 0.64, 0.05), CFrame.new(0, H * 0.18, -D / 2 - 0.02), color)
end

local function lapels(rig, color: Color3, gap: number?)
	local W, H, D = torsoFront(rig)
	local g = gap or W * 0.12
	for _, sx in { -1, 1 } do
		piece(rig, "UpperTorso", "Lapel", Vector3.new(W * 0.1, H * 0.62, 0.05),
			CFrame.new(sx * (g + W * 0.05), H * 0.17, -D / 2 - 0.035) * CFrame.Angles(0, 0, rad(sx * 13)), color)
	end
end

local function bowTie(rig, color: Color3)
	local W, H, D = torsoFront(rig)
	local y, z = H / 2 - 0.12, -D / 2 - 0.06
	piece(rig, "UpperTorso", "BowKnot", Vector3.new(0.15, 0.14, 0.1), CFrame.new(0, y, z), color)
	for _, sx in { -1, 1 } do
		piece(rig, "UpperTorso", "BowWing", Vector3.new(0.24, 0.22, 0.08),
			CFrame.new(sx * 0.18, y, z + 0.01) * CFrame.Angles(0, 0, rad(sx * 8)), color)
	end
	local _ = W
end

local function necktie(rig, color: Color3, bar: Color3?)
	local _, H, D = torsoFront(rig)
	local top = H / 2 - 0.1
	piece(rig, "UpperTorso", "TieKnot", Vector3.new(0.2, 0.16, 0.08), CFrame.new(0, top, -D / 2 - 0.05), color)
	piece(rig, "UpperTorso", "TieBlade", Vector3.new(0.19, H * 0.56, 0.05),
		CFrame.new(0, top - 0.08 - H * 0.28, -D / 2 - 0.045), color)
	if bar then
		piece(rig, "UpperTorso", "TieBar", Vector3.new(0.3, 0.05, 0.06), CFrame.new(0, top - H * 0.3, -D / 2 - 0.075),
			bar, GOLD)
	end
end

local function buttons(rig, color: Color3, xs, count: number, opts)
	local _, H, D = torsoFront(rig)
	for _, x in xs do
		for i = 1, count do
			ballPiece(rig, "UpperTorso", "Button", 0.13, CFrame.new(x, H * 0.18 - (i - 1) * H * 0.2, -D / 2 - 0.04),
				color, opts or GOLD)
		end
	end
end

-- left chest (the wearer's left = -X)
local function chestPlate(rig, name: string, size: Vector3, color: Color3, opts, dy: number?, dz: number?)
	local W, H, D = torsoFront(rig)
	return piece(rig, "UpperTorso", name, size, CFrame.new(-W * 0.27, H * 0.2 + (dy or 0), -D / 2 - 0.04 - (dz or 0)),
		color, opts)
end

local function sleeveBands(rig, part: string, name: string, color: Color3, y: number, opts)
	for _, side in { "Left", "Right" } do
		local s = sizeOf(rig, side .. part)
		piece(rig, side .. part, name, Vector3.new(s.X * 1.06, 0.14, s.Z * 1.06), CFrame.new(0, s.Y * y, 0), color, opts)
	end
end

local function epaulettes(rig, color: Color3)
	for _, side in { "Left", "Right" } do
		local s = sizeOf(rig, side .. "UpperArm")
		piece(rig, side .. "UpperArm", "Epaulette", Vector3.new(s.X * 1.12, 0.12, s.Z * 1.12),
			CFrame.new(0, s.Y / 2 + 0.02, 0), color, GOLD)
	end
end

local function belt(rig, color: Color3, buckle: Color3?)
	local s = sizeOf(rig, "LowerTorso")
	piece(rig, "LowerTorso", "Belt", Vector3.new(s.X * 1.03, 0.2, s.Z * 1.06), CFrame.new(0, s.Y * 0.1, 0), color)
	if buckle then
		piece(rig, "LowerTorso", "Buckle", Vector3.new(0.26, 0.17, 0.06), CFrame.new(0, s.Y * 0.1, -s.Z * 0.53 - 0.03),
			buckle, GOLD)
	end
end

local function apron(rig, color: Color3)
	local s = sizeOf(rig, "LowerTorso")
	piece(rig, "LowerTorso", "Apron", Vector3.new(s.X * 0.86, 1.85, 0.06), CFrame.new(0, -0.82, -s.Z / 2 - 0.06), color)
end

local function coatTails(rig, color: Color3)
	local s = sizeOf(rig, "LowerTorso")
	piece(rig, "LowerTorso", "CoatTail", Vector3.new(s.X * 0.92, 1.25, 0.07), CFrame.new(0, -0.5, s.Z / 2 + 0.06), color)
end

local function legStripes(rig, color: Color3)
	for _, side in { "Left", "Right" } do
		local sx = side == "Left" and -1 or 1
		for _, part in { "UpperLeg", "LowerLeg" } do
			local s = sizeOf(rig, side .. part)
			piece(rig, side .. part, "Stripe", Vector3.new(0.05, s.Y * 0.96, 0.16), CFrame.new(sx * (s.X / 2 + 0.02), 0, 0),
				color)
		end
	end
end

------------------------------------------------------------------
-- head pieces (head space: front = -Z)
------------------------------------------------------------------
local function hair(rig, color: Color3, style: string?)
	local h = headSize(rig)
	if style ~= "back" then
		blob(rig, "Head", "Hair", Vector3.new(h.X * 1.07, h.Y * 0.6, h.Z * 1.1), CFrame.new(0, h.Y * 0.3, h.Z * 0.04), color,
			{ hair = true })
	end
	blob(rig, "Head", "HairBack", Vector3.new(h.X * 1.03, h.Y * 0.66, h.Z * 0.42), CFrame.new(0, h.Y * 0.08, h.Z * 0.36),
		color, { hair = true })
	if style == "quiff" then
		blob(rig, "Head", "Quiff", Vector3.new(h.X * 0.7, h.Y * 0.3, h.Z * 0.45), CFrame.new(0, h.Y * 0.55, -h.Z * 0.22),
			color, { hair = true })
	end
end

local function topHat(rig, color: Color3, band: Color3)
	local h = headSize(rig)
	local y0 = h.Y * 0.44
	cylY(rig, "Head", "HatBrim", h.X * 1.5, 0.09, CFrame.new(0, y0, 0), color, { shadow = true })
	cylY(rig, "Head", "HatCrown", h.X * 0.98, h.Y * 0.82, CFrame.new(0, y0 + h.Y * 0.41, 0), color, { shadow = true })
	cylY(rig, "Head", "HatBand", h.X * 1.0, 0.17, CFrame.new(0, y0 + 0.13, 0), band)
end

local function peakedCap(rig, color: Color3, brim: Color3, band: Color3?)
	local h = headSize(rig)
	cylY(rig, "Head", "CapCrown", h.X * 1.08, h.Y * 0.3, CFrame.new(0, h.Y * 0.43, 0.02), color, { shadow = true })
	blob(rig, "Head", "CapTop", Vector3.new(h.X * 1.14, h.Y * 0.24, h.Z * 1.14), CFrame.new(0, h.Y * 0.6, 0.02), color)
	piece(rig, "Head", "CapBrim", Vector3.new(h.X * 0.92, 0.07, h.Z * 0.5),
		CFrame.new(0, h.Y * 0.33, -h.Z * 0.66) * CFrame.Angles(rad(-12), 0, 0), brim)
	if band then cylY(rig, "Head", "CapBand", h.X * 1.1, 0.09, CFrame.new(0, h.Y * 0.34, 0.02), band, GOLD) end
end

local function dealerVisor(rig, color: Color3)
	local h = headSize(rig)
	piece(rig, "Head", "VisorBand", Vector3.new(h.X * 1.05, 0.14, h.Z * 1.05), CFrame.new(0, h.Y * 0.3, 0), color)
	piece(rig, "Head", "Visor", Vector3.new(h.X * 0.92, 0.05, h.Z * 0.6),
		CFrame.new(0, h.Y * 0.29, -h.Z * 0.76) * CFrame.Angles(rad(-14), 0, 0), color,
		{ material = Enum.Material.Glass, transparency = 0.3 })
end

local function hardHat(rig, color: Color3)
	local h = headSize(rig)
	blob(rig, "Head", "HardHat", Vector3.new(h.X * 1.18, h.Y * 0.74, h.Z * 1.2), CFrame.new(0, h.Y * 0.36, 0), color,
		{ shadow = true, reflectance = 0.05 })
	cylY(rig, "Head", "HatRim", h.X * 1.36, 0.07, CFrame.new(0, h.Y * 0.22, -0.04), color)
	piece(rig, "Head", "HatRidge", Vector3.new(0.14, 0.1, h.Z * 1.0), CFrame.new(0, h.Y * 0.72, 0), color)
end

local function sunglasses(rig)
	local h = headSize(rig)
	piece(rig, "Head", "Shades", Vector3.new(h.X * 0.84, h.Y * 0.17, 0.06), CFrame.new(0, h.Y * 0.07, -h.Z / 2 - 0.035),
		C.Jet, { reflectance = 0.35 })
	for _, sx in { -1, 1 } do
		piece(rig, "Head", "ShadesArm", Vector3.new(0.04, 0.05, h.Z * 0.75),
			CFrame.new(sx * (h.X * 0.5 + 0.01), h.Y * 0.08, -h.Z * 0.1), C.Jet)
	end
end

local function earpiece(rig)
	local h = headSize(rig)
	ballPiece(rig, "Head", "Earpiece", 0.16, CFrame.new(h.X * 0.5 + 0.03, 0, 0), C.Jet)
	piece(rig, "Head", "EarWire", Vector3.new(0.04, h.Y * 0.62, 0.04), CFrame.new(h.X * 0.49, -h.Y * 0.36, h.Z * 0.12),
		C.Reflect, { transparency = 0.2 })
end

local function headset(rig)
	local h = headSize(rig)
	piece(rig, "Head", "HeadsetBand", Vector3.new(h.X * 1.12, 0.07, 0.14), CFrame.new(0, h.Y * 0.53, 0.02), C.Jet)
	for _, sx in { -1, 1 } do
		piece(rig, "Head", "HeadsetCup", Vector3.new(0.09, 0.34, 0.3), CFrame.new(sx * (h.X / 2 + 0.05), 0.02, 0.02), C.Jet)
	end
	piece(rig, "Head", "HeadsetBoom", Vector3.new(0.04, 0.04, h.Z * 0.55),
		CFrame.new(-(h.X / 2 + 0.03), -h.Y * 0.17, -h.Z * 0.26) * CFrame.Angles(0, rad(-18), 0), C.Jet)
	ballPiece(rig, "Head", "HeadsetMic", 0.11, CFrame.new(-h.X * 0.36, -h.Y * 0.19, -h.Z * 0.52), C.Jet)
end

------------------------------------------------------------------
-- things in their hands (hand space: the arm hangs along -Y)
------------------------------------------------------------------
-- (the hand hangs ~2.1 studs above the soles: the mop reaches the floor)
local function mop(rig)
	cylY(rig, "RightHand", "MopHandle", 0.14, 3.5, CFrame.new(0, -0.2, -0.14) * CFrame.Angles(rad(6), 0, 0), C.Wood)
	piece(rig, "RightHand", "MopHead", Vector3.new(1.05, 0.2, 0.42), CFrame.new(0, -1.86, -0.32), C.Silver, CHROME)
	piece(rig, "RightHand", "MopStrands", Vector3.new(1.0, 0.24, 0.46), CFrame.new(0, -2.0, -0.32), C.MopGrey,
		{ material = Enum.Material.Fabric })
end

local function clipboard(rig)
	piece(rig, "LeftHand", "Clipboard", Vector3.new(0.07, 1.15, 0.86), CFrame.new(-0.02, -0.42, -0.08), C.Wood)
	piece(rig, "LeftHand", "ClipPaper", Vector3.new(0.02, 0.98, 0.72), CFrame.new(-0.07, -0.47, -0.08), C.White)
	piece(rig, "LeftHand", "Clip", Vector3.new(0.1, 0.12, 0.3), CFrame.new(-0.05, 0.12, -0.08), C.Chrome, CHROME)
end

local function shaker(rig)
	cylY(rig, "RightHand", "Shaker", 0.36, 0.66, CFrame.new(0, -0.42, -0.12), C.Chrome, CHROME)
	cylY(rig, "RightHand", "ShakerCap", 0.26, 0.2, CFrame.new(0, -0.02, -0.12), C.Chrome, CHROME)
end

local function microphone(rig)
	cylY(rig, "RightHand", "MicHandle", 0.13, 0.62, CFrame.new(0, 0.05, -0.22) * CFrame.Angles(rad(-20), 0, 0), C.Jet)
	ballPiece(rig, "RightHand", "MicHead", 0.27, CFrame.new(0, 0.38, -0.34), C.Silver, CHROME)
end

local function wrench(rig)
	piece(rig, "RightHand", "WrenchHandle", Vector3.new(0.13, 1.0, 0.07), CFrame.new(0, -0.48, -0.14), C.Chrome, CHROME)
	piece(rig, "RightHand", "WrenchJaw", Vector3.new(0.36, 0.22, 0.07), CFrame.new(0, -1.02, -0.14), C.Chrome, CHROME)
end

------------------------------------------------------------------
-- the roles
------------------------------------------------------------------
-- colours per body part group: head (skin), torso, arms, hands, lowerTorso, legs, feet
local LOOKS = {
	greeter = { skin = 1, torso = C.Magenta, arms = C.Magenta, hands = C.White, lower = C.Black, legs = C.Black },
	security = { skin = 4, torso = C.Black, arms = C.Black, lower = C.Black, legs = C.Black,
		scale = { width = 1.14, depth = 1.08, height = 1.05 } },
	dealer = { skin = 2, torso = C.Black, arms = C.Shirt, lower = C.Black, legs = C.Black },
	pit_boss = { skin = 3, torso = C.Charcoal, arms = C.Charcoal, lower = C.Charcoal, legs = C.Charcoal,
		scale = { width = 1.06, depth = 1.04, height = 1.02 } },
	bartender = { skin = 5, torso = C.Burgundy, arms = C.Shirt, lower = C.Black, legs = C.Black },
	valet = { skin = 1, torso = C.ValetRed, arms = C.ValetRed, hands = C.White, lower = C.Black, legs = C.Black,
		scale = { height = 0.97 } },
	technician = { skin = 4, torso = C.HiVis, arms = C.Charcoal, lower = C.Jeans, legs = C.Jeans },
	janitor = { skin = 3, torso = C.ShirtBlue, arms = C.ShirtBlue, hands = C.Rubber, lower = C.Overall, legs = C.Overall },
	host = { skin = 2, torso = C.White, arms = C.White, lower = C.Black, legs = C.Black },
	entertainer = { skin = 5, torso = C.SequinGold, arms = C.SequinGold, lower = C.Black, legs = C.Black,
		material = Enum.Material.Foil, reflectance = 0.12 },
	floor_manager = { skin = 1, torso = C.Navy, arms = C.Navy, lower = C.Navy, legs = C.Navy },
}

local DRESS = {
	greeter = function(rig)
		shirtFront(rig, C.Shirt)
		lapels(rig, C.MagentaDeep)
		bowTie(rig, C.Jet)
		local W = sizeOf(rig, "UpperTorso").X
		buttons(rig, C.Gold, { -W * 0.2, W * 0.2 }, 3)
		epaulettes(rig, C.Gold)
		coatTails(rig, C.Magenta)
		sleeveBands(rig, "LowerArm", "Cuff", C.Gold, -0.42, GOLD)
		ballPiece(rig, "UpperTorso", "Carnation", 0.22, CFrame.new(-W * 0.3, sizeOf(rig, "UpperTorso").Y * 0.3,
			-sizeOf(rig, "UpperTorso").Z / 2 - 0.08), C.Pink)
		hair(rig, HAIR[2], "back")
		topHat(rig, C.Jet, C.Magenta)
	end,
	security = function(rig)
		shirtFront(rig, C.Shirt, sizeOf(rig, "UpperTorso").X * 0.2)
		lapels(rig, C.Jet, sizeOf(rig, "UpperTorso").X * 0.1)
		necktie(rig, C.Jet)
		chestPlate(rig, "Badge", Vector3.new(0.3, 0.36, 0.06), C.Gold, GOLD)
		chestPlate(rig, "BadgeStar", Vector3.new(0.15, 0.15, 0.06), C.GoldDeep, GOLD, 0, 0.02)
		belt(rig, C.Jet, C.Chrome)
		hair(rig, HAIR[3])
		sunglasses(rig)
		earpiece(rig)
	end,
	dealer = function(rig)
		shirtFront(rig, C.Shirt, sizeOf(rig, "UpperTorso").X * 0.3)
		bowTie(rig, C.Crimson)
		buttons(rig, C.Gold, { 0 }, 3)
		sleeveBands(rig, "UpperArm", "Garter", C.Gold, 0.05, GOLD)
		belt(rig, C.Jet)
		hair(rig, HAIR[1])
		dealerVisor(rig, C.Visor)
	end,
	pit_boss = function(rig)
		shirtFront(rig, C.Shirt)
		lapels(rig, C.CharcoalDeep)
		necktie(rig, C.Crimson, C.Gold)
		chestPlate(rig, "PocketSquare", Vector3.new(0.28, 0.14, 0.05), C.Gold, GOLD, 0.06)
		local s = sizeOf(rig, "LeftLowerArm")
		piece(rig, "LeftLowerArm", "Watch", Vector3.new(s.X * 1.08, 0.16, s.Z * 1.08), CFrame.new(0, -s.Y * 0.38, 0), C.Gold,
			GOLD)
		belt(rig, C.Jet, C.Gold)
		hair(rig, HAIR[6], "quiff")
	end,
	bartender = function(rig)
		shirtFront(rig, C.Shirt, sizeOf(rig, "UpperTorso").X * 0.28)
		bowTie(rig, C.Jet)
		buttons(rig, C.Gold, { 0 }, 3)
		sleeveBands(rig, "UpperArm", "Garter", C.Crimson, 0.05)
		apron(rig, C.Jet)
		hair(rig, HAIR[1], "quiff")
		shaker(rig)
	end,
	valet = function(rig)
		shirtFront(rig, C.Shirt, sizeOf(rig, "UpperTorso").X * 0.18)
		bowTie(rig, C.Jet)
		local W = sizeOf(rig, "UpperTorso").X
		buttons(rig, C.Gold, { -W * 0.18, W * 0.18 }, 3)
		epaulettes(rig, C.Gold)
		legStripes(rig, C.ValetRed)
		hair(rig, HAIR[3], "back")
		peakedCap(rig, C.ValetRed, C.Jet, C.Gold)
	end,
	technician = function(rig)
		local W, H, D = torsoFront(rig)
		for _, y in { -H * 0.12, H * 0.2 } do
			piece(rig, "UpperTorso", "Reflector", Vector3.new(W * 1.03, 0.13, D * 1.05), CFrame.new(0, y, 0), C.Reflect,
				{ reflectance = 0.3 })
		end
		local s = sizeOf(rig, "LowerTorso")
		piece(rig, "LowerTorso", "ToolBelt", Vector3.new(s.X * 1.05, 0.26, s.Z * 1.08), CFrame.new(0, 0, 0), C.Leather)
		for _, sx in { -1, 1 } do
			piece(rig, "LowerTorso", "Pouch", Vector3.new(0.34, 0.42, 0.3),
				CFrame.new(sx * (s.X / 2 + 0.05), -0.2, -0.1), C.Leather)
		end
		hair(rig, HAIR[1], "back")
		hardHat(rig, C.HardHat)
		wrench(rig)
	end,
	janitor = function(rig)
		local W, H, D = torsoFront(rig)
		piece(rig, "UpperTorso", "Bib", Vector3.new(W * 0.62, H * 0.5, 0.06), CFrame.new(0, -H * 0.22, -D / 2 - 0.03),
			C.Overall)
		piece(rig, "UpperTorso", "BibPocket", Vector3.new(W * 0.26, H * 0.16, 0.05), CFrame.new(0, -H * 0.16, -D / 2 - 0.07),
			C.NavyDeep)
		for _, sx in { -1, 1 } do
			piece(rig, "UpperTorso", "Strap", Vector3.new(0.2, H * 0.56, 0.06), CFrame.new(sx * W * 0.24, H * 0.2, -D / 2 - 0.03),
				C.Overall)
			piece(rig, "UpperTorso", "StrapBack", Vector3.new(0.2, H * 0.9, 0.06), CFrame.new(sx * W * 0.24, 0, D / 2 + 0.03),
				C.Overall)
			ballPiece(rig, "UpperTorso", "StrapButton", 0.13, CFrame.new(sx * W * 0.24, -H * 0.02, -D / 2 - 0.07), C.Gold, GOLD)
		end
		hair(rig, HAIR[2], "back")
		peakedCap(rig, C.Overall, C.Overall)
		mop(rig)
	end,
	host = function(rig)
		shirtFront(rig, C.Shirt)
		lapels(rig, C.Jet)
		bowTie(rig, C.Jet)
		buttons(rig, C.Jet, { 0 }, 2, {})
		chestPlate(rig, "PocketSquare", Vector3.new(0.28, 0.15, 0.05), C.Purple, nil, 0.06)
		local W, H, D = torsoFront(rig)
		piece(rig, "UpperTorso", "VipPin", Vector3.new(0.3, 0.22, 0.06), CFrame.new(W * 0.27, H * 0.22, -D / 2 - 0.05),
			C.Gold, GOLD)
		belt(rig, C.Jet)
		hair(rig, HAIR[4], "quiff")
	end,
	entertainer = function(rig)
		shirtFront(rig, C.Jet)
		lapels(rig, C.Jet)
		bowTie(rig, C.White)
		sleeveBands(rig, "LowerArm", "Cuff", C.Jet, -0.42)
		hair(rig, HAIR[3], "back")
		topHat(rig, C.Jet, C.Gold)
		microphone(rig)
	end,
	floor_manager = function(rig)
		shirtFront(rig, C.Shirt)
		lapels(rig, C.NavyDeep)
		necktie(rig, C.Gold)
		chestPlate(rig, "NameBadge", Vector3.new(0.36, 0.14, 0.05), C.Gold, GOLD, 0.02)
		belt(rig, C.Jet, C.Gold)
		hair(rig, HAIR[2])
		headset(rig)
		clipboard(rig)
	end,
}

------------------------------------------------------------------
-- rigs
------------------------------------------------------------------
local LIMBS = {
	Head = "head", UpperTorso = "torso", LowerTorso = "lower",
	LeftUpperArm = "arms", LeftLowerArm = "arms", RightUpperArm = "arms", RightLowerArm = "arms",
	LeftHand = "hands", RightHand = "hands",
	LeftUpperLeg = "legs", LeftLowerLeg = "legs", RightUpperLeg = "legs", RightLowerLeg = "legs",
	LeftFoot = "feet", RightFoot = "feet",
}

-- colour the body parts as the uniform; skin parts are marked for the client
local function paintBody(rig: Model, look)
	local skin = SKIN[look.skin or 1]
	for _, d in rig:GetDescendants() do
		if d:IsA("BasePart") then
			local group = LIMBS[d.Name]
			if group then
				local color = (group == "head" and skin) or (group == "hands" and (look.hands or skin))
					or (group == "torso" and look.torso) or (group == "lower" and look.lower)
					or (group == "arms" and look.arms) or (group == "legs" and look.legs) or C.Shoe
				d.Color = color
				if (group == "torso" or group == "arms") and look.material then
					d.Material = look.material
					d.Reflectance = look.reflectance or 0
				end
				if group == "head" or (group == "hands" and not look.hands) then d:SetAttribute("Skin", true) end
			end
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.Massless = d.Name ~= "HumanoidRootPart"
		end
	end
end

-- the R15 rig from a HumanoidDescription (yields; nil when the call fails)
local function describedRig(look): Model?
	local desc = Instance.new("HumanoidDescription")
	local skin = SKIN[look.skin or 1]
	desc.HeadColor = skin
	desc.TorsoColor = look.torso
	desc.LeftArmColor = look.arms
	desc.RightArmColor = look.arms
	desc.LeftLegColor = look.legs
	desc.RightLegColor = look.legs
	local sc = look.scale or {}
	pcall(function()
		desc.BodyTypeScale = 0
		desc.ProportionScale = 0
		desc.HeightScale = sc.height or 1
		desc.WidthScale = sc.width or 1
		desc.DepthScale = sc.depth or 1
		desc.HeadScale = 1
	end)
	local ok, rig = pcall(function()
		return Players:CreateHumanoidModelFromDescription(desc, Enum.HumanoidRigType.R15)
	end)
	if ok and typeof(rig) == "Instance" and rig:IsA("Model") and rig:FindFirstChild("HumanoidRootPart")
		and rig:FindFirstChild("UpperTorso") and rig:FindFirstChild("Head") then
		return rig
	end
	if not ok then warn("[StaffModels] CreateHumanoidModelFromDescription: " .. tostring(rig)) end
	return nil
end

-- a code-built R15 block rig with the standard part + joint names, so the R15
-- walk / idle animations drive it (used only when the description call fails)
local BLOCK = {
	-- name, size, centre (feet on y = 0), parent part, joint name, joint point
	{ "LowerTorso", Vector3.new(2, 0.4, 1), Vector3.new(0, 2.7, 0), "HumanoidRootPart", "Root", Vector3.new(0, 2.7, 0) },
	{ "UpperTorso", Vector3.new(2, 1.6, 1), Vector3.new(0, 3.7, 0), "LowerTorso", "Waist", Vector3.new(0, 2.9, 0) },
	{ "Head", Vector3.new(1.2, 1.2, 1.2), Vector3.new(0, 5.1, 0), "UpperTorso", "Neck", Vector3.new(0, 4.5, 0) },
	{ "LeftUpperArm", Vector3.new(1, 1.15, 1), Vector3.new(-1.5, 3.93, 0), "UpperTorso", "LeftShoulder", Vector3.new(-1.25, 4.25, 0) },
	{ "LeftLowerArm", Vector3.new(0.95, 1.05, 0.95), Vector3.new(-1.5, 2.83, 0), "LeftUpperArm", "LeftElbow", Vector3.new(-1.5, 3.36, 0) },
	{ "LeftHand", Vector3.new(0.9, 0.32, 0.9), Vector3.new(-1.5, 2.14, 0), "LeftLowerArm", "LeftWrist", Vector3.new(-1.5, 2.3, 0) },
	{ "RightUpperArm", Vector3.new(1, 1.15, 1), Vector3.new(1.5, 3.93, 0), "UpperTorso", "RightShoulder", Vector3.new(1.25, 4.25, 0) },
	{ "RightLowerArm", Vector3.new(0.95, 1.05, 0.95), Vector3.new(1.5, 2.83, 0), "RightUpperArm", "RightElbow", Vector3.new(1.5, 3.36, 0) },
	{ "RightHand", Vector3.new(0.9, 0.32, 0.9), Vector3.new(1.5, 2.14, 0), "RightLowerArm", "RightWrist", Vector3.new(1.5, 2.3, 0) },
	{ "LeftUpperLeg", Vector3.new(0.95, 1.2, 0.95), Vector3.new(-0.5, 1.9, 0), "LowerTorso", "LeftHip", Vector3.new(-0.5, 2.5, 0) },
	{ "LeftLowerLeg", Vector3.new(0.9, 1.15, 0.9), Vector3.new(-0.5, 0.88, 0), "LeftUpperLeg", "LeftKnee", Vector3.new(-0.5, 1.3, 0) },
	{ "LeftFoot", Vector3.new(0.9, 0.3, 1.1), Vector3.new(-0.5, 0.15, -0.05), "LeftLowerLeg", "LeftAnkle", Vector3.new(-0.5, 0.3, 0) },
	{ "RightUpperLeg", Vector3.new(0.95, 1.2, 0.95), Vector3.new(0.5, 1.9, 0), "LowerTorso", "RightHip", Vector3.new(0.5, 2.5, 0) },
	{ "RightLowerLeg", Vector3.new(0.9, 1.15, 0.9), Vector3.new(0.5, 0.88, 0), "RightUpperLeg", "RightKnee", Vector3.new(0.5, 1.3, 0) },
	{ "RightFoot", Vector3.new(0.9, 0.3, 1.1), Vector3.new(0.5, 0.15, -0.05), "RightLowerLeg", "RightAnkle", Vector3.new(0.5, 0.3, 0) },
}

local function blockRig(): Model
	local rig = Instance.new("Model")
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(2, 2, 1)
	root.CFrame = CFrame.new(0, 3, 0)
	root.Transparency = 1
	root.Parent = rig
	rig.PrimaryPart = root
	local parts = { HumanoidRootPart = root }
	for _, spec in BLOCK do
		local p = Instance.new("Part")
		p.Name = spec[1]
		p.Size = spec[2]
		p.CFrame = CFrame.new(spec[3])
		p.Material = Enum.Material.SmoothPlastic
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		p.Parent = rig
		parts[spec[1]] = p
	end
	for _, spec in BLOCK do
		local p0, p1 = parts[spec[4]], parts[spec[1]]
		local joint = CFrame.new(spec[6])
		local m = Instance.new("Motor6D")
		m.Name = spec[5]
		m.Part0 = p0
		m.Part1 = p1
		m.C0 = p0.CFrame:Inverse() * joint
		m.C1 = p1.CFrame:Inverse() * joint
		m.Parent = p1
	end
	-- a face on the block head
	local face = Instance.new("Decal")
	face.Name = "face"
	face.Face = Enum.NormalId.Front
	face.Texture = "rbxasset://textures/face.png"
	face.Parent = parts.Head
	local hum = Instance.new("Humanoid")
	hum.RigType = Enum.HumanoidRigType.R15
	hum.HipHeight = 2
	hum.Parent = rig
	Instance.new("Animator").Parent = hum
	return rig
end

local function finishRig(rig: Model, def, look)
	rig.Name = def.id
	-- no Animate script (clients drive the animations), and no BodyColors: it would
	-- re-apply its 6 colours over the uniform's per-part ones (gloves, belts, pants)
	for _, d in rig:GetDescendants() do
		if d:IsA("LuaSourceContainer") or d:IsA("BodyColors") then d:Destroy() end
	end
	-- the avatar call leaves the default head without a face
	local head = rig:FindFirstChild("Head")
	if head and head:IsA("BasePart") and not head:FindFirstChildOfClass("Decal") then
		local face = Instance.new("Decal")
		face.Name = "face"
		face.Face = Enum.NormalId.Front
		face.Texture = "rbxasset://textures/face.png"
		face.Parent = head
	end
	local hum = rig:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		hum.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
		hum.BreakJointsOnDeath = false
		pcall(function() hum.RequiresNeck = false end)
		pcall(function() hum.EvaluateStateMachine = false end) -- clients pose / move them; no physics states
		if not hum:FindFirstChildOfClass("Animator") then Instance.new("Animator").Parent = hum end
	end
	local root = rig:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		rig.PrimaryPart = root
		root.Transparency = 1
		-- how high the root stands above the soles in the rest pose (the client
		-- seats them with it; Humanoid.HipHeight + half the root as a fallback)
		local soles = math.huge
		for _, name in { "LeftFoot", "RightFoot" } do
			local foot = rig:FindFirstChild(name)
			if foot and foot:IsA("BasePart") then soles = math.min(soles, foot.Position.Y - foot.Size.Y / 2) end
		end
		local offset = soles < math.huge and root.Position.Y - soles or nil
		if not offset or offset < 1 or offset > 8 then
			offset = (hum and hum.HipHeight or 2) + root.Size.Y / 2
		end
		rig:SetAttribute("GroundOffset", offset)
	end
	paintBody(rig, look)
	local folder = Instance.new("Folder")
	folder.Name = "Uniform"
	folder.Parent = rig
	local dress = DRESS[def.id]
	if dress then
		local ok, err = pcall(dress, rig)
		if not ok then warn(("[StaffModels] dressing %s: %s"):format(def.id, tostring(err))) end
	end
	rig:SetAttribute("StaffId", def.id)
	rig:SetAttribute("RoleName", def.name)
	rig:SetAttribute("Tone", def.tone or "Gold")
	return rig
end

-- the template for one role (yields while the avatar builds)
local function buildRole(def): Model
	local look = LOOKS[def.id] or { skin = 1, torso = C.Black, arms = C.Black, lower = C.Black, legs = C.Black }
	local rig = describedRig(look)
	if not rig then rig = blockRig() end
	return finishRig(rig, def, look)
end

------------------------------------------------------------------
-- props
------------------------------------------------------------------
local function propPart(model: Model, name: string, size: Vector3, cf: CFrame, color: Color3, opts)
	opts = opts or {}
	local p = Instance.new("Part")
	p.Name = name
	if opts.shape then p.Shape = opts.shape end
	p.Size = size
	setPart(p, color, opts)
	p.Anchored = true
	p.Massless = false
	p.CastShadow = opts.shadow ~= false
	p.CFrame = cf
	p.Parent = model
	return p
end

local function propCylY(model, name, d: number, h: number, pos: Vector3, color, opts)
	opts = table.clone(opts or {})
	opts.shape = Enum.PartType.Cylinder
	return propPart(model, name, Vector3.new(h, d, d), CFrame.new(pos) * CFrame.Angles(0, 0, rad(90)), color, opts)
end

local function signText(part: BasePart, face: Enum.NormalId, text: string, color: Color3, fill: Color3?)
	local g = Instance.new("SurfaceGui")
	g.Face = face
	g.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	g.PixelsPerStud = 60
	g.LightInfluence = 0.3
	g.Parent = part
	local lbl = Instance.new("TextLabel")
	lbl.Size = UDim2.fromScale(1, 1)
	lbl.BackgroundTransparency = fill and 0 or 1
	lbl.BackgroundColor3 = fill or Color3.new()
	lbl.TextScaled = true
	lbl.Font = Enum.Font.LuckiestGuy
	lbl.TextColor3 = color
	lbl.Text = text
	lbl.Parent = g
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0.06, 0)
	pad.PaddingRight = UDim.new(0.06, 0)
	pad.PaddingTop = UDim.new(0.1, 0)
	pad.PaddingBottom = UDim.new(0.1, 0)
	pad.Parent = lbl
	local stroke = Instance.new("UIStroke")
	stroke.Color = C.Ink
	stroke.Thickness = 2
	stroke.Parent = lbl
	return g
end

local function finishProp(model: Model, primary: BasePart)
	model.PrimaryPart = primary
	primary.PivotOffset = primary.CFrame:Inverse() -- pivot = the ground centre (model space origin)
end

-- the valet's podium: black lacquer, gold trim, a "VALET" sign
local function valetPodium(): Model
	local m = Instance.new("Model")
	m.Name = "ValetPodium"
	local body = propPart(m, "Body", Vector3.new(1.5, 2.7, 1.0), CFrame.new(0, 1.35, 0), C.Lacquer, { reflectance = 0.08 })
	propPart(m, "Base", Vector3.new(1.8, 0.16, 1.3), CFrame.new(0, 0.08, 0), C.Gold, GOLD)
	propPart(m, "Desk", Vector3.new(1.75, 0.12, 1.2), CFrame.new(0, 2.76, 0.05) * CFrame.Angles(rad(-12), 0, 0), C.Gold, GOLD)
	local sign = propPart(m, "Sign", Vector3.new(1.3, 0.55, 0.06), CFrame.new(0, 1.9, -0.53), C.CrimsonDeep, { shadow = false })
	signText(sign, Enum.NormalId.Front, "VALET", C.Gold)
	for i = 0, 2 do
		propCylY(m, "KeyHook", 0.08, 0.16, Vector3.new(-0.4 + i * 0.4, 1.2, -0.56), C.Gold, GOLD)
	end
	finishProp(m, body)
	return m
end

-- the entertainer's stage: a round crimson platform in a gold rim with marquee
-- bulbs, a curtain backdrop and a "SHOWTIME" valance (the back is +Z)
local function stage(): Model
	local m = Instance.new("Model")
	m.Name = "Stage"
	local rim = propCylY(m, "Rim", 6.8, 0.5, Vector3.new(0, 0.25, 0), C.Gold, GOLD)
	propCylY(m, "Deck", 6.3, 0.14, Vector3.new(0, 0.57, 0), C.CrimsonDeep, { reflectance = 0.12 })
	propCylY(m, "Glow", 7.0, 0.08, Vector3.new(0, 0.04, 0), C.Pink, { material = Enum.Material.Neon, shadow = false })
	local bulbs = Instance.new("Folder")
	bulbs.Name = "Bulbs"
	bulbs.Parent = m
	for i = 0, 15 do
		local a = i / 16 * math.pi * 2
		local b = propPart(bulbs, "Bulb", Vector3.new(0.26, 0.26, 0.26), CFrame.new(math.cos(a) * 3.42, 0.32, math.sin(a) * 3.42),
			i % 2 == 0 and C.Gold or C.White, { shape = Enum.PartType.Ball, material = Enum.Material.Neon, shadow = false })
		b:SetAttribute("Phase", i % 2)
	end
	propPart(m, "Curtain", Vector3.new(7.2, 8.2, 0.3), CFrame.new(0, 4.1, 3.5), C.Crimson,
		{ material = Enum.Material.Fabric })
	for _, sx in { -1, 1 } do
		propPart(m, "CurtainEdge", Vector3.new(0.3, 8.2, 0.42), CFrame.new(sx * 3.7, 4.1, 3.5), C.Gold, GOLD)
	end
	local valance = propPart(m, "Valance", Vector3.new(7.8, 1.3, 0.5), CFrame.new(0, 8.6, 3.4), C.CrimsonDeep)
	signText(valance, Enum.NormalId.Front, "SHOWTIME", C.Gold)
	propPart(m, "ValanceTrim", Vector3.new(8.0, 0.18, 0.6), CFrame.new(0, 7.92, 3.4), C.Gold, GOLD)
	local lamp = propPart(m, "Lamp", Vector3.new(0.4, 0.4, 0.4), CFrame.new(0, 7.6, 2.6), C.Jet, { transparency = 1, shadow = false })
	local spot = Instance.new("SpotLight")
	spot.Face = Enum.NormalId.Bottom
	spot.Angle = 70
	spot.Range = 14
	spot.Brightness = 2.4
	spot.Color = Color3.fromRGB(255, 226, 180)
	spot.Shadows = false
	spot.Parent = lamp
	finishProp(m, rim)
	return m
end

-- the janitor's yellow A-frame
local function wetFloorSign(): Model
	local m = Instance.new("Model")
	m.Name = "WetFloorSign"
	local root = propPart(m, "Root", Vector3.new(0.2, 0.2, 0.2), CFrame.new(0, 0.1, 0), C.HardHat, { transparency = 1, shadow = false })
	for _, sz in { -1, 1 } do
		local board = propPart(m, "Board", Vector3.new(1.0, 1.7, 0.06),
			CFrame.new(0, 0.82, sz * 0.2) * CFrame.Angles(rad(sz * -12), 0, 0), C.HardHat, { shadow = true })
		signText(board, sz < 0 and Enum.NormalId.Front or Enum.NormalId.Back, "CAUTION\nWET FLOOR", C.Jet)
	end
	finishProp(m, root)
	return m
end

------------------------------------------------------------------
-- boot
------------------------------------------------------------------
local folder: Folder? = nil

function StaffModels.folder(): Folder?
	return folder
end

function StaffModels.start(_deps)
	local old = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
	if old then old:Destroy() end
	local f = Instance.new("Folder")
	f.Name = FOLDER_NAME
	f.Parent = ReplicatedStorage
	folder = f

	local props = Instance.new("Folder")
	props.Name = "Props"
	for _, build in { valetPodium, stage, wetFloorSign } do
		local ok, res = pcall(build)
		if ok then res.Parent = props else warn("[StaffModels] prop: " .. tostring(res)) end
	end
	props.Parent = f

	-- the avatars build in the background (each call loads body parts); the
	-- client picks every template up as it lands in the folder
	task.spawn(function()
		local built = 0
		for _, def in Config.Staff do
			local ok, res = pcall(buildRole, def)
			if ok and res then
				res.Parent = f
				built += 1
			else
				warn(("[StaffModels] %s: %s"):format(def.id, tostring(res)))
			end
		end
		f:SetAttribute("Ready", true)
		print(("[CasinoTycoon] StaffModels: %d staff looks ready."):format(built))
	end)
end

return StaffModels
