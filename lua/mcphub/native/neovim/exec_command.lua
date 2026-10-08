--- The `execute_command` native tool. Kept apart from `terminal.lua`, which
--- registers it, so the definition can be exercised without a running hub.
local Path = require("plenary.path")
local State = require("mcphub.state")
local exec = require("mcphub.native.neovim.utils.exec")

local M = {}

--- User-facing configuration for `execute_command`, declared in
--- `mcphub/config.lua` under `builtin_tools.execute_command`. Every field is
--- optional and falls back to the runner's default.
---
---@class MCPHub.ExecuteCommandConfig
---@field capture_bytes integer? Output kept in memory per stream; the rest is only in the log file
---@field kill_ladder MCPHub.Exec.KillStep[]? Signals sent to the process group before SIGKILL
---@field keys { cancel: string?, output: string[]? }? Keys on a command's label in a CodeCompanion chat
---@field memory_limit "auto"|number|false? RSS in bytes above which a command is terminated; "auto" is min(25 % RAM, 8 GiB)
---@field nice integer|false? CPU niceness of commands, within [0, 19]; `false` runs them at Neovim's priority
---@field oom_score_adj integer|false? Linux only: OOM-killer score of commands; `false` leaves it alone
---@field refresh_ms integer? How often the chat's progress line for a running command is redrawn, in ms
---@field timeout_default number? Seconds a command may run when the call passes no `timeout`
---@field timeout_soft_limit number? Largest `timeout`, in seconds, that runs without the user's confirmation

local DEFAULT_TIMEOUT, DEFAULT_SOFT_LIMIT = 30, 600

--- Longest timer libuv accepts reliably (about 24.8 days); a confirmed
--- timeout beyond it, `math.huge` included, is clamped rather than overflowing.
local MAX_TIMER_MS = 0x7fffffff

--- Read at call time, because `State.config` is empty until mcphub's `setup()`
--- runs.
---@return MCPHub.ExecuteCommandConfig
local function config()
    return (State.config.builtin_tools or {}).execute_command or {}
end

---@return number default
---@return number soft_limit
local function timeouts()
    local cfg = config()
    return cfg.timeout_default or DEFAULT_TIMEOUT, cfg.timeout_soft_limit or DEFAULT_SOFT_LIMIT
end

---@param n number
---@return string
local function seconds(n)
    return ("%g s"):format(n)
end

---@param n integer
---@return string
local function size(n)
    for _, unit in ipairs({ { 1024 * 1024, "MiB" }, { 1024, "KiB" } }) do
        if n >= unit[1] and n % unit[1] == 0 then
            return ("%d %s"):format(n / unit[1], unit[2])
        end
    end
    return ("%d bytes"):format(n)
end

--- The timeout a call runs under, in seconds; `0` means none. An absent
--- `timeout` takes the configured default. Exemptions from the soft limit are
--- not checked here: `confirm_if` has the user approve them before the call.
---@param value any The call's `timeout` argument
---@return number? seconds
---@return string? err
function M.resolve_timeout(value)
    if value == nil or value == vim.NIL then
        return (timeouts())
    end
    if type(value) ~= "number" or value ~= value or value < 0 then
        return nil, ("timeout must be a non-negative number of seconds, got %s"):format(vim.inspect(value))
    end
    return value
end

--- Why a call needs the user's confirmation despite auto-approval, if it does.
--- Invalid timeouts pass, so the handler can reject them without a prompt.
---@param args table The call's arguments
---@return string? reason
function M.confirm_if(args)
    local t = args and args.timeout
    if type(t) ~= "number" then
        return nil
    end
    local _, soft = timeouts()
    if t == 0 then
        return "no timeout requested (timeout = 0)"
    end
    if t > soft then
        return ("timeout %s exceeds the %s soft limit"):format(seconds(t), seconds(soft))
    end
end

--- Display cells the label's command may take; the full command is in the
--- folded block below the label.
local LABEL_CELLS = 120

