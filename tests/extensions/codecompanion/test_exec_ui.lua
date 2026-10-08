-- Tests for mcphub.extensions.codecompanion.exec_ui: the command block written
-- under a CodeCompanion tool label, its fold, and the progress line above it.
--
-- Run with `make test`, or just this file with
-- `make test_file FILE=tests/extensions/codecompanion/test_exec_ui.lua`.
local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local State = require("mcphub.state")
local exec = require("mcphub.native.neovim.utils.exec")
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

local MiB, GiB = 1024 * 1024, 1024 * 1024 * 1024

--- A running job as the runner records it, with `fields` overriding.
---@param fields? table
local function fake_job(fields)
    return vim.tbl_extend("force", {
        started_at = vim.uv.now(),
        exited = false,
        stats = { out_bytes = 0, out_lines = 0 },
    }, fields or {})
end

--- An exited job that ran for 12.3 s and exited 0, with `fields` overriding.
---@param fields? table
local function ended_job(fields)
    return fake_job(
        vim.tbl_extend("force", { started_at = 0, ended_at = 12300, exited = true, exit_code = 0 }, fields or {})
    )
end

--- The 0-based rows of the job's key marks and progress lines, and the
--- progress lines' text.
local function progress_marks()
    local found = { key = {}, progress = {}, text = {} }
    local registry = exec_ui.registry[chat.buf] or {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(chat.buf, exec_ui.NS, 0, -1, { details = true })) do
        if mark[4].virt_lines then
            table.insert(found.progress, mark[2])
            table.insert(found.text, mark[4].virt_lines[1][1][1])
        elseif registry[mark[1]] then
            table.insert(found.key, mark[2])
        end
    end
    return found
end

--- Real jobs a case started; `post_case` stops those still running.
---@type MCPHub.Exec.Job[]
local started = {}

--- Start a real command under a short ladder, attached to the chat's label.
---@param command string
---@return MCPHub.Exec.Job
local function attach_command(command)
    local job = assert(exec.start({
        command = command,
        cwd = "/tmp",
        kill_ladder = { { "sigint", 200 }, { "sigterm", 200 } },
    }))
    table.insert(started, job)
    exec_ui.attach(fake_tools(), job)
    return job
end

---@param job MCPHub.Exec.Job
---@return boolean exited
local function wait_exit(job)
    return vim.wait(5000, function()
        return job.exited
    end, 10)
end

--- Put the chat's cursor on a 1-based row and press the cancel key there.
---@param row integer
local function press_cancel(row)
    vim.api.nvim_win_set_cursor(chat.win, { row, 0 })
    vim.api.nvim_feedkeys(vim.keycode("<LocalLeader>k"), "x", false)
end

local HINT = " · " .. vim.fn.keytrans(vim.keycode("<LocalLeader>k")) .. " cancel"

---@return boolean
local function hinted()
    return vim.endswith(progress_marks().text[1], HINT)
end

--- Put the chat's cursor on a 1-based row, then wait for the progress line to
--- show or drop the cancel hint.
---@param row integer
---@param shown boolean
---@return boolean
local function hint_follows(row, shown)
    vim.api.nvim_win_set_cursor(chat.win, { row, 0 })
    return vim.wait(1000, function()
        return hinted() == shown
    end, 10)
end

