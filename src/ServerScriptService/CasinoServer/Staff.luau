--!nonstrict
-- Staff.luau — hiring persists in profile.Staff = { [staffId] = true }.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Common = ReplicatedStorage:WaitForChild("CasinoCommon")
local Config = require(Common:WaitForChild("Config"))

local Staff = {}
local Economy, Data

function Staff.hire(player: Player, staffId: string)
	local def = Config.getStaffDef(staffId)
	if not def then return { ok = false, message = "Unknown staff." } end
	local p = Data.get(player)
	if not p then return { ok = false, message = "Data not ready." } end
	if p.Staff[staffId] then return { ok = false, message = "Already hired." } end
	if not Economy.tryWithdraw(player, def.cost) then
		return { ok = false, message = "Not enough " .. Config.CurrencyName .. "." }
	end
	p.Staff[staffId] = true
	return { ok = true, message = "Hired " .. def.name .. "!" }
end

-- Extra house edge (fraction of bet) from hired staff. Takes the owner Player.
function Staff.getHouseBonus(ownerPlayer: Player): number
	local p = Data.get(ownerPlayer)
	if not p then return 0 end
	local bonus = 0
	for staffId in p.Staff do
		local def = Config.getStaffDef(staffId)
		if def then bonus += def.houseEdgeBonus end
	end
	return bonus
end

function Staff.start(deps)
	Economy = deps.Economy
	Data = deps.Data
end

return Staff
