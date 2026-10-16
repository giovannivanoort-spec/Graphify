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
function Remotes.ClaimDaily(): RemoteFunction return ensure("RemoteFunction", "ClaimDaily") :: RemoteFunction end
function Remotes.BuyTicketItem(): RemoteFunction return ensure("RemoteFunction", "BuyTicketItem") :: RemoteFunction end
function Remotes.TravelTo(): RemoteFunction return ensure("RemoteFunction", "TravelTo") :: RemoteFunction end
function Remotes.BuyStory(): RemoteFunction return ensure("RemoteFunction", "BuyStory") :: RemoteFunction end
function Remotes.SetCasinoName(): RemoteFunction return ensure("RemoteFunction", "SetCasinoName") :: RemoteFunction end
function Remotes.SetCasinoTheme(): RemoteFunction return ensure("RemoteFunction", "SetCasinoTheme") :: RemoteFunction end
function Remotes.RideElevator(): RemoteFunction return ensure("RemoteFunction", "RideElevator") :: RemoteFunction end
function Remotes.GetTrafficCars(): RemoteFunction return ensure("RemoteFunction", "GetTrafficCars") :: RemoteFunction end
-- the Rebirth & Rewards update (each module sets its own OnServerInvoke)
--   Rebirth()                         -> { ok, message, count, coins }
--   BuyRebirthUpgrade(id)             -> { ok, message, level }
--   UsePotion(potionId)               -> { ok, message, seconds }
--   SetBoostTarget(placedId)          -> { ok }   (call right before prompting the machine-boost product)
--   ApplyStoredBoost(placedId, secs?) -> { ok, message, seconds }
--   ClaimPlaytime(index)              -> { ok, message, reward }
--   BuyDecor(decorId) / PlaceDecor(decorId, x, z, rotY, story) / MoveDecor(placedId, x, z, rotY, story)
--   PickupDecor(placedId) / SellDecor(placedId)
--   PromoteStaff(staffId)             -> { ok, message, level }
function Remotes.Rebirth(): RemoteFunction return ensure("RemoteFunction", "Rebirth") :: RemoteFunction end
function Remotes.BuyRebirthUpgrade(): RemoteFunction return ensure("RemoteFunction", "BuyRebirthUpgrade") :: RemoteFunction end
function Remotes.UsePotion(): RemoteFunction return ensure("RemoteFunction", "UsePotion") :: RemoteFunction end
function Remotes.SetBoostTarget(): RemoteFunction return ensure("RemoteFunction", "SetBoostTarget") :: RemoteFunction end
function Remotes.ApplyStoredBoost(): RemoteFunction return ensure("RemoteFunction", "ApplyStoredBoost") :: RemoteFunction end
function Remotes.ClaimPlaytime(): RemoteFunction return ensure("RemoteFunction", "ClaimPlaytime") :: RemoteFunction end
function Remotes.BuyDecor(): RemoteFunction return ensure("RemoteFunction", "BuyDecor") :: RemoteFunction end
function Remotes.PlaceDecor(): RemoteFunction return ensure("RemoteFunction", "PlaceDecor") :: RemoteFunction end
function Remotes.MoveDecor(): RemoteFunction return ensure("RemoteFunction", "MoveDecor") :: RemoteFunction end
function Remotes.PickupDecor(): RemoteFunction return ensure("RemoteFunction", "PickupDecor") :: RemoteFunction end
function Remotes.SellDecor(): RemoteFunction return ensure("RemoteFunction", "SellDecor") :: RemoteFunction end
function Remotes.PromoteStaff(): RemoteFunction return ensure("RemoteFunction", "PromoteStaff") :: RemoteFunction end
-- the Cheaters & VIP update (each module sets its own OnServerInvoke)
--   KickGuest(npcModel)               -> { ok, message, cheater, reward }   (owner only, own casino)
--   ClaimQuest(questId)               -> { ok, message, reward }
--   RerollQuest(questId)              -> { ok, message }
--   SpinWheel(kind)                   -> { ok, message, index, prize }       kind = "free" | "tickets"
function Remotes.KickGuest(): RemoteFunction return ensure("RemoteFunction", "KickGuest") :: RemoteFunction end
function Remotes.ClaimQuest(): RemoteFunction return ensure("RemoteFunction", "ClaimQuest") :: RemoteFunction end
function Remotes.RerollQuest(): RemoteFunction return ensure("RemoteFunction", "RerollQuest") :: RemoteFunction end
function Remotes.SpinWheel(): RemoteFunction return ensure("RemoteFunction", "SpinWheel") :: RemoteFunction end

