--- Process runner behind the `execute_command` tool.
---
--- Spawns through `jobstart`, which makes every job the leader of its own
--- process group, and reassembles output into lines as described in
--- `:h channel-lines`. Memory use is bounded per stream: only a head and a
--- tail of the output are kept, while the full output is streamed to a log
--- file in the spill directory. A job is stopped by signalling its whole
--- process group along an escalation ladder that always ends in SIGKILL.
local spill = require("mcphub.utils.spill")

local M = {}

--- Bytes of output kept in memory per stream, split evenly between head and
--- tail.
M.DEFAULT_CAPTURE_BYTES = 4 * 1024 * 1024

---@alias MCPHub.Exec.KillStep { [1]: string, [2]: integer } Signal name and grace period in ms

--- Soft signals sent before the final SIGKILL.
---@type MCPHub.Exec.KillStep[]
M.DEFAULT_KILL_LADDER = { { "sigint", 2000 }, { "sigterm", 3000 } }

local SOFT_SIGNALS = { sigint = true, sigterm = true, sighup = true }
local MIN_GRACE_MS, MAX_GRACE_MS, MAX_TOTAL_GRACE_MS = 100, 10000, 30000

--- Check a user-supplied ladder. SIGKILL is rejected because the ladder
--- always ends with it anyway, and the bounds keep a misconfigured ladder from
--- delaying that kill indefinitely.
---@param ladder any
---@return boolean ok
---@return string? err
function M.validate_ladder(ladder)
    if type(ladder) ~= "table" or not vim.islist(ladder) then
        return false, "kill_ladder must be a list of { signal, grace_ms } steps"
    end
    local total = 0
    for i, step in ipairs(ladder) do
        if type(step) ~= "table" then
            return false, ("kill_ladder[%d] must be { signal, grace_ms }"):format(i)
        end
        local sig, grace = step[1], step[2]
        if type(sig) ~= "string" or not SOFT_SIGNALS[sig:lower()] then
            return false,
                ("kill_ladder[%d]: %s is not one of sigint, sigterm, sighup (sigkill always ends the ladder)"):format(
                    i,
                    vim.inspect(sig)
                )
        end
        if type(grace) ~= "number" or grace < MIN_GRACE_MS or grace > MAX_GRACE_MS then
            return false,
                ("kill_ladder[%d]: grace %s is not within [%d, %d] ms"):format(
                    i,
                    vim.inspect(grace),
                    MIN_GRACE_MS,
                    MAX_GRACE_MS
                )
        end
        total = total + grace
    end
    if total > MAX_TOTAL_GRACE_MS then
        return false, ("kill_ladder: graces sum to %d ms, more than %d ms"):format(total, MAX_TOTAL_GRACE_MS)
    end
    return true
end

---@class MCPHub.Exec.Capture
---@field half integer Byte budget of the head and of the tail; also the longest line kept
---@field prefix string Prepended to every line in the log
---@field head string[]
---@field head_bytes integer
---@field head_full boolean Once set, every later line goes to the tail
---@field tail table<integer, string> Ring of lines `tail[tail_first..tail_last]`
---@field tail_first integer
---@field tail_last integer
---@field tail_bytes integer
---@field partial string Kept start of the line still being received
---@field spilled boolean The line in flight outgrew `half` and streams straight to the log
---@field cut integer Bytes of the line in flight not kept in memory
---@field bytes integer Bytes received, newlines included
---@field line_count integer Lines received
---@field elided_lines integer Lines dropped between head and tail
---@field cut_lines integer Lines kept only in part
---@field log_buf string[] Log output not yet written
local Capture = {}
Capture.__index = Capture

---@param opts? { capture_bytes?: integer, prefix?: string }
---@return MCPHub.Exec.Capture
function Capture.new(opts)
    opts = opts or {}
    return setmetatable({
        half = math.max(1, math.floor((opts.capture_bytes or M.DEFAULT_CAPTURE_BYTES) / 2)),
        prefix = opts.prefix or "",
        head = {},
        head_bytes = 0,
        head_full = false,
        tail = {},
        tail_first = 1,
        tail_last = 0,
        tail_bytes = 0,
        partial = "",
        spilled = false,
        cut = 0,
        bytes = 0,
        line_count = 0,
        elided_lines = 0,
        cut_lines = 0,
        log_buf = {},
    }, Capture)
end

