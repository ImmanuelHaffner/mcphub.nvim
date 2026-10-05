-- Tests for mcphub.native.neovim.utils.exec, the process runner behind
-- `execute_command`.
--
-- Run with `make test`, or just this file with
-- `make test_file FILE=tests/native/neovim/test_exec.lua`.
local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality
local exec = require("mcphub.native.neovim.utils.exec")
local spill = require("mcphub.utils.spill")

local MiB = 1024 * 1024
-- BSD `seq` formats with `%g`, so a bare `seq 1 2000000` ends in `2e+06`, twice.
local SEQ_2M = "seq -f %.0f 1 2000000"

--- Run `command` in /tmp and wait for it to exit.
---@param command string
---@param opts? { capture_bytes?: integer }
---@return MCPHub.Exec.Job
local function run(command, opts)
    local done
    local job, err = exec.start({
        command = command,
        cwd = "/tmp",
        capture_bytes = opts and opts.capture_bytes,
        on_exit = function(j)
            done = j
        end,
    })
    assert(job, err)
    assert(
        vim.wait(60000, function()
            return done ~= nil
        end, 10),
        "command did not exit: " .. command
    )
    return done
end

---@param s string
---@param needle string
local function contains(s, needle)
    return s:find(needle, 1, true) ~= nil
end

local real_dir = spill.DIR

local T = new_set({
    hooks = {
        -- Every job writes a log, so keep them out of the real spill dir.
        pre_case = function()
            spill.DIR = vim.fn.tempname()
        end,
        post_case = function()
            vim.fn.delete(spill.DIR, "rf")
            spill.DIR = real_dir
        end,
    },
})

T["capture"] = new_set()

T["capture"]["keeps blank lines"] = function()
    eq(run([[printf 'one\n\nthree\n']]).stdout:lines(), { "one", "", "three" })
end

T["capture"]["does not split a line longer than one read"] = function()
    -- One read is 64-128 KiB depending on the platform, so 200,000 bytes
    -- reliably spans several chunks.
    local lines = run([[head -c 200000 /dev/zero | tr '\0' x; echo]]).stdout:lines()
    eq(#lines, 1)
    eq(#lines[1], 200000)
end

T["capture"]["keeps output without a trailing newline"] = function()
    eq(run("printf tail").stdout:lines(), { "tail" })
end

T["capture"]["captures stderr separately"] = function()
    local job = run("echo out; echo err >&2")
    eq(job.stdout:lines(), { "out" })
    eq(job.stderr:lines(), { "err" })
end

T["bounds"] = new_set()

T["bounds"]["keeps memory bounded"] = function()
    -- 100-byte lines: the bound is about bytes, and short lines would only
    -- make the test slow.
    local job = run([[yes "$(printf '%099d' 0)" | head -c 50000000]], { capture_bytes = MiB })
    eq(#job.stdout:text(job.log_path) < 1.1 * MiB, true)
    eq(job.stats.out_bytes, 50000000)
    eq(job.stats.out_lines, 500000)
end

T["bounds"]["keeps memory bounded for a line without newlines"] = function()
    local job = run([[head -c 5000000 /dev/zero | tr '\0' x]], { capture_bytes = MiB })
    local lines = job.stdout:lines()
    eq(#lines, 1)
    eq(#lines[1] < 0.6 * MiB, true)
    eq(vim.endswith(lines[1], ("…[+%d bytes]"):format(5000000 - MiB / 2)), true)
    eq(job.stdout:truncated(), true)
    -- The log gets the whole line, plus the newline closing it.
    eq(vim.uv.fs_stat(job.log_path).size, 5000001)
end

T["bounds"]["keeps head and tail"] = function()
    local job = run(SEQ_2M, { capture_bytes = MiB })
    local lines = job.stdout:lines()
    eq(lines[1], "1")
    eq(lines[#lines], "2000000")
    eq(job.stdout:truncated(), true)
    eq(contains(job.stdout:text(job.log_path), "lines elided — full log: " .. job.log_path), true)
    eq(job.stats.out_lines, 2000000)
end

T["bounds"]["leaves small output alone"] = function()
    local job = run("echo hi")
    eq(job.stdout:truncated(), false)
    eq(job.stdout:text(job.log_path), "hi\n")
end

T["log"] = new_set()

T["log"]["holds the complete output"] = function()
    local job = run(SEQ_2M, { capture_bytes = MiB })
    local lines = vim.fn.readfile(job.log_path)
    eq(#lines, 2000000)
    eq(lines[#lines], "2000000")
end

T["log"]["prefixes stderr lines"] = function()
    local job = run("echo out; echo err >&2")
    local lines = vim.fn.readfile(job.log_path)
    table.sort(lines)
    eq(lines, { "[stderr] err", "out" })
end

T["log"]["is named for the spill GC"] = function()
    local job = run("true")
    eq(vim.fn.fnamemodify(job.log_path, ":h"), spill.DIR)
    eq(vim.fn.fnamemodify(job.log_path, ":t"):match(spill._FILE_PATTERN) ~= nil, true)
    eq(vim.fn.fnamemodify(job.log_path, ":e"), "log")
end

T["lifecycle"] = new_set()

T["lifecycle"]["reports the exit code"] = function()
    local job = run("exit 3")
    eq(job.exit_code, 3)
    eq(job.exited, true)
    eq(exec.get(job.id), nil)
end

return T
