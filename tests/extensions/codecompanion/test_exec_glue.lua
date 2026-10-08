-- Tests for the CodeCompanion glue in mcphub.extensions.codecompanion.{tools,core}:
-- the tool label, and what reaches hub:call_tool after the approval gate.
--
-- Run with `make test`, or just this file with
-- `make test_file FILE=tests/extensions/codecompanion/test_exec_glue.lua`.
local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local State = require("mcphub.state")
local core = require("mcphub.extensions.codecompanion.core")
local exec_command = require("mcphub.native.neovim.exec_command")
local exec_ui = require("mcphub.extensions.codecompanion.exec_ui")
local mcphub = require("mcphub")
local native = require("mcphub.native")
local shared = require("mcphub.extensions.shared")
local tools = require("mcphub.extensions.codecompanion.tools")

local real = {}

--- The arguments and caller of every `hub:call_tool`.
---@type { arguments: table, caller: table }[]
local called

--- CodeCompanion isn't on the test runtimepath; these stand in for the modules
--- `tools.lua` requires from it.
local FAKE_MODULES = {
    codecompanion = {
        has = function()
            return true
        end,
    },
    ["codecompanion.config"] = { interactions = { chat = { tools = { groups = {} } } } },
}

--- An output callback, and a function that waits until it has been called.
---@return fun() output_cb
---@return fun() wait
local function waiter()
    local done
    return function()
        done = true
    end, function()
        assert(vim.wait(1000, function()
            return done
        end, 10))
    end
end

--- Run `execute_command` through `core.execute_mcp_tool` and wait for its output handler.
---@param tool_input table
local function execute(tool_input)
    local output_cb, wait = waiter()
    core.execute_mcp_tool(
        { server_name = "neovim", tool_name = "execute_command", tool_input = tool_input },
        {},
        output_cb,
        ---@diagnostic disable-next-line: missing-fields
        { action = "use_mcp_tool" }
    )
    wait()
end

--- Run a CodeCompanion tool's cmd the way its runner does, with `register_job`.
---@param tool table What the tool's `callback()` returns
---@param action table The LLM's arguments
---@return function register_job The function passed in `cmd_opts`
local function run_cmd(tool, action)
    local output_cb, wait = waiter()
    local register_job = function() end
    tool.cmds[1]({}, action, { output_cb = output_cb, register_job = register_job })
    wait()
    return register_job
end

local T = new_set({
    hooks = {
        pre_case = function()
            real.is_native_server = native.is_native_server
            real.is_auto_approved_in_server = shared.is_auto_approved_in_server
            real.show_mcp_tool_prompt = shared.show_mcp_tool_prompt
            real.get_hub_instance = mcphub.get_hub_instance
            real.attach = exec_ui.attach
            real.builtin_tools = State.config.builtin_tools
            real.modules = {}
            for name, module in pairs(FAKE_MODULES) do
                real.modules[name] = package.loaded[name] or false
                package.loaded[name] = vim.deepcopy(module)
            end
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
                    get_servers = function()
                        return { { name = "neovim", capabilities = { tools = { exec_command.definition } } } }
                    end,
                    call_tool = function(_, _, _, arguments, opts)
                        table.insert(called, { arguments = arguments, caller = opts.caller })
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
            exec_ui.attach = real.attach
            State.config.builtin_tools = real.builtin_tools
            for name, module in pairs(real.modules) do
                package.loaded[name] = module or nil
            end
        end,
    },
})

T["call_tool"] = new_set()

T["call_tool"]["receives the clamped arguments"] = function()
    shared.show_mcp_tool_prompt = function()
        return false, false, { id = "clamp" }
    end
    execute({ command = "sleep 5", cwd = "/tmp", timeout = 1200 })
    eq(#called, 1)
    eq(called[1].arguments, { command = "sleep 5", cwd = "/tmp", timeout = 600, _clamped_from = 1200 })
end

T["call_tool"]["receives the original arguments otherwise"] = function()
    execute({ command = "ls", cwd = "/tmp", timeout = 60 })
    eq(#called, 1)
    eq(called[1].arguments, { command = "ls", cwd = "/tmp", timeout = 60 })
end

T["register_job"] = new_set()

T["register_job"]["reaches the caller from use_mcp_tool"] = function()
    local tool = tools.create_static_tools({}).use_mcp_tool.callback()
    local register_job = run_cmd(
        tool,
        { server_name = "neovim", tool_name = "execute_command", tool_input = { command = "ls", cwd = "/tmp" } }
    )
    eq(#called, 1)
    eq(called[1].caller.register_job, register_job)
end

T["register_job"]["reaches the caller from an individual tool"] = function()
    tools.register({})
    local config = package.loaded["codecompanion.config"]
    local tool = config.interactions.chat.tools["neovim__execute_command"].callback()
    local register_job = run_cmd(tool, { command = "ls", cwd = "/tmp" })
    eq(#called, 1)
    eq(called[1].caller.register_job, register_job)
end

T["on_job"] = new_set()

T["on_job"]["hands the job to the chat's progress line"] = function()
    local attached = {}
    exec_ui.attach = function(_, job)
        table.insert(attached, job)
    end
    execute({ command = "ls", cwd = "/tmp" })
    eq(#called, 1)
    local job = { id = 1 }
    called[1].caller.on_job(job)
    eq(#attached, 1)
    eq(attached[1] == job, true)
end

T["cmd_string"] = new_set()

T["cmd_string"]["labels an individual tool with its command"] = function()
    tools.register({})
    local config = package.loaded["codecompanion.config"]
    local tool = config.interactions.chat.tools["neovim__execute_command"].callback()
    eq(tool.output.cmd_string({ args = { command = "ls -la", cwd = "/tmp" } }), "$ ls -la")
end

T["cmd_string"]["labels use_mcp_tool with the command it runs"] = function()
    local tool = tools.create_static_tools({}).use_mcp_tool.callback()
    local input = { command = "pwd", cwd = "/tmp" }
    local args = { server_name = "neovim", tool_name = "execute_command", tool_input = input }
    eq(tool.output.cmd_string({ args = args }), "$ pwd")
    args.tool_input = vim.json.encode(input)
    eq(tool.output.cmd_string({ args = args }), "$ pwd")
end

T["cmd_string"]["is nil for a tool without a label"] = function()
    native.is_native_server = function(name)
        return name == "neovim" and { capabilities = { tools = { { name = "plain" } } } } or nil
    end
    local output = core.create_output_handlers(
        "neovim__plain",
        true,
        {},
        { server_name = "neovim", tool_name = "plain" }
    )
    eq(output.cmd_string({ args = {} }), nil)
end

T["error output"] = new_set()

T["error output"]["ends on its closing fence"] = function()
    local written
    local chat = {
        add_tool_output = function(_, _, for_llm, for_user)
            written = { for_llm, for_user }
        end,
    }
    local output = core.create_output_handlers("neovim__execute_command", true, {})
    output.error({}, { "Timed out after 1 s" }, { tools = { chat = chat } })
    -- A trailing blank line would join CodeCompanion's fold over the output and
    -- take the separator before the next tool, with its progress line, along.
    eq(written[1], written[2])
    eq(written[1]:match("Timed out after 1 s\n`+$") ~= nil, true)
end

return T
