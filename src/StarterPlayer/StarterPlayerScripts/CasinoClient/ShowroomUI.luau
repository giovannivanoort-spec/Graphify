--!nonstrict
-- ShowroomUI.luau — keeps each showroom display's price label honest: green when
-- you can afford it, red (with the shortfall) when you can't. Updates live as
-- your cash changes.
--
-- The card itself reveals on approach natively (BillboardGui.MaxDistance) and the
-- actual purchase is handled in init.client (E -> BuyToInventory), so this module
-- is purely the affordability polish.

local CollectionService = game:GetService("CollectionService")

local UILib = require(script.Parent:WaitForChild("UILib"))
local C = UILib.Colors

local ShowroomUI = {}
local TAG = "CasinoShopDisplay"

local function commas(n: number): string
	local s = tostring(math.floor(n))
	local k
	repeat s, k = s:gsub("^(-?%d+)(%d%d%d)", "%1,%2") until k == 0
	return s
end

local function refreshOne(display: Instance, cash: number)
	local cost = display:GetAttribute("ShopCost")
	if not cost then return end
	local card = display:FindFirstChild("InfoCard", true)
	local price = card and card:FindFirstChild("Price", true)
	if not (price and price:IsA("TextLabel")) then return end
	if cash >= cost then
		price.TextColor3 = C.Accent
		price.Text = ("$%s   [E] Buy"):format(commas(cost))
	else
		price.TextColor3 = C.Red
		price.Text = ("$%s   need $%s more"):format(commas(cost), commas(cost - cash))
	end
end

function ShowroomUI.start()
	local cashValue = UILib.getCashValue()

	local function refreshAll()
		local cash = cashValue.Value
		for _, d in CollectionService:GetTagged(TAG) do
			refreshOne(d, cash)
		end
	end

	-- coalesce bursts of cash changes (an owner's cash ticks on every NPC spin)
	local pending = false
	local function schedule()
		if pending then return end
		pending = true
		task.delay(0.15, function()
			pending = false
			refreshAll()
		end)
	end

	cashValue.Changed:Connect(schedule)
	-- color a freshly-spawned display immediately (no affordability flash),
	-- with schedule() as a backup in case its card hasn't replicated yet
	CollectionService:GetInstanceAddedSignal(TAG):Connect(function(display)
		refreshOne(display, cashValue.Value)
		schedule()
	end)
	task.defer(refreshAll)
end

return ShowroomUI
