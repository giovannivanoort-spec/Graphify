--!nonstrict
-- ManageUI.luau — MY CASINO, three tabs:
--   MACHINES     every placed machine, grouped by floor, with MOVE / STORE / SELL
--   BUILDING     your floors, the GUEST FLOW readout (guests/min = the lower of
--                DEMAND and LOBBY, which one holds you back and the upgrades
--                that raise it; "busy city" guest weight), machine capacity and
--                the BUILD NEXT FLOOR button (locked until the floor's Casino Rank)
--   NAME & STYLE rename the casino (shown on its signs) and pick its colours
-- plus the per-machine popup you get when interacting with your own machine
-- (a stats board: bets, game time, guest win chance, house edge, XP / game, income
-- multipliers; three upgrade tracks with level pips and what the next level changes;
-- the x3 boost; move / store / sell). Stands get a sale / guests-served board.
-- ManageUI.openOverview(tab?)  tab = "machines" | "building" | "style"

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Remotes = require(Common:WaitForChild("Remotes"))
local Config = require(Common:WaitForChild("Config"))
local Materials = require(Common:WaitForChild("Materials"))
local UILib = require(script.Parent:WaitForChild("UILib"))
local PlacementController = require(script.Parent:WaitForChild("PlacementController"))
local UpgradesUI = require(script.Parent:WaitForChild("UpgradesUI"))
local A = UILib.Assets
local C = UILib.Colors
local F = UILib.Fonts

local ManageUI = {}

-- Other modules draw onto a tab after it renders: ManageUI.addTabExtra("building",
-- fn(page, state)) runs fn on every render of that tab ("machines" | "building" |
-- "style"); page holds the tab's frames (BUILDING: "Tower", "Info"). VipFloorUI
-- puts the VIP floor on the BUILDING tab's tower this way.
local tabExtras: {[string]: {(Instance, any) -> ()}} = {}
function ManageUI.addTabExtra(tab: string, fn: (Instance, any) -> ())
	tabExtras[tab] = tabExtras[tab] or {}
	table.insert(tabExtras[tab], fn)
end

local FLOW_REFRESH = 10 -- s between fresh snapshots while the BUILDING tab is up

------------------------------------------------------------------
-- rank gates + guest-flow helpers
------------------------------------------------------------------
-- a gate above your rank blocks buying; no rank in the snapshot = no gates
local function gateOpen(gate, rank): boolean
	gate, rank = tonumber(gate), tonumber(rank)
	return gate == nil or rank == nil or gate <= rank
end

local function rankName(r: number): string
	local ranks = Config.Progression and Config.Progression.Ranks
	local def = ranks and ranks[r]
	return def and def.name or ("Rank " .. tostring(r))
end

-- guests per minute: one decimal while small, whole numbers after
local function fmtRate(x): string
	x = tonumber(x) or 0
	if x < 10 then return string.format("%.1f", x) end
	return UILib.commas(math.floor(x + 0.5))
end

-- the tracks that raise each side of the flow (economy_spec 4 / 6.3):
-- DEMAND = machines x Billboards x Valet x Shuttles x Night Life,
-- LOBBY  = machines x Bigger Lobby x Valet / visit time (Walkways, Fast Dealers)
local FLOW_TRACKS = {
	DEMAND = { "marketing", "parking", "partyBus", "nightLife" },
	LOBBY = { "capacity", "patronSpeed", "dealers", "parking" },
}

-- up to two of them you can buy now (not maxed, gate open) + the next one a
-- rank-up will open ("Valet Parking (Rank 4)")
local function boosters(state, side: string)
	local cat = UILib.getCatalog()
	local byId = {}
	for _, t in (cat and cat.upgradeTracks or {}) do byId[t.id] = t end
	local levels = state.upgradeLevels or {}
	local now, ids, later = {}, {}, nil
	for _, id in FLOW_TRACKS[side] or {} do
		local t = byId[id]
		local lvl = tonumber(levels[id]) or 0
		if t and lvl < #t.values then
			local gate = t.gates and t.gates[lvl + 1]
			if gateOpen(gate, state.rank) then
				if #now < 2 then
					table.insert(now, t.name)
					table.insert(ids, id)
				end
			elseif not later then
				later = ("%s (Rank %d)"):format(t.name, tonumber(gate) or 0)
			end
		end
	end
	return now, ids, later
end

------------------------------------------------------------------
-- GUEST FLOW card (BUILDING tab): the big guests/min, a DEMAND and a LOBBY
-- meter (the bottleneck in crimson with a tag), a friendly hint naming the
-- upgrades that raise the bottleneck + a BOOST button, and the "busy city"
-- line when one guest you see stands for several (spec 6.4, weight W > 1)
------------------------------------------------------------------
local function flowCard(parent: Instance, state, order: number)
	local flow = type(state.flow) == "table" and state.flow or nil
	local weight = flow and tonumber(flow.weight) or 1
	local busy = weight > 1.05
	local card = UILib.make("Frame", {
		Name = "Flow", BackgroundColor3 = C.Cream, BorderSizePixel = 0, LayoutOrder = order,
		Size = UDim2.new(1, 0, 0, flow and (busy and 186 or 152) or 64), Parent = parent,
	})
	UILib.corner(card, 18)
	UILib.stroke(card, C.Ink, 3, true)
	if not flow then
		UILib.body(card, {
			text = "GUEST FLOW: guests are on their way - the numbers show up in a moment.", size = 15, wrap = true,
			frameSize = UDim2.new(1, -28, 1, 0), position = UDim2.fromOffset(14, 0),
		})
		return card
	end
	local demand, lobby = tonumber(flow.demand) or 0, tonumber(flow.lobby) or 0
	local rate = tonumber(flow.rate) or math.min(demand, lobby)
	local side = flow.bottleneck == "LOBBY" and "LOBBY" or "DEMAND"

	-- the big number
	UILib.body(card, {
		text = "GUESTS / MIN", font = F.Display, size = 16, color = C.Brown, xAlign = Enum.TextXAlignment.Center,
		frameSize = UDim2.fromOffset(128, 20), position = UDim2.fromOffset(10, 14),
	})
	UILib.text(card, {
		name = "Rate", text = fmtRate(rate), font = F.Number, size = 46, color = C.GreenTop, stroke = 4, shadow = 4,
		frameSize = UDim2.fromOffset(128, 56), position = UDim2.fromOffset(10, 36),
	})

	-- the two meters, scaled to the larger side
	local top = math.max(demand, lobby, 0.001)
	local meters = UILib.make("Frame", {
		Name = "Meters", BackgroundTransparency = 1, Position = UDim2.fromOffset(150, 10),
		Size = UDim2.new(1, -162, 0, 80), Parent = card,
	})
	for i, m in { { "DEMAND", demand }, { "LOBBY", lobby } } do
		local y = (i - 1) * 40
		local isNeck = m[1] == side
		UILib.body(meters, {
			text = m[1], font = F.Display, size = 17, color = isNeck and C.Crimson or C.Brown,
			frameSize = UDim2.fromOffset(84, 30), position = UDim2.fromOffset(0, y),
		})
		UILib.progressBar(meters, {
			name = m[1] .. "Bar", size = UDim2.new(1, -186, 0, 22), position = UDim2.fromOffset(86, y + 4),
			tone = isNeck and "Red" or "Green", textSize = 14, value = m[2] / top,
			text = fmtRate(m[2]) .. "/min",
		})
		if isNeck then
			local tag = UILib.badge(meters, "BOTTLENECK", "Red", -4, 3)
			tag.AnchorPoint = Vector2.new(1, 0)
			tag.Position = UDim2.new(1, 0, 0, y + 2)
			UILib.make("UIScale", { Name = "TagScale", Scale = 0.72, Parent = tag })
		end
	end

	-- the hint + BOOST
	local names, ids, later = boosters(state, side)
	local fix
	if #names > 0 then
		fix = "<b>" .. table.concat(names, "</b>, <b>") .. "</b>"
	elseif later then
		fix = "more machines (next: <b>" .. later .. "</b>)"
	else
		fix = "more machines"
	end
	local text = side == "DEMAND"
		and ("Your lobby has room - you need more guests. Raise <b>DEMAND</b>: %s."):format(fix)
		or ("Guests are lining up at the door! Raise <b>LOBBY</b>: %s."):format(fix)
	UILib.body(card, {
		name = "Hint", text = text, rich = true, wrap = true, size = 14, color = C.Brown,
		frameSize = UDim2.new(1, -176, 0, 48), position = UDim2.fromOffset(14, 96),
		yAlign = Enum.TextYAlignment.Top,
	})
	UILib.button({
		parent = card, tone = "Green", text = "BOOST", icon = "upgrade", textSize = 21,
		size = UDim2.fromOffset(140, 50), anchor = Vector2.new(1, 0), position = UDim2.new(1, -12, 0, 94),
		onClick = function()
			if ids[1] then
				UpgradesUI.open({ focus = ids[1] })
			else
				UpgradesUI.open({ tab = "guests" })
			end
		end,
	})

	-- busy city: each guest on screen counts several times (the guest weight)
	if busy then
		local strip = UILib.make("Frame", {
			Name = "BusyCity", BackgroundColor3 = C.White, Position = UDim2.fromOffset(10, 150),
			Size = UDim2.new(1, -20, 0, 28), Parent = card,
		})
		UILib.corner(strip, 999)
		UILib.gradient(strip, C.PurpleTop, C.Purple)
		UILib.stroke(strip, C.Ink, 2.5, true)
		local w = weight >= 10 and tostring(math.floor(weight + 0.5)) or string.format("%.1f", weight)
		UILib.text(strip, {
			text = ("BUSY CITY: EACH GUEST YOU SEE COUNTS x%s"):format(w), size = 15, stroke = 2, shadow = 2,
		})
	end
	return card
end

local TABS = {
	{ id = "machines", label = "MACHINES" },
	{ id = "building", label = "BUILDING" },
	{ id = "style", label = "NAME & STYLE" },
}
local SLOTS = {
	{ key = "walls", label = "WALLS" },
	{ key = "trim", label = "TRIM" },
	{ key = "neon", label = "NEON" },
	{ key = "carpet", label = "CARPET" },
}

local function findMachine(placedId: string)
	for _, m in Workspace:GetChildren() do
		if m:IsA("Model") and m:GetAttribute("PlacedId") == placedId then return m end
	end
	for _, m in Workspace:GetDescendants() do
		if m:IsA("Model") and m:GetAttribute("PlacedId") == placedId then return m end
	end
	return nil
end

local function report(res, okKind)
	if res and res.ok then
		UILib.toast(string.upper(res.message or "Done!"), okKind or "income")
	else
		UILib.toast(res and res.message or "Something went wrong", "error")
	end
end

local function smallButton(parent, tone, text, onClick, order)
	return UILib.button({
		parent = parent, tone = tone, text = text, textSize = 19, size = UDim2.fromOffset(112, 50),
		order = order, radius = 14, onClick = onClick,
	})
end

------------------------------------------------------------------
-- MACHINES tab
------------------------------------------------------------------
local function renderMachines(page, state, p)
	local building = state.building or {}
	local placed = state.placed or {}
	local header = ("MACHINES: %d / %d   •   %d FLOOR%s"):format(#placed, building.capacity or state.maxMachines or 14,
		building.stories or 1, (building.stories or 1) == 1 and "" or "S")
	if type(state.flow) == "table" and state.flow.rate then
		header ..= ("   •   %s GUESTS/MIN"):format(fmtRate(state.flow.rate))
	end
	UILib.body(page, { text = header, font = F.Display, size = 20, frameSize = UDim2.new(1, 0, 0, 28) })
	local list = UILib.scroller(page, { padding = 10, position = UDim2.fromOffset(0, 34), size = UDim2.new(1, 0, 1, -34),
		memory = "machines" })
	if #placed == 0 then
		UILib.body(list, {
			text = "Nothing placed yet - open ITEMS and place your first machine!", size = 16,
			xAlign = Enum.TextXAlignment.Center, frameSize = UDim2.new(1, 0, 0, 60),
		})
		return
	end
	-- group by floor, ground floor first
	local byFloor = {}
	for _, m in placed do
		local s = m.story or 1
		byFloor[s] = byFloor[s] or {}
		table.insert(byFloor[s], m)
	end
	local order = 0
	-- (+1: the VIP floor sits on top of the floors you bought)
	local vipStory = type(state.vipFloor) == "table" and tonumber(state.vipFloor.story) or nil
	for floor = 1, Config.Building.MaxStories + 1 do
		local items = byFloor[floor]
		if items then
			order += 1
			UILib.body(list, {
				text = floor == vipStory and "VIP LOUNGE  •  x" .. tostring(state.vipFloor.mult or 1.25) .. " EARNINGS"
					or (floor == 1 and "GROUND FLOOR" or ("FLOOR %d"):format(floor)), font = F.Display, size = 18,
				color = floor == vipStory and C.Purple or C.Crimson, frameSize = UDim2.new(1, 0, 0, 24), order = order,
			})
			for _, m in items do
				order += 1
				local isConc = m.kind == "concession"
				local up = m.upgrades or {}
				local lvl = (up.speed or 0) + (up.bets or 0) + (up.lucky or 0)
				local row = UILib.row({
					parent = list, order = order, height = 84, tone = A.TypeTone[m.type] or "Blue", icon = A.TypeIcon[m.type] or "star",
					model = { kind = "machine", id = m.machineId }, -- the real machine (ModelIcons)
					title = string.upper(m.name),
					desc = isConc and "Concession" or ("%s - %d upgrade%s"):format(m.type, lvl, lvl == 1 and "" or "s"),
					rightWidth = 380,
				})
				smallButton(row.right, "Blue", "MOVE", function()
					local inst = findMachine(m.placedId)
					if inst then p.close(); PlacementController.beginMove(inst) end
				end, 1)
				smallButton(row.right, "Orange", "STORE", function()
					local inst = findMachine(m.placedId)
					if inst then report(Remotes.PickupMachine():InvokeServer(inst), "info") end
				end, 2)
				smallButton(row.right, "Red", "SELL", function()
					local inst = findMachine(m.placedId)
					if inst then report(Remotes.SellMachine():InvokeServer(inst), "income") end
				end, 3)
			end
		end
	end
end

------------------------------------------------------------------
-- BUILDING tab: a little tower of floors + the next-floor purchase
------------------------------------------------------------------
local function renderBuilding(page, state, cashValue, shownNew)
	local b = state.building or {}
	local stories, maxStories = b.stories or 1, b.maxStories or Config.Building.MaxStories
	local perStory = Config.Building.MachinesPerStory
	local storyRanks = type(state.storyRanks) == "table" and state.storyRanks or {}
	local rank = tonumber(state.rank)
	local cost = tonumber(b.nextStoryCost) or 0

	-- the tower (left): owned floors in crimson, the rest show their price or
	-- the Casino Rank that opens them
	local tower = UILib.make("Frame", {
		Name = "Tower", BackgroundTransparency = 1, Position = UDim2.fromOffset(20, 6), Size = UDim2.fromOffset(300, 420), Parent = page,
	})
	local floorH = 64
	for s = 1, maxStories do
		local owned = s <= stories
		local gate = tonumber(storyRanks[s])
		local open = gateOpen(gate, rank)
		local f = UILib.make("Frame", {
			Name = "Floor" .. s, BackgroundColor3 = C.White, AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.new(0, 0, 1, -(s - 1) * (floorH + 8)), Size = UDim2.new(1, 0, 0, floorH), Parent = tower,
		})
		UILib.corner(f, 14)
		if owned then
			UILib.gradient(f, C.CrimsonTop, C.CrimsonDeep)
		else
			UILib.gradient(f, C.Cream, C.CreamLine)
		end
		UILib.stroke(f, C.Ink, 3.5, true)
		local label = s == 1 and "GROUND" or ("FLOOR " .. s)
		if not owned then
			if not open then
				label ..= "  •  RANK " .. tostring(gate)
			elseif s == stories + 1 then
				label ..= "  •  " .. UILib.moneyShort(cost)
			else
				label ..= "  •  LOCKED"
			end
		end
		local face = UILib.text(f, {
			text = label, size = 22, xAlign = Enum.TextXAlignment.Left,
			frameSize = UDim2.new(1, -66, 1, 0), position = UDim2.fromOffset(16, 0),
			-- unowned floors: flat brown on cream (an ink outline muddies it)
			color = owned and C.GoldTop or C.Brown, shadow = owned and 3 or 0, stroke = (not owned) and 0 or nil,
			transparency = owned and 0 or 0.25,
		})
		UILib.fitText(face, label, 22, 226, 15) -- "FLOOR 5  •  RANK 10" stays clear of the lock
		local mark = owned and UILib.Tex.check or (open and "build" or "lock")
		UILib.image(f, mark, {
			size = UDim2.fromOffset(owned and 34 or 44, owned and 34 or 44), anchor = Vector2.new(1, 0.5),
			position = UDim2.new(1, owned and -14 or -8, 0.5, 0), transparency = (not owned and open and s > stories + 1) and 0.5 or 0,
		})
	end

	-- the info + purchase (right)
	local info = UILib.make("Frame", {
		Name = "Info", BackgroundTransparency = 1, Position = UDim2.fromOffset(350, 4), Size = UDim2.new(1, -370, 1, -8), Parent = page,
	})
	UILib.list(info, "y", 8)
	UILib.body(info, {
		text = ("YOUR CASINO HAS %d OF %d FLOORS"):format(stories, maxStories), font = F.Display, size = 26,
		color = C.Crimson, frameSize = UDim2.new(1, 0, 0, 32), order = 1,
	})
	UILib.body(info, {
		text = ("Every floor holds %d more machines and gets its own elevator stop. Guests ride up to play."):format(perStory),
		size = 15, wrap = true, autoY = true, frameSize = UDim2.new(1, 0, 0, 20), order = 2,
	})
	UILib.body(info, {
		text = ("MACHINE SLOTS: %d"):format(b.capacity or perStory), font = F.Display, size = 22,
		color = C.Green, frameSize = UDim2.new(1, 0, 0, 28), order = 3,
	})
	-- guest flow (servers with ranks send it; nil until the first flow tick)
	if type(state.flow) == "table" or rank ~= nil then
		flowCard(info, state, 4)
	end
	if stories >= maxStories then
		UILib.button({ parent = info, tone = "Purple", text = "TOP FLOOR REACHED", textSize = 24,
			size = UDim2.fromOffset(380, 70), order = 5 })
		return nil
	end

	local n = stories + 1
	local gate = tonumber(storyRanks[n])
	local locked = not gateOpen(gate, rank)
	local btn
	if locked then
		-- spec 6.1: Buildings.buyStory refuses below StoryRanks[n]; say so up front
		btn = UILib.button({
			parent = info, tone = "Black", text = ("FLOOR %d UNLOCKS AT RANK %d"):format(n, gate), icon = "lock",
			textSize = 22, size = UDim2.fromOffset(440, 70), order = 5,
			onClick = function()
				UILib.toast(("Floor %d unlocks at Rank %d (%s)"):format(n, gate, rankName(gate)), "error",
					("Then it costs %s."):format(UILib.moneyFull(cost)))
			end,
		})
		UILib.body(info, {
			text = ("Reach %s, then build it for %s."):format(string.upper(rankName(gate)), UILib.moneyFull(cost)),
			size = 14, color = C.Brown, frameSize = UDim2.new(1, 0, 0, 18), order = 6,
		})
	else
		btn = UILib.button({
			parent = info, tone = "Green", text = ("BUILD FLOOR %d  •  %s"):format(n, UILib.moneyShort(cost)),
			icon = "build", textSize = 24, size = UDim2.fromOffset(440, 70), order = 5,
			onClick = function()
				local res = Remotes.BuyStory():InvokeServer()
				if res and res.ok then
					UILib.toast(string.upper(res.message or "NEW FLOOR!"), "unlock", "Ride the elevator to decorate it.")
				else
					UILib.toast(res and res.message or "Purchase failed", "error")
				end
			end,
		})
		btn.setTone(cashValue.Value >= cost and "Green" or "Red")
	end
	-- a floor a rank-up just opened: NEW until you've seen it here
	if UILib.isNew("floor", n) or shownNew[n] then
		shownNew[n] = true
		local badge = UILib.badge(btn.Instance, "NEW!", "Red", -10, 8)
		badge.Position = UDim2.fromOffset(-10, -12)
		UILib.markSeen("floor", n)
	end
	if locked then return nil end
	return { handle = btn, cost = cost }
end

------------------------------------------------------------------
-- NAME & STYLE tab
------------------------------------------------------------------
-- the carpet row: each swatch shows a crop of the carpet's own pattern (the
-- flat swatch colour until / unless its texture exists) and the name of the
-- hovered (else the chosen) carpet sits at the end of the row
local function carpetRow(col, theme, order: number)
	local carpets = Config.Building.Carpets
	local swatches = Config.Building.Palettes.carpet
	local chosen = carpets[theme.carpet or 1] or carpets[1]
	local row = UILib.make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 52), LayoutOrder = order, Parent = col })
	UILib.list(row, "x", 8, nil, Enum.VerticalAlignment.Center)
	UILib.body(row, { text = "CARPET", font = F.Display, size = 20, color = C.Brown,
		frameSize = UDim2.fromOffset(110, 40), order = 0 })
	local caption = UILib.body(row, { text = string.upper(chosen.name), font = F.Display, size = 18, color = C.Crimson,
		frameSize = UDim2.fromOffset(220, 40), order = #carpets + 1 })
	for idx, carpet in carpets do
		local selected = theme.carpet == idx
		local def = Materials.Defs[carpet.key]
		local pattern = def and def.color or ""
		-- the colour map is 8 studs of carpet: show a quarter (2 motifs across)
		local sw = UILib.make("ImageButton", {
			Name = "Swatch", AutoButtonColor = false, BackgroundColor3 = swatches[idx] or C.Ink,
			Image = pattern, ScaleType = Enum.ScaleType.Crop,
			ImageRectSize = pattern ~= "" and Vector2.new(512, 512) or Vector2.zero,
			Size = UDim2.fromOffset(selected and 60 or 54, selected and 50 or 44), LayoutOrder = idx, Parent = row,
		})
		UILib.corner(sw, 12)
		UILib.stroke(sw, selected and C.Gold or C.Ink, selected and 5 or 3, true)
		sw.MouseEnter:Connect(function() caption.Text = string.upper(carpet.name) end)
		sw.MouseLeave:Connect(function() caption.Text = string.upper(chosen.name) end)
		sw.Activated:Connect(function()
			local res = Remotes.SetCasinoTheme():InvokeServer("carpet", idx)
			if not (res and res.ok) then UILib.toast(res and res.message or "Couldn't change carpet", "error") end
		end)
	end
end

local function renderStyle(page, state)
	local b = state.building or {}
	local theme = b.theme or Config.Building.DefaultTheme
	local col = UILib.make("Frame", { Name = "Col", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = page })
	UILib.list(col, "y", 12)

	-- name
	UILib.body(col, { text = "CASINO NAME", font = F.Display, size = 22, color = C.Crimson,
		frameSize = UDim2.new(1, 0, 0, 26), order = 1 })
	local nameRow = UILib.make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 62), LayoutOrder = 2, Parent = col })
	UILib.list(nameRow, "x", 12, nil, Enum.VerticalAlignment.Center)
	local boxFrame = UILib.make("Frame", {
		BackgroundColor3 = C.White, Size = UDim2.fromOffset(520, 56), LayoutOrder = 1, Parent = nameRow,
	})
	UILib.corner(boxFrame, 16)
	UILib.stroke(boxFrame, C.Ink, 3.5, true)
	local box = UILib.make("TextBox", {
		BackgroundTransparency = 1, Size = UDim2.new(1, -24, 1, 0), Position = UDim2.fromOffset(12, 0),
		Font = F.Display, TextSize = 26, TextColor3 = C.Ink, PlaceholderText = "Type a name...",
		PlaceholderColor3 = C.CreamLine, Text = b.name or "", ClearTextOnFocus = false, TextXAlignment = Enum.TextXAlignment.Left,
		Parent = boxFrame,
	}) :: TextBox
	box:GetPropertyChangedSignal("Text"):Connect(function()
		if #box.Text > Config.Building.NameMaxLength then box.Text = box.Text:sub(1, Config.Building.NameMaxLength) end
	end)
	UILib.button({
		parent = nameRow, tone = "Green", text = "SAVE", textSize = 24, size = UDim2.fromOffset(150, 58), order = 2,
		onClick = function()
			local res = Remotes.SetCasinoName():InvokeServer(box.Text)
			if res and res.ok then
				UILib.toast("RENAMED!", "unlock", res.message)
			else
				UILib.toast(res and res.message or "Couldn't rename", "error")
			end
		end,
	})
	UILib.body(col, {
		text = ("%d-%d letters. Shown on your sign, your facade and your roof."):format(Config.Building.NameMinLength,
			Config.Building.NameMaxLength), size = 14, frameSize = UDim2.new(1, 0, 0, 18), order = 3,
	})

	-- colour rows (the carpet row shows the carpets' patterns + names)
	for i, slot in SLOTS do
		if slot.key == "carpet" then
			carpetRow(col, theme, 3 + i)
		else
			local row = UILib.make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 52), LayoutOrder = 3 + i, Parent = col })
			UILib.list(row, "x", 8, nil, Enum.VerticalAlignment.Center)
			UILib.body(row, { text = slot.label, font = F.Display, size = 20, color = C.Brown,
				frameSize = UDim2.fromOffset(110, 40), order = 0 })
			for idx, color in Config.Building.Palettes[slot.key] do
				local selected = theme[slot.key] == idx
				local sw = UILib.make("TextButton", {
					Name = "Swatch", Text = "", AutoButtonColor = false, BackgroundColor3 = color,
					Size = UDim2.fromOffset(selected and 48 or 42, selected and 48 or 42), LayoutOrder = idx, Parent = row,
				})
				UILib.corner(sw, 12)
				UILib.stroke(sw, selected and C.Gold or C.Ink, selected and 5 or 3, true)
				sw.Activated:Connect(function()
					local res = Remotes.SetCasinoTheme():InvokeServer(slot.key, idx)
					if not (res and res.ok) then UILib.toast(res and res.message or "Couldn't change colour", "error") end
				end)
			end
		end
	end
