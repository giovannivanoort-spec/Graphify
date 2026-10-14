--!nonstrict
-- PlacementController.luau — ghost-preview placement for either a NEW machine
-- (from inventory) or MOVING an already-placed machine. The ghost is a model
-- with a body + a forward-pointing arrow so you can see which way it faces.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Remotes = require(Common:WaitForChild("Remotes"))
local UILib = require(script.Parent:WaitForChild("UILib"))
local C = UILib.Colors

local player = Players.LocalPlayer
local mouse = player:GetMouse()

local PlacementController = {}

local active = nil  -- { mode, item|machine, ghost, body, arrow, rotationY, ... }

local function findOwnPlot(): BasePart?
	-- Plots can be: a Model with a "Base" / PrimaryPart whose model has OwnerId,
	-- OR a BasePart directly tagged with OwnerId attribute.
	for _, m in Workspace:GetChildren() do
		if m:GetAttribute("OwnerId") == player.UserId then
			if m:IsA("BasePart") then return m end
			if m:IsA("Model") then
				return (m:FindFirstChild("Base") :: BasePart?) or m.PrimaryPart
			end
		end
	end
	local plotsFolder = Workspace:FindFirstChild("Plots")
	if plotsFolder then
		for _, m in plotsFolder:GetChildren() do
			if m:GetAttribute("OwnerId") == player.UserId then
				if m:IsA("BasePart") then return m end
				if m:IsA("Model") then
					return (m:FindFirstChild("Base") :: BasePart?) or m.PrimaryPart
				end
			end
		end
	end
	return nil
end

local function isInside(base: BasePart, pos: Vector3): boolean
	if not base then return false end
	local half = base.Size / 2 - Vector3.new(4, 0, 4)
	local rel = base.CFrame:PointToObjectSpace(pos)
	return math.abs(rel.X) <= half.X and math.abs(rel.Z) <= half.Z
end

local function buildGhost(size: Vector3, color: Color3): (Model, BasePart, BasePart)
	local model = Instance.new("Model")
	model.Name = "PlacementGhost"

	local body = Instance.new("Part")
	body.Anchored = true; body.CanCollide = false; body.CanQuery = false
	body.Size = size; body.Transparency = 0.45
	body.Color = color; body.Material = Enum.Material.ForceField
	body.Parent = model
	model.PrimaryPart = body

	-- Arrow: a wedge sitting on top, pointing along the body's LookVector (-Z).
	local arrow = Instance.new("WedgePart")
	arrow.Anchored = true; arrow.CanCollide = false; arrow.CanQuery = false
	arrow.Size = Vector3.new(math.max(size.X * 0.4, 1), 0.25, math.max(size.Z * 0.9, 2))
	arrow.Transparency = 0.1
	arrow.Color = Color3.fromRGB(255, 230, 60)
	arrow.Material = Enum.Material.Neon
	arrow.Parent = model
	return model, body, arrow
end

local function updateGhost()
	if not active then return end
	local body, arrow = active.body, active.arrow
	local hit = mouse.Hit and mouse.Hit.Position or Vector3.new()
	local size = body.Size
	local pos = Vector3.new(hit.X, active.surfaceY + size.Y / 2, hit.Z)
	local cf = CFrame.new(pos) * CFrame.Angles(0, math.rad(active.rotationY), 0)
	body.CFrame = cf
	-- arrow sits on top of body, pointing along body's LookVector (-Z local)
	arrow.CFrame = cf * CFrame.new(0, size.Y / 2 + 0.15, -size.Z * 0.05)
	local ok = active.base and isInside(active.base, Vector3.new(hit.X, active.surfaceY, hit.Z))
	body.Color = ok and C.Green or C.Red
end

local function cleanup()
	if not active then return end
	if active.conn then active.conn:Disconnect() end
	if active.inputConn then active.inputConn:Disconnect() end
	if active.ghost then active.ghost:Destroy() end
	if active.bar then active.bar:Destroy() end
	-- restore the moved machine if cancelled mid-move
	if active.mode == "move" and active.machine and active.machine.Parent then
		for _, d in active.machine:GetDescendants() do
			if d:IsA("BasePart") then d.Transparency = active.savedTrans[d] or d.Transparency end
		end
	end
	active = nil
end

local function confirm()
	if not active then return end
	local pos = active.body.Position
	local res
	if active.mode == "place" then
		res = Remotes.PlaceFromInventory():InvokeServer(active.item.id, pos.X, pos.Z, active.rotationY)
	else
		res = Remotes.MoveMachine():InvokeServer(active.machine, pos.X, pos.Z, active.rotationY)
	end
	if res and res.ok then
		UILib.toast(res.message, C.Green)
		if active.mode == "move" and active.machine and active.machine.Parent then
			-- restore visibility (server already moved it)
			for _, d in active.machine:GetDescendants() do
				if d:IsA("BasePart") then d.Transparency = active.savedTrans[d] or 0 end
			end
			active.machine = nil  -- prevent double-restore in cleanup
		end
		cleanup()
	else
		UILib.toast(res and res.message or "Can't place there.", C.Red)
	end
end

function PlacementController.cancel()
	cleanup()
end

