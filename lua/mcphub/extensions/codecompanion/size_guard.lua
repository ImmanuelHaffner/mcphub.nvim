--- mcphub.extensions.codecompanion.size_guard — keep oversized MCP results out
--- of the chat context.
---
--- A single MCP call can return more text than the whole conversation budget: a
--- `rg` dump, a `vim.inspect` of a large table, a 40k-line log. This module
--- decides *whether* a result is too large and, when it is, replaces its text
--- with a short summary plus the path it was written to. The writing, budget
--- arithmetic and summary formatting all live in `mcphub.utils.spill`; what lives
--- here is policy: configuration, the skip list, and the GC lifecycle.
---
--- ## Where it hooks, and why not in the output handler
---
--- `mcphub.extensions.codecompanion.core.execute_mcp_tool` calls it, because that
--- is the only place the **real identity** of the call is known:
--- `parsed_params.server_name` and `parsed_params.tool_name` (or `uri`). The
--- obvious-looking alternative — wrapping `create_output_handlers().success` — can
--- only see `display_name`, which is unreliable for skip matching in three
--- separate ways:
---
---   1. `add_mcp_prefix_to_tool_names` rewrites it to `mcp__<server>__<tool>`, so
---      a configured `"neovim__read_file"` silently stops matching and the tool
---      becomes guarded when the user asked for it to be skipped.
---   2. On the static `@mcp` path every call shares one handler created with
---      `action_name`, so `display_name` is literally `use_mcp_tool` for *every*
---      tool — a per-tool skip list can never match there.
---   3. Server names are sanitised and de-duplicated with `_1`/`_2` suffixes on
---      conflict.
---
--- Identity-based matching is immune to all three.
---
--- ## Why the defaults live here rather than in the extension's `setup()`
---
--- The CodeCompanion extension declares its other defaults inline as flat
--- booleans. These are not flat: the token budget is meaningless without a
--- counter, and the skip list encodes a correctness constraint (see
--- `DEFAULT_SKIP`). Keeping them next to the code that interprets them is what
--- stops the two from drifting.
---
--- @module "mcphub.extensions.codecompanion.size_guard"

local spill = require("mcphub.utils.spill")

local M = {}

--- Default token budget. 20k tokens is the comfortable upper bound for a single
--- tool invocation given typical chat context budgets; past that a payload is
--- large enough to deserve on-demand `rg`/`jq` inspection instead of going
--- inline. `spill`'s byte and line defaults are derived from this figure
--- (~5 bytes/token, ~10 lines per 100 tokens) so all three stay in one ballpark.
--- @type integer
M.DEFAULT_MAX_TOKENS = 20000

--- Tools whose output is a **contract**, not a payload — spilling them is
--- counter-productive or outright breaking, so they are skipped by default.
---
--- `neovim__read_with_fingerprint` is the load-bearing entry: its payload is the
--- file content *plus* the `baseline_fingerprint` that `neovim__apply_edit`
--- requires on every op. Spilled, the model receives a summary and a path — no
--- content, and a fingerprint it cannot legitimately use — which breaks every
--- edit that follows. The remaining six return short structured reports
--- (diffs, per-op outcomes, confirmations, directory listings) that the model is
--- expected to read and act on.
---
--- Deliberately **not** here, i.e. guarded: `execute_command`, `execute_lua`,
--- `read_file`, `read_multiple_files` and `find_files`. Their output is an opaque
--- payload of unbounded size, and a spilled copy stays fully inspectable with
--- `rg`/`head`. Note the asymmetry with `read_with_fingerprint` is intentional:
--- a plain read has no fingerprint contract to break.
---
--- @type string[]
M.DEFAULT_SKIP = {
    "neovim__apply_edit",
    "neovim__delete_items",
    "neovim__edit_file",
    "neovim__list_directory",
    "neovim__move_item",
    "neovim__read_with_fingerprint",
    "neovim__write_file",
}

--- Resolved configuration, rebuilt on every `setup()`.
--- @type MCPHub.Extensions.CodeCompanion.SizeGuardConfig
local config = {}

--- Skip lookup derived from `config.skip`, keyed by both `<server>__<name>` and
--- bare `<name>`.
--- @type table<string, true>
local skip_set = {}

--- The installed GC timer, if any. Sole owner of that timer's lifecycle.
--- @type mcphub.spill.GCHandle|nil
local gc_handle = nil

--- Resolve a token counter, preferring the user's, else CodeCompanion's pure-Lua
--- heuristic estimator. Returns nil when neither is available, which disables the
--- token budget rather than erroring.
--- @param user_counter? fun(s: string): integer
--- @return (fun(s: string): integer)|nil
local function resolve_token_counter(user_counter)
    if type(user_counter) == "function" then
        return user_counter
    end
    local ok, tokens_util = pcall(require, "codecompanion.utils.tokens")
    if ok and type(tokens_util.calculate) == "function" then
        return function(s)
            return tokens_util.calculate(s)
        end
    end
    return nil
end

--- Build the skip lookup.
---
--- The user's list is **additive** on top of `DEFAULT_SKIP` unless
--- `skip_defaults = false`. Additive is the safe direction: a user adding one
--- entry would otherwise silently drop `read_with_fingerprint` and break the
--- fingerprint contract, since Lua list options replace rather than merge.
---
--- Each entry is registered under two keys so both spellings work:
--- `"neovim__read_file"` (explicit server) and `"read_file"` (that tool on any
--- server).
---
--- @param user_skip? string[]
--- @param skip_defaults? boolean
--- @return table<string, true>
local function build_skip_set(user_skip, skip_defaults)
    local set = {}
    if skip_defaults ~= false then
        for _, name in ipairs(M.DEFAULT_SKIP) do
            set[name] = true
        end
    end
    for _, name in ipairs(user_skip or {}) do
        set[name] = true
    end
    return set
