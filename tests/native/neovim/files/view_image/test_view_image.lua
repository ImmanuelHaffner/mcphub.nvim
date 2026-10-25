-- Tests for mcphub.native.neovim.files.view_image, the `view_image` tool:
-- its registration behind `builtin_tools.view_image.enabled`, and its handler.
--
-- Run with `make test`, or just this file with
-- `make test_file FILE=tests/native/neovim/files/view_image/test_view_image.lua`.
local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local NativeServer = require("mcphub.native.utils.server")
local State = require("mcphub.state")
local mcphub = require("mcphub")
local view_image = require("mcphub.native.neovim.files.view_image")

local FILES_MODULE = "mcphub.native.neovim.files"

--- Names of the tools `files/init.lua` registers with the `neovim` server when
--- loaded afresh under `builtin_tools`.
---@param builtin_tools table?
---@return string[]
local function registered_tools(builtin_tools)
    local real_add_tool, real_add_resource = mcphub.add_tool, mcphub.add_resource
    local real_builtin_tools = State.config.builtin_tools
    local names = {}
    mcphub.add_tool = function(server, tool)
        if server == "neovim" then
            table.insert(names, tool.name)
        end
    end
    mcphub.add_resource = function() end
    State.config.builtin_tools = builtin_tools
    package.loaded[FILES_MODULE] = nil

    local ok, err = pcall(require, FILES_MODULE)

    package.loaded[FILES_MODULE] = nil
    mcphub.add_tool, mcphub.add_resource = real_add_tool, real_add_resource
    State.config.builtin_tools = real_builtin_tools
    assert(ok, err)
    return names
end

--- Call `view_image` through a native server that serves only it.
---@param arguments table
---@return { content: MCPContent[], isError?: boolean }? result
---@return string? err
local function call(arguments)
    ---@diagnostic disable-next-line: missing-fields
    local server = setmetatable(
        { name = "fake", status = "connected", capabilities = { tools = { view_image.definition } } },
        NativeServer
    )
    local response, err, done
    server:call_tool("view_image", arguments, {
        callback = function(r, e)
            response, err, done = r, e, true
        end,
    })
    assert(vim.wait(1000, function()
        return done
    end, 10))
    return response and response.result, err
end

local T = new_set()

T["registration"] = new_set()

T["registration"]["is absent by default"] = function()
    local names = registered_tools(nil)
    eq(vim.tbl_contains(names, "view_image"), false)
    -- Guards against a vacuous pass: the module did register its other tools
    eq(vim.tbl_contains(names, "write_file"), true)
end

T["registration"]["is absent when disabled explicitly"] = function()
    eq(vim.tbl_contains(registered_tools({ view_image = { enabled = false } }), "view_image"), false)
end

T["registration"]["is present when enabled"] = function()
    eq(vim.tbl_contains(registered_tools({ view_image = { enabled = true } }), "view_image"), true)
end

T["registration"]["defaults to disabled in the config"] = function()
    local defaults = require("mcphub.config").setup({})
    eq(defaults.builtin_tools.view_image, { enabled = false })
end

T["definition"] = new_set()

T["definition"]["declares one required path"] = function()
    local def = view_image.definition
    eq(def.name, "view_image")
    eq(def.call_noun, "image")
    eq(def.inputSchema.required, { "path" })
    eq(def.inputSchema.properties.path.type, "string")
end

T["definition"]["labels a call with its path"] = function()
    eq(view_image.definition.label({ path = "a/b.png" }), "a/b.png")
    eq(view_image.definition.label({ path = "" }), nil)
    eq(view_image.definition.label({}), nil)
end

T["handler"] = new_set()

T["handler"]["reports that it is not implemented"] = function()
    local result, err = call({ path = "a.png" })
    local text = (result and result.content and result.content[1] and result.content[1].text) or err or ""
    eq(result and result.isError, true)
    eq(text:find("not implemented", 1, true) ~= nil, true)
end

return T
