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

    it("resolves the defaults when no defer is configured", function()
        local ui = edit_ui.new(nil)
        assert.is_true(focus_gate.inert(ui.defer))
        assert.is.equal(2000, ui.defer.settle_ms)
    end)
end)