end

function ManageUI.openOverview(initialTab: string?)
	-- the HUD's CASINO tile hands its Activated args (an InputObject) straight in
	local current = "machines"
	for _, t in TABS do
		if initialTab == t.id then current = t.id end
	end
	local p = UILib.panel({ name = "ManagePanel", title = "MY CASINO", icon = "slot", width = 980, height = 610 })
	local content = p.content
	local cashValue = UILib.getCashValue()
	local page = UILib.make("Frame", {
		Name = "Page", BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 60), Size = UDim2.new(1, 0, 1, -60), Parent = content,
	})
	local buyButton = nil
	local shownNew = {} -- floors whose NEW badge stays up while this panel is open

	local function render(state)
		if not p.alive then return end
		-- keep the name box's text while typing: the style tab re-renders on changes
		local focused = page:FindFirstChildWhichIsA("TextBox", true)
		if focused and focused:IsFocused() then return end
		for _, ch in page:GetChildren() do ch:Destroy() end
		buyButton = nil
		if current == "machines" then
			renderMachines(page, state, p)
		elseif current == "building" then
			buyButton = renderBuilding(page, state, cashValue, shownNew)
		else
			renderStyle(page, state)
		end
		-- what other modules add to this tab (ManageUI.addTabExtra)
		for _, fn in (tabExtras[current] or {}) do
			local ok, err = pcall(fn, page, state)
			if not ok then warn("[ManageUI] " .. current .. " extra: " .. tostring(err)) end
		end
	end
	-- the guest-flow numbers only travel with a snapshot, and the server pushes
	-- one on purchases: fetch a fresh one on open, on a switch to BUILDING and
	-- every FLOW_REFRESH seconds while the flow card is up
	local fetching = false
	local function refresh()
		if fetching then return end
		fetching = true
		task.spawn(function()
			local ok, snap = pcall(function() return Remotes.GetData():InvokeServer() end)
			fetching = false
			if ok and snap and p.alive then UILib.setState(snap) end
		end)
	end

	UILib.tabs(content, TABS, function(id)
		current = id
		render(UILib.state)
		if id == "building" then refresh() end
	end, current)

	local conn = cashValue.Changed:Connect(function()
		if buyButton then buyButton.handle.setTone(cashValue.Value >= buyButton.cost and "Green" or "Red") end
	end)
	local unsub = UILib.subscribe(render)
	p.onClose(function() unsub(); conn:Disconnect() end)
	refresh()
	task.spawn(function()
		while true do
			task.wait(FLOW_REFRESH)
			if not p.alive then break end
			if current == "building" then refresh() end
		end
	end)
