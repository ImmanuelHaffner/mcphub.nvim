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
---@field hunks integer Hunks the review shows
---@field batch { [1]: integer, [2]: integer }? Position and size of the batch; nil for a single file

---@class MCPHub.FocusGate.Opts
---@field config MCPHub.FocusGate.Config
---@field chat_bufnr integer? The invoking chat; nil: the chat condition holds vacuously
---@field bufnr integer? The target buffer
---@field reference_hash string? sha256 the target must still match, for the staleness flag

---@class MCPHub.FocusGate.Handle
---@field waiting boolean Whether the review is still held back
---@field stale fun(): boolean Whether the target differs from `reference_hash`; never for a review that did not wait
---@field cancel fun(self: MCPHub.FocusGate.Handle, reason: string) Give up on the review and report `reason`
---@field close fun(self: MCPHub.FocusGate.Handle) Give up on the review silently, e.g. while cleaning up
---@field state MCPHub.FocusGate.State? Why the review waits; nil once it no longer does

---@class MCPHub.FocusGate.State
---@field id integer
---@field phase "blocked"|"settling"|"closed"
---@field reason string? The first condition that fails, e.g. "insert mode"; nil while settling
---@field settle_deadline integer? `vim.uv.now()` at which the settle period ends
---@field augroup integer?
---@field timer uv.uv_timer_t?

--- Names for the modes a review waits out, by the first character of the mode code.
local MODE_NAMES = {
    n = "normal mode",
    i = "insert mode",
    R = "replace mode",
    v = "visual mode",
    V = "visual mode",
    ["\22"] = "visual mode",
    s = "select mode",
    S = "select mode",
    ["\19"] = "select mode",
    c = "command line",
    t = "terminal mode",
    r = "prompt",
    ["!"] = "shell",
}

local next_id = 0
--- Gates currently waiting, so specs can prove that none outlives its review.
local active = 0

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

--- Whether the mode `m` lets a review open. Mode codes match exactly, so `{ "n" }`
--- admits neither Operator-pending `no` nor `niI` from `i_CTRL-O`.
---@param config MCPHub.FocusGate.Config
---@param m { mode: string, blocking: boolean }
---@return boolean
local function mode_allowed(config, m)
    return not m.blocking and (config.allow_in_modes == nil or config.allow_in_modes[m.mode] == true)
end

---@param m { mode: string, blocking: boolean }
---@return string
local function mode_reason(m)
    if m.blocking then
        return "waiting for input"
    elseif vim.startswith(m.mode, "no") then
        return "operator pending"
    end
    return MODE_NAMES[m.mode:sub(1, 1)] or ("mode " .. m.mode)
end

--- Where the chat is, as far as the user can tell: "focused", "visible" in the current
--- tab, shown only in an "other_tab", or "hidden" in no window at all.
---@param chat_bufnr integer
---@return "focused"|"visible"|"other_tab"|"hidden"
local function chat_placement(chat_bufnr)
    if vim.api.nvim_win_get_buf(0) == chat_bufnr then
        return "focused"
    end
    local tab, elsewhere = vim.api.nvim_get_current_tabpage(), false
    -- Floating windows count, so a floating chat layout works too.
    for _, win in ipairs(vim.fn.win_findbuf(chat_bufnr)) do
        if vim.api.nvim_win_get_tabpage(win) == tab then
            return "visible"
        end
        elsewhere = true
    end
    return elsewhere and "other_tab" or "hidden"
end

local CHAT_REASONS = {
    visible = "chat unfocused",
    other_tab = "chat in other tab",
    hidden = "chat hidden",
}

--- Why the chat holds the review back, or nil when it does not. A caller that is no
--- chat, such as the hub UI, passes no `chat_bufnr`, and nothing holds it back.
---@param config MCPHub.FocusGate.Config
---@param chat_bufnr integer?
---@return string?
local function chat_reason(config, chat_bufnr)
    if not config.chat or not chat_bufnr then
        return nil
    end
    local placement = chat_placement(chat_bufnr)
    if placement == "focused" or (placement == "visible" and config.chat == "visible") then
        return nil
    end
    return CHAT_REASONS[placement]
end

