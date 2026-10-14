--!strict
-- Remotes.luau — creates/returns all RemoteEvents & RemoteFunctions once.
-- Works whether required first on the server or the client.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Remotes = {}
local FOLDER_NAME = "CasinoRemotes"

local function getFolder(): Folder
	local folder = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
	if not folder then
		if RunService:IsServer() then
			folder = Instance.new("Folder")
			folder.Name = FOLDER_NAME
			folder.Parent = ReplicatedStorage
		else
			folder = ReplicatedStorage:WaitForChild(FOLDER_NAME, 15)
		end
	end
	return folder :: Folder
end

local function ensure(className: string, name: string): Instance
	local folder = getFolder()
	local existing = folder:FindFirstChild(name)
	if existing then return existing end
	if RunService:IsServer() then
		local inst = Instance.new(className)
		inst.Name = name
		inst.Parent = folder
		return inst
	end
	return folder:WaitForChild(name, 15)
end

-- RemoteFunctions (request/response) -----------------------------
function Remotes.GetCatalog(): RemoteFunction return ensure("RemoteFunction", "GetCatalog") :: RemoteFunction end
function Remotes.GetData(): RemoteFunction return ensure("RemoteFunction", "GetData") :: RemoteFunction end
function Remotes.BuyToInventory(): RemoteFunction return ensure("RemoteFunction", "BuyToInventory") :: RemoteFunction end
function Remotes.PlaceFromInventory(): RemoteFunction return ensure("RemoteFunction", "PlaceFromInventory") :: RemoteFunction end
function Remotes.PickupMachine(): RemoteFunction return ensure("RemoteFunction", "PickupMachine") :: RemoteFunction end
function Remotes.MoveMachine(): RemoteFunction return ensure("RemoteFunction", "MoveMachine") :: RemoteFunction end
function Remotes.SellMachine(): RemoteFunction return ensure("RemoteFunction", "SellMachine") :: RemoteFunction end
function Remotes.HireStaff(): RemoteFunction return ensure("RemoteFunction", "HireStaff") :: RemoteFunction end
function Remotes.BuyUpgrade(): RemoteFunction return ensure("RemoteFunction", "BuyUpgrade") :: RemoteFunction end
function Remotes.UpgradeMachine(): RemoteFunction return ensure("RemoteFunction", "UpgradeMachine") :: RemoteFunction end
function Remotes.PlayGame(): RemoteFunction return ensure("RemoteFunction", "PlayGame") :: RemoteFunction end
function Remotes.ClaimOffline(): RemoteFunction return ensure("RemoteFunction", "ClaimOffline") :: RemoteFunction end
function Remotes.GetMonetization(): RemoteFunction return ensure("RemoteFunction", "GetMonetization") :: RemoteFunction end

-- RemoteEvents (server -> client pushes) -------------------------
function Remotes.DataUpdated(): RemoteEvent return ensure("RemoteEvent", "DataUpdated") :: RemoteEvent end
function Remotes.WelcomeBack(): RemoteEvent return ensure("RemoteEvent", "WelcomeBack") :: RemoteEvent end

-- On the server, create every remote at require time. Otherwise remotes that are
-- only touched lazily (e.g. WelcomeBack, which is fired only when there's offline
-- income) may never exist, and a client doing WaitForChild on them times out and
-- gets nil — which previously crashed the whole client boot.
if RunService:IsServer() then
	Remotes.GetCatalog(); Remotes.GetData(); Remotes.BuyToInventory(); Remotes.PlaceFromInventory()
	Remotes.PickupMachine(); Remotes.MoveMachine(); Remotes.SellMachine(); Remotes.HireStaff()
	Remotes.BuyUpgrade(); Remotes.UpgradeMachine(); Remotes.PlayGame(); Remotes.ClaimOffline()
	Remotes.GetMonetization()
	Remotes.DataUpdated(); Remotes.WelcomeBack()
end

return Remotes
