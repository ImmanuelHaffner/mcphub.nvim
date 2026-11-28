local M = {}

---@class FileInfo
---@field name string # File name or path
---@field type string # File type (file/directory/link/etc)
---@field size number # File size in bytes
---@field modified number # Last modification timestamp
---@field symlink_target string|nil # If type is 'link', the target path

---@class DirectoryInfo
---@field path string # Current directory path
---@field is_git boolean # Whether the directory is a git repository
---@field files FileInfo[] # List of files in the directory

---@param path? string # Directory path to scan (defaults to current working directory)
---@return DirectoryInfo
---@param path? string # Directory path to scan (defaults to current working directory)
---@return DirectoryInfo
function M.get_directory_info(path)
    path = path or vim.loop.cwd()

    -- Normalize path separators
    path = vim.fn.fnamemodify(path, ":p:h")

    -- Check if the specified path is a git repo
    -- Use -C flag to specify directory instead of cd command for better cross-platform support
    local is_git = vim.fn
        .system(string.format("git -C %s rev-parse --is-inside-work-tree 2>/dev/null", vim.fn.shellescape(path)))
        :match("true")
    local files = {}

    if is_git then
        -- Use git ls-files for git-aware listing in the specified directory
        local git_files = vim.fn.systemlist(
            string.format("git -C %s ls-files --cached --others --exclude-standard", vim.fn.shellescape(path))
        )
        for _, file in ipairs(git_files) do
            -- Build full path using cross-platform path joining
            local full_path = vim.fs.joinpath and vim.fs.joinpath(path, file) or (path .. "/" .. file)

            -- Use lstat to detect symlinks without following them
            local lstat = vim.loop.fs_lstat(full_path)
            if lstat then
                local file_info = {
                    name = file,
                    type = lstat.type,
                    size = lstat.size,
                    modified = lstat.mtime.sec,
                }

                -- If it's a symlink, get the target path
                if lstat.type == "link" then
                    local target = vim.loop.fs_readlink(full_path)
                    if target then
                        file_info.symlink_target = target
                    end
                end

                table.insert(files, file_info)
            end
        end
    else
        -- Fallback to regular directory listing
        local handle = vim.loop.fs_scandir(path)
        if handle then
            while true do
                local name, type = vim.loop.fs_scandir_next(handle)
                if not name then
                    break
                end

                -- Build full path using cross-platform path joining
                local full_path = vim.fs.joinpath and vim.fs.joinpath(path, name) or (path .. "/" .. name)

                -- Use lstat to detect symlinks without following them
                local lstat = vim.loop.fs_lstat(full_path)
                if lstat then
                    local file_info = {
                        name = name,
                        type = type or lstat.type,
                        size = lstat.size,
                        modified = lstat.mtime.sec,
                    }

                    -- If it's a symlink, get the target path
                    if lstat.type == "link" then
                        local target = vim.loop.fs_readlink(full_path)
                        if target then
                            file_info.symlink_target = target
                        end
                    end

                    table.insert(files, file_info)
                end
            end
        end
    end

    return {
        path = path,
        is_git = is_git,
        files = files,
    }
end
---@class BufferInfo
---@field name string
---@field filename string
---@field windows number[]
---@field winnr number
---@field cursor_pos number[]
---@field filetype string
---@field line_count number
---@field is_visible boolean
---@field is_modified boolean
---@field is_loaded boolean
---@field lastused number
---@field bufnr number

---@class EditorInfo
---@field last_active BufferInfo
---@field buffers BufferInfo[]