local function buildBar(label: string)
	local bar = UILib.make("Frame", {
		Name = "PlaceBar", AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -18), Size = UDim2.fromOffset(360, 56),
		BackgroundColor3 = C.Panel, Parent = UILib.getScreen() })
	UILib.corner(bar, 12); UILib.stroke(bar, C.Accent, 2)
	UILib.make("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 8),
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		VerticalAlignment = Enum.VerticalAlignment.Center, Parent = bar })
	local function mk(text, color, cb)
		local b = UILib.button({ Size = UDim2.fromOffset(104, 40), BackgroundColor3 = color,
			Text = text, TextSize = 15, TextColor3 = C.White, Parent = bar })
		b.MouseButton1Click:Connect(cb)
	end
	mk(label, C.Green, confirm)
	mk("Rotate", C.Blue, function() if active then active.rotationY = (active.rotationY + 45) % 360 end end)
	mk("Cancel", C.Red, PlacementController.cancel)
	return bar
end

local function startSession(opts)
	cleanup()

	local base = findOwnPlot()
	local surfaceY = base and (base.Position.Y + base.Size.Y / 2) or 1

	local ghost, body, arrow = buildGhost(opts.size, opts.color)
	ghost.Parent = Workspace
	mouse.TargetFilter = ghost

	active = {
		mode = opts.mode, item = opts.item, machine = opts.machine,
		ghost = ghost, body = body, arrow = arrow,
		rotationY = opts.rotationY or 0,
		base = base, surfaceY = surfaceY,
		savedTrans = {},
	}

	-- hide the original machine while moving so it's not in the way visually
	if opts.mode == "move" and opts.machine then
		for _, d in opts.machine:GetDescendants() do
			if d:IsA("BasePart") then
				active.savedTrans[d] = d.Transparency
				d.Transparency = 1
			end
		end
	end

	active.bar = buildBar(opts.label or "Place")
	active.conn = RunService.RenderStepped:Connect(updateGhost)
	active.inputConn = UserInputService.InputBegan:Connect(function(input, gp)
		if gp then return end
		if input.KeyCode == Enum.KeyCode.R then
			active.rotationY = (active.rotationY + 45) % 360
		elseif input.KeyCode == Enum.KeyCode.Escape then
			PlacementController.cancel()
		elseif input.UserInputType == Enum.UserInputType.MouseButton1 then
			confirm()
		end
	end)
end

function PlacementController.begin(item)
	startSession({
		mode = "place", item = item,
		size = Vector3.new(item.sizeX or 4, item.sizeY or 5, item.sizeZ or 3),
		color = Color3.new(item.r or 1, item.g or 1, item.b or 1),
		label = "Place",
	})
end

function PlacementController.beginMove(machine: Instance)
	if not machine or machine:GetAttribute("OwnerId") ~= player.UserId then return end
	local body = machine.PrimaryPart or machine:FindFirstChild("Body")
	if not (body and body:IsA("BasePart")) then return end
	local _, ry, _ = body.CFrame:ToOrientation()
	startSession({
		mode = "move", machine = machine,
		size = body.Size,
		color = body.Color,
		rotationY = math.deg(ry),
		label = "Move here",
	})
end

-- "Pick a machine to move" mode: shows a banner; on next click of one of your
-- own machines, switches into ghost move mode. Esc cancels.
local selectActive = nil

local function findOwnedMachineFromInstance(inst: Instance?): Instance?
	while inst and inst ~= Workspace do
		if inst:GetAttribute("GameType") and inst:GetAttribute("OwnerId") == player.UserId then
			return inst
		end
		inst = inst.Parent
	end
	return nil
end

local function endSelect()
	if not selectActive then return end
	if selectActive.banner then selectActive.banner:Destroy() end
	if selectActive.inputConn then selectActive.inputConn:Disconnect() end
	selectActive = nil
end

function PlacementController.enterSelectMode()
	endSelect()
	cleanup()

	local banner = UILib.make("Frame", {
		Name = "MoveSelectBanner", AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -18), Size = UDim2.fromOffset(420, 56),
		BackgroundColor3 = C.Panel, Parent = UILib.getScreen() })
	UILib.corner(banner, 12); UILib.stroke(banner, C.Accent, 2)
	UILib.make("TextLabel", {
		Size = UDim2.new(1, -120, 1, 0), Position = UDim2.fromOffset(12, 0),
		BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 15,
		TextColor3 = C.White, TextXAlignment = Enum.TextXAlignment.Left,
		Text = "Click a machine to move (Esc to cancel)", Parent = banner })
	local cancel = UILib.button({ Size = UDim2.fromOffset(96, 36),
		Position = UDim2.new(1, -108, 0.5, -18), BackgroundColor3 = C.Red,
		Text = "Cancel", TextSize = 14, TextColor3 = C.White, Parent = banner })
	cancel.MouseButton1Click:Connect(endSelect)

	selectActive = { banner = banner }
	selectActive.inputConn = UserInputService.InputBegan:Connect(function(input, gp)
		if gp then return end
		if input.KeyCode == Enum.KeyCode.Escape then endSelect(); return end
		if input.UserInputType ~= Enum.UserInputType.MouseButton1
			and input.UserInputType ~= Enum.UserInputType.Touch then return end
		local target = mouse.Target
		local m = findOwnedMachineFromInstance(target)
		if m then
			endSelect()
			PlacementController.beginMove(m)
		else
			UILib.toast("That's not your machine.", C.Red)
		end
	end)
end

return PlacementController
