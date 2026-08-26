local Path = require("plenary.path")
local deprecation = require("mcphub.utils.deprecation")

--- Soft-deprecated in favour of `read_with_fingerprint`. Still fully functional
--- and still registered; disable it from the MCPHub UI if unwanted. The notice
--- itself lives in `mcphub.utils.deprecation`, which the UI consults too, so the
--- wording cannot drift between the two.
local READ_FILE_DEPRECATED = deprecation.READ_FILE

---Resolve `path` to a normalised absolute path.
---Relative paths resolve against Neovim's current working directory.
---@param path string
---@return string
local function absolute(path)
    return vim.fs.normalize(Path:new(path):absolute())
end

---Count the entries beneath `path`, recursively, for verifying a copy.
---@param path string absolute path
---@return integer
local function count_entries(path)
    local n = 0
    for _ in vim.fs.dir(path, { depth = 64 }) do
        n = n + 1
    end
    return n
end

---Delete `path`, file or directory, and confirm it is gone.
---
---Deliberately avoids `Path:rm`: with `recursive = false` it calls `uv.fs_unlink`
---even on a directory (EISDIR, discarded), and with `recursive = true` it feeds a
---plain file to `scandir`, which matches nothing. Both fail silently and return
---nothing at all, so a caller cannot distinguish them from success.
---@param path string absolute path
---@return boolean ok
---@return string? err
local function remove(path)
    local stat = vim.uv.fs_stat(path)
    if not stat then
        return true
    end
    if stat.type == "directory" then
        vim.fn.delete(path, "rf")
    else
        vim.uv.fs_unlink(path)
    end
    if vim.uv.fs_stat(path) then
        return false, "could not delete " .. path
    end
    return true
end

---Move `src` to `dst`, creating missing parent directories and falling back to
---copy+delete when the two paths live on different filesystems.
---
---Deliberately avoids `Path:rename`, which returns `uv.fs_rename`'s status rather
---than raising: a caller that ignores the return value cannot tell a completed
---move from a failed one, which is exactly how this tool used to lie.
---@param src string absolute source path
---@param dst string absolute destination path
---@return boolean ok
---@return string detail how the move was performed, or why it failed
local function move(src, dst)
    local parent = vim.fs.dirname(dst)
    if vim.fn.isdirectory(parent) == 0 then
        pcall(vim.fn.mkdir, parent, "p")
        if vim.fn.isdirectory(parent) == 0 then
            return false, "Could not create destination directory: " .. parent
        end
    end

    local renamed, rename_err, errname = vim.uv.fs_rename(src, dst)
    if renamed then
        return true, "renamed"
    end
    if errname ~= "EXDEV" then
        return false, rename_err or string.format("Could not move %s to %s", src, dst)
    end

    -- EXDEV: renaming across filesystems is impossible, so copy the payload over
    -- and only drop the source once the copy is confirmed complete.
    local source = Path:new(src)
    local is_dir = source:is_dir()
    local expected = is_dir and count_entries(src) or nil
    local copied, copy_err
    if is_dir then
        copied, copy_err = pcall(function()
            source:copy({ destination = dst, recursive = true, parents = true, override = false })
        end)
    else
        copied, copy_err = vim.uv.fs_copyfile(src, dst)
    end
    if not copied then
        return false, string.format("Cross-device move failed while copying: %s", copy_err or "unknown error")
    end

    -- Never delete the source on the strength of a copy we have not checked.
    if is_dir then
        local arrived = count_entries(dst)
        if arrived ~= expected then
            return false,
                string.format(
                    "Cross-device copy of %s is incomplete (%d of %d entries); source left untouched",
                    src,
                    arrived,
                    expected
                )
        end
    elseif not vim.uv.fs_stat(dst) then
        return false, "Cross-device copy reported success but " .. dst .. " does not exist"
    end

    local removed, rm_err = remove(src)
    if not removed then
        return false, string.format("Copied to %s but %s", dst, rm_err or ("could not remove source " .. src))
    end
    return true, "copied across filesystems"
end

