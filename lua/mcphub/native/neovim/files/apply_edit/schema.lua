--- mcphub.native.neovim.files.apply_edit.schema — input validation and parsing.
---
--- Walks a raw request body (the same shape an MCP client emits as the tool
--- argument) and either returns a typed parsed representation or a list of
--- structured field errors.
---
--- Why hand-rolled and not a JSON-Schema library:
---   * The request shape is small and fixed. A library would contribute
---     ~3× the code we need.
---   * Error reports here are designed as a teaching channel: every error
---     carries a `hint` describing the discrete next move the caller
---     should make. A generic library says "property X failed assertion
---     Y"; we can say "use `content_ref` plus a `contents` entry for
---     multi-line content." For an LLM caller this is the difference
---     between one self-correcting turn and several guessing turns.
---   * The mcphub layer above us does NOT enforce inputSchema beyond
---     `type == "object"`. Validation here is authoritative.
---
--- ## Indexing convention (load-bearing)
---
--- Two different index spaces coexist in this engine, and they are
--- deliberately offset by one:
---
---   * **Lua-side `op_index`**: 1-based. Matches `parsed_ops[op_index]`,
---     `#parsed_ops`, and `ipairs` iteration order. Used by every
---     module inside `lua/mcphub/native/neovim/files/apply_edit/`
---     (schema, planner, applier, response).
---   * **JSON-side `op_index` and `path`**: 0-based. Matches JSON Pointer
---     (RFC 6901) and the JavaScript/Python/TypeScript array-index
---     convention every LLM is fluent in.
---
--- The translation happens at exactly two sites:
---   1. Inside `validate_op`, where the JSON path string `"ops[N]"` is
---      formatted with `op_index - 1`.
---   2. Inside `response.lua` (future), where every `op_index` field on
---      its way to JSON gets `- 1`.
---
--- Everywhere else, `op_index` is 1-based Lua. Why this split: 0-based
--- Lua indices interact badly with `ipairs` (which starts at 1 and
--- silently skips index 0), `#tbl` (which is undefined when index 0 is
--- present), and `table.insert` (which appends after `#tbl`). A
--- 0-based `op_index` stored on a Lua-1-based table is a foot-gun in
--- waiting. The 1-based-in / 0-based-out convention costs one
--- subtraction at the protocol edge and removes a whole class of
--- off-by-one bugs from the engine internals.
---
--- @module "mcphub.native.neovim.files.apply_edit.schema"

local M = {}

local fingerprint = require("mcphub.native.neovim.files.apply_edit.fingerprint")

--------------------------------------------------------------------------------
-- Error / warning taxonomy
--------------------------------------------------------------------------------

--- A structured validation error.
--- @class mcphub.edit.schema.Error
--- @field path     string  Dotted/bracketed field path, e.g. "ops[2].anchor.text".
--- @field reason   string  See `M.ERROR_REASONS` for the enum.
--- @field message  string  Short human-readable description.
--- @field hint?    string  Discrete next move the caller should take.
--- @field expected? string Optional: what type/shape was expected.
--- @field got?     any     Optional: what was actually present (truncated/enriched).
--- @field op_index? integer Optional: **1-based** Lua-native index into `parsed_ops[]`.
---                          The serialiser (`response.lua`) subtracts 1 before emitting
---                          to JSON, so the LLM sees a 0-based index matching the
---                          JSON path `"ops[N]"`. Inside Lua-land we stay 1-based to
---                          avoid `ipairs` silently skipping the first entry. See
---                          the indexing convention note in this module's header.

M.ERROR_REASONS = {
    -- Schema-validation reasons (raised by schema.lua itself).
    missing_field = "missing_field",
    wrong_type = "wrong_type",
    out_of_range = "out_of_range",
    bad_pattern = "bad_pattern",
    unknown_kind = "unknown_kind",
    mutually_exclusive = "mutually_exclusive", -- both `content` and `content_ref` given
    content_boundary_newline = "content_boundary_newline", -- DISABLED 2026-07-15: `content` starts or ends with a newline (reason kept but check inert)
    anchor_leading_newline = "anchor_leading_newline", -- `unique_text.text` starts with a newline (widens range backward)
    missing_content = "missing_content", -- neither `content` nor `content_ref`
    dangling_content_ref = "dangling_content_ref", -- ref does not resolve in `contents`
    occurrence_all_disallowed = "occurrence_all_disallowed", -- replace_range + occurrence: "all"
    bad_modifier_target = "bad_modifier_target", -- insert with a non-positional anchor
    unsupported_op_kind = "unsupported_op_kind", -- declared in schema but not yet implemented
    unsupported_anchor_kind = "unsupported_anchor_kind", -- ditto for anchor kinds

    -- Planner reasons (raised by planner.lua and anchor resolvers).
    anchor_ambiguous = "anchor_ambiguous", -- unique_text matched >1 site with no `occurrence`
    anchor_not_found = "anchor_not_found", -- anchor resolved to zero matches
    range_conflict = "range_conflict", -- two ops claim overlapping ranges in one file
    io_error = "io_error", -- could not read the file
    stale_fingerprint = "stale_fingerprint", -- op's `baseline_fingerprint` does not match current file fingerprint

    -- read-side reasons (raised by mcphub.native.neovim.files.apply_edit.read).
    invalid_range = "invalid_range", -- start_line > end_line; a malformed range pair
    start_after_eof = "start_after_eof", -- start_line > total_lines; LLM assumed stale file state
}

M.WARNING_REASONS = {
    unused_content_label = "unused_content_label",
    indent_detect_fallback = "indent_detect_fallback", -- "detect" treated as "match_anchor" for now
    content_encoding_lossy = "content_encoding_lossy", -- response echoed ill-formed UTF-8; bytes replaced with U+FFFD
}

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

