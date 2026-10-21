--- Tests that an interactive review configured with `ui.defer` waits for an allowed
--- mode, for the invoking chat to be visible or focused, and for a settle period
--- before it takes focus.
---
--- Every case runs in a child Neovim, driving real mode, window and tab changes. A
--- scratch buffer stands in for the CodeCompanion chat.
--- Waiting is observed by polling the child, never by sleeping in it: the settle
--- period is short, and each case only asserts what holds before it can elapse
--- or after it certainly has.
---
--- @module "tests.native.neovim.files.edit_file.test_edit_ui_defer"

local Helpers = require("tests.helpers")
local eq = MiniTest.expect.equality

local child = Helpers.new_child_neovim()

--- Child-side helpers, installed once per case. `child.lua_func` cannot carry
--- upvalues across the RPC boundary, so the helpers live in the child's `_G`.
local PROBE = [[
_G.probe = {}
vim.o.shortmess = vim.o.shortmess .. "WF"

function _G.probe.fingerprint(path)
    local record = assert(require("mcphub.native.neovim.files.apply_edit.file_record").read(path))
    return require("mcphub.native.neovim.files.apply_edit.fingerprint").compute(record.content)
end

--- Start an interactive `apply_edit` with `defer` as its `ui.defer`.
function _G.probe.apply_edit(input, defer, chat_bufnr)
    local engine = require("mcphub.native.neovim.files.apply_edit.engine")
    local ui_backend = require("mcphub.native.neovim.files.apply_edit.ui_backend")
    _G.probe.response = nil
    engine.apply(input, function(request, file_cb)
        request.chat_bufnr = chat_bufnr
        return ui_backend.drive_file(request, file_cb, { ui = { defer = defer } })
    end, function(r)
        _G.probe.response = r
    end)
end

--- Start an interactive `edit_file` with `defer` as its `ui.defer`.
function _G.probe.edit_file(path, diff, defer)
    local EditSession = require("mcphub.native.neovim.files.edit_file.edit_session")
    _G.probe.response = nil
    EditSession.new(path, diff, { ui = { defer = defer } }):start({
        interactive = true,
        on_success = function(summary)
            _G.probe.response = { ok = true, summary = summary }
        end,
        on_error = function(err)
            _G.probe.response = { ok = false, error = err }
        end,
    })
end

function _G.probe.await_response()
    vim.wait(5000, function()
        return _G.probe.response ~= nil
    end, 10)
    return _G.probe.response
end

--- Whether the current window shows `path` with the review's keymaps set.
function _G.probe.in_review(path)
    return vim.fn.resolve(vim.api.nvim_buf_get_name(0)) == path and vim.fn.maparg("ga", "n", false, true).buffer == 1
end

function _G.probe.await_review(path, timeout)
    return vim.wait(timeout or 5000, function()
        return _G.probe.in_review(path)
    end, 10)
end

--- Autocmds of every gate that is still waiting.
function _G.probe.gate_autocmds()
    return #vim.tbl_filter(function(au)
        return (au.group_name or ""):find("^mcphub_focus_gate_") ~= nil
    end, vim.api.nvim_get_autocmds({ event = "ModeChanged" }))
end

function _G.probe.active_gates()
    return require("mcphub.native.neovim.files.edit_file.focus_gate")._test.active_count()
end

--- A stand-in for a CodeCompanion chat: a scratch buffer, which the review never
--- picks to show a file in.
function _G.probe.make_chat()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(bufnr, "[chat]")
    return bufnr
end

--- Wait on a bare gate, so that a case can read why it waits.
function _G.probe.gate(defer, chat_bufnr)
    local focus_gate = require("mcphub.native.neovim.files.edit_file.focus_gate")
    _G.probe.opened = false
    _G.probe.handle = focus_gate.wait({ config = focus_gate.resolve(defer), chat_bufnr = chat_bufnr }, function()
        _G.probe.opened = true
    end)
end

--- "open", the reason the gate waits, or "settling".
function _G.probe.reason()
    if _G.probe.opened then
        return "open"
    end
    local state = _G.probe.handle.state
    return state and (state.reason or state.phase) or "closed"
end

function _G.probe.await_reason(expected)
    vim.wait(2000, function()
        return _G.probe.reason() == expected
    end, 10)
    return _G.probe.reason()
end
]]

local SETTLE_MS = 50

local tmpdir

local T = MiniTest.new_set({
    hooks = {
        pre_case = function()
            child.setup()
            child.lua(PROBE)
            -- A modifiable buffer to type in; the initial one is read-only.
            child.cmd("enew")
            local dir = child.lua_get("vim.fn.tempname()")
            child.fn.mkdir(dir, "p")
            -- Canonical, so paths compare equal to the buffer names behind macOS's `/var` symlink.
            tmpdir = child.fn.resolve(dir)
        end,
        post_case = function()
            child.stop()
            vim.fn.delete(tmpdir, "rf")
        end,
    },
})

