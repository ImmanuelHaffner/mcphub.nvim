--- mcphub.utils.spill — spill large strings to disk and return a small summary.
---
--- The motivating use case is MCP tool output: a single call whose stringified
--- response exceeds a byte / line / token budget can blow the LLM's context
--- window in one shot. Writing the payload to a tempfile and returning a short
--- pointer with usage hints lets the agent inspect the data on demand via
--- `rg` / `jq` / `head` instead of flooding the chat.
---
--- Pure data helper: no Neovim UI dependencies, no CodeCompanion dependency, no
--- knowledge of MCP. Safe to call from any context (autocmd, plugin handler,
--- async callback). Token counting is injected by the caller — see
--- `estimate_tokens` — so this module never has to know about a tokenizer.
---
--- The policy layer that decides *which* MCP results get spilled lives in
--- `mcphub.extensions.codecompanion.size_guard`.
---
--- ## Budget semantics
---
--- Every budget option follows the same three-way convention:
---
---   * `nil`     — use this module's default.
---   * `false`   — disable that budget entirely.
---   * a number  — use it as the threshold.
---
--- A payload is spilled when it exceeds **any** enabled budget, so the checks
--- are independent: disabling `max_bytes` does not stop a many-line payload from
--- being caught by `max_lines`.
---
--- @module "mcphub.utils.spill"

local M = {}

--- Detected payload format. Named rather than inlined because LuaLS cannot parse
--- a string-literal union inside an inline table type.
--- @alias mcphub.spill.Format "json"|"xml"|"text"

--- Default spill directory, under Neovim's standard cache path. Callers may
--- override per call with `opts.dir`; this is only the fallback.
--- @type string
M.DIR = vim.fn.stdpath("cache") .. "/mcphub-spill"

--- Default byte budget — text larger than this is spilled.
--- Sized for an acceptable inline payload of ~20k tokens, at the middle of the
--- typical 3-6 bytes/token band (so ~5 bytes/token → ~96 KB).
--- @type integer
M.DEFAULT_MAX_BYTES = 96 * 1024

--- Default line budget — text with more lines than this is spilled.
--- Catches small-byte-but-many-line payloads (sparse logs, CSV dumps). Sized so
--- a typical ~20k-token structured payload does not trip on lines alone
--- (~10 lines per 100 tokens for code/JSON).
--- @type integer
M.DEFAULT_MAX_LINES = 2000

--- Default token budget — deliberately `nil`, i.e. disabled, so a caller with no
--- token counter is never surprised by an estimator running. Supply both
--- `max_tokens` and `token_counter` to enable token-based spilling.
--- @type integer|nil
M.DEFAULT_MAX_TOKENS = nil

--- Resolve one budget option against its default.
---
--- This is the single place the `nil` / `false` / number convention is
--- interpreted; every budget check goes through it so the three-way semantics
--- cannot drift between bytes, lines and tokens.
---
--- @param value integer|false|nil
--- @param default integer|nil
--- @return integer|nil threshold  `nil` means "this budget is disabled".
local function budget(value, default)
    if value == false then
        return nil
    end
    if value == nil then
        return default
    end
    return value
end

--- Sanitize a label into a filesystem-safe slug.
--- @param label string|nil
--- @return string slug Sanitised, max 80 chars. Returns `"output"` when label is nil/empty.
local function slugify(label)
    if not label or label == "" then
        return "output"
    end
    return (label:gsub("[^%w_%-]+", "_")):sub(1, 80)
end

--- Detect the format of `text` from its first non-whitespace character.
--- Cheap and deliberately conservative — when in doubt, treat as text. The
--- `[^%s]` class demands a non-whitespace character so whitespace-only or empty
--- inputs fall through to the `text` default.
--- @param text string
--- @return "json"|"xml"|"text"
local function detect_format(text)
    local first = text:match("^%s*([^%s])")
    if first == "{" or first == "[" then
        return "json"
    end
    if first == "<" then
        return "xml"
    end
    return "text"
end

--- File extension to use for a given detected format.
local FORMAT_EXT = { json = "json", xml = "xml", text = "txt" }

--- Cheap line counter: the number of `\n` bytes plus one.
--- @param s string
--- @return integer
local function count_lines(s)
    if s == "" then
        return 0
    end
    local _, n = s:gsub("\n", "\n")
    return n + 1
end

