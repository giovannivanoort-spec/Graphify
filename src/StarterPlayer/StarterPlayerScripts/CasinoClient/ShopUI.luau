--!nonstrict
-- ShopUI.luau — the SHOP panel: MACHINES / SNACKS & BAR / STAFF tabs of item
-- cards. Machines & concessions buy into your Inventory (BuyToInventory, same
-- remote the physical Showroom uses); staff hire permanently. The Showroom
-- button still teleports you to the physical displays.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Remotes = require(Common:WaitForChild("Remotes"))
local Config = require(Common:WaitForChild("Config"))
local UILib = require(script.Parent:WaitForChild("UILib"))
local C = UILib.Colors
local A = UILib.Assets

local player = Players.LocalPlayer
local ShopUI = {}

local STAFF_TONES = { pit_boss = "Blue", security = "Green", host = "Purple" }

function ShopUI.open(tab: string?)
	local cat = UILib.getCatalog()
	if not cat then UILib.toast("Shop unavailable", "error"); return end
	local cashValue = UILib.getCashValue()

	local p = UILib.panel({ name = "ShopPanel", title = "SHOP", icon = "shop", width = 1000, height = 548 })
	local content = p.content

	local body = UILib.make("Frame", {
		Name = "Body", BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 60),
		Size = UDim2.new(1, 0, 1, -104), Parent = content,
	})
	local footer = UILib.make("Frame", {
		Name = "Footer", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, 40), Parent = content,
	})
	UILib.body(footer, {
		text = "Tip: walk through the Showroom to see every machine up close!", size = 14,
		frameSize = UDim2.new(1, -230, 1, 0), transparency = 0.25,
	})
	UILib.button({
		parent = footer, tone = "Blue", text = "SHOWROOM", textSize = 20, icon = "slot", iconSize = 30,
		size = UDim2.fromOffset(210, 46), anchor = Vector2.new(1, 0.5), position = UDim2.new(1, 0, 0.5, -2),
		onClick = function()
			local char = player.Character
			local hrp = char and char:FindFirstChild("HumanoidRootPart")
			if hrp then
				local ctr = Config.Showroom.Center
				hrp.CFrame = CFrame.new(ctr.X, ctr.Y + 4, ctr.Z + 12) * CFrame.Angles(0, math.rad(180), 0)
				p.close()
			end
		end,
	})

	local buttons = {} -- { handle, cost } so affordability can recolour live
	local function refreshAffordability()
		local cash = cashValue.Value
		for _, b in buttons do
			if b.cost then b.handle.setTone(cash >= b.cost and "Green" or "Red") end
		end
	end
	local conn = cashValue.Changed:Connect(refreshAffordability)
	p.onClose(function() conn:Disconnect() end)

	local function buy(def)
		local res = Remotes.BuyToInventory():InvokeServer(def.id)
		if res and res.ok then
			UILib.toast("BOUGHT " .. string.upper(def.name) .. "!", "unlock", "It's in your Items — place it on your plot.")
		else
			UILib.toast(res and res.message or "Purchase failed", "error")
		end
	end

	local current
	local function render(which)
		current = which
		for _, ch in body:GetChildren() do ch:Destroy() end
		table.clear(buttons)
		local grid = UILib.scroller(body, { grid = true })

		if which == "machines" or which == "concessions" then
			local list = which == "machines" and cat.machines or cat.concessions
			-- how many of each you already own (inventory + placed) -> "x2" badge
			local ownedCount = {}
			for _, it in (UILib.state.inventory or {}) do ownedCount[it.machineId] = (ownedCount[it.machineId] or 0) + 1 end
			for _, m in (UILib.state.placed or {}) do ownedCount[m.machineId] = (ownedCount[m.machineId] or 0) + 1 end
			for i, def in (list or {}) do
				local isConc = which == "concessions"
				local stat = isConc and ("+$%d per visit"):format(def.revenuePerVisit or 0)
					or ("Bets $%d-$%d"):format(def.minBet or 0, def.maxBet or 0)
				local n = ownedCount[def.id] or 0
				local card = UILib.card({
					parent = grid, order = i, tone = A.TypeTone[def.type] or "Blue",
					icon = A.TypeIcon[def.type] or "star", title = string.upper(def.name), stat = stat,
					titleSize = #def.name > 13 and 18 or 22,
					badge = n > 0 and { text = "OWNED x" .. n, tone = "Gold" } or nil,
					button = { tone = "Green", text = UILib.abbreviate(def.cost), icon = "coin",
						onClick = function() buy(def) end },
				})
				table.insert(buttons, { handle = card.button, cost = def.cost })
			end
		else -- staff
			local hired = {}
			for _, id in (UILib.state.staff or {}) do hired[id] = true end
			for i, s in (cat.staff or {}) do
				local owned = hired[s.id] == true
				local card = UILib.card({
					parent = grid, order = i, tone = STAFF_TONES[s.id] or "Purple", icon = "staff",
					title = string.upper(s.name), stat = ("+%d%% house edge"):format(math.floor((s.bonus or 0) * 100 + 0.5)),
					badge = owned and { text = "HIRED", tone = "Green" } or nil,
					button = owned and { tone = "Purple", text = "HIRED" } or {
						tone = "Green", text = UILib.abbreviate(s.cost), icon = "coin",
						onClick = function()
							local res = Remotes.HireStaff():InvokeServer(s.id)
							if res and res.ok then
								UILib.toast(string.upper(res.message or "Hired!"), "unlock")
							else
								UILib.toast(res and res.message or "Hire failed", "error")
							end
						end,
					},
				})
				if not owned then table.insert(buttons, { handle = card.button, cost = s.cost }) end
			end
		end
		refreshAffordability()
	end

	local tabs = UILib.tabs(content, {
		{ id = "machines", label = "MACHINES" },
		{ id = "concessions", label = "SNACKS & BAR" },
		{ id = "staff", label = "STAFF" },
	}, render)
	tabs.select(tab or "machines")

	-- re-render when a purchase/hire lands (owned badges, HIRED state)
	local first = true
	local unsub = UILib.subscribe(function()
		if first then first = false; return end
		if current and p.alive then render(current) end
	end)
	p.onClose(unsub)
end

return ShopUI
