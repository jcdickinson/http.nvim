local function get_current_dir()
	local filepath = debug.getinfo(1, "S").source:sub(2)
	return vim.fn.fnamemodify(filepath, ":p:h:h:h")
end

local root_dir = get_current_dir()

local function add_pattern(pattern)
	for _, ext in ipairs({ ".so", ".dll", ".dylib" }) do
		local filepath = root_dir .. pattern .. ext
		if not string.find(package.cpath, filepath, 1, true) then
			package.cpath = filepath .. ";" .. package.cpath
		end
	end
end

add_pattern("/target/debug/?")
add_pattern("/target/release/?")

local function load_module()
	local mod_ok, mod = pcall(require, "libhttp_nvim")

	if not mod_ok then
		local err = table.concat({ "libhttp_nvim not loaded", vim.inspect(mod) }, " ")
		require("http.notify").error(err)
		mod = { supported = false }
		function mod.get_recv_fd()
			return nil, err
		end
		function mod.string_request(...)
			local a = { ... }
			a[1](err)
		end
		return mod
	end

	local function create_pipe()
		local result_ready, err = vim.loop.new_pipe(false)
		if not result_ready then
			local result = {}
			function result:read_start(cb)
				cb(err or "failed to create pipe")
			end
			return result
		end

		local recv_fd, fd_err = mod.get_recv_fd()
		if not recv_fd then
			local result = {}
			function result:read_start(cb)
				cb(fd_err or "failed to get receiver fd")
				result_ready:close()
			end
			return result
		end

		result_ready:open(recv_fd)
		return result_ready
	end

	local pipe = create_pipe()
	local function recv(err)
		if err then
			require("http.notify").error("read pipe crashed", err)
			if pipe and pipe.close then
				pipe:close()
			end
			return
		end

		local ok, cb = pcall(mod.recv)
		if ok then
			cb()
		else
			require("http.notify").error("recv failed", cb)
			pipe:close()
		end
	end
	pipe:read_start(recv)

	mod.supported = true
	return mod
end
local mod = load_module()

local M = {}

M.supported = mod.supported
M.string_request = mod.string_request
M.download_request = mod.string_request

return require("http.util").freeze(M)