--- Truncate a value for inclusion in an error report.
local function truncate(v, max_len)
    max_len = max_len or 80
    local t = type(v)
    if t == "string" then
        if #v > max_len then
            return v:sub(1, max_len) .. "…"
        end
        return v
    elseif t == "table" then
        return "<object>"
    end
    return v
end

--- Render a Lua type name in a way that's useful to a remote caller. The
--- caller is reasoning in JSON terms; Lua's "table" should become "object"
--- or "array" depending on shape; "nil" should become "null"; "number" is
--- left alone (we use a separate "integer" check elsewhere).
local function json_type_of(v)
    local t = type(v)
    if t == "nil" then
        return "null"
    end
    if t == "table" then
        -- Distinguish array-like from object-like for friendlier messages.
        local n = #v
        local keys = 0
        for _ in pairs(v) do
            keys = keys + 1
        end
        if keys == n then
            return "array"
        end
        return "object"
    end
    return t
end

--- Sorted list of keys from a (string-keyed) table.
local function sorted_keys(tbl)
    local keys = {}
    for k, _ in pairs(tbl or {}) do
        if type(k) == "string" then
            table.insert(keys, k)
        end
    end
    table.sort(keys)
    return keys
end

--- Build an Error record.
local function err(path, reason, message, opts)
    opts = opts or {}
    return {
        path = path,
        reason = reason,
        message = message,
        hint = opts.hint,
        expected = opts.expected,
        got = opts.got ~= nil and truncate(opts.got) or nil,
        op_index = opts.op_index,
    }
end

--- Match identifier-shape pattern for content labels.
local function is_identifier(s)
    return type(s) == "string" and s:match("^[%a_][%w_]*$") ~= nil
end

--------------------------------------------------------------------------------
-- Field-level predicates (with hints)
--------------------------------------------------------------------------------

local function expect_string(v, path, errors, opts)
    if type(v) == "string" then
        return true
    end
    table.insert(
        errors,
        err(path, M.ERROR_REASONS.wrong_type, "expected a string", {
            expected = "string",
            got = json_type_of(v),
            op_index = opts and opts.op_index,
            hint = opts and opts.hint or 'wrap the value in quotes — e.g. "..." in JSON',
        })
    )
    return false
end

local function expect_nonempty_string(v, path, errors, opts)
    if type(v) ~= "string" then
        table.insert(
            errors,
            err(path, M.ERROR_REASONS.wrong_type, "expected a string", {
                expected = "non-empty string",
                got = json_type_of(v),
                op_index = opts and opts.op_index,
                hint = opts and opts.hint or "provide a non-empty string for this field",
            })
        )
        return false
    end
    if v == "" then
        table.insert(
            errors,
            err(path, M.ERROR_REASONS.out_of_range, "expected a non-empty string", {
                expected = "non-empty string",
                got = '""',
                op_index = opts and opts.op_index,
                hint = opts and opts.hint or "an empty string is not a valid value here",
            })
        )
        return false
    end
    return true
end

local function expect_integer(v, path, errors, opts)
    if type(v) ~= "number" or v ~= math.floor(v) then
        table.insert(
            errors,
            err(path, M.ERROR_REASONS.wrong_type, "expected an integer", {
                expected = "integer",
                got = json_type_of(v),
                op_index = opts and opts.op_index,
                hint = opts and opts.hint or "a whole number with no fractional part",
            })
        )
        return false
    end
    if opts and opts.min and v < opts.min then
        table.insert(
            errors,
            err(path, M.ERROR_REASONS.out_of_range, string.format("expected an integer >= %d", opts.min), {
                expected = string.format(">= %d", opts.min),
                got = v,
                op_index = opts.op_index,
                hint = opts.hint or string.format("the minimum allowed value is %d", opts.min),
            })
        )
        return false
    end
    return true
end

local function expect_table(v, path, errors, opts)
    if type(v) == "table" then
        return true
    end
    table.insert(
        errors,
        err(path, M.ERROR_REASONS.wrong_type, "expected an object", {
            expected = "object",
            got = json_type_of(v),
            op_index = opts and opts.op_index,
            hint = opts and opts.hint or "this field takes a JSON object ({ ... })",
        })
    )
    return false
end

--------------------------------------------------------------------------------
-- Anchor validation
--------------------------------------------------------------------------------

--- Every base anchor kind the schema accepts, in the order error messages
--- present them: the kinds an `anchors/` resolver actually handles first, then
--- present them: the kinds an `anchors/` resolver actually handles first, then
--- the ones declared only for forward compatibility. `blurb` is the one-phrase
--- gloss used where a message has to say what a kind matches on; every kind
--- carries one, so promoting a kind is a one-word edit here and nothing else.
---
--- This list is the single source of truth for the three questions the validator
--- asks — "is this a base anchor kind at all?" (`unknown_kind`), "is there a
--- resolver for it yet?" (`unsupported_anchor_kind`), and "what should I tell the
--- LLM to use instead?" — plus every prose enumeration below. Implementing a new
--- kind is therefore flipping one `implemented` flag, not hunting six strings.
--- @type { name: string, implemented: boolean, blurb: string }[]
local BASE_ANCHOR_KIND_LIST = {
    { name = "line_range", implemented = true, blurb = "by line numbers" },
    { name = "unique_text", implemented = true, blurb = "by substring" },
    { name = "treesitter", implemented = false, blurb = "by treesitter query" },
    { name = "lsp_symbol", implemented = false, blurb = "by LSP document symbol" },
}

--- Membership *and* implementation lookup, keyed by kind name. Truthy for every
--- accepted kind, so `if not BASE_ANCHOR_KINDS[by]` still reads as before.
--- @type table<string, { name: string, implemented: boolean, blurb: string? }>
local BASE_ANCHOR_KINDS = {}

