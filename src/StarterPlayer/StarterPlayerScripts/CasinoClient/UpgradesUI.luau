--!nonstrict
-- UpgradesUI.luau — one-time owner upgrades as cream rows: tone tile + 3D icon,
-- crimson title, description, and a price button (green if affordable, red if
-- not, purple OWNED once bought).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Remotes = require(Common:WaitForChild("Remotes"))
local UILib = require(script.Parent:WaitForChild("UILib"))

local UpgradesUI = {}

local LOOK = {
	marketing_1 = { "cash", "Green" },
	marketing_2 = { "cash", "Blue" },
	rigged      = { "star", "Purple" },
	comp_drinks = { "popcorn", "Orange" },
	neon_sign   = { "gem", "Pink" },
	high_roller = { "crown", "Gold" },
}

function UpgradesUI.open()
	local cat = UILib.getCatalog()
	if not cat then UILib.toast("Upgrades unavailable", "error"); return end
	local cashValue = UILib.getCashValue()

	local p = UILib.panel({ name = "UpgradesPanel", title = "UPGRADES", icon = "upgrade", width = 860, height = 560 })
	local list = UILib.scroller(p.content, { padding = 12 })

	local buttons = {}
	local function refreshTones()
		for _, b in buttons do
			b.handle.setTone(cashValue.Value >= b.cost and "Green" or "Red")
		end
	end

	local function render(state)
		if not p.alive then return end
		for _, ch in list:GetChildren() do
			if ch:IsA("GuiObject") then ch:Destroy() end
		end
		table.clear(buttons)
		local owned = {}
		for _, id in (state.upgrades or {}) do owned[id] = true end
		for i, u in (cat.upgrades or {}) do
			local look = LOOK[u.id] or { "star", "Gold" }
			local row = UILib.row({
				parent = list, order = i, tone = look[2], icon = look[1],
				title = string.upper(u.name), desc = u.desc, rightWidth = 200,
			})
			if owned[u.id] then
				UILib.button({ parent = row.right, tone = "Purple", text = "OWNED", textSize = 22,
					size = UDim2.fromOffset(170, 56) })
			else
				local b = UILib.button({
					parent = row.right, tone = "Green", text = UILib.abbreviate(u.cost), icon = "coin", textSize = 24,
					size = UDim2.fromOffset(176, 58),
					onClick = function()
						local res = Remotes.BuyUpgrade():InvokeServer(u.id)
						if res and res.ok then
							UILib.toast(string.upper(u.name) .. " UNLOCKED!", "unlock", u.desc)
						else
							UILib.toast(res and res.message or "Purchase failed", "error")
						end
					end,
				})
				table.insert(buttons, { handle = b, cost = u.cost })
			end
		end
		refreshTones()
	end

	local conn = cashValue.Changed:Connect(refreshTones)
	local unsub = UILib.subscribe(render)
	p.onClose(function() conn:Disconnect(); unsub() end)
end

return UpgradesUI