local function fixture(name, lines)
    local path = tmpdir .. "/" .. name
    child.fn.writefile(lines, path)
    return path
end

--- Start an interactive `apply_edit` replacing line 2 of a fresh fixture.
---@param defer table? The `ui.defer` to review with
---@param chat_bufnr integer? The chat that asks for the edit
---@return string path
local function start_apply_edit(defer, chat_bufnr)
    local path = fixture("target.txt", { "A", "B", "C" })
    local fp = child.lua_get("_G.probe.fingerprint(...)", { path })
    child.lua_func(function(input, d, c)
        _G.probe.apply_edit(input, d, c)
    end, {
        ops = {
            {
                kind = "replace_range",
                path = path,
                baseline_fingerprint = fp,
                anchor = { by = "line_range", start = 2, ["end"] = 2 },
                content = "B2",
                indent = "preserve",
            },
        },
    }, defer, chat_bufnr)
    return path
end

local function in_review(path)
    return child.lua_get("_G.probe.in_review(...)", { path })
end

local function await_review(path, timeout)
    return child.lua_get("_G.probe.await_review(...)", { path, timeout })
end

--- Let the child's event loop run for `ms`, so that a review that should not
--- open has every chance to.
local function idle(ms)
    child.lua("vim.wait(...)", { ms })
end

local NORMAL_ONLY = { allow_in_modes = { "n" }, settle_ms = SETTLE_MS }

T["without defer, a review opens before the call returns"] = function()
    local path = start_apply_edit(nil)
    eq(in_review(path), true)
end

T["a review allowed on entry opens at once, without waiting to settle"] = function()
    local path = start_apply_edit({ allow_in_modes = { "n" }, settle_ms = 60000 })
    eq(in_review(path), true)
    eq(child.lua_get("_G.probe.active_gates()"), 0)
end

T["insert mode holds a review back until Normal mode has settled"] = function()
    local before = child.api.nvim_get_current_buf()
    child.type_keys("i")
    local path = start_apply_edit(NORMAL_ONLY)

    idle(4 * SETTLE_MS)
    eq(child.api.nvim_get_current_buf(), before)
    eq(child.api.nvim_get_mode().mode, "i")

    child.type_keys("<Esc>")
    eq(in_review(path), false)
    eq(await_review(path), true)
    eq(child.api.nvim_win_get_cursor(0)[1], 2)
end

T["re-entering a blocked mode restarts the settle period"] = function()
    local settle_ms = 400
    child.type_keys("i")
    local path = start_apply_edit({ allow_in_modes = { "n" }, settle_ms = settle_ms })

    -- Back into insert mode well within the settle period.
    child.type_keys("<Esc>", "i")
    idle(settle_ms + 200)
    eq(in_review(path), false)

    child.type_keys("<Esc>")
    local released = vim.uv.hrtime()
    eq(await_review(path), true)
    eq((vim.uv.hrtime() - released) / 1e6 >= settle_ms - 50, true)
end

T["completion returns to the window that was current when the review opened"] = function()
    local path = fixture("target.txt", { "A", "B", "C" })
    child.cmd("edit " .. vim.fn.fnameescape(path))
    local review_win = child.api.nvim_get_current_win()
    -- A window the review never picks: it only shows files in normal buffers.
    child.cmd("vsplit")
    child.cmd("enew")
    child.bo.buftype = "nofile"
    local moved_to = child.api.nvim_get_current_win()
    child.api.nvim_set_current_win(review_win)

    child.type_keys("i")
    local fp = child.lua_get("_G.probe.fingerprint(...)", { path })
    child.lua_func(function(input, d)
        _G.probe.apply_edit(input, d)
    end, {
        ops = {
            {
                kind = "replace_range",
                path = path,
                baseline_fingerprint = fp,
                anchor = { by = "line_range", start = 2, ["end"] = 2 },
                content = "B2",
                indent = "preserve",
            },
        },
    }, NORMAL_ONLY)
    child.api.nvim_set_current_win(moved_to)
    child.type_keys("<Esc>")

    eq(await_review(path), true)
    eq(child.api.nvim_get_current_win(), review_win)
    child.type_keys("ga")
    eq(child.lua_get("_G.probe.await_response()").status, "applied")
    eq(child.api.nvim_get_current_win(), moved_to)
end

T["apply_edit refuses a target edited while its review waited"] = function()
    child.type_keys("i")
    local path = start_apply_edit(NORMAL_ONLY)
    child.lua_func(function(p)
        vim.api.nvim_buf_set_lines(vim.fn.bufnr(p), 0, 1, false, { "A edited" })
    end, path)
    child.type_keys("<Esc>")

    local response = child.lua_get("_G.probe.await_response()")
    eq(response.status, "failed")
    eq(response.failed[1].reason, "stale_fingerprint")
    eq(response.failed[1].live_content, "A edited\nB\nC\n")
    eq(child.fn.win_findbuf(child.fn.bufnr(path)), {})
    eq(child.fn.readfile(path), { "A", "B", "C" })