--- Build a one-line structural preview for the spill summary.
---   * JSON: top-level keys, when the payload parses as an object.
---   * Text/XML: the first non-empty line, truncated to 200 chars.
--- Returns an empty string when no useful preview can be derived.
--- @param text string
--- @param format "json"|"xml"|"text"
--- @return string
local function structure_hint(text, format)
    if format == "json" then
        local ok, decoded = pcall(vim.json.decode, text)
        if ok and type(decoded) == "table" then
            local keys = {}
            for k in pairs(decoded) do
                if type(k) == "string" then
                    table.insert(keys, k)
                end
                if #keys >= 12 then
                    break
                end
            end
            if #keys > 0 then
                table.sort(keys)
                return "\nTop-level JSON keys: `" .. table.concat(keys, "`, `") .. "`"
            end
            -- Array or empty object: fall through to the first-line preview.
        end
    end
    local first_line = text:match("^%s*([^\n]+)")
    if not first_line or first_line == "" then
        return ""
    end
    if #first_line > 200 then
        first_line = first_line:sub(1, 200) .. "…"
    end
    return "\nFirst line: `" .. first_line .. "`"
end

--- Build format-appropriate inspection hints for the summary message.
--- @param format "json"|"xml"|"text"
--- @param path string
--- @return string
local function inspection_hints(format, path)
    if format == "json" then
        return string.format(
            [[
To inspect it, prefer ONE of:
  • `jq '<filter>' %s`          — JSON projection (recommended)
  • `rg <pattern> %s`           — content search
  • `head -c 2000 %s`           — peek at the start]],
            path,
            path,
            path
        )
    end
    if format == "xml" then
        return string.format(
            [[
To inspect it, prefer ONE of:
  • `rg <pattern> %s`           — content search
  • `xmllint --xpath '<expr>' %s`  — XML projection (if installed)
  • `head -c 2000 %s`           — peek at the start]],
            path,
            path,
            path
        )
    end
    return string.format(
        [[
To inspect it, prefer ONE of:
  • `rg <pattern> %s`           — content search
  • `head -n 50 %s`             — first 50 lines
  • `tail -n 50 %s`             — last 50 lines
  • `wc -l %s`                  — line count]],
        path,
        path,
        path,
        path
    )
end

--- Estimate the token count of `text` using the caller's counter.
---
--- Pluggable by design: this module has no dependency on CodeCompanion or any
--- tokenizer. Call sites that want token-aware budgeting inject their own
--- counter. Returns `nil` when no counter is configured or the counter errors,
--- which disables the token budget rather than failing the spill decision.
---
--- @param text string
--- @param opts? { token_counter?: fun(s: string): integer }
--- @return integer|nil tokens `nil` when no usable counter is configured.
function M.estimate_tokens(text, opts)
    local counter = opts and opts.token_counter
    if type(counter) ~= "function" then
        return nil
    end
    local ok, n = pcall(counter, text)
    if not ok or type(n) ~= "number" then
        return nil
    end
    return math.floor(n)
end

--- Decide whether `text` exceeds any enabled budget.
---
--- The token check runs only when a token budget is enabled *and* a counter is
--- available, so a missing counter silently degrades to bytes + lines instead of
--- erroring.
---
--- @param text string|nil
--- @param opts? { max_bytes?: integer|false, max_lines?: integer|false, max_tokens?: integer|false, token_counter?: fun(s: string): integer }
--- @return boolean too_large
--- @return string|nil reason Which budget tripped: `"bytes"`, `"lines"` or `"tokens"`.
function M.too_large(text, opts)
    if not text or text == "" then
        return false, nil
    end
    opts = opts or {}

    local max_bytes = budget(opts.max_bytes, M.DEFAULT_MAX_BYTES)
    if max_bytes and #text > max_bytes then
        return true, "bytes"
    end

    local max_lines = budget(opts.max_lines, M.DEFAULT_MAX_LINES)
    if max_lines and count_lines(text) > max_lines then
        return true, "lines"
    end

    local max_tokens = budget(opts.max_tokens, M.DEFAULT_MAX_TOKENS)
    if max_tokens and opts.token_counter then
        local n = M.estimate_tokens(text, opts)
        if n and n > max_tokens then
            return true, "tokens"
        end
    end

    return false, nil
end

--- Monotonic per-process counter, mixed into spill filenames.
---
--- `math.random` is not seeded per process, so two Neovim instances started in
--- the same second could otherwise pick the same name and clobber each other's
--- payload. The counter guarantees uniqueness *within* a process and the random
--- suffix makes a cross-process collision vanishingly unlikely.
local write_seq = 0

