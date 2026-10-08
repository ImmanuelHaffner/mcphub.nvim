--- CodeCompanion chat decorations for native tools: the command a tool runs,
--- written as a code block under its label and folded together with it, and
--- a live progress line above the fold while the command runs.
local State = require("mcphub.state")
local exec = require("mcphub.native.neovim.utils.exec")
local fence = require("mcphub.utils.fence")
local shared = require("mcphub.extensions.shared")

local M = {}

M.NS = vim.api.nvim_create_namespace("mcphub_exec")

---@class MCPHub.ExecUI.CommandFold
---@field bufnr integer The chat buffer
---@field fence_mark integer Extmark on the block's closing fence
---@field height integer Rows from the label to the closing fence
---@field label string The label's text, for a CodeCompanion that cannot render `chunks`
---@field summary_row? integer The row its CodeCompanion fold summary is keyed by

--- Folds to re-create once CodeCompanion has rewritten their label row, keyed
--- by the `bufnr` of the tools coordinator, which `CodeCompanionToolFinished`
--- reports.
---@type table<integer, MCPHub.ExecUI.CommandFold[]>
local pending = {}

--- CodeCompanion's fold and icon modules, or nil when CodeCompanion is absent.
---@return table? folds
---@return table? icons
local function codecompanion_ui()
    local ok_folds, folds = pcall(require, "codecompanion.interactions.chat.ui.folds")
    local ok_icons, icons = pcall(require, "codecompanion.interactions.chat.ui.icons")
    if ok_folds and ok_icons then
        return folds, icons
    end
end

---@param entry MCPHub.ExecUI.CommandFold
---@return integer? first The label row, 0-based
---@return integer? last The closing fence's row, 0-based
local function rows(entry)
    local pos = vim.api.nvim_buf_get_extmark_by_id(entry.bufnr, M.NS, entry.fence_mark, {})
    if pos[1] then
        return pos[1] - entry.height, pos[1]
    end
end

--- The fold line, styled like CodeCompanion's tool folds: the label's current
--- status icon, then the label text. Evaluated on every redraw, so the icon
--- follows the tool from running to done.
---@param entry MCPHub.ExecUI.CommandFold
---@return table[]? chunks
local function fold_chunks(entry)
    local row = rows(entry)
    local _, icons = codecompanion_ui()
    if not (row and icons) then
        return nil
    end
    local text = vim.api.nvim_buf_get_lines(entry.bufnr, row, row + 1, false)[1] or ""
    local marks = vim.api.nvim_buf_get_extmarks(entry.bufnr, icons.ns(), { row, 0 }, { row, -1 }, { details = true })
    local icon = marks[1] and marks[1][4].virt_text and marks[1][4].virt_text[1]
    if not icon then
        return { { text, "CodeCompanionChatToolText" } }
    end
    -- CodeCompanion names each status's text group after its icon group, minus the `Icon` suffix.
    return { { icon[1], icon[2] }, { text, (icon[2]:gsub("Icon$", "")) } }
end

--- Register the fold with CodeCompanion, whose 'foldtext' renders only the folds
--- it has a summary for. The summary is keyed by the fold's first row.
---@param entry MCPHub.ExecUI.CommandFold
---@param row integer
local function register_summary(entry, row)
    local folds = codecompanion_ui()
    if not folds then
        return
    end
    local summaries = folds.fold_summaries[entry.bufnr] or {}
    folds.fold_summaries[entry.bufnr] = summaries
    if entry.summary_row and entry.summary_row ~= row then
        summaries[entry.summary_row] = nil
    end
    entry.summary_row = row
    summaries[row] = {
        type = "tool",
        content = entry.label,
        chunks = function()
            return fold_chunks(entry)
        end,
    }
end

--- A chat with no window can hold no fold, so queue it where CodeCompanion
--- queues its own; `Folds:setup` creates it once a window shows the chat again.
---@param bufnr integer
---@param first integer
---@param last integer
local function defer_fold(bufnr, first, last)
    local folds = codecompanion_ui()
    if not (folds and folds.pending) then
        return
    end
    folds.pending[bufnr] = folds.pending[bufnr] or {}
    folds.pending[bufnr][first] = last
end

--- Create a manual fold over the 0-based rows `first`..`last` in `win`.
---@param win integer
---@param first integer
---@param last integer
---@param closed boolean
local function create_fold(win, first, last, closed)
    vim.api.nvim_win_call(win, function()
        local view = vim.fn.winsaveview()
        -- `:fold` raises E350 unless 'foldmethod' is manual or marker.
        if pcall(vim.cmd, ("%d,%dfold"):format(first + 1, last + 1)) and not closed then
            vim.cmd(("%dfoldopen"):format(first + 1))
        end
        vim.fn.winrestview(view)
    end)
