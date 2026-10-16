--!nonstrict
-- Buildings.luau — every plot is a casino BUILDING. Story 1 is the plot's
-- carpet; owners buy more stories with Cash (Config.Building). The building
-- is code-built per plot and rebuilt whenever its story count changes. This
-- module builds the SHELL and runs the gameplay:
--   * stucco walls in the owner's colour with a recessed glass band (clear
--     storefront on story 1, smoked bronze above; the back is solid) and a
--     20-wide open entrance
--   * a carpeted floor slab per extra story with a dark ceiling under it, and
--     soft ceiling lights on every story
--   * a membrane roof deck
--   * an elevator booth on every story (players pick a floor; NPCs ride too)
--   * with the VIP pass, a free VIP LOUNGE story on top of the bought floors
--     (Buildings.vip: VipFloor.luau switches it on, dresses its interior and
--     moves its contents): black marble, gold glass, a gold VIP elevator
-- Facade.luau dresses it in the "Grand Palace" look: piers, pilasters,
-- courses, the porte-cochère + name sign, the cornice, parapet, roof sign and
-- the roof kit that grows with the stories.
-- Colours are applied in place (parts carry a "ThemeSlot" attribute) and the
-- (filtered) casino name goes on the pylon, the porte-cochère and the roof.
-- Every part that belongs to one story carries a "Story" attribute so the
-- client can cut away the stories above you (BuildingView).

local Players = game:GetService("Players")
local TextService = game:GetService("TextService")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lighting = game:GetService("Lighting")

local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Config = require(Common:WaitForChild("Config"))
local Remotes = require(Common:WaitForChild("Remotes"))

-- report to GameEvents (quests & co. listen); never in the way of the action
local function gameEvent(player, name: string, amount: number?)
	local m = script.Parent:FindFirstChild("GameEvents")
	if not m then return end
	local ok, GE = pcall(require, m)
	if ok and type(GE) == "table" and GE.emit then pcall(GE.emit, player, name, amount) end
end
local Materials = require(Common:WaitForChild("Materials"))
local WP = require(Common:WaitForChild("WorldPalette"))
local MachineModels = require(script.Parent:WaitForChild("MachineModels"))
local Facade = require(script.Parent:WaitForChild("Facade"))

local Buildings = {}
local Plots, Data, Economy, Upgrades, Monetization, pushData, Progression

local BC = Config.Building
local H = BC.StoryHeight
local E = BC.Elevator
local K = MachineModels.Kit
local P = MachineModels.Palette

local NAME_TAG = "CasinoNameLabel"
local NIGHT_TAG = "NightLight" -- DayNightFX: decorative neon is dimmed by day
local WHITE = Color3.new(1, 1, 1)
local STOREFRONT = { clear = true } -- story-1 front runs
local VIP_RUN = { vip = true }      -- the VIP lounge's runs: gold glass
local DOOR = 10                     -- the entrance: clear |x| < 10, y 1 .. 11.5
-- the VIP lounge (rendered targets): black marble, gold glass, gold neon
local VIP_MARBLE = Color3.fromRGB(44, 34, 54) -- plum-black: the tiles and veins still read
local VIP_GLASS = Color3.fromRGB(214, 170, 78)
local VIP_GLASS_NIGHT = Color3.fromRGB(255, 192, 96)
local VIP_NEON = Color3.fromRGB(255, 204, 92)

------------------------------------------------------------------
-- helpers
------------------------------------------------------------------
local function frameOf(rec): CFrame
	-- ground-level frame of the plot: y = 0 at the bottom of the 1-stud base,
	-- front (the street) is local -Z
	return rec.base.CFrame * CFrame.new(0, -rec.base.Size.Y / 2, 0)
end

function Buildings.storyFloorY(story: number): number
	return 1 + (story - 1) * H -- local height of a story's floor surface
end

local function ownerProfile(rec)
	local owner = rec.ownerId and Players:GetPlayerByUserId(rec.ownerId)
	return owner and Data.get(owner), owner
end

