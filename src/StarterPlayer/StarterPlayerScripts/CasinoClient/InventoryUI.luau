--!nonstrict
-- InventoryUI.luau — ITEMS panel: owned-but-unplaced machines grouped per type
-- ("x2 owned"), filterable by tab. PLACE closes the panel and starts the ghost
-- placement controller for one copy.

local UILib = require(script.Parent:WaitForChild("UILib"))
local PlacementController = require(script.Parent:WaitForChild("PlacementController"))
local A = UILib.Assets

local InventoryUI = {}

function InventoryUI.open(openShop)
	local p = UILib.panel({ name = "InventoryPanel", title = "ITEMS", icon = "items", width = 1000, height = 500 })
	local content = p.content
	local body = UILib.make("Frame", {
		Name = "Body", BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 60),
		Size = UDim2.new(1, 0, 1, -60), Parent = content,
	})

	local filter = "all"
	local function render(state)
		if not p.alive then return end
		for _, ch in body:GetChildren() do ch:Destroy() end
		-- group copies by machineId, keep the first item to place
		local groups, order = {}, {}
		for _, item in (state.inventory or {}) do
			local isConc = item.kind == "concession"
			if filter == "all" or (filter == "machines" and not isConc) or (filter == "snacks" and isConc) then
				local g = groups[item.machineId]
				if not g then
					g = { item = item, count = 0 }
					groups[item.machineId] = g
					table.insert(order, item.machineId)
				end
				g.count += 1
			end
		end

		if #order == 0 then
			local empty = UILib.make("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = body })
			UILib.image(empty, "items", {
				size = UDim2.fromOffset(150, 150), anchor = Vector2.new(0.5, 0), position = UDim2.new(0.5, 0, 0, 6),
			})
			UILib.text(empty, {
				text = "NOTHING HERE YET!", size = 32, frameSize = UDim2.new(1, 0, 0, 40), position = UDim2.fromOffset(0, 160),
				color = UILib.Colors.Crimson,
			})
			UILib.button({
				parent = empty, tone = "Gold", text = "GO SHOPPING", icon = "shop", textSize = 24,
				size = UDim2.fromOffset(260, 60), anchor = Vector2.new(0.5, 0), position = UDim2.new(0.5, 0, 0, 214),
				onClick = function() p.close(); if openShop then openShop() end end,
			})
			return
		end

		local grid = UILib.scroller(body, { grid = true })
		for i, machineId in order do
			local g = groups[machineId]
			local item = g.item
			UILib.card({
				parent = grid, order = i, tone = A.TypeTone[item.type] or "Blue", icon = A.TypeIcon[item.type] or "star",
				title = string.upper(item.name), titleSize = #item.name > 13 and 18 or 22,
				stat = ("x%d owned"):format(g.count),
				badge = g.count > 1 and { text = "x" .. g.count, tone = "Gold" } or nil,
				button = { tone = "Blue", text = "PLACE", onClick = function()
					p.close()
					PlacementController.begin(item)
				end },
			})
		end
	end

	local tabs = UILib.tabs(content, {
		{ id = "all", label = "ALL" },
		{ id = "machines", label = "MACHINES" },
		{ id = "snacks", label = "SNACKS & BAR" },
	}, function(id)
		filter = id
		render(UILib.state)
	end, "all")

	local unsub = UILib.subscribe(render)
	p.onClose(unsub)
	return tabs
end

return InventoryUI
