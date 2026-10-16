--!nonstrict
-- InventoryUI.luau — ITEMS panel: owned-but-unplaced machines grouped per type
-- ("x2 owned") and decor pieces (the snapshot's decor.inventory counts),
-- filterable by tab (ALL / MACHINES / SNACKS & BAR / DECOR). PLACE closes the
-- panel and starts BUILD MODE with that item (PlacementController: the build
-- bar lists everything else, and you keep building after each place). MOVE
-- starts build mode in "pick something to move" (what the old BUILD tile did).

local UILib = require(script.Parent:WaitForChild("UILib"))
local PlacementController = require(script.Parent:WaitForChild("PlacementController"))
local A = UILib.Assets

local InventoryUI = {}

-- openShop(tab?): opens the SHOP (on the decor tab from DECOR when it can)
function InventoryUI.open(openShop)
	local p = UILib.panel({ name = "InventoryPanel", title = "ITEMS", icon = "items", width = 1000, height = 500 })
	local content = p.content
	local body = UILib.make("Frame", {
		Name = "Body", BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 60),
		Size = UDim2.new(1, 0, 1, -60), Parent = content,
	})
	-- rearrange what's already placed (machines and decor)
	UILib.button({
		parent = content, name = "MoveButton", tone = "Pink", text = "MOVE", icon = "build", textSize = 20, iconSize = 26,
		size = UDim2.fromOffset(150, 46), anchor = Vector2.new(1, 0), position = UDim2.new(1, -4, 0, 2),
		onClick = function()
			p.close()
			PlacementController.enterSelectMode()
		end,
	})

	local filter = "all"
	local function render(state)
		if not p.alive then return end
		for _, ch in body:GetChildren() do ch:Destroy() end
		local cards = {}
		-- machines / stands: copies grouped by machineId, the first one is placed
		local groups = {}
		for _, item in (state.inventory or {}) do
			local isConc = item.kind == "concession"
			if filter == "all" or (filter == "machines" and not isConc) or (filter == "snacks" and isConc) then
				local g = groups[item.machineId]
				if not g then
					g = { item = item, count = 0 }
					groups[item.machineId] = g
					table.insert(cards, g)
				end
				g.count += 1
			end
		end
		-- decor: decorId -> count
		local decor = type(state.decor) == "table" and state.decor.inventory
		if type(decor) == "table" and (filter == "all" or filter == "decor") then
			local list = {}
			for id, n in decor do
				local count = tonumber(n) or 0
				if type(id) == "string" and count > 0 then
					table.insert(list, { decorId = id, count = count, info = PlacementController.decorInfo(id) })
				end
			end
			table.sort(list, function(a, b) return a.info.name < b.info.name end)
			for _, c in list do table.insert(cards, c) end
		end

		if #cards == 0 then
			local empty = UILib.make("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = body })
			UILib.image(empty, filter == "decor" and "plant" or "items", {
				size = UDim2.fromOffset(150, 150), anchor = Vector2.new(0.5, 0), position = UDim2.new(0.5, 0, 0, 6),
			})
			UILib.text(empty, {
				text = "NOTHING HERE YET!", size = 32, frameSize = UDim2.new(1, 0, 0, 40), position = UDim2.fromOffset(0, 160),
				color = UILib.Colors.Crimson,
			})
			UILib.button({
				parent = empty, tone = "Gold", text = "GO SHOPPING", icon = "shop", textSize = 24,
				size = UDim2.fromOffset(260, 60), anchor = Vector2.new(0.5, 0), position = UDim2.new(0.5, 0, 0, 214),
				onClick = function()
					p.close()
					if openShop then openShop(filter == "decor" and "decor" or nil) end
				end,
			})
			return
		end

		local grid = UILib.scroller(body, { grid = true, memory = filter }) -- (keeps its scroll on re-render)
		for i, c in cards do
			if c.decorId then
				local info = c.info
				UILib.card({
					parent = grid, order = i, tone = info.tone, icon = info.icon,
					model = { kind = "decor", id = c.decorId }, -- the real piece (ModelIcons)
					title = string.upper(info.name), titleSize = #info.name > 13 and 18 or 22,
					stat = ("x%d owned%s"):format(c.count, info.flat and "  •  WALKABLE" or ""),
					badge = c.count > 1 and { text = "x" .. c.count, tone = "Gold" } or nil,
					button = { tone = "Green", text = "PLACE", onClick = function()
						p.close()
						PlacementController.beginDecor(c.decorId)
					end },
				})
			else
				local item = c.item
				UILib.card({
					parent = grid, order = i, tone = A.TypeTone[item.type] or "Blue", icon = A.TypeIcon[item.type] or "star",
					model = { kind = "machine", id = item.machineId }, -- the real machine / stand (ModelIcons)
					title = string.upper(item.name), titleSize = #item.name > 13 and 18 or 22,
					stat = ("x%d owned"):format(c.count),
					badge = c.count > 1 and { text = "x" .. c.count, tone = "Gold" } or nil,
					button = { tone = "Blue", text = "PLACE", onClick = function()
						p.close()
						PlacementController.begin(item)
					end },
				})
			end
		end
	end

	local tabs = UILib.tabs(content, {
		{ id = "all", label = "ALL" },
		{ id = "machines", label = "MACHINES" },
		{ id = "snacks", label = "SNACKS & BAR" },
		{ id = "decor", label = "DECOR" },
	}, function(id)
		filter = id
		render(UILib.state)
	end, "all")

	local unsub = UILib.subscribe(render)
	p.onClose(unsub)
	return tabs
end

return InventoryUI