--- The first condition that holds the review back, or nil when it may open. The chat
--- comes first: getting to it is the step the user has to take before any other.
---@param opts MCPHub.FocusGate.Opts
---@return string?
local function blocked_by(opts)
    local chat = chat_reason(opts.config, opts.chat_bufnr)
    if chat then
        return chat
    end
    local m = vim.api.nvim_get_mode()
    if not mode_allowed(opts.config, m) then
        return mode_reason(m)
    end
    return nil
end

--- The hook that draws a review's row in the chat, if the caller has one.
---@param caller table? `req.caller` of a native tool call
---@return (fun(row: table): { remove: fun() }?)?
function M.show_pending(caller)
    if type(caller) == "table" and type(caller.show_pending) == "function" then
        return caller.show_pending
    end
    return nil
end

--- A review's row: what is reviewed, and why it waits, for how much longer, or how far it got.
---@param state MCPHub.FocusGate.State|{ phase: "reviewing", decided: integer }
---@param label MCPHub.FocusGate.Label?
---@param now integer `vim.uv.now()`
---@param stale boolean? Whether the target no longer matches what the edit was planned against
---@return string[][] chunks
function M.render(state, label, now, stale)
    local Text = require("mcphub.utils.text")
    local settling = state.phase == "settling" and state.settle_deadline
    local reviewing = state.phase == "reviewing"
    local items = {}
    local function plain(text, hl)
        items[#items + 1] = { { text, hl or "Comment" } }
    end
    local function pill(text)
        items[#items + 1] = {
            { "\u{E0B6}", Text.highlights.error },
            { text, Text.highlights.error_fill },
            { "\u{E0B4}", Text.highlights.error },
        }
    end

    local icon = reviewing and "📝 " or settling and "⏳ " or "🚫 "
    plain(icon .. (label and label.name ~= "" and label.name or "review"))
    if label and label.hunks then
        local count = reviewing and (state.decided .. "/" .. label.hunks) or tostring(label.hunks)
        plain(count .. (label.hunks == 1 and " hunk" or " hunks"))
    end
    if label and label.batch then
        plain(Text.icons.file .. " " .. label.batch[1] .. "/" .. label.batch[2], "Directory")
    end
    if settling then
        plain(("opens in %.1fs"):format(math.max(0, state.settle_deadline - now) / 1000))
    elseif state.reason then
        pill(state.reason)
    end
    if stale then
        pill("file changed, may not apply")
    end

    local chunks = {}
    for i, item in ipairs(items) do
        if i > 1 then
            chunks[#chunks + 1] = { " · ", "Comment" }
        end
        vim.list_extend(chunks, item)
    end
    return chunks
end

--- Whether the target has drifted from `opts.reference_hash`, re-hashing only when its
--- `changedtick` moved: the row is redrawn far more often than the file is edited.
---@param opts MCPHub.FocusGate.Opts
---@return fun(): boolean
local function staleness(opts)
    local tick, stale = nil, false
    return function()
        local bufnr = opts.bufnr
        if not (opts.reference_hash and bufnr and vim.api.nvim_buf_is_loaded(bufnr)) then
            return false
        end
        local now = vim.api.nvim_buf_get_changedtick(bufnr)
        if now ~= tick then
            tick = now
            stale = require("mcphub.native.neovim.utils.buffer").content_hash(bufnr) ~= opts.reference_hash
        end
        return stale
    end
end

--- Hold a review back until it may take focus, then call `on_open`.
---
--- When every condition holds on entry the review opens synchronously. Otherwise
--- the gate waits until they all hold, and then for `settle_ms` more, starting the
--- settle period afresh whenever a condition fails again, so that a user who
--- leaves insert mode only briefly is not interrupted.
---@param opts MCPHub.FocusGate.Opts
---@param on_open fun() Opens the review
---@param on_abort fun(reason: string)? Reports a review given up before it opened
---@return MCPHub.FocusGate.Handle
function M.wait(opts, on_open, on_abort)
    assert(type(opts) == "table" and opts.config, "focus_gate.wait: opts.config is required")
    local config = opts.config

    local reason = not M.inert(config) and blocked_by(opts) or nil
    if not reason then
        on_open()
        return {
            waiting = false,
            stale = function()
                return false
            end,
            cancel = function() end,
            close = function() end,
        }
    end

    next_id, active = next_id + 1, active + 1
    ---@type MCPHub.FocusGate.State
    local state = { id = next_id, phase = "blocked", reason = reason }
    ---@type fun(): boolean Whether this call closed the gate, rather than an earlier one
    local close
    ---@type MCPHub.FocusGate.Handle
    local handle = {
        waiting = true,
        state = state,
        stale = staleness(opts),
        cancel = function(_, why)
            if close() and on_abort then
                on_abort(why)
            end
        end,
        close = function()
            close()
        end,
    }
    -- Bumped whenever a settle timer starts or stops, so that a timer callback
    -- already queued on the main loop can tell it has been superseded.
    local generation = 0

    local function stop_timer()
        generation = generation + 1
        if state.timer then
            state.timer:stop()
            state.timer:close()
            state.timer = nil
        end
        state.settle_deadline = nil
    end

    close = function()
        if state.phase == "closed" then
            return false
        end
        state.phase = "closed"
        stop_timer()
        pcall(vim.api.nvim_del_augroup_by_id, state.augroup)
        handle.waiting, handle.state = false, nil
        active = active - 1
        return true
    end

    local function evaluate()
        if state.phase == "closed" then
            return
        end
        local why = blocked_by(opts)
        if why then
            if state.phase == "settling" then
                stop_timer()
            end
            state.phase, state.reason = "blocked", why
            return
        end
        if state.phase == "settling" then
            return
        end
        state.phase, state.reason = "settling", nil
        stop_timer()
        local mine = generation
        state.settle_deadline = vim.uv.now() + config.settle_ms
        state.timer = vim.uv.new_timer()
        state.timer:start(
            config.settle_ms,
            0,
            vim.schedule_wrap(function()
                if mine ~= generation or state.phase ~= "settling" then
                    return
                end
                -- No event reports every way a condition can fail again, so check once more.
                if blocked_by(opts) then
                    return evaluate()
                end
                if close() then
                    on_open()
                end
            end)
        )
    end

    state.augroup = vim.api.nvim_create_augroup("mcphub_focus_gate_" .. state.id, { clear = true })
    vim.api.nvim_create_autocmd({ "ModeChanged", "WinEnter", "TabEnter", "BufWinEnter", "WinClosed" }, {
        group = state.augroup,
        callback = function()
            vim.schedule(evaluate)
        end,
    })

    -- A review whose chat or file is gone has no one left to show it to. A hidden
    -- buffer is not gone, and neither event means gone on its own: `:edit` unloads a
    -- buffer only to load it again, and renaming a listed buffer deletes its old name.
    -- So each event only prompts a look, once the command behind it has finished.
    for _, watched in ipairs({
        { opts.chat_bufnr, "The chat that requested this edit was closed." },
        { opts.bufnr, "The file's buffer was closed before the review opened." },
    }) do
        local bufnr, why = watched[1], watched[2]
        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_create_autocmd({ "BufUnload", "BufDelete", "BufWipeout" }, {
                group = state.augroup,
                buffer = bufnr,
                callback = function()
                    vim.schedule(function()
                        if not (vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr)) then
                            handle:cancel(why)
                        end
                    end)
                end,
            })
        end
    end

    return handle
end

--- The hook that stops a tool call's waiting reviews when the user stops the turn.
---
--- CodeCompanion keeps one job per tool call and kills it on stop, so a call that
--- reviews several files registers once, with a handle that cancels whichever of
--- its reviews is waiting at that moment. It registers only once a review actually
--- waits, leaving every other edit out of CodeCompanion's job slot.
---@param caller table? `req.caller` of a native tool call
---@return (fun(handle: MCPHub.FocusGate.Handle))? on_gate Hand it every waiting gate; nil without a stop hook
function M.on_turn_stop(caller)
    if type(caller) ~= "table" or type(caller.register_job) ~= "function" then
        return nil
    end
    local waiting, registered = nil, false
    return function(handle)
        waiting = handle
        if registered then
            return
        end
        registered = true
        caller.register_job({
            -- May come long after the review opened; cancelling an open gate is a no-op.
            kill = function()
                if waiting then
                    waiting:cancel("Stopped by the user.")
                end
            end,
        })
    end
end

--- Test-only surface; not part of the module's contract.
M._test = {
    reset_warnings = function()
        warned = {}
    end,
    mode_allowed = mode_allowed,
    active_count = function()
        return active
    end,
}

return M
