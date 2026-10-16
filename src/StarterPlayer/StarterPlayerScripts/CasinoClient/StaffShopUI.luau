--!nonstrict
-- StaffShopUI.luau — SHOP > STAFF (replaces the built-in tab through
-- ShopUI.registerTab). A crew bar on top (roles hired, people on the floor, a
-- SEE THEM hop to your casino) and one Showtime card per role (Config.Staff):
--   * the role's 3D icon on a sunburst stage with its level medallion, the name,
--     where they work, gold level pips and the team size
--   * NOW -> NEXT: the effect at this level and the next one (Config.staffEffectText)
--   * one button: HIRE / PROMOTE with the price (green / red with your Cash), a
--     RANK lock (the level's Casino Rank gate) or MAX LEVEL
-- Hiring calls HireStaff, promoting PromoteStaff; the server pushes a snapshot and
-- the shop re-renders the tab (levels come from the snapshot's staffLevels).
-- StaffShopUI.open() opens the shop on this tab.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Config = require(Common:WaitForChild("Config"))
local Remotes = require(Common:WaitForChild("Remotes"))
local UILib = require(script.Parent:WaitForChild("UILib"))

local StaffShopUI = {}
local C = UILib.Colors
local F = UILib.Fonts
local make = UILib.make
local deps = {}

local CARD_W, CARD_H = 282, 300
local HEADER_H = 54

-- where they work, for the card and the hire toast
local POST_TEXT = {
	entrance = "At your front door", curb = "At the taxi curb", tables = "Behind your tables",
	stands = "Behind your stands", vip = "By your best game", pit = "In the table pit",
	stage = "On your stage", wander = "All over the floor", slots = "At your slots",
	floor = "Running the floor",
}
local HIRE_LINE = {
	entrance = "Find them at your front door!", curb = "They're waiting at your curb!",
	tables = "They're dealing at your tables!", stands = "They're working your stands!",
	vip = "They're by your priciest machine!", pit = "They're running your table pit!",
	stage = "Catch the show on your stage!", wander = "They're mopping your floors!",
	slots = "They're tuning your slot machines!", floor = "They're walking your casino floor!",
}

local function levelsNow(): {[string]: number}
	local st = UILib.state
	local raw = (type(st.staffInfo) == "table" and type(st.staffInfo.levels) == "table" and st.staffInfo.levels)
		or (type(st.staffLevels) == "table" and st.staffLevels) or {}
	local out = {}
	for id, v in raw do
		local def = Config.getStaffDef(id)
		if def then
			local lvl = v == true and 1 or math.floor(tonumber(v) or 0)
			out[id] = math.clamp(lvl, 0, def.maxLevel or #def.values)
		end
	end
	-- an older snapshot: a list of hired ids
	if next(out) == nil and type(st.staff) == "table" then
		for _, id in st.staff do
			if type(id) == "string" and Config.getStaffDef(id) then out[id] = 1 end
		end
	end
	return out
end

local function rankNow(): number
	return tonumber(UILib.state.rank) or 1
end

local function rankName(r: number): string?
	local d = Config.Progression and Config.Progression.Ranks and Config.Progression.Ranks[r]
	return d and d.name or nil
end

------------------------------------------------------------------
-- pieces
------------------------------------------------------------------
-- gold level pips on an ink rail
local function pips(parent: Instance, level: number, max: number, pos: UDim2)
	local rail = make("Frame", {
		Name = "Pips", BackgroundColor3 = C.Ink, BackgroundTransparency = 0.35, BorderSizePixel = 0,
		Position = pos, Size = UDim2.fromOffset(max * 22 + 10, 18), Parent = parent,
	})
	UILib.corner(rail, 9)
	UILib.list(rail, "x", 4, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
	for i = 1, max do
		local p = make("Frame", {
			Name = "Pip", Size = UDim2.fromOffset(18, 10), BackgroundColor3 = i <= level and C.White or C.Brown,
			BackgroundTransparency = i <= level and 0 or 0.25, BorderSizePixel = 0, LayoutOrder = i, Parent = rail,
		})
		UILib.corner(p, 5)
		if i <= level then
			UILib.gradient(p, C.GoldTop, C.GoldDeep)
			UILib.stroke(p, C.GoldShadow, 1.5, true)
		end
	end
	return rail
end

-- a small capsule: ink fill, an icon, a Fredoka label
local function chip(parent: Instance, icon: string?, text: string, pos: UDim2, color: Color3?)
	local f = make("Frame", {
		Name = "Chip", BackgroundColor3 = C.Ink, BackgroundTransparency = 0.25, BorderSizePixel = 0,
		Position = pos, Size = UDim2.fromOffset(0, 24), AutomaticSize = Enum.AutomaticSize.X, Parent = parent,
	})
	UILib.corner(f, 12)
	UILib.pad(f, icon and 4 or 10, 0, 10, 0)
	UILib.list(f, "x", 4, nil, Enum.VerticalAlignment.Center)
	if icon then UILib.image(f, icon, { size = UDim2.fromOffset(24, 24), order = 1 }) end
	UILib.body(f, {
		text = text, font = F.Number, size = 14, color = color or C.GoldTop, autoX = true,
		frameSize = UDim2.fromOffset(0, 24), order = 2,
	})
	return f
end

-- the NOW / NEXT line inside the effect panel
local function effectLine(parent: Instance, y: number, tag: string, tagTone: string, text: string, color: Color3)
	local t = UILib.Tones[tagTone] or UILib.Tones.Gold
	local pill = make("Frame", {
		Name = "Tag", BackgroundColor3 = C.White, BorderSizePixel = 0, Position = UDim2.fromOffset(8, y),
		Size = UDim2.fromOffset(54, 24), Parent = parent,
	})
	UILib.corner(pill, 12)
	UILib.gradient(pill, t.top, t.base)
	UILib.stroke(pill, C.Ink, 2, true)
	UILib.text(pill, { text = tag, size = 14, stroke = 1.5, shadow = 1 })
	local label = UILib.body(parent, {
		text = text, font = F.Heavy, size = 15, color = color, position = UDim2.fromOffset(70, y),
		frameSize = UDim2.new(1, -78, 0, 24),
	})
	UILib.fitText(label, text, 15, CARD_W - 20 - 80, 11) -- long effects shrink to one line
	label.TextTruncate = Enum.TextTruncate.AtEnd
	return label
end

------------------------------------------------------------------
-- hire / promote
------------------------------------------------------------------
local busy = false
local function act(def, level: number, anchor: GuiObject?)
	if busy then return end
	busy = true
	local remote = level == 0 and Remotes.HireStaff() or Remotes.PromoteStaff()
	local ok, res = pcall(function() return remote:InvokeServer(def.id) end)
	busy = false
	if ok and type(res) == "table" and res.ok then
		local newLevel = tonumber(res.level) or (level + 1)
		if level == 0 then
			UILib.toast(string.upper(def.name) .. " HIRED!", "unlock", HIRE_LINE[def.post] or "They're on your casino floor!")
		else
			local grew = Config.staffTeam(def, newLevel) > Config.staffTeam(def, level)
			local line = grew and ("Your team grew to %d!"):format(Config.staffTeam(def, newLevel))
				or ("Now %s."):format(Config.staffEffectText(def, Config.staffValue(def, newLevel)))
			UILib.toast(("%s IS NOW LV %d!"):format(string.upper(def.name), newLevel), "unlock", line)
		end
		if anchor then UILib.fx("celebrate", "unlock", anchor) end
	elseif ok and type(res) == "table" and res.needRank then
		UILib.toast(res.message or "Locked", "info", "Every game your guests play earns XP for your Casino Rank.")
	else
		UILib.toast((ok and type(res) == "table" and res.message) or "Hire failed", "error")
	end
end

------------------------------------------------------------------
-- one role's card
------------------------------------------------------------------
local function card(ctx, def, order: number, level: number)
	local t = UILib.Tones[def.tone] or UILib.Tones.Gold
	local maxLevel = def.maxLevel or #def.values
	local nextLevel = level + 1
	local need = def.gates[nextLevel]
	local rank = rankNow()
	local maxed = level >= maxLevel
	local locked = not maxed and need ~= nil and need > rank

	local root = make("Frame", {
		Name = "Staff_" .. def.id, BackgroundTransparency = 1, Size = UDim2.fromOffset(CARD_W, CARD_H),
		LayoutOrder = order, Parent = ctx.grid,
	})
	local hover = make("UIScale", { Parent = root }) :: UIScale
	local body = make("Frame", {
		Name = "Body", BackgroundColor3 = C.White, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), Parent = root,
	})
	UILib.corner(body, 24)
	UILib.gradient(body, t.top, t.base)
	UILib.stroke(body, C.Ink, 4, true)

	-- portrait stage (clipped to its rounded corners)
	local stage = make("CanvasGroup", {
		Name = "Stage", BackgroundTransparency = 1, BorderSizePixel = 0, Position = UDim2.fromOffset(10, 10),
		Size = UDim2.fromOffset(116, 122), Parent = body,
	})
	UILib.corner(stage, 18)
	local bg = make("Frame", { Name = "Bg", BackgroundColor3 = C.White, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), Parent = stage })
	UILib.gradient(bg, t.base, t.shadow)
	UILib.image(stage, UILib.Tex.sunburst, {
		size = UDim2.fromOffset(240, 240), anchor = Vector2.new(0.5, 0.5), position = UDim2.fromScale(0.5, 0.6),
		transparency = 0.84,
	})
	UILib.image(stage, UILib.Tex.glow, {
		size = UDim2.fromOffset(140, 120), anchor = Vector2.new(0.5, 0.5), position = UDim2.fromScale(0.5, 0.55),
		transparency = 0.35,
	})
	local floor = make("Frame", {
		Name = "Floor", BackgroundColor3 = C.Ink, BackgroundTransparency = 0.7, BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 1, -14), Size = UDim2.fromOffset(78, 14),
		Parent = stage,
	}, { make("UICorner", { CornerRadius = UDim.new(0.5, 0) }) })
	local icon = UILib.image(stage, def.icon or "staff", {
		size = UDim2.fromOffset(100, 100), anchor = Vector2.new(0.5, 0.5), position = UDim2.fromScale(0.5, 0.5),
	})
	if level == 0 then
		icon.ImageColor3 = locked and Color3.fromRGB(150, 150, 160) or Color3.fromRGB(225, 225, 230)
		icon.ImageTransparency = locked and 0.25 or 0.05
	end
	local ring = make("Frame", {
		Name = "StageRing", BackgroundTransparency = 1, Position = UDim2.fromOffset(10, 10),
		Size = UDim2.fromOffset(116, 122), Parent = body,
	})
	UILib.corner(ring, 18)
	UILib.stroke(ring, C.Ink, 3, true)
	-- the actual staff member: the role's rig waist up (ModelIcons, over the
	-- CanvasGroup, under the ring), tinted like the icon it replaces
	local rig = UILib.modelIcon(body, "staff", def.id, {
		name = "Rig", position = UDim2.fromOffset(12, 12), size = UDim2.fromOffset(112, 118), z = 2, fallback = icon,
		hover = root, color = icon.ImageColor3, transparency = icon.ImageTransparency,
		onModel = function(shown) floor.Visible = not shown end, -- no floor under a waist-up portrait
	})
	if rig then ring.ZIndex = 3 end
	if level > 0 then
		UILib.medallion(body, {
			size = 44, number = level, caption = "LV", glow = false, position = UDim2.fromOffset(-4, -6), z = 3,
		})
	end

	-- name, where they work, pips, team
	-- (narrower than the column: the corner badge - HIRED / MAX! / RANK - overlaps its end)
	local title = UILib.text(body, {
		name = "Title", text = "", size = 24, xAlign = Enum.TextXAlignment.Left,
		frameSize = UDim2.fromOffset(116, 30), position = UDim2.fromOffset(136, 10),
	})
	UILib.fitText(title, string.upper(def.name), 24, 114, 14)
	local post = UILib.body(body, {
		name = "Post", text = "", font = F.Heavy, size = 12, color = C.White, transparency = 0.1,
		position = UDim2.fromOffset(137, 40), frameSize = UDim2.fromOffset(138, 16),
	})
	UILib.fitText(post, POST_TEXT[def.post] or "", 12, 136, 9)
	pips(body, level, maxLevel, UDim2.fromOffset(136, 64))
	local team = Config.staffTeam(def, math.max(level, 1))
	local grows = level > 0 and not maxed and Config.staffTeam(def, nextLevel) - team or 0
	local teamText = level > 0 and ("TEAM x%d"):format(team) or ("HIRE x%d"):format(team)
	if grows > 0 then teamText ..= (" (+%d)"):format(grows) end -- the next level adds people
	chip(body, "staff", teamText, UDim2.fromOffset(136, 92))

	-- NOW -> NEXT
	local panel = make("Frame", {
		Name = "Effect", BackgroundColor3 = C.White, BorderSizePixel = 0, Position = UDim2.fromOffset(10, 142),
		Size = UDim2.fromOffset(CARD_W - 20, 70), Parent = body,
	})
	UILib.corner(panel, 16)
	UILib.gradient(panel, C.Cream, C.CreamRow)
	UILib.stroke(panel, C.Ink, 3, true)
	if level > 0 then
		effectLine(panel, 8, "NOW", "Gold", Config.staffEffectText(def, Config.staffValue(def, level)), C.Brown)
	else
		effectLine(panel, 8, "NOW", "Black", "Not on your team yet", C.Brown).TextTransparency = 0.35
	end
	if maxed then
		effectLine(panel, 38, "MAX", "Purple", "Top of their game!", C.Purple)
	else
		effectLine(panel, 38, level == 0 and "HIRE" or "NEXT", "Green", Config.staffEffectText(def, def.values[nextLevel]),
			C.GreenShadow)
	end

	-- the button
	local btn
	local bpos = UDim2.new(0, 10, 1, -74)
	local bsize = UDim2.new(1, -20, 0, 62)
	if maxed then
		btn = UILib.button({ parent = body, tone = "Purple", text = "MAX LEVEL", icon = "star", textSize = 22, iconSize = 28,
			size = bsize, position = bpos })
		btn.setEnabled(false)
	elseif locked then
		local rn = rankName(need)
		btn = UILib.button({
			parent = body, tone = "Purple", icon = "lock", textSize = 22, iconSize = 28, size = bsize, position = bpos,
			text = level == 0 and ("RANK %d"):format(need) or ("LV%d AT RANK %d"):format(nextLevel, need),
			onClick = function()
				local what = level == 0 and ("Hire a %s"):format(def.name) or ("%s level %d"):format(def.name, nextLevel)
				UILib.toast(("%s unlocks at Rank %d%s"):format(what, need, rn and (" (" .. rn .. ")") or ""), "info",
					"Every game your guests play earns XP for your Casino Rank.")
			end,
		})
	else
		local cost = def.costs[nextLevel] or 0
		btn = UILib.button({
			parent = body, tone = "Green", icon = "coin", textSize = 22, iconSize = 28, size = bsize, position = bpos,
			text = (level == 0 and "HIRE " or "PROMOTE ") .. UILib.short(cost),
			onClick = function() act(def, level, root) end,
		})
		ctx.affordable(btn, cost)
	end

	-- corner badge
	local badge
	if maxed then
		badge = { "MAX!", "Gold" }
	elseif locked and level == 0 then
		badge = { "RANK " .. need, "Purple" }
	elseif level > 0 then
		badge = { "HIRED", "Green" }
	end
	if badge then
		local b = UILib.badge(root, badge[1], badge[2], -8, 8)
		b.AnchorPoint = Vector2.new(1, 0)
		b.Position = UDim2.new(1, 8, 0, -12)
	end
	if not UILib.IsTouch then
		root.MouseEnter:Connect(function() UILib.tween(hover, { Scale = 1.03 }, 0.15) end)
		root.MouseLeave:Connect(function() UILib.tween(hover, { Scale = 1 }, 0.15) end)
	end
	return root