end

------------------------------------------------------------------
-- MACHINE POPUP (the owner interacts with their own machine): a velvet STATS BOARD
-- (MachineStats: the bets guests can place, how long a game takes, how often guests
-- win, the house edge, XP a game, and an INCOME band with this machine's multipliers:
-- VIP floor, x3 boost, rebirth perk, VIP pass, ticket boost, cash bonus), the three
-- upgrade rows (level pips + what the next level changes: "Game time 1.0 s -> 0.84 s"),
-- the x3 boost strip (BoostFX) and MOVE / STORE / SELL. Stands get a board of their
-- own (sale per guest, guests served a minute, sales a minute, stand stops).
------------------------------------------------------------------
local UPGRADE_KINDS = { "speed", "bets", "lucky" }
local UPGRADE_LOOK = { speed = { "stopwatch", "Blue" }, bets = { "chips", "Green" }, lucky = { "chance", "Purple" } }
local UPGRADE_STATS = { speed = { "time" }, bets = { "bets" }, lucky = { "win", "edge" } } -- they pop on a level-up

-- the x3 machine boost strip under the upgrades (BoostFX.machineSection; optional:
-- without the module the popup keeps its old size)
local BOOST_Y, BOOST_H = 344, 90   -- where the strip starts / how much taller the popup gets
local STATS_H = 96                 -- the stats board, top of the popup
local ROW_H, ROW_GAP = 74, 6       -- the upgrade rows under it (104 .. 338)
local ROWS_Y = STATS_H + 8
local function boostSection()
	local mod = script.Parent:FindFirstChild("BoostFX")
	if not mod then return nil end
	local ok, res = pcall(require, mod)
	return (ok and type(res) == "table" and type(res.machineSection) == "function") and res.machineSection or nil
