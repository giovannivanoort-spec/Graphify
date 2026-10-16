--!nonstrict
-- TrafficClient.luau — drives the city's cars on this client. The server
-- plans them (CasinoServer/Traffic) and only sends a small route spec + start
-- time per car; every frame each car is put where its RoadNet route says it is
-- at the server's clock, so every player sees the same car in the same place
-- and the patrons (server NPCs) step out just as it stops at their casino.
--   * cars are clones of the ReplicatedStorage.TrafficCars templates
--     (anchored; no collisions, queries or touches), all moved with one
--     BulkMoveTo per frame
--   * a car is made when it leaves its tunnel (s 470, deep in the dark) and
--     destroyed when it's back in one; cars far from the camera leave the
--     world until they come close again (they keep their schedule)
--   * sedans, sports cars and white limos wear the body colour sent with them

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Config = require(Common:WaitForChild("Config"))
local Remotes = require(Common:WaitForChild("Remotes"))
local RoadNet = require(Common:WaitForChild("RoadNet"))

local TrafficClient = {}

local TC = Config.Traffic or {}
local RECOLOR = { Body = true, Roof = true, Spoiler = true } -- the parts that wear the body colour

local cars = {}        -- id -> { route, t0, kind, color, model?, parts, offsets, shown }
local templates = nil  -- ReplicatedStorage.TrafficCars
local folder = nil     -- Workspace.Traffic (this client's own)

local function templateName(kind): string
	if type(kind) ~= "string" or kind == "" then return "Sedan" end
	return kind:sub(1, 1):upper() .. kind:sub(2)
end

local function addCar(p)
	if type(p) ~= "table" or type(p.id) ~= "number" or type(p.t0) ~= "number" or cars[p.id] then return end
	local ok, route = pcall(RoadNet.build, p.spec)
	if not (ok and route) then return end
	cars[p.id] = {
		route = route, t0 = p.t0, kind = p.kind,
		color = typeof(p.color) == "Color3" and p.color or nil,
	}
end

-- the car's model, cloned the first time it comes into view
local function makeModel(car): boolean
	if not templates then return false end
	local tpl = templates:FindFirstChild(templateName(car.kind)) or templates:FindFirstChild("Sedan")
	if not tpl then return false end
	local m = tpl:Clone()
	if not m then return false end -- (Clone gives nil for a non-Archivable template)
	local parts, offsets = {}, {}
	for _, d in m:GetDescendants() do
		if d:IsA("BasePart") then
			table.insert(parts, d)
			table.insert(offsets, d.CFrame) -- templates sit at the origin: this is the part's place in the car
			if car.color and RECOLOR[d.Name] then d.Color = car.color end
		end
	end
	car.model, car.parts, car.offsets = m, parts, offsets
	return true
end

local moveParts, moveCFrames = {}, {}

local function step()
	local now = Workspace:GetServerTimeNow()
	local cam = Workspace.CurrentCamera
	local eye = cam and cam.CFrame.Position or Vector3.zero
	local cull = TC.CullDistance or 850
	local count = 0
	for id, car in cars do
		local t = now - car.t0
		if t >= car.route.duration then
			-- back inside a tunnel
			if car.model then car.model:Destroy() end
			cars[id] = nil
		elseif t >= 0 then
			local cf = car.route:sample(t)
			if (cf.Position - eye).Magnitude < cull then
				if car.model or makeModel(car) then
					if not car.shown then
						car.model.Parent = folder
						car.shown = true
					end
					for i, part in car.parts do
						count += 1
						moveParts[count] = part
						moveCFrames[count] = cf * car.offsets[i]
					end
				end
			elseif car.shown then
				car.model.Parent = nil
				car.shown = false
			end
		end
	end
	for i = #moveParts, count + 1, -1 do
		moveParts[i] = nil
		moveCFrames[i] = nil
	end
	if count > 0 then
		Workspace:BulkMoveTo(moveParts, moveCFrames, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

function TrafficClient.start()
	if TC.Enabled == false then return end
	folder = Instance.new("Folder")
	folder.Name = "Traffic"
	folder.Parent = Workspace
	task.spawn(function()
		templates = ReplicatedStorage:WaitForChild("TrafficCars", 120)
	end)
	Remotes.TrafficCar().OnClientEvent:Connect(addCar)
	-- the cars already on the road when we joined
	task.spawn(function()
		local ok, list = pcall(function()
			return Remotes.GetTrafficCars():InvokeServer()
		end)
		if ok and type(list) == "table" then
			for _, p in list do addCar(p) end
		end
	end)
	RunService.RenderStepped:Connect(step)
end

return TrafficClient
