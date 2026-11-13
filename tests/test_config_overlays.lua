-- Tests for `config_overlays`: extra config files the hub reads after the global one.
--
-- Run with `make test`, or just this file with
-- `make test_file FILE=tests/test_config_overlays.lua`.
local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality
local helpers = require("tests.helpers")

local State = require("mcphub.state")
local config_manager = require("mcphub.utils.config_manager")

local GLOBAL = vim.fn.fnamemodify("tests/servers.json", ":p")

local tmpdir

--- @param name string
--- @return string
local function tmp(name)
    return tmpdir .. "/" .. name
end

--- @param path string
--- @return string|nil
local function slurp(path)
    local file = io.open(path, "r")
    if not file then
        return nil
    end
    local content = file:read("*a")
    file:close()
    return content
end

--- @param path string
--- @param value table
local function write_json(path, value)
    vim.fn.writefile({ vim.json.encode(value) }, path)
end

--- @param path string
--- @return table
local function read_json(path)
    return vim.json.decode(slurp(path))
end

local saved

local T = new_set({
    hooks = {
        pre_case = function()
            tmpdir = vim.fn.tempname()
            vim.fn.mkdir(tmpdir, "p")
        end,
        post_case = function()
            vim.fn.delete(tmpdir, "rf")
            State.current_hub = nil
            State.config_files_cache = nil
        end,
    },
})

T["context"] = new_set()

T["context"]["has only the global config by default"] = function()
    local hub = helpers.setup_plugin()
    eq(hub:_resolve_global_context().config_files, { GLOBAL })
end

T["context"]["lists overlays after the global config, in order"] = function()
    local hub = helpers.setup_plugin({
        config_overlays = { tmp("a.json"), { path = tmp("b.json"), ephemeral = true } },
    })
    eq(hub:_resolve_global_context().config_files, { GLOBAL, tmp("a.json"), tmp("b.json") })
end

T["context"]["expands and normalises overlay paths"] = function()
    local hub = helpers.setup_plugin({ config_overlays = { "~/x//y.json" } })
    eq(hub:_config_overlays()[1].path, vim.fs.normalize(vim.fn.expand("~/x/y.json")))
end

T["context"]["keeps overlay flags"] = function()
    local hub = helpers.setup_plugin({ config_overlays = { { path = tmp("b.json"), ephemeral = true } } })
    eq(hub:_config_overlays(), { { path = tmp("b.json"), ephemeral = true } })
end

T["context"]["skips invalid entries"] = function()
    local hub = helpers.setup_plugin({ config_overlays = { "", { ephemeral = true }, 42, tmp("a.json") } })
    eq(hub:_resolve_global_context().config_files, { GLOBAL, tmp("a.json") })
end

T["args"] = new_set()

T["args"]["pass every config file in order"] = function()
    local hub = helpers.setup_plugin({ config_overlays = { tmp("a.json"), tmp("b.json") } })
    local args = hub:_build_cmd_args(hub:_resolve_global_context())

    local configs = {}
    for i, arg in ipairs(args) do
        if arg == "--config" then
            table.insert(configs, args[i + 1])
        end
    end
    eq(configs, { GLOBAL, tmp("a.json"), tmp("b.json") })
    eq(vim.tbl_contains(args, "--watch"), true)
end

T["files"] = new_set()

T["files"]["a missing overlay is created on refresh"] = function()
    helpers.setup_plugin()
    local overlay = tmp("sub/overlay.json")
    State.current_hub = { config_files = { GLOBAL, overlay } }

    eq(config_manager.refresh_config(), true)
    eq(vim.json.decode(slurp(overlay)), { mcpServers = {} })
end

T["files"]["an existing overlay is left untouched on refresh"] = function()
    helpers.setup_plugin()
    local overlay = tmp("overlay.json")
    local content = '{"mcpServers": {"x": {"command": "true"}}}'
    vim.fn.writefile({ content }, overlay)
    State.current_hub = { config_files = { GLOBAL, overlay } }

    eq(config_manager.refresh_config(), true)
    eq(slurp(overlay), content .. "\n")
    eq(State.config_files_cache[overlay].mcpServers.x.command, "true")
end

T["sources"] = new_set({
    hooks = {
        pre_case = function()
            saved = {
                config = State.config,
                servers = State.server_state.servers,
                native_servers = State.server_state.native_servers,
            }
            write_json(tmp("global.json"), {
                mcpServers = { g = { command = "true" }, both = { command = "global" } },
            })
            write_json(tmp("overlay.json"), {
                mcpServers = { x = { command = "true", disabled = true }, both = { command = "overlay" } },
            })
            State.config = { config = tmp("global.json") }
            State.server_state.servers = {}
            State.server_state.native_servers = {}
            State.current_hub = { config_files = { tmp("global.json"), tmp("overlay.json") } }
            config_manager.refresh_config()
        end,
        post_case = function()
            State.config = saved.config
            State.server_state.servers = saved.servers
            State.server_state.native_servers = saved.native_servers
        end,
    },
})

T["sources"]["an overlay-only name is written to the overlay"] = function()
    local global = slurp(tmp("global.json"))
    eq(config_manager.update_server_config("x", { disabled = false }), true)
    eq(read_json(tmp("overlay.json")).mcpServers.x, { command = "true", disabled = false })
    eq(slurp(tmp("global.json")), global)
end

T["sources"]["an unknown name is written to the global config"] = function()
    local overlay = slurp(tmp("overlay.json"))
    eq(config_manager.update_server_config("new", { command = "true" }), true)
    eq(read_json(tmp("global.json")).mcpServers.new, { command = "true" })
    eq(slurp(tmp("overlay.json")), overlay)
end

T["sources"]["a name in both files resolves to the later one"] = function()
    eq(config_manager.get_config_source("both"), tmp("overlay.json"))
    eq(config_manager.get_server_config("both").command, "overlay")
end

T["sources"]["an explicit config_source wins"] = function()
    eq(config_manager.update_server_config("x", { command = "true" }, { config_source = tmp("global.json") }), true)
    eq(read_json(tmp("global.json")).mcpServers.x, { command = "true" })
    eq(read_json(tmp("overlay.json")).mcpServers.x.disabled, true)
end

T["sources"]["get_server_config finds an overlay-only entry"] = function()
    eq(config_manager.get_server_config("x"), { command = "true", disabled = true })
    eq(config_manager.get_server_config("missing"), nil)
end

T["sources"]["starting an overlay-only server enables it in the overlay"] = function()
    local hub = helpers.setup_plugin()
    local global = slurp(tmp("global.json"))
    hub:start_mcp_server("x")
    eq(read_json(tmp("overlay.json")).mcpServers.x.disabled, false)
    eq(slurp(tmp("global.json")), global)
end

return T