end

------------------------------------------------------------------
-- the crew bar over the cards
------------------------------------------------------------------
local function header(ctx, levels)
	local hired, team, total = 0, 0, #Config.Staff
	for _, def in Config.Staff do
		local lvl = levels[def.id] or 0
		if lvl > 0 then
			hired += 1
			team += Config.staffTeam(def, lvl)
		end
	end
	local bar = make("Frame", {
		Name = "CrewBar", BackgroundColor3 = C.White, BorderSizePixel = 0, Size = UDim2.new(1, -20, 0, HEADER_H - 8),
		Position = UDim2.fromOffset(6, 2), Parent = ctx.body,
	})
	UILib.corner(bar, 16)
	UILib.gradient(bar, C.CrimsonTop, C.CrimsonDeep)
	UILib.stroke(bar, C.Ink, 3, true)
	UILib.image(bar, "staff", { size = UDim2.fromOffset(54, 54), position = UDim2.fromOffset(6, -6) })
	UILib.text(bar, {
		text = "YOUR CREW", size = 24, xAlign = Enum.TextXAlignment.Left, gradient = { C.White, C.GoldTop },
		frameSize = UDim2.fromOffset(170, HEADER_H - 8), position = UDim2.fromOffset(66, 0),
	})
	chip(bar, nil, ("%d / %d ROLES HIRED"):format(hired, total), UDim2.fromOffset(236, 11))
	chip(bar, nil, ("TEAM OF %d"):format(team), UDim2.fromOffset(420, 11), C.GreenTop)
	if hired > 0 and deps.HudUI and deps.HudUI.travelTo then
		UILib.button({
			parent = bar, tone = "Blue", text = "SEE THEM", icon = "slot", textSize = 18, iconSize = 24,
			size = UDim2.fromOffset(150, 40), anchor = Vector2.new(1, 0.5), position = UDim2.new(1, -6, 0.5, -1),
			onClick = function()
				if ctx.panel and ctx.panel.close then ctx.panel.close() end
				deps.HudUI.travelTo("casino")
			end,
		})
	end
end

local function render(ctx)
	local levels = levelsNow()
	-- room for the crew bar, and wider cards than the shop's default cell
	ctx.grid.Position = UDim2.fromOffset(0, HEADER_H)
	ctx.grid.Size = UDim2.new(1, 0, 1, -HEADER_H)
	local layout = ctx.grid:FindFirstChildOfClass("UIGridLayout")
	if layout then
		layout.CellSize = UDim2.fromOffset(CARD_W, CARD_H)
		layout.CellPadding = UDim2.fromOffset(20, 24)
	end
	header(ctx, levels)
	for i, def in Config.Staff do
		local ok, err = pcall(card, ctx, def, i, levels[def.id] or 0)
		if not ok then warn("[StaffShopUI] " .. def.id .. ": " .. tostring(err)) end
	end
end

function StaffShopUI.open()
	if deps.ShopUI and deps.ShopUI.open then deps.ShopUI.open("staff") end
end

function StaffShopUI.start(d)
	deps = d or {}
	if deps.ShopUI and deps.ShopUI.registerTab then
		deps.ShopUI.registerTab({ id = "staff", label = "STAFF", order = 40, render = render })
	end
end

return StaffShopUI
