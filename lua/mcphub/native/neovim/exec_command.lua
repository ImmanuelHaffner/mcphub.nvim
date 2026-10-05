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

---@return string
function M.description()
    local default, soft = timeouts()
    local shell = exec.build_argv("")
    shell[#shell] = nil
    local signals = {}
    for _, step in ipairs((exec.resolve_ladder(config().kill_ladder))) do
        signals[#signals + 1] = step[1]:upper()
    end
    signals[#signals + 1] = "SIGKILL"
    return table.concat({
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
    }, "\n")
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
---@return string
function M.format_result(job)
    local parts = {}
    if job.reason == "timeout" then
        table.insert(
            parts,
            ("Timed out after %s and was terminated%s; pass a larger `timeout` if the command is expected to run longer.\n"):format(
                seconds(job.timeout_ms / 1000),
                job.last_signal and (" (%s)"):format(job.last_signal:upper()) or ""
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

    local _, err = exec.start({
        command = command,
        cwd = path:absolute(),
        capture_bytes = config().capture_bytes,
        kill_ladder = config().kill_ladder,
        timeout_ms = timeout > 0 and math.max(1, math.min(math.floor(timeout * 1000 + 0.5), MAX_TIMER_MS)) or nil,
        on_exit = function(job)
            local text = M.format_result(job)
            if job.reason == "timeout" then
                res:error(text)
            else
                res:text(text):send()
            end
        end,
    })
    if err then
        return res:error(err)
    end
end

---@type MCPTool
M.definition = {
    name = "execute_command",
    description = M.description,
    inputSchema = M.input_schema,
    confirm_if = M.confirm_if,
    call_noun = "command",
    cwd_param = "cwd",
    handler = M.handler,
}

return M