---@return EditorInfo
function M.get_editor_info()
    local buffers = vim.fn.getbufinfo({ buflisted = 1 })
    local valid_buffers = {}
    local last_active = nil
    local max_lastused = 0

    for _, buf in ipairs(buffers) do
        -- Only include valid files (non-empty name and empty buftype)
        local buftype = vim.api.nvim_buf_get_option(buf.bufnr, "buftype")
        if buf.name ~= "" and buftype == "" then
            local buffer_info = {
                bufnr = buf.bufnr,
                name = buf.name,
                filename = buf.name,
                is_visible = #buf.windows > 0,
                is_modified = buf.changed == 1,
                is_loaded = buf.loaded == 1,
                lastused = buf.lastused,
                windows = buf.windows,
                winnr = buf.windows[1], -- Primary window showing this buffer
            }

            -- Add cursor info for currently visible buffers
            if buffer_info.is_visible then
                local win = buffer_info.winnr
                local cursor = vim.api.nvim_win_get_cursor(win)
                buffer_info.cursor_pos = cursor
            end

            -- Add additional buffer info
            buffer_info.filetype = vim.api.nvim_buf_get_option(buf.bufnr, "filetype")
            buffer_info.line_count = vim.api.nvim_buf_line_count(buf.bufnr)

            table.insert(valid_buffers, buffer_info)

            -- Track the most recently used buffer
            if buf.lastused > max_lastused then
                max_lastused = buf.lastused
                last_active = buffer_info
            end
        end
    end

    -- If no valid buffers found, provide default last_active
    if not last_active and #valid_buffers > 0 then
        last_active = valid_buffers[1]
    end

    return {
        last_active = last_active,
        buffers = valid_buffers,
    }
end

---@param file_path string The path to the file to find
---@return BufferInfo|nil The buffer info if found, nil otherwise
function M.find_buffer(file_path)
    local bufs = M.get_editor_info().buffers
    for _, buf in ipairs(bufs) do
        if buf.filename == file_path then
            return buf
        end
    end
    return nil
end

--- Load a file into a buffer without showing it in any window. Loading runs the
--- usual read pipeline, filetype detection included, so LSP clients still attach.
--- A file that does not exist yet yields an empty buffer named after it.
---@param file_path string The path to the file to load
---@return integer|nil bufnr The loaded buffer, or nil if it could not be loaded
function M.load_hidden(file_path)
    local bufnr = vim.fn.bufadd(vim.fn.fnamemodify(file_path, ":p"))
    if bufnr == 0 then
        return nil
    end
    if not vim.api.nvim_buf_is_loaded(bufnr) and not pcall(vim.fn.bufload, bufnr) then
        return nil
    end
    return bufnr
end

--- A buffer's content as the bytes `:write` would produce, `'fileformat'` aside: lines
--- joined by `\n`, with a final `\n` iff `'endofline'` is set. `apply_edit` fingerprints
--- this string, so anything comparing against a fingerprinted read must use it too.
---@param bufnr integer A loaded buffer
---@return string content
---@return boolean endofline
function M.normalised_content(bufnr)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local endofline = vim.bo[bufnr].endofline
    local content = table.concat(lines, "\n")
    if endofline and #lines > 0 then
        content = content .. "\n"
    end
    return content, endofline
end

--- Full sha256 of `normalised_content(bufnr)`. Comparing content rather than
--- `changedtick` means an edit that was undone again counts as no change.
---@param bufnr integer A loaded buffer
---@return string hash 64 lowercase hex characters
function M.content_hash(bufnr)
    return vim.fn.sha256((M.normalised_content(bufnr)))
end

--- Remember that `bufnr` holds changes made against a version of its file that is no
--- longer on disk, until it is read or written again. Needed because `:checktime` reports
--- a change once: it records the new timestamp, so asking again finds nothing.
---@param bufnr integer
local function mark_conflict(bufnr)
    vim.b[bufnr].mcphub_disk_conflict = true
    local group = vim.api.nvim_create_augroup("mcphub_disk_conflict_" .. bufnr, { clear = true })
    vim.api.nvim_create_autocmd({ "BufReadPost", "BufWritePost", "BufUnload" }, {
        group = group,
        buffer = bufnr,
        callback = function()
            pcall(function()
                vim.b[bufnr].mcphub_disk_conflict = nil
            end)
            pcall(vim.api.nvim_del_augroup_by_id, group)
        end,
    })
end

