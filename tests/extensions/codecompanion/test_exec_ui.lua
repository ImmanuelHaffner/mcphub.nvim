-- Tests for mcphub.extensions.codecompanion.exec_ui: the command block written
-- under a CodeCompanion tool label, and its fold.
--
-- Run with `make test`, or just this file with
-- `make test_file FILE=tests/extensions/codecompanion/test_exec_ui.lua`.
local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local exec_command = require("mcphub.native.neovim.exec_command")
local exec_ui = require("mcphub.extensions.codecompanion.exec_ui")
local native = require("mcphub.native")

local COMMAND = "cat <<EOF\n  hi\nEOF"
local LABEL = "neovim__execute_command: " .. exec_command.label({ command = COMMAND })

--- The 1-based rows of the label, and of the block below it once written.
local LABEL_ROW, FENCE_ROW = 3, 8

local ICON_NS = vim.api.nvim_create_namespace("test_exec_ui_icons")
local RUNNING = { "R ", "CodeCompanionChatToolInProgress" }
local DONE = { "D ", "CodeCompanionChatToolSuccessIcon" }

--- CodeCompanion isn't on the test runtimepath; these stand in for the UI
--- modules `exec_ui` reads.
local FAKE_MODULES = {
    ["codecompanion.interactions.chat.ui.folds"] = function()
        return { fold_summaries = {}, pending = {} }
    end,
    ["codecompanion.interactions.chat.ui.icons"] = function()
        return {
            ns = function()
                return ICON_NS
            end,
        }
    end,
}

local real = {}

---@type { buf: integer, win: integer }
local chat

--- A CodeCompanion tools coordinator whose orchestrator reports the label row.
---@param orchestrator? table Replaces the orchestrator
local function fake_tools(orchestrator)
    return {
        bufnr = chat.buf,
        chat = {
            bufnr = chat.buf,
            tool_orchestrator = orchestrator or {
                get_tool_label = function()
                    return { bufnr = chat.buf, row = LABEL_ROW - 1, text = LABEL }
                end,
            },
        },
    }
end

---@param tools? table
---@param tool_name? string
local function show(tools, tool_name)
    ---@diagnostic disable-next-line: missing-fields
    exec_ui.show_command(tools or fake_tools(), {
        server_name = "neovim",
        tool_name = tool_name or "execute_command",
        arguments = { command = COMMAND, cwd = "/tmp" },
    })
end

local function lines()
    return vim.api.nvim_buf_get_lines(chat.buf, 0, -1, false)
end

--- `foldclosed` and `foldclosedend` of a 1-based row, the label's by default.
---@param row? integer
local function fold(row)
    row = row or LABEL_ROW
    return vim.api.nvim_win_call(chat.win, function()
        return { vim.fn.foldclosed(row), vim.fn.foldclosedend(row) }
    end)
end

--- CodeCompanion's status icon on a 0-based row, as `Icons.apply` places it.
---@param row integer
---@param icon string[]
local function set_icon(row, icon)
    vim.api.nvim_buf_clear_namespace(chat.buf, ICON_NS, row, row + 1)
    vim.api.nvim_buf_set_extmark(chat.buf, ICON_NS, row, 0, { virt_text = { icon }, virt_text_pos = "inline" })
end

---@param row? integer 0-based row of the label's summary
local function summary(row)
    local summaries = package.loaded["codecompanion.interactions.chat.ui.folds"].fold_summaries[chat.buf] or {}
    return summaries[row or LABEL_ROW - 1]
end

---@param count integer
local function insert_above(count)
    vim.bo[chat.buf].modifiable = true
    vim.api.nvim_buf_set_lines(chat.buf, 0, 0, false, vim.fn["repeat"]({ "above" }, count))
    vim.bo[chat.buf].modifiable = false
end

--- What CodeCompanion does when the tool finishes: rewrite the label row and
--- its icon, add the output below, then fire the event.
---@param shift? integer Rows inserted above the label since it was written
local function finish_tool(shift)
    local row = LABEL_ROW - 1 + (shift or 0)
    vim.bo[chat.buf].modifiable = true
    vim.api.nvim_buf_set_lines(chat.buf, row, row + 1, false, { LABEL })
    vim.api.nvim_buf_set_lines(chat.buf, -1, -1, false, { "", "**output**" })
    vim.bo[chat.buf].modifiable = false
    set_icon(row, DONE)
    vim.api.nvim_exec_autocmds("User", { pattern = "CodeCompanionToolFinished", data = { bufnr = chat.buf } })
