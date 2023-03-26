local M = {}

function M.notify(level, ...)
	vim.notify(table.concat({ ... }, " "), level, {
		title = "http",
	})
end

for k, v in pairs(vim.log.levels) do
	M[k:lower()] = function(...)
		M.notify(v, ...)
	end
end

return M
