--- Tests that an edit is never applied to a buffer that changed after its blocks
--- were located.
---
--- The race these cases reproduce: an interactive `apply_edit` batch reviews its
--- files one after another, so a later file sits waiting while the user reviews an
--- earlier one, and the user may edit it meanwhile. The planner validated every
--- fingerprint before the first review opened, so without a second check the later
--- file's blocks would land on line numbers that no longer mean what they meant.
---
--- Staleness is decided by content, not `changedtick`: an edit that was undone
--- again leaves the file applicable.
---
--- @module "tests.native.neovim.files.apply_edit.test_stale_apply"

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

function _G.probe.start(input)
    local engine = require("mcphub.native.neovim.files.apply_edit.engine")
    local ui_backend = require("mcphub.native.neovim.files.apply_edit.ui_backend")
    _G.probe.response = nil
    engine.apply(input, ui_backend.drive_file, function(r)
        _G.probe.response = r
    end)
end

function _G.probe.await_response()
    vim.wait(5000, function()
        return _G.probe.response ~= nil
    end, 10)
    return _G.probe.response
end

--- Wait until the current window shows `path` with the review's keymaps set.
function _G.probe.await_review(path)
    return vim.wait(5000, function()
        return vim.fn.resolve(vim.api.nvim_buf_get_name(0)) == path and vim.fn.maparg("ga", "n", false, true).buffer == 1
    end, 10)
end

function _G.probe.lines(path)
    return vim.api.nvim_buf_get_lines(vim.fn.bufnr(path), 0, -1, false)
end

function _G.probe.set_lines(path, start, finish, lines)
    vim.api.nvim_buf_set_lines(vim.fn.bufnr(path), start, finish, false, lines)
end
]]

local tmpdir

