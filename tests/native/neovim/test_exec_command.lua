-- Tests for mcphub.native.neovim.exec_command, the `execute_command` tool
-- definition, driven through its handler with a real ToolResponse.
--
-- Run with `make test`, or just this file with
-- `make test_file FILE=tests/native/neovim/test_exec_command.lua`.
local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality
local ToolResponse = require("mcphub.native.utils.response").ToolResponse
local State = require("mcphub.state")
local exec = require("mcphub.native.neovim.utils.exec")
local exec_command = require("mcphub.native.neovim.exec_command")
local prompt_utils = require("mcphub.utils.prompt")
local spill = require("mcphub.utils.spill")

--- Call the handler and wait for its response.
---@param params table
---@return { content: MCPContent[], isError?: boolean }
local function call(params)
    local result
    local res = ToolResponse:new(function(r)
        result = r.result
    end)
    ---@diagnostic disable-next-line: missing-fields, param-type-mismatch
    exec_command.handler({ params = params, caller = {} }, res)
    assert(
        vim.wait(10000, function()
            return result ~= nil
        end, 10),
        "handler did not respond"
    )
    return result
end

local real_dir = spill.DIR
local real_builtin_tools = State.config.builtin_tools

local T = new_set({
    hooks = {
        pre_case = function()
            spill.DIR = vim.fn.tempname()
        end,
        post_case = function()
            vim.fn.delete(spill.DIR, "rf")
            spill.DIR = real_dir
            State.config.builtin_tools = real_builtin_tools
        end,
    },
})

T["handler"] = new_set()

T["handler"]["rejects a missing directory"] = function()
    local result = call({ command = "true", cwd = "/nonexistent/mcphub-test" })
    eq(result.isError, true)
    eq(vim.startswith(result.content[1].text, "Directory does not exist:"), true)
end

T["handler"]["keeps the result format"] = function()
    local result = call({ command = "echo hi", cwd = "/tmp" })
    eq(result.isError, nil)
    eq(result.content[1].text, "Command: echo hi\nWorking Directory: /tmp\nExit Code: 0\nOutput:\n\nhi\n")
end

T["handler"]["points at the log when output was elided"] = function()
    State.config.builtin_tools = { execute_command = { capture_bytes = 1000 } }
    local text = call({ command = "seq 1 1000", cwd = "/tmp" }).content[1].text
    local log_path = text:match("\nFull log: (%S+)\n$")
    eq(type(log_path), "string")
    eq(text:find("lines elided — full log: " .. log_path, 1, true) ~= nil, true)
    eq(#vim.fn.readfile(log_path), 1000)
end

T["handler"]["omits the log for small output"] = function()
    local text = call({ command = "echo hi", cwd = "/tmp" }).content[1].text
    eq(text:find("Full log:", 1, true), nil)
end

T["timeout"] = new_set()

T["timeout"]["applies the default"] = function()
    State.config.builtin_tools = { execute_command = { timeout_default = 1 } }
    local started = vim.uv.now()
    local result = call({ command = "sleep 100", cwd = "/tmp" })
    eq(result.isError, true)
    eq(vim.startswith(result.content[1].text, "Timed out after 1 s and was terminated (SIGINT)"), true)
    eq(vim.uv.now() - started < 3000, true)
end

T["timeout"]["lets a command finish within the requested timeout"] = function()
    State.config.builtin_tools = { execute_command = { timeout_default = 1 } }
    local result = call({ command = "sleep 1.5", cwd = "/tmp", timeout = 3 })
    eq(result.isError, nil)
    eq(result.content[1].text:find("Exit Code: 0\n", 1, true) ~= nil, true)
end

T["timeout"]["rejects invalid values without spawning"] = function()
    for _, value in ipairs({ -1, "10", 0 / 0 }) do
        local result = call({ command = "true", cwd = "/tmp", timeout = value })
        eq(result.isError, true)
        eq(vim.startswith(result.content[1].text, "timeout must be a non-negative number"), true)
    end
    eq(next(exec.jobs), nil)
end

-- The handler trusts its caller here: NativeServer:call_tool has already
-- refused exemptions the user did not confirm (tests/extensions/test_shared.lua).
T["timeout"]["0 runs without a timer"] = function()
    State.config.builtin_tools = { execute_command = { timeout_default = 1 } }
    local result = call({ command = "sleep 2; echo done", cwd = "/tmp", timeout = 0 })
    eq(result.isError, nil)
    eq(result.content[1].text:find("Exit Code: 0\n", 1, true) ~= nil, true)
end

T["timeout"]["clamps a confirmed huge timeout"] = function()
    for _, value in ipairs({ 1e300, math.huge }) do
        local result = call({ command = "true", cwd = "/tmp", timeout = value })
        eq(result.isError, nil)
    end
end

T["timeout"]["confirm_if names exemptions only"] = function()
    eq(exec_command.confirm_if({ timeout = 0 }), "no timeout requested (timeout = 0)")
    eq(exec_command.confirm_if({ timeout = 601 }), "timeout 601 s exceeds the 600 s soft limit")
    for _, args in ipairs({ {}, { timeout = 600 }, { timeout = "0" }, { timeout = -1 } }) do
        eq(exec_command.confirm_if(args), nil)
    end
end

T["timeout"]["reports a clamp by the user"] = function()
    local text = call({ command = "echo hi", cwd = "/tmp", timeout = 600, _clamped_from = 1800 }).content[1].text
    eq(
        text,
        "Ran with `timeout = 600` s; the user clamped it from 1800 s.\nCommand: echo hi\nWorking Directory: /tmp\nExit Code: 0\nOutput:\n\nhi\n"
    )

    text = call({ command = "true", cwd = "/tmp", timeout = 600, _clamped_from = 0 }).content[1].text
    eq(vim.startswith(text, "Ran with `timeout = 600` s; the user clamped it from `timeout = 0` (no timeout).\n"), true)

    text = call({ command = "true", cwd = "/tmp", timeout = 600 }).content[1].text
    eq(text:find("clamped", 1, true), nil)
end

T["timeout"]["keeps the output captured so far"] = function()
    local result = call({ command = "echo before; sleep 100", cwd = "/tmp", timeout = 1 })
    eq(result.isError, true)
    eq(result.content[1].text:find("Output:\n\nbefore\n", 1, true) ~= nil, true)
end

T["definition"] = new_set()

T["definition"]["renders the description and schema from the config"] = function()
    State.config.builtin_tools = {
        execute_command = {
            timeout_default = 45,
            timeout_soft_limit = 300,
            capture_bytes = 1024 * 1024,
            kill_ladder = { { "sigterm", 1000 } },
        },
    }
    local description = prompt_utils.get_description(exec_command.definition)
    eq(description:find("Default: 45. Values up to 300 run without asking", 1, true) ~= nil, true)
    eq(description:find("receives SIGTERM, then SIGKILL;", 1, true) ~= nil, true)
    eq(description:find("larger than 1 MiB per stream", 1, true) ~= nil, true)
    local schema = prompt_utils.get_inputSchema(exec_command.definition)
    eq(schema.properties.timeout.type, "number")
    eq(schema.properties.timeout.description:find("Default: 45. Up to 300", 1, true) ~= nil, true)
    eq(vim.tbl_contains(schema.required, "timeout"), false)
end

return T