local all_names = {}
local implemented_names = {}
local implemented_glosses = {}
local implemented_quoted_glosses = {}
for _, kind in ipairs(BASE_ANCHOR_KIND_LIST) do
    -- Without this, promoting a blurb-less kind would fail at load with LuaJIT's
    -- opaque `string.format` error instead of naming what is missing.
    assert(type(kind.blurb) == "string", "base anchor kind needs a `blurb`: " .. tostring(kind.name))
    BASE_ANCHOR_KINDS[kind.name] = kind
    table.insert(all_names, kind.name)
    if kind.implemented then
        table.insert(implemented_names, kind.name)
        table.insert(implemented_glosses, string.format("%s (%s)", kind.name, kind.blurb))
        table.insert(implemented_quoted_glosses, string.format("`%s` (%s)", kind.name, kind.blurb))
    end
end

--- Message fragments derived from `BASE_ANCHOR_KIND_LIST`, built once at load.
local ALL_KINDS = table.concat(all_names, ", ")
local IMPLEMENTED_KINDS = table.concat(implemented_names, ", ")
local IMPLEMENTED_KINDS_OR = table.concat(implemented_names, " or ")
local IMPLEMENTED_GLOSSED = table.concat(implemented_glosses, ", ")
local IMPLEMENTED_GLOSSED_OR = table.concat(implemented_quoted_glosses, " or ")

local MODIFIER_KINDS = {
    before = true,
    after = true,
    between = true,
}

local ANCHOR_KIND_OVERVIEW = "base anchor kinds: "
    .. IMPLEMENTED_GLOSSED
    .. "; "
    .. "positional modifiers: before / after (wrap a base anchor), between (insert at the seam between two adjacent texts)"

--- Validate a base anchor (resolves to a range). Returns parsed copy on success.
local function validate_base_anchor(anchor, path, errors, op_index)
    if
        not expect_table(anchor, path, errors, {
            op_index = op_index,
            hint = 'an anchor is an object like { by: "line_range", start: 10, end: 12 }',
        })
    then
        return nil
    end

    if
        not expect_nonempty_string(anchor.by, path .. ".by", errors, {
            op_index = op_index,
            hint = "set `by` to one of: "
                .. IMPLEMENTED_KINDS
                .. ", or before / after / between (positional modifiers)",
        })
    then
        return nil
    end

    local by = anchor.by
    if not BASE_ANCHOR_KINDS[by] then
        table.insert(
            errors,
            err(path .. ".by", M.ERROR_REASONS.unknown_kind, "unknown base anchor kind", {
                expected = "one of: " .. ALL_KINDS,
                got = by,
                op_index = op_index,
                hint = ANCHOR_KIND_OVERVIEW,
            })
        )
        return nil
    end

    if by == "line_range" then
        local ok_start = expect_integer(
            anchor.start,
            path .. ".start",
            errors,
            { min = 1, op_index = op_index, hint = "line numbers are 1-based and inclusive" }
        )
        local ok_end = expect_integer(anchor["end"], path .. ".end", errors, {
            min = 1,
            op_index = op_index,
            hint = "line numbers are 1-based and inclusive; `end` is the last line of the range",
        })
        if not (ok_start and ok_end) then
            return nil
        end
        if anchor["end"] < anchor.start then
            table.insert(
                errors,
                err(path .. ".end", M.ERROR_REASONS.out_of_range, "`end` must be >= `start`", {
                    expected = string.format(">= %d (the value of `start`)", anchor.start),
                    got = anchor["end"],
                    op_index = op_index,
                    hint = "for a single-line anchor, set start and end to the same line number",
                })
            )
            return nil
        end
        return { by = "line_range", start = anchor.start, ["end"] = anchor["end"] }
    elseif by == "unique_text" then
        if
            not expect_nonempty_string(anchor.text, path .. ".text", errors, {
                op_index = op_index,
                hint = "`text` is the substring to search for; it must appear exactly once unless `occurrence` is set",
            })
        then
            return nil
        end

        -- A LEADING newline in `text` silently widens the resolved range
        -- backward: the `\n` is the *previous* line's terminator, so
        -- `byte_to_line` maps the match start onto that previous line, pulling
        -- it into the range. A `replace_range`/`delete_range` anchored this way
        -- then clobbers the preceding line — a silent off-by-one. Reject it.
        -- (A TRAILING newline is deliberately allowed: it is a load-bearing
        -- end-of-line disambiguator — e.g. `text: "foo\n"` matches the whole
        -- line `foo` but not the `foo` prefix of a `foobar` line.)
        if anchor.text:sub(1, 1) == "\n" then
            table.insert(
                errors,
                err(path .. ".text", M.ERROR_REASONS.anchor_leading_newline, "`text` must not start with a newline", {
                    expected = "a substring that does not begin with \\n",
                    got = truncate(anchor.text),
                    op_index = op_index,
                    hint = "a leading newline silently pulls the preceding line into the matched range, "
                        .. "so the edit would clobber one line too many. Drop the leading \\n. "
                        .. "If you meant to include the previous line, put its text before the newline. "
                        .. "(A TRAILING newline is fine and useful: it anchors to end-of-line, "
                        .. 'e.g. "foo\\n" matches the whole line "foo" but not the "foo" in "foobar".)',
                })
            )
            return nil
        end
        local parsed = { by = "unique_text", text = anchor.text }

        if anchor.occurrence ~= nil then
            if anchor.occurrence == "all" then
                parsed.occurrence = "all"
            elseif type(anchor.occurrence) == "table" then
                if
                    not expect_integer(anchor.occurrence.nth, path .. ".occurrence.nth", errors, {
                        min = 1,
                        op_index = op_index,
                        hint = "`nth` is 1-based: 1 = first match, 2 = second, etc.",
                    })
                then
                    return nil
                end
                parsed.occurrence = { nth = anchor.occurrence.nth }
            else
                table.insert(
                    errors,
                    err(
                        path .. ".occurrence",
                        M.ERROR_REASONS.wrong_type,
                        '`occurrence` must be either "all" or { nth: N }',
                        {
                            expected = '"all" | { nth: integer >= 1 }',
                            got = json_type_of(anchor.occurrence),
                            op_index = op_index,
                            hint = "omit `occurrence` to require a unique match; "
                                .. "use { nth: N } to pick the Nth match; "
                                .. 'use "all" (only on delete_range) to apply to every match',
                        }
                    )
                )
                return nil
            end
        end
        return parsed
    elseif not BASE_ANCHOR_KINDS[by].implemented then
        -- Declared for forward compatibility, but no resolver handles it yet.
        -- Unknown kinds were already rejected above, so the entry exists here.
        table.insert(
            errors,
            err(
                path .. ".by",
                M.ERROR_REASONS.unsupported_anchor_kind,
                string.format("anchor kind %q is accepted by the schema but not yet implemented", by),
                {
                    expected = IMPLEMENTED_KINDS_OR .. " (currently implemented)",
                    got = by,
                    op_index = op_index,
                    hint = "use " .. IMPLEMENTED_GLOSSED_OR .. " for now",
                }
            )
        )
        return nil
    end
