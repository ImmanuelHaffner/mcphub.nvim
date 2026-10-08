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

--- Start the handler; the returned function waits for its response.
---@param params table
---@param caller? table Defaults to an empty caller
---@return fun(): { content: MCPContent[], isError?: boolean } wait
local function start(params, caller)
    local result
    local res = ToolResponse:new(function(r)
        result = r.result
    end)
    ---@diagnostic disable-next-line: missing-fields, param-type-mismatch
    exec_command.handler({ params = params, caller = caller or {} }, res)
    return function()
        assert(
            vim.wait(10000, function()
                return result ~= nil
            end, 10),
            "handler did not respond"
        )
        return result
    end
end

--- Call the handler and wait for its response.
---@param params table
---@param caller? table
---@return { content: MCPContent[], isError?: boolean }
local function call(params, caller)
    return start(params, caller)()
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

T["memory"] = new_set()

T["memory"]["reports a command killed over the memory limit"] = function()
    State.config.builtin_tools = {
        execute_command = { memory_limit = 64 * 1024 * 1024, kill_ladder = { { "sigint", 200 } } },
    }
    -- Repeating a byte writes every page; `bytearray(n)` would leave them untouched.
    local result = call({
        command = [[echo before; python3 -c "x = b'\x01' * (256 * 2**20); import time; time.sleep(30)"]],
        cwd = "/tmp",
    })
    local text = result.content[1].text
    eq(result.isError, true)
    eq(text:match("^Killed: memory use %d+ MiB exceeded the 64 MiB limit %(SIGINT%)%.\n") ~= nil, true)
    eq(text:find("Output:\n\nbefore\n", 1, true) ~= nil, true)
end

T["stop"] = new_set()

T["stop"]["the registered handle stops the command through the ladder"] = function()
    local handle
    local wait = start({ command = "sleep 107", cwd = "/tmp" }, {
        register_job = function(h)
            handle = h
        end,
    })
    local _, job = next(exec.jobs)
    eq(type(handle and handle.kill), "function")

    handle:kill("sigterm")
    eq(wait().isError, nil)
    eq(job.reason, "stopped")
    eq(job.last_signal, "sigint")
    eq(
        vim.wait(3000, function()
            return vim.fn.system({ "pgrep", "-f", "sleep 107" }) == ""
        end, 50),
        true
    )
end

T["stop"]["a caller without register_job runs normally"] = function()
    local result = call({ command = "echo hi", cwd = "/tmp" }, { type = "avante" })
    eq(result.isError, nil)
    eq(result.content[1].text:find("Output:\n\nhi\n", 1, true) ~= nil, true)
end

T["on_job"] = new_set()

T["on_job"]["receives the running job"] = function()
    local seen
    local wait = start({ command = "sleep 0.2", cwd = "/tmp" }, {
        on_job = function(job)
            seen = job
        end,
    })
    local _, job = next(exec.jobs)
    eq(seen ~= nil and seen == job, true)
    eq(seen.exited, false)
    eq(wait().isError, nil)
end

T["on_job"]["a failing on_job does not fail the command"] = function()
    local result = call({ command = "echo hi", cwd = "/tmp" }, {
        on_job = function()
            error("boom")
        end,
    })
    eq(result.isError, nil)
end

T["cancel"] = new_set()

T["cancel"]["reports the cancellation with the partial output"] = function()
    local wait = start({ command = "echo before; sleep 100", cwd = "/tmp" })
    local _, job = next(exec.jobs)
    assert(vim.wait(2000, function()
        return job.stats.out_lines > 0
    end, 10))
    job:terminate("cancelled")
    local result = wait()
    eq(result.isError, true)
    local text = result.content[1].text
    local log_path =
        text:match("^Cancelled by the user after 0 s %(SIGINT%)%. Partial output %(1 line, full log at (%S+)%):\n")
    eq(log_path, job.log_path)
    eq(text:find("Output:\n\nbefore\n", 1, true) ~= nil, true)
end

T["definition"] = new_set()

T["definition"]["renders the description and schema from the config"] = function()
    State.config.builtin_tools = {
        execute_command = {
            timeout_default = 45,
            timeout_soft_limit = 300,
            capture_bytes = 1024 * 1024,
            kill_ladder = { { "sigterm", 1000 } },
            memory_limit = 512 * 1024 * 1024,
        },
    }
    local description = prompt_utils.get_description(exec_command.definition)
    eq(description:find("Default: 45. Values up to 300 run without asking", 1, true) ~= nil, true)
    eq(description:find("receives SIGTERM, then SIGKILL;", 1, true) ~= nil, true)
    eq(description:find("larger than 1 MiB per stream", 1, true) ~= nil, true)
    eq(
        description:find(
            "- Commands run at reduced CPU priority and are terminated if their memory use exceeds 512 MiB.",
            1,
            true
        ) ~= nil,
        true
    )
    eq(description:find("nice -n", 1, true), nil)
    local schema = prompt_utils.get_inputSchema(exec_command.definition)
    eq(schema.properties.timeout.type, "number")
    eq(schema.properties.timeout.description:find("Default: 45. Up to 300", 1, true) ~= nil, true)
    eq(vim.tbl_contains(schema.required, "timeout"), false)
end

T["definition"]["omits the priority sentence when nice is off"] = function()
    State.config.builtin_tools = { execute_command = { nice = false, memory_limit = 3 * 1024 * 1024 * 1024 / 2 } }
    local description = prompt_utils.get_description(exec_command.definition)
    eq(description:find("reduced CPU priority", 1, true), nil)
    eq(description:find("- Commands are terminated if their memory use exceeds 1.5 GiB.", 1, true) ~= nil, true)

    State.config.builtin_tools = { execute_command = { nice = false, memory_limit = false } }
    eq(prompt_utils.get_description(exec_command.definition):find("terminated if their memory", 1, true), nil)
end

T["definition"]["omits the memory clause without a limit"] = function()
    State.config.builtin_tools = { execute_command = { memory_limit = false } }
    local description = prompt_utils.get_description(exec_command.definition)
    eq(description:find("- Commands run at reduced CPU priority.", 1, true) ~= nil, true)
    eq(description:find("memory use", 1, true), nil)
end

T["definition"]["labels the call with the command on one line"] = function()
    eq(exec_command.label({ command = "a\nb" }), "$ a ⏎ b")
    eq(
        exec_command.label({ command = "  for f in *;\n\tdo  echo $f;\r\ndone\n" }),
        "$ for f in *; ⏎ do echo $f; ⏎ done"
    )
    local label = exec_command.label({ command = ("ä"):rep(300) })
    eq(vim.fn.strdisplaywidth(label), 122)
    eq(vim.endswith(label, "ä…"), true)
end

T["definition"]["keeps the verbatim command for the folded block"] = function()
    local command = "cat <<EOF\n  hi\nEOF"
    eq(exec_command.label_block({ command = command }), { lang = "sh", text = command })
end

return T
