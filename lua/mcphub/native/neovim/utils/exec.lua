--- Process runner behind the `execute_command` tool.
---
--- Spawns through `jobstart`, which makes every job the leader of its own
--- process group, and reassembles output into lines as described in
--- `:h channel-lines`.
local M = {}

---@class MCPHub.Exec.Capture
---@field lines string[] Completed lines
---@field partial string The line still being received
local Capture = {}
Capture.__index = Capture

---@return MCPHub.Exec.Capture
function Capture.new()
    return setmetatable({ lines = {}, partial = "" }, Capture)
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
    self.partial = self.partial .. data[1]
    for i = 2, #data do
        table.insert(self.lines, self.partial)
        self.partial = data[i]
    end
end

--- Keep output whose last line has no trailing newline.
function Capture:finish()
    if self.partial ~= "" then
        table.insert(self.lines, self.partial)
        self.partial = ""
    end
end

---@return boolean
function Capture:is_empty()
    return #self.lines == 0 and self.partial == ""
end

--- Captured lines, each terminated by a newline.
---@return string
function Capture:text()
    if #self.lines == 0 then
        return ""
    end
    return table.concat(self.lines, "\n") .. "\n"
end

M.Capture = Capture

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

---@class MCPHub.Exec.Opts
---@field command string Shell command line
---@field cwd string Absolute working directory
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

---@param opts MCPHub.Exec.Opts
---@return MCPHub.Exec.Job? job
---@return string? err
function M.start(opts)
    ---@type MCPHub.Exec.Job
    local job = {
        id = 0,
        pid = 0,
        command = opts.command,
        cwd = opts.cwd,
        started_at = vim.uv.now(),
        exited = false,
        stdout = Capture.new(),
        stderr = Capture.new(),
    }

    -- Neovim runs `on_exit` only after both output streams have closed, so the
    -- captures are complete by the time it fires.
    local ok, id = pcall(vim.fn.jobstart, M.build_argv(opts.command), {
        cwd = opts.cwd,
        on_stdout = function(_, data)
            job.stdout:feed(data)
        end,
        on_stderr = function(_, data)
            job.stderr:feed(data)
        end,
        on_exit = function(_, code)
            job.stdout:finish()
            job.stderr:finish()
            job.exit_code = code
            job.ended_at = vim.uv.now()
            job.exited = true
            M.jobs[job.id] = nil
            if opts.on_exit then
                opts.on_exit(job)
            end
        end,
    })

    if not ok then
        return nil, tostring(id)
    end
    if id == 0 then
        return nil, "Invalid arguments for jobstart"
    end
    if id == -1 then
        return nil, "Command is not executable"
    end

    job.id = id
    job.pid = vim.fn.jobpid(id)
    M.jobs[id] = job
    return job
end

return M