--- The command as one line of at most `LABEL_CELLS` cells, since
--- CodeCompanion's tool label is a single buffer line.
---@param command string
---@return string
local function one_line(command)
    local line = vim.trim(command):gsub("\r?\n", " ⏎ "):gsub("%s+", " ")
    if vim.fn.strdisplaywidth(line) <= LABEL_CELLS then
        return line
    end
    local kept, width = {}, 0
    for _, char in ipairs(vim.fn.split(line, "\\zs")) do
        width = width + vim.fn.strdisplaywidth(char)
        if width > LABEL_CELLS - 1 then
            break
        end
        kept[#kept + 1] = char
    end
    return table.concat(kept) .. "…"
end

--- The command, shown after the tool's name on its CodeCompanion label from
--- the moment it starts.
---@param args table The call's arguments
---@return string
function M.label(args)
    return "$ " .. one_line(args.command)
end

--- The verbatim command, written as a folded code block below the label.
---@param args table The call's arguments
---@return { lang: string, text: string }
function M.label_block(args)
    return { lang = "sh", text = args.command }
end

---@return string
function M.description()
    local default, soft = timeouts()
    local shell = exec.build_argv("", { nice = false, oom_score_adj = false })
    shell[#shell] = nil
    local signals = {}
    for _, step in ipairs((exec.resolve_ladder(config().kill_ladder))) do
        signals[#signals + 1] = step[1]:upper()
    end
    signals[#signals + 1] = "SIGKILL"
    local lines = {
        ("Execute a shell command (`%s`) in `cwd` and return its exit code, stdout and stderr. The environment is inherited from Neovim."):format(
            table.concat(shell, " ")
        ),
        "",
        ("- `timeout` (optional, seconds): the command is terminated after this long. Default: %g. Values up to %g run without asking; larger values, or `0` for no timeout, require the user's confirmation — use them only when the command genuinely needs it."):format(
            default,
            soft
        ),
        ("- On timeout or cancellation the process group receives %s; the result says why the command stopped and includes the output captured so far."):format(
            table.concat(signals, ", then ")
        ),
        ("- Output larger than %s per stream is elided in the middle; the result names a log file holding the full output."):format(
            size(config().capture_bytes or exec.DEFAULT_CAPTURE_BYTES)
        ),
    }
    local nice = exec.resolve_nice(config().nice)
    local memory_limit = exec.resolve_memory_limit(config().memory_limit)
    if nice and memory_limit then
        lines[#lines + 1] = ("- Commands run at reduced CPU priority and are terminated if their memory use exceeds %s."):format(
            exec.mem_size(memory_limit)
        )
    elseif nice then
        lines[#lines + 1] = "- Commands run at reduced CPU priority."
    elseif memory_limit then
        lines[#lines + 1] = ("- Commands are terminated if their memory use exceeds %s."):format(
            exec.mem_size(memory_limit)
        )
    end
    return table.concat(lines, "\n")
end

---@return table
function M.input_schema()
    local default, soft = timeouts()
    return {
        type = "object",
        properties = {
            command = {
                type = "string",
                description = "Shell command to execute",
                examples = { [["ls -la"]] },
            },
            cwd = {
                type = "string",
                description = "Working directory for the command",
                default = ".",
            },
            timeout = {
                type = "number",
                description = ("Seconds before the command is terminated. Default: %g. Up to %g runs without asking; larger values, or 0 for no timeout, need the user's confirmation."):format(
                    default,
                    soft
                ),
            },
        },
        required = { "command", "cwd" },
    }
end

---@param job MCPHub.Exec.Job
---@param clamped_from? number The `timeout` the call asked for before the user clamped it
---@return string
function M.format_result(job, clamped_from)
    local parts = {}
    if clamped_from then
        table.insert(
            parts,
            ("Ran with `timeout = %g` s; the user clamped it from %s.\n"):format(
                job.timeout_ms / 1000,
                clamped_from == 0 and "`timeout = 0` (no timeout)" or seconds(clamped_from)
            )
        )
    end
    if job.reason == "timeout" then
        table.insert(
            parts,
            ("Timed out after %s and was terminated%s; pass a larger `timeout` if the command is expected to run longer.\n"):format(
                seconds(job.timeout_ms / 1000),
                job.last_signal and (" (%s)"):format(job.last_signal:upper()) or ""
            )
        )
    elseif job.reason == "memory" then
        table.insert(
            parts,
            ("Killed: memory use %s exceeded the %s limit%s.\n"):format(
                exec.mem_size(job.memory_peak),
                exec.mem_size(job.memory_limit),
                job.last_signal and (" (%s)"):format(job.last_signal:upper()) or ""
            )
        )
    elseif job.reason == "cancelled" then
        local lines = job.stats.out_lines
        table.insert(
            parts,
            ("Cancelled by the user after %d s%s. Partial output (%s%s):\n"):format(
                math.floor(((job.ended_at or vim.uv.now()) - job.started_at) / 1000),
                job.last_signal and (" (%s)"):format(job.last_signal:upper()) or "",
                lines == 1 and "1 line" or ("%d lines"):format(lines),
                job.log_path and (", full log at " .. job.log_path) or ""
            )
        )
    end
    vim.list_extend(parts, {
        "Command: " .. job.command .. "\n",
        "Working Directory: " .. job.cwd .. "\n",
        "Exit Code: " .. tostring(job.exit_code) .. "\n",
    })
    if not job.stdout:is_empty() then
        table.insert(parts, "Output:\n\n" .. job.stdout:text(job.log_path))
    end
    if not job.stderr:is_empty() then
        table.insert(parts, "\nError Output:\n" .. job.stderr:text(job.log_path))
    end
    if job.stdout:is_empty() and job.stderr:is_empty() then
        table.insert(parts, "Command completed with no output.")
    end
    if job.log_path and (job.stdout:truncated() or job.stderr:truncated()) then
        table.insert(parts, "\nFull log: " .. job.log_path .. "\n")
    end
    return table.concat(parts)
end

---@param req ToolRequest
---@param res ToolResponse
function M.handler(req, res)
    local command = req.params.command
    local cwd = req.params.cwd
    -- Set by the approval gate when the user chose to run with the soft limit.
    local clamped_from = req.params._clamped_from
    req.params._clamped_from = nil
    if type(clamped_from) ~= "number" then
        clamped_from = nil
    end

    if not command or command == "" then
        return res:error("command field is required and cannot be empty.")
    end
    if not cwd or cwd == "" then
        return res:error("cwd field is required and cannot be empty.")
    end

    local path = Path:new(cwd)
    if not path:exists() then
        return res:error("Directory does not exist: " .. cwd)
    end
    if not path:is_dir() then
        return res:error("Path is not a directory: " .. cwd)
    end

    local timeout, timeout_err = M.resolve_timeout(req.params.timeout)
    if not timeout then
        return res:error(timeout_err)
    end

    local job, err = exec.start({
        command = command,
        cwd = path:absolute(),
        capture_bytes = config().capture_bytes,
        kill_ladder = config().kill_ladder,
        nice = config().nice,
        oom_score_adj = config().oom_score_adj,
        memory_limit = config().memory_limit,
        timeout_ms = timeout > 0 and math.max(1, math.min(math.floor(timeout * 1000 + 0.5), MAX_TIMER_MS)) or nil,
        on_exit = function(job)
            local text = M.format_result(job, clamped_from)
            if job.reason == "timeout" or job.reason == "memory" or job.reason == "cancelled" then
                res:error(text)
            else
                res:text(text):send()
            end
        end,
    })
    if not job then
        return res:error(err)
    end
    -- CodeCompanion's whole-turn stop calls `kill("sigterm")` on the registered
    -- handle; route it into the ladder so the whole process group goes.
    if req.caller and req.caller.register_job then
        req.caller.register_job({
            kill = function()
                job:terminate("stopped")
            end,
        })
    end
    -- The chat's progress display; failing to show it must not fail the command.
    if req.caller and req.caller.on_job then
        pcall(req.caller.on_job, job)
    end
end

---@type MCPTool
M.definition = {
    name = "execute_command",
    description = M.description,
    inputSchema = M.input_schema,
    label = M.label,
    label_block = M.label_block,
    confirm_if = M.confirm_if,
    call_noun = "command",
    cwd_param = "cwd",
    timeout_param = "timeout",
    timeout_soft_limit = function()
        local _, soft = timeouts()
        return soft
    end,
    handler = M.handler,
}

return M
