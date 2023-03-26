local M = {}

--- @generic T
--- @param table `T`
--- @return `T`
function M.freeze(table)
	table.__index = table
	table.__newindex = function()
		error("table is read-only")
	end
	return setmetatable({}, table)
end

return M