end

--- Rewriting a fold's first row with `nvim_buf_set_lines` makes Neovim drop the
--- fold's last row. Replace the shrunken fold with one reaching the fence again,
--- as closed or open as the user left it.
---@param entry MCPHub.ExecUI.CommandFold
local function repair(entry)
    if not vim.api.nvim_buf_is_valid(entry.bufnr) then
        return
    end
    local first, last = rows(entry)
    if not first then
        return
    end
    ---@cast last integer
    for _, win in ipairs(vim.fn.win_findbuf(entry.bufnr)) do
        local present, closed
        vim.api.nvim_win_call(win, function()
            -- A fold the user deleted stays deleted.
            present = vim.fn.foldlevel(first + 1) > 0
            closed = vim.fn.foldclosed(first + 1) ~= -1
            if present then
                local view = vim.fn.winsaveview()
                vim.cmd(("%dnormal! zd"):format(first + 1))
                vim.fn.winrestview(view)
            end
        end)
        if present then
            create_fold(win, first, last, closed)
        end
    end
    register_summary(entry, first)
end

local augroup
local function watch_tool_finished()
    if augroup then
        return
    end
    augroup = vim.api.nvim_create_augroup("mcphub_exec_ui", { clear = true })
    vim.api.nvim_create_autocmd("User", {
        group = augroup,
        pattern = "CodeCompanionToolFinished",
        callback = function(args)
            local key = args.data and args.data.bufnr
            local entries = key and pending[key]
            if not entries then
                return
            end
            pending[key] = nil
            for _, entry in ipairs(entries) do
                repair(entry)
            end
        end,
    })
end

--- Write the tool's `label_block` directly below its label and fold both,
--- closed, in every window showing the chat, or once one does. CodeCompanion
--- has written the label by the time the tool runs. Does nothing for a tool
--- without `label_block`, or against a CodeCompanion without `get_tool_label`.
---@param tools table CodeCompanion's tools coordinator
---@param parsed_params MCPHub.ParsedParams
function M.show_command(tools, parsed_params)
    local tool = shared.find_native_tool(parsed_params.server_name, parsed_params.tool_name)
    local orchestrator = tools and tools.chat and tools.chat.tool_orchestrator
    if not (tool and tool.label_block and orchestrator and orchestrator.get_tool_label) then
        return
    end
    local ok_label, label = pcall(orchestrator.get_tool_label, orchestrator)
    local ok_block, block = pcall(tool.label_block, parsed_params.arguments)
    if not (ok_label and label and ok_block and type(block) == "table" and type(block.text) == "string") then
        return
    end

    local bufnr, first = label.bufnr, label.row
    local lines = vim.split(fence.code_block(block.text, { info = block.lang, min = 3 }), "\n", { plain = true })
    local modifiable = vim.bo[bufnr].modifiable
    vim.bo[bufnr].modifiable = true
    local written = pcall(vim.api.nvim_buf_set_lines, bufnr, first + 1, first + 1, false, lines)
    vim.bo[bufnr].modifiable = modifiable
    if not written then
        return
    end

    local last = first + #lines
    ---@type MCPHub.ExecUI.CommandFold
    local entry = {
        bufnr = bufnr,
        fence_mark = vim.api.nvim_buf_set_extmark(bufnr, M.NS, last, 0, { right_gravity = false }),
        height = #lines,
        label = label.text,
    }
    local windows = vim.fn.win_findbuf(bufnr)
    for _, win in ipairs(windows) do
        create_fold(win, first, last, true)
    end
    if #windows == 0 then
        defer_fold(bufnr, first, last)
    end
    register_summary(entry, first)
    watch_tool_finished()
    local key = tools.bufnr or bufnr
    pending[key] = pending[key] or {}
    table.insert(pending[key], entry)
end

local DEFAULT_REFRESH_MS = 500

--- Jobs by chat buffer and by the id of the extmark on their label row.
---@type table<integer, table<integer, MCPHub.Exec.Job>>
M.registry = {}

---@class MCPHub.ExecUI.Progress
---@field bufnr integer
---@field key integer Extmark on the label row, which keys the job in `M.registry`
---@field mark integer Extmark carrying the progress line
---@field job MCPHub.Exec.Job

