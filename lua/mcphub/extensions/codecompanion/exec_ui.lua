--- CodeCompanion chat decorations for native tools: the command a tool runs,
--- written as a code block under its label and folded together with it.
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

return M