end

-- MachineStats (CasinoCommon), required on first use: without it the popup still sells upgrades
local statsModule, statsWarned = nil, false
local function machineStats()
	if statsModule then return statsModule end
	local mod = Common:FindFirstChild("MachineStats")
	if not mod then return nil end
	local ok, res = pcall(require, mod)
	if ok and type(res) == "table" then
		statsModule = res
	elseif not statsWarned then
		statsWarned = true
		warn("[ManageUI] MachineStats: " .. tostring(res))
	end
	return statsModule
end

local TextService = game:GetService("TextService")
local VELVET_TOP, VELVET_BOTTOM = Color3.fromHex("#8E0F22"), Color3.fromHex("#3B0E19")
local CHIP_TONE = { vipFloor = "Purple", boost = "Orange", perk = "Pink", vipPass = "Gold", tickets = "Blue", cash = "Green" }
local function hexOf(c: Color3): string
	return "#" .. c:ToHex()
end
local TXT_NOW, TXT_ARROW, TXT_NEXT = hexOf(C.Brown), hexOf(C.Crimson), hexOf(C.GreenShadow)
local TXT_MAX, TXT_WARN = hexOf(C.PurpleShadow), hexOf(C.CrimsonDeep)

-- owner-wide earnings multipliers (Gambling: Monetization.getEarningsMultiplier): the
-- VIP pass's x2 and the Ticket Shop's 2X cash while it runs
local function ownerEarnings(state)
	local parts = {}
	if state.vip then
		for _, gp in ((Config.Monetization or {}).Gamepasses or {}) do
			local e = gp.effect
			local m = type(e) == "table" and e.vipBadge and tonumber(e.earningsMult)
			if m and m ~= 1 then table.insert(parts, { key = "vipPass", label = "VIP PASS", mult = m, icon = "crown" }) end
		end
	end
	if UILib.secondsLeft(tonumber(state.boostSeconds) or 0) > 0 then
		table.insert(parts, { key = "tickets", label = "TICKET BOOST", icon = "ticket",
			mult = tonumber(state.boostMult) or tonumber(Config.BoostMultiplier) or 2 })
	end
	return parts