end

--- Configure GC according to `gc_opts`.
---
--- Behaviour matrix:
---   * `false`        → no startup sweep, no timer.
---   * `nil` / `true` → deferred startup sweep plus a periodic timer on
---                      `spill`'s defaults (24h retention, hourly).
---   * table          → as `true`, with `max_age_hours` / `period_minutes`
---                      overrides.
---
--- A previously installed timer is ALWAYS stopped first, whatever the new mode.
--- That unifies "toggle off" and "reconfigure" into one path, so there is exactly
--- one place the timer lifecycle is managed.
---
--- @param gc_opts boolean|table|nil
--- @param dir string|nil
local function configure_gc(gc_opts, dir)
    if gc_handle then
        gc_handle.stop()
        gc_handle = nil
    end
    if gc_opts == false then
        return
    end
    local cfg = type(gc_opts) == "table" and vim.deepcopy(gc_opts) or {}
    cfg.dir = dir
    -- One-shot sweep, deferred so it never competes with startup.
    vim.defer_fn(function()
        pcall(spill.gc, cfg)
    end, 3000)
    gc_handle = spill.start_periodic_gc(cfg)
end

--- Resolve configuration and (re)configure GC. Idempotent: safe to call on every
--- CodeCompanion extension `setup()`, including `:Lazy reload`.
--- @param user_opts? MCPHub.Extensions.CodeCompanion.SizeGuardConfig
function M.setup(user_opts)
    user_opts = user_opts or {}

    -- `max_tokens = false` disables the budget outright, so no counter is
    -- resolved and CodeCompanion's estimator is never invoked.
    local max_tokens = user_opts.max_tokens
    local token_counter = nil
    if max_tokens == false then
        max_tokens = false
    else
        token_counter = resolve_token_counter(user_opts.token_counter)
        if max_tokens == nil then
            max_tokens = M.DEFAULT_MAX_TOKENS
        end
    end

    config = {
        enabled = user_opts.enabled ~= false,
        max_bytes = user_opts.max_bytes,
        max_lines = user_opts.max_lines,
        max_tokens = max_tokens,
        token_counter = token_counter,
        dir = user_opts.dir,
        skip = user_opts.skip,
        skip_defaults = user_opts.skip_defaults,
        gc = user_opts.gc,
    }
    skip_set = build_skip_set(config.skip, config.skip_defaults)
    configure_gc(config.gc, config.dir)
end

--- Whether results from this capability are exempt from spilling.
---
--- Matches on real identity, never on a display name: both `<server>__<name>` and
--- bare `<name>` are accepted so a skip entry can be scoped to one server or
--- applied across all of them.
---
--- @param server_name string|nil
--- @param name string|nil Tool name or resource URI.
--- @return boolean
function M.is_skipped(server_name, name)
    if type(name) ~= "string" or name == "" then
        return false
    end
    if type(server_name) == "string" and server_name ~= "" and skip_set[server_name .. "__" .. name] then
        return true
    end
    return skip_set[name] == true
end

--- Spill `result.text` in place when it exceeds a budget.
---
--- Mutating in place is deliberate: the output handler formats `result.text` into
--- both the LLM-facing and the user-facing message, so replacing it here keeps
--- the two in sync without re-implementing any markdown wrapping.
---
--- Never raises: any failure inside the guard must not take down a tool call that
--- otherwise succeeded, so the whole body is wrapped in `pcall`. A spill failure
--- inside `spill` itself already degrades to a truncated inline preview.
---
--- @param result MCPResponseOutput|nil The parsed response; mutated in place.
--- @param identity { server_name?: string, tool_name?: string, uri?: string }
--- @return boolean spilled True iff `result.text` was replaced.
--- @return string|nil path Where the payload was written.
function M.apply(result, identity)
    if not config.enabled then
        return false, nil
    end
    if type(result) ~= "table" or type(result.text) ~= "string" or result.text == "" then
        return false, nil
    end

    identity = identity or {}
    local name = identity.tool_name or identity.uri
    if M.is_skipped(identity.server_name, name) then
        return false, nil
    end

    local label = identity.server_name and name and (identity.server_name .. "__" .. name) or (name or "mcp_output")
    local ok, replacement, path, spilled = pcall(spill.maybe_spill, result.text, {
        label = label,
        dir = config.dir,
        max_bytes = config.max_bytes,
        max_lines = config.max_lines,
        max_tokens = config.max_tokens,
        token_counter = config.token_counter,
    })
    if not ok or not spilled then
        return false, nil
    end
    result.text = replacement
    return true, path
end

--- The resolved configuration. Read-only introspection for tests and `:checkhealth`-style probes.
--- @return MCPHub.Extensions.CodeCompanion.SizeGuardConfig
function M.get_config()
    return vim.deepcopy(config)
end

--- Reset to an unconfigured state, stopping any GC timer. Test seam.
function M.reset()
    if gc_handle then
        gc_handle.stop()
        gc_handle = nil
    end
    config = {}
    skip_set = {}
end

return M
