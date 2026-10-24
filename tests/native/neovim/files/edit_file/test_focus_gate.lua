--- Tests for `focus_gate`, which decides when an interactive `EditUI` review
--- may take focus, and for its seam in `EditUI:start_interactive_editing`.
---
--- @module "tests.native.neovim.files.edit_file.test_focus_gate"

local assert = require("tests.native.neovim.files.apply_edit.busted_assert")
local edit_ui = require("mcphub.native.neovim.files.edit_file.edit_ui")
local focus_gate = require("mcphub.native.neovim.files.edit_file.focus_gate")

--- Run `fn` with `vim.notify` captured, returning the warnings it raised.
---@param fn fun()
---@return string[] messages
local function warnings_of(fn)
    focus_gate._test.reset_warnings()
    local messages = {}
    local real_notify = vim.notify
    vim.notify = function(message, level)
        if level == vim.log.levels.WARN then
            messages[#messages + 1] = message
        end
    end
    local ok, err = pcall(fn)
    vim.notify = real_notify
    if not ok then
        error(err, 0)
    end
    return messages
end

describe("resolve", function()
    it("gives the defaults for nil and for an empty table", function()
        for _, cfg in ipairs({ focus_gate.resolve(nil), focus_gate.resolve({}) }) do
            assert.is_nil(cfg.allow_in_modes)
            assert.is.equal(false, cfg.chat)
            assert.is.equal(2000, cfg.settle_ms)
            assert.is_true(focus_gate.inert(cfg))
        end
    end)

    it("turns the mode list into a set", function()
        local cfg = focus_gate.resolve({ allow_in_modes = { "n", "\22" } })
        assert.are.same({ n = true, ["\22"] = true }, cfg.allow_in_modes)
        assert.is_false(focus_gate.inert(cfg))
    end)

    it("ignores an empty mode list, which would block forever, with one warning", function()
        local cfg
        local messages = warnings_of(function()
            cfg = focus_gate.resolve({ allow_in_modes = {} })
            focus_gate.resolve({ allow_in_modes = {} })
        end)
        assert.is_nil(cfg.allow_in_modes)
        assert.is.equal(1, #messages)
        assert.is_truthy(messages[1]:find("allow_in_modes", 1, true))
    end)

    it("ignores a mode string, which is not a list", function()
        local cfg
        local messages = warnings_of(function()
            cfg = focus_gate.resolve({ allow_in_modes = "n" })
        end)
        assert.is_nil(cfg.allow_in_modes)
        assert.is.equal(1, #messages)
    end)

    it("accepts both chat policies", function()
        assert.is.equal("visible", focus_gate.resolve({ chat = "visible" }).chat)
        assert.is.equal("focused", focus_gate.resolve({ chat = "focused" }).chat)
        assert.is_false(focus_gate.inert(focus_gate.resolve({ chat = "focused" })))
    end)

    it("ignores an unknown chat policy with a warning", function()
        local cfg
        local messages = warnings_of(function()
            cfg = focus_gate.resolve({ chat = "yes" })
        end)
        assert.is.equal(false, cfg.chat)
        assert.is.equal(1, #messages)
    end)

    it("clamps settle_ms to a non-negative integer", function()
        assert.is.equal(0, focus_gate.resolve({ settle_ms = -5 }).settle_ms)
        assert.is.equal(150, focus_gate.resolve({ settle_ms = 150.7 }).settle_ms)
    end)
end)

describe("chat_bufnr", function()
    it("names the chat of a CodeCompanion caller", function()
        local bufnr = vim.api.nvim_create_buf(false, true)
        local caller = { type = "codecompanion", codecompanion = { chat = { bufnr = bufnr } } }
        assert.is.equal(bufnr, focus_gate.chat_bufnr(caller))
        vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it("gives nil for a wiped chat and for other callers", function()
        local bufnr = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_delete(bufnr, { force = true })
        assert.is_nil(focus_gate.chat_bufnr({ type = "codecompanion", codecompanion = { chat = { bufnr = bufnr } } }))
        assert.is_nil(focus_gate.chat_bufnr({ type = "hubui", hubui = {} }))
        assert.is_nil(focus_gate.chat_bufnr({ type = "codecompanion" }))
        assert.is_nil(focus_gate.chat_bufnr(nil))
    end)
end)

describe("mode_allowed", function()
    local allowed = focus_gate._test.mode_allowed

    it("matches mode codes exactly", function()
        local cfg = focus_gate.resolve({ allow_in_modes = { "n" } })
        assert.is_true(allowed(cfg, { mode = "n", blocking = false }))
        for _, mode in ipairs({ "no", "niI", "ntT", "i" }) do
            assert.is_false(allowed(cfg, { mode = mode, blocking = false }), mode)
        end
    end)

    it("never admits a blocking mode", function()
        local cfg = focus_gate.resolve({ allow_in_modes = { "n" } })
        assert.is_false(allowed(cfg, { mode = "n", blocking = true }))
        assert.is_false(allowed(focus_gate.resolve(nil), { mode = "n", blocking = true }))
    end)

    it("admits any listed mode, blockwise visual included", function()
        local cfg = focus_gate.resolve({ allow_in_modes = { "v", "\22" } })
        assert.is_true(allowed(cfg, { mode = "\22", blocking = false }))
        assert.is_true(allowed(cfg, { mode = "v", blocking = false }))
        assert.is_false(allowed(cfg, { mode = "V", blocking = false }))
    end)

    it("admits every mode without an allow list", function()
        assert.is_true(allowed(focus_gate.resolve(nil), { mode = "i", blocking = false }))
    end)
end)

describe("wait", function()
    --- A config that holds the review back in whatever mode this process is in.
    local function never()
        return focus_gate.resolve({ allow_in_modes = { "\19" }, settle_ms = 0 })
    end

    it("opens synchronously", function()
        local opened = false
        local handle = focus_gate.wait({ config = focus_gate.resolve(nil) }, function()
            opened = true
        end)
        assert.is_true(opened)
        assert.is_false(handle.waiting)
        -- Closing or cancelling an opened gate is a no-op.
        handle:close()
        handle:cancel("late")
    end)

    it("holds back a review in a mode that is not allowed", function()
        local opened = false
        local handle = focus_gate.wait({ config = never() }, function()
            opened = true
        end)
        assert.is_false(opened)
        assert.is_true(handle.waiting)
        assert.is.equal("blocked", handle.state.phase)
        assert.is.equal(1, focus_gate._test.active_count())
        handle:close()
    end)

    it("reports a cancel once, and leaves nothing behind", function()
        local reasons = {}
        local handle = focus_gate.wait({ config = never() }, function()
            error("must not open")
        end, function(reason)
            reasons[#reasons + 1] = reason
        end)
        local augroup = handle.state.augroup

        handle:cancel("gone")
        handle:cancel("again")
        handle:close()

        assert.are.same({ "gone" }, reasons)
        assert.is_false(handle.waiting)
        assert.is_nil(handle.state)
        assert.is.equal(0, focus_gate._test.active_count())
        assert.is_false(pcall(vim.api.nvim_get_autocmds, { group = augroup }))
    end)

    it("closes silently", function()
        local aborted = false
        local handle = focus_gate.wait({ config = never() }, function() end, function()
            aborted = true
        end)
        handle:close()
        handle:cancel("late")
        assert.is_false(aborted)
        assert.is.equal(0, focus_gate._test.active_count())
    end)
end)

describe("on_turn_stop", function()
    local function never()
        return focus_gate.resolve({ allow_in_modes = { "\19" }, settle_ms = 0 })
    end

    it("gives nothing to a caller that cannot be stopped", function()
        assert.is_nil(focus_gate.on_turn_stop(nil))
        assert.is_nil(focus_gate.on_turn_stop({ type = "hubui" }))
    end)

    it("registers once per call and cancels the review waiting when the turn stops", function()
        local jobs, reasons = {}, {}
        local on_gate = focus_gate.on_turn_stop({
            register_job = function(job)
                jobs[#jobs + 1] = job
            end,
        })
        local function waiting(name)
            return focus_gate.wait({ config = never() }, function() end, function(reason)
                reasons[#reasons + 1] = name .. ": " .. reason
            end)
        end
        assert.is.equal(0, #jobs)

        local first = waiting("first")
        on_gate(first)
        first:close()
        on_gate(waiting("second"))
        assert.is.equal(1, #jobs)

        jobs[1].kill("sigterm")
        jobs[1].kill("sigterm")
        assert.are.same({ "second: Stopped by the user." }, reasons)
        assert.is.equal(0, focus_gate._test.active_count())
    end)
end)

describe("render", function()
    local Text = require("mcphub.utils.text")
    local blocked = { phase = "blocked", reason = "insert mode" }
    local settling = { phase = "settling", settle_deadline = 1500 }

    local function pill(why)
        return "\u{E0B6}" .. why .. "\u{E0B4}"
    end

    local function text(state, label, now, stale)
        return table.concat(
            vim.tbl_map(function(chunk)
                return chunk[1]
            end, focus_gate.render(state, label, now or 0, stale)),
            ""
        )
    end

    it("names the file and its hunks in Comment, and why it waits in a pill", function()
        local chunks = focus_gate.render(blocked, { name = "a.lua", hunks = 1 }, 0)
        assert.are.same({
            { "🚫 a.lua", "Comment" },
            { " · ", "Comment" },
            { "1 hunk", "Comment" },
            { " · ", "Comment" },
            { "\u{E0B6}", Text.highlights.error },
            { "insert mode", Text.highlights.error_fill },
            { "\u{E0B4}", Text.highlights.error },
        }, chunks)
        assert.is.equal(
            "🚫 a.lua · 3 hunks · " .. pill("insert mode"),
            text(blocked, { name = "a.lua", hunks = 3 })
        )
    end)

    it("shows the batch part only for a batch, in Directory", function()
        local label = { name = "a.lua", hunks = 3, batch = { 2, 3 } }
        assert.are.same({ Text.icons.file .. " 2/3", "Directory" }, focus_gate.render(blocked, label, 0)[5])
        assert.is.equal(
            "🚫 a.lua · 3 hunks · " .. Text.icons.file .. " 2/3 · " .. pill("insert mode"),
            text(blocked, label)
        )
        assert.is_nil(text(blocked, { name = "a.lua", hunks = 3 }):find(Text.icons.file, 1, true))
    end)

    it("shows each reason as given", function()
        for _, why in ipairs({ "chat unfocused", "chat in other tab", "operator pending" }) do
            local shown = text({ phase = "blocked", reason = why }, { name = "a.lua", hunks = 1 })
            assert.is.equal("🚫 a.lua · 1 hunk · " .. pill(why), shown)
        end
    end)

    it("counts down while settling", function()
        assert.is.equal("⏳ a.lua · 1 hunk · opens in 0.5s", text(settling, { name = "a.lua", hunks = 1 }, 1000))
        assert.is.equal("⏳ a.lua · 1 hunk · opens in 0.0s", text(settling, { name = "a.lua", hunks = 1 }, 2000))
    end)

    it("flags a stale target in a pill, also while settling", function()
        local label = { name = "a.lua", hunks = 1 }
        local chunks = focus_gate.render(blocked, label, 0, true)
        assert.are.same({ "file changed, may not apply", Text.highlights.error_fill }, chunks[#chunks - 1])
        assert.is.equal(
            "🚫 a.lua · 1 hunk · " .. pill("insert mode") .. " · " .. pill("file changed, may not apply"),
            text(blocked, label, 0, true)
        )
        assert.is.equal(
            "⏳ a.lua · 1 hunk · opens in 0.5s · " .. pill("file changed, may not apply"),
            text(settling, label, 1000, true)
        )
    end)

    it("counts the decided hunks once the review is open", function()
        local label = { name = "a.lua", hunks = 3, batch = { 2, 3 } }
        assert.is.equal(
            "📝 a.lua · 1/3 hunks · " .. Text.icons.file .. " 2/3",
            text({ phase = "reviewing", decided = 1 }, label)
        )
        assert.is.equal(
            "📝 a.lua · 0/1 hunk",
            text({ phase = "reviewing", decided = 0 }, { name = "a.lua", hunks = 1 })
        )
    end)
end)

describe("staleness", function()
    local buffer = require("mcphub.native.neovim.utils.buffer")

    it("is never reported for a review that opens at once", function()
        local handle = focus_gate.wait({ config = focus_gate.resolve(nil) }, function() end)
        assert.is_false(handle.stale())
    end)

    it("flags the target while it differs from the reference, re-hashing only on change", function()
        local bufnr = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "A", "B" })
        local handle = focus_gate.wait({
            config = focus_gate.resolve({ allow_in_modes = { "\19" }, settle_ms = 0 }),
            bufnr = bufnr,
            reference_hash = buffer.content_hash(bufnr),
        }, function() end)

        local real_hash, hashes = buffer.content_hash, 0
        buffer.content_hash = function(...)
            hashes = hashes + 1
            return real_hash(...)
        end
        local ok, err = pcall(function()
            assert.is_false(handle.stale())
            handle.stale()
            assert.is.equal(1, hashes)

            vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { "A edited" })
            assert.is_true(handle.stale())
            handle.stale()
            assert.is.equal(2, hashes)

            vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { "A" })
            assert.is_false(handle.stale())
            assert.is.equal(3, hashes)
        end)
        buffer.content_hash = real_hash
        handle:close()
        vim.api.nvim_buf_delete(bufnr, { force = true })
        if not ok then
            error(err, 0)
        end
    end)
end)

describe("count_hunks", function()
    it("counts the hunks the review shows", function()
        local function block(id, found, found_lines, replace_lines)
            return {
                block_id = id,
                location_result = { found = found, found_lines = found_lines, start_line = 1 },
                replace_lines = replace_lines,
                applied_start_line = 1,
            }
        end
        local old = { "1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12" }
        local new = vim.deepcopy(old)
        new[1], new[12] = "one", "twelve"
        local blocks = {
            block("b1", true, old, new),
            block("b2", true, { "x" }, { "y" }),
            block("b3", false, {}, { "z" }),
        }
        local ui = edit_ui.new(nil)
        ui.state = { located_blocks = blocks }
        assert.is.equal(3, edit_ui.count_hunks(blocks))
        assert.is.equal(#ui:_generate_hunk_blocks(), edit_ui.count_hunks(blocks))
    end)
end)

describe("EditUI seam", function()
    --- Start an `EditUI` session with `_open` stubbed out, so no window is touched,
    --- while spying on `focus_gate.wait`.
    ---@param ui_config table?
    ---@param opts table
    ---@return { opened: boolean, waited: table?, ui: EditUI }
    local function start(ui_config, opts)
        local seen = { opened = false }
        local real_wait = focus_gate.wait
        focus_gate.wait = function(gate_opts, on_open, on_abort)
            seen.waited = gate_opts
            return real_wait(gate_opts, on_open, on_abort)
        end
        local ui = edit_ui.new(ui_config)
        seen.ui = ui
        ui._open = function()
            seen.opened = true
        end
        local ok, err = pcall(ui.start_interactive_editing, ui, opts)
        focus_gate.wait = real_wait
        if not ok then
            error(err, 0)
        end
        return seen
    end

    it("routes an interactive review through the gate with its chat and config", function()
        local seen = start({ defer = { chat = "focused", settle_ms = 10 } }, { interactive = true, chat_bufnr = 7 })
        -- No window shows buffer 7, so the gate holds the review back until cleanup.
        assert.is_false(seen.opened)
        assert.is_true(seen.ui.gate.waiting)
        seen.ui:cleanup()
        assert.is.equal(0, focus_gate._test.active_count())
        assert.is_not_nil(seen.waited)
        assert.is.equal(7, seen.waited.chat_bufnr)
        assert.is.equal("focused", seen.waited.config.chat)
        assert.is.equal(10, seen.waited.config.settle_ms)
    end)

    it("never holds back an auto-approved edit", function()
        local seen = start({ defer = { chat = "focused" } }, { interactive = false, chat_bufnr = 7 })
        assert.is_true(seen.opened)
        assert.is_nil(seen.waited)
    end)

    --- A `show_pending` that records the rows it is given and how often each was removed.
    local function recorder()
        local rows = {}
        return rows,
            function(row)
                local entry = { row = row, removed = 0 }
                rows[#rows + 1] = entry
                return {
                    remove = function()
                        entry.removed = entry.removed + 1
                    end,
                }
            end
    end

    local function row_text(entry)
        return table.concat(
            vim.tbl_map(function(chunk)
                return chunk[1]
            end, entry.row.render(vim.uv.now())),
            ""
        )
    end

    it("shows no row for an auto-approved edit", function()
        local rows, show = recorder()
        start({ defer = { chat = "focused" } }, { interactive = false, chat_bufnr = 7, show_pending = show })
        assert.is.equal(0, #rows)
    end)

    it("shows the row while the review waits and removes it once on cleanup", function()
        local rows, show = recorder()
        local seen = start(
            { defer = { chat = "focused", settle_ms = 10 } },
            { interactive = true, chat_bufnr = 7, show_pending = show }
        )
        assert.is.equal(1, #rows)
        assert.is_truthy(row_text(rows[1]):find("🚫 review · 0 hunks · ", 1, true))
        seen.ui:cleanup()
        seen.ui:cleanup()
        assert.is.equal(1, rows[1].removed)
    end)

    it("resolves the defaults when no defer is configured", function()
        local ui = edit_ui.new(nil)
        assert.is_true(focus_gate.inert(ui.defer))
        assert.is.equal(2000, ui.defer.settle_ms)
    end)
end)