end

-- one income chip: "x1.25 VIP FLOOR" on its tone, an icon riding on the left (a crowded
-- band, 4+ chips, shows just the icon and "x1.25")
local function chipIcon(part): string?
	if part.key == "vipFloor" and UILib.resolveIcon("vipfloor") ~= "" then return "vipfloor" end
	return part.icon and UILib.resolveIcon(part.icon) ~= "" and part.icon or nil
end
local function chipText(part, compact: boolean): string
	if compact and chipIcon(part) then return part.text or "" end
	return ("%s %s"):format(part.text or "", part.label or "")
end
local function chip(parent: Instance, part, compact: boolean, order: number)
	local t = UILib.Tones[CHIP_TONE[part.key] or "Gold"] or UILib.Tones.Gold
	local f = UILib.make("Frame", {
		Name = "Chip_" .. tostring(part.key), BackgroundColor3 = C.White, BorderSizePixel = 0,
		Size = UDim2.fromOffset(0, 22), AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = order, Parent = parent,
	})
	UILib.corner(f, 999)
	UILib.gradient(f, t.top, t.base)
	UILib.stroke(f, C.Ink, 2, true)
	UILib.pad(f, 3, 0, 9, 0)
	UILib.list(f, "x", 3, nil, Enum.VerticalAlignment.Center)
	local icon = chipIcon(part)
	if icon then UILib.image(f, icon, { size = UDim2.fromOffset(22, 22), order = 1 }) end
	UILib.text(f, {
		text = chipText(part, compact), size = 14, autoX = true, frameSize = UDim2.fromScale(0, 1), order = 2,
		stroke = 1.5, shadow = 1,
	})
	return f
end
-- the band's chips at full size (design px), for the fit check
local function chipsWidth(parts, compact: boolean): number
	local w = 0
	for _, part in parts do
		local ok, b = pcall(function()
			return TextService:GetTextSize(chipText(part, compact), 14, F.Display, Vector2.new(1000, 100))
		end)
		w += (ok and b.X or 90) + 12 + (chipIcon(part) and 25 or 0) + 6
	end
	return w
end