end

T["edit_file reports an error for a target edited while its review waited"] = function()
    local path = fixture("target.txt", { "A", "B", "C" })
    child.type_keys("i")
    child.lua_func(function(p, d)
        _G.probe.edit_file(p, "<<<<<<< SEARCH\nB\n=======\nB2\n>>>>>>> REPLACE", d)
    end, path, NORMAL_ONLY)
    child.lua_func(function(p)
        vim.api.nvim_buf_set_lines(vim.fn.bufnr(p), 0, 1, false, { "A edited" })
    end, path)
    child.type_keys("<Esc>")

    local response = child.lua_get("_G.probe.await_response()")
    eq(response.ok, false)
    eq(response.error:find("changed before the edit could be applied", 1, true) ~= nil, true)
    eq(child.fn.win_findbuf(child.fn.bufnr(path)), {})
end

T["a gate leaves no autocmd or timer behind once the review opens"] = function()
    child.type_keys("i")
    local path = start_apply_edit(NORMAL_ONLY)
    eq(child.lua_get("_G.probe.active_gates()"), 1)
    eq(child.lua_get("_G.probe.gate_autocmds()") > 0, true)

    child.type_keys("<Esc>")
    eq(await_review(path), true)
    eq(child.lua_get("_G.probe.active_gates()"), 0)
    eq(child.lua_get("_G.probe.gate_autocmds()"), 0)
end

local function make_chat()
    return child.lua_get("_G.probe.make_chat()")
end

local function gate(defer, chat_bufnr)
    child.lua_func(function(d, c)
        _G.probe.gate(d, c)
    end, defer, chat_bufnr)
end

local function reason()
    return child.lua_get("_G.probe.reason()")
end

local function await_reason(expected)
    return child.lua_get("_G.probe.await_reason(...)", { expected })
end

--- Show `chat` in a vertical split and return to the window that was current.
---@return integer chat_win
local function split_chat(chat)
    child.cmd("vertical sbuffer " .. chat)
    local chat_win = child.api.nvim_get_current_win()
    child.cmd("wincmd p")
    return chat_win
end

T["chat = visible waits while the chat is only in another tab"] = function()
    local chat = make_chat()
    child.cmd("tabnew")
    child.api.nvim_win_set_buf(0, chat)
    child.cmd("tabprevious")

    gate({ chat = "visible", settle_ms = SETTLE_MS }, chat)
    eq(reason(), "chat in other tab")

    child.cmd("tabnext")
    eq(await_reason("open"), "open")
end

T["chat = visible waits while the chat is in no window, and not for focus"] = function()
    local chat = make_chat()
    gate({ chat = "visible", settle_ms = SETTLE_MS }, chat)
    eq(reason(), "chat hidden")

    local chat_win = split_chat(chat)
    eq(await_reason("open"), "open")
    eq(child.api.nvim_get_current_win() ~= chat_win, true)
end

T["chat = focused waits for the chat window first, then for an allowed mode"] = function()
    local chat = make_chat()
    local chat_win = split_chat(chat)
    child.type_keys("i")

    gate({ chat = "focused", allow_in_modes = { "n" }, settle_ms = SETTLE_MS }, chat)
    -- Both conditions fail; the chat is named first.
    eq(reason(), "chat unfocused")

    child.api.nvim_set_current_win(chat_win)
    eq(await_reason("insert mode"), "insert mode")

    child.type_keys("<Esc>")
    eq(await_reason("open"), "open")
end

T["chat = focused leaves a caller without a chat to the mode condition alone"] = function()
    local defer = { chat = "focused", allow_in_modes = { "n" }, settle_ms = SETTLE_MS }
    gate(defer, nil)
    eq(reason(), "open")

    child.type_keys("i")
    gate(defer, nil)
    eq(reason(), "insert mode")
end

T["a review requested while typing in the chat opens after Esc, and completion returns to the chat"] = function()
    local chat = make_chat()
    local chat_win = split_chat(chat)
    child.api.nvim_set_current_win(chat_win)
    child.type_keys("i")

    local path = start_apply_edit({ chat = "focused", allow_in_modes = { "n" }, settle_ms = SETTLE_MS }, chat)
    idle(4 * SETTLE_MS)
    eq(child.api.nvim_get_current_win(), chat_win)

    child.type_keys("<Esc>")
    eq(await_review(path), true)
    child.type_keys("ga")
    eq(child.lua_get("_G.probe.await_response()").status, "applied")
    eq(child.api.nvim_get_current_win(), chat_win)
end

return T