local T = new_set({
    hooks = {
        pre_case = function()
            real.is_native_server = native.is_native_server
            real.builtin_tools = State.config.builtin_tools
            State.config.builtin_tools = { execute_command = { refresh_ms = 20 } }
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
            if real.notify then
                vim.notify, real.notify = real.notify, nil
            end
            for _, job in ipairs(started) do
                job:terminate("stopped")
                wait_exit(job)
            end
            started = {}
            for name, module in pairs(real.modules) do
                package.loaded[name] = module or nil
            end
            vim.api.nvim_win_close(chat.win, true)
            vim.api.nvim_buf_delete(chat.buf, { force = true })
            -- With the buffer gone, the next redraw drops its progress lines and stops.
            vim.wait(1000, function()
                return not exec_ui._ticker_active()
            end, 10)
            State.config.builtin_tools = real.builtin_tools
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

T["progress line"] = new_set()

T["progress line"]["renders a running job"] = function()
    local now = 100000
    local job = fake_job({
        started_at = now - 12000,
        timeout_ms = 30000,
        stats = { out_lines = 1200, out_bytes = 3.4 * MiB, rss_bytes = 210 * MiB, last_output_at = now - 4000 },
    })
    eq(exec_ui.render(job, now), { { "⏱ 12s/30s · 1.2k lines · 3 MiB · RSS 210 MiB · idle 4s", "Comment" } })
end

T["progress line"]["renders how the job ended"] = function()
    local function text(fields)
        return exec_ui.render(ended_job(fields), 0)[1]
    end
    eq(text({}), { "12.3s · exit 0", "Comment" })
    eq(text({ exit_code = 3 }), { "12.3s · exit 3", "DiagnosticWarn" })
    eq(text({ reason = "timeout", timeout_ms = 30000, exit_code = 130 }), { "timed out after 30s", "DiagnosticWarn" })
    eq(text({ reason = "cancelled", ended_at = 47400 })[1], "cancelled after 47s")
    eq(text({ reason = "stopped" })[1], "stopped")
    eq(text({ reason = "memory", memory_peak = 8.3 * GiB, memory_limit = 8 * GiB })[1], "killed: RSS 8.3 GiB > 8 GiB")
end

T["progress line"]["attach marks the label and puts the line above it"] = function()
    exec_ui.attach(fake_tools(), fake_job())
    local marks = progress_marks()
    eq(marks.key, { LABEL_ROW - 1 })
    eq(marks.progress, { LABEL_ROW - 2 })
    eq(vim.startswith(marks.text[1], "⏱ 0s · 0 lines · 0 B · idle 0s"), true)
end

T["progress line"]["is a no-op against an unpatched CodeCompanion"] = function()
    exec_ui.attach(fake_tools({}), fake_job())
    eq(vim.api.nvim_buf_get_extmarks(chat.buf, exec_ui.NS, 0, -1, {}), {})
end

T["progress line"]["the marks survive the label's completion"] = function()
    exec_ui.attach(fake_tools(), fake_job())
    vim.bo[chat.buf].modifiable = true
    vim.api.nvim_buf_set_lines(chat.buf, LABEL_ROW - 1, LABEL_ROW, false, { "done" })
    vim.bo[chat.buf].modifiable = false
    local marks = progress_marks()
    eq({ marks.key, marks.progress }, { { LABEL_ROW - 1 }, { LABEL_ROW - 2 } })
    insert_above(2)
    marks = progress_marks()
    eq({ marks.key, marks.progress }, { { LABEL_ROW + 1 }, { LABEL_ROW } })
end

T["progress line"]["shows how the job ended, then stops redrawing"] = function()
    local job = fake_job()
    exec_ui.attach(fake_tools(), job)
    eq(exec_ui._ticker_active(), true)
    job.exited, job.ended_at, job.exit_code = true, job.started_at + 1500, 0
    eq(
        vim.wait(1000, function()
            return not exec_ui._ticker_active()
        end, 10),
        true
    )
    eq(progress_marks().text, { "1.5s · exit 0" })
end

T["cancel key"] = new_set()

T["cancel key"]["cancels the command on its label"] = function()
    local job = attach_command("sleep 100")
    press_cancel(LABEL_ROW)
    eq(job.reason, "cancelled")
    eq(wait_exit(job), true)
end

T["cancel key"]["cancels from inside the label's closed fold"] = function()
    show()
    local job = attach_command("sleep 100")
    press_cancel(LABEL_ROW + 2)
    eq(fold(LABEL_ROW + 2), { LABEL_ROW, FENCE_ROW })
    eq(job.reason, "cancelled")
end

T["cancel key"]["does nothing off the label"] = function()
    local notified = 0
    real.notify = vim.notify
    vim.notify = function()
        notified = notified + 1
    end
    local job = attach_command("sleep 100")
    -- The row above the label, which carries the progress line.
    press_cancel(LABEL_ROW - 1)
    eq(job.terminating, false)
    eq(notified, 0)
end

T["cancel key"]["does nothing on a finished command"] = function()
    local job = attach_command("true")
    eq(wait_exit(job), true)
    press_cancel(LABEL_ROW)
    eq(job.terminating, false)
    eq(job.reason, nil)
end

T["cancel key"]["pressing again leaves the ladder alone"] = function()
    local job = attach_command("trap '' INT TERM; echo ready; sleep 100")
    -- Once the trap is set, only SIGKILL ends the group.
    eq(
        vim.wait(2000, function()
            return job.stats.out_lines > 0
        end, 10),
        true
    )
    press_cancel(LABEL_ROW)
    eq(job.last_signal, "sigint")
    press_cancel(LABEL_ROW)
    eq(job.last_signal, "sigint")
    eq(
        vim.wait(1000, function()
            return job.last_signal == "sigterm"
        end, 5),
        true
    )
    press_cancel(LABEL_ROW)
    eq(job.last_signal, "sigterm")
    eq(wait_exit(job), true)
    eq(job.last_signal, "sigkill")
end

T["cancel hint"] = new_set()

T["cancel hint"]["shows while the cursor is on the label or in its closed fold"] = function()
    show()
    attach_command("sleep 100")
    eq(hint_follows(LABEL_ROW, true), true)
    eq(hint_follows(LABEL_ROW - 1, false), true)
    eq(hint_follows(LABEL_ROW + 2, true), true)
end

T["cancel hint"]["goes once the command is cancelled"] = function()
    attach_command("sleep 100")
    eq(hint_follows(LABEL_ROW, true), true)
    press_cancel(LABEL_ROW)
    eq(hinted(), false)
end

return T
