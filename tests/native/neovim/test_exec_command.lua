-- Tests for mcphub.native.neovim.exec_command, the `execute_command` tool
-- definition, driven through its handler with a real ToolResponse.
--
-- Run with `make test`, or just this file with
-- `make test_file FILE=tests/native/neovim/test_exec_command.lua`.
local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality
local ToolResponse = require("mcphub.native.utils.response").ToolResponse
local State = require("mcphub.state")
local exec_command = require("mcphub.native.neovim.exec_command")
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

return T