--- Progress lines still to redraw: their job runs, or exited since the last
--- redraw.
---@type MCPHub.ExecUI.Progress[]
local live = {}

---@type uv.uv_timer_t?
local ticker

local DEFAULT_CANCEL_KEY = "<LocalLeader>k"

---@return string lhs
local function cancel_key()
    local cfg = (State.config.builtin_tools or {}).execute_command or {}
    return (cfg.keys or {}).cancel or DEFAULT_CANCEL_KEY
end

--- The row a command's keys act on, 0-based: the cursor's, or the first row of
--- the closed fold the cursor is in, which for a command is its label's. The
--- cursor stays inside a fold that is closed around it, as `zc` does.
---@param win integer
---@return integer
local function cursor_row(win)
    local row = vim.api.nvim_win_get_cursor(win)[1]
    local first = vim.api.nvim_win_call(win, function()
        return vim.fn.foldclosed(row)
    end)
    return (first ~= -1 and first or row) - 1
end

--- The job whose label is on `row`.
---@param bufnr integer
---@param row integer 0-based
---@return MCPHub.Exec.Job?
local function job_at(bufnr, row)
    local jobs = M.registry[bufnr]
    if not jobs then
        return nil
    end
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, M.NS, { row, 0 }, { row, -1 }, {})) do
        if jobs[mark[1]] then
            return jobs[mark[1]]
        end
    end
end

---@param job MCPHub.Exec.Job
---@return boolean
local function cancellable(job)
    return not (job.exited or job.terminating)
end

---@param n integer
---@return string
local function line_count(n)
    if n == 1 then
        return "1 line"
    end
    for _, unit in ipairs({ { 1e9, "G" }, { 1e6, "M" }, { 1e3, "k" } }) do
        if n >= unit[1] then
            return (("%.1f"):format(n / unit[1]):gsub("%.0$", "")) .. unit[2] .. " lines"
        end
    end
    return n .. " lines"
end

