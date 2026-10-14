--!nonstrict
-- Inventory.luau — owned-but-unplaced machines, stored in profile.Inventory as
-- { { id = "guid", machineId = "slots_basic" }, ... }. Server-authoritative.

local HttpService = game:GetService("HttpService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Config = require(Common:WaitForChild("Config"))

local Inventory = {}
local Data

function Inventory.list(player: Player)
	local p = Data.get(player)
	return p and p.Inventory or {}
end

function Inventory.count(player: Player): number
	return #Inventory.list(player)
end

function Inventory.add(player: Player, machineId: string)
	local p = Data.get(player)
	if not p then return nil end
	if #p.Inventory >= Config.MaxInventory then return nil end
	local item = { id = HttpService:GenerateGUID(false), machineId = machineId }
	table.insert(p.Inventory, item)
	return item
end

function Inventory.find(player: Player, itemId: string)
	for _, item in Inventory.list(player) do
		if item.id == itemId then return item end
	end
	return nil
end

function Inventory.remove(player: Player, itemId: string)
	local p = Data.get(player)
	if not p then return nil end
	for i, item in p.Inventory do
		if item.id == itemId then
			table.remove(p.Inventory, i)
			return item
		end
	end
	return nil
end

function Inventory.start(deps)
	Data = deps.Data
end

return Inventory