end

local T = new_set({
    hooks = {
        pre_case = function()
            real.is_native_server = native.is_native_server
            native.is_native_server = function(name)
                local plain = { name = "plain", label = exec_command.label }
                return name == "neovim" and { capabilities = { tools = { exec_command.definition, plain } } } or nil
            end
            real.modules = {}
            for name, make in pairs(FAKE_MODULES) do
                real.modules[name] = package.loaded[name] or false
                package.loaded[name] = make()
            end
            local buf = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "## assistant", "", LABEL })
            vim.bo[buf].modifiable = false
            vim.cmd("split")
            local win = vim.api.nvim_get_current_win()
            vim.api.nvim_win_set_buf(win, buf)
            vim.wo[win].foldmethod = "manual"
            chat = { buf = buf, win = win }
            set_icon(LABEL_ROW - 1, RUNNING)
        end,
        post_case = function()
            native.is_native_server = real.is_native_server
            for name, module in pairs(real.modules) do
                package.loaded[name] = module or nil
            end
            vim.api.nvim_win_close(chat.win, true)
            vim.api.nvim_buf_delete(chat.buf, { force = true })
        end,
    },
})

T["show_command"] = new_set()

T["show_command"]["writes the verbatim command below the label"] = function()
    show()
    eq(lines(), { "## assistant", "", LABEL, "```sh", "cat <<EOF", "  hi", "EOF", "```" })
    eq(vim.bo[chat.buf].modifiable, false)
end

T["show_command"]["folds the label and the block, closed"] = function()
    show()
    eq(fold(), { LABEL_ROW, FENCE_ROW })
end

T["show_command"]["queues the fold with CodeCompanion while the chat has no window"] = function()
    local hidden = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(chat.win, hidden)
    show()
    eq(lines()[FENCE_ROW], "```")
    eq(
        package.loaded["codecompanion.interactions.chat.ui.folds"].pending[chat.buf],
        { [LABEL_ROW - 1] = FENCE_ROW - 1 }
    )
    eq(summary().type, "tool")
    vim.api.nvim_win_set_buf(chat.win, chat.buf)
    vim.api.nvim_buf_delete(hidden, { force = true })
end

T["show_command"]["queues nothing while the chat is displayed"] = function()
    show()
    eq(package.loaded["codecompanion.interactions.chat.ui.folds"].pending[chat.buf], nil)
end

T["show_command"]["is a no-op against an unpatched CodeCompanion"] = function()
    show(fake_tools({}))
    eq(lines(), { "## assistant", "", LABEL })
end

T["show_command"]["is a no-op for a tool without label_block"] = function()
    show(nil, "plain")
    eq(lines(), { "## assistant", "", LABEL })
end

T["show_command"]["the fold reaches the fence again after the tool finishes"] = function()
    show()
    finish_tool()
    eq(fold(), { LABEL_ROW, FENCE_ROW })
    eq(lines()[FENCE_ROW + 2], "**output**")
end

T["show_command"]["a fold the user opened stays open"] = function()
    show()
    vim.api.nvim_win_call(chat.win, function()
        vim.cmd(LABEL_ROW .. "foldopen")
    end)
    finish_tool()
    eq(fold(), { -1, -1 })
    vim.api.nvim_win_call(chat.win, function()
        vim.cmd(LABEL_ROW .. "foldclose")
    end)
    eq(fold(), { LABEL_ROW, FENCE_ROW })
end

T["fold line"] = new_set()

T["fold line"]["is a CodeCompanion tool fold showing the label's status icon"] = function()
    show()
    eq(summary().type, "tool")
    eq(summary().content, LABEL)
    eq(summary().chunks(), { RUNNING, { LABEL, "CodeCompanionChatToolInProgress" } })
end

T["fold line"]["follows the label's status once the tool finishes"] = function()
    show()
    finish_tool()
    eq(summary().chunks(), { DONE, { LABEL, "CodeCompanionChatToolSuccess" } })
end

T["fold line"]["moves with the label when lines are inserted above it"] = function()
    show()
    insert_above(2)
    finish_tool(2)
    eq(summary(), nil)
    eq(summary(LABEL_ROW + 1).chunks(), { DONE, { LABEL, "CodeCompanionChatToolSuccess" } })
    eq(fold(LABEL_ROW + 2), { LABEL_ROW + 2, FENCE_ROW + 2 })
end

return T
