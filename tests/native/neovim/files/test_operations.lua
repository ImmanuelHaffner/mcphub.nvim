-- Tests for the basic file operations tools (`mcphub.native.neovim.files.operations`).
--
-- Run with `make test`, or just this file with
-- `make test_file FILE=tests/native/neovim/files/test_operations.lua`.
--
-- These specs exist because two of these tools used to report success without
-- doing anything. `move_item` called plenary's `Path:rename`, which returns
-- `uv.fs_rename`'s status rather than raising, discarded that status, and then
-- emitted "Moved <src> to <dst>" unconditionally -- so a move into a
-- not-yet-existing directory (ENOENT) or across filesystems (EXDEV) changed
-- nothing while claiming to have succeeded. `delete_items` called `Path:rm()`
-- with no options, whose non-recursive branch unlinks the path; on a directory
-- that fails with EISDIR, the error was discarded, and "Successfully deleted 1
-- item" was reported over an untouched tree.
--
-- Hence the shape of every spec below: a success assertion always interrogates
-- the FILESYSTEM, never merely the returned message.
local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local Response = require("mcphub.native.utils.response")
local tools = require("mcphub.native.neovim.files.operations")

--- Fixture directory for the running case, recreated per case.
local root
--- Buffers opened by the running case, wiped in `post_case`.
local scratch_buffers
--- Paths outside `root` created by the running case, removed in `post_case`.
local extra_paths

---Find a tool by name in the module's `MCPTool[]`.
---@param name string
---@return MCPTool
local function tool(name)
    for _, candidate in ipairs(tools) do
        if candidate.name == name then
            return candidate
        end
    end
    error("tool not found: " .. name)
end

---Invoke a tool handler synchronously and return its raw result table.
---A `ToolResponse` built without an output handler returns instead of calling back.
---@param name string
---@param params table
---@return table
local function call(name, params)
    -- The handler only reads `params`; supplying the rest of `ToolRequest`, and the
    -- exact response subclass, is the dispatcher's business rather than this spec's.
    ---@diagnostic disable: missing-fields, param-type-mismatch
    local result = tool(name).handler({ params = params }, Response.ToolResponse:new()).result
    ---@diagnostic enable: missing-fields, param-type-mismatch
    return result
end

---@param result table
---@return boolean
local function failed(result)
    return result.isError == true
end

---Concatenate every text chunk of a result.
---@param result table
---@return string
local function text(result)
    local parts = {}
    for _, chunk in ipairs(result.content or {}) do
        table.insert(parts, chunk.text or "")
    end
    return table.concat(parts, "\n")
end

---@param result table
---@param needle string
---@return boolean
local function mentions(result, needle)
    return text(result):find(needle, 1, true) ~= nil
end

---@param path string
---@return boolean
local function exists(path)
    return vim.uv.fs_stat(path) ~= nil
end

---Write `lines` to `path`, creating parent directories.
---@param path string
---@param lines string[]
local function fixture(path, lines)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    vim.fn.writefile(lines, path)
end

---Load `path` into a buffer without touching any window, registered for cleanup.
---@param path string
---@return integer
local function open(path)
    local buf = vim.fn.bufadd(path)
    vim.fn.bufload(buf)
    table.insert(scratch_buffers, buf)
    return buf
end

---A directory on a filesystem other than the one holding `root`, if any exists.
---Without one, the EXDEV fallback cannot be exercised at all.
---@return string?
local function other_device()
    local here = vim.uv.fs_stat(root)
    for _, candidate in ipairs({ "/dev/shm", "/run/user/" .. vim.uv.getuid() }) do
        local stat = vim.uv.fs_stat(candidate)
        if stat and here and stat.dev ~= here.dev then
            return candidate
        end
    end
    return nil
end

local T = new_set({
    hooks = {
        pre_case = function()
            root = vim.fs.normalize(vim.fn.tempname())
            vim.fn.mkdir(root, "p")
            scratch_buffers = {}
            extra_paths = {}
        end,
        post_case = function()
            for _, buf in ipairs(scratch_buffers) do
                if vim.api.nvim_buf_is_valid(buf) then
                    pcall(vim.api.nvim_buf_delete, buf, { force = true })
                end
            end
            for _, path in ipairs(extra_paths) do
                vim.fn.delete(path, "rf")
            end
            vim.fn.delete(root, "rf")
        end,
    },
})