---Re-point loaded buffers from `src` onto `dst` after a completed move.
---`src` may be a file or a directory; buffers beneath a moved directory follow it.
---@param src string absolute source path
---@param dst string absolute destination path
---@return string[] moved "old -> new" for each buffer that followed the file
---@return string[] unsaved new names of buffers left holding unwritten changes
local function repoint_buffers(src, dst)
    local moved, unsaved = {}, {}
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == "" then
            local name = vim.fs.normalize(vim.api.nvim_buf_get_name(buf))
            local new_name
            if name == src then
                new_name = dst
            elseif name:sub(1, #src + 1) == src .. "/" then
                new_name = dst .. name:sub(#src + 1)
            end
            if new_name and pcall(vim.api.nvim_buf_set_name, buf, new_name) then
                if vim.bo[buf].modified then
                    -- Reloading would discard the unwritten changes, so leave them be.
                    table.insert(unsaved, new_name)
                else
                    -- Safe only because the destination is verified to exist by now;
                    -- reloading a buffer whose file is missing empties it.
                    vim.api.nvim_buf_call(buf, function()
                        pcall(function()
                            vim.cmd("silent! edit!")
                        end)
                    end)
                end
                table.insert(moved, string.format("%s -> %s", name, new_name))
            end
        end
    end
    return moved, unsaved
end

---Basic file operations tools
---@type MCPTool[]
local file_tools = {
    {
        name = "read_file",
        description = deprecation.banner(READ_FILE_DEPRECATED) .. "Read contents of a file",
        inputSchema = {
            type = "object",
            properties = {
                path = {
                    type = "string",
                    description = "Path to the file to read",
                },
                start_line = {
                    type = "number",
                    description = "Start reading from this line (1-based index)",
                    default = 1,
                },
                end_line = {
                    type = "number",
                    description = "Read until this line (inclusive)",
                    default = -1,
                },
            },
            required = { "path" },
        },
        handler = function(req, res)
            local params = req.params
            deprecation.notify_once(READ_FILE_DEPRECATED)
            local p = Path:new(params.path)

            if not p:exists() then
                return res:error("File not found: " .. params.path)
            end
            if params.start_line and params.end_line then
                params.start_line = tonumber(params.start_line)
                params.end_line = tonumber(params.end_line)
                if not params.start_line or not params.end_line then
                    return res:error("`start_line` and `end_line` must be numbers")
                end
                local extracted = {}
                local current_line = 0

                for line in p:iter() do
                    current_line = current_line + 1
                    if
                        current_line >= params.start_line and (params.end_line == -1 or current_line <= params.end_line)
                    then
                        table.insert(extracted, string.format("%4d │ %s", current_line, line))
                    end
                    if params.end_line ~= -1 and current_line > params.end_line then
                        break
                    end
                end
                return res:text(table.concat(extracted, "\n")):send()
            else
                return res:text(p:read()):send()
            end
        end,
    },
    {
        name = "move_item",
        description = "Move or rename a file/directory. Creates missing parent directories, refuses to overwrite an "
            .. "existing destination, verifies the move actually happened, and re-points any loaded buffer at the "
            .. "new path.",
        inputSchema = {
            type = "object",
            properties = {
                path = {
                    type = "string",
                    description = "Source path",
                },
                new_path = {
                    type = "string",
                    description = "Destination path",
                },
            },
            required = { "path", "new_path" },
        },
        handler = function(req, res)
            local src = absolute(req.params.path)
            local dst = absolute(req.params.new_path)

            if not vim.uv.fs_stat(src) then
                return res:error("Source path not found: " .. req.params.path)
            end
            if src == dst then
                return res:error("Source and destination are the same path: " .. src)
            end
            if vim.uv.fs_stat(dst) then
                return res:error("Destination already exists: " .. req.params.new_path)
            end

            local ok, detail = move(src, dst)
            if not ok then
                return res:error(detail)
            end

            -- Confirm the outcome instead of trusting it. `uv.fs_rename` reports
            -- failure by return value, not by raising, so an unchecked move used to
            -- yield a cheerful success message with nothing moved.
            if not vim.uv.fs_stat(dst) then
                return res:error(string.format("Reported no error, but %s does not exist", dst))
            end
            if vim.uv.fs_stat(src) then
                return res:error(string.format("Reported no error, but source %s is still present", src))
            end

            local lines = { string.format("Moved %s to %s (%s)", src, dst, detail) }
            local moved, unsaved = repoint_buffers(src, dst)
            for _, entry in ipairs(moved) do
                table.insert(lines, "  re-pointed buffer: " .. entry)
            end
            for _, name in ipairs(unsaved) do
                table.insert(lines, "  NOTE: " .. name .. " has unsaved changes; write it to keep them")
            end
            return res:text(table.concat(lines, "\n")):send()
        end,
    },
    {
        name = "read_multiple_files",
        description = "Read contents of multiple files in parallel. Prefer this tool when you need to view contents of more than one file at once.",
        inputSchema = {
            type = "object",
            properties = {
                paths = {
                    type = "array",
                    items = {
                        type = "string",
                    },
                    description = "Array of file paths to read",
                    examples = {
                        "file1.txt",
                        "/home/path/to/file2.txt",
                    },
                },
            },
            required = { "paths" },
        },
        handler = function(req, res)
            local params = req.params
            local results = {}
            local errors = {}

            if not params.paths or not vim.islist(params.paths) then
                return res:error("`paths` must be an array of strings. Provided " .. vim.inspect(params.paths))
            end

            if #params.paths == 0 then
                return res:error("`paths` array cannot be empty")
            end

            for i, path in ipairs(params.paths) do
                local p = Path:new(path)

                if not p:exists() then
                    table.insert(errors, string.format("File %d not found: %s", i, path))
                else
                    local success, content = pcall(function()
                        return p:read()
                    end)

                    if success then
                        table.insert(results, {
                            path = path,
                            content = content,
                            index = i,
                        })
                    else
                        table.insert(errors, string.format("Failed to read file %d (%s): %s", i, path, content))
                    end
                end
            end

            -- Format the response
            local response_parts = {}

            if #results > 0 then
                local file_word = #results == 1 and "file" or "files"
                table.insert(response_parts, string.format("Successfully read %d %s:\n", #results, file_word))

                for _, result in ipairs(results) do
                    table.insert(response_parts, string.format("=== File %d: %s ===", result.index, result.path))
                    table.insert(response_parts, result.content)
                    table.insert(response_parts, "") -- Empty line separator
                end
            end

            if #errors > 0 then
                if #results > 0 then
                    table.insert(response_parts, "\nErrors encountered:")
                end
                for _, error in ipairs(errors) do
                    table.insert(response_parts, "ERROR: " .. error)
                end
            end

            if #results == 0 and #errors > 0 then
                return res:error(table.concat(errors, "\n"))
            end

            return res:text(table.concat(response_parts, "\n")):send()
        end,
    },
    {
        name = "delete_items",
        description = "Delete multiple files or directories",
        inputSchema = {
            type = "object",
            properties = {
                paths = {
                    type = "array",
                    items = {
                        type = "string",
                    },
                    description = "Array of paths to delete",
                },
            },
            required = { "paths" },
        },
        handler = function(req, res)
            local params = req.params
            local results = {}
            local errors = {}

            if not params.paths or not vim.islist(params.paths) then
                return res:error("paths must be an array of strings")
            end

            if #params.paths == 0 then
                return res:error("paths array cannot be empty")
            end

            for i, path in ipairs(params.paths) do
                local p = Path:new(path)

                if not p:exists() then
                    table.insert(errors, string.format("Path %d not found: %s", i, path))
                else
                    local success, err = remove(absolute(path))

                    if success then
                        table.insert(results, {
                            path = path,
                            index = i,
                        })
                    else
                        table.insert(errors, string.format("Failed to delete path %d (%s): %s", i, path, err))
                    end
                end
            end

            -- Format the response
            local response_parts = {}

            if #results > 0 then
                local item_word = #results == 1 and "item" or "items"
                table.insert(response_parts, string.format("Successfully deleted %d %s:", #results, item_word))

                for _, result in ipairs(results) do
                    table.insert(response_parts, string.format("  %d. %s", result.index, result.path))
                end
            end

            if #errors > 0 then
                if #results > 0 then
                    table.insert(response_parts, "\nErrors encountered:")
                end
                for _, error in ipairs(errors) do
                    table.insert(response_parts, "ERROR: " .. error)
                end
            end

            if #results == 0 and #errors > 0 then
                return res:error(table.concat(errors, "\n"))
            end

            return res:text(table.concat(response_parts, "\n")):send()
        end,
    },
}

return file_tools