---@param s string
function Capture:_log(s)
    if s ~= "" then
        self.log_buf[#self.log_buf + 1] = s
    end
end

--- Keep a completed line in the head while it has room, else in the tail ring.
---@param line string
function Capture:_keep(line)
    local size = #line + 1
    if not self.head_full and self.head_bytes + size <= self.half then
        self.head[#self.head + 1] = line
        self.head_bytes = self.head_bytes + size
        return
    end
    self.head_full = true
    self.tail_last = self.tail_last + 1
    self.tail[self.tail_last] = line
    self.tail_bytes = self.tail_bytes + size
    while self.tail_bytes > self.half and self.tail_first < self.tail_last do
        local old = self.tail[self.tail_first]
        self.tail[self.tail_first] = nil
        self.tail_first = self.tail_first + 1
        self.tail_bytes = self.tail_bytes - #old - 1
        self.elided_lines = self.elided_lines + 1
    end
end

--- Extend the line in flight. Its first `half` bytes stay in memory; once it
--- grows past that, everything received so far goes to the log and the rest
--- of the line follows it there directly.
---@param s string
function Capture:_append(s)
    if s == "" then
        return
    end
    if self.spilled then
        self:_log(s)
        self.cut = self.cut + #s
        return
    end
    local room = self.half - #self.partial
    if #s <= room then
        self.partial = self.partial == "" and s or self.partial .. s
        return
    end
    self:_log(self.prefix)
    self:_log(self.partial)
    self:_log(s)
    self.partial = self.partial .. s:sub(1, room)
    self.cut = #s - room
    self.spilled = true
end

function Capture:_close()
    local line = self.partial
    if self.spilled then
        self:_log("\n")
        line = ("%s…[+%d bytes]"):format(line, self.cut)
        self.cut_lines = self.cut_lines + 1
        self.spilled = false
        self.cut = 0
    else
        self:_log(self.prefix)
        self:_log(line)
        self:_log("\n")
    end
    self.partial = ""
    self.line_count = self.line_count + 1
    self:_keep(line)
end

--- Feed one `on_stdout`/`on_stderr` payload. The first item continues the
--- previous partial line and every later item starts a new one, so each item
--- after the first closes the line before it. EOF arrives as `{ "" }`, which
--- this handles without a special case.
---@param data string[]?
function Capture:feed(data)
    if not data or #data == 0 then
        return
    end
    local bytes = #data - 1
    for i = 1, #data do
        bytes = bytes + #data[i]
    end
    self.bytes = self.bytes + bytes
    self:_append(data[1])
    for i = 2, #data do
        self:_close()
        self:_append(data[i])
    end
end

--- Keep output whose last line has no trailing newline.
function Capture:finish()
    if self.partial ~= "" or self.spilled then
        self:_close()
    end
end

--- Hand over the log output accumulated since the last call.
---@return string[]
function Capture:take_log()
    local buf = self.log_buf
    self.log_buf = {}
    return buf
end

---@return boolean
function Capture:is_empty()
    return self.line_count == 0 and self.partial == "" and not self.spilled
end

--- Whether anything received is missing from `text()`.
---@return boolean
function Capture:truncated()
    return self.elided_lines > 0 or self.cut_lines > 0
end

--- The lines kept in memory: the head, then the tail.
---@return string[]
function Capture:lines()
    local out = vim.list_extend({}, self.head)
    for i = self.tail_first, self.tail_last do
        out[#out + 1] = self.tail[i]
    end
    return out
end

--- Kept lines, each terminated by a newline, with a marker where lines were
--- dropped between head and tail.
---@param log_path? string Named in the marker
---@return string
function Capture:text(log_path)
    local out = vim.list_extend({}, self.head)
    if self.elided_lines > 0 then
        out[#out + 1] = ("[… %d lines elided — %s]"):format(
            self.elided_lines,
            log_path and ("full log: " .. log_path) or "no log was written"
        )
    end
    for i = self.tail_first, self.tail_last do
        out[#out + 1] = self.tail[i]
    end
    if #out == 0 then
        return ""
    end
    return table.concat(out, "\n") .. "\n"
end

M.Capture = Capture

---@class MCPHub.Exec.Stats
---@field out_bytes integer Bytes received on stdout and stderr
---@field out_lines integer Lines received on stdout and stderr
---@field last_output_at? integer `vim.uv.now()` when output last arrived

---@class MCPHub.Exec.Job
---@field id integer `jobstart` id
---@field pid integer Process id; also the process-group id
---@field command string
---@field cwd string
---@field started_at integer `vim.uv.now()` at spawn
---@field ended_at? integer `vim.uv.now()` at exit
---@field exited boolean
---@field exit_code? integer
---@field stdout MCPHub.Exec.Capture
---@field stderr MCPHub.Exec.Capture
---@field log_path? string Full output; stderr lines prefixed `[stderr] `. Absent if the file could not be opened.
---@field stats MCPHub.Exec.Stats
---@field kill_ladder? MCPHub.Exec.KillStep[] Validated when `terminate` first runs
---@field terminating boolean `terminate` has run
---@field reason? MCPHub.Exec.TerminateReason Why `terminate` ran
---@field last_signal? string Last signal sent to the process group

---@alias MCPHub.Exec.TerminateReason "timeout" | "cancelled" | "stopped" | "memory"

---@class MCPHub.Exec.Opts
---@field command string Shell command line
---@field cwd string Absolute working directory
---@field capture_bytes? integer Output kept in memory per stream
---@field kill_ladder? MCPHub.Exec.KillStep[] Soft steps of `terminate`; an invalid ladder falls back to the default
---@field on_exit? fun(job: MCPHub.Exec.Job) Called once, after all output has been captured

--- Running jobs by `jobstart` id.
---@type table<integer, MCPHub.Exec.Job>
M.jobs = {}

--- The argv `jobstart(command)` would use, built explicitly so it can later be
--- wrapped.
---@param command string
---@return string[]
function M.build_argv(command)
    local argv = vim.split(vim.o.shell, "%s+", { trimempty = true })
    vim.list_extend(argv, vim.split(vim.o.shellcmdflag, "%s+", { trimempty = true }))
    table.insert(argv, command)
    return argv
end

---@param id integer
---@return MCPHub.Exec.Job?
function M.get(id)
    return M.jobs[id]
end

--- Open the job's log. Without one the job still runs; the result then says
--- that no full log exists.
---@return string? path
---@return integer? fd
local function open_log()
    local path = spill.new_path("execute_command", "log")
    if not path then
        return nil, nil
    end
    local fd = vim.uv.fs_open(path, "a", 420)
    if not fd then
        return nil, nil
    end
    return path, fd
end

---@class MCPHub.Exec.Job
local Job = {}
Job.__index = Job

--- Whether any process is left in the job's process group. The leader
--- exiting doesn't settle that: a non-interactive shell starts background
--- commands with SIGINT ignored, so they outlive a SIGINT that ends the shell.
---@return boolean
function Job:_group_alive()
    return vim.uv.kill(-self.pid, 0) == 0
end

--- Stop the job by walking the kill ladder over its process group: each soft
--- signal, then its grace period, then SIGKILL. The walk stops as soon as the
--- group is empty. Calling this again, or after the job exited, does nothing.
---@param reason MCPHub.Exec.TerminateReason
function Job:terminate(reason)
    if self.terminating or self.exited then
        return
    end
    self.terminating = true
    self.reason = reason

    local ladder = self.kill_ladder or M.DEFAULT_KILL_LADDER
    local ok, err = M.validate_ladder(ladder)
    if not ok then
        vim.notify("mcphub: invalid execute_command kill_ladder, using the default: " .. err, vim.log.levels.ERROR)
        ladder = M.DEFAULT_KILL_LADDER
    end
    local steps = {}
    for _, step in ipairs(ladder) do
        steps[#steps + 1] = { step[1]:lower(), step[2] }
    end
    steps[#steps + 1] = { "sigkill" }

    local function send(i)
        if not self:_group_alive() then
            return
        end
        local sig, grace = steps[i][1], steps[i][2]
        pcall(vim.uv.kill, -self.pid, sig)
        self.last_signal = sig
        if steps[i + 1] then
            vim.defer_fn(function()
                send(i + 1)
            end, grace)
        end
    end
    send(1)
end

M.Job = Job

---@param opts MCPHub.Exec.Opts
---@return MCPHub.Exec.Job? job
---@return string? err
function M.start(opts)
    local log_path, fd = open_log()
    ---@type MCPHub.Exec.Job
    local job = setmetatable({
        id = 0,
        pid = 0,
        command = opts.command,
        cwd = opts.cwd,
        started_at = vim.uv.now(),
        exited = false,
        kill_ladder = opts.kill_ladder,
        terminating = false,
        stdout = Capture.new({ capture_bytes = opts.capture_bytes }),
        stderr = Capture.new({ capture_bytes = opts.capture_bytes, prefix = "[stderr] " }),
        log_path = log_path,
        stats = { out_bytes = 0, out_lines = 0 },
    }, Job)

    local function flush()
        for _, capture in ipairs({ job.stdout, job.stderr }) do
            local buf = capture:take_log()
            if fd and #buf > 0 then
                vim.uv.fs_write(fd, buf)
            end
        end
        job.stats.out_bytes = job.stdout.bytes + job.stderr.bytes
        job.stats.out_lines = job.stdout.line_count + job.stderr.line_count
    end

    ---@param capture MCPHub.Exec.Capture
    ---@param data string[]
    local function on_output(capture, data)
        capture:feed(data)
        if not (#data == 1 and data[1] == "") then
            job.stats.last_output_at = vim.uv.now()
        end
        flush()
    end

    local function close_log()
        if fd then
            vim.uv.fs_close(fd)
            fd = nil
        end
    end

    -- Neovim runs `on_exit` only after both output streams have closed, so the
    -- captures are complete by the time it fires.
    local ok, id = pcall(vim.fn.jobstart, M.build_argv(opts.command), {
        cwd = opts.cwd,
        on_stdout = function(_, data)
            on_output(job.stdout, data)
        end,
        on_stderr = function(_, data)
            on_output(job.stderr, data)
        end,
        on_exit = function(_, code)
            job.stdout:finish()
            job.stderr:finish()
            flush()
            close_log()
            job.exit_code = code
            job.ended_at = vim.uv.now()
            job.exited = true
            M.jobs[job.id] = nil
            if opts.on_exit then
                opts.on_exit(job)
            end
        end,
    })

    local err
    if not ok then
        err = tostring(id)
    elseif id == 0 then
        err = "Invalid arguments for jobstart"
    elseif id == -1 then
        err = "Command is not executable"
    end
    if err then
        close_log()
        if log_path then
            vim.uv.fs_unlink(log_path)
        end
        return nil, err
    end

    job.id = id
    job.pid = vim.fn.jobpid(id)
    M.jobs[id] = job
    return job
end

return M
