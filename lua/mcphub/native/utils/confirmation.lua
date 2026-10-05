--- Forced confirmation for native tools that declare `confirm_if(args) → reason?`.
---
--- The approval gate asks the user and grants the call; the native server
--- refuses any call `confirm_if` objects to unless it was granted. A grant is
--- keyed on the identity of the arguments table the gate approved, which the
--- model cannot forge: it only ever produces JSON, decoded into fresh tables.
--- So a caller that skips the gate fails closed instead of bypassing it.
local M = {}

---@type table<table, true>
local granted = setmetatable({}, { __mode = "k" })

--- Why `tool` must not run with `arguments` unconfirmed, if it must not. A
--- `confirm_if` that throws forces confirmation rather than letting the call
--- through.
---@param tool table A native tool definition
---@param arguments table?
---@return string? reason
function M.reason(tool, arguments)
    if type(tool.confirm_if) ~= "function" then
        return nil
    end
    local ok, reason = pcall(tool.confirm_if, arguments or {})
    if not ok then
        return "confirm_if failed: " .. tostring(reason)
    end
    if reason == nil or reason == false then
        return nil
    end
    return tostring(reason)
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
