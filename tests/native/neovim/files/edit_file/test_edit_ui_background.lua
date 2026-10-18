--- Tests that auto-approved edits apply without touching any window.
---
--- Every case runs in a child Neovim laid out with two windows. It records the
--- layout (each window's buffer and cursor, and the current window) and counts
--- `WinEnter` events, then compares both after an auto-approved `edit_file`,
--- `write_file` or `apply_edit`: an auto-approved edit has nothing to show the
--- user, so it must leave the layout exactly as it found it.
---
--- @module "tests.native.neovim.files.edit_file.test_edit_ui_background"

local Helpers = require("tests.helpers")
local eq = MiniTest.expect.equality

local child = Helpers.new_child_neovim()

--- Child-side helpers, installed once per case. `child.lua_func` cannot carry
--- upvalues across the RPC boundary, so the helpers live in the child's `_G`.
local PROBE = [[
_G.probe = { win_enters = 0 }
vim.o.shortmess = vim.o.shortmess .. "WF"
vim.api.nvim_create_autocmd("WinEnter", {
    callback = function()
        _G.probe.win_enters = _G.probe.win_enters + 1
    end,
})

function _G.probe.layout()
    local wins = {}
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        wins[#wins + 1] = {
            win = win,
            buf = vim.api.nvim_win_get_buf(win),
            cursor = vim.api.nvim_win_get_cursor(win),
        }
    end
    return { current = vim.api.nvim_get_current_win(), wins = wins, win_enters = _G.probe.win_enters }
end

function _G.probe.edit_session(path, diff, opts)
    local EditSession = require("mcphub.native.neovim.files.edit_file.edit_session")
    local result
    local session = EditSession.new(path, diff, nil)
    session:start(vim.tbl_extend("force", {
        interactive = false,
        on_success = function(summary)
            result = { ok = true, summary = summary }
        end,
        on_error = function(err)
            result = { ok = false, error = err }
        end,
    }, opts or {}))
    vim.wait(5000, function()
        return result ~= nil
    end, 10)
    return result
end

function _G.probe.fingerprint(path)
    local record = assert(require("mcphub.native.neovim.files.apply_edit.file_record").read(path))
    return require("mcphub.native.neovim.files.apply_edit.fingerprint").compute(record.content)
end

function _G.probe.apply_edit(input)
    local engine = require("mcphub.native.neovim.files.apply_edit.engine")
    local ui_backend = require("mcphub.native.neovim.files.apply_edit.ui_backend")
    local response
    engine.apply(input, function(request, file_cb)
        request.interactive = false
        return ui_backend.drive_file(request, file_cb)
    end, function(r)
        response = r
    end)
    vim.wait(5000, function()
        return response ~= nil
    end, 10)
    return response
end
]]

local tmpdir

local T = MiniTest.new_set({
    hooks = {
        pre_case = function()
            child.setup()
            child.lua(PROBE)
            tmpdir = child.lua_get("vim.fn.tempname()")
            child.fn.mkdir(tmpdir, "p")
            -- Two windows, the right one current.
            child.cmd("vsplit")
            child.cmd("wincmd l")
        end,
        post_case = function()
            child.stop()
            vim.fn.delete(tmpdir, "rf")
        end,
    },
})

--- Write `lines` to `name` under the case's temp dir, without loading it.
---@param name string
---@param lines string[]
---@return string path
local function fixture(name, lines)
    local path = tmpdir .. "/" .. name
    child.fn.writefile(lines, path)
    return path
end

local function layout()
    return child.lua_get("_G.probe.layout()")
end

--- Assert the layout is exactly `before`, with no window entered since.
local function expect_untouched(before)
    local after = layout()
    eq(after.current, before.current)
    eq(after.wins, before.wins)
    eq(after.win_enters, before.win_enters)
end

local REPLACE_B = "<<<<<<< SEARCH\nB\n=======\nB2\n>>>>>>> REPLACE"

T["edit_file on a file that is not loaded leaves every window alone"] = function()
    local path = fixture("unloaded.txt", { "A", "B", "C" })
    local before = layout()

    local result = child.lua_func(function(p, diff)
        return _G.probe.edit_session(p, diff)
    end, path, REPLACE_B)

    eq(result.ok, true)
    expect_untouched(before)
    eq(child.fn.readfile(path), { "A", "B2", "C" })
    -- Loading it for the edit must not put it in the buffer list either.
    eq(child.lua_get("vim.bo[vim.fn.bufnr(...)].buflisted", { path }), false)
end

T["edit_file on a file shown in another window moves neither focus nor its cursor"] = function()
    local path = fixture("shown.txt", { "A", "B", "C" })
    child.cmd("wincmd h")
    child.cmd("edit " .. vim.fn.fnameescape(path))
    child.api.nvim_win_set_cursor(0, { 3, 0 })
    child.cmd("wincmd l")
    local before = layout()

    local result = child.lua_func(function(p, diff)
        return _G.probe.edit_session(p, diff)
    end, path, REPLACE_B)

    eq(result.ok, true)
    expect_untouched(before)
    eq(child.fn.readfile(path), { "A", "B2", "C" })
end

T["write_file into a missing directory creates it without a window"] = function()
    local path = tmpdir .. "/new/dir/created.txt"
    local before = layout()

    local result = child.lua_func(function(p)
        return _G.probe.edit_session(p, "", { replace_file_content = "one\ntwo" })
    end, path)

    eq(result.ok, true)
    expect_untouched(before)
    eq(child.fn.readfile(path), { "one", "two" })
end

T["the hidden buffer still gets its filetype"] = function()
    local path = fixture("module.lua", { "local A = 1", "B", "return A" })

    child.lua_func(function(p, diff)
        return _G.probe.edit_session(p, diff)
    end, path, REPLACE_B)

    eq(child.lua_get("vim.bo[vim.fn.bufnr(...)].filetype", { path }), "lua")
end

T["apply_edit across two files leaves every window alone and accepts every op"] = function()
    local one = fixture("one.txt", { "A", "B", "C" })
    local two = fixture("two.txt", { "X", "Y", "Z" })
    local fp_one = child.lua_get("_G.probe.fingerprint(...)", { one })
    local fp_two = child.lua_get("_G.probe.fingerprint(...)", { two })
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
    local before = layout()

    local response = child.lua_func(function(input)
        return _G.probe.apply_edit(input)
    end, {
        ops = {
            replace(one, fp_one, 1, "A2"),
            replace(one, fp_one, 3, "C2"),
            replace(two, fp_two, 2, "Y2"),
        },
    })

    eq(response.status, "applied")
    eq(#response.applied, 3)
    eq(#response.rejected, 0)
    -- Diagnostics are still collected for a buffer no window shows.
    for _, file in ipairs(response.files) do
        eq(type(file.diagnostic_counts), "table")
    end
    expect_untouched(before)
    eq(child.fn.readfile(one), { "A2", "B", "C2" })
    eq(child.fn.readfile(two), { "X", "Y2", "Z" })
end

T["an interactive review still opens the file"] = function()
    local path = fixture("interactive.txt", { "A", "B", "C" })

    child.lua_func(function(p, diff)
        local EditSession = require("mcphub.native.neovim.files.edit_file.edit_session")
        _G.session = EditSession.new(p, diff, nil)
        _G.session:start({ interactive = true })
    end, path, REPLACE_B)

    -- Resolved, because macOS temp paths sit behind the `/var` -> `/private/var` symlink.
    eq(child.fn.resolve(child.api.nvim_buf_get_name(0)), child.fn.resolve(path))
    eq(child.api.nvim_win_get_cursor(0)[1], 2)
end

return T