end

--- Validate any anchor (base or modifier-wrapped). Returns parsed copy on success.
--- @param require_position boolean If true, anchor must be modifier-wrapped (insert ops).
local function validate_anchor(anchor, path, errors, op_index, require_position)
    if
        not expect_table(anchor, path, errors, {
            op_index = op_index,
            hint = "an anchor is an object — see the tool description for the anchor grammar",
        })
    then
        return nil
    end

    if
        not expect_nonempty_string(anchor.by, path .. ".by", errors, {
            op_index = op_index,
            hint = require_position and "for `insert`, set `by` to one of: before, after, between"
                or "set `by` to one of the base kinds ("
                    .. IMPLEMENTED_KINDS
                    .. ") or modifiers (before, after, between)",
        })
    then
        return nil
    end

    local by = anchor.by

    if MODIFIER_KINDS[by] then
        -- `between` is shaped differently from `before`/`after`: it carries two
        -- texts (`before_text`/`after_text`) naming the two sides of the seam,
        -- rather than wrapping a base anchor in `of`.
        if by == "between" then
            if
                not expect_nonempty_string(anchor.before_text, path .. ".before_text", errors, {
                    op_index = op_index,
                    hint = "`before_text` is the existing text immediately before the insertion seam "
                        .. "(a verbatim slice of the file); it may span several lines",
                })
            then
                return nil
            end
            if
                not expect_nonempty_string(anchor.after_text, path .. ".after_text", errors, {
                    op_index = op_index,
                    hint = "`after_text` is the existing text immediately after the insertion seam "
                        .. "(a verbatim slice of the file); it may span several lines",
                })
            then
                return nil
            end
            return { by = "between", before_text = anchor.before_text, after_text = anchor.after_text }
        end

        if
            not expect_table(anchor.of, path .. ".of", errors, {
                op_index = op_index,
                hint = '`of` wraps a base anchor: { by: "after", of: { by: "line_range", start: 10, end: 10 } }',
            })
        then
            return nil
        end

        local of_parsed = validate_base_anchor(anchor.of, path .. ".of", errors, op_index)
        if not of_parsed then
            return nil
        end

        return { by = by, of = of_parsed }
    end

    if BASE_ANCHOR_KINDS[by] then
        if require_position then
            table.insert(
                errors,
                err(
                    path,
                    M.ERROR_REASONS.bad_modifier_target,
                    "insert requires a positional anchor (before, after, or between)",
                    {
                        expected = "modifier-wrapped anchor",
                        got = string.format("base anchor (by: %q)", by),
                        op_index = op_index,
                        hint = string.format(
                            'wrap your anchor: { by: "after", of: <your current anchor> }. '
                                .. 'Use "before"/"after" to insert above/below a base anchor, '
                                .. 'or { by: "between", above: ..., below: ... } to insert at the seam '
                                .. "between two adjacent texts."
                        ),
                    }
                )
            )
            return nil
        end
        return validate_base_anchor(anchor, path, errors, op_index)
    end

    table.insert(
        errors,
        err(path .. ".by", M.ERROR_REASONS.unknown_kind, "unknown anchor kind", {
            expected = "base anchor kind, or before / after / between",
            got = by,
            op_index = op_index,
            hint = ANCHOR_KIND_OVERVIEW,
        })
    )
    return nil
end

--------------------------------------------------------------------------------
-- Op validation
--------------------------------------------------------------------------------

local IMPLEMENTED_OP_KINDS = {
    replace_range = true,
    insert = true,
    delete_range = true,
}

local FUTURE_OP_KINDS = {
    rename_symbol = true,
    lsp_code_action = true,
}

local OP_KIND_OVERVIEW = "replace_range overwrites a range; insert adds content at a position; delete_range removes a range. "
    .. "rename_symbol and lsp_code_action are accepted by the schema but not yet implemented."

