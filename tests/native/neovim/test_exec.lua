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

--- Start `command` in /tmp without waiting for it.
---@param command string
---@param opts? { capture_bytes?: integer, kill_ladder?: MCPHub.Exec.KillStep[], timeout_ms?: integer }
---@return MCPHub.Exec.Job job
---@return fun(): MCPHub.Exec.Job? exited The job once `on_exit` has run
local function spawn(command, opts)
    local done
    local job, err = exec.start({
        command = command,
        cwd = "/tmp",
        capture_bytes = opts and opts.capture_bytes,
        kill_ladder = opts and opts.kill_ladder,
        timeout_ms = opts and opts.timeout_ms,
        on_exit = function(j)
            done = j
        end,
    })
    assert(job, err)
    return job, function()
        return done
    end
end

--- Run `command` in /tmp and wait for it to exit.
---@param command string
---@param opts? { capture_bytes?: integer, timeout_ms?: integer }
---@return MCPHub.Exec.Job
local function run(command, opts)
    local _, exited = spawn(command, opts)
    assert(
        vim.wait(60000, function()
            return exited() ~= nil
        end, 10),
        "command did not exit: " .. command
    )
    return assert(exited())
end

--- Wait until the job printed its first line, which the commands below do
--- once their traps are installed and their children are running.
---@param job MCPHub.Exec.Job
local function wait_ready(job)
    assert(
        vim.wait(5000, function()
            return job.stdout.line_count > 0
        end, 10),
        "command never became ready: " .. job.command
    )
end

---@param pattern string
---@return boolean
local function pgrep(pattern)
    -- An argv list, so no shell whose own command line would match.
    vim.fn.system({ "pgrep", "-f", pattern })
    return vim.v.shell_error == 0
end

---@type MCPHub.Exec.KillStep[]
local SHORT_LADDER = { { "sigint", 200 }, { "sigterm", 200 } }

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
            for _, job in pairs(exec.jobs) do
                pcall(vim.uv.kill, -job.pid, "sigkill")
            end
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

T["lifecycle"]["terminates the job when its timeout fires"] = function()
    local job = run("sleep 100", { timeout_ms = 200 })
    eq(job.reason, "timeout")
    eq(job.last_signal, "sigint")
    eq(job.ended_at - job.started_at < 1000, true)
end

T["lifecycle"]["cancels the timeout when the job exits first"] = function()
    local job = run("true", { timeout_ms = 200 })
    eq(job._timer, nil)
    vim.wait(300)
    eq(job.reason, nil)
end

T["terminate"] = new_set()

T["terminate"]["ends a cooperative process with SIGINT"] = function()
    local job, exited =
        spawn([[trap 'kill $!; exit 0' INT; sleep 100 & echo ready; wait]], { kill_ladder = SHORT_LADDER })
    wait_ready(job)
    local t0 = vim.uv.now()
    job:terminate("cancelled")
    eq(
        vim.wait(300, function()
            return exited() ~= nil
        end, 10),
        true
    )
    eq(job.exit_code, 0)
    eq(job.reason, "cancelled")
    eq(job.last_signal, "sigint")
    eq(vim.uv.now() - t0 < 300, true)
    -- The group emptied, so the ladder stopped there.
    vim.wait(300)
    eq(job.last_signal, "sigint")
end

T["terminate"]["escalates to SIGKILL"] = function()
    local job, exited = spawn([[trap '' INT TERM; echo ready; sleep 100]], { kill_ladder = SHORT_LADDER })
    wait_ready(job)
    job:terminate("timeout")
    eq(
        vim.wait(700, function()
            return exited() ~= nil
        end, 10),
        true
    )
    eq(job.last_signal, "sigkill")
end

T["terminate"]["kills the whole process group"] = function()
    local job, exited = spawn([[echo ready; sleep 101 | cat]], { kill_ladder = SHORT_LADDER })
    wait_ready(job)
    eq(pgrep("sleep 101"), true)
    job:terminate("stopped")
    vim.wait(1000, function()
        return exited() ~= nil
    end, 10)
    eq(pgrep("sleep 101"), false)
end

