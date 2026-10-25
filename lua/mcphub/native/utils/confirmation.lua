--- Forced confirmation for native tools that declare `confirm_if(args, ctx) → reason?`.
---
--- The approval gate asks the user and grants the call; the native server
--- refuses any call `confirm_if` objects to unless it was granted. A grant is
--- keyed on the identity of the arguments table the gate approved, which the
--- model cannot forge: it only ever produces JSON, decoded into fresh tables.
--- So a caller that skips the gate fails closed instead of bypassing it.
local M = {}

---@type table<table, true>
local granted = setmetatable({}, { __mode = "k" })

--- Directories the user approved for the rest of a chat, keyed weakly on the
--- chat so they go with it.
---@type table<table, table<string, true>>
local scopes = setmetatable({}, { __mode = "k" })

---@class MCPHub.ConfirmationContext
---@field chat? table The CodeCompanion chat that made the call; without one no scope can be remembered

---@class MCPHub.ForcedConfirmation
---@field reason string Shown in the approval window
---@field scope? string Realpath of a directory the user may approve for the rest of the chat

--- Why `tool` must not run with `arguments` unconfirmed, if it must not, and
--- the directory the user may approve instead of the one call. A `confirm_if`
--- that throws forces confirmation rather than letting the call through.
---@param tool table A native tool definition
---@param arguments table?
---@param ctx MCPHub.ConfirmationContext?
---@return string? reason
---@return string? scope
function M.reason(tool, arguments, ctx)
    if type(tool.confirm_if) ~= "function" then
        return nil
    end
    local ok, reason = pcall(tool.confirm_if, arguments or {}, ctx or {})
    if not ok then
        return "confirm_if failed: " .. tostring(reason)
    end
    if reason == nil or reason == false then
        return nil
    end
    if type(reason) == "table" then
        return tostring(reason.reason), type(reason.scope) == "string" and reason.scope or nil
    end
    return tostring(reason)
end

--- Approve the directory `dir` for the rest of `chat`.
---@param chat table?
---@param dir string
function M.allow_scope(chat, dir)
    if type(chat) ~= "table" or type(dir) ~= "string" then
        return
    end
    scopes[chat] = scopes[chat] or {}
    scopes[chat][dir] = true
end

--- Whether the realpath `path` lies at or below a directory approved for
--- `chat`. The trailing separator keeps `/a/bc` out of an approved `/a/b`.
---@param chat table?
---@param path string
---@return boolean
function M.scope_allowed(chat, path)
    local dirs = type(chat) == "table" and scopes[chat]
    if not dirs or type(path) ~= "string" then
        return false
    end
    for dir in pairs(dirs) do
        local prefix = dir:sub(-1) == "/" and dir or dir .. "/"
        if path == dir or path:sub(1, #prefix) == prefix then
            return true
        end
    end
    return false
end

--- Record that the user approved a call with exactly this arguments table.
---@param arguments table
function M.grant(arguments)
    granted[arguments] = true
end

--- Use up the grant for `arguments`, if there is one.
---@param arguments table?
---@return boolean
function M.consume(arguments)
    if arguments == nil or not granted[arguments] then
        return false
    end
    granted[arguments] = nil
    return true
end

return M