--- Reject content whose resolved string starts or ends with a newline.
---
--- Unlike a `unique_text` anchor (which is *matched* against the file), `content`
--- is pure output: its bytes are split on `\n` and spliced into the buffer. A
--- leading `\n` injects a blank line *before* the content; a trailing `\n`
--- injects one *after*.
---
--- TEMPORARILY DISABLED (2026-07-15): the boundary-newline rejection is switched
--- off behind an early `return true` while we bake in prod experience. LLMs
--- genuinely need to prepend/append a blank line to `content` -- e.g. inserting
--- a new function or test case that must be visually separated by an empty line
--- -- and the applier's `content_to_lines` already round-trips a boundary `\n`
--- deterministically (trailing `\n` -> a blank line after, leading `\n` -> a
--- blank line before). The rejection body below is left INTACT, not deleted, so
--- it can be re-enabled by removing the early `return true` if feedback shows
--- the boundary newline causes more harm than good.
---
--- @param content string   The resolved content string (inline or from `contents`).
--- @param field_path string Full JSON path of the offending field for the error.
--- @param op_index integer
--- @param errors table[]
--- @return boolean ok  false if a boundary newline was found (error pushed).
local function check_content_boundary_newline(content, field_path, op_index, errors)
    -- DISABLED: allow leading/trailing newlines in content (see docstring above).
    if true then
        return true
    end
    if content:sub(1, 1) ~= "\n" and content:sub(-1) ~= "\n" then
        return true
    end
    local where = content:sub(1, 1) == "\n" and (content:sub(-1) == "\n" and "starts and ends" or "starts") or "ends"
    table.insert(
        errors,
        err(
            field_path,
            M.ERROR_REASONS.content_boundary_newline,
            string.format("`content` must not start or end with a newline (it %s with one)", where),
            {
                expected = "content with no leading or trailing newline",
                op_index = op_index,
                hint = "a boundary newline is spliced into the buffer as a spurious blank line "
                    .. "(leading \\n → blank line before, trailing \\n → blank line after). "
                    .. "`content` is the line body only; do not terminate it with \\n. "
                    .. "Interior newlines are fine for multi-line content. To add a genuine blank "
                    .. "line, include it as an interior line between non-empty lines.",
            }
        )
    )
    return false
end

--- Validate the `content` / `content_ref` pair on an op.
--- Returns (resolved_inline_content, resolved_label, ok). Exactly one of the
--- first two is non-nil on success.
local function validate_content_pair(op, op_path, op_index, contents, used_labels, errors)
    local has_content = op.content ~= nil
    local has_content_ref = op.content_ref ~= nil

    if has_content and has_content_ref then
        table.insert(
            errors,
            err(op_path, M.ERROR_REASONS.mutually_exclusive, "`content` and `content_ref` are mutually exclusive", {
                expected = "exactly one of `content` or `content_ref`",
                got = "both fields are set",
                op_index = op_index,
                hint = "use `content` for short single-line text inline in the op; "
                    .. "use `content_ref` + a `contents` entry for multi-line or bulky content. "
                    .. "Pick one and remove the other.",
            })
        )
        return nil, nil, false
    end

    if not has_content and not has_content_ref then
        table.insert(
            errors,
            err(op_path, M.ERROR_REASONS.missing_content, "one of `content` or `content_ref` is required", {
                expected = "`content` (inline string) or `content_ref` (label into `contents`)",
                op_index = op_index,
                hint = 'for short content: `content: "text here"`. '
                    .. 'For multi-line content: `content_ref: "my_label"` plus a top-level '
                    .. '`contents: { my_label: "..." }`.',
            })
        )
        return nil, nil, false
    end

    if has_content then
        if
            not expect_string(op.content, op_path .. ".content", errors, {
                op_index = op_index,
                hint = "`content` is the replacement/insertion text as a single string",
            })
        then
            return nil, nil, false
        end
        if not check_content_boundary_newline(op.content, op_path .. ".content", op_index, errors) then
            return nil, nil, false
        end
        return op.content, nil, true
    end

    -- has_content_ref
    if
        not expect_nonempty_string(op.content_ref, op_path .. ".content_ref", errors, {
            op_index = op_index,
            hint = "`content_ref` is a label that must match a key in the top-level `contents` map",
        })
    then
        return nil, nil, false
    end

    if not is_identifier(op.content_ref) then
        table.insert(
            errors,
            err(op_path .. ".content_ref", M.ERROR_REASONS.bad_pattern, "`content_ref` must match identifier shape", {
                expected = "^[a-zA-Z_][a-zA-Z0-9_]*$  (letters, digits, underscore; not starting with a digit)",
                got = op.content_ref,
                op_index = op_index,
                hint = 'use a label like "my_function_body" or "_helper"',
            })
        )
        return nil, nil, false
    end

    if not contents or contents[op.content_ref] == nil then
        local available = sorted_keys(contents)
        local got_msg
        if #available == 0 then
            got_msg = string.format("%q  (the `contents` map is empty or missing)", op.content_ref)
        else
            got_msg = string.format("%q  (available labels: %s)", op.content_ref, table.concat(available, ", "))
        end
        table.insert(
            errors,
            err(
                op_path .. ".content_ref",
                M.ERROR_REASONS.dangling_content_ref,
                "`content_ref` does not resolve in `contents`",
                {
                    expected = "a label present as a key in the top-level `contents` map",
                    got = got_msg,
                    op_index = op_index,
                    hint = #available == 0
                            and "declare the content at the top level: `contents: { " .. op.content_ref .. ': "..." }`'
                        or "either rename the ref to one of the available labels above, "
                            .. "or add an entry under `contents`",
                }
            )
        )
        return nil, nil, false
    end

    if not check_content_boundary_newline(contents[op.content_ref], op_path .. ".content_ref", op_index, errors) then
        return nil, nil, false
    end

    used_labels[op.content_ref] = true
    return nil, op.content_ref, true
end

