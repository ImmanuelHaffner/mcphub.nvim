-- Tests for MCPHub:get_servers — capability filtering and native-server resolution.
--
-- Run with `make test`, or just this file with
-- `make test_file FILE=tests/test_hub_get_servers.lua`.
local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality
local helpers = require("tests.helpers")

local State = require("mcphub.state")

local CONFIG_SOURCE = "/test/servers.json"

local saved

--- A connected native server with one tool, read from `config_source` (cached, so nothing touches disk).
---@param tool table
---@param disabled_tools? string[]
local function install_native_server(tool, disabled_tools)
    State.config_files_cache = {
        [CONFIG_SOURCE] = {
            mcpServers = {},
            nativeMCPServers = { native = { disabled_tools = disabled_tools or {} } },
        },
    }
    State.server_state.servers = {}
    State.server_state.native_servers = {
        {
            name = "native",
            status = "connected",
            is_native = true,
            config_source = CONFIG_SOURCE,
            description = "a native server",
            capabilities = { tools = { tool }, resources = {}, resourceTemplates = {}, prompts = {} },
        },
    }
end

local T = new_set({
    hooks = {
        pre_case = function()
            saved = {
                cache = State.config_files_cache,
                servers = State.server_state.servers,
                native_servers = State.server_state.native_servers,
            }
        end,
        post_case = function()
            State.config_files_cache = saved.cache
            State.server_state.servers = saved.servers
            State.server_state.native_servers = saved.native_servers
        end,
    },
})

T["native servers"] = new_set()

T["native servers"]["resolve function-valued description and inputSchema"] = function()
    local hub = helpers.setup_plugin()
    install_native_server({
        name = "dyn",
        description = function()
            return "dynamic"
        end,
        inputSchema = function()
            return { type = "object", properties = { n = { type = "number" } }, required = { "n" } }
        end,
        handler = function() end,
    })

    local tool = hub:get_servers()[1].capabilities.tools[1]
    eq(tool.description, "dynamic")
    eq(tool.inputSchema, { type = "object", properties = { n = { type = "number" } }, required = { "n" } })
    eq(tool.handler, nil)
end

T["native servers"]["empty properties from a function schema encode as an object"] = function()
    local hub = helpers.setup_plugin()
    install_native_server({
        name = "empty",
        description = "no params",
        inputSchema = function()
            return { type = "object", properties = {} }
        end,
    })

    local schema = hub:get_servers()[1].capabilities.tools[1].inputSchema
    eq(vim.json.encode(schema.properties), "{}")
end

T["native servers"]["disabled tools are filtered out"] = function()
    local hub = helpers.setup_plugin()
    install_native_server({ name = "off", description = "x", inputSchema = { type = "object", properties = {} } }, {
        "off",
    })

    eq(hub:get_servers()[1].capabilities.tools, {})
end

return T