local T = MiniTest.new_set({
    hooks = {
        pre_case = function()
            child.setup()
            child.lua(PROBE)
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

local function fingerprint(path)
    return child.lua_get("_G.probe.fingerprint(...)", { path })
end

local function replace(path, fp, line, content)
    return {
        kind = "replace_range",
        path = path,
        baseline_fingerprint = fp,
        anchor = { by = "line_range", start = line, ["end"] = line },
        content = content,
        indent = "preserve",
    }
end

--- Start an interactive two-file batch and wait for the first file's review.
---@return string one, string two
local function start_batch(extra_two_ops)
    local one = fixture("one.txt", { "A", "B", "C" })
    local two = fixture("two.txt", { "X", "dup", "Y", "dup", "Z" })
    local fp_one, fp_two = fingerprint(one), fingerprint(two)
    local ops = { replace(one, fp_one, 1, "A2"), replace(two, fp_two, 1, "X2") }
    for _, op in ipairs(extra_two_ops and extra_two_ops(two, fp_two) or {}) do
        ops[#ops + 1] = op
    end
    child.lua_func(function(input)
        _G.probe.start(input)
    end, { ops = ops })
    eq(child.lua_get("_G.probe.await_review(...)", { one }), true)
    return one, two
end

local function accept_review()
    child.type_keys("ga")
end

local function await_response()
    return child.lua_get("_G.probe.await_response()")
end

T["the shared hash agrees with the fingerprinted content"] = function()
    local cases = child.lua_get([[(function()
        local buffer = require("mcphub.native.neovim.utils.buffer")
        local file_record = require("mcphub.native.neovim.files.apply_edit.file_record")
        local out = {}
        for _, spec in ipairs({ { lines = { "a", "b" }, eol = true }, { lines = { "a", "b" }, eol = false }, { lines = { "" }, eol = true } }) do
            local b = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_buf_set_lines(b, 0, -1, false, spec.lines)
            vim.bo[b].endofline = spec.eol
            out[#out + 1] = { buffer.content_hash(b), vim.fn.sha256(file_record.from_buffer(b).content) }
        end
        return out
    end)()]])
    for _, pair in ipairs(cases) do
        eq(pair[1], pair[2])
        eq(#pair[1], 64)
    end
end

T["a file edited while an earlier file is in review is refused, and the earlier file still applies"] = function()
    local one, two = start_batch()
    child.lua_func(function(p)
        _G.probe.set_lines(p, 4, 5, { "Z edited" })
    end, two)

    accept_review()
    local response = await_response()

    eq(response.status, "partial")
    eq(#response.applied, 1)
    eq(response.applied[1].path, one)
    eq(#response.failed, 1)
    eq(response.failed[1].reason, "stale_fingerprint")
    eq(response.failed[1].op_index, 2)
    eq(response.failed[1].live_fingerprint, fingerprint(two))
    eq(child.fn.readfile(one), { "A2", "B", "C" })
    -- Neither the user's edit nor the file on disk was touched.
    eq(child.lua_get("_G.probe.lines(...)", { two }), { "X", "dup", "Y", "dup", "Z edited" })
    eq(child.fn.readfile(two), { "X", "dup", "Y", "dup", "Z" })
end

T["an op spanning several blocks is reported once"] = function()
    local _, two = start_batch(function(path, fp)
        return {
            {
                kind = "delete_range",
                path = path,
                baseline_fingerprint = fp,
                anchor = { by = "unique_text", text = "dup", occurrence = "all" },
            },
        }
    end)
    child.lua_func(function(p)
        _G.probe.set_lines(p, 2, 3, { "Y edited" })
    end, two)

    accept_review()
    local response = await_response()

    local op_indices = {}
    for _, failure in ipairs(response.failed) do
        op_indices[#op_indices + 1] = failure.op_index
    end
    table.sort(op_indices)
    eq(op_indices, { 2, 3 })
end

T["an edit that was undone again leaves the file applicable"] = function()
    local one, two = start_batch()
    local tick_before = child.lua_get("vim.b[vim.fn.bufnr(...)].changedtick", { two })
    child.lua_func(function(p)
        _G.probe.set_lines(p, 4, 5, { "Z edited" })
        _G.probe.set_lines(p, 4, 5, { "Z" })
    end, two)
    eq(child.lua_get("vim.b[vim.fn.bufnr(...)].changedtick", { two }) > tick_before, true)

    accept_review()
    eq(child.lua_get("_G.probe.await_review(...)", { two }), true)
    accept_review()
    local response = await_response()

    eq(response.status, "applied")
    eq(#response.applied, 2)
    eq(child.fn.readfile(one), { "A2", "B", "C" })
    eq(child.fn.readfile(two), { "X2", "dup", "Y", "dup", "Z" })
end

T["an untouched batch applies every file"] = function()
    local one, two = start_batch()

    accept_review()
    eq(child.lua_get("_G.probe.await_review(...)", { two }), true)
    accept_review()
    local response = await_response()

    eq(response.status, "applied")
    eq(#response.failed, 0)
    eq(child.fn.readfile(one), { "A2", "B", "C" })
    eq(child.fn.readfile(two), { "X2", "dup", "Y", "dup", "Z" })
end

T["EditUI refuses a stale target before showing it"] = function()
    local path = fixture("stale.txt", { "A", "B", "C" })
    child.cmd("edit " .. vim.fn.fnameescape(path))
    child.cmd("enew")
    local before = child.api.nvim_get_current_win()
    local before_buf = child.api.nvim_get_current_buf()

    local result = child.lua_func(function(p)
        local buffer = require("mcphub.native.neovim.utils.buffer")
        local EditUI = require("mcphub.native.neovim.files.edit_file.edit_ui")
        local bufnr = vim.fn.bufnr(p)
        local reference = buffer.content_hash(bufnr)
        vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { "A edited" })

        local out = {}
        local function start(extra)
            local ui = EditUI.new({})
            ui:start_interactive_editing(vim.tbl_extend("force", {
                interactive = true,
                file_path = p,
                original_content = "A\nB\nC\n",
                located_blocks = {},
                reference_hash = reference,
                on_complete = function()
                    out.completed = true
                end,
                on_cancel = function(reason)
                    out.cancelled = reason
                end,
            }, extra or {}))
        end
        start({
            on_stale = function(live)
                out.live = live
            end,
        })
        start()
        return out
    end, path)

    eq(result.live, "A edited\nB\nC\n")
    eq(type(result.cancelled), "string")
    eq(result.completed, nil)
    eq(child.api.nvim_get_current_win(), before)
    eq(child.api.nvim_get_current_buf(), before_buf)
    eq(child.lua_get("_G.probe.lines(...)", { path }), { "A edited", "B", "C" })
end

return T