--- Validate the `indent` field on a content-producing op. Returns parsed value.
local function validate_indent(op, op_path, op_index, warnings, errors)
    -- `indent` is REQUIRED on every content-producing op. The field forces the
    -- caller to make a conscious, explicit choice between two incompatible
    -- mental models, rather than silently inheriting a default it did not
    -- reason about:
    --   * "match_anchor" — the caller writes `content` at column 0 and the
    --     engine prepends the anchor line's leading whitespace.
    --   * "preserve"     — the caller has already indented `content` itself and
    --     the engine inserts the bytes verbatim.
    -- In practice an LLM left to a default would leave `indent` unset (taking
    -- match_anchor) while ALSO hand-indenting the content — yielding doubled
    -- indentation. Requiring the field eliminates that footgun: the caller
    -- cannot stay silent about which side owns the indentation.
    if op.indent == nil then
        table.insert(
            errors,
            err(op_path .. ".indent", M.ERROR_REASONS.missing_field, "`indent` is required on this op", {
                expected = '"match_anchor" | "preserve" | "detect"',
                op_index = op_index,
                hint = 'choose explicitly: "match_anchor" if you wrote `content` at column 0 '
                    .. 'and want the anchor line\'s indentation prepended; "preserve" if you '
                    .. "already indented `content` yourself and want it inserted verbatim. "
                    .. 'Pick the one matching how you wrote `content`: "match_anchor" plus '
                    .. "already-indented content incorrectly doubles the indentation.",
            })
        )
        return nil
    end
    if op.indent == "match_anchor" or op.indent == "preserve" then
        return op.indent
    end
    if op.indent == "detect" then
        table.insert(warnings, {
            path = op_path .. ".indent",
            reason = M.WARNING_REASONS.indent_detect_fallback,
            message = '`indent: "detect"` is accepted but treated as `"match_anchor"` for now',
            op_index = op_index,
        })
        return "match_anchor"
    end
    table.insert(
        errors,
        err(
            op_path .. ".indent",
            M.ERROR_REASONS.wrong_type,
            '`indent` must be one of: "match_anchor", "preserve", "detect"',
            {
                expected = '"match_anchor" | "preserve" | "detect"',
                got = op.indent,
                op_index = op_index,
                hint = '"match_anchor" (default) prepends the anchor line\'s leading whitespace to each '
                    .. 'content line; "preserve" keeps your bytes verbatim; '
                    .. '"detect" is reserved but currently falls back to "match_anchor"',
            }
        )
    )
    return nil
end

