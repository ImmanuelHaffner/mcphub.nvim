--- mcphub.utils.deprecation — soft-deprecation policy for built-in tools.
---
--- A *soft* deprecation leaves the tool registered and fully working, but steers
--- everyone involved towards its replacement, at each moment where that advice
--- is actionable:
---
---   * `M.banner()` prefixes the tool's `description`, so the LLM reads the
---     recommendation before it decides which tool to call. This is the half
---     that actually changes model behaviour.
---   * `M.notify_once()` raises a `vim.notify` WARN the first time the tool is
---     invoked in a session, so a human finds out that something in their setup
---     still routes through the old path.
---   * `M.notify_enabled()` raises one when the tool is re-enabled from the
---     MCPHub UI — the moment the user is actually deciding, and can act on it.
---
--- Nothing here disables anything, and no call site is removed. A user who wants
--- a deprecated tool gone entirely adds it to the server's `disabled_tools` from
--- the MCPHub UI, which is persisted to `servers.json`.
---
--- ## Why the notices live here rather than in the tool modules
---
--- Two unrelated call sites need the same text: the tool itself (at call time)
--- and `ui/views/main.lua` (at toggle time). The UI additionally has to answer
--- "is this deprecated?" for a capability it knows only as a server name plus a
--- tool name. One registry keyed by the LLM-facing tool name serves both and
--- keeps the two wordings from drifting apart. It also keeps the dependency
--- pointing the right way: a UI view may require `mcphub.utils.*`, but it has no
--- business requiring a native tool module.
---
--- ## Why `vim.notify` rather than `mcphub.utils.log.warn`
---
--- `log.warn` is dropped when it falls below `config.log.level`, and that
--- defaults to `vim.log.levels.ERROR` — so a logged warning would be silent for
--- virtually every user. A deprecation notice nobody sees is not a deprecation
--- notice. We do keep the logger's `vim.schedule` wrapping, since a tool handler
--- may run in a context where `vim.notify` is not safe to call directly.
---
--- ## Why once per session on use, but every time on enable
---
--- A single chat can call one tool dozens of times, so the invocation notice is
--- advice that should cost exactly one notification and never drown out the
--- tool's own output. Enabling is the opposite: a deliberate, infrequent user
--- action, where answering every time is proportionate.
---
--- @module "mcphub.utils.deprecation"

local M = {}

--- A soft-deprecation descriptor. Every entry point takes the same one, so the
--- LLM-facing text and the user-facing text can never disagree.
--- @class mcphub.DeprecationNotice
--- @field name        string  Tool name as the LLM addresses it: `<server>__<tool>`.
--- @field replacement string  Tool to prefer instead, in the same form.
--- @field reason      string  One sentence on why the replacement is better. Shown to LLM and user alike.

--- @type mcphub.DeprecationNotice
M.EDIT_FILE = {
    name = "neovim__edit_file",
    replacement = "neovim__apply_edit",
    reason = "It anchors each edit to an explicit line range, a unique text span or a named seam, and refuses to "
        .. "apply against a file that changed since it was read, rather than matching SEARCH blocks by content "
        .. "with a fuzzy fallback.",
}

--- @type mcphub.DeprecationNotice
M.READ_FILE = {
    name = "neovim__read_file",
    replacement = "neovim__read_with_fingerprint",
    reason = "`neovim__apply_edit` requires a `baseline_fingerprint` on every op and only "
        .. "`neovim__read_with_fingerprint` issues one, so reading a file you may go on to edit through this tool "
        .. "forces a second, redundant read.",
}

--- Every notice, keyed by `name` (the `<server>__<tool>` form).
--- @type table<string, mcphub.DeprecationNotice>
M.notices = {
    [M.EDIT_FILE.name] = M.EDIT_FILE,
    [M.READ_FILE.name] = M.READ_FILE,
}

--- Tool names already warned about in this session.
--- @type table<string, true>
local warned = {}

--- Look up a notice for a tool identified the way the MCPHub UI identifies it:
--- a server name plus the bare tool name.
---
--- @param server_name string  e.g. `"neovim"`.
--- @param tool_name string    e.g. `"edit_file"`.
--- @return mcphub.DeprecationNotice|nil notice  `nil` when the tool is not deprecated.
function M.for_tool(server_name, tool_name)
    if type(server_name) ~= "string" or type(tool_name) ~= "string" then
        return nil
    end
    return M.notices[string.format("%s__%s", server_name, tool_name)]
end

--- Build the prefix for a deprecated tool's `description`.
---
--- Ends with a blank line, so it reads as its own paragraph once concatenated
--- onto the existing description.
---
--- @param notice mcphub.DeprecationNotice
--- @return string banner
function M.banner(notice)
    local fmt = "DEPRECATED: prefer `%s` over `%s`. %s\n\n"
    return string.format(fmt, notice.replacement, notice.name, notice.reason)
end

--- Warn the user, at most once per session, that a deprecated tool was called.
---
--- Safe to call unconditionally as the first statement of a handler: it reports
--- that the tool *was invoked*, which holds whether or not the call validates.
---
--- @param notice mcphub.DeprecationNotice
function M.notify_once(notice)
    if warned[notice.name] then
        return
    end
    warned[notice.name] = true
    local fmt = "`%s` is deprecated — prefer `%s`.\n%s"
    M.notify(string.format(fmt, notice.name, notice.replacement, notice.reason))
end

--- Warn the user that they just enabled a deprecated tool.
---
--- Not rate-limited: enabling is a deliberate action, so it deserves an answer
--- every time.
---
--- @param notice mcphub.DeprecationNotice
function M.notify_enabled(notice)
    local fmt = "`%s` is deprecated and you just enabled it — prefer `%s`.\n%s"
    M.notify(string.format(fmt, notice.name, notice.replacement, notice.reason))
end

--- Emit a WARN notification on the main loop.
---
--- @param msg string
function M.notify(msg)
    vim.schedule(function()
        vim.notify(msg, vim.log.levels.WARN, { title = "MCPHub" })
    end)
end

--- Forget which tools have been warned about, re-arming `notify_once`.
---
--- Test seam, and handy from the command line when reviewing a notice's wording.
function M.reset()
    warned = {}
end

return M
