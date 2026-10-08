--- A float that tails an `execute_command` job's log while the command runs,
--- and still shows the log once it has finished.
local State = require("mcphub.state")
local Text = require("mcphub.utils.text")
local exec_command = require("mcphub.native.neovim.exec_command")

local M = {}

--- Bytes from the end of the log the float shows; `gF` opens the whole file.
local TAIL_BYTES = 256 * 1024
local DEFAULT_REFRESH_MS = 500

---@class MCPHub.ExecFloat
---@field job MCPHub.Exec.Job
---@field buf integer
---@field win integer
---@field footer? fun(job: MCPHub.Exec.Job, now: integer): string[][] Live stats for the bottom border
---@field size? integer Log size at the last read; -1 once the missing log was reported
---@field timer? uv.uv_timer_t Pending refreshes; absent once the job has exited

--- The open float of each job, so that opening it again focuses it.
---@type table<MCPHub.Exec.Job, MCPHub.ExecFloat>
local floats = setmetatable({}, { __mode = "k" })

--- The last `TAIL_BYTES` of the log as lines. A tail starting mid-file drops
--- its first line, which is cut.
---@param path string
---@return string[]? lines
local function read_tail(path)
    local fd = vim.uv.fs_open(path, "r", 420)
    if not fd then
        return nil
    end
    local stat = vim.uv.fs_fstat(fd)
    local size = stat and stat.size or 0
    local offset = math.max(0, size - TAIL_BYTES)
    local data = vim.uv.fs_read(fd, size - offset, offset) or ""
    vim.uv.fs_close(fd)
    local lines = vim.split(data, "\n", { plain = true })
    if lines[#lines] == "" then
        table.remove(lines)
    end
    if offset > 0 then
        table.remove(lines, 1)
    end
    return lines
end

---@param f MCPHub.ExecFloat
local function stop(f)
    if f.timer then
        f.timer:stop()
        f.timer:close()
        f.timer = nil
    end
end

---@param f MCPHub.ExecFloat
local function close(f)
    stop(f)
    if floats[f.job] == f then
        floats[f.job] = nil
    end
    if vim.api.nvim_win_is_valid(f.win) then
        vim.api.nvim_win_close(f.win, true)
    end
end

--- The bottom border: the live stats, then the keys that apply right now.
---@param f MCPHub.ExecFloat
---@return string[][]
local function footer(f)
    local chunks = {}
    if f.footer then
        for _, chunk in ipairs(f.footer(f.job, vim.uv.now())) do
            chunks[#chunks + 1] = { " " .. chunk[1] .. " ", chunk[2] }
        end
    end
    local keys = { { "q", "close" } }
    if not (f.job.exited or f.job.terminating) then
        keys[#keys + 1] = { "<C-c>", "cancel" }
    end
    if f.job.log_path then
        keys[#keys + 1] = { "gF", "full log" }
    end
    for _, key in ipairs(keys) do
        chunks[#chunks + 1] = { "  " .. key[1] .. " ", Text.highlights.title }
        chunks[#chunks + 1] = { key[2] .. " ", Text.highlights.muted }
    end
    return chunks
end

---@param f MCPHub.ExecFloat
---@param lines string[]
local function set_lines(f, lines)
    local follow = vim.api.nvim_win_get_cursor(f.win)[1] == vim.api.nvim_buf_line_count(f.buf)
    vim.bo[f.buf].modifiable = true
    vim.api.nvim_buf_set_lines(f.buf, 0, -1, false, lines)
    vim.bo[f.buf].modifiable = false
    if follow then
        vim.api.nvim_win_set_cursor(f.win, { vim.api.nvim_buf_line_count(f.buf), 0 })
    end
end

--- Re-read the log if it has grown, and redraw the footer. The read after the
--- job has exited is the last one: the runner has flushed the whole log by then.
---@param f MCPHub.ExecFloat
local function refresh(f)
    if not vim.api.nvim_win_is_valid(f.win) then
        return close(f)
    end
    local exited = f.job.exited
    local path = f.job.log_path
    local stat = path and vim.uv.fs_stat(path)
    if stat and stat.size ~= f.size then
        f.size = stat.size
        set_lines(f, read_tail(path) or {})
    elseif not stat and f.size ~= -1 then
        f.size = -1
        set_lines(f, { path and ("The log is gone: " .. path) or "This command wrote no log." })
    end
    vim.api.nvim_win_set_config(f.win, { footer = footer(f), footer_pos = "center" })
    if exited then
        stop(f)
    end
end

---@param f MCPHub.ExecFloat
local function map_keys(f)
    local function map(lhs, rhs, desc)
        vim.keymap.set("n", lhs, rhs, { buffer = f.buf, nowait = true, desc = desc })
    end
    map("q", function()
        close(f)
    end, "Close the command's output")
    map("<C-c>", function()
        if not (f.job.exited or f.job.terminating) then
            f.job:terminate("cancelled")
            refresh(f)
        end
    end, "Cancel the command")
    map("gF", function()
        local path = f.job.log_path
        if path and vim.uv.fs_stat(path) then
            close(f)
            vim.cmd.tabedit(vim.fn.fnameescape(path))
        end
    end, "Open the command's full log in a tab")
end

--- Show `job`'s output in a centred float, following the log while the command
--- runs. A float already open for `job` is focused instead.
---@param job MCPHub.Exec.Job
---@param opts? { footer?: fun(job: MCPHub.Exec.Job, now: integer): string[][] }
---@return MCPHub.ExecFloat
function M.open(job, opts)
    local open = floats[job]
    if open and vim.api.nvim_win_is_valid(open.win) then
        vim.api.nvim_set_current_win(open.win)
        return open
    end

    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].filetype = "log"
    vim.bo[buf].modifiable = false
    local width = math.max(20, math.floor(vim.o.columns * 0.8))
    local height = math.max(3, math.floor((vim.o.lines - vim.o.cmdheight) * 0.8))
    local title = ("%s — %s"):format(exec_command.label({ command = job.command }), vim.fn.fnamemodify(job.cwd, ":~"))
    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        width = width,
        height = height,
        row = math.floor((vim.o.lines - vim.o.cmdheight - height) / 2) - 1,
        col = math.floor((vim.o.columns - width) / 2),
        style = "minimal",
        -- A title needs a border, and Neovim 0.10 has no 'winborder' to inherit.
        border = "rounded",
        title = { { " " .. title .. " ", Text.highlights.title } },
        title_pos = "center",
    })

    ---@type MCPHub.ExecFloat
    local f = { job = job, buf = buf, win = win, footer = opts and opts.footer }
    floats[job] = f
    map_keys(f)
    vim.api.nvim_create_autocmd("WinClosed", {
        pattern = tostring(win),
        once = true,
        callback = function()
            stop(f)
            if floats[job] == f then
                floats[job] = nil
            end
        end,
    })

    refresh(f)
    if not job.exited then
        local cfg = (State.config.builtin_tools or {}).execute_command or {}
        local interval = cfg.refresh_ms or DEFAULT_REFRESH_MS
        f.timer = vim.uv.new_timer()
        f.timer:start(
            interval,
            interval,
            vim.schedule_wrap(function()
                refresh(f)
            end)
        )
    end
    return f
end

return M