--- Write `text` to a unique file in the spill dir and return its absolute path.
---
--- The directory is created if needed. The extension follows a content sniff
--- (json → `.json`, xml → `.xml`, else `.txt`) so editors and tools pick up
--- syntax automatically.
---
--- @param text string
--- @param opts? { label?: string, dir?: string }
--- @return string|nil path   Absolute path on success.
--- @return string|nil err    Error message on failure.
--- @return string|nil format Detected format on success.
function M.write(text, opts)
    opts = opts or {}
    local dir = opts.dir or M.DIR
    -- `vim.fn.mkdir` RAISES on an unwritable path (E739) rather than returning
    -- false, which would break this function's "return nil, err" contract and,
    -- through it, the truncated-preview fallback in `spill()`. Contain it here.
    local made, mkdir_err = pcall(vim.fn.mkdir, dir, "p")
    if not made then
        return nil, tostring(mkdir_err), nil
    end
    write_seq = write_seq + 1
    local ts = os.date("%Y%m%d-%H%M%S")
    local rand = string.format("%04x%04x", write_seq % 0xffff, math.random(0, 0xffff))
    local format = detect_format(text)
    local path = string.format("%s/%s-%s-%s.%s", dir, slugify(opts.label), ts, rand, FORMAT_EXT[format])
    local fd, err = io.open(path, "w")
    if not fd then
        return nil, err, nil
    end
    fd:write(text)
    fd:close()
    return path, nil, format
end

--- Build the summary that takes the place of `text` in the chat.
---
--- Includes a token estimate when a counter is supplied, and format-appropriate
--- inspection hints (`jq` for JSON, `xmllint` for XML, `rg`/`head`/`tail` for
--- plain text).
---
--- @param text string The original (large) payload.
--- @param path string The path it was written to.
--- @param opts? { format?: mcphub.spill.Format, token_counter?: fun(s: string): integer }
--- @return string
function M.summarize(text, path, opts)
    opts = opts or {}
    local n_bytes = #text
    local n_lines = count_lines(text)
    local n_tokens = M.estimate_tokens(text, opts)
    local size_str
    if n_tokens then
        size_str = string.format("%d bytes, %d lines, ≈%d tokens", n_bytes, n_lines, n_tokens)
    else
        size_str = string.format("%d bytes, %d lines", n_bytes, n_lines)
    end
    local format = opts.format or detect_format(text)
    local struct_hint = structure_hint(text, format)
    local hints = inspection_hints(format, path)
    return string.format(
        [[⚠ Tool output was %s — too large for the chat context.
The full response was written to: `%s` (detected format: `%s`)%s

%s
DO NOT `cat` the whole file into the chat.]],
        size_str,
        path,
        format,
        struct_hint,
        hints
    )
end

--- Spill `text` to disk and return a replacement summary.
---
--- If the write fails, returns a truncated inline preview instead, so a failed
--- spill still cannot blow the context window.
---
--- @param text string
--- @param opts? { label?: string, dir?: string, max_bytes?: integer|false, max_lines?: integer|false, max_tokens?: integer|false, token_counter?: fun(s: string): integer }
--- @return string replacement Short text suitable to inject in place of `text`.
--- @return string|nil path    Where the payload was written, `nil` if the write failed.
function M.spill(text, opts)
    opts = opts or {}
    local path, err, format = M.write(text, opts)
    if not path then
        local cap = budget(opts.max_bytes, M.DEFAULT_MAX_BYTES) or M.DEFAULT_MAX_BYTES
        return string.format(
            "⚠ Tool output (%d bytes) too large for chat AND spill-to-disk failed (%s).\n"
                .. "Truncated to first %d bytes:\n\n%s\n…[truncated]",
            #text,
            tostring(err),
            cap,
            text:sub(1, cap)
        ),
            nil
    end
    -- Propagate the detected format so the summary does not sniff twice.
    local summary_opts = vim.tbl_extend("force", opts, { format = format })
    return M.summarize(text, path, summary_opts), path
end

--- Spill `text` only if it exceeds a budget; otherwise return it unchanged.
--- This is the one-call entry point most call sites want.
---
--- @param text string|nil
--- @param opts? { label?: string, dir?: string, max_bytes?: integer|false, max_lines?: integer|false, max_tokens?: integer|false, token_counter?: fun(s: string): integer }
--- @return string text       The original text, or the summary placeholder.
--- @return string|nil path   Where it was written, `nil` if it was not spilled.
--- @return boolean spilled   True iff the text was actually spilled.
--- @return string|nil reason Which budget tripped, `nil` if not spilled.
function M.maybe_spill(text, opts)
    if not text then
        return "", nil, false, nil
    end
    local big, reason = M.too_large(text, opts)
    if not big then
        return text, nil, false, nil
    end
    local replacement, path = M.spill(text, opts)
    return replacement, path, true, reason