-- one stat: 3D icon, gold label, big number (shrunk to fit the cell)
local function statCell(parent: Instance, o)
	local cell = UILib.make("Frame", {
		Name = "Stat_" .. o.id, BackgroundTransparency = 1, Size = UDim2.new(0, o.width, 1, 0),
		LayoutOrder = o.order, Parent = parent,
	})
	if o.order > 1 then -- a gold hairline between the cells
		UILib.make("Frame", {
			Name = "Divider", BackgroundColor3 = C.Gold, BackgroundTransparency = 0.6, BorderSizePixel = 0,
			AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, -1, 0.5, 0), Size = UDim2.new(0, 2, 0.72, 0),
			Parent = cell,
		})
	end
	UILib.image(cell, o.icon, {
		name = "Icon", size = UDim2.fromOffset(44, 44), anchor = Vector2.new(0, 0.5), position = UDim2.new(0, 1, 0.5, 0),
	})
	local label = UILib.body(cell, {
		name = "Label", text = o.label, font = F.Display, size = 14, color = C.GoldTop,
		frameSize = UDim2.new(1, -48, 0, 18), position = UDim2.fromOffset(47, 5),
	})
	UILib.fitText(label, o.label, 14, o.width - 50, 10)
	local face, holder = UILib.text(cell, {
		name = "Value", text = o.value, font = F.Number, size = 24, gradient = { C.White, C.GoldTop },
		stroke = 2.5, shadow = 2, xAlign = Enum.TextXAlignment.Left,
		frameSize = UDim2.new(1, -48, 0, 28), position = UDim2.fromOffset(47, 23),
	})
	UILib.fitText(face, o.value, 24, o.width - 52, 13)
	return holder
end

-- the velvet scoreboard: o = { cells = { { id, icon, label, value, width } }, income =
-- MachineStats parts, total = "= x3.75", hint (no parts) }; returns { [cell id] = value holder }
local function statsBoard(parent: Instance, o)
	local board = UILib.make("Frame", {
		Name = "StatsBoard", BackgroundColor3 = C.White, BorderSizePixel = 0,
		Size = UDim2.new(1, -8, 0, STATS_H), Parent = parent,
	})
	UILib.corner(board, 18)
	UILib.gradient(board, VELVET_TOP, VELVET_BOTTOM)
	UILib.stroke(board, C.Ink, 3.5, true)
	local pattern = UILib.make("ImageLabel", {
		Name = "Pattern", BackgroundTransparency = 1, Image = UILib.Tex.pattern, ScaleType = Enum.ScaleType.Tile,
		TileSize = UDim2.fromOffset(34, 34), ImageColor3 = C.Gold, ImageTransparency = 0.92,
		Size = UDim2.fromScale(1, 1), Parent = board,
	})
	UILib.corner(pattern, 18)
	local shine = UILib.make("Frame", {
		Name = "Shine", BackgroundColor3 = C.White, BackgroundTransparency = 0.9, BorderSizePixel = 0,
		Position = UDim2.fromOffset(12, 5), Size = UDim2.new(1, -24, 0, 20), Parent = board,
	})
	UILib.corner(shine, 10)
	local trim = UILib.make("Frame", {
		Name = "Trim", BackgroundTransparency = 1, Position = UDim2.fromOffset(4, 4), Size = UDim2.new(1, -8, 1, -8),
		Parent = board,
	})
	UILib.corner(trim, 14)
	UILib.stroke(trim, C.Gold, 1.5, true, 0.45)

	local cells = UILib.make("Frame", {
		Name = "Cells", BackgroundTransparency = 1, Position = UDim2.fromOffset(10, 4), Size = UDim2.new(1, -20, 0, 56),
		Parent = board,
	})
	UILib.list(cells, "x", 0, nil, Enum.VerticalAlignment.Center)
	local values = {}
	for i, c in o.cells do
		c.order = i
		values[c.id] = statCell(cells, c)
	end

	-- INCOME: what multiplies this machine's earnings, and the total
	local band = UILib.make("Frame", {
		Name = "Income", BackgroundColor3 = C.Ink, BackgroundTransparency = 0.25, BorderSizePixel = 0,
		Position = UDim2.new(0, 8, 1, -35), Size = UDim2.new(1, -16, 0, 28), Parent = board,
	})
	UILib.corner(band, 999)
	local items = UILib.make("Frame", {
		Name = "Items", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 6, 0.5, 0), Size = UDim2.new(1, -112, 0, 24), Parent = band,
	})
	UILib.list(items, "x", 6, nil, Enum.VerticalAlignment.Center)
	UILib.image(items, "cash", { size = UDim2.fromOffset(26, 26), order = 1 })
	UILib.body(items, {
		text = "INCOME", font = F.Display, size = 15, color = C.GoldTop, autoX = true,
		frameSize = UDim2.fromOffset(0, 22), order = 2,
	})
	local parts = o.income or {}
	-- crowded (4+ chips): icon + "x1.25" only, and shrink the row if it still runs into
	-- the total (design px: the items frame is 704 - 112 wide; the icon + INCOME take ~100)
	local compact = #parts >= 4
	local need = 100 + chipsWidth(parts, compact)
	if need > 592 then
		UILib.make("UIScale", { Name = "Fit", Scale = math.max(0.7, 592 / need), Parent = items })
	end
	for i, part in parts do chip(items, part, compact, 2 + i) end
	if #parts == 0 and o.hint then
		UILib.body(items, {
			text = o.hint, size = 14, font = F.Heavy, color = C.Cream, transparency = 0.2, autoX = true,
			frameSize = UDim2.fromOffset(0, 22), order = 50,
		})
	end
	if #parts > 0 then
		UILib.text(band, {
			name = "Total", text = o.total or "", font = F.Number, size = 20, gradient = { C.White, C.GoldTop },
			stroke = 2, shadow = 2, xAlign = Enum.TextXAlignment.Right, anchor = Vector2.new(1, 0.5),
			position = UDim2.new(1, -14, 0.5, 0), frameSize = UDim2.fromOffset(96, 26),
		})
	end
	return values
end

-- an upgrade row's second line: what the next level changes
--   "Game time 1.0 s -> 0.84 s  (+19% games)"   "Max bet $75 -> $93  (guests bet ~$20)"
--   "Guests win 29% -> 28%   House edge 42% -> 43%"
local function deltaText(MS, kind: string, now, nxt): string
	local lines = MS.upgradeLines(kind, now, nxt)
	local function label(text: string): string
		return ('<font color="%s" transparency="0.25">%s</font>'):format(TXT_NOW, text)
	end
	if nxt and kind == "lucky" and nxt.tilt <= now.tilt + 1e-9 then
		return ('%s <font color="%s">%s</font>    <font color="%s">House tilt maxed (%s): no more effect</font>'):format(
			label("Guests win"), TXT_NOW, MS.percent(now.guestWinChance), TXT_WARN, MS.percent(now.tilt))
	end
	if nxt and kind == "speed" and nxt.gameSeconds >= now.gameSeconds - 1e-6 then
		return ('%s <font color="%s">%s</font>    <font color="%s">As fast as it gets: no more effect</font>'):format(
			label("Game time"), TXT_NOW, MS.seconds(now.gameSeconds), TXT_WARN)
	end
	local parts = {}
	for _, l in lines do
		if l.next then
			table.insert(parts, ('%s <font color="%s">%s</font>  <font color="%s">→</font>  <font color="%s">%s</font>'):format(
				label(l.label), TXT_NOW, l.now, TXT_ARROW, TXT_NEXT, l.next))
		else
			table.insert(parts, ('%s <font color="%s">%s</font>'):format(label(l.label), TXT_NOW, l.now))
		end
	end
	local s = table.concat(parts, "     ")
	if not nxt then
		return s .. ('     <font color="%s">MAXED</font>'):format(TXT_MAX)
	end
	if kind == "speed" then
		local more = now.gameSeconds / math.max(1e-6, nxt.gameSeconds) - 1
		s ..= ('   <font color="%s">(+%d%% games)</font>'):format(TXT_NEXT, math.floor(more * 100 + 0.5))
	elseif kind == "bets" and now.avgBet then
		if now.avgBet >= now.maxBet * 0.85 then
			s ..= ('   <font color="%s">(guests max it out!)</font>'):format(TXT_NEXT)
		else
			s ..= ('   %s'):format(label(("(guests bet ~%s)"):format(MS.money(now.avgBet))))
		end
	end
	return s