-- RemoteEvents (server -> client pushes) -------------------------
function Remotes.DataUpdated(): RemoteEvent return ensure("RemoteEvent", "DataUpdated") :: RemoteEvent end
function Remotes.WelcomeBack(): RemoteEvent return ensure("RemoteEvent", "WelcomeBack") :: RemoteEvent end
-- a car leaves a tunnel: { id, spec (RoadNet route), t0 (server time), kind, color }
function Remotes.TrafficCar(): RemoteEvent return ensure("RemoteEvent", "TrafficCar") :: RemoteEvent end
-- owner-facing effects (Gambling -> CasinoClient/UXFX), purely cosmetic:
--   { kind = "income", list = { { m = machine, p = Vector3, a = amount, c = isConcession? }, ... } }
--   { kind = "bigwin", machine, pos, amount, mult, name, by? }
function Remotes.FX(): RemoteEvent return ensure("RemoteEvent", "FX") :: RemoteEvent end
-- the owner reached a new Casino Rank (Progression -> that client):
--   { rank = n, name = "...", from = previous rank, clientele = x,
--     unlocks = { machines = {ids}, levels = { {track = id, level = n} }, floor = n?, staff = {ids} } }
function Remotes.RankUp(): RemoteEvent return ensure("RemoteEvent", "RankUp") :: RemoteEvent end
-- a rebirth went through (Rebirth -> that client): { count, coins, coinsTotal }
function Remotes.RebirthDone(): RemoteEvent return ensure("RemoteEvent", "RebirthDone") :: RemoteEvent end
-- a suspicious guest is winning at the owner's casino (Cheaters -> owner): { npc, machine, name }
function Remotes.CheaterAlert(): RemoteEvent return ensure("RemoteEvent", "CheaterAlert") :: RemoteEvent end
-- a guest was thrown out (-> everyone near, for the effects): { npc, by = "owner" | "security", cheater, reward, ownerId }
function Remotes.GuestKicked(): RemoteEvent return ensure("RemoteEvent", "GuestKicked") :: RemoteEvent end
-- a server-wide casino event started / ended (Events -> all): { id, name, desc, endsAt (server os.time), active }
function Remotes.CasinoEvent(): RemoteEvent return ensure("RemoteEvent", "CasinoEvent") :: RemoteEvent end
-- a quest is complete (Quests -> that client): { id, title }
function Remotes.QuestDone(): RemoteEvent return ensure("RemoteEvent", "QuestDone") :: RemoteEvent end

-- On the server, create every remote at require time. Otherwise remotes that are
-- only touched lazily (e.g. WelcomeBack, which is fired only when there's offline
-- income) may never exist, and a client doing WaitForChild on them times out and
-- gets nil — which previously crashed the whole client boot.
if RunService:IsServer() then
	Remotes.GetCatalog(); Remotes.GetData(); Remotes.BuyToInventory(); Remotes.PlaceFromInventory()
	Remotes.PickupMachine(); Remotes.MoveMachine(); Remotes.SellMachine(); Remotes.HireStaff()
	Remotes.BuyUpgrade(); Remotes.UpgradeMachine(); Remotes.PlayGame(); Remotes.ClaimOffline()
	Remotes.GetMonetization(); Remotes.ClaimDaily(); Remotes.BuyTicketItem(); Remotes.TravelTo()
	Remotes.BuyStory(); Remotes.SetCasinoName(); Remotes.SetCasinoTheme(); Remotes.RideElevator()
	Remotes.GetTrafficCars()
	Remotes.Rebirth(); Remotes.BuyRebirthUpgrade(); Remotes.UsePotion(); Remotes.SetBoostTarget()
	Remotes.ApplyStoredBoost(); Remotes.ClaimPlaytime(); Remotes.BuyDecor(); Remotes.PlaceDecor()
	Remotes.MoveDecor(); Remotes.PickupDecor(); Remotes.SellDecor(); Remotes.PromoteStaff()
	Remotes.DataUpdated(); Remotes.WelcomeBack(); Remotes.TrafficCar(); Remotes.FX(); Remotes.RankUp()
	Remotes.RebirthDone()
	Remotes.KickGuest(); Remotes.ClaimQuest(); Remotes.RerollQuest(); Remotes.SpinWheel()
	Remotes.CheaterAlert(); Remotes.GuestKicked(); Remotes.CasinoEvent(); Remotes.QuestDone()
end

return Remotes
