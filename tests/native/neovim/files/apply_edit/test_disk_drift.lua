--- Tests that an edit to a buffer whose file changed on disk behind Neovim's back
--- neither prompts nor reports an edit that never reached the disk.
---
--- Reads are buffer-first, and Neovim only notices a file changing on disk through
--- `checktime`, which skips every buffer not shown in a window. A buffer this tool
--- loaded hidden was therefore never brought up to date, and a shown one only on the
--- next `checktime` trigger. A plan made against such a buffer passed its fingerprint
--- check, and the `:write` that ends the edit stopped at "WARNING: The file has been
--- changed since reading it!!! Do you really want to write to it (y/n)?". Under a UI,
--- the `FocusGained` of the user switching over to answer ran `checktime` on the now
--- modified buffer and added the W12 dialog on top: choosing Load reloaded the buffer
--- from disk in the middle of the write, so answering `y` wrote the disk content back
--- without the edit, and the tool reported the edit as applied.
---
--- A headless child answers the write prompt itself, so these cases pin the
--- preconditions: no prompt, nothing reported applied that is not on disk.
---
--- @module "tests.native.neovim.files.apply_edit.test_disk_drift"

local Helpers = require("tests.helpers")
local eq = MiniTest.expect.equality

local child = Helpers.new_child_neovim()

local PROBE = [[
_G.probe = {}

function _G.probe.fingerprint(path)
    local record = assert(require("mcphub.native.neovim.files.apply_edit.file_record").read(path))
    return require("mcphub.native.neovim.files.apply_edit.fingerprint").compute(record.content)
end

--- Change the file without Neovim noticing, with an mtime its records cannot match.
function _G.probe.change_on_disk(path, lines)
    vim.fn.writefile(lines, path)
    local future = os.time() + 10
    vim.uv.fs_utime(path, future, future)
end

--- Start an auto-approved apply on the next tick, so that the RPC request returns
--- even if the apply blocks on a prompt.
function _G.probe.start(input)
    local engine = require("mcphub.native.neovim.files.apply_edit.engine")
    local ui_backend = require("mcphub.native.neovim.files.apply_edit.ui_backend")
    _G.probe.response = nil
    vim.schedule(function()
        engine.apply(input, function(request, file_cb)
            request.interactive = false
            return ui_backend.drive_file(request, file_cb)
        end, function(r)
            _G.probe.response = r
        end)
    end)
end

function _G.probe.await_response()
    vim.wait(5000, function()
        return _G.probe.response ~= nil
    end, 10)
    return _G.probe.response
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

local function replace_first_line(path, fp, content)
    return {
        ops = {
            {
                kind = "replace_range",
                path = path,
                baseline_fingerprint = fp,
                anchor = { by = "line_range", start = 1, ["end"] = 1 },
                content = content,
                indent = "preserve",
            },
        },
    }
end

local function apply(input)
    child.lua_func(function(i)
        _G.probe.start(i)
    end, input)
    return child.lua_get("_G.probe.await_response()")
end

local function prompted()
    return child.lua_get("vim.fn.execute('messages')"):find("changed since reading it", 1, true) ~= nil
end

local function buffer_lines(path)
    return child.lua_get("vim.api.nvim_buf_get_lines(vim.fn.bufnr(...), 0, -1, false)", { path })
end

--- One case per way a buffer comes to be loaded: hidden, as the tool loads it, and
--- shown in a window the user is not in.
for _, shown in ipairs({ false, true }) do
    local where = shown and "a shown buffer" or "a hidden buffer"

    T["an edit planned against " .. where .. " whose file changed on disk is refused without a prompt"] = function()
        local path = fixture("drift.txt", { "A", "B", "C" })
        if shown then
            child.cmd("edit " .. vim.fn.fnameescape(path) .. " | vsplit | enew")
        end
        local fp = child.lua_get("_G.probe.fingerprint(...)", { path })
        child.lua_func(function(p)
            _G.probe.change_on_disk(p, { "A", "B", "C", "D external" })
        end, path)

        local response = apply(replace_first_line(path, fp, "A edited"))

        eq(prompted(), false)
        eq(type(response), "table")
        eq(response.status, "failed")
        eq(#response.applied, 0)
        eq(response.failed[1].reason, "stale_fingerprint")
        -- The external change survives, and the buffer now shows it.
        eq(child.fn.readfile(path), { "A", "B", "C", "D external" })
        eq(buffer_lines(path), { "A", "B", "C", "D external" })
        eq(child.lua_get("vim.bo[vim.fn.bufnr(...)].modified", { path }), false)
    end
end

T["a read after the file changed on disk shows the disk, and an edit against it lands"] = function()
    local path = fixture("reread.txt", { "A", "B", "C" })
    child.lua_get("_G.probe.fingerprint(...)", { path })
    child.lua_func(function(p)
        _G.probe.change_on_disk(p, { "A", "B", "C", "D external" })
    end, path)

    local fp = child.lua_get("_G.probe.fingerprint(...)", { path })
    local response = apply(replace_first_line(path, fp, "A edited"))

    eq(prompted(), false)
    eq(response.status, "applied")
    eq(child.fn.readfile(path), { "A edited", "B", "C", "D external" })
end

T["a write that fails is not reported as applied"] = function()
    local path = fixture("readonly.txt", { "A", "B", "C" })
    local fp = child.lua_get("_G.probe.fingerprint(...)", { path })
    child.fn.setfperm(path, "r--r--r--")

    local response = apply(replace_first_line(path, fp, "A edited"))

    eq(type(response), "table")
    eq(#response.applied, 0)
    eq(response.status, "failed")
    eq(response.failed[1].reason, "write_failed")
    eq(response.files[1].readback, nil)
    eq(child.fn.readfile(path), { "A", "B", "C" })
end

T["unsaved changes over a file changed on disk are neither read nor edited, nor overwritten"] = function()
    local path = fixture("conflict.txt", { "A", "B", "C" })
    local fp = child.lua_get("_G.probe.fingerprint(...)", { path })
    child.lua_func(function(p)
        vim.api.nvim_buf_set_lines(vim.fn.bufnr(p), 2, 3, false, { "C mine" })
        _G.probe.change_on_disk(p, { "A", "B", "C", "D external" })
    end, path)

    local read = child.lua_func(function(p)
        return require("mcphub.native.neovim.files.apply_edit.read").read_with_fingerprint(p)
    end, path)
    eq(read.failed[1].reason, "disk_conflict")

    -- Asked twice: `checktime` reports a change only once, the conflict must persist.
    for _ = 1, 2 do
        local response = apply(replace_first_line(path, fp, "A edited"))
        eq(response.status, "failed")
        eq(response.failed[1].reason, "disk_conflict")
    end

    eq(prompted(), false)
    eq(buffer_lines(path), { "A", "B", "C mine" })
    eq(child.fn.readfile(path), { "A", "B", "C", "D external" })

    -- Once the user discards their changes, the buffer follows the disk again.
    child.lua_func(function(p)
        vim.api.nvim_buf_call(vim.fn.bufnr(p), function()
            vim.cmd("silent undo")
        end)
    end, path)
    eq(child.lua_get("_G.probe.fingerprint(...)", { path }) ~= fp, true)
    eq(buffer_lines(path), { "A", "B", "C", "D external" })
end

return T