end

function ManageUI.openForMachine(machine: Instance)
	local isConc = machine:GetAttribute("Kind") == "concession"
	local gameType = machine:GetAttribute("GameType") or "Slots"
	local boost = (not isConc) and boostSection() or nil
	local p = UILib.panel({
		name = "MachinePanel", title = string.upper(machine.Name or "Machine"), icon = A.TypeIcon[gameType] or "slot",
		iconModel = { kind = "machine", id = machine:GetAttribute("MachineId") }, -- the real machine in the ribbon
		width = 820, height = isConc and 300 or (560 + (boost and BOOST_H or 0)),
	})
	local content = p.content
	local cashValue = UILib.getCashValue()
	-- the server's view of this machine (snapshot placed[i]): next upgrade prices, sell refund
	local function placedEntry()
		local pid = machine:GetAttribute("PlacedId")
		if pid == nil then return nil end
		for _, e in (UILib.state.placed or {}) do
			if e.placedId == pid then return e end
		end
		return nil
	end
	local entry = placedEntry()
	local refund = entry and tonumber(entry.refund)

	local actions = UILib.make("Frame", {
		Name = "Actions", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -4), Size = UDim2.fromOffset(0, 62), AutomaticSize = Enum.AutomaticSize.X,
		Parent = content,
	})
	UILib.list(actions, "x", 14, nil, Enum.VerticalAlignment.Center)
	UILib.button({ parent = actions, tone = "Blue", text = "MOVE", icon = "build", textSize = 22, size = UDim2.fromOffset(190, 60), order = 1,
		onClick = function() p.close(); PlacementController.beginMove(machine) end })
	UILib.button({ parent = actions, tone = "Orange", text = "STORE", icon = "items", textSize = 22, size = UDim2.fromOffset(190, 60), order = 2,
		onClick = function()
			local res = Remotes.PickupMachine():InvokeServer(machine)
			report(res, "info")
			if res and res.ok then p.close() end
		end })
	UILib.button({ parent = actions, tone = "Red", text = refund and ("SELL " .. UILib.moneyShort(refund)) or "SELL",
		icon = "cash", textSize = refund and 20 or 22, size = UDim2.fromOffset(190, 60), order = 3,
		onClick = function()
			local res = Remotes.SellMachine():InvokeServer(machine)
			report(res, "income")
			if res and res.ok then p.close() end
		end })

	if isConc then
		-- a stand (MachineStats.stand): what one guest spends here (its price x your rank's
		-- clientele x stand bonuses), the guests it serves a minute (your guest flow x the
		-- chance an arriving guest stops at a stand x this stand's share of those stops),
		-- what that makes a minute, and the stop chance (more KINDS of stands: more stops)
		local standDef = Config.getMachineDef(machine:GetAttribute("MachineId"))
		local board = UILib.make("Frame", {
			Name = "StandStats", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, STATS_H), Parent = content,
		})
		local function renderStand()
			if not p.alive then return end
			for _, ch in board:GetChildren() do ch:Destroy() end
			local state = UILib.state
			local MS = machineStats()
			-- the stands in your casino (a guest picks one weighted by its revenue)
			local kinds, nKinds, total = {}, 0, 0
			for _, e in (state.placed or {}) do
				local d = e.kind == "concession" and Config.getMachineDef(e.machineId)
				if d then
					if not kinds[d.type] then
						kinds[d.type] = true
						nKinds += 1
					end
					total += math.max(0, tonumber(d.revenuePerVisit) or 0)
				end
			end
			local flow = type(state.flow) == "table" and state.flow or nil
			local st = MS and standDef and MS.stand(standDef, state.effects, {
				clientele = state.clientele, rate = flow and flow.rate, kinds = nKinds, totalRevenue = total,
				Earnings = ownerEarnings(state),
			})
			if not st then
				UILib.body(board, {
					text = "Guests buy here when they arrive.", size = 18, xAlign = Enum.TextXAlignment.Center,
					frameSize = UDim2.new(1, 0, 0, 40), position = UDim2.fromOffset(0, 10),
				})
				return
			end
			local served = st.guestsPerMinute
			statsBoard(board, {
				cells = {
					{ id = "sale", icon = A.TypeIcon[gameType] or "popcorn", label = "SALE / GUEST", width = 176,
					  value = MS.money(st.salePerGuest) },
					{ id = "served", icon = "staff", label = "SERVED / MIN", width = 176,
					  value = served and (served < 10 and ("%.1f"):format(served) or UILib.commas(math.floor(served + 0.5))) or "..." },
					{ id = "sales", icon = "cash", label = "SALES / MIN", width = 176,
					  value = st.salesPerMinute and MS.money(st.salesPerMinute) or "..." },
					{ id = "stops", icon = "chance", label = "STAND STOPS", width = 172, value = MS.percent(st.stopChance) },
				},
				income = st.income,
				total = #st.income > 0 and ("= " .. MS.mult(st.incomeMult)) or "x1",
				hint = ("VIP guests spend %s here"):format(MS.money(st.vipSale)),
			})
		end
		local unsub = UILib.subscribe(function() renderStand() end)   -- (runs now, then on every snapshot)
		p.onClose(unsub)
		return
	end

	-- the machine's def (Config is replicated): upgrade prices scale with its catalog
	-- price (Config.machineUpgradeCost, the same formula Placement charges)
	local def = Config.getMachineDef(machine:GetAttribute("MachineId"))
	local maxLevel = tonumber(Config.MachineUpgradeMaxLevel) or 5
	local function upgradeCost(kind: string, lvl: number): number
		-- the snapshot's price when it describes this level (it lags a push behind a purchase)
		local e = placedEntry()
		local fromServer = e and type(e.upgradeCosts) == "table" and tonumber(e.upgradeCosts[kind])
		if fromServer and type(e.upgrades) == "table" and tonumber(e.upgrades[kind]) == lvl then
			return fromServer
		end
		local c = def and Config.machineUpgradeCost and Config.machineUpgradeCost(def, lvl + 1)
		return tonumber(c) or tonumber((Config.MachineUpgradeCosts or {})[lvl + 1]) or 0
	end
	local function levelsNow()
		local out = {}
		for _, kind in UPGRADE_KINDS do
			local attr = kind:sub(1, 1):upper() .. kind:sub(2) .. "Level"
			out[kind] = math.clamp(math.floor(tonumber(machine:GetAttribute(attr)) or 0), 0, maxLevel)
		end
		return out
	end

	local area = UILib.make("Frame", {
		Name = "MachineStats", BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, ROWS_Y + 3 * ROW_H + 2 * ROW_GAP), Parent = content,
	})
	local buttons = {}
	local drawn, shownLevels = nil, nil
	local function render(force: boolean?)
		if not p.alive then return end
		local state = UILib.state
		local MS = machineStats()
		local levels = levelsNow()
		local effects = type(state.effects) == "table" and state.effects or {}
		local attrs = MS and MS.attrsOf(machine) or {}
		attrs.Earnings = ownerEarnings(state)
		attrs.Clientele = tonumber(state.clientele)
		local costs = {}
		for _, kind in UPGRADE_KINDS do costs[kind] = upgradeCost(kind, levels[kind]) end

		-- redraw only when something on screen changes (BoostLeft ticks every few seconds)
		local sig = {}
		for _, v in { levels.speed, levels.bets, levels.lucky, costs.speed, costs.bets, costs.lucky,
			(tonumber(attrs.BoostLeft) or 0) > 0, attrs.VipFloor == true, attrs.Clientele } do
			table.insert(sig, tostring(v))
		end
		for _, name in { "IncomeMult", "PerkSpeed", "PerkTilt" } do table.insert(sig, tostring(attrs[name])) end
		for _, k in { "speedBonus", "tiltBonus", "cashMult", "xpMult", "walletMult", "betBonus", "vipChance", "vipWalletBonus" } do
			table.insert(sig, ("%.4f"):format(tonumber(effects[k]) or 0))
		end
		for _, part in attrs.Earnings do table.insert(sig, part.key .. tostring(part.mult)) end
		local key = table.concat(sig, "|")
		if key == drawn and not force then return end
		drawn = key

		for _, ch in area:GetChildren() do ch:Destroy() end
		table.clear(buttons)
		local now = MS and def and MS.compute(def, levels, effects, attrs) or nil
		local values = {}
		if now then
			values = statsBoard(area, {
				cells = {
					{ id = "bets", icon = "chips", label = "BETS", width = 170,
					  value = ("%s - %s"):format(MS.money(now.minBet), MS.money(now.maxBet)) },
					{ id = "time", icon = "stopwatch", label = "GAME TIME", width = 132, value = MS.seconds(now.gameSeconds) },
					{ id = "win", icon = "chance", label = "WIN CHANCE", width = 142, value = MS.percent(now.guestWinChance) },
					{ id = "edge", icon = "house", label = "HOUSE EDGE", width = 142, value = MS.percent(now.houseEdge) },
					{ id = "xp", icon = "xp", label = "XP / GAME", width = 114, value = MS.xp(now.xpPerGame) },
				},
				income = now.income,
				total = #now.income > 0 and ("= " .. MS.mult(now.incomeMult)) or "x1",
				hint = boost and "Boost it below for x3 income!" or "No income bonuses yet",
			})
		end

		local list = UILib.make("Frame", {
			Name = "Upgrades", BackgroundTransparency = 1, Position = UDim2.fromOffset(0, now and ROWS_Y or 0),
			Size = UDim2.new(1, 0, 0, 3 * ROW_H + 2 * ROW_GAP), Parent = area,
		})
		UILib.list(list, "y", ROW_GAP)
		local tiles = {}
		for i, kind in UPGRADE_KINDS do
			local spec = Config.MachineUpgrades and Config.MachineUpgrades[kind]
			if spec then
				local lvl = levels[kind]
				local look = UPGRADE_LOOK[kind]
				local row = UILib.row({
					parent = list, order = i, height = ROW_H, tone = look[2], icon = look[1],
					title = string.upper(spec.name or kind), rightWidth = 184, name = "Upgrade_" .. kind,
				})
				tiles[kind] = row.Instance:FindFirstChild("Tile")
				-- line 1: the title with its level pips beside it
				local head = UILib.make("Frame", {
					Name = "Head", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 26), LayoutOrder = 1, Parent = row.info,
				})
				UILib.list(head, "x", 12, nil, Enum.VerticalAlignment.Center)
				local title = row.info:FindFirstChild("Title")
				if title and title:IsA("TextLabel") then
					title.Parent = head
					title.TextSize = 22
					title.AutomaticSize = Enum.AutomaticSize.X
					title.Size = UDim2.fromOffset(0, 26)
				end
				local pips = UILib.pips(head, lvl, maxLevel, 2)
				pips.Size = UDim2.fromOffset(maxLevel * 36 + 64, 16)
				-- line 2: what the next level changes ("Game time 1.0 s -> 0.84 s")
				local nxt = now and MS.nextLevel(def, levels, effects, attrs, kind) or nil
				UILib.body(row.info, {
					name = "Delta", rich = true, size = 14, font = F.Heavy, color = C.Brown, order = 2,
					text = now and deltaText(MS, kind, now, nxt) or tostring(spec.desc or ""),
					frameSize = UDim2.new(1, 0, 0, 18),
				})
				if lvl >= maxLevel then
					UILib.button({ parent = row.right, tone = "Purple", text = "MAXED", textSize = 21, size = UDim2.fromOffset(168, 54) })
				else
					local cost = costs[kind]
					local b = UILib.button({
						parent = row.right, tone = cashValue.Value >= cost and "Green" or "Red", text = UILib.short(cost),
						icon = "coin", textSize = 23, size = UDim2.fromOffset(168, 54),
						onClick = function()
							local res = Remotes.UpgradeMachine():InvokeServer(machine, kind)
							report(res, "unlock")
							-- (the new *Level attribute redraws it; this is the fallback)
							if res and res.ok then task.delay(0.4, function() render() end) end
						end,
					})
					table.insert(buttons, { handle = b, cost = cost })
				end
			end
		end

		-- a level just landed: pop the stats it improved and its row's tile
		if shownLevels then
			for _, kind in UPGRADE_KINDS do
				if levels[kind] > (shownLevels[kind] or 0) then
					for _, id in UPGRADE_STATS[kind] do
						local holder = values[id]
						if holder then
							UILib.fx("pop", holder, 1.35)
							UILib.fx("sparkle", holder, 8, C.GoldTop)
						end
					end
					if tiles[kind] then UILib.fx("pop", tiles[kind], 1.2) end
				end
			end
		end
		shownLevels = levels
	end
	render(true)
	if boost then
		local ok, err = pcall(boost, content, machine, p, BOOST_Y)
		if not ok then warn("[ManageUI] boost section: " .. tostring(err)) end
	end

	-- redraw on what changes it: the machine's level / boost / VIP floor / perk attributes,
	-- every snapshot (effects, prices, passes) and a slow tick (a ticket boost running out)
	local conns = {}
	for _, name in { "SpeedLevel", "BetsLevel", "LuckyLevel", "BoostLeft", "VipFloor", "IncomeMult", "PerkSpeed", "PerkTilt" } do
		table.insert(conns, machine:GetAttributeChangedSignal(name):Connect(function() render() end))
	end
	table.insert(conns, cashValue.Changed:Connect(function()
		for _, b in buttons do b.handle.setTone(cashValue.Value >= b.cost and "Green" or "Red") end
	end))
	local unsub = UILib.subscribe(function() render() end)
	task.spawn(function()
		while p.alive do
			task.wait(2)
			render()
		end
	end)
	p.onClose(function()
		unsub()
		for _, c in conns do c:Disconnect() end
	end)
end

return ManageUI
