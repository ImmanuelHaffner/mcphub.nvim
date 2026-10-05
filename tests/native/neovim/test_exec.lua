-- Tests for mcphub.native.neovim.utils.exec, the process runner behind
-- `execute_command`.
--
-- Run with `make test`, or just this file with
-- `make test_file FILE=tests/native/neovim/test_exec.lua`.
local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality
local exec = require("mcphub.native.neovim.utils.exec")

--- Run `command` in /tmp and wait for it to exit.
---@param command string
---@return MCPHub.Exec.Job
local function run(command)
    local done
    local job, err = exec.start({
        command = command,
        cwd = "/tmp",
        on_exit = function(j)
            done = j
        end,
    })
    assert(job, err)
    assert(
        vim.wait(10000, function()
            return done ~= nil
        end, 10),
        "command did not exit: " .. command
    )
    return done
end

local T = new_set()

T["capture"] = new_set()

T["capture"]["keeps blank lines"] = function()
    eq(run([[printf 'one\n\nthree\n']]).stdout.lines, { "one", "", "three" })
end

T["capture"]["does not split a line longer than one read"] = function()
    -- One read is 64-128 KiB depending on the platform, so 200,000 bytes
    -- reliably spans several chunks.
    local lines = run([[head -c 200000 /dev/zero | tr '\0' x; echo]]).stdout.lines
    eq(#lines, 1)
    eq(#lines[1], 200000)
end

T["capture"]["keeps output without a trailing newline"] = function()
    eq(run("printf tail").stdout.lines, { "tail" })
end

T["capture"]["captures stderr separately"] = function()
    local job = run("echo out; echo err >&2")
    eq(job.stdout.lines, { "out" })
    eq(job.stderr.lines, { "err" })
end

T["lifecycle"] = new_set()

T["lifecycle"]["reports the exit code"] = function()
    local job = run("exit 3")
    eq(job.exit_code, 3)
    eq(job.exited, true)
    eq(exec.get(job.id), nil)
end

return T