T["terminate"]["keeps escalating while the group outlives the leader"] = function()
    -- A non-interactive shell starts `sleep &` with SIGINT ignored, so SIGINT
    -- ends the shell and leaves the sleep running.
    local job, exited = spawn([[trap 'exit 0' INT; sleep 102 & echo ready; wait]], { kill_ladder = SHORT_LADDER })
    wait_ready(job)
    job:terminate("cancelled")
    eq(
        vim.wait(300, function()
            return exited() ~= nil
        end, 10),
        true
    )
    eq(
        vim.wait(700, function()
            return not pgrep("sleep 102")
        end, 50),
        true
    )
    eq(job.last_signal, "sigterm")
end

T["terminate"]["is idempotent"] = function()
    local job, exited = spawn([[trap '' INT TERM; echo ready; sleep 100]], { kill_ladder = SHORT_LADDER })
    wait_ready(job)
    local seen = {}
    local function observe()
        if job.last_signal and seen[#seen] ~= job.last_signal then
            seen[#seen + 1] = job.last_signal
        end
        return exited() ~= nil
    end
    local t0 = vim.uv.now()
    job:terminate("timeout")
    vim.wait(100, observe, 5)
    job:terminate("cancelled")
    eq(vim.wait(1000, observe, 5), true)
    eq(seen, { "sigint", "sigterm", "sigkill" })
    eq(job.reason, "timeout")
    -- A restarted ladder would take at least 100 + 400 ms.
    eq(vim.uv.now() - t0 < 500, true)
end

T["terminate"]["falls back to the default ladder when the configured one is invalid"] = function()
    local default, notify = exec.DEFAULT_KILL_LADDER, vim.notify
    local notified
    exec.DEFAULT_KILL_LADDER = { { "sigint", 100 } }
    vim.notify = function(msg, level)
        notified = { msg, level }
    end
    local ok, err = pcall(function()
        local job, exited = spawn([[trap '' INT TERM; echo ready; sleep 100]], { kill_ladder = { { "sigkill", 100 } } })
        wait_ready(job)
        job:terminate("timeout")
        eq(
            vim.wait(1000, function()
                return exited() ~= nil
            end, 10),
            true
        )
        eq(job.last_signal, "sigkill")
    end)
    exec.DEFAULT_KILL_LADDER, vim.notify = default, notify
    assert(ok, err)
    eq(notified[2], vim.log.levels.ERROR)
    eq(contains(notified[1], "sigkill"), true)
end

T["validate_ladder"] = new_set()

T["validate_ladder"]["accepts the default and any case"] = function()
    eq(exec.validate_ladder(exec.DEFAULT_KILL_LADDER), true)
    eq(exec.validate_ladder({ { "SIGHUP", 100 } }), true)
    eq(exec.validate_ladder({}), true)
end

T["validate_ladder"]["rejects SIGKILL"] = function()
    local ok, err = exec.validate_ladder({ { "sigkill", 100 } })
    eq(ok, false)
    eq(contains(assert(err), "sigkill"), true)
end

T["validate_ladder"]["bounds each grace"] = function()
    eq(exec.validate_ladder({ { "sigint", 99 } }), false)
    eq(exec.validate_ladder({ { "sigint", 10001 } }), false)
    eq(exec.validate_ladder({ { "sigint" } }), false)
end

T["validate_ladder"]["caps the total grace"] = function()
    eq(exec.validate_ladder({ { "sigint", 10000 }, { "sigterm", 10000 }, { "sighup", 10000 } }), true)
    eq(exec.validate_ladder({ { "sigint", 10000 }, { "sigterm", 10000 }, { "sighup", 10001 } }), false)
    local ok, err =
        exec.validate_ladder({ { "sigint", 10000 }, { "sigterm", 10000 }, { "sighup", 10000 }, { "sigint", 100 } })
    eq(ok, false)
    eq(contains(assert(err), "30000"), true)
end

T["validate_ladder"]["rejects malformed ladders"] = function()
    eq(exec.validate_ladder("sigint"), false)
    eq(exec.validate_ladder({ sigint = 100 }), false)
    eq(exec.validate_ladder({ "sigint" }), false)
end

return T
