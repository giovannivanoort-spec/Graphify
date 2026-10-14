--!nonstrict
-- MachineFX.luau — client-side life for the code-built 3D machines. Everything
-- here is local (cheap for the server, never replicated):
--   * marquee bulbs chase on every machine / showroom display / prop (the
--     services desk) with a Bulbs folder
--   * on each play the server bumps the machine's "PlayTick" attribute (and
--     sets "LastWin"); we then spin the roulette wheel + ball, spin the fortune
--     wheel, tumble the dice or pull the slot lever, and flash the bulbs on a win
-- Works with StreamingEnabled: models are tracked as they stream in and out.

local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

local MachineFX = {}

local ON = Color3.fromHex("#FFF3A8")
local ON_ALT = Color3.new(1, 1, 1)
local OFF = Color3.fromHex("#6B4A0E")
local TAGS = { "CasinoMachine", "CasinoShopDisplay", "CasinoProp" }

local tracked: {[Model]: any} = {}
local busy: {[Model]: boolean} = {}

local function easeOutCubic(t: number): number
	return 1 - (1 - t) ^ 3
end

-- run `step(alpha)` every frame for `duration` seconds
local function animate(duration: number, step: (number) -> ())
	local t0 = os.clock()
	while true do
		local a = math.min((os.clock() - t0) / duration, 1)
		step(a)
		if a >= 1 then break end
		RunService.RenderStepped:Wait()
	end
end

-- rotate a set of parts about an axis through `centre`
local function rotateParts(parts, bases, centre: Vector3, axis: Vector3, angle: number)
	local rot = CFrame.new(centre) * CFrame.fromAxisAngle(axis, angle) * CFrame.new(-centre)
	for i, p in parts do
		if p.Parent then p.CFrame = rot * bases[i] end
	end
end

------------------------------------------------------------------
-- per-type play animations
------------------------------------------------------------------
local function spinRoulette(model)
	local wheel = model:FindFirstChild("Wheel")
	if not wheel then return end
	local parts, bases = {}, {}
	for _, n in { "Wheel", "Turret", "TurretKnob" } do
		local p = model:FindFirstChild(n)
		if p then table.insert(parts, p); table.insert(bases, p.CFrame) end
	end
	local ball = model:FindFirstChild("Ball")
	local centre = wheel.Position
	local up = Vector3.yAxis
	local ballBase = ball and ball.CFrame
	local ballR = ball and (Vector3.new(ball.Position.X, centre.Y, ball.Position.Z) - centre).Magnitude or 1.2
	local ballY = ball and ball.Position.Y or centre.Y
	local total = math.rad(540 + math.random(0, 359))
	local ballStart = math.random() * math.pi * 2
	animate(3.0, function(a)
		local e = easeOutCubic(a)
		rotateParts(parts, bases, centre, up, total * e)
		if ball and ball.Parent then
			-- ball runs the other way, then drops into the wheel and rides it
			local ang = ballStart - total * 1.6 * e
			local r = ballR + (1 - e) * 0.18
			ball.CFrame = CFrame.new(centre + Vector3.new(math.cos(ang) * r, ballY - centre.Y, math.sin(ang) * r))
		end
	end)
	local _ = ballBase
end

local function spinFortune(model)
	local wheel = model:FindFirstChild("Wheel")
	if not wheel then return end
	local parts, bases = {}, {}
	for _, n in { "Wheel", "Hub", "HubCap" } do
		local p = model:FindFirstChild(n)
		if p then table.insert(parts, p); table.insert(bases, p.CFrame) end
	end
	local axis = wheel.CFrame.RightVector -- the cylinder's axle
	local centre = wheel.Position
	local pointer = model:FindFirstChild("Pointer")
	local pBase = pointer and pointer.CFrame
	local total = math.rad(720 + math.random(0, 359))
	local lastClick = 0
	animate(3.4, function(a)
		local angle = total * easeOutCubic(a)
		rotateParts(parts, bases, centre, axis, angle)
		-- the pointer flicks as pegs pass
		if pointer and pBase then
			local seg = math.floor(angle / (math.pi * 2 / 12))
			if seg ~= lastClick then
				lastClick = seg
				pointer.CFrame = pBase * CFrame.Angles(0, 0, math.rad(12))
			else
				pointer.CFrame = pointer.CFrame:Lerp(pBase, 0.35)
			end
		end
	end)
	if pointer and pBase then pointer.CFrame = pBase end
end

