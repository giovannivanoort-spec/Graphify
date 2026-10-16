--!nonstrict
-- RankUI.luau — the Casino Rank on the client (economy_spec 6.1). The rank runs
-- on XP: every game your guests play earns XP (better machines earn more), and a
-- rebirth keeps it.
--   * RANK UP — Remotes.RankUp { rank, name, from, clientele, xp, unlocks = { machines = {ids},
--     levels = { {track, level} }, floor?, staff = {ids}, decor = {ids} } } plays a crimson
--     UXFX banner ("RANK UP!" + the rank's name) with confetti bursting from the HUD rank
--     chip, then slides up a non-modal unlock card (crimson velvet, chasing bulbs, gold
--     ribbon): one tile per unlock — machines, stands, decor, staff, upgrade levels, the
--     floor — a SHOW ME button (hop to the Showroom / the stand shop / the upgrades
--     panel on that track / the building tab) and NICE!. Tiles are clickable too.
--     The card waits while a panel is open and steps aside when one opens.
--     Catalog / decor items that also need rebirths you don't have yet stay out of
--     the rank lists (the REBIRTH panel shows them).
--   * every unlock is marked NEW for this session (UILib.markNew "machine" /
--     "upgrade" / "floor" / "decor"): HUD tiles, Showroom, shop, upgrades and the
--     building tab badge it until it has been seen
--   * a rank rise seen only in a snapshot (no RankUp within 1.5 s: an older server,
--     a dropped event) gets the same fanfare, its unlocks read from the catalog
--   * RankUI.open() — the CASINO RANK panel: your rank and its perk (clientele),
--     XP to the next rank, what the next rank unlocks, all 12 ranks as a ladder
-- Started from init.client inside pcall: RankUI.start({ travelTo(dest), openUpgrades(opts),
-- openShop(tab), openCasino(tab), isBusy() }). Nothing else depends on this module.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextService = game:GetService("TextService")
local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Remotes = require(Common:WaitForChild("Remotes"))
local Config = require(Common:WaitForChild("Config"))
local UILib = require(script.Parent:WaitForChild("UILib"))
local A = UILib.Assets
local C = UILib.Colors
local F = UILib.Fonts
local make = UILib.make

local RankUI = {}
local player = Players.LocalPlayer
local deps = {}
local started = false

------------------------------------------------------------------
-- data: ranks, catalog look-ups, what a rank unlocks
------------------------------------------------------------------
local function rankList()
	local cat = UILib.getCatalog()
	if cat and type(cat.ranks) == "table" and #cat.ranks > 0 then return cat.ranks end
	return (Config.Progression and Config.Progression.Ranks) or {}
end

local function rankName(r: number): string
	local def = rankList()[r]
	return def and def.name or ("Rank " .. tostring(r))
end

local function storyRanks(state)
	if state and type(state.storyRanks) == "table" then return state.storyRanks end
	local cat = UILib.getCatalog()
	if cat and type(cat.storyRanks) == "table" then return cat.storyRanks end
	return (Config.Progression and Config.Progression.StoryRanks) or {}
end

-- "x6.5" / "x10"
local function multText(x): string
	x = tonumber(x) or 1
	if math.abs(x - math.floor(x + 0.5)) < 0.01 then return "x" .. tostring(math.floor(x + 0.5)) end
	return "x" .. string.format("%.1f", x)
end

local TYPE_LOOK = { Plinko = { "coin", "Blue" } } -- types UIAssets has no icon for yet
local function machineLook(pack): (string, string)
	local t = pack and pack.type
	local fb = TYPE_LOOK[t]
	return A.TypeIcon[t] or (fb and fb[1]) or "slot", A.TypeTone[t] or (fb and fb[2]) or "Blue"
end

local function emptyUnlocks()
	return { machines = {}, stands = {}, staff = {}, levels = {}, decor = {}, floor = nil }
end

-- "12.4K XP"
local function xpText(n): string
	return UILib.short(math.max(0, math.floor(tonumber(n) or 0))) .. " XP"
end

-- the rebirths the player has (snapshot rebirth.count)
local function rebirthsOf(state): number
	local rb = type(state) == "table" and state.rebirth
	return type(rb) == "table" and (tonumber(rb.count) or 0) or 0
end

local function decorList()
	return type(Config.Decor) == "table" and Config.Decor or {}
end

local function index()
	local cat = UILib.getCatalog() or {}
	local idx = { machine = {}, stand = {}, staff = {}, track = {}, decor = {} }
	for _, m in (cat.machines or {}) do idx.machine[m.id] = m end
	for _, m in (cat.concessions or {}) do idx.stand[m.id] = m end
	for _, s in (cat.staff or {}) do idx.staff[s.id] = s end
	for _, t in (cat.upgradeTracks or {}) do idx.track[t.id] = t end
	for _, d in decorList() do
		if type(d) == "table" and d.id then idx.decor[d.id] = d end
	end
	return idx, cat
end

local function addUnique(list, item, key)
	local k = key(item)
	for _, x in list do
		if key(x) == k then return end
	end
	table.insert(list, item)
end
local function idKey(x) return tostring(x.id) end
local function levelKey(x) return tostring(x.track.id) .. ":" .. tostring(x.level) end

local function merge(into, u)
	for _, m in u.machines do addUnique(into.machines, m, idKey) end
	for _, m in u.stands do addUnique(into.stands, m, idKey) end
	for _, s in u.staff do addUnique(into.staff, s, idKey) end
	for _, l in u.levels do addUnique(into.levels, l, levelKey) end
	for _, d in (u.decor or {}) do addUnique(into.decor, d, idKey) end
	if u.floor and (into.floor == nil or u.floor > into.floor) then into.floor = u.floor end
end

-- what ranks (from, to] unlock, read from the catalog: the rank panel's preview,
-- the ladder and the fallback when a rank-up arrives without the server's list.
-- Items that also need more rebirths than you have are left out.
local function unlocksBetween(from: number, to: number, state)
	local _, cat = index()
	local u = emptyUnlocks()
	local rebirths = rebirthsOf(state)
	local function inRange(x): boolean
		local n = tonumber(x) or 1
		return n > from and n <= to
	end
	local function reachable(item): boolean
		return (tonumber(item.rebirth) or 0) <= rebirths
	end
	for _, m in (cat.machines or {}) do
		if inRange(m.unlockRank) and reachable(m) then table.insert(u.machines, m) end
	end
	for _, m in (cat.concessions or {}) do
		if inRange(m.unlockRank) and reachable(m) then table.insert(u.stands, m) end
	end
	for _, s in (cat.staff or {}) do
		if s.unlockRank ~= nil and inRange(s.unlockRank) then table.insert(u.staff, s) end
	end
	for _, t in (cat.upgradeTracks or {}) do
		for lvl, gate in (t.gates or {}) do
			if inRange(gate) then table.insert(u.levels, { track = t, level = lvl }) end
		end
	end
	for n, gate in storyRanks(state) do
		if n >= 2 and inRange(gate) then u.floor = math.max(u.floor or 0, n) end
	end
	for _, d in decorList() do
		if type(d) == "table" and d.id and d.unlockRank ~= nil and inRange(d.unlockRank) and reachable(d) then
			table.insert(u.decor, d)
		end
	end
	return u
end

-- the server's list (ids) -> catalog packs; nil when the payload has none
local function fromPayload(raw)
	if type(raw) ~= "table" then return nil end
	local idx = index()
	local u = emptyUnlocks()
	for _, id in (type(raw.machines) == "table" and raw.machines or {}) do
		if idx.stand[id] then
			table.insert(u.stands, idx.stand[id])
		else
			table.insert(u.machines, idx.machine[id] or { id = id, name = tostring(id) })
		end
	end
	for _, id in (type(raw.staff) == "table" and raw.staff or {}) do
		table.insert(u.staff, idx.staff[id] or { id = id, name = tostring(id) })
	end
	for _, l in (type(raw.levels) == "table" and raw.levels or {}) do
		if type(l) == "table" and l.track ~= nil then
			local t = idx.track[l.track] or { id = l.track, name = tostring(l.track), icon = "upgrade", tone = "Gold" }
			table.insert(u.levels, { track = t, level = tonumber(l.level) or 1 })
		end
	end
	for _, id in (type(raw.decor) == "table" and raw.decor or {}) do
		table.insert(u.decor, idx.decor[id] or { id = id, name = tostring(id), icon = "sparkles", tone = "Gold" })
	end
	u.floor = tonumber(raw.floor)
	return u
end

local function markAllNew(u)
	for _, m in u.machines do UILib.markNew("machine", m.id) end
	for _, m in u.stands do UILib.markNew("machine", m.id) end
	for _, l in u.levels do UILib.markNew("upgrade", l.track.id) end
	for _, d in (u.decor or {}) do UILib.markNew("decor", d.id) end
	if u.floor then UILib.markNew("floor", u.floor) end
end

-- "2 machines  •  1 stand  •  Floor 3  •  6 upgrades"
local function summary(u): string
	local parts = {}
	local function add(n: number, one: string, many: string)
		if n > 0 then table.insert(parts, ("%d %s"):format(n, n == 1 and one or many)) end
	end
	add(#u.machines, "machine", "machines")
	add(#u.stands, "stand", "stands")
	if u.floor then table.insert(parts, "Floor " .. tostring(u.floor)) end
	add(#u.levels, "upgrade", "upgrades")
	add(#u.staff, "staff", "staff")
	add(#(u.decor or {}), "decor piece", "decor")
	return #parts > 0 and table.concat(parts, "  •  ") or "Richer guests"
end

-- one tile per unlock, headline first: machines, stands, the floor, staff, levels
local function tileItems(u)
	local items = {}
	for _, m in u.machines do
		local icon, tone = machineLook(m)
		table.insert(items, { kind = "machine", id = m.id, label = m.name, icon = icon, tone = tone })
	end
	for _, m in u.stands do
		local icon, tone = machineLook(m)
		table.insert(items, { kind = "stand", id = m.id, label = m.name, icon = icon, tone = tone })
	end
	-- a floor you already own (a save from before ranks keeps its floors) is no news
	local building = type(UILib.state) == "table" and UILib.state.building
	local owned = type(building) == "table" and tonumber(building.stories) or 1
	if u.floor and u.floor > owned then
		table.insert(items, { kind = "floor", id = u.floor, label = "Floor " .. tostring(u.floor), icon = "build", tone = "Red" })
	end
	for _, s in u.staff do
		table.insert(items, { kind = "staff", id = s.id, label = s.name, icon = "staff", tone = "Purple" })
	end
	for _, d in (u.decor or {}) do
		table.insert(items, { kind = "decor", id = d.id, label = d.name, icon = d.icon or "sparkles", tone = d.tone or "Gold" })
	end
	for _, l in u.levels do
		table.insert(items, {
			kind = "level", id = l.track.id, label = l.track.name, icon = l.track.icon or "upgrade",
			tone = l.track.tone or "Gold", chip = "LV " .. tostring(l.level),
		})
	end
	return items
end

------------------------------------------------------------------
-- where an unlock lives
------------------------------------------------------------------
local function act(item)
	if not item then
		RankUI.open()
		return
	end
	local k = item.kind
	if k == "machine" then
		if deps.travelTo then deps.travelTo("showroom") end
	elseif k == "stand" or k == "staff" then
		if deps.openShop then deps.openShop(k == "staff" and "staff" or "concessions") end
	elseif k == "decor" then
		if deps.openShop then deps.openShop("decor") end
	elseif k == "level" then
		if deps.openUpgrades then deps.openUpgrades({ focus = item.id }) end
	elseif k == "floor" then
		if deps.openCasino then deps.openCasino("building") end
	else
		RankUI.open()
	end
end

-- SHOW ME goes to the headline unlock: machines are what a rank is for
local SHOW_ORDER = { "machine", "stand", "floor", "level", "decor", "staff" }
local SHOW_ICON = { machine = "shop", stand = "popcorn", floor = "build", level = "upgrade", staff = "staff", decor = "plant" }
local function headline(items)
	for _, kind in SHOW_ORDER do
		for _, it in items do
			if it.kind == kind then return it end
		end
	end
	return nil
end

------------------------------------------------------------------
-- an unlock tile: tone box + 3D icon (+ "LV 3" chip), name below
------------------------------------------------------------------
local TILE_W, TILE_H, TILE_GAP = 84, 98, 8
local MODEL_KIND = { machine = "machine", stand = "machine", decor = "decor", staff = "staff" } -- unlock kind -> ModelIcons kind
local function unlockTile(parent: Instance, item, order: number, onClick)
	local root = make("Frame", {
		Name = "Unlock_" .. tostring(item.kind), BackgroundTransparency = 1, Size = UDim2.fromOffset(TILE_W, TILE_H),
		LayoutOrder = order, Parent = parent,
	})
	local scale = make("UIScale", { Name = "PressScale", Parent = root }) :: UIScale
	local mover = make("Frame", { Name = "Mover", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = root })
	local tone = UILib.Tones[item.tone] or UILib.Tones.Gold
	local box = make("Frame", {
		Name = "Box", BackgroundColor3 = C.White, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 2),
		Size = UDim2.fromOffset(68, 68), Parent = mover,
	})
	UILib.corner(box, 18)
	UILib.gradient(box, tone.top, tone.base)
	UILib.stroke(box, C.Ink, 3, true)
	UILib.image(box, UILib.Tex.glow, {
		size = UDim2.fromScale(1.1, 1.1), anchor = Vector2.new(0.5, 0.5), position = UDim2.fromScale(0.5, 0.5), transparency = 0.45,
	})
	local img = UILib.image(box, item.icon, {
		name = "Icon", size = UDim2.fromScale(1.08, 1.08), anchor = Vector2.new(0.5, 0.5), position = UDim2.fromScale(0.5, 0.46),
	})
	-- machines, stands, decor and staff show the real thing (ModelIcons), the icon as its fallback
	local modelKind = MODEL_KIND[item.kind]
	if modelKind and item.id ~= nil then
		local person = modelKind == "staff"
		UILib.modelIcon(box, modelKind, item.id, {
			name = "Model", position = UDim2.fromOffset(3, 3), size = UDim2.new(1, -6, 1, -6), z = 3, fallback = img,
			hover = root, shadow = not person, align = not person and "bottom" or nil, bottom = 0.1,
		})
	end
	if item.chip then
		local chip = make("Frame", {
			-- inside the box's bottom edge, clear of the name below it
			Name = "Chip", BackgroundColor3 = C.White, AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, 10, 1, -2),
			Size = UDim2.fromOffset(0, 22), AutomaticSize = Enum.AutomaticSize.X, Parent = box,
		})
		UILib.corner(chip, 999)
		UILib.gradient(chip, C.CrimsonTop, C.Crimson)
		UILib.stroke(chip, C.Ink, 2.5, true)
		UILib.pad(chip, 6, 0, 6, 0)
		UILib.text(chip, { text = item.chip, size = 13, autoX = true, frameSize = UDim2.fromScale(0, 1), stroke = 1.5, shadow = 1 })
	end
	UILib.body(mover, {
		name = "Label", text = string.upper(tostring(item.label or "")), font = F.Display, size = 13, color = C.Brown,
		wrap = true, xAlign = Enum.TextXAlignment.Center, yAlign = Enum.TextYAlignment.Top,
		frameSize = UDim2.fromOffset(TILE_W + 8, 28), position = UDim2.fromOffset(-4, 72),
	})
	if onClick then
		local click = make("TextButton", {
			Name = "Click", Text = "", BackgroundTransparency = 1, AutoButtonColor = false, Size = UDim2.fromScale(1, 1),
			ZIndex = 8, Parent = root,
		}) :: TextButton
		UILib.pressJuice(click, scale, mover)
		click.Activated:Connect(function() onClick(item) end)
	end
	return root
end

------------------------------------------------------------------
-- the unlock card (non-modal, bottom centre, above the income ticker)
------------------------------------------------------------------
local CARD_W, PER_ROW, MAX_ROWS = 700, 7, 2
local card = nil   -- { root, alive, data, close() }

-- px from the screen's bottom edge to the card: clears HudUI's income ticker
-- (12 px + 56 design px at the HUD's scale) at any viewport
local function cardGap(): number
	local cam = workspace.CurrentCamera
	local vp = cam and cam.ViewportSize or Vector2.new(1280, 720)
	local s = math.clamp(math.min(vp.X / 1280, vp.Y / 720), 0.5, 1.4) * (UILib.IsTouch and 1.12 or 1)
	return math.floor(12 + 56 * s + 18)
end
local pending = nil
local waiting = false

local function bulbRing(parent: Instance, w: number, h: number)
	local pts = {}
	local band, step = 10, 28
	for x = 34, w - 34, step do table.insert(pts, Vector2.new(x, band)) end
	for y = 34 + step, h - 34 - step, step do table.insert(pts, Vector2.new(w - band, y)) end
	for x = w - 34, 34, -step do table.insert(pts, Vector2.new(x, h - band)) end
	for y = h - 34 - step, 34 + step, -step do table.insert(pts, Vector2.new(band, y)) end
	local bulbs = {}
	for i, pt in pts do
		local b = make("Frame", {
			Name = "Bulb", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(pt.X, pt.Y),
			Size = UDim2.fromOffset(10, 10), BackgroundColor3 = C.GoldTop, BorderSizePixel = 0, Parent = parent,
		})
		UILib.corner(b, 999)
		UILib.stroke(b, C.GoldShadow, 1.5, true)
		bulbs[i] = b
	end
	return bulbs
end

local function ribbon(parent: Instance, title: string)
	local TITLE_SIZE = 40
	local tw = TextService:GetTextSize(title, TITLE_SIZE, F.Display, Vector2.new(2000, 100)).X
	local width = tw + 160 -- crown + tails + margins
	local rb = make("Frame", {
		Name = "Ribbon", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, -36),
		Size = UDim2.fromOffset(width, 70), BackgroundTransparency = 1, Parent = parent,
	})
	UILib.image(rb, UILib.Tex.ribbonTail, { size = UDim2.fromOffset(56, 46), position = UDim2.fromOffset(-2, 24) })
	UILib.image(rb, UILib.Tex.ribbonTail, {
		size = UDim2.fromOffset(56, 46), position = UDim2.new(1, -54, 0, 24), rotation = 180,
	})
	local band = make("Frame", {
		Name = "Band", BackgroundColor3 = C.White, Position = UDim2.fromOffset(28, 4), Size = UDim2.new(1, -56, 0, 56),
		BorderSizePixel = 0, Parent = rb,
	})
	UILib.corner(band, 14)
	UILib.gradient(band, C.GoldTop, C.GoldDeep, C.Gold)
	UILib.stroke(band, C.Ink, 5, true)
	make("Frame", {
		Name = "Shine", BackgroundColor3 = C.White, BackgroundTransparency = 0.5, BorderSizePixel = 0,
		Position = UDim2.fromOffset(10, 5), Size = UDim2.new(1, -20, 0, 14), Parent = band,
	}, { make("UICorner", { CornerRadius = UDim.new(0, 7) }) })
	local row = make("Frame", { Name = "Row", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = band })
	UILib.list(row, "x", 6, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
	UILib.image(row, "crown", { size = UDim2.fromOffset(60, 60), order = 1, rotation = -10 })
	UILib.text(row, {
		text = title, size = TITLE_SIZE, autoX = true, frameSize = UDim2.fromScale(0, 1), order = 2, stroke = 5, shadow = 5,
		gradient = { C.White, C.GoldTop },
	})
	return rb
end

local function buildCard(data, animate: boolean)
	local screen = UILib.getScreen()
	if card then card.alive = false end
	local old = screen:FindFirstChild("RankUpCard")
	if old then old:Destroy() end

	local items = tileItems(data.unlocks)
	local cap = PER_ROW * MAX_ROWS
	local overflow = #items > cap
	local shown = overflow and cap - 1 or #items
	local slots = shown + (overflow and 1 or 0)
	local rows = math.clamp(math.ceil(slots / PER_ROW), 1, MAX_ROWS)
	local tilesH = rows * TILE_H + (rows - 1) * TILE_GAP
	local tilesY = 96
	local buttonsY = tilesY + tilesH + 14
	local innerH = buttonsY + 58 + 16
	local W, H = CARD_W, innerH + 40
	local restY = -cardGap()

	local root = make("Frame", {
		Name = "RankUpCard", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, animate and (H + 160) or restY), Size = UDim2.fromOffset(W, H),
		ZIndex = 45, Parent = screen,
	})
	UILib.autoScale(root, { fit = Vector2.new(W, H + 130) })
	local popper = make("Frame", { Name = "Pop", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = root })
	local pop = make("UIScale", { Name = "CardPop", Scale = animate and 0.6 or 1, Parent = popper }) :: UIScale

	-- hard shadow, crimson velvet, chasing bulbs, gold trim, cream inner
	local shadow = make("Frame", {
		Name = "HardShadow", BackgroundColor3 = C.Ink, Size = UDim2.fromScale(1, 1), Position = UDim2.fromOffset(0, 10),
		BorderSizePixel = 0, Parent = popper,
	})
	UILib.corner(shadow, 30)
	local velvet = make("Frame", {
		Name = "Velvet", BackgroundColor3 = C.White, Size = UDim2.fromScale(1, 1), BorderSizePixel = 0, Parent = popper,
	})
	UILib.corner(velvet, 30)
	UILib.gradient(velvet, C.CrimsonTop, C.CrimsonDeep)
	UILib.stroke(velvet, C.Ink, 5, true)
	local bulbs = bulbRing(velvet, W, H)
	local trim = make("Frame", {
		Name = "Trim", BackgroundTransparency = 1, Position = UDim2.fromOffset(16, 16), Size = UDim2.new(1, -32, 1, -32),
		Parent = velvet,
	})
	UILib.corner(trim, 22)
	UILib.stroke(trim, C.GoldTop, 2, true, 0.15)
	local inner = make("Frame", {
		Name = "Inner", BackgroundColor3 = C.White, Position = UDim2.fromOffset(20, 20), Size = UDim2.new(1, -40, 1, -40),
		BorderSizePixel = 0, Parent = velvet,
	})
	UILib.corner(inner, 18)
	UILib.gradient(inner, C.Cream, C.CreamRow)
	UILib.stroke(inner, C.Gold, 4, true)
	local pattern = make("ImageLabel", {
		Name = "Pattern", BackgroundTransparency = 1, Image = UILib.Tex.pattern, ScaleType = Enum.ScaleType.Tile,
		TileSize = UDim2.fromOffset(34, 34), ImageColor3 = Color3.fromHex("#C98A3A"), ImageTransparency = 0.88,
		Size = UDim2.fromScale(1, 1), Parent = inner,
	})
	UILib.corner(pattern, 18)

	local rb = ribbon(popper, ("RANK %d!"):format(data.rank))

	-- the rank's name + its perk
	local nameLbl = UILib.text(inner, {
		name = "RankName", text = "", size = 30, color = C.Crimson, stroke = 3, shadow = 3,
		frameSize = UDim2.new(1, -40, 0, 38), position = UDim2.fromOffset(20, 36),
	})
	UILib.fitText(nameLbl, string.upper(tostring(data.name or rankName(data.rank))), 30, W - 120, 18)
	local clientele = tonumber(data.clientele) or (rankList()[data.rank] and rankList()[data.rank].clientele)
	local perk = clientele and ("Guests now bring <b>%s</b> cash"):format(multText(clientele)) or "Your casino moved up the Strip"
	UILib.body(inner, {
		name = "Perk", rich = true, font = F.Heavy, size = 15, color = C.Brown, xAlign = Enum.TextXAlignment.Center,
		text = perk .. (#items > 0 and "  •  you unlocked:" or ""),
		frameSize = UDim2.new(1, -40, 0, 20), position = UDim2.fromOffset(20, 72),
	})

	local api = { root = root, alive = true, data = data }
	local function close(instant: boolean?)
		if not api.alive then return end
		api.alive = false
		if card == api then card = nil end
		if instant then
			root:Destroy()
			return
		end
		UILib.tween(pop, { Scale = 0.7 }, 0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		UILib.tween(root, { Position = UDim2.new(0.5, 0, 1, H + 160) }, 0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		task.delay(0.26, function() root:Destroy() end)
	end
	api.close = close

	-- the tiles
	local grid = make("Frame", {
		Name = "Tiles", BackgroundTransparency = 1, Position = UDim2.fromOffset(8, tilesY), Size = UDim2.new(1, -16, 0, tilesH),
		Parent = inner,
	})
	make("UIGridLayout", {
		CellSize = UDim2.fromOffset(TILE_W, TILE_H), CellPadding = UDim2.fromOffset(TILE_GAP, TILE_GAP),
		HorizontalAlignment = Enum.HorizontalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder, Parent = grid,
	})
	local function onTile(item)
		close()
		act(item)
	end
	for i = 1, shown do unlockTile(grid, items[i], i, onTile) end
	if overflow then
		unlockTile(grid, {
			kind = "more", label = ("+%d more"):format(#items - shown), icon = "star", tone = "Purple",
		}, shown + 1, function()
			close()
			RankUI.open()
		end)
	end
	if #items == 0 then
		UILib.body(grid, {
			text = "Richer guests are on their way to your casino!", font = F.Display, size = 20, color = C.Brown,
			xAlign = Enum.TextXAlignment.Center, frameSize = UDim2.fromScale(1, 1),
		})
	end

	-- the buttons
	local buttons = make("Frame", {
		Name = "Buttons", BackgroundTransparency = 1, Position = UDim2.fromOffset(0, buttonsY), Size = UDim2.new(1, 0, 0, 58),
		Parent = inner,
	})
	UILib.list(buttons, "x", 16, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
	local target = headline(items)
	UILib.button({
		parent = buttons, tone = "Green", text = target and "SHOW ME" or "RANK PERKS",
		icon = target and SHOW_ICON[target.kind] or "crown", textSize = 26, size = UDim2.fromOffset(240, 58), order = 1,
		onClick = function()
			close()
			act(target)
		end,
	})
	UILib.button({
		parent = buttons, tone = "Gold", text = "NICE!", textSize = 26, size = UDim2.fromOffset(180, 58), order = 2,
		onClick = function() close() end,
	})
	local x = UILib.closeButton(popper, function() close() end)
	x.Position = UDim2.new(1, -40, 0, -20)

	-- a mouse hovering keeps it up; otherwise it slides away on its own (touch
	-- taps fire MouseEnter without a MouseLeave, so only mice count)
	local hovered = false
	if not UILib.IsTouch then
		root.MouseEnter:Connect(function() hovered = true end)
		root.MouseLeave:Connect(function() hovered = false end)
	end
	task.spawn(function()
		local t0, phase = os.clock(), 0
		while api.alive and root.Parent do
			phase = 1 - phase
			for i, b in bulbs do
				b.BackgroundColor3 = ((i + phase) % 2 == 0) and C.GoldTop or C.GoldDeep
			end
			task.wait(0.3)
			if os.clock() - t0 > 25 and not hovered then close() end
		end
	end)

	if animate then
		UILib.tween(root, { Position = UDim2.new(0.5, 0, 1, restY) }, 0.45, Enum.EasingStyle.Back)
		UILib.tween(pop, { Scale = 1 }, 0.45, Enum.EasingStyle.Back)
		UILib.fx("sound", "open")
		task.delay(0.3, function()
			if api.alive and rb.Parent then UILib.fx("confetti", rb, 30, "show") end
		end)
	end
	card = api
	return api
end

local function showPending()
	if not pending then return end
	local data = pending
	pending = nil
	if card and card.alive then
		-- a newer rank-up while the card is up: fold it in
		local cur = card.data
		if data.rank >= cur.rank then
			cur.rank, cur.name, cur.clientele = data.rank, data.name, data.clientele
		end
		merge(cur.unlocks, data.unlocks)
		buildCard(cur, false)
		return
	end
	buildCard(data, true)
end

local function queueCard(data, delay: number)
	if pending then
		if data.rank >= pending.rank then
			pending.rank, pending.name, pending.clientele = data.rank, data.name, data.clientele
		end
		merge(pending.unlocks, data.unlocks)
	else
		pending = data
	end
	if card and card.alive then
		showPending()
		return
	end
	if waiting then return end
	waiting = true
	task.delay(delay, function()
		-- a panel owns the screen, or a machine is being placed: wait (up to two minutes)
		local t0 = os.clock()
		local function busy(): boolean
			if UILib.hasOpenPanel() then return true end
			local ok, placing = pcall(function() return deps.isBusy and deps.isBusy() end)
			return ok and placing == true
		end
		while busy() and os.clock() - t0 < 120 do task.wait(0.5) end
		waiting = false
		showPending()
	end)
end

------------------------------------------------------------------
-- rank up
------------------------------------------------------------------
local celebrated = {} -- [rank] = true once its fanfare played (this session)
local lastRank = nil  -- the highest rank a snapshot showed

local function onRankUp(payload)
	if type(payload) ~= "table" then return end
	local r = tonumber(payload.rank)
	if not r or celebrated[r] then return end
	local from = tonumber(payload.from) or (lastRank and math.min(lastRank, r - 1)) or (r - 1)
	for k = from + 1, r do celebrated[k] = true end
	local state = UILib.state
	local u = fromPayload(payload.unlocks) or unlocksBetween(from, r, state)
	markAllNew(u)
	local name = tostring(payload.name or rankName(r))
	local hasFx = UILib.FX ~= nil
	UILib.fx("banner", "RANK UP!", ("RANK %d  •  %s"):format(r, string.upper(name)), "crimson")
	local anchor = UILib.fxTargets.rank
	UILib.fx("celebrate", "rankup", (typeof(anchor) == "Instance" and anchor.Parent) and anchor or nil)
	if not hasFx then
		UILib.toast("RANK UP!", "unlock", ("Rank %d: %s"):format(r, name))
	end
	queueCard({ rank = r, name = name, clientele = tonumber(payload.clientele), unlocks = u }, hasFx and 2.5 or 0.4)
end

------------------------------------------------------------------
-- the CASINO RANK panel
------------------------------------------------------------------
local LEFT_W, COL_GAP, LADDER_H = 404, 20, 78

local function ladderRow(parent: Instance, k: number, def, r: number, state)
	local done, current = k < r, k == r
	local row = make("Frame", {
		Name = "Rank" .. k, BackgroundColor3 = current and C.White or (done and C.Cream or C.CreamRow),
		Size = UDim2.new(1, -8, 0, LADDER_H), LayoutOrder = k, Parent = parent,
	})
	UILib.corner(row, 18)
	if current then UILib.gradient(row, C.GoldTop, C.Gold) end
	UILib.stroke(row, current and C.Crimson or C.Ink, current and 4 or 3, true)
	UILib.medallion(row, {
		size = 58, number = k, glow = false, dim = k > r, anchor = Vector2.new(0, 0.5), position = UDim2.new(0, 10, 0.5, 0),
	})
	local nameLbl = UILib.body(row, {
		name = "Name", text = "", font = F.Display, size = 21, color = k > r and C.Brown or C.Crimson,
		transparency = k > r and 0.2 or 0, frameSize = UDim2.new(1, -150, 0, 24), position = UDim2.fromOffset(80, 8),
	})
	UILib.fitText(nameLbl, string.upper(tostring(def.name or ("Rank " .. k))), 21, 270, 14)
	local from = k == 1 and "WHERE IT STARTS" or ("AT " .. xpText(tonumber(def.xp or def.threshold) or 0))
	UILib.body(row, {
		name = "Threshold", text = ("%s  •  GUESTS %s"):format(from, multText(def.clientele)), font = F.Heavy, size = 13,
		color = C.Brown, frameSize = UDim2.new(1, -150, 0, 16), position = UDim2.fromOffset(80, 34),
	})
	UILib.body(row, {
		name = "Unlocks", text = summary(unlocksBetween(k - 1, k, state)), size = 12, color = C.Brown, transparency = 0.15,
		frameSize = UDim2.new(1, -150, 0, 16), position = UDim2.fromOffset(80, 53),
	})
	if current then
		local b = UILib.badge(row, "YOU", "Red", 6, 3)
		b.AnchorPoint = Vector2.new(1, 0.5)
		b.Position = UDim2.new(1, -14, 0.5, 0)
	elseif done then
		UILib.image(row, UILib.Tex.check, {
			name = "Done", size = UDim2.fromOffset(40, 40), anchor = Vector2.new(1, 0.5), position = UDim2.new(1, -18, 0.5, 0),
		})
	else
		UILib.image(row, "lock", {
			name = "Locked", size = UDim2.fromOffset(46, 46), anchor = Vector2.new(1, 0.5), position = UDim2.new(1, -14, 0.5, 0),
		})
	end
	return row
end

function RankUI.open()
	local p = UILib.panel({ name = "RankPanel", title = "CASINO RANK", icon = "crown", width = 980, height = 610 })
	local content = p.content
	local shownRank = nil
	local progress = nil

	local function build(state)
		for _, ch in content:GetChildren() do ch:Destroy() end
		progress = nil
		local r = tonumber(state.rank)
		shownRank = r
		if not r then
			UILib.body(content, {
				text = "Your Casino Rank shows up as soon as your casino reports in.", size = 18,
				xAlign = Enum.TextXAlignment.Center, frameSize = UDim2.new(1, 0, 0, 60), position = UDim2.fromOffset(0, 200),
			})
			return
		end
		local list = rankList()
		local def = list[r]
		local top = #list > 0 and #list or r

		-- your rank: chip, name, perk, progress
		local cur = make("Frame", {
			Name = "Current", BackgroundColor3 = C.Cream, Size = UDim2.fromOffset(LEFT_W, 208), Parent = content,
		})
		UILib.corner(cur, 20)
		UILib.stroke(cur, C.Ink, 3.5, true)
		UILib.medallion(cur, {
			name = "Chip", size = 112, number = r, caption = "RANK", crown = true, position = UDim2.fromOffset(16, 22), z = 2,
		})
		UILib.body(cur, {
			text = ("RANK %d OF %d"):format(r, math.max(top, r)), font = F.Display, size = 17, color = C.Brown,
			transparency = 0.2, frameSize = UDim2.fromOffset(240, 22), position = UDim2.fromOffset(146, 16),
		})
		local nameLbl = UILib.text(cur, {
			name = "RankName", text = "", size = 30, color = C.Crimson, xAlign = Enum.TextXAlignment.Left,
			frameSize = UDim2.fromOffset(244, 38), position = UDim2.fromOffset(144, 38), stroke = 2.5, shadow = 2,
		})
		UILib.fitText(nameLbl, string.upper(tostring(state.rankName or rankName(r))), 30, 236, 16)
		local clientele = tonumber(state.clientele) or (def and tonumber(def.clientele))
		if clientele then
			local pill = make("Frame", {
				Name = "Perk", BackgroundColor3 = C.White, Position = UDim2.fromOffset(144, 84), Size = UDim2.fromOffset(0, 34),
				AutomaticSize = Enum.AutomaticSize.X, Parent = cur,
			})
			UILib.corner(pill, 999)
			UILib.gradient(pill, C.GreenTop, C.Green)
			UILib.stroke(pill, C.Ink, 3, true)
			UILib.pad(pill, 14, 0, 14, 0)
			UILib.text(pill, {
				text = ("GUESTS BRING %s CASH"):format(multText(clientele)), size = 16, autoX = true,
				frameSize = UDim2.fromScale(0, 1), stroke = 2, shadow = 2,
			})
		end
		local bar = UILib.progressBar(cur, {
			name = "RankBar", size = UDim2.fromOffset(LEFT_W - 32, 30), position = UDim2.fromOffset(16, 144), textSize = 15,
		})
		local caption = UILib.body(cur, {
			name = "ToGo", text = "", rich = true, font = F.Heavy, size = 14, color = C.Brown,
			xAlign = Enum.TextXAlignment.Center, frameSize = UDim2.fromOffset(LEFT_W - 32, 20), position = UDim2.fromOffset(16, 182),
		})
		progress = function(st, liveXP)
			local prog = math.max(tonumber(st.rankProgress) or 0, tonumber(liveXP) or 0)
			local nxt = tonumber(st.rankNext)
			if nxt then
				local floor = tonumber(st.rankFloor) or 0
				bar.setTone("Gold")
				bar.set((prog - floor) / math.max(1, nxt - floor),
					UILib.commas(math.min(prog, nxt)) .. " / " .. UILib.commas(nxt) .. " XP")
				caption.Text = ('<font color="#%s">%s</font> to <font color="#%s">%s</font>  •  every game earns XP'):format(
					C.GreenShadow:ToHex(), xpText(math.max(0, nxt - prog)), C.Crimson:ToHex(),
					string.upper(rankName(r + 1)))
			else
				bar.setTone("Purple")
				bar.set(1, UILib.commas(prog) .. " XP")
				caption.Text = "You made it to the top of the Strip!"
			end
		end
		progress(state, player:GetAttribute("XP"))

		-- what the next rank unlocks
		local nxt = make("Frame", {
			Name = "NextUnlocks", BackgroundColor3 = C.Cream, Position = UDim2.fromOffset(0, 218),
			Size = UDim2.new(0, LEFT_W, 1, -218), Parent = content,
		})
		UILib.corner(nxt, 20)
		UILib.stroke(nxt, C.Ink, 3.5, true)
		if r < top then
			local n = r + 1
			UILib.body(nxt, {
				text = ("AT RANK %d YOU UNLOCK"):format(n), font = F.Display, size = 20, color = C.Crimson,
				frameSize = UDim2.new(1, -28, 0, 26), position = UDim2.fromOffset(14, 8),
			})
			local nd = list[n]
			UILib.body(nxt, {
				text = ("%s  •  GUESTS BRING %s CASH"):format(string.upper(rankName(n)), multText(nd and nd.clientele)),
				font = F.Heavy, size = 13, color = C.GreenShadow, frameSize = UDim2.new(1, -28, 0, 18),
				position = UDim2.fromOffset(14, 34),
			})
			local grid = UILib.scroller(nxt, {
				grid = true, cell = UDim2.fromOffset(TILE_W, TILE_H), gap = UDim2.fromOffset(TILE_GAP, 6),
				position = UDim2.fromOffset(4, 54), size = UDim2.new(1, -8, 1, -58),
			})
			-- two full rows of tiles fit without scrolling
			local pad = grid:FindFirstChildOfClass("UIPadding")
			if pad then
				pad.PaddingTop = UDim.new(0, 4)
				pad.PaddingBottom = UDim.new(0, 6)
			end
			local items = tileItems(unlocksBetween(r, n, state))
			for i, it in items do unlockTile(grid, it, i, nil) end
		else
			UILib.image(nxt, "crown", {
				size = UDim2.fromOffset(120, 120), anchor = Vector2.new(0.5, 0), position = UDim2.new(0.5, 0, 0, 26), rotation = -8,
			})
			UILib.body(nxt, {
				text = "EVERY MACHINE, UPGRADE AND FLOOR IS YOURS.", font = F.Display, size = 20, color = C.Crimson, wrap = true,
				xAlign = Enum.TextXAlignment.Center, frameSize = UDim2.new(1, -40, 0, 60), position = UDim2.fromOffset(20, 160),
			})
		end

		-- the ladder: all ranks, yours highlighted
		local rx = LEFT_W + COL_GAP
		UILib.body(content, {
			text = "THE STRIP LADDER", font = F.Display, size = 22, color = C.Crimson,
			frameSize = UDim2.fromOffset(260, 28), position = UDim2.fromOffset(rx + 4, 0),
		})
		UILib.body(content, {
			text = "Every game your guests play earns XP", size = 13, color = C.Brown, xAlign = Enum.TextXAlignment.Right,
			frameSize = UDim2.fromOffset(250, 28), anchor = Vector2.new(1, 0), position = UDim2.new(1, -6, 0, 0),
		})
		local ladder = UILib.scroller(content, {
			name = "Ladder", padding = 8, position = UDim2.fromOffset(rx, 32), size = UDim2.new(1, -rx, 1, -32),
		})
		if #list == 0 then
			ladderRow(ladder, r, { name = state.rankName, threshold = state.rankFloor, clientele = clientele }, r, state)
		end
		for k, d in list do ladderRow(ladder, k, d, r, state) end
		task.delay(0.1, function()
			if p.alive and ladder.Parent then
				ladder.CanvasPosition = Vector2.new(0, math.max(0, (r - 2) * (LADDER_H + 8)))
			end
		end)
	end

	local function update(state)
		if not p.alive then return end
		if tonumber(state.rank) ~= shownRank or not progress then
			build(state)
		else
			progress(state, player:GetAttribute("XP"))
		end
	end
	local unsub = UILib.subscribe(update)
	-- the bar follows the XP the server mirrors onto the player between snapshots
	local xpConn = player:GetAttributeChangedSignal("XP"):Connect(function()
		if p.alive and progress then progress(UILib.state, player:GetAttribute("XP")) end
	end)
	p.onClose(function()
		unsub()
		xpConn:Disconnect()
	end)
end

------------------------------------------------------------------
-- start
------------------------------------------------------------------
function RankUI.start(d): boolean
	if started then return true end
	started = true
	deps = type(d) == "table" and d or {}

	-- the server's rank-up event (Progression.luau)
	task.spawn(function()
		local ev = nil
		if type(Remotes.RankUp) == "function" then
			local ok, res = pcall(Remotes.RankUp)
			if ok then ev = res end
		end
		if typeof(ev) == "Instance" and ev:IsA("RemoteEvent") then
			ev.OnClientEvent:Connect(function(payload)
				local ok, err = pcall(onRankUp, payload)
				if not ok then warn("[RankUI] rank up: " .. tostring(err)) end
			end)
		else
			warn("[RankUI] RankUp remote missing; rank-ups are picked up from snapshots.")
		end
	end)

	-- snapshots: the first sets the baseline (no fanfare for the rank you join
	-- with); a rise the RankUp event didn't announce gets the fanfare anyway
	UILib.subscribe(function(state)
		local r = tonumber(state.rank)
		if not r then return end
		if lastRank == nil then
			lastRank = r
			for k = 1, r do celebrated[k] = true end
			return
		end
		if r > lastRank then
			local from = lastRank
			lastRank = r
			task.delay(1.5, function()
				if celebrated[r] then return end
				local ok, err = pcall(onRankUp, { rank = r, name = state.rankName, from = from, clientele = state.clientele })
				if not ok then warn("[RankUI] rank up: " .. tostring(err)) end
			end)
		end
	end)

	-- the card steps aside when a panel opens (SHOW ME opens one too)
	UILib.onFx(function(event)
		if event == "panelOpen" and card and card.alive then card.close() end
	end)
	return true
end

return RankUI
