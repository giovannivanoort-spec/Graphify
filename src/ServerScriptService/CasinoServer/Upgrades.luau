--!nonstrict
-- Upgrades.luau — server module for one-time owner upgrades.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Config = require(Common:WaitForChild("Config"))

local Upgrades = {}
local Economy, Data

function Upgrades.has(profile, id: string): boolean
	if not profile or not profile.Upgrades then return false end
	for _, owned in profile.Upgrades do
		if owned == id then return true end
	end
	return false
end

-- Sum the named effect key across every upgrade the owner has.
function Upgrades.effect(profile, key: string): number
	local total = 0
	if not profile or not profile.Upgrades then return 0 end
	for _, id in profile.Upgrades do
		local def = Config.getUpgradeDef(id)
		if def and def.effect and def.effect[key] then
			total += def.effect[key]
		end
	end
	return total
end

-- Same, but looked up by userId (used by NPCs for casino owners).
function Upgrades.effectForUser(userId: number, key: string): number
	local player = Players:GetPlayerByUserId(userId)
	if not player then return 0 end
	return Upgrades.effect(Data.get(player), key)
end

function Upgrades.buy(player: Player, id: string)
	local def = Config.getUpgradeDef(id)
	if not def then return { ok = false, message = "Unknown upgrade." } end
	local profile = Data.get(player)
	if not profile then return { ok = false, message = "Profile not loaded." } end
	if Upgrades.has(profile, id) then
		return { ok = false, message = "Already purchased." }
	end
	if Economy.getCash(player) < def.cost then
		return { ok = false, message = "Not enough " .. Config.CurrencyName .. "." }
	end
	if not Economy.tryWithdraw(player, def.cost) then
		return { ok = false, message = "Purchase failed." }
	end
	table.insert(profile.Upgrades, id)
	return { ok = true, message = "Purchased " .. def.name .. "." }
end

function Upgrades.start(deps)
	Economy = deps.Economy
	Data = deps.Data
end

return Upgrades
