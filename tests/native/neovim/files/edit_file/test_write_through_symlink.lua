--- Tests that an edit is written from the buffer it was made in when the target
--- is reached through a symlinked directory.
---
--- A buffer created while its directory does not exist yet keeps the name it was
--- given, symlinks and all, because there is nothing to resolve. Writing it with
--- `:write {file}` would then treat the canonical path as another file: a second
--- buffer appears for it, and the edited one stays `'modified'`.
---
--- @module "tests.native.neovim.files.edit_file.test_write_through_symlink"

local Helpers = require("tests.helpers")
local eq = MiniTest.expect.equality

local child = Helpers.new_child_neovim()

local tmpdir

local T = MiniTest.new_set({
    hooks = {
        pre_case = function()
            child.setup()
            tmpdir = child.lua_get("vim.fn.tempname()")
            child.fn.mkdir(tmpdir .. "/real", "p")
            child.lua("assert(vim.uv.fs_symlink(...))", { tmpdir .. "/real", tmpdir .. "/link" })
        end,
        post_case = function()
            child.stop()
            vim.fn.delete(tmpdir, "rf")
        end,
    },
})

T["write_file into a missing directory behind a symlink leaves one unmodified buffer"] = function()
    local path = tmpdir .. "/link/new/created.txt"

    local result = child.lua_func(function(p)
        local EditSession = require("mcphub.native.neovim.files.edit_file.edit_session")
        local out
        EditSession.new(p, "", nil):start({
            interactive = false,
            replace_file_content = "one\ntwo",
            on_success = function()
                out = { ok = true }
            end,
            on_error = function(err)
                out = { ok = false, error = err }
            end,
        })
        vim.wait(5000, function()
            return out ~= nil
        end, 10)
        out.buffers = {}
        for _, b in ipairs(vim.api.nvim_list_bufs()) do
            if vim.fn.resolve(vim.api.nvim_buf_get_name(b)) == vim.fn.resolve(p) then
                out.buffers[#out.buffers + 1] = { modified = vim.bo[b].modified }
            end
        end
        return out
    end, path)

    eq(result.ok, true)
    eq(result.buffers, { { modified = false } })
    eq(child.fn.readfile(path), { "one", "two" })
end

return T
