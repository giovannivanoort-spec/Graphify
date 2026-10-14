--!nonstrict
-- ManageUI.luau — MY CASINO overview (every placed machine with MOVE / STORE /
-- SELL) and the per-machine popup you get when interacting with your own machine
-- (three upgrade tracks with level pips + move / store / sell).

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Remotes = require(Common:WaitForChild("Remotes"))
local UILib = require(script.Parent:WaitForChild("UILib"))
local PlacementController = require(script.Parent:WaitForChild("PlacementController"))
local A = UILib.Assets

local ManageUI = {}

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

function ManageUI.openOverview()
	local p = UILib.panel({ name = "ManagePanel", title = "MY CASINO", icon = "slot", width = 900, height = 560 })
	local content = p.content
	local header = UILib.body(content, {
		text = "", font = UILib.Fonts.Display, size = 20, frameSize = UDim2.new(1, 0, 0, 28),
	})
	local list = UILib.scroller(content, {
		padding = 12, position = UDim2.fromOffset(0, 34), size = UDim2.new(1, 0, 1, -34),
	})

	local function render(state)
		if not p.alive then return end
		for _, ch in list:GetChildren() do
			if ch:IsA("GuiObject") then ch:Destroy() end
		end
		local placed = state.placed or {}
		header.Text = ("MACHINES ON YOUR FLOOR: %d / %d"):format(#placed, state.maxMachines or 14)
		if #placed == 0 then
			UILib.body(list, {
				text = "Nothing placed yet - open ITEMS and place your first machine!", size = 16,
				xAlign = Enum.TextXAlignment.Center, frameSize = UDim2.new(1, 0, 0, 60),
			})
			return
		end
		for i, m in placed do
			local isConc = m.kind == "concession"
			local up = m.upgrades or {}
			local lvl = (up.speed or 0) + (up.bets or 0) + (up.lucky or 0)
			local row = UILib.row({
				parent = list, order = i, height = 88, tone = A.TypeTone[m.type] or "Blue", icon = A.TypeIcon[m.type] or "star",
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
	local unsub = UILib.subscribe(render)
	p.onClose(unsub)
end

-- popup when the owner interacts with their own machine
local UPGRADE_LOOK = { speed = { "star", "Blue" }, bets = { "cash", "Green" }, lucky = { "gem", "Purple" } }

function ManageUI.openForMachine(machine: Instance)
	local isConc = machine:GetAttribute("Kind") == "concession"
	local gameType = machine:GetAttribute("GameType") or "Slots"
	local p = UILib.panel({
		name = "MachinePanel", title = string.upper(machine.Name or "Machine"), icon = A.TypeIcon[gameType] or "slot",
		width = 820, height = isConc and 300 or 560,
	})
	local content = p.content
	local cashValue = UILib.getCashValue()

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
	UILib.button({ parent = actions, tone = "Red", text = "SELL", icon = "cash", textSize = 22, size = UDim2.fromOffset(190, 60), order = 3,
		onClick = function()
			local res = Remotes.SellMachine():InvokeServer(machine)
			report(res, "income")
			if res and res.ok then p.close() end
		end })

	if isConc then
		UILib.body(content, {
			text = ("Patrons spend $%d here every visit."):format(machine:GetAttribute("RevenuePerVisit") or 0),
			size = 18, xAlign = Enum.TextXAlignment.Center, frameSize = UDim2.new(1, 0, 0, 40), position = UDim2.fromOffset(0, 10),
		})
		return
	end

	local cat = UILib.getCatalog()
	local list = UILib.make("Frame", {
		Name = "Upgrades", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 1, -80), Parent = content,
	})
	UILib.list(list, "y", 12)
	local buttons = {}
	local function render()
		for _, ch in list:GetChildren() do
			if ch:IsA("GuiObject") then ch:Destroy() end
		end
		table.clear(buttons)
		for i, spec in (cat and cat.machineUpgrades or {}) do
			local attr = spec.key:sub(1, 1):upper() .. spec.key:sub(2) .. "Level"
			local lvl = machine:GetAttribute(attr) or 0
			local look = UPGRADE_LOOK[spec.key] or { "star", "Gold" }
			local row = UILib.row({
				parent = list, order = i, height = 96, tone = look[2], icon = look[1],
				title = string.upper(spec.name), rightWidth = 200,
			})
			UILib.pips(row.info, lvl, spec.maxLevel, 3)
			if lvl >= spec.maxLevel then
				UILib.button({ parent = row.right, tone = "Purple", text = "MAXED", textSize = 22, size = UDim2.fromOffset(170, 56) })
			else
				local cost = spec.costs[lvl + 1] or 0
				local b = UILib.button({
					parent = row.right, tone = "Green", text = UILib.abbreviate(cost), icon = "coin", textSize = 24,
					size = UDim2.fromOffset(176, 58),
					onClick = function()
						local res = Remotes.UpgradeMachine():InvokeServer(machine, spec.key)
						report(res, "unlock")
						-- give the new *Level attribute a moment to replicate
						if res and res.ok then task.delay(0.25, function() if p.alive then render() end end) end
					end,
				})
				table.insert(buttons, { handle = b, cost = cost })
			end
		end
		for _, b in buttons do b.handle.setTone(cashValue.Value >= b.cost and "Green" or "Red") end
	end
	render()
	local conn = cashValue.Changed:Connect(function()
		for _, b in buttons do b.handle.setTone(cashValue.Value >= b.cost and "Green" or "Red") end
	end)
	p.onClose(function() conn:Disconnect() end)
end

return ManageUI
