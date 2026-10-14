--!nonstrict
-- WelcomeUI.luau — WELCOME BACK popup with the offline income your machines
-- earned (big cash render on a spinning sunburst) and a CLAIM button.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Remotes = require(Common:WaitForChild("Remotes"))
local UILib = require(script.Parent:WaitForChild("UILib"))
local C = UILib.Colors

local WelcomeUI = {}

function WelcomeUI.show(info)
	local p = UILib.panel({ name = "WelcomePanel", title = "WELCOME BACK!", icon = "star", width = 640, height = 470 })
	local content = p.content
	UILib.body(content, {
		text = ("Your %d machine(s) kept earning while you were away (%.1f h):"):format(info.machines or 0, info.hours or 0),
		size = 16, xAlign = Enum.TextXAlignment.Center, frameSize = UDim2.new(1, 0, 0, 24), wrap = true,
	})
	local stage = UILib.make("Frame", {
		Name = "Stage", BackgroundTransparency = 1, ClipsDescendants = true,
		Position = UDim2.fromOffset(0, 30), Size = UDim2.new(1, 0, 0, 170), Parent = content,
	})
	local burst = UILib.image(stage, UILib.Tex.sunburst, {
		size = UDim2.fromOffset(420, 420), anchor = Vector2.new(0.5, 0.5), position = UDim2.fromScale(0.5, 0.5),
		color = C.GoldTop, transparency = 0.6,
	})
	UILib.spin(burst, 12)
	UILib.image(stage, UILib.Tex.glow, {
		size = UDim2.fromOffset(260, 200), anchor = Vector2.new(0.5, 0.5), position = UDim2.fromScale(0.5, 0.5),
		transparency = 0.2,
	})
	UILib.image(stage, "cash", {
		size = UDim2.fromOffset(170, 170), anchor = Vector2.new(0.5, 0.5), position = UDim2.fromScale(0.5, 0.5),
	})
	local amount = UILib.text(content, {
		text = "$0", font = UILib.Fonts.Number, size = 52, color = C.Green,
		frameSize = UDim2.new(1, 0, 0, 60), position = UDim2.fromOffset(0, 200), stroke = 4, shadow = 4,
	})
	UILib.countTo(amount, 0, function(n) return "$" .. UILib.commas(n) end)
	task.delay(0.25, function()
		UILib.countTo(amount, info.amount or 0, function(n) return "$" .. UILib.commas(n) end)
	end)
	local claimed = false
	local function claim()
		if claimed then return end
		claimed = true
		local res = Remotes.ClaimOffline():InvokeServer()
		if res and res.ok then
			UILib.toast("CLAIMED " .. UILib.money(res.amount) .. "!", "income", "Your casino never sleeps.")
		end
	end
	UILib.button({
		parent = content, tone = "Gold", text = "CLAIM!", textSize = 36,
		size = UDim2.fromOffset(300, 72), anchor = Vector2.new(0.5, 1), position = UDim2.new(0.5, 0, 1, -2),
		onClick = function() claim(); p.close() end,
	})
	-- closing with X / Esc / backdrop still pays out — never lose offline income
	p.onClose(claim)
end

function WelcomeUI.start()
	local ev = Remotes.WelcomeBack()
	if not ev then
		warn("[WelcomeUI] WelcomeBack remote missing; skipping offline popup.")
		return
	end
	ev.OnClientEvent:Connect(function(info)
		if info and (info.amount or 0) > 0 then WelcomeUI.show(info) end
	end)
end

return WelcomeUI
