local util = require("http.util")

--- @class ResponseHeaders: { [integer]: IndexedResponseHeaderValue, [string]: HeaderValue }
local H = {}

--- Gets the first value of a header, or nil.
--- @param name string the name of the header to get.
--- @return string|nil value the header value
function H:get(name)
	local result = self[name]
	if result then
		return result[1]
	end
	return nil
end

--- Gets the value of a header, concatenating values with ';', or nil.
--- @param name string the name of the header to get.
--- @return string|nil value the header value
function H:concat(name)
	local result = self[name]
	if result then
		return table.concat(result, "; ")
	end
	return nil
end

--- @enum methods
local METHODS = {
	OPTIONS = "OPTIONS",
	GET = "GET",
	POST = "POST",
	PUT = "PUT",
	DELETE = "DELETE",
	HEAD = "HEAD",
	TRACE = "TRACE",
	CONNECT = "CONNECT",
	PATCH = "PATCH",
}

--- @enum versions
local VERSIONS = {
	HTTP_09 = 0,
	HTTP_10 = 1,
	HTTP_11 = 2,
	HTTP_20 = 3,
	HTTP_30 = 4,
}

local M = {}

--- @class IndexedResponseHeaderValue
--- @field name string The name of the header
--- @field value string The value of the header

--- @class HeaderValue: { [integer]: string }

--- @class Response
--- @field code integer the response status code
--- @field status string the response status string
--- @field url string the final response URL
--- @field version versions the HTTP version used
--- @field content_length integer|nil the number of bytes
--- @field headers ResponseHeaders the response headers
--- @field remote_addr string|nil the remote endpoint

--- @class StringResponse : Response
--- @fieldbody string

--- @alias RequestCallback fun(err: string, result: string)

--- @class Request
--- @field [1] methods method to use
--- @field [2] string the URL
--- @field headers { [string]: HeaderValue | string } headers? the request headers
--- @field timeout float the timeout in seconds
--- @field version versions the HTTP version to use

--- @class StringRequest : Request
--- @field [3] string|nil the request body
--- @field callback fun(err: nil, result: StringResponse)|fun(err: string, result: nil) the callback function

local function build_headers(resp)
	local result = {}
	for i, v in ipairs(resp:get_header_iter()) do
		result[i] = {
			name = v[1],
			value = v[2],
		}

		if not result[v[1]] then
			result[v[1]] = {}
		end
		table.insert(result[v[1]], v[2])
	end
	return setmetatable(result, H)
end

local function build_response(resp)
	local values = {
		code = resp.code,
		status = resp.status,
		url = resp.url,
		version = resp.version,
		content_length = resp.content_length,
		headers = build_headers(resp),
		remote_addr = resp.remote_addr,
	}

	return values
end

--- Sends a request to the server
--- @param request StringRequest
function M.string_request(request)
	local lib = require("http.lib")
	local headers = {}

	if request.headers then
		for k, v in request.headers do
			if type(v) == "string" then
				headers[k] = { v }
			elseif type(v) == "table" then
				headers[k] = v
			end
		end
	end

	lib.string_request(function(err, resp)
		if err then
			request.callback(err)
			return
		end
		local r = build_response(resp)
		r.body = resp.body
		request.callback(nil, r)
	end, request[1], request[2], headers, request[3], request.timeout, request.version)
end

M.methods = util.freeze(METHODS)
M.versions = util.freeze(VERSIONS)
M.supported = false

function M:__index(index)
	if index == "supported" then
		return require("http.lib").supported
	else
		return rawget(self, index)
	end
end

return util.freeze(M)