--- Validate one op. Returns parsed op table on success, nil on failure.
---
--- @param op       table   The raw op input.
--- @param op_index integer **1-based** Lua index; `parsed_ops[op_index]` will be this op.
---                         The JSON path embedded in error messages uses `op_index - 1`
---                         to stay 0-based on the wire — see the indexing convention
---                         note in this module's header.
--- @param require_fingerprint boolean  When true (the production default), the op must
---                         carry a well-formed `baseline_fingerprint`. When false (a
---                         test-only bypass routed through `M.validate`'s `opts`),
---                         the field is not required and its format is not validated.
---                         The bypass is per-call by design; there is no module-level
---                         state to leak between tests, and the LLM-facing
---                         `mcphub.native.neovim.files.apply_edit.engine.apply(input)` boundary does not accept opts so
---                         production callers cannot relax this check.
local function validate_op(op, op_index, contents, used_labels, errors, warnings, require_fingerprint)
    -- JSON path stays 0-based (matches JSON Pointer convention and the LLM's
    -- mental model of array indices). Only Lua-side state is 1-based.
    local op_path = string.format("ops[%d]", op_index - 1)

    if
        not expect_table(op, op_path, errors, {
            op_index = op_index,
            hint = "each entry in `ops` is an object with at least a `kind`, `path`, and (for most kinds) an `anchor`",
        })
    then
        return nil
    end

    if
        not expect_nonempty_string(op.kind, op_path .. ".kind", errors, {
            op_index = op_index,
            hint = "set `kind` to one of: replace_range, insert, delete_range",
        })
    then
        return nil
    end

    local kind = op.kind

    if not (IMPLEMENTED_OP_KINDS[kind] or FUTURE_OP_KINDS[kind]) then
        table.insert(
            errors,
            err(op_path .. ".kind", M.ERROR_REASONS.unknown_kind, "unknown op kind", {
                expected = "one of: replace_range, insert, delete_range (also rename_symbol, lsp_code_action — accepted but not implemented)",
                got = kind,
                op_index = op_index,
                hint = OP_KIND_OVERVIEW,
            })
        )
        return nil
    end

    if FUTURE_OP_KINDS[kind] then
        table.insert(
            errors,
            err(
                op_path .. ".kind",
                M.ERROR_REASONS.unsupported_op_kind,
                string.format("`%s` is accepted by the schema but not yet implemented", kind),
                {
                    expected = "one of the currently-implemented kinds: replace_range, insert, delete_range",
                    got = kind,
                    op_index = op_index,
                    hint = kind == "rename_symbol"
                            and "until rename_symbol lands, emit one replace_range op per textual occurrence"
                        or "until lsp_code_action lands, perform the equivalent edits as explicit replace_range / insert ops",
                }
            )
        )
        return nil
    end

    if
        not expect_nonempty_string(op.path, op_path .. ".path", errors, {
            op_index = op_index,
            hint = "`path` is the file to edit; absolute or relative to the workspace root",
        })
    then
        return nil
    end

    if op.anchor == nil then
        table.insert(
            errors,
            err(op_path .. ".anchor", M.ERROR_REASONS.missing_field, "`anchor` is required", {
                expected = "anchor object — see the tool description",
                op_index = op_index,
                hint = 'every op must specify where to act: `anchor: { by: "line_range", start: 10, end: 12 }` '
                    .. 'or `anchor: { by: "unique_text", text: "..." }`',
            })
        )
        return nil
    end

    local require_position = (kind == "insert")
    local anchor = validate_anchor(op.anchor, op_path .. ".anchor", errors, op_index, require_position)
    if not anchor then
        return nil
    end

    -- baseline_fingerprint presence + format. Gated on require_fingerprint so
    -- tests that aren't about the fingerprint mechanism can call
    -- M.validate(input, { bypass_fingerprint = true }) and skip the check.
    -- See validate_op's docstring for the bypass rationale.
    if require_fingerprint then
        if op.baseline_fingerprint == nil then
            table.insert(
                errors,
                err(
                    op_path .. ".baseline_fingerprint",
                    M.ERROR_REASONS.missing_field,
                    "`baseline_fingerprint` is required on every op",
                    {
                        expected = "string of exactly " .. fingerprint.LEN .. " lowercase-hex characters",
                        op_index = op_index,
                        hint = "call neovim__read_with_fingerprint first; pass the returned "
                            .. "`baseline_fingerprint` verbatim on every op against that file. "
                            .. "This closes the race between read and edit: "
                            .. "the planner refuses to apply if the file mutated in between.",
                    }
                )
            )
            return nil
        end
        if not fingerprint.is_valid_format(op.baseline_fingerprint) then
            table.insert(
                errors,
                err(
                    op_path .. ".baseline_fingerprint",
                    M.ERROR_REASONS.bad_pattern,
                    "`baseline_fingerprint` must be exactly " .. fingerprint.LEN .. " lowercase-hex characters",
                    {
                        expected = "^[0-9a-f]{" .. fingerprint.LEN .. "}$",
                        got = op.baseline_fingerprint,
                        op_index = op_index,
                        hint = "do not parse or regenerate the fingerprint; "
                            .. "pass it through verbatim from neovim__read_with_fingerprint",
                    }
                )
            )
            return nil
        end
    end

    if kind == "delete_range" then
        return {
            kind = "delete_range",
            path = op.path,
            anchor = anchor,
            baseline_fingerprint = op.baseline_fingerprint,
        }
    end

    -- replace_range / insert: content + indent.

    -- `occurrence: "all"` produces a multi-range result. The only op that
    -- has well-defined semantics on multi-range is `delete_range` — for
    -- everything else, broadcasting one piece of content (replace_range)
    -- or one zero-width position (insert via a modifier) across multiple
    -- distinct sites would force one of: silently picking a site, or
    -- crashing at apply time. We reject at the schema layer instead.
    --
    -- The `occurrence` field lives on the **base** anchor — either
    -- `anchor` directly (for `replace_range` with `unique_text`) or
    -- `anchor.of` (for `insert` with a modifier wrapping `unique_text`).
    -- We check both shapes.
    local base_for_occurrence = anchor.of or anchor
    if
        kind ~= "delete_range"
        and base_for_occurrence.by == "unique_text"
        and base_for_occurrence.occurrence == "all"
    then
        local error_path = anchor.of and (op_path .. ".anchor.of.occurrence") or (op_path .. ".anchor.occurrence")
        table.insert(
            errors,
            err(
                error_path,
                M.ERROR_REASONS.occurrence_all_disallowed,
                '`occurrence: "all"` is valid only on `delete_range`',
                {
                    expected = "omit, or use { nth: N }",
                    got = '"all"',
                    op_index = op_index,
                    hint = kind == "replace_range"
                            and "broadcasting one replacement across multiple matches is ambiguous; " .. "emit one replace_range op per occurrence (each with its own `occurrence.nth`), " .. 'or, if you genuinely want to remove all matches, use kind: "delete_range"'
                        or "inserting at multiple positions in one op is undefined; "
                            .. "emit one insert op per intended position (each with its own `occurrence.nth`)",
                }
            )
        )
        return nil
    end

    local content, content_ref, ok = validate_content_pair(op, op_path, op_index, contents, used_labels, errors)
    if not ok then
        return nil
    end

    local indent = validate_indent(op, op_path, op_index, warnings, errors)
    if not indent then
        return nil
    end

    return {
        kind = kind,
        path = op.path,
        anchor = anchor,
        content = content,
        content_ref = content_ref,
        indent = indent,
        baseline_fingerprint = op.baseline_fingerprint,
    }
end

--------------------------------------------------------------------------------
-- Contents map validation
--------------------------------------------------------------------------------

--- Validate the top-level `contents` map. Returns the parsed (shallow-copied)
--- map or nil if invalid.
local function validate_contents(contents, errors)
    if contents == nil then
        return {}
    end
    if type(contents) ~= "table" then
        table.insert(
            errors,
            err(
                "contents",
                M.ERROR_REASONS.wrong_type,
                "`contents` must be an object mapping labels to content strings",
                {
                    expected = "object",
                    got = json_type_of(contents),
                    hint = '`contents: { "my_label": "...", "another_label": "..." }` — labels are identifiers, values are strings',
                }
            )
        )
        return nil
    end

    local parsed = {}
    local any_bad = false
    for key, value in pairs(contents) do
        local field_path = string.format("contents[%q]", tostring(key))
        if type(key) ~= "string" then
            table.insert(
                errors,
                err(field_path, M.ERROR_REASONS.wrong_type, "`contents` keys must be strings", {
                    expected = "string key",
                    got = json_type_of(key),
                    hint = 'JSON object keys are always strings; use a label like "my_content"',
                })
            )
            any_bad = true
        elseif not is_identifier(key) then
            table.insert(
                errors,
                err(field_path, M.ERROR_REASONS.bad_pattern, "`contents` key must match identifier shape", {
                    expected = "^[a-zA-Z_][a-zA-Z0-9_]*$  (letters, digits, underscore; not starting with a digit)",
                    got = key,
                    hint = 'rename the label to something identifier-shaped, e.g. "block_1" instead of "1block"',
                })
            )
            any_bad = true
        elseif type(value) ~= "string" then
            table.insert(
                errors,
                err(field_path, M.ERROR_REASONS.wrong_type, "`contents` value must be a string", {
                    expected = "string",
                    got = json_type_of(value),
                    hint = "put the entire content inside one JSON string; multi-line is fine with \\n",
                })
            )
            any_bad = true
        else
            parsed[key] = value
        end
    end
    if any_bad then
        return nil
    end
    return parsed
end

--------------------------------------------------------------------------------
-- Top-level entry point
--------------------------------------------------------------------------------

--- A typed parsed request, the value returned on success.
--- @class mcphub.edit.schema.Parsed
--- @field ops         table[]                Typed op records.
--- @field contents    table<string, string>  Resolved sidecar.
--- @field dry_run     boolean
--- @field warnings    table[]                Non-fatal warnings (e.g. unused content labels).

--- Validate and parse an incoming request body.
---
--- ## Bypass for tests
---
--- `opts.bypass_fingerprint = true` skips the `baseline_fingerprint`
--- presence/format check inside each op. The flag exists so tests that
--- aren't about the fingerprint mechanism don't have to thread synthetic
--- fingerprints through every fixture.
---
--- The LLM-facing engine entry `mcphub.native.neovim.files.apply_edit.engine.apply(input)` takes **no** opts
--- argument and calls `M.validate(input)` with no opts, so the production
--- path is structurally unable to relax this check — the bypass is not a
--- protocol surface. The `opts` parameter is internal to the schema module
--- and to tests that exercise it directly. See `mcphub.native.neovim.files.apply_edit.fingerprint`.
---
--- @param input table The raw decoded request body.
--- @param opts? table  Internal. `{ bypass_fingerprint = boolean? }`. Tests only.
--- @return boolean ok
--- @return mcphub.edit.schema.Parsed|mcphub.edit.schema.Error[] parsed_or_errors
function M.validate(input, opts)
    opts = opts or {}
    local require_fingerprint = not (opts.bypass_fingerprint == true)

    local errors = {}
    local warnings = {}

    if type(input) ~= "table" then
        table.insert(
            errors,
            err("", M.ERROR_REASONS.wrong_type, "request body must be an object", {
                expected = "object",
                got = json_type_of(input),
                hint = "the top-level value is `{ ops: [...] }`, optionally with `contents` and `dry_run`",
            })
        )
        return false, errors
    end

    if input.ops == nil then
        table.insert(
            errors,
            err("ops", M.ERROR_REASONS.missing_field, "`ops` is required", {
                expected = "non-empty array of op objects",
                hint = 'every request needs at least one op, e.g. `{ ops: [{ kind: "replace_range", path: "...", anchor: ..., content: "..." }] }`',
            })
        )
        return false, errors
    end
    if type(input.ops) ~= "table" then
        table.insert(
            errors,
            err("ops", M.ERROR_REASONS.wrong_type, "`ops` must be an array", {
                expected = "array",
                got = json_type_of(input.ops),
                hint = "`ops` is a JSON array of op objects, even when there is only one op",
            })
        )
        return false, errors
    end
    if #input.ops == 0 then
        table.insert(
            errors,
            err("ops", M.ERROR_REASONS.out_of_range, "`ops` must contain at least one op", {
                expected = "length >= 1",
                got = 0,
                hint = "add an op to `ops`; an empty batch is a no-op and not allowed",
            })
        )
        return false, errors
    end

    -- Validate `contents` before ops so content_ref resolution sees the map.
    local contents = validate_contents(input.contents, errors)
    if not contents then
        return false, errors
    end

    -- Optional scalars.
    if input.dry_run ~= nil and type(input.dry_run) ~= "boolean" then
        table.insert(
            errors,
            err("dry_run", M.ERROR_REASONS.wrong_type, "`dry_run` must be a boolean", {
                expected = "boolean",
                got = json_type_of(input.dry_run),
                hint = "`dry_run: true` plans and previews without writing; omit or set false to apply",
            })
        )
    end
    -- Validate every op. `op_index` is 1-based Lua-native; the JSON `path`
    -- field inside each error record uses 0-based form (`ops[0]`, `ops[1]`,
    -- ...) — that translation happens inside `validate_op`.
    local used_labels = {}
    local parsed_ops = {}
    for i, op in ipairs(input.ops) do
        local parsed = validate_op(op, i, contents, used_labels, errors, warnings, require_fingerprint)
        if parsed then
            table.insert(parsed_ops, parsed)
        end
    end

    if #errors > 0 then
        return false, errors
    end

    -- Unused-label warnings (non-fatal).
    for label, _ in pairs(contents) do
        if not used_labels[label] then
            table.insert(warnings, {
                path = string.format("contents[%q]", label),
                reason = M.WARNING_REASONS.unused_content_label,
                message = string.format(
                    "content label %q is declared in `contents` but not referenced by any op",
                    label
                ),
                hint = "either reference it from an op via `content_ref`, or remove it from `contents`",
            })
        end
    end

    return true,
        {
            ops = parsed_ops,
            contents = contents,
            dry_run = input.dry_run == true,
            warnings = warnings,
        }
end

--------------------------------------------------------------------------------
-- Response helpers
--------------------------------------------------------------------------------

--- Format a one-line summary of a list of schema errors, suitable for the
--- response's top-level `summary` field. Designed to orient the caller before
--- it dives into the per-field details.
---
--- @param errors mcphub.edit.schema.Error[]
--- @return string
function M.format_error_summary(errors)
    if not errors or #errors == 0 then
        return "no schema errors"
    end

    -- Count distinct op indices that had errors (vs request-level errors).
    local op_indices = {}
    local request_level = 0
    for _, e in ipairs(errors) do
        if e.op_index ~= nil then
            op_indices[e.op_index] = true
        else
            request_level = request_level + 1
        end
    end

    local n_ops = 0
    for _ in pairs(op_indices) do
        n_ops = n_ops + 1
    end

    local parts = {}
    if request_level > 0 then
        table.insert(
            parts,
            string.format("%d request-level %s", request_level, request_level == 1 and "error" or "errors")
        )
    end
    if n_ops > 0 then
        local total_op_errors = #errors - request_level
        table.insert(
            parts,
            string.format(
                "%d %s across %d %s",
                total_op_errors,
                total_op_errors == 1 and "error" or "errors",
                n_ops,
                n_ops == 1 and "op" or "ops"
            )
        )
    end

    return "request schema invalid: " .. table.concat(parts, ", ")
end

return M