local function themeOf(rec)
	local profile, owner = ownerProfile(rec)
	local theme = profile and profile.Building and profile.Building.theme
	if theme then return theme end
	-- open plots each wear a curated look (by the plot model's PlotIndex)
	local list = BC.UnownedThemes
	if not owner and list and #list > 0 then
		local idx = tonumber(rec.model:GetAttribute("PlotIndex")) or tonumber(string.match(rec.model.Name, "%d+"))
		if idx then return list[(math.floor(idx) - 1) % #list + 1] end
	end
	return BC.DefaultTheme
end

local function themeColor(theme, slot: string): Color3
	local list = BC.Palettes[slot]
	return list[theme[slot] or 1] or list[1]
end

-- the Materials key of the theme's carpet
local function carpetKey(theme): string
	local list = BC.Carpets
	local entry = list[theme.carpet or 1] or list[1]
	return entry.key
end

-- same switch as DayNightFX: are the lamps / decorative neon on right now?
local function lampsOnNow(): boolean
	local dn = Config.DayNight
	local t = Lighting.ClockTime
	return t >= dn.LampsOn or t < dn.LampsOff
end

------------------------------------------------------------------
-- the VIP floor: the VIP pass's free story ON TOP of the floors you bought,
-- so a casino has bought + 1 stories while its owner has it. VipFloor.luau
-- switches it on by setting Buildings.vip = {
--   owns(player) -> boolean   the owner has the VIP floor right now
--   moved(player, from, to)   it goes from story `from` to `to`: its machines,
--                             decor and the people up there move along
--   dress(folder, at, ctx)    builds the lounge interior into that story's folder
--                             (ctx: story, yFloor, W, D, S, bulbs, lit); false =
--                             it didn't (the plain ceiling lights go in)
-- } (nil = no VIP floors at all)
------------------------------------------------------------------
Buildings.vip = nil

local function boughtOf(profile): number
	return (profile and profile.Building and profile.Building.stories) or 1
end

local function hasVip(player: Player?): boolean
	local hook = Buildings.vip
	if not (player and type(hook) == "table" and type(hook.owns) == "function") then return false end
	local ok, res = pcall(hook.owns, player)
	return ok and res == true
end

-- the plot owner's VIP story (nil without one)
local function vipStoryOf(rec): number?
	local profile, owner = ownerProfile(rec)
	if not (profile and owner and hasVip(owner)) then return nil end
	return boughtOf(profile) + 1
end

-- stories the building has: the floors bought + the VIP floor
local function storiesOf(rec): number
	return boughtOf((ownerProfile(rec))) + (vipStoryOf(rec) and 1 or 0)
end

-- the VIP floor moves (a floor bought, a rebirth): VipFloor takes its contents along
local function vipMoved(player: Player, from: number, to: number)
	local hook = Buildings.vip
	if from == to or not (type(hook) == "table" and type(hook.moved) == "function") then return end
	local ok, err = pcall(hook.moved, player, from, to)
	if not ok then warn("[Buildings] VIP floor move: " .. tostring(err)) end
end

-- tag a part with its story + colour slot
local function mark(p: Instance, story: number?, slot: string?)
	if story then p:SetAttribute("Story", story) end
	if slot then p:SetAttribute("ThemeSlot", slot) end
	return p
end

-- materials (colours come from applyTheme): owner-coloured stucco walls and
-- brass trim (both nil-safe so they can wrap a seg() that built nothing)
local function stucco(p: BasePart?): BasePart?
	if p then Materials.apply(p, "Stucco") end
	return p
end
local function brass(p: BasePart?): BasePart?
	if p then
		Materials.apply(p, "Brass")
		p.Reflectance = 0
	end
	return p
end

-- building neon is decoration: DayNightFX shows it as a dim plain strip by day
-- (applyTheme writes its DayColor / NightColor from the owner's pick)
local function decorNeon(p: BasePart): BasePart
	p:SetAttribute("DayMaterial", "SmoothPlastic")
	p:SetAttribute("NightMaterial", "Neon")
	CollectionService:AddTag(p, NIGHT_TAG)
	return p
end

------------------------------------------------------------------
-- the shell
------------------------------------------------------------------
-- one straight wall run for one story: solid base, a 7-tall glass band
-- (floor + 3 .. floor + 10) recessed 0.5 behind the wall face, solid top.
-- opts.clear = story-1 storefront glass (else smoked bronze). Facade.luau
-- frames the windows (it fills the band between them flush with stucco).
local function wallRun(parent, at, story, axis: string, fixed: number, a: number, b: number,
	yb: number, yFloor: number, yt: number, outward: number, glass: boolean, opts)
	opts = opts or {}
	local len = b - a
	local mid = (a + b) / 2
	-- depth / shift: thickness across the wall and offset of its centre line
	local function seg(name, y0, y1, slot, color, partOpts, depth, shift)
		local h = y1 - y0
		if h <= 0.01 then return nil end
		local d = depth or 1
		local c = fixed + (shift or 0)
		local size = axis == "x" and Vector3.new(len, h, d) or Vector3.new(d, h, len)
		local pos = axis == "x" and Vector3.new(mid, (y0 + y1) / 2, c) or Vector3.new(c, (y0 + y1) / 2, mid)
		return mark(K.part(parent, name, size, at(pos.X, pos.Y, pos.Z), color, partOpts), story, slot)
	end
	local wy0, wy1 = yFloor + 3, yFloor + 10
	if glass then
		stucco(seg("WallLow", yb, wy0, "walls", WP.Ink, { solid = true }))
		-- 0.4 thick, its outer face on the wall's centre line (0.5 behind the face)
		local clear = opts.clear == true
		local vip = opts.vip == true -- the VIP lounge: gold glass, a gold glow at night
		local tint = clear and WP.GlassClear or (vip and VIP_GLASS or WP.GlassSmoke)
		local dayT = clear and 0.7 or (vip and 0.3 or 0.5)
		local win = seg("Window", wy0, wy1, nil, tint, {
			solid = true, transparency = dayT, reflectance = clear and 0.05 or (vip and 0.3 or 0.12), shadow = false,
		}, 0.4, -outward * 0.2)
		-- smoked windows light up warm after dark, like hotel rooms (DayNightFX);
		-- the storefront stays clear so you see the casino floor
		if win and not clear then
			win:SetAttribute("DayMaterial", "SmoothPlastic")
			win:SetAttribute("NightMaterial", "Neon")
			win:SetAttribute("DayColor", tint)
			win:SetAttribute("NightColor", vip and VIP_GLASS_NIGHT or Color3.fromRGB(190, 132, 78))
			win:SetAttribute("DayTransparency", dayT)
			win:SetAttribute("NightTransparency", vip and 0.45 or 0.55)
			CollectionService:AddTag(win, NIGHT_TAG)
		end
		stucco(seg("WallHigh", wy1, yt, "walls", WP.Ink, { solid = true }))
	else
		stucco(seg("Wall", yb, yt, "walls", WP.Ink, { solid = true }))
	end
end

-- vip: the VIP lounge's elevator (black marble, gold doors + always-on gold neon)
local function elevatorBooth(parent, at, story: number, yFloor: number, stories: number, vip: boolean?)
	local ex, ez, es = E.x, E.z, E.size
	local h = H - 1.6
	local booth = mark(K.part(parent, "ElevatorBooth", Vector3.new(es, h, es), at(ex, yFloor + h / 2, ez),
		WP.Ink, { solid = true }), story, (not vip) and "walls" or nil)
	if vip then Materials.paint(booth, "PolishedTile", VIP_MARBLE) else stucco(booth) end
	-- the door frame's neon: the owner's colour, dim by day (gold and always on in the lounge)
	local function frameNeon(p: BasePart): BasePart
		if vip then
			p.Color = VIP_NEON
			return mark(p, story, nil)
		end
		return mark(decorNeon(p), story, "neon")
	end
	-- brass in the owner's trim colour (applyTheme), plain gold in the lounge
	local function metal(p: BasePart): BasePart
		if vip then return Materials.paint(p, "Brass", WP.Brass) end
		return brass(p) :: BasePart
	end
	local front = ez - es / 2
	for _, sx in { -1, 1 } do
		metal(mark(K.part(parent, "ElevatorDoor", Vector3.new(2.4, 9.5, 0.3),
			at(ex + sx * 1.25, yFloor + 4.85, front - 0.15), WP.Brass), story, (not vip) and "trim" or nil))
		frameNeon(K.neon(parent, "ElevatorFrame", Vector3.new(0.3, 10.2, 0.3), at(ex + sx * 2.7, yFloor + 5.1, front - 0.2),
			WP.Magenta))
	end
	-- a hair wider and deeper than the side bars, so their faces never coincide
	frameNeon(K.neon(parent, "ElevatorFrame", Vector3.new(5.8, 0.3, 0.34), at(ex, yFloor + 10.1, front - 0.2), WP.Magenta))
	-- floor number + "ELEVATOR" above the doors ("VIP LOUNGE" up there)
	local display = mark(K.part(parent, "ElevatorDisplay", Vector3.new(4.6, 1.4, 0.2), at(ex, yFloor + 11.4, front - 0.15),
		WP.Ink, { shadow = false }), story, nil)
	local g = K.surface(display, Enum.NormalId.Front, 60, 0)
	pcall(function() g.Brightness = 1.6 end)
	K.guiText(g, vip and "VIP LOUNGE" or ("ELEVATOR  •  %d / %d"):format(story, stories), { color = P.GoldTop, strokeThickness = 3 })
	-- call button with the prompt (the client opens the floor picker)
	local button = metal(mark(K.part(parent, "ElevatorButton", Vector3.new(0.9, 1.4, 0.3),
		at(ex + 3.4, yFloor + 4.2, front - 0.15), WP.Brass), story, (not vip) and "trim" or nil))
	K.neon(parent, "ElevatorButtonLight", Vector3.new(0.5, 0.5, 0.1), at(ex + 3.4, yFloor + 4.4, front - 0.35),
		vip and VIP_NEON or P.NeonGreen):SetAttribute("Story", story)
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "ElevatorPrompt"
	prompt.ActionText = "Ride"
	prompt.ObjectText = "Elevator"
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 10
	prompt.RequiresLineOfSight = false
	prompt.Parent = button
	button:SetAttribute("Story", story)
	CollectionService:AddTag(button, "ElevatorCall")
	local _ = booth
end

local function buildShell(rec)
	local old = rec.model:FindFirstChild("Building")
	if old then old:Destroy() end

	local S = storiesOf(rec)
	local vipStory = vipStoryOf(rec) -- the VIP lounge (the top story), nil without one
	local frame = frameOf(rec)
	local function at(x, y, z) return frame * CFrame.new(x, y, z) end
	local W, D = rec.size.X, rec.size.Z
	local hw, hd = W / 2 + 0.5, D / 2 + 0.5 -- wall centre lines (walls sit just outside the carpet)
	local carpet = carpetKey(themeOf(rec))

	local b = Instance.new("Model")
	b.Name = "Building"
	b:SetAttribute("Stories", S)
	b:SetAttribute("VipStory", vipStory) -- (clients label it VIP: elevator, build bar)
	local bulbs = Instance.new("Folder")
	bulbs.Name = "Bulbs"
	bulbs.Parent = b

	for story = 1, S do
		local yFloor = Buildings.storyFloorY(story)
		local yb = story == 1 and 0 or yFloor
		local yt = story * H + 1
		local vip = story == vipStory
		local f = Instance.new("Folder")
		f.Name = "Story" .. story
		f.Parent = b

		if story >= 2 then
			-- the carpet is the slab's own material (Color white: the pattern is baked in);
			-- the VIP lounge's is polished black marble (VipFloor inlays the gold)
			local slab = mark(K.part(f, "Floor", Vector3.new(W, 1, D), at(0, yFloor - 0.5, 0), WHITE, { solid = true }),
				story, (not vip) and "carpet" or nil)
			if vip then Materials.paint(slab, "PolishedTile", VIP_MARBLE) else Materials.apply(slab, carpet) end
		end
		-- dark ceiling under the slab above (under the roof on the top story). It
		-- belongs to the story above, so the cutaway hides it with that floor.
		local cy = story < S and story * H - 0.1 or S * H + 0.9
		mark(K.part(f, "Ceiling", Vector3.new(W - 0.2, 0.2, D - 0.2), at(0, cy, 0), WP.Ceiling, { shadow = false }),
			story + 1, nil)

		-- sides (from the front wall's inner face to the back wall's outer
		-- face, so no wall faces overlap) + a solid back
		local glass = vip and VIP_RUN or nil -- the VIP lounge wears gold glass
		wallRun(f, at, story, "z", -hw, -hd + 0.5, hd + 0.5, yb, yFloor, yt, -1, true, glass)
		wallRun(f, at, story, "z", hw, -hd + 0.5, hd + 0.5, yb, yFloor, yt, 1, true, glass)
		wallRun(f, at, story, "x", hd, -hw + 0.5, hw - 0.5, yb, yFloor, yt, 1, false)
		-- front: storefronts either side of the open entrance on story 1 (the
		-- name sign is on the porte-cochère, Facade), a glass band above
		if story == 1 then
			wallRun(f, at, story, "x", -hd, -hw - 0.5, -DOOR, yb, yFloor, yt, -1, true, STOREFRONT)
			wallRun(f, at, story, "x", -hd, DOOR, hw + 0.5, yb, yFloor, yt, -1, true, STOREFRONT)
			-- header over the doorway (the opening is y 1 .. 11.5)
			stucco(mark(K.part(f, "EntranceHeader", Vector3.new(DOOR * 2, yt - (yFloor + 10.5), 1),
				at(0, (yFloor + 10.5 + yt) / 2, -hd), WP.Ink, { solid = true }), story, "walls"))
		else
			wallRun(f, at, story, "x", -hd, -hw - 0.5, hw + 0.5, yb, yFloor, yt, -1, true, glass)
		end

		elevatorBooth(f, at, story, yFloor, S, vip)

		-- the VIP lounge's interior (VipFloor: velvet, gold, chandeliers that light it)
		local dressed = false
		if vip and type(Buildings.vip) == "table" and type(Buildings.vip.dress) == "function" then
			local ok, res = pcall(Buildings.vip.dress, f, at, {
				story = story, yFloor = yFloor, W = W, D = D, S = S, bulbs = bulbs, lit = lampsOnNow(),
			})
			if ok then dressed = res ~= false else warn("[Buildings] VIP lounge: " .. tostring(res)) end
		end
		-- soft ceiling lights in a 2 x 2 grid (no shadows): each pool is ~25 studs
		-- across, so even an empty floor reads at night
		for _, lx in (not dressed) and { -W / 4, W / 4 } or {} do
			for _, lz in { -D / 4, D / 4 } do
				local lamp = mark(K.part(f, "CeilingLight", Vector3.new(0.5, 0.5, 0.5), at(lx, yFloor + H - 1.8, lz), WHITE,
					{ transparency = 1, shadow = false }), story, nil)
				K.new("SpotLight", { Face = Enum.NormalId.Bottom, Angle = 120, Range = 40, Brightness = 1.6,
					Color = WP.Interior, Shadows = false }, lamp)
			end
		end
	end

	-- roof deck: a membrane slab over the wall tops (story S + 1, so the
	-- cutaway lifts it with the crown)
	local roofY = S * H + 1
	local roof = Instance.new("Folder")
	roof.Name = "Roof"
	roof.Parent = b
	mark(Materials.paint(K.part(roof, "RoofSlab", Vector3.new(W + 2, 1, D + 2), at(0, roofY + 0.5, 0), WP.Roof, { solid = true }),
		"RoofMembrane", WP.Roof), S + 1, nil)

	-- the looks: piers, courses, porte-cochère + name sign, crown, roof kit
	Facade.build(b, at, {
		S = S, W = W, D = D, bulbs = bulbs, roof = roof, lit = lampsOnNow(), vipStory = vipStory,
		plotIndex = tonumber(rec.model:GetAttribute("PlotIndex")) or tonumber(string.match(rec.model.Name, "%d+")) or 1,
	})

	b.Parent = rec.model
	CollectionService:AddTag(b, "CasinoProp") -- MachineFX chases the canopy + roof bulbs
	CollectionService:AddTag(b, "CasinoBuilding")
	return b
end

------------------------------------------------------------------
-- colours + name
------------------------------------------------------------------
-- the Color each ThemeSlot gets: walls (stucco, the owner's colour as is),
-- frame (stone that contrasts with the walls), wallsDark, trim (rendered on
-- brass) and neon (its night colour). Also returns the dimmed day colour of
-- the decorative neon. Slot "carpet" is a material, handled in applyTheme.
local function slotColors(theme)
	local W, T, N = themeColor(theme, "walls"), themeColor(theme, "trim"), themeColor(theme, "neon")
	local lum = 0.2126 * W.R + 0.7152 * W.G + 0.0722 * W.B
	return {
		walls = W,
		frame = Materials.tint("Ashlar", lum > 0.62 and WP.DeepStone or WP.Stone),
		wallsDark = W:Lerp(Color3.new(), 0.35),
		trim = Materials.tint("Brass", T),
		neon = N:Lerp(Color3.new(), 0.1),
	}, N:Lerp(WP.Ink, 0.55)
end

function Buildings.applyTheme(rec)
	local theme = themeOf(rec)
	local colors, neonDay = slotColors(theme)
	local carpet = carpetKey(theme)
	local lit = lampsOnNow()
	local function paint(d)
		if not d:IsA("BasePart") then return end
		local slot = d:GetAttribute("ThemeSlot")
		if slot == nil then return end
		if slot == "carpet" then
			Materials.apply(d, carpet)
			d.Color = WHITE
		elseif slot == "neon" and CollectionService:HasTag(d, NIGHT_TAG) then
			-- DayNightFX swaps between these; write the current one too so a
			-- re-theme looks right straight away
			d:SetAttribute("NightColor", colors.neon)
			d:SetAttribute("DayColor", neonDay)
			d.Color = lit and colors.neon or neonDay
		elseif colors[slot] then
			d.Color = colors[slot]
		end
	end
	-- the building plus the frontage props out front (pylon etc.)
	for _, name in { "Building", "Frontage" } do
		local container = rec.model:FindFirstChild(name)
		if container then
			for _, d in container:GetDescendants() do paint(d) end
		end
	end
	-- the ground floor is the plot's own base: the same carpet, no textures
	for _, t in rec.base:GetChildren() do
		if t:IsA("Texture") then t:Destroy() end
	end
	Materials.apply(rec.base, carpet)
	rec.base.Color = WHITE
end

function Buildings.displayName(rec): string
	local profile, owner = ownerProfile(rec)
	if not owner then return "OPEN PLOT" end
	local name = profile and profile.Building and profile.Building.name or ""
	if name ~= "" then return name end
	return owner.DisplayName .. "'s Casino"
end

function Buildings.refreshName(rec)
	local text = Buildings.displayName(rec)
	for _, label in CollectionService:GetTagged(NAME_TAG) do
		if label:IsDescendantOf(rec.model) then label.Text = text end
	end
	if Plots and Plots.setSignText then Plots.setSignText(rec, text) end
end

function Buildings.rebuild(rec)
	buildShell(rec)
	Buildings.applyTheme(rec)
	Buildings.refreshName(rec)
end

------------------------------------------------------------------
-- queries used by Placement / NPCs / the client snapshot
------------------------------------------------------------------
-- the floors the owner BOUGHT (profile.Building.stories, 1 .. MaxStories)
function Buildings.bought(player: Player): number
	return boughtOf(Data.get(player))
end

-- the VIP floor's story (the floors bought + 1), nil without the VIP floor
function Buildings.vipStory(player: Player): number?
	if not hasVip(player) then return nil end
	return Buildings.bought(player) + 1
end

-- the stories the building HAS: the floors bought + the VIP floor (placing,
-- restoring, riding and the machine slots all count every one of them)
function Buildings.stories(player: Player): number
	return Buildings.bought(player) + (Buildings.vipStory(player) and 1 or 0)
end

function Buildings.capacity(player: Player): number
	local profile = Data.get(player)
	local extra = Monetization and (Monetization.getMaxMachines(player) - Config.MaxMachinesPerPlot) or 0
	local slots = Upgrades and Upgrades.effect(profile, "machineSlots") or 0
	return BC.MachinesPerStory * Buildings.stories(player) + extra + slots
end

-- story a world height belongs to in this plot (1-based)
function Buildings.storyAt(rec, worldY: number): number
	local localY = worldY - (rec.base.Position.Y - rec.base.Size.Y / 2)
	-- +0.25 absorbs float error for things standing exactly on a floor
	return math.max(1, math.floor((localY - 1) / H + 0.25) + 1)
end

-- true when a footprint (centre + radius) would overlap the elevator booth or
-- the space in front of its doors
function Buildings.blocksElevator(rec, pos: Vector3, radius: number): boolean
	local rel = rec.base.CFrame:PointToObjectSpace(pos)
	local half = E.size / 2
	local x0, x1 = E.x - half - 1.6, E.x + half + 1.6 -- incl. the call button
	local z0, z1 = E.z - half - 5, E.z + half         -- incl. the landing in front
	local cx = math.clamp(rel.X, x0, x1)
	local cz = math.clamp(rel.Z, z0, z1)
	return (Vector2.new(rel.X - cx, rel.Z - cz)).Magnitude < radius
end

-- where you step out of the elevator on a story (world CFrame, facing the street)
function Buildings.elevatorExit(rec, story: number): CFrame
	local frame = frameOf(rec)
	return frame * CFrame.new(E.x, Buildings.storyFloorY(story) + 3, E.z - E.size / 2 - 3.5)
end

------------------------------------------------------------------
-- owner actions
------------------------------------------------------------------
function Buildings.buyStory(player: Player)
	local profile = Data.get(player)
	local rec = Plots.getRecordForOwner(player.UserId)
	if not (profile and rec) then return { ok = false, message = "You don't own a casino yet." } end
	local S = profile.Building.stories
	if S >= BC.MaxStories then return { ok = false, message = "Your casino is as tall as it gets!" } end
	-- each floor needs a Casino Rank (Config.Progression.StoryRanks); floors you have stay
	local need = Config.Progression and Config.Progression.StoryRanks[S + 1]
	if need and Progression and (Progression.rank(profile)) < need then
		return { ok = false, message = Progression.floorLockedMessage(S + 1, need), needRank = need }
	end
	local cost = BC.StoryCosts[S + 1]
	if Economy.getCash(player) < cost then return { ok = false, message = "Not enough " .. Config.CurrencyName .. "." } end
	if not Economy.tryWithdraw(player, cost) then return { ok = false, message = "Purchase failed." } end
	local vipFrom = Buildings.vipStory(player)
	profile.Building.stories = S + 1
	-- the VIP floor stays on top: up a story, its machines + decor along
	if vipFrom then vipMoved(player, vipFrom, vipFrom + 1) end
	Buildings.rebuild(rec)
	gameEvent(player, "floorBought", 1)
	return { ok = true, message = ("Floor %d is open!"):format(S + 1), stories = S + 1, vipStory = vipFrom and vipFrom + 1 }
end

-- Set the owner's floor count (a rebirth takes the casino back to 1 floor) and
-- rebuild the shell. Anyone standing on a floor (or the roof) that goes away is
-- taken down to the ground floor's elevator first. The VIP floor stays on top
-- (story n + 1): it moves with its contents and the people on it.
function Buildings.setStories(player: Player, n: number): boolean
	local profile = Data.get(player)
	if not (profile and type(profile.Building) == "table") then return false end
	n = math.clamp(math.floor(tonumber(n) or 1), 1, BC.MaxStories)
	local was = tonumber(profile.Building.stories) or 1
	local vipFrom = Buildings.vipStory(player)
	profile.Building.stories = n
	local rec = Plots.getRecordForOwner(player.UserId)
	if rec and n < was then
		local half = rec.size / 2 + Vector3.new(4, 0, 4)
		for _, plr in Players:GetPlayers() do
			local root = plr.Character and plr.Character:FindFirstChild("HumanoidRootPart")
			if root and root:IsA("BasePart") then
				local rel = rec.base.CFrame:PointToObjectSpace(root.Position)
				local s = Buildings.storyAt(rec, root.Position.Y)
				if math.abs(rel.X) <= half.X and math.abs(rel.Z) <= half.Z and s > n and s ~= vipFrom then
					root.AssemblyLinearVelocity = Vector3.zero
					root.CFrame = Buildings.elevatorExit(rec, 1)
				end
			end
		end
	end
	if vipFrom then vipMoved(player, vipFrom, n + 1) end
	if rec then Buildings.rebuild(rec) end
	return true
end

local NAME_PATTERN = "^[%w %-%.!'&]+$"

function Buildings.setName(player: Player, text: any)
	local profile = Data.get(player)
	local rec = Plots.getRecordForOwner(player.UserId)
	if not (profile and rec) then return { ok = false, message = "You don't own a casino yet." } end
	if type(text) ~= "string" then return { ok = false, message = "Type a name first." } end
	text = text:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
	if #text < BC.NameMinLength or #text > BC.NameMaxLength then
		return { ok = false, message = ("Names are %d-%d characters."):format(BC.NameMinLength, BC.NameMaxLength) }
	end
	if not text:match(NAME_PATTERN) then
		return { ok = false, message = "Use letters, numbers and simple punctuation." }
	end
	-- Roblox text filtering: required before anyone else sees the name
	local ok, filtered = pcall(function()
		local result = TextService:FilterStringAsync(text, player.UserId, Enum.TextFilterContext.PublicChat)
		return result:GetNonChatStringForBroadcastAsync()
	end)
	if not ok or type(filtered) ~= "string" then
		return { ok = false, message = "Couldn't check that name - try again." }
	end
	if filtered:find("#") then
		return { ok = false, message = "That name isn't allowed." }
	end
	profile.Building.name = filtered
	Buildings.refreshName(rec)
	return { ok = true, message = "Your casino is now " .. filtered .. "!", name = filtered }
end

function Buildings.setTheme(player: Player, slot: any, index: any)
	local profile = Data.get(player)
	local rec = Plots.getRecordForOwner(player.UserId)
	if not (profile and rec) then return { ok = false, message = "You don't own a casino yet." } end
	local list = type(slot) == "string" and BC.Palettes[slot]
	index = tonumber(index)
	if not list or not index or index ~= math.floor(index) or index < 1 or index > #list then
		return { ok = false, message = "Unknown colour." }
	end
	profile.Building.theme[slot] = index
	Buildings.applyTheme(rec)
	return { ok = true, message = "Looking good!" }
end

-- teleport a player to another story of the building whose elevator they're at
function Buildings.ride(player: Player, buildingModel: any, story: any)
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not root then return { ok = false } end
	local rec
	for _, r in Plots.allRecords() do
		if r.model == buildingModel then rec = r break end
	end
	story = tonumber(story)
	if not rec or not story then return { ok = false, message = "Unknown elevator." } end
	local S = storiesOf(rec)
	story = math.floor(story)
	if story < 1 or story > S then return { ok = false, message = "That floor doesn't exist." } end
	-- must be standing at one of this building's elevators. The call button sits
	-- ~5 studs from the exit spot and its prompt reaches 10 (the floor panel
	-- closes 12 out), so allow 20 from the exit plus a little lag
	local near = false
	for s = 1, S do
		if (Buildings.elevatorExit(rec, s).Position - root.Position).Magnitude < 20 then near = true break end
	end
	if not near then return { ok = false, message = "Walk up to the elevator first." } end
	root.CFrame = Buildings.elevatorExit(rec, story)
	return { ok = true, story = story }
end

-- snapshot fields for the client UI
function Buildings.snapshot(player: Player)
	local profile = Data.get(player)
	local b = profile and profile.Building
	if not b then return nil end
	return {
		stories = b.stories, maxStories = BC.MaxStories,
		nextStoryCost = BC.StoryCosts[b.stories + 1],
		name = b.name, displayName = (function()
			local rec = Plots.getRecordForOwner(player.UserId)
			return rec and Buildings.displayName(rec) or b.name
		end)(),
		theme = table.clone(b.theme),
		capacity = Buildings.capacity(player),
		-- `stories` stays the floors bought; the VIP floor sits on top of them
		vipStory = Buildings.vipStory(player),   -- nil without the VIP floor
		floors = Buildings.stories(player),      -- stories the building has (bought + VIP)
	}
end

function Buildings.start(deps)
	Plots = deps.Plots
	Data = deps.Data
	Economy = deps.Economy
	Upgrades = deps.Upgrades
	Monetization = deps.Monetization
	pushData = deps.pushData
	Progression = deps.Progression

	-- every plot starts as an empty 1-story building; it's rebuilt with the
	-- owner's floors, colours and name when someone gets it (Plots calls these
	-- with the plot record, after setting / clearing its owner)
	for _, rec in Plots.allRecords() do
		local ok, err = pcall(Buildings.rebuild, rec)
		if not ok then warn("[Buildings] " .. tostring(err)) end
	end
	Plots.onAssigned = Buildings.rebuild
	Plots.onReleased = Buildings.rebuild

	Remotes.BuyStory().OnServerInvoke = function(player)
		local res = Buildings.buyStory(player)
		if res.ok and pushData then pushData(player) end
		return res
	end
	Remotes.SetCasinoName().OnServerInvoke = function(player, text)
		local res = Buildings.setName(player, text)
		if res.ok and pushData then pushData(player) end
		return res
	end
	Remotes.SetCasinoTheme().OnServerInvoke = function(player, slot, index)
		local res = Buildings.setTheme(player, slot, index)
		if res.ok and pushData then pushData(player) end
		return res
	end
	Remotes.RideElevator().OnServerInvoke = function(player, buildingModel, story)
		return Buildings.ride(player, buildingModel, story)
	end
	print("[CasinoTycoon] Buildings: casino shells ready.")
end

return Buildings
