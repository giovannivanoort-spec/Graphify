--!nonstrict
-- UpgradesUI.luau — the owner's upgrade TRACKS (Config.UpgradeTracks, 17 of
-- them) in four tabs that follow each track's `group` hint:
--   GUESTS    how many guests come and fit inside
--   SPENDING  how much every guest brings and bets
--   HOUSE     how your floor plays (edge, speed, machines per visit)
--   BUSINESS  stands, machine slots, income while you're away
-- One cream row per track: tone tile + 3D icon, crimson title, what it does,
-- level pips (gold = owned, cream = buyable at your rank, dark + lock = needs a
-- higher Casino Rank), the effect now -> at the next level, and one button:
-- the price (green when you can afford it, red when not), a lock "RANK X" when
-- the next level's gate is above your rank (gates only block buying; owned
-- levels stay), or MAXED.
-- Levels a rank-up just unlocked wear a NEW badge (UILib.isNew("upgrade", id));
-- they count as seen once their row has been on screen (the badge stays up
-- while the panel is open). Each tab carries a NEW tag, or a green count of
-- the levels you can buy there right now. Buying plays the UXFX juice through
-- the "unlock" toast (ka-ching, coins from the cash pill to the button,
-- confetti) and pops the row's tile; maxing a track adds a little celebration.
--
-- UpgradesUI.open(opts?)   opts = { tab = "guests" | "spending" | "house" | "business",
--                                   focus = trackId }   (anything that isn't a table is ignored)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Remotes = require(Common:WaitForChild("Remotes"))
local Config = require(Common:WaitForChild("Config"))
local UILib = require(script.Parent:WaitForChild("UILib"))
local C = UILib.Colors
local F = UILib.Fonts

local UpgradesUI = {}

local ROW_H, ROW_GAP = 116, 12
local TABS = {
	{ id = "guests", label = "GUESTS", group = "Guests", hint = "More guests drive up to your casino - and fit inside." },
	{ id = "spending", label = "SPENDING", group = "Spending", hint = "Every guest brings more cash and bets more of it." },
	{ id = "house", label = "HOUSE", group = "House", hint = "Your floor plays faster and the house keeps more." },
	{ id = "business", label = "BUSINESS", group = "Business", hint = "Stands, machine slots and income while you're away." },
}
-- for a catalog without `group` (older server): the same buckets by track id
local FALLBACK_GROUP = {
	marketing = "Guests", capacity = "Guests", parking = "Guests", nightLife = "Guests", partyBus = "Guests",
	highRollers = "Spending", tipJar = "Spending", vipLounge = "Spending", bigSpenders = "Spending",
	redCarpet = "Spending", houseEdge = "House", comps = "House", patronSpeed = "House", dealers = "House",
	concessions = "Business", autoManager = "Business", floorPlan = "Business",
}

-- rich-text colours
local function hexOf(c: Color3): string
	return "#" .. c:ToHex()
end
local TXT_NOW, TXT_ARROW, TXT_NEXT = hexOf(C.Brown), hexOf(C.Crimson), hexOf(C.GreenShadow)
local TXT_LOCK, TXT_MAX = hexOf(C.CrimsonDeep), hexOf(C.PurpleShadow)
local PIP_LOCKED = Color3.fromHex("#6B5A60")

local function groupOf(track): string
	local g = track.group
	if not g and Config.getUpgradeTrack then
		local def = Config.getUpgradeTrack(track.id)
		g = def and def.group
	end
	return g or FALLBACK_GROUP[track.id] or TABS[#TABS].group
end

local function tabOf(track): string
	local g = groupOf(track)
	for _, t in TABS do
		if t.group == g then return t.id end
	end
	return TABS[#TABS].id
end

local function rankName(r: number): string
	local ranks = Config.Progression and Config.Progression.Ranks
	local def = ranks and ranks[r]
	return def and def.name or ("Rank " .. tostring(r))
end

-- a gate above your rank blocks buying; no rank in the snapshot = no gates
local function gateOpen(gate, rank): boolean
	gate, rank = tonumber(gate), tonumber(rank)
	return gate == nil or rank == nil or gate <= rank
end

-- the effect at a level: formats with "%%" show fractions as percentages,
-- the rest print the value as is
local function describe(track, level: number): string
	if level <= 0 then return "none" end
	local v = tonumber(track.values[math.min(level, #track.values)]) or 0
	if string.find(track.format, "%%%%") then v *= 100 end
	return string.format(track.format, math.floor(v + 0.5))
end

local function effectText(track, lvl: number, max: number, gate, rank): string
	if lvl >= max then
		return ('<font color="%s">%s</font>   <font color="%s">ALL LEVELS OWNED</font>'):format(
			TXT_NEXT, describe(track, lvl), TXT_MAX)
	end
	local s = ('<font color="%s">%s</font>  <font color="%s">→</font>  <font color="%s">%s</font>'):format(
		TXT_NOW, lvl > 0 and describe(track, lvl) or "Not owned", TXT_ARROW, TXT_NEXT, describe(track, lvl + 1))
	if not gateOpen(gate, rank) then
		s ..= ('   <font color="%s">needs Rank %d</font>'):format(TXT_LOCK, tonumber(gate) or 0)
	end
	return s
end

-- level pips: gold = owned, cream = buyable at your rank, dark + lock = gated
local function drawPips(holder: Frame, track, lvl: number, rank)
	for _, ch in holder:GetChildren() do
		if ch:IsA("GuiObject") then ch:Destroy() end
	end
	local max = #track.values
	for i = 1, max do
		local owned = i <= lvl
		local open = gateOpen(track.gates and track.gates[i], rank)
		local p = UILib.make("Frame", {
			Name = "Pip", Size = UDim2.fromOffset(30, 12), BorderSizePixel = 0, LayoutOrder = i,
			BackgroundColor3 = owned and C.White or (open and C.CreamLine or PIP_LOCKED), Parent = holder,
		})
		UILib.corner(p, 6)
		UILib.stroke(p, C.Ink, 2.5, true)
		if owned then
			UILib.gradient(p, C.GoldTop, C.GoldDeep)
		elseif not open then
			UILib.image(p, "lock", {
				size = UDim2.fromOffset(18, 18), anchor = Vector2.new(0.5, 0.5), position = UDim2.fromScale(0.5, 0.5),
			})
		end
	end
	UILib.body(holder, {
		text = ("LV %d/%d"):format(lvl, max), font = F.Display, size = 15, color = C.Brown,
		frameSize = UDim2.fromOffset(70, 16), order = max + 1,
	})
end

------------------------------------------------------------------
-- one track row (updated in place on every snapshot / cash change)
------------------------------------------------------------------
local function buildRow(ctx, list: Instance, track, order: number)
	local row = UILib.row({
		parent = list, order = order, height = ROW_H, tone = track.tone, icon = track.icon,
		title = string.upper(track.name), desc = track.desc, rightWidth = 200, name = "Track_" .. tostring(track.id),
	})
	local pips = UILib.make("Frame", {
		Name = "Pips", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 18), LayoutOrder = 3, Parent = row.info,
	})
	UILib.list(pips, "x", 6, nil, Enum.VerticalAlignment.Center)
	local effect = UILib.body(row.info, {
		name = "Effect", text = "", rich = true, size = 14, font = F.Heavy, frameSize = UDim2.new(1, 0, 0, 18), order = 4,
	})
	local newBadge = UILib.badge(row.Instance, "NEW!", "Red", -10, 8)
	newBadge.Position = UDim2.fromOffset(-8, -10)
	newBadge.Visible = false

	local r = {
		track = track, Instance = row.Instance, tile = row.Instance:FindFirstChild("Tile"),
		mode = "buy", cost = 0, level = 0, gate = nil, busy = false, drawn = nil,
	}
	r.button = UILib.button({
		parent = row.right, tone = "Green", text = "", icon = "coin", textSize = 24,
		size = UDim2.fromOffset(176, 58), onClick = function() ctx.press(r) end,
	})
	function r.refreshTone()
		if r.mode == "buy" then r.button.setTone(ctx.cash() >= r.cost and "Green" or "Red") end
	end
	function r.update(state)
		local levels = state.upgradeLevels or {}
		local lvl = tonumber(levels[track.id]) or 0
		local max = #track.values
		local rank = tonumber(state.rank)
		local gate = track.gates and track.gates[lvl + 1]
		local key = tostring(lvl) .. ":" .. tostring(rank)
		if key ~= r.drawn then
			r.drawn = key
			drawPips(pips, track, lvl, rank)
		end
		effect.Text = effectText(track, lvl, max, gate, rank)
		r.level, r.gate = lvl, gate
		if lvl >= max then
			r.mode = "maxed"
			r.button.setTone("Purple")
			r.button.setIcon(nil)
			r.button.setText("MAXED")
		elseif not gateOpen(gate, rank) then
			r.mode = "locked"
			r.button.setTone("Black")
			r.button.setIcon("lock")
			r.button.setText("RANK " .. tostring(gate))
		else
			r.mode = "buy"
			r.cost = tonumber(track.costs[lvl + 1]) or 0
			r.button.setIcon("coin")
			r.button.setText(UILib.short(r.cost))
			r.refreshTone()
		end
		-- NEW only while that new level is still there to buy
		newBadge.Visible = r.mode == "buy"
			and (UILib.isNew("upgrade", track.id) or ctx.shownNew[track.id] == true)
	end
	return r
end

local function press(ctx, r)
	if r.busy then return end
	local track = r.track
	if r.mode == "locked" then
		local gate = tonumber(r.gate) or 0
		UILib.toast(("Level %d unlocks at Rank %d (%s)"):format(r.level + 1, gate, rankName(gate)), "error")
		return
	elseif r.mode == "maxed" then
		UILib.fx("pop", r.button.Instance, 1.08)
		return
	end
	r.busy = true
	local ok, res = pcall(function() return Remotes.BuyUpgrade():InvokeServer(track.id) end)
	r.busy = false
	if ok and type(res) == "table" and res.ok then
		local lvl = tonumber(res.level) or (r.level + 1)
		UILib.toast(("%s  LV %d"):format(string.upper(track.name), lvl), "unlock", describe(track, lvl))
		-- the row on screen now (rows update in place; a tab switch rebuilds them)
		local live = ctx.rows[track.id]
		local tile = live and live.tile
		if tile and tile.Parent then
			UILib.fx("pop", tile, 1.25)
			if lvl >= #track.values then
				UILib.fx("celebrate", "small", tile)
				UILib.fx("confetti", tile, 26, "show")
			end
		end
	else
		UILib.toast(ok and type(res) == "table" and res.message or "Purchase failed", "error")
	end
end

------------------------------------------------------------------
-- tab tags: NEW (crimson) when a rank-up unlocked a level there, else a green
-- count of levels you can buy right now
------------------------------------------------------------------
local function makeTag(tabFrame: Instance)
	local tag = UILib.make("Frame", {
		Name = "Tag", BackgroundColor3 = C.White, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(1, 18, 0, 3),
		Size = UDim2.fromOffset(0, 24), AutomaticSize = Enum.AutomaticSize.X, Rotation = 8, ZIndex = 6, Visible = false,
		Parent = tabFrame,
	})
	UILib.corner(tag, 999)
	local grad = UILib.gradient(tag, C.GreenTop, C.Green)
	UILib.stroke(tag, C.Ink, 2.5, true)
	UILib.pad(tag, 8, 0, 8, 0)
	local label = UILib.text(tag, {
		text = "", size = 14, autoX = true, frameSize = UDim2.fromScale(0, 1), shadow = 1, stroke = 2, z = 6,
	})
	local api = {}
	function api.set(kind: string?, n: number?)
		tag.Visible = kind ~= nil
		if kind == "new" then
			grad.Color = ColorSequence.new(C.CrimsonTop, C.Crimson)
			label.Text = "NEW"
		elseif kind == "count" then
			grad.Color = ColorSequence.new(C.GreenTop, C.Green)
			label.Text = tostring(n or 0)
		end
	end
	return api
end

-- rank chip at the right end of the hint line (under the tabs): your rank's chip + name
local function rankChip(parent: Instance)
	local chip = UILib.make("Frame", {
		Name = "RankChip", BackgroundColor3 = C.Ink, BackgroundTransparency = 0.1, AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -6, 0, 54), Size = UDim2.fromOffset(196, 32), Visible = false, Parent = parent,
	})
	UILib.corner(chip, 999)
	UILib.stroke(chip, C.GoldDeep, 3, true)
	local med = UILib.medallion(chip, {
		size = 42, number = 1, glow = false, anchor = Vector2.new(0, 0.5), position = UDim2.new(0, -12, 0.5, 0), z = 2,
	})
	local name = UILib.text(chip, {
		text = "", size = 15, xAlign = Enum.TextXAlignment.Left, frameSize = UDim2.new(1, -44, 1, 0),
		position = UDim2.fromOffset(36, 0), gradient = { C.White, C.GoldTop }, stroke = 2, shadow = 2,
	})
	return function(state)
		local r = tonumber(state.rank)
		chip.Visible = r ~= nil
		if not r then return end
		med.set(r)
		UILib.fitText(name, string.upper(tostring(state.rankName or ("Rank " .. r))), 15, 148, 10)
	end
end

------------------------------------------------------------------
-- the panel
------------------------------------------------------------------
function UpgradesUI.open(opts)
	if type(opts) ~= "table" then opts = {} end -- (the HUD tile passes an InputObject)
	local cat = UILib.getCatalog()
	local tracks = cat and cat.upgradeTracks
	if not tracks then
		UILib.toast("Upgrades unavailable", "error")
		return
	end
	local cashValue = UILib.getCashValue()

	local byTab = {}
	for _, t in TABS do byTab[t.id] = {} end
	for _, track in tracks do table.insert(byTab[tabOf(track)], track) end

	local p = UILib.panel({ name = "UpgradesPanel", title = "UPGRADES", icon = "upgrade", width = 940, height = 610 })
	local content = p.content
	local ctx = { rows = {}, shownNew = {} }
	function ctx.cash(): number return cashValue.Value end
	function ctx.press(r) press(ctx, r) end

	local hint = UILib.body(content, {
		name = "Hint", text = "", size = 15, color = C.Brown, frameSize = UDim2.new(1, -224, 0, 32),
		position = UDim2.fromOffset(4, 54),
	})
	local renderRankChip = rankChip(content)
	local list = UILib.scroller(content, {
		padding = ROW_GAP, position = UDim2.fromOffset(0, 88), size = UDim2.new(1, 0, 1, -88),
	})

	-- where to start: the asked tab / the focused track's tab, else where a
	-- rank-up left something NEW, else where something is buyable, else GUESTS
	local function buyable(track, state): boolean
		local lvl = tonumber((state.upgradeLevels or {})[track.id]) or 0
		local cost = track.costs[lvl + 1]
		return cost ~= nil and cashValue.Value >= cost and gateOpen(track.gates and track.gates[lvl + 1], state.rank)
	end
	local initial = nil
	for _, t in TABS do
		if opts.tab == t.id then initial = t.id end
	end
	if not initial and opts.focus then
		for _, track in tracks do
			if track.id == opts.focus then initial = tabOf(track) end
		end
	end
	if not initial then
		for _, t in TABS do
			for _, track in byTab[t.id] do
				if not initial and UILib.isNew("upgrade", track.id) then initial = t.id end
			end
		end
	end
	if not initial then
		for _, t in TABS do
			for _, track in byTab[t.id] do
				if not initial and buyable(track, UILib.state) then initial = t.id end
			end
		end
	end
	initial = initial or TABS[1].id

	local current = nil
	local tags = {}
	local function renderTags(state)
		for _, t in TABS do
			local tag = tags[t.id]
			if tag then
				local fresh, n = false, 0
				for _, track in byTab[t.id] do
					if UILib.isNew("upgrade", track.id) then fresh = true end
					if buyable(track, state) then n += 1 end
				end
				if fresh then
					tag.set("new")
				elseif n > 0 then
					tag.set("count", n)
				else
					tag.set(nil)
				end
			end
		end
	end

	local function render(state)
		if not p.alive then return end
		state = state or UILib.state
		local seen = {}
		for id, r in ctx.rows do
			if UILib.isNew("upgrade", id) then
				ctx.shownNew[id] = true -- the badge stays up while the panel is open
				table.insert(seen, id)
			end
			r.update(state)
		end
		for _, id in seen do UILib.markSeen("upgrade", id) end
		renderTags(state)
		renderRankChip(state)
	end

	local function build(tabId: string)
		current = tabId
		for _, ch in list:GetChildren() do
			if ch:IsA("GuiObject") then ch:Destroy() end
		end
		table.clear(ctx.rows)
		list.CanvasPosition = Vector2.zero
		for i, track in byTab[tabId] or {} do
			ctx.rows[track.id] = buildRow(ctx, list, track, i)
		end
		if #(byTab[tabId] or {}) == 0 then
			UILib.body(list, {
				text = "Nothing here yet.", size = 16, xAlign = Enum.TextXAlignment.Center, frameSize = UDim2.new(1, 0, 0, 60),
			})
		end
		for _, t in TABS do
			if t.id == tabId then hint.Text = t.hint end
		end
		render(UILib.state)
	end

	local items = {}
	for _, t in TABS do table.insert(items, { id = t.id, label = t.label }) end
	local tabsApi = UILib.tabs(content, items, function(id) build(id) end, initial)
	for _, t in TABS do
		local frame = tabsApi.Instance:FindFirstChild("Tab_" .. t.id)
		if frame then tags[t.id] = makeTag(frame) end
	end
	build(initial)

	-- open on a given track: scroll its row into view and give its tile a pop
	if opts.focus and ctx.rows[opts.focus] then
		local index = 0
		for i, track in byTab[current] do
			if track.id == opts.focus then index = i end
		end
		task.delay(0.12, function()
			if not p.alive then return end
			list.CanvasPosition = Vector2.new(0, math.max(0, (index - 1) * (ROW_H + ROW_GAP)))
		end)
		task.delay(0.4, function()
			local r = ctx.rows[opts.focus]
			if p.alive and r and r.tile and r.tile.Parent then UILib.fx("pop", r.tile, 1.3) end
		end)
	end

	local conn = cashValue.Changed:Connect(function()
		if not p.alive then return end
		for _, r in ctx.rows do r.refreshTone() end
		renderTags(UILib.state)
	end)
	local unsub = UILib.subscribe(render)
	p.onClose(function()
		conn:Disconnect()
		unsub()
	end)
end

return UpgradesUI
