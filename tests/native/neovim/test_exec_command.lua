-- Tests for mcphub.native.neovim.exec_command, the `execute_command` tool
-- definition, driven through its handler with a real ToolResponse.
--
-- Run with `make test`, or just this file with
-- `make test_file FILE=tests/native/neovim/test_exec_command.lua`.
local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality
local ToolResponse = require("mcphub.native.utils.response").ToolResponse
local exec_command = require("mcphub.native.neovim.exec_command")

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

local T = new_set()

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

return T
