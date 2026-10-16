--!nonstrict
-- MachineFX.luau — client-side life for the code-built 3D machines. Everything
-- here is local (cheap for the server, never replicated):
--   * marquee bulbs chase on every machine / showroom display / prop (the
--     services desk) with a Bulbs folder
--   * on each play the server bumps the machine's "PlayTick" attribute (and
--     sets "LastWin"); we then spin the roulette wheel + ball, spin the fortune
--     wheel, tumble the dice (Die1..Die3), pull the slot lever or drop the
--     Plinko ball through its pins ("LastPath"), and flash the bulbs on a win
--   * showpiece gems (sub-models with a SpinRate attribute) turn slowly; a
--     spinner turns about its PrimaryPart's own +Y, whichever way that points
--     (the Diamond Vault's door handle turns about the door's axis)
--   * a win bursts the machine's own "Sparks" particle emitters (the Rebirth
--     Wing's embers, glints, gold dust); a model with BurstOnPlay bursts on
--     every play (the Volcano erupts with each roll)
--   * MachineFX.flash(model, seconds) strobes a machine's bulbs on demand (UXFX
--     calls it when a guest hits a big win on one of your machines)
-- Works with StreamingEnabled: models are tracked as they stream in and out.

local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

local MachineFX = {}

local ON = Color3.fromHex("#FFF3A8")
local ON_ALT = Color3.new(1, 1, 1)
local OFF = Color3.fromHex("#6B4A0E")
local TAGS = { "CasinoMachine", "CasinoShopDisplay", "CasinoProp" }
local CHASE_RANGE = 300 -- studs: bulbs farther from the camera than this don't chase

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
	-- DiceHop: how high the dice jump (the Sic Bo dome keeps them low)
	local hopH = tonumber(model:GetAttribute("DiceHop")) or 0.9
	for i, name in { "Die1", "Die2", "Die3" } do
		local d = model:FindFirstChild(name)
		if d then
			task.spawn(function()
				local base = d.CFrame
				local spinA = Vector3.new(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5).Unit
				local turns = math.rad(360 + math.random(0, 720))
				local final = CFrame.Angles(math.rad(90 * math.random(0, 3)), math.rad(math.random(0, 359)), math.rad(90 * math.random(0, 3)))
				task.wait((i - 1) * 0.08)
				animate(1.1, function(a)
					local hop = math.sin(a * math.pi) * hopH
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

local function flashBulbs(model, seconds: number?)
	local st = tracked[model]
	if not st then return false end
	st.flashUntil = math.max(st.flashUntil, os.clock() + (seconds or 1.6))
	return true
end

-- PLINKO: the Ball drops through the pin board one row every 0.12 s along the
-- server's path (the "LastPath" attribute: 8 x "0"/"1", 1 = right), bounces
-- on the pins Pegs/P<row>_<rights so far> and lands in Pockets/Pocket<1 +
-- rights>, which lights up. Without a (matching) path it takes a random one
-- that agrees with LastWin.
local PLINKO_WIN_POCKET = { true, true, true, false, false, false, true, true, true }
local PLINKO_ODDS = { 1, 8, 28, 56, 70, 56, 28, 8, 1 } -- C(8, k)

local function countRights(path: string): number
	return select(2, path:gsub("1", ""))
end

local function randomPath(won: boolean): string
	local pockets = won and { 1, 2, 3, 7, 8, 9 } or { 4, 5, 6 }
	local total = 0
	for _, p in pockets do total += PLINKO_ODDS[p] end
	local r = math.random() * total
	local pocket = pockets[#pockets]
	for _, p in pockets do
		r -= PLINKO_ODDS[p]
		if r <= 0 then pocket = p break end
	end
	local bits = {}
	for i = 1, 8 do bits[i] = (i <= pocket - 1) and "1" or "0" end
	for i = 8, 2, -1 do
		local j = math.random(1, i)
		bits[i], bits[j] = bits[j], bits[i]
	end
	return table.concat(bits)
end

local function dropPlinko(model)
	local ball = model:FindFirstChild("Ball")
	local pegs = model:FindFirstChild("Pegs")
	local pockets = model:FindFirstChild("Pockets")
	local anchor = model.PrimaryPart
	if not (ball and ball:IsA("BasePart") and pegs and pockets and anchor) then return end
	local won = model:GetAttribute("LastWin") == true
	local path = model:GetAttribute("LastPath")
	if type(path) ~= "string" or #path ~= 8 or PLINKO_WIN_POCKET[countRights(path) + 1] ~= won then
		path = randomPath(won)
	end
	-- the rest spot, kept relative to the cabinet (the owner may move it)
	local rel = anchor.CFrame:ToObjectSpace(ball.CFrame)
	local start = ball.CFrame
	local look, up = start.LookVector, start.UpVector
	local r = ball.Size.X / 2
	-- a point on the board brought into the ball's plane
	local function onPlane(p: Vector3): Vector3
		return p + look * ((start.Position - p):Dot(look))
	end
	local points = {}
	local k = 0
	for row = 1, 8 do
		local peg = pegs:FindFirstChild(("P%d_%d"):format(row, k))
		if not (peg and peg:IsA("BasePart")) then return end
		table.insert(points, onPlane(peg.Position) + up * (peg.Size.Y / 2 + r))
		if path:sub(row, row) == "1" then k += 1 end
	end
	local pocket = pockets:FindFirstChild("Pocket" .. (k + 1))
	if not (pocket and pocket:IsA("BasePart")) then return end
	local rest = onPlane(pocket.Position) - up * (pocket.Size.Y / 2 - r)

	local function place(p: Vector3)
		if ball.Parent then ball.CFrame = CFrame.new(p) * start.Rotation end
	end
	-- fall onto the first pin, hop from pin to pin, drop into the bin
	local from = start.Position
	animate(0.2, function(a) place(from:Lerp(points[1], a * a)) end)
	for i = 1, #points - 1 do
		local p0, p1 = points[i], points[i + 1]
		local hop = (p1 - p0).Magnitude * 0.3
		animate(0.12, function(a) place(p0:Lerp(p1, a) + up * (hop * 4 * a * (1 - a))) end)
	end
	local last = points[#points]
	animate(0.24, function(a) place(last:Lerp(rest, a * a) + up * (0.12 * 4 * a * (1 - a))) end)
	-- the bin lights up; a win strobes the bulbs
	local mat, col = pocket.Material, pocket.Color
	pocket.Material = Enum.Material.Neon
	pocket.Color = col:Lerp(Color3.new(1, 1, 1), 0.25)
	if won then flashBulbs(model, 1.4) end
	task.wait(0.9)
	if pocket.Parent then
		pocket.Material = mat
		pocket.Color = col
	end
	-- back to the chute
	if ball.Parent and anchor.Parent then ball.CFrame = anchor.CFrame * rel end
end

-- IDLE SPINNERS: sub-models with a SpinRate attribute (degrees per second)
-- turn slowly about their PrimaryPart's up axis: the showpiece gems on the
-- Billionaire Roulette and the Jewelry Boutique. Only near the camera.
local SPIN_RANGE = 160
local spinners: {[Model]: any} = {}

local function trackSpinners(model)
	for _, d in model:GetDescendants() do
		if d:IsA("Model") and d:GetAttribute("SpinRate") and not spinners[d] then
			spinners[d] = { owner = model, angle = 0 }
		end
	end
end

local function stepSpinners(dt: number)
	local cam = workspace.CurrentCamera
	local camPos = cam and cam.CFrame.Position or Vector3.zero
	for sp, rec in spinners do
		if not sp.Parent or not rec.owner.Parent then
			spinners[sp] = nil
			continue
		end
		local core = sp.PrimaryPart
		if not core then continue end
		if (core.Position - camPos).Magnitude > SPIN_RANGE then continue end
		-- first sight, or the server moved the machine (turning never moves the
		-- core): every part stands as the server placed it, so start over
		if not rec.pivot or (core.Position - rec.pivot.Position).Magnitude > 0.01 then
			rec.pivot = core.CFrame
			rec.angle = 0
			rec.base = {}
		end
		-- parts that stream in later arrive unturned too
		for _, p in sp:GetChildren() do
			if p:IsA("BasePart") and not rec.base[p] then
				rec.base[p] = rec.pivot:ToObjectSpace(p.CFrame)
			end
		end
		rec.angle = (rec.angle + math.rad(sp:GetAttribute("SpinRate") or 30) * dt) % (math.pi * 2)
		local turn = rec.pivot * CFrame.Angles(0, rec.angle, 0)
		for p, rel in rec.base do
			if p.Parent then p.CFrame = turn * rel else rec.base[p] = nil end
		end
	end
end

-- strobe a machine's bulbs for `seconds` (UXFX: a guest's big win on your floor)
function MachineFX.flash(model: Instance, seconds: number?): boolean
	return flashBulbs(model, seconds)
end

-- a burst from the machine's own "Sparks" emitters (near the camera only)
local BURST_RANGE = 120
local function burstSparks(model, count: number)
	local st = tracked[model]
	if not (st and st.sparks and #st.sparks > 0) then return end
	local cam = workspace.CurrentCamera
	if cam and (model:GetPivot().Position - cam.CFrame.Position).Magnitude > BURST_RANGE then return end
	for _, e in st.sparks do
		if e.Parent then pcall(function() e:Emit(count) end) end
	end
end

local function onPlay(model)
	local won = model:GetAttribute("LastWin") == true
	if won or model:GetAttribute("BurstOnPlay") then burstSparks(model, won and 14 or 8) end
	if busy[model] then
		flashBulbs(model)
		return
	end
	busy[model] = true
	local t = model:GetAttribute("GameType") or model:GetAttribute("DemoType")
	-- (a Plinko win flashes when the ball lands)
	if won and t ~= "Plinko" then flashBulbs(model) end
	local ok, err = pcall(function()
		if t == "Roulette" then
			spinRoulette(model)
		elseif t == "Wheel" then
			spinFortune(model)
		elseif t == "Dice" then
			rollDice(model)
		elseif t == "Slots" then
			pullLever(model)
		elseif t == "Plinko" then
			dropPlinko(model)
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
	local st = { bulbs = folder and folder:GetChildren() or {}, flashUntil = 0, sparks = {} }
	tracked[model] = st
	st.conn = model:GetAttributeChangedSignal("PlayTick"):Connect(function()
		task.spawn(onPlay, model)
	end)
	-- showpiece gems that turn and the "Sparks" emitters a win bursts (both
	-- may stream in after the model)
	local function addSparks(d: Instance)
		if d:IsA("ParticleEmitter") and d.Name == "Sparks" and not table.find(st.sparks, d) then
			table.insert(st.sparks, d)
		end
	end
	trackSpinners(model)
	for _, d in model:GetDescendants() do addSparks(d) end
	st.spinConn = model.DescendantAdded:Connect(function(d)
		if d:IsA("Model") and d:GetAttribute("SpinRate") then trackSpinners(model) end
		addSparks(d)
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
	if st.spinConn then st.spinConn:Disconnect() end
	tracked[model] = nil
	busy[model] = nil
end

function MachineFX.start()
	for _, tag in TAGS do
		for _, m in CollectionService:GetTagged(tag) do track(m) end
		CollectionService:GetInstanceAddedSignal(tag):Connect(track)
		CollectionService:GetInstanceRemovedSignal(tag):Connect(untrack)
	end
	local spinWarned = 0
	RunService.RenderStepped:Connect(function(dt)
		if next(spinners) ~= nil then
			local ok, err = pcall(stepSpinners, dt)
			if not ok and spinWarned < 3 then
				spinWarned += 1
				warn("[MachineFX] spin: " .. tostring(err))
			end
		end
	end)
	-- the chase: alternate bulbs swap every 0.35 s; a machine that's flashing
	-- (a win, a jackpot) strobes all its bulbs together every 0.12 s while the
	-- rest keep their pace. Signs far from the camera keep their last colours
	-- (a city of 23 casinos has thousands of bulbs; nobody sees a chase 300
	-- studs away)
	task.spawn(function()
		local phase, strobe, sinceChase = 0, 0, 1
		while true do
			local now = os.clock()
			local chaseTick = sinceChase >= 0.34
			if chaseTick then
				sinceChase = 0
				phase = 1 - phase
			end
			strobe = 1 - strobe
			local cam = workspace.CurrentCamera
			local camPos = cam and cam.CFrame.Position or Vector3.zero
			local anyFlash = false
			for model, st in tracked do
				if not model.Parent then
					untrack(model)
				else
					local flashing = now < st.flashUntil
					if flashing then anyFlash = true end
					if flashing or (chaseTick and (model:GetPivot().Position - camPos).Magnitude <= CHASE_RANGE) then
						for _, b in st.bulbs do
							if b:IsA("BasePart") and b.Parent then
								local on = flashing and (strobe == 1) or ((b:GetAttribute("Phase") or 0) == phase)
								b.Color = on and ((b:GetAttribute("Phase") == 1) and ON_ALT or ON) or OFF
							end
						end
					end
				end
			end
			sinceChase += task.wait(anyFlash and 0.12 or 0.35)
		end
	end)
end

return MachineFX