T["move_item"] = new_set()

T["move_item"]["moves a file within an existing directory"] = function()
    fixture(root .. "/a.txt", { "one", "two" })
    local result = call("move_item", { path = root .. "/a.txt", new_path = root .. "/b.txt" })
    eq(failed(result), false)
    eq(exists(root .. "/a.txt"), false)
    eq(vim.fn.readfile(root .. "/b.txt"), { "one", "two" })
end

T["move_item"]["creates missing parent directories"] = function()
    -- The original defect: `uv.fs_rename` fails with ENOENT when the destination's
    -- parent does not exist, and nothing along the path created it.
    fixture(root .. "/a.txt", { "payload" })
    local dst = root .. "/brand/new/dir/a.txt"
    local result = call("move_item", { path = root .. "/a.txt", new_path = dst })
    eq(failed(result), false)
    eq(exists(root .. "/a.txt"), false)
    eq(vim.fn.readfile(dst), { "payload" })
end

T["move_item"]["moves a directory with its contents"] = function()
    fixture(root .. "/tree/nested/deep.txt", { "deep" })
    local result = call("move_item", { path = root .. "/tree", new_path = root .. "/moved/tree" })
    eq(failed(result), false)
    eq(exists(root .. "/tree"), false)
    eq(vim.fn.readfile(root .. "/moved/tree/nested/deep.txt"), { "deep" })
end

T["move_item"]["reports a missing source as an error"] = function()
    local result = call("move_item", { path = root .. "/ghost.txt", new_path = root .. "/b.txt" })
    eq(failed(result), true)
    eq(mentions(result, "Source path not found"), true)
end

T["move_item"]["refuses an existing destination and touches neither path"] = function()
    fixture(root .. "/a.txt", { "source" })
    fixture(root .. "/b.txt", { "destination" })
    local result = call("move_item", { path = root .. "/a.txt", new_path = root .. "/b.txt" })
    eq(failed(result), true)
    eq(vim.fn.readfile(root .. "/a.txt"), { "source" })
    eq(vim.fn.readfile(root .. "/b.txt"), { "destination" })
end

T["move_item"]["refuses a move onto itself"] = function()
    fixture(root .. "/a.txt", { "kept" })
    local result = call("move_item", { path = root .. "/a.txt", new_path = root .. "/a.txt" })
    eq(failed(result), true)
    eq(vim.fn.readfile(root .. "/a.txt"), { "kept" })
end

T["move_item"]["never claims success while the source is still in place"] = function()
    -- The regression stated as an invariant over a spread of shapes: a non-error
    -- result implies the destination exists and the source is gone.
    local moves = {
        { from = "flat.txt", to = "flat-moved.txt" },
        { from = "deep.txt", to = "a/b/c/deep.txt" },
        { from = "dir", to = "elsewhere/dir" },
    }
    for _, move in ipairs(moves) do
        if move.from == "dir" then
            fixture(root .. "/dir/inner.txt", { "inner" })
        else
            fixture(root .. "/" .. move.from, { move.from })
        end
        local src, dst = root .. "/" .. move.from, root .. "/" .. move.to
        local result = call("move_item", { path = src, new_path = dst })
        eq(failed(result), false)
        eq(exists(dst), true)
        eq(exists(src), false)
    end
end

T["move_item"]["falls back to copy+delete across filesystems"] = function()
    local elsewhere = other_device()
    if not elsewhere then
        MiniTest.skip("no second filesystem available to exercise the EXDEV path")
    end
    local dst = elsewhere .. "/mcphub-operations-test-" .. vim.fs.basename(root) .. "/moved.txt"
    table.insert(extra_paths, vim.fs.dirname(dst))
    fixture(root .. "/a.txt", { "across" })
    local result = call("move_item", { path = root .. "/a.txt", new_path = dst })
    eq(failed(result), false)
    eq(mentions(result, "copied across filesystems"), true)
    eq(exists(root .. "/a.txt"), false)
    eq(vim.fn.readfile(dst), { "across" })
end

T["move_item"]["buffers"] = new_set()

