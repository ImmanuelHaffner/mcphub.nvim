-- Tests for the CodeCompanion glue in mcphub.extensions.codecompanion.core:
-- what reaches hub:call_tool after the approval gate.
--
-- Run with `make test`, or just this file with
-- `make test_file FILE=tests/extensions/codecompanion/test_exec_glue.lua`.
local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local State = require("mcphub.state")
local core = require("mcphub.extensions.codecompanion.core")
local exec_command = require("mcphub.native.neovim.exec_command")
local mcphub = require("mcphub")
local native = require("mcphub.native")
local shared = require("mcphub.extensions.shared")

local real = {}

--- The arguments every `hub:call_tool` received.
---@type table[]
local called

--- Run `execute_command` through the glue and wait for its output handler.
---@param tool_input table
local function execute(tool_input)
    local done
    core.execute_mcp_tool(
        { server_name = "neovim", tool_name = "execute_command", tool_input = tool_input },
        {},
        function()
            done = true
        end,
        { action = "use_mcp_tool" }
    )
    assert(vim.wait(1000, function()
        return done
    end, 10))
end

local T = new_set({
    hooks = {
        pre_case = function()
            real.is_native_server = native.is_native_server
            real.is_auto_approved_in_server = shared.is_auto_approved_in_server
            real.show_mcp_tool_prompt = shared.show_mcp_tool_prompt
            real.get_hub_instance = mcphub.get_hub_instance
            real.builtin_tools = State.config.builtin_tools
            State.config.builtin_tools = nil
            called = {}
            native.is_native_server = function(name)
                return name == "neovim" and { capabilities = { tools = { exec_command.definition } } } or nil
            end
            shared.is_auto_approved_in_server = function()
                return true
            end
            mcphub.get_hub_instance = function()
                return {
                    call_tool = function(_, _, _, arguments, opts)
                        table.insert(called, arguments)
                        opts.callback(nil, "not run")
                    end,
                }
            end
        end,
        post_case = function()
            native.is_native_server = real.is_native_server
            shared.is_auto_approved_in_server = real.is_auto_approved_in_server
            shared.show_mcp_tool_prompt = real.show_mcp_tool_prompt
            mcphub.get_hub_instance = real.get_hub_instance
            State.config.builtin_tools = real.builtin_tools
        end,
    },
})

T["call_tool"] = new_set()

T["call_tool"]["receives the clamped arguments"] = function()
    shared.show_mcp_tool_prompt = function()
        return false, false, { id = "clamp" }
    end
    execute({ command = "sleep 5", cwd = "/tmp", timeout = 1200 })
    eq(called, { { command = "sleep 5", cwd = "/tmp", timeout = 600, _clamped_from = 1200 } })
end

T["call_tool"]["receives the original arguments otherwise"] = function()
    execute({ command = "ls", cwd = "/tmp", timeout = 60 })
    eq(called, { { command = "ls", cwd = "/tmp", timeout = 60 } })
end

return T
