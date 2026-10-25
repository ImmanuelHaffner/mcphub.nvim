--- Where `view_image` looks for an image: the path resolved against the working
--- directory of the chat that asked for it, and whether it lies inside that
--- directory.
local M = {}

---@class MCPHub.ViewImagePath
---@field given string The path as the model passed it
---@field real string Its realpath
---@field cwd string The realpath of the chat's working directory
---@field inside boolean Whether `real` lies below `cwd`

--- The working directory of the chat that made the call, as CodeCompanion's
--- memory tool sees it, so both tools agree on what "inside" means; the global
--- cwd when the caller is not a chat or CodeCompanion cannot tell.
---@param caller table? `req.caller` of a native tool call
---@return string
function M.chat_cwd(caller)
    local chat = type(caller) == "table"
        and caller.type == "codecompanion"
        and type(caller.codecompanion) == "table"
        and caller.codecompanion.chat
    if type(chat) == "table" then
        local ok, memory = pcall(require, "codecompanion.memory")
        if ok and type(memory) == "table" and type(memory.chat_cwd) == "function" then
            local cwd_ok, cwd = pcall(memory.chat_cwd, chat)
            if cwd_ok and type(cwd) == "string" and cwd ~= "" then
                return cwd
            end
        end
    end
    return vim.fn.getcwd(-1, -1)
end

--- Whether `path` lies below `dir`. Both should be realpaths; the trailing
--- separator keeps `/a/bc` from counting as inside `/a/b`.
---@param path string
---@param dir string
---@return boolean
function M.is_inside(path, dir)
    local prefix = dir:sub(-1) == "/" and dir or dir .. "/"
    return path:sub(1, #prefix) == prefix
end

--- Resolve the path the model passed: `~` is expanded, a relative path is taken
--- against the chat's working directory, and symlinks are followed, so a link
--- that points outside counts as outside.
---@param path string
---@param caller table? `req.caller` of a native tool call
---@return MCPHub.ViewImagePath|nil
---@return string|nil err
function M.resolve(path, caller)
    if type(path) ~= "string" or path == "" then
        return nil, "path is required"
    end
    local cwd = M.chat_cwd(caller)
    local abs = vim.fs.normalize(path)
    if vim.fn.isabsolutepath(abs) == 0 then
        abs = vim.fs.joinpath(cwd, abs)
    end
    local real = vim.uv.fs_realpath(abs)
    if not real then
        return nil, ("%s does not exist"):format(path)
    end
    local stat = vim.uv.fs_stat(real)
    if not stat or stat.type ~= "file" then
        return nil, ("%s is not a regular file"):format(path)
    end
    local real_cwd = vim.uv.fs_realpath(cwd) or vim.fs.normalize(cwd)
    return { given = path, real = real, cwd = real_cwd, inside = M.is_inside(real, real_cwd) }
end

return M