local function rollDice(model)
	for i, name in { "Die1", "Die2" } do
		local d = model:FindFirstChild(name)
		if d then
			task.spawn(function()
				local base = d.CFrame
				local spinA = Vector3.new(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5).Unit
				local turns = math.rad(360 + math.random(0, 720))
				local final = CFrame.Angles(math.rad(90 * math.random(0, 3)), math.rad(math.random(0, 359)), math.rad(90 * math.random(0, 3)))
				task.wait((i - 1) * 0.08)
				animate(1.1, function(a)
					local hop = math.sin(a * math.pi) * 0.9
					local pos = base.Position + Vector3.new(0, hop, 0)
					if a < 1 then
						d.CFrame = CFrame.new(pos) * CFrame.fromAxisAngle(spinA, turns * a) * base.Rotation
					else
						d.CFrame = CFrame.new(base.Position) * final
					end
				end)
			end)
		end
	end
	task.wait(1.2)
end

local function pullLever(model)
	local lever = model:FindFirstChild("Lever")
	if not (lever and lever:IsA("Model") and lever.PrimaryPart) then return end
	local hub = lever.PrimaryPart
	local parts, bases = {}, {}
	for _, p in lever:GetChildren() do
		if p:IsA("BasePart") then table.insert(parts, p); table.insert(bases, p.CFrame) end
	end
	local axis = hub.CFrame.RightVector
	animate(0.18, function(a) rotateParts(parts, bases, hub.Position, axis, math.rad(-42) * a) end)
	animate(0.45, function(a) rotateParts(parts, bases, hub.Position, axis, math.rad(-42) * (1 - easeOutCubic(a))) end)
end

local function flashBulbs(model)
	local st = tracked[model]
	if not st then return end
	st.flashUntil = os.clock() + 1.6
end

local function onPlay(model)
	if busy[model] then
		flashBulbs(model)
		return
	end
	busy[model] = true
	if model:GetAttribute("LastWin") then flashBulbs(model) end
	local ok, err = pcall(function()
		local t = model:GetAttribute("GameType")
		if t == "Roulette" then
			spinRoulette(model)
		elseif t == "Wheel" then
			spinFortune(model)
		elseif t == "Dice" then
			rollDice(model)
		elseif t == "Slots" then
			pullLever(model)
		end
	end)
	if not ok then warn("[MachineFX] " .. tostring(err)) end
	busy[model] = nil
end

------------------------------------------------------------------
-- tracking (works with streaming)
------------------------------------------------------------------
local function track(model: Instance)
	if not model:IsA("Model") or tracked[model] then return end
	local folder = model:FindFirstChild("Bulbs")
	local st = { bulbs = folder and folder:GetChildren() or {}, flashUntil = 0 }
	tracked[model] = st
	st.conn = model:GetAttributeChangedSignal("PlayTick"):Connect(function()
		task.spawn(onPlay, model)
	end)
	-- bulbs may stream in after the model itself
	if folder then
		folder.ChildAdded:Connect(function() st.bulbs = folder:GetChildren() end)
	else
		st.childConn = model.ChildAdded:Connect(function(c)
			if c.Name == "Bulbs" then
				st.bulbs = c:GetChildren()
				c.ChildAdded:Connect(function() st.bulbs = c:GetChildren() end)
			end
		end)
	end
end

local function untrack(model: Instance)
	local st = tracked[model]
	if not st then return end
	if st.conn then st.conn:Disconnect() end
	if st.childConn then st.childConn:Disconnect() end
	tracked[model] = nil
	busy[model] = nil
end

function MachineFX.start()
	for _, tag in TAGS do
		for _, m in CollectionService:GetTagged(tag) do track(m) end
		CollectionService:GetInstanceAddedSignal(tag):Connect(track)
		CollectionService:GetInstanceRemovedSignal(tag):Connect(untrack)
	end
	-- the chase: alternate bulbs swap every 0.35 s (fast strobe while flashing)
	task.spawn(function()
		local phase = 0
		while true do
			local now = os.clock()
			phase = 1 - phase
			for model, st in tracked do
				if not model.Parent then
					untrack(model)
				else
					local flashing = now < st.flashUntil
					for _, b in st.bulbs do
						if b:IsA("BasePart") and b.Parent then
							local on = flashing and (phase == 1) or ((b:GetAttribute("Phase") or 0) == phase)
							b.Color = on and ((b:GetAttribute("Phase") == 1) and ON_ALT or ON) or OFF
						end
					end
				end
			end
			task.wait(0.35)
		end
	end)
end

return MachineFX
