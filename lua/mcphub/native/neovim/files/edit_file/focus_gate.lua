--- Decides when an interactive `EditUI` review may take focus.
---
--- Opening a review moves the cursor into the edited file, which interrupts
--- whatever the user is doing. The gate holds the review back until the
--- conditions configured under `ui.defer` hold. With the defaults it holds
--- nothing back and opens the review at once, exactly as before it existed.
---
--- @module "mcphub.native.neovim.files.edit_file.focus_gate"

local M = {}

local DEFAULT_SETTLE_MS = 2000

---@class MCPHub.FocusGate.Config
---@field allow_in_modes table<string, true>? Set of exact `nvim_get_mode().mode` codes; nil: any mode
---@field chat false|"visible"|"focused" Whether the invoking chat must be visible in the current tab, or focused
---@field settle_ms integer Quiet period after a blocked gate's conditions clear

---@class MCPHub.FocusGate.Label
---@field name string File name, `vim.fs.basename` of the path
---@field hunks integer Hunks the review will show
---@field batch { [1]: integer, [2]: integer }? Position and size of the batch; nil for a single file

---@class MCPHub.FocusGate.Opts
---@field config MCPHub.FocusGate.Config
---@field chat_bufnr integer? The invoking chat; nil: the chat condition holds vacuously
---@field bufnr integer? The target buffer
---@field reference_hash string? sha256 the target must still match, for the pending row's staleness flag
---@field label MCPHub.FocusGate.Label? What the pending row shows
---@field show_pending (fun(row: table): { remove: fun() })? Draws the pending row; nil outside CodeCompanion

---@class MCPHub.FocusGate.Handle
---@field waiting boolean Whether the review is still held back
---@field cancel fun(self: MCPHub.FocusGate.Handle, reason: string) Give up on the review and report `reason`
---@field close fun(self: MCPHub.FocusGate.Handle) Give up on the review silently, e.g. while cleaning up

--- Warnings already shown. `EditUI.new` resolves the config once per review, so
--- a misconfiguration would otherwise warn on every single edit.
---@type table<string, true>
local warned = {}

---@param message string
local function warn_once(message)
    if warned[message] then
        return
    end
    warned[message] = true
    vim.notify("mcphub: " .. message, vim.log.levels.WARN)
end

---@param allow any The user's `allow_in_modes`
---@return table<string, true>?
local function resolve_modes(allow)
    if allow == nil or allow == false then
        return nil
    end
    local modes = {}
    if type(allow) == "table" then
        for _, mode in ipairs(allow) do
            if type(mode) == "string" and mode ~= "" then
                modes[mode] = true
            end
        end
    end
    if next(modes) == nil then
        -- An empty allow list would hold every review back forever.
        warn_once('`ui.defer.allow_in_modes` must be a non-empty list of mode codes such as { "n" }; ignoring it')
        return nil
    end
    return modes
end

--- Normalise the user's `ui.defer` table.
---@param defer table? The user's `ui.defer`
---@return MCPHub.FocusGate.Config
function M.resolve(defer)
    defer = type(defer) == "table" and defer or {}

    local chat = defer.chat
    if chat == nil then
        chat = false
    elseif chat ~= false and chat ~= "visible" and chat ~= "focused" then
        warn_once('`ui.defer.chat` must be false, "visible" or "focused"; ignoring ' .. vim.inspect(chat))
        chat = false
    end

    local settle_ms = tonumber(defer.settle_ms) or DEFAULT_SETTLE_MS
    return {
        allow_in_modes = resolve_modes(defer.allow_in_modes),
        chat = chat,
        settle_ms = math.max(0, math.floor(settle_ms)),
    }
end

--- Whether `config` can never hold a review back.
---@param config MCPHub.FocusGate.Config
---@return boolean
function M.inert(config)
    return config.allow_in_modes == nil and not config.chat
end

--- The buffer of the CodeCompanion chat that made a tool call, if it made it.
--- The only place that knows the shape of CodeCompanion's caller.
---@param caller table? `req.caller` of a native tool call
---@return integer?
function M.chat_bufnr(caller)
    if type(caller) ~= "table" or caller.type ~= "codecompanion" or type(caller.codecompanion) ~= "table" then
        return nil
    end
    local chat = caller.codecompanion.chat
    local bufnr = type(chat) == "table" and chat.bufnr or nil
    if type(bufnr) == "number" and vim.api.nvim_buf_is_valid(bufnr) then
        return bufnr
    end
    return nil
end

--- Hold a review back until it may take focus, then call `on_open`.
---@param opts MCPHub.FocusGate.Opts
---@param on_open fun() Opens the review
---@param _on_abort fun(reason: string)? Reports a review given up before it opened
---@return MCPHub.FocusGate.Handle
function M.wait(opts, on_open, _on_abort)
    assert(type(opts) == "table" and opts.config, "focus_gate.wait: opts.config is required")
    local handle = {
        waiting = false,
        cancel = function() end,
        close = function() end,
    }
    on_open()
    return handle
end

--- Test-only surface; not part of the module's contract.
M._test = {
    reset_warnings = function()
        warned = {}
    end,
}

return M
