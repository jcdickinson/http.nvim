# http.nvim

A HTTP client for your neovim plugin needs.

## Contributing

Feel free to create an issue/PR if you want to see anything else implemented.

## Installation

### [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
    "jcdickinson/http.nvim",
    run = "cargo build --workspace --release"
}
```

### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
    "jcdickinson/http.nvim",
    build = "cargo build --workspace --release"
},
```

## API

### request

This send a request to the HTTP endpoint that contains an optional string body,
and returns a string body.

```lua
local http = require("http")

http.request({
  http.methods.POST,
  "https://www.example.com",
  "The message body", -- optional
  "/path/to/download/to", -- optional, will suppress `body` in the response
  headers = { -- optional
    ["content-type"] = "text/plain",
    ["multi"] = { "multiple", "values" }
  },
  timeout = 10.0, -- optional, in seconds
  version = http.versions.HTTP20 -- optional, in seconds
  callback = function(err, response)
    if err then
        -- an error occurred
        return
    end
    if response.code < 400 then
        -- a success status code
    else
        -- a failure status code
    end

    -- this will need be scheduled onto the main loop
    vim.schedule(function()
        vim.print({
            response.status, -- the status text
            response.url, -- the final URL that was queried
            response.version, -- the HTTP version used
            response.content_length, -- optional, the content length
            response.remote_addr, -- optional, the remote address
        })

        -- Headers:
        -- Headers may appear multiple times, this is preserved

        for _, v in ipairs(response.headers) do
            -- the same header may appear multiple times
            vim.print({
                v.name,
                v.value
            })
        end

        for k, v in pairs(response.headers) do
            if type(v) == "table" then
                for _, v in ipairs(v) do
                    vim.print({
                        k,
                        v
                    })
                end
            end
        end

        vim.print({
            response.headers.get('content-type'), -- first header value
            response.headers.concat('content-type') -- header values concatenated with ';'
        })
    end)
  end
})
```