end

--------------------------------------------------------------------------------
-- Garbage collection.
--
-- Spilled files are ephemeral debugging artifacts: by the time a tool response
-- is more than a few hours old, the state it describes (CI run, issue, doc
-- revision, …) is usually stale anyway. We age them out aggressively rather
-- than letting the directory grow unbounded.
--------------------------------------------------------------------------------

--- Default age cap for `gc()`. Anything older is deleted.
--- @type integer
M.DEFAULT_GC_MAX_AGE_HOURS = 24

--- Default period for the background timer.
--- @type integer
M.DEFAULT_GC_PERIOD_MINUTES = 60

--- Pattern matching the files this module writes:
---   `<slug>-YYYYMMDD-HHMMSS-XXXXXXXX.<ext>`
--- `gc()` uses it so a user's own files in the spill dir are never touched.
local SPILL_FILE_PATTERN = "^.+%-%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d%-[%da-f]+%.[a-z]+$"

--- Stat helper returning size + mtime seconds, or nil.
local function file_stat(path)
    local st = vim.uv.fs_stat(path)
    if not st then
        return nil, nil
    end
    return st.size, st.mtime and st.mtime.sec or nil
end

--- Sweep the spill dir, deleting files older than `max_age_hours`.
---
--- Only files matching this module's own naming pattern are considered; foreign
--- files are left alone. Individual `unlink` failures are skipped silently (the
--- file may be open elsewhere, permissions, …). Synchronous, and the directory
--- is small enough that it typically completes well under a millisecond.
---
--- @param opts? { max_age_hours?: integer, dir?: string }
--- @return { scanned: integer, deleted: integer, freed_bytes: integer, kept_bytes: integer }
function M.gc(opts)
    opts = opts or {}
    local dir = opts.dir or M.DIR
    local max_age_hours = opts.max_age_hours or M.DEFAULT_GC_MAX_AGE_HOURS
    local age_cutoff = os.time() - (max_age_hours * 3600)

    local stats = { scanned = 0, deleted = 0, freed_bytes = 0, kept_bytes = 0 }
    local handle = vim.uv.fs_scandir(dir)
    if not handle then
        return stats
    end

    while true do
        local name, t = vim.uv.fs_scandir_next(handle)
        if not name then
            break
        end
        if t == "file" and name:match(SPILL_FILE_PATTERN) then
            stats.scanned = stats.scanned + 1
            local path = dir .. "/" .. name
            local size, mtime = file_stat(path)
            if size and mtime then
                if mtime < age_cutoff then
                    if vim.uv.fs_unlink(path) then
                        stats.deleted = stats.deleted + 1
                        stats.freed_bytes = stats.freed_bytes + size
                    end
                else
                    stats.kept_bytes = stats.kept_bytes + size
                end
            end
        end
    end
    return stats
end

--- @class mcphub.spill.GCHandle
--- @field stop fun() Stop the periodic timer (idempotent).
--- @field timer? any The underlying libuv timer, exposed for introspection. Absent if timer creation failed.

--- Start a background timer calling `gc()` every `period_minutes`.
---
--- **Not idempotent** — each call creates a new timer, and the caller owns the
--- lifecycle: stash the handle and `stop()` it before starting another, or two
--- timers run concurrently. That is deliberate; whoever decides *when* to
--- (re)configure GC is the right owner of the timer.
---
--- The timer fires on libuv's thread, so the GC call is wrapped in
--- `vim.schedule()` + `pcall()`: it always runs through Neovim's event loop and
--- a future bug there can never kill the timer.
---
--- @param opts? { max_age_hours?: integer, period_minutes?: integer, dir?: string }
--- @return mcphub.spill.GCHandle handle
function M.start_periodic_gc(opts)
    opts = opts or {}
    local period_minutes = opts.period_minutes or M.DEFAULT_GC_PERIOD_MINUTES
    local period_ms = period_minutes * 60 * 1000

    local timer = vim.uv.new_timer()
    if not timer then
        -- Timer creation failed (extremely unlikely). Return a no-op handle so
        -- the caller's code paths stay uniform.
        return { stop = function() end }
    end

    timer:start(period_ms, period_ms, function()
        vim.schedule(function()
            pcall(M.gc, opts)
        end)
    end)

    local stopped = false
    return {
        timer = timer, -- exposed so callers can introspect
        stop = function()
            if stopped then
                return
            end
            stopped = true
            pcall(timer.stop, timer)
            pcall(timer.close, timer)
        end,
    }
end

return M