--- Bring a loaded buffer up to date with its file, without a prompt.
---
--- Neovim notices a file changing on disk only through `checktime`, which skips every
--- buffer not shown in a window: a buffer loaded hidden keeps the content it was loaded
--- with for good, and a shown one until the next check. Reading such a buffer lies about
--- the file, and writing it stops at "The file has been changed since reading it" — or,
--- if a reload slips in while that prompt waits, writes the file back without the edit.
---
--- A buffer without changes is reloaded. One with changes is left alone and reported as a
--- conflict, which it stays until it is read or written again, or its changes are undone.
--- The check is Neovim's own (`:checktime {bufnr}`), with a `FileChangedShell` autocmd
--- answering in place of the W11/W12 dialogs.
---@param bufnr integer A loaded buffer
---@return "unchanged"|"reloaded"|"conflict"|"deleted"
function M.sync_with_disk(bufnr)
    if
        not vim.api.nvim_buf_is_loaded(bufnr)
        or vim.bo[bufnr].buftype ~= ""
        or vim.api.nvim_buf_get_name(bufnr) == ""
    then
        return "unchanged"
    end
    if vim.b[bufnr].mcphub_disk_conflict then
        if vim.bo[bufnr].modified then
            return "conflict"
        end
        -- The changes were undone; the timestamp is already recorded, so reload by hand.
        vim.b[bufnr].mcphub_disk_conflict = nil
        vim.api.nvim_buf_call(bufnr, function()
            vim.cmd("silent edit!")
        end)
        return "reloaded"
    end

    local tick = vim.b[bufnr].changedtick
    local reason
    local group = vim.api.nvim_create_augroup("mcphub_sync_with_disk", { clear = true })
    vim.api.nvim_create_autocmd("FileChangedShell", {
        group = group,
        buffer = bufnr,
        callback = function()
            reason = vim.v.fcs_reason
            vim.v.fcs_choice = (reason == "conflict" or reason == "deleted") and "" or "reload"
        end,
    })
    -- With a count, `:checktime` checks that buffer at once, shown or not; without one it
    -- would skip hidden buffers, and postpone the check when not typed.
    local ok, err = pcall(vim.cmd, "checktime " .. bufnr)
    pcall(vim.api.nvim_del_augroup_by_id, group)
    if not ok then
        error(err, 0)
    end

    if reason == "conflict" then
        mark_conflict(bufnr)
        return "conflict"
    elseif reason == "deleted" then
        return "deleted"
    end
    -- `'autoread'` reloads an unchanged buffer without asking the autocmd.
    return vim.b[bufnr].changedtick ~= tick and "reloaded" or "unchanged"
end

---Open file in editor and get target window
---@param file_path string The path to the file to open
---@return number|nil The buffer number of the opened file, or nil if not found
function M.open_file_in_editor(file_path)
    local abs_path = vim.fn.fnamemodify(file_path, ":p")

    local function safe_edit(file)
        local ok = pcall(vim.cmd.edit, vim.fn.fnameescape(file))
        if not ok then
            vim.cmd.enew()
            vim.cmd.file(file)
        end
    end

    -- Try to find existing window with the file
    for _, winid in ipairs(vim.api.nvim_list_wins()) do
        local bufnr = vim.api.nvim_win_get_buf(winid)
        local buf_name = vim.api.nvim_buf_get_name(bufnr)
        if buf_name == abs_path then
            vim.api.nvim_set_current_win(winid)
            return vim.api.nvim_get_current_buf()
        end
    end

    local editor_info = M.get_editor_info()
    -- Try to use last active buffer's window if available
    if editor_info and editor_info.last_active then
        local last_active = editor_info.last_active
        if last_active.winnr and vim.api.nvim_win_is_valid(last_active.winnr) then
            vim.api.nvim_set_current_win(last_active.winnr)
            safe_edit(abs_path)
            return vim.api.nvim_get_current_buf()
        end
    end

    -- Create new window for the file
    local chat_win = vim.api.nvim_get_current_win()
    local chat_col = vim.api.nvim_win_get_position(chat_win)[2]
    local total_width = vim.o.columns

    -- Determine where to place new window based on chat position
    if chat_col > total_width / 2 then
        vim.cmd("topleft vnew") -- New window on the left
    else
        vim.cmd("botright vnew") -- New window on the right
    end

    safe_edit(abs_path)
    local bufnr = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_option(bufnr, "buflisted", true)

    return bufnr
end
return M
