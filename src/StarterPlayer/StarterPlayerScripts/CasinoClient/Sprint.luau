--!nonstrict
-- Sprint.luau — hold Shift (PC) / L3 (gamepad) / the auto-created touch button
-- (mobile) to sprint. Stamina drains while you're actually moving and regenerates
-- after a short delay. Fully client-side (WalkSpeed replicates from the owner).
-- Builds + drives its own stamina bar above the action dock.

local ContextActionService = game:GetService("ContextActionService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Config = require(Common:WaitForChild("Config"))
local UILib = require(script.Parent:WaitForChild("UILib"))
local C = UILib.Colors

local Sprint = {}
local player = Players.LocalPlayer

function Sprint.start()
	local cfg = Config.Sprint
	if not cfg or not cfg.Enabled then return end

	-- stamina bar: bottom-centre, sitting just above the HUD income ticker (same
	-- anchor + viewport scale as the ticker so the two never overlap)
	local screen = UILib.getScreen()
	local holder = UILib.make("Frame", {
		Name = "StaminaHolder", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -12), Size = UDim2.fromOffset(300, 92), Parent = screen })
	UILib.autoScale(holder, { mult = UILib.IsTouch and 1.12 or 1 })
	local bar = UILib.make("Frame", {
		Name = "StaminaBar", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromScale(0.5, 0),
		Size = UDim2.fromOffset(240, 22), BackgroundColor3 = C.Ink, BackgroundTransparency = 0.25, Parent = holder })
	UILib.corner(bar, 999)
	local barStroke = UILib.stroke(bar, C.Ink, 3, true)
	local fill = UILib.make("Frame", { Name = "Fill", Size = UDim2.fromScale(1, 1), BackgroundColor3 = C.White, Parent = bar })
	UILib.corner(fill, 999)
	UILib.gradient(fill, C.GoldTop, C.Gold)
	local _, lbl = UILib.text(bar, { text = "SPRINT", size = 15, stroke = 2, shadow = 1 })

	local stamina = cfg.MaxStamina
	local sprinting = false
	local lockedOut = false
	local lastSprint = 0
	local baseSpeed = cfg.BaseSpeed

	local function humanoid()
		local char = player.Character
		return char and char:FindFirstChildOfClass("Humanoid")
	end

	-- input (the `true` makes ContextActionService auto-create a mobile button)
	local function onSprint(_, state)
		if state == Enum.UserInputState.Begin then
			sprinting = true
		elseif state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
			sprinting = false
		end
		return Enum.ContextActionResult.Pass
	end
	ContextActionService:BindAction("CasinoSprint", onSprint, true, Enum.KeyCode.LeftShift, Enum.KeyCode.ButtonL3)
	ContextActionService:SetTitle("CasinoSprint", "Run")

	local function onChar(char)
		local h = char:WaitForChild("Humanoid", 5)
		if h then baseSpeed = (h.WalkSpeed > 0 and h.WalkSpeed) or cfg.BaseSpeed end
	end
	player.CharacterAdded:Connect(onChar)
	if player.Character then task.spawn(onChar, player.Character) end

	RunService.Heartbeat:Connect(function(dt)
		local h = humanoid()
		local moving = h and h.MoveDirection.Magnitude > 0.1
		local canSprint = sprinting and not lockedOut and (not cfg.UseStamina or stamina > 0)
		local running = canSprint and moving and h ~= nil

		if cfg.UseStamina then
			if running then
				stamina = math.max(0, stamina - cfg.DrainPerSecond * dt)
				lastSprint = os.clock()
				if stamina <= 0 then lockedOut = true end
			elseif os.clock() - lastSprint >= cfg.RegenDelay then
				stamina = math.min(cfg.MaxStamina, stamina + cfg.RegenPerSecond * dt)
				if lockedOut and stamina >= cfg.MinToStart then lockedOut = false end
			end
		end

		if h then
			local want = running and cfg.SprintSpeed or baseSpeed
			if math.abs(h.WalkSpeed - want) > 0.01 then h.WalkSpeed = want end
		end

		local cam = Workspace.CurrentCamera
		if cam then
			local wantFOV = running and 78 or 70
			cam.FieldOfView = cam.FieldOfView + (wantFOV - cam.FieldOfView) * math.min(1, dt * 8)
		end

		-- bar
		local pct = cfg.UseStamina and (stamina / cfg.MaxStamina) or 1
		fill.Size = UDim2.fromScale(math.clamp(pct, 0, 1), 1)
		-- tint multiplies the gold gradient: white = gold, warm red when nearly empty
		fill.BackgroundColor3 = (pct < 0.2 and C.CrimsonTop) or (pct < 0.4 and C.OrangeTop) or C.White
		local show = cfg.UseStamina and (running or pct < 0.999)
		local targetT = show and 0.25 or 1
		bar.BackgroundTransparency = bar.BackgroundTransparency + (targetT - bar.BackgroundTransparency) * math.min(1, dt * 6)
		barStroke.Transparency = show and 0 or 1
		fill.Visible = show
		lbl.Visible = show
	end)
end

return Sprint