--- The progress line: while the job runs, elapsed time against its timeout,
--- output, RSS and the time since the last output; once it has exited, how
--- long it ran and how it ended, which the folded label's status icon would
--- otherwise be the only sign of.
---@param job MCPHub.Exec.Job
---@param now integer `vim.uv.now()`
---@param hint? string The cancel key, shown while the cursor is on the command's label
---@return string[][] chunks
function M.render(job, now, hint)
    if job.exited then
        local ran = (job.ended_at or now) - job.started_at
        local text
        if job.reason == "timeout" then
            text = ("timed out after %gs"):format(job.timeout_ms / 1000)
        elseif job.reason == "cancelled" then
            text = ("cancelled after %ds"):format(math.floor(ran / 1000))
        elseif job.reason == "stopped" then
            text = "stopped"
        elseif job.reason == "memory" then
            text = ("killed: RSS %s > %s"):format(exec.mem_size(job.memory_peak), exec.mem_size(job.memory_limit))
        else
            text = ("%.1fs · exit %s"):format(ran / 1000, tostring(job.exit_code))
        end
        local ok = job.reason == nil and job.exit_code == 0
        return { { text, ok and "Comment" or "DiagnosticWarn" } }
    end
    local stats = job.stats
    local elapsed = ("⏱ %ds"):format(math.floor((now - job.started_at) / 1000))
    if job.timeout_ms then
        elapsed = elapsed .. ("/%gs"):format(job.timeout_ms / 1000)
    end
    local parts = { elapsed, line_count(stats.out_lines), exec.mem_size(stats.out_bytes) }
    if stats.rss_bytes then
        parts[#parts + 1] = "RSS " .. exec.mem_size(stats.rss_bytes)
    end
    parts[#parts + 1] = ("idle %ds"):format(math.floor((now - (stats.last_output_at or job.started_at)) / 1000))
    if hint then
        parts[#parts + 1] = hint .. " cancel"
    end
    return { { table.concat(parts, " · "), "Comment" } }
end

--- The cancel key to show on `entry`'s line: while its job can be cancelled
--- and the current window's cursor is on its label.
---@param entry MCPHub.ExecUI.Progress
---@return string?
local function hint(entry)
    local win = vim.api.nvim_get_current_win()
    if not cancellable(entry.job) or vim.api.nvim_win_get_buf(win) ~= entry.bufnr then
        return nil
    end
    local pos = vim.api.nvim_buf_get_extmark_by_id(entry.bufnr, M.NS, entry.key, {})
    if pos[1] ~= cursor_row(win) then
        return nil
    end
    return vim.fn.keytrans(vim.keycode(cancel_key()))
end

---@param entry MCPHub.ExecUI.Progress
---@param now integer
---@return boolean drawn False once the line went with its buffer or mark
local function draw(entry, now)
    if not vim.api.nvim_buf_is_valid(entry.bufnr) then
        return false
    end
    local pos = vim.api.nvim_buf_get_extmark_by_id(entry.bufnr, M.NS, entry.mark, {})
    if not pos[1] then
        return false
    end
    vim.api.nvim_buf_set_extmark(entry.bufnr, M.NS, pos[1], 0, {
        id = entry.mark,
        virt_lines = { M.render(entry.job, now, hint(entry)) },
    })
    return true
end

--- Redraw every live progress line, the final one for a job that has exited,
--- and stop once none is left.
local function tick()
    local now = vim.uv.now()
    for i = #live, 1, -1 do
        local entry = live[i]
        if not draw(entry, now) or entry.job.exited then
            table.remove(live, i)
        end
    end
    if #live == 0 and ticker then
        ticker:stop()
        ticker:close()
        ticker = nil
    end
end

local function start_ticker()
    if ticker then
        return
    end
    local cfg = (State.config.builtin_tools or {}).execute_command or {}
    local interval = cfg.refresh_ms or DEFAULT_REFRESH_MS
    ticker = vim.uv.new_timer()
    ticker:start(interval, interval, vim.schedule_wrap(tick))
end

---@param bufnr integer
local function redraw(bufnr)
    local now = vim.uv.now()
    for _, entry in ipairs(live) do
        if entry.bufnr == bufnr then
            draw(entry, now)
        end
    end
end

--- Cancel the running command whose label the cursor of `win` is on. Off a
--- label, or on a command that has finished or is terminating already, do
--- nothing at all.
---@param win integer
local function cancel(win)
    local bufnr = vim.api.nvim_win_get_buf(win)
    local job = job_at(bufnr, cursor_row(win))
    if job and cancellable(job) then
        job:terminate("cancelled")
        redraw(bufnr)
    end
end

--- Map the cancel key in the chat, and let the progress lines' cancel hint
--- follow the cursor. Once per buffer.
---@param bufnr integer
local function setup_buffer(bufnr)
    if vim.b[bufnr].mcphub_exec_keys then
        return
    end
    vim.b[bufnr].mcphub_exec_keys = true
    vim.keymap.set("n", cancel_key(), function()
        cancel(vim.api.nvim_get_current_win())
    end, { buffer = bufnr, desc = "Cancel the command on this label" })
    vim.api.nvim_create_autocmd({ "CursorMoved", "WinLeave", "BufLeave" }, {
        group = vim.api.nvim_create_augroup("mcphub_exec_ui_hint", { clear = false }),
        buffer = bufnr,
        callback = function()
            -- Scheduled, so that on leaving, the window entered decides.
            vim.schedule(function()
                redraw(bufnr)
            end)
        end,
    })
end

--- Register `job` under its tool's label, where the cancel key finds it, and
--- show its progress line directly above the label. Does nothing against a
--- CodeCompanion without `get_tool_label`.
---@param tools table CodeCompanion's tools coordinator
---@param job MCPHub.Exec.Job
function M.attach(tools, job)
    local orchestrator = tools and tools.chat and tools.chat.tool_orchestrator
    if not (orchestrator and orchestrator.get_tool_label) then
        return
    end
    local ok, label = pcall(orchestrator.get_tool_label, orchestrator)
    if not (ok and label) then
        return
    end
    local bufnr, row = label.bufnr, label.row
    -- CodeCompanion rewrites the label row with `nvim_buf_set_lines`, which
    -- pushes a mark with the default gravity onto the next row.
    local key = vim.api.nvim_buf_set_extmark(bufnr, M.NS, row, 0, { right_gravity = false })
    M.registry[bufnr] = M.registry[bufnr] or {}
    M.registry[bufnr][key] = job
    -- A closed fold hides the decorations on its rows, so the line hangs off the
    -- blank row CodeCompanion writes before every tool block.
    local mark = vim.api.nvim_buf_set_extmark(bufnr, M.NS, row - 1, 0, {
        virt_lines = { M.render(job, vim.uv.now()) },
    })
    table.insert(live, { bufnr = bufnr, key = key, mark = mark, job = job })
    setup_buffer(bufnr)
    start_ticker()
end

--- Whether the progress lines' redraw timer is running; for tests.
---@return boolean
function M._ticker_active()
    return ticker ~= nil
end

return M