T["move_item"]["buffers"]["re-points an unmodified buffer and keeps its contents"] = function()
    local path = root .. "/clean.txt"
    fixture(path, { "clean", "second line" })
    local buf = open(path)
    local dst = root .. "/renamed/clean.txt"
    local result = call("move_item", { path = path, new_path = dst })
    eq(failed(result), false)
    eq(vim.api.nvim_buf_get_name(buf), dst)
    -- Reloading a buffer whose file is missing empties it, which is how an earlier
    -- version of this tool destroyed a note. The contents must survive the move.
    eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "clean", "second line" })
    eq(vim.bo[buf].modified, false)
    eq(mentions(result, "re-pointed buffer"), true)
end

T["move_item"]["buffers"]["keeps unsaved changes in a modified buffer"] = function()
    local path = root .. "/dirty.txt"
    fixture(path, { "on disk" })
    local buf = open(path)
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "unsaved" })
    local dst = root .. "/renamed/dirty.txt"
    local result = call("move_item", { path = path, new_path = dst })
    eq(failed(result), false)
    eq(vim.api.nvim_buf_get_name(buf), dst)
    -- Deliberately not reloaded: `edit!` would discard the unwritten line.
    eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "on disk", "unsaved" })
    eq(vim.bo[buf].modified, true)
    eq(vim.fn.readfile(dst), { "on disk" })
    eq(mentions(result, "unsaved changes"), true)
end

T["move_item"]["buffers"]["follows a buffer beneath a moved directory"] = function()
    local path = root .. "/tree/nested/deep.txt"
    fixture(path, { "deep" })
    local buf = open(path)
    local result = call("move_item", { path = root .. "/tree", new_path = root .. "/moved/tree" })
    eq(failed(result), false)
    eq(vim.api.nvim_buf_get_name(buf), root .. "/moved/tree/nested/deep.txt")
    eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "deep" })
end

T["move_item"]["buffers"]["does not mistake a shared prefix for containment"] = function()
    -- Moving `<root>/dir` must leave `<root>/dir-sibling.txt` alone: the
    -- containment test appends a separator rather than comparing raw prefixes.
    local sibling = root .. "/dir-sibling.txt"
    fixture(sibling, { "sibling" })
    local sibling_buf = open(sibling)
    fixture(root .. "/dir/inner.txt", { "inner" })
    local result = call("move_item", { path = root .. "/dir", new_path = root .. "/moved" })
    eq(failed(result), false)
    eq(vim.api.nvim_buf_get_name(sibling_buf), sibling)
end

T["delete_items"] = new_set()

T["delete_items"]["deletes a file"] = function()
    fixture(root .. "/a.txt", { "gone" })
    local result = call("delete_items", { paths = { root .. "/a.txt" } })
    eq(failed(result), false)
    eq(exists(root .. "/a.txt"), false)
end

T["delete_items"]["deletes a non-empty directory recursively"] = function()
    -- The sibling defect: `Path:rm()` unlinks, which cannot remove a directory,
    -- and the discarded EISDIR was reported as a successful deletion.
    fixture(root .. "/tree/nested/deep.txt", { "deep" })
    local result = call("delete_items", { paths = { root .. "/tree" } })
    eq(failed(result), false)
    eq(exists(root .. "/tree"), false)
end

T["delete_items"]["never claims a deletion that did not happen"] = function()
    fixture(root .. "/file.txt", { "x" })
    fixture(root .. "/dir/inner.txt", { "y" })
    local paths = { root .. "/file.txt", root .. "/dir" }
    local result = call("delete_items", { paths = paths })
    eq(failed(result), false)
    for _, path in ipairs(paths) do
        eq(exists(path), false)
    end
end

T["delete_items"]["reports a missing path as an error"] = function()
    local result = call("delete_items", { paths = { root .. "/ghost" } })
    eq(failed(result), true)
    eq(mentions(result, "not found"), true)
end

T["delete_items"]["reports the deleted and the missing side by side"] = function()
    fixture(root .. "/a.txt", { "gone" })
    local result = call("delete_items", { paths = { root .. "/a.txt", root .. "/ghost" } })
    eq(failed(result), false)
    eq(exists(root .. "/a.txt"), false)
    eq(mentions(result, "Successfully deleted 1 item"), true)
    eq(mentions(result, "ghost"), true)
end

T["delete_items"]["rejects arguments that are not a list of paths"] = function()
    ---@diagnostic disable-next-line: assign-type-mismatch
    eq(failed(call("delete_items", { paths = "not-a-list" })), true)
    eq(failed(call("delete_items", { paths = {} })), true)
end

return T
