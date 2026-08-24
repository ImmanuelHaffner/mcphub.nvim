--- mcphub.native.neovim.files.apply_edit.anchors.modifier — resolver for positional modifier anchors.
---
--- Modifiers resolve to a **zero-width position** consumed by `insert`
--- ops — `replace_range` and `delete_range` need ranges, not positions,
--- and the schema rejects modifier-wrapped anchors on those op kinds.
---
--- ## The three modifiers
---
--- | Modifier  | Wraps                     | Position                                   |
--- |-----------|---------------------------|--------------------------------------------|
--- | `before`  | a base anchor `of`        | the seam *above* the base span (before S)  |
--- | `after`   | a base anchor `of`        | the seam *below* the base span (after E)   |
--- | `between` | two texts before/after_text | the seam *between* the two adjacent texts |
---
--- `before`/`after` pin to the **outer** edges of the span their base
--- anchor resolves to: `before` → before its first line, `after` → after
--- its last line. The span is matched purely to be unique; the seam is
--- always one of its two outer faces.
---
--- `between` exists for the case `before`/`after` cannot express: a seam
--- whose disambiguating context straddles it — some lines *above* the
--- insertion point and the line that makes the location unique *below*
--- it (or vice versa). You name the two sides directly: `before_text` is
--- the text immediately before the seam, `after_text` the text immediately
--- after. The engine matches `before_text .. "\n" .. after_text` as a
--- single contiguous block (so the *concatenation* must be unique, not
--- either side alone) and places the seam at the join. This reuses the
--- `unique_text` matcher verbatim, so `between` inherits its
--- `anchor_not_found` / `anchor_ambiguous` reporting (with candidates) for
--- free.
---
--- ## The zero-width convention
---
--- A range with `end_line = start_line - 1` is a **zero-width position**:
--- nothing is replaced; new content is inserted at `start_line` and
--- existing content from `start_line` onward shifts down. This maps
--- directly to `nvim_buf_set_lines(bufnr, start_0, start_0, false, lines)`
--- (start and end indices equal — pure insertion).
---
--- ## Multi-range bases (`occurrence: "all"`)
---
--- The schema allows `before`/`after` to wrap a `unique_text` with
--- `occurrence: "all"`, but the semantics of "insert before every match"
--- are not part of MVP — `insert` ops resolve to a single position. If
--- the base resolver returns the multi-range shape `{ranges = {...}}`,
--- this resolver fails with an invariant assertion. (Real-world demand
--- for multi-position inserts can lift this later; the failure mode for
--- now is "schema accepts, planner refuses".)
---
--- @module "mcphub.native.neovim.files.apply_edit.anchors.modifier"

local line_range_anchor = require("mcphub.native.neovim.files.apply_edit.anchors.line_range")
local unique_text_anchor = require("mcphub.native.neovim.files.apply_edit.anchors.unique_text")

local M = {}

--- Dispatch a base anchor to the right resolver.
---
--- This is a small private dispatcher; the planner-side public dispatch
--- lives in `mcphub.native.neovim.files.apply_edit.anchors`. Duplicating the two-line table here keeps
--- the modifier module self-contained and avoids a require cycle.
---
--- @param base_anchor table
--- @param record mcphub.edit.FileRecord
--- @return mcphub.edit.ResolvedRange|{ranges: mcphub.edit.ResolvedRange[]}|nil
--- @return mcphub.edit.AnchorFailure|nil
local function resolve_base(base_anchor, record)
    local by = base_anchor.by
    if by == "line_range" then
        return line_range_anchor.resolve(base_anchor, record)
    end
    if by == "unique_text" then
        return unique_text_anchor.resolve(base_anchor, record)
    end
    -- v2 kinds (treesitter, lsp_symbol) are rejected at the schema layer
    -- with `unsupported_anchor_kind`, so we should never see them here.
    error(string.format("modifier.resolve_base: unknown base anchor kind %q", tostring(by)))
end

--- Number of lines a (possibly multi-line) string occupies. A string with
--- no `\n` is one line; each `\n` adds one. A trailing `\n` is not expected
--- in anchor text (the LLM sends a verbatim slice), but if present it would
--- count the empty final segment — callers pass the `before_text` side,
--- which is the text immediately preceding the seam and never ends in `\n`.
---
--- @param s string
--- @return integer
local function line_count(s)
    local n = 1
    for _ in s:gmatch("\n") do
        n = n + 1
    end
    return n
end

--- Compute the resolved zero-width position for `before`/`after` applied
--- to a base range.
---
--- @param by string                   'before' | 'after'
--- @param base mcphub.edit.ResolvedRange
--- @return mcphub.edit.ResolvedRange
local function apply_edge(by, base)
    local S, E = base.start_line, base.end_line
    if by == "before" then
        return { start_line = S, end_line = S - 1 }
    elseif by == "after" then
        return { start_line = E + 1, end_line = E }
    else
        error("modifier.apply_edge: unknown modifier `by`: " .. tostring(by))
    end
end

--- Resolve a `between { before_text, after_text }` modifier.
---
--- Matches `before_text .. "\n" .. after_text` as a single contiguous block
--- via the `unique_text` resolver, then places the seam at the join between
--- the last line of `before_text` and the first line of `after_text`. The
--- block must be unique; ambiguity / not-found failures propagate from
--- `unique_text`.
---
--- @param anchor table                { by = 'between', before_text = string, after_text = string }
--- @param record mcphub.edit.FileRecord
--- @return mcphub.edit.ResolvedRange|nil
--- @return mcphub.edit.AnchorFailure|nil
local function resolve_between(anchor, record)
    local before_text, after_text = anchor.before_text, anchor.after_text
    local block = before_text .. "\n" .. after_text
    local result, fail = unique_text_anchor.resolve({ by = "unique_text", text = block }, record)
    if fail ~= nil then
        -- Echo back the caller's actual `between` shape, not the synthetic
        -- unique_text we used internally.
        fail.anchor = anchor
        return nil, fail
    end
    -- The seam falls immediately after `before_text`'s last line.
    -- `before_text` occupies `[block.start_line .. block.start_line +
    -- n_before - 1]`, so the insertion line is `block.start_line + n_before`.
    local n_before = line_count(before_text)
    local seam_line = result.start_line + n_before
    return { start_line = seam_line, end_line = seam_line - 1 }, nil
end

--- Resolve a positional-modifier anchor against a file record.
---
--- Returns a single resolved zero-width position on success, or a
--- structured failure on error. Failures from the underlying base /
--- block match are propagated with `anchor` rewritten to echo back the
--- caller's full modifier-wrapped form (not the unwrapped internals).
---
--- @param anchor table                Validated parsed modifier anchor.
--- @param record mcphub.edit.FileRecord
--- @return mcphub.edit.ResolvedRange|nil
--- @return mcphub.edit.AnchorFailure|nil
function M.resolve(anchor, record)
    assert(type(anchor) == "table", "resolve: anchor must be a table")
    assert(
        type(record) == "table" and type(record.n_lines) == "number",
        "resolve: record must be a FileRecord (n_lines required)"
    )

    local by = anchor.by

    if by == "between" then
        assert(
            type(anchor.before_text) == "string" and anchor.before_text ~= "",
            "resolve: between requires a non-empty `before_text` string"
        )
        assert(
            type(anchor.after_text) == "string" and anchor.after_text ~= "",
            "resolve: between requires a non-empty `after_text` string"
        )
        return resolve_between(anchor, record)
    end

    assert(
        by == "before" or by == "after",
        "resolve: anchor.by must be a modifier kind (before/after/between), got: " .. tostring(by)
    )
    assert(type(anchor.of) == "table", "resolve: anchor.of must be a table (the wrapped base anchor)")

    local result, fail = resolve_base(anchor.of, record)
    if fail ~= nil then
        -- Propagate the base failure, but rewrite `anchor` to echo back
        -- the full modifier-wrapped form so the LLM sees its actual
        -- input shape (not just the unwrapped base).
        fail.anchor = anchor
        return nil, fail
    end

    -- The modifier expects a single resolved range, not a multi-range
    -- `{ranges=...}` from occurrence: "all". The schema refuses this
    -- combination at validation time (see `occurrence_all_disallowed`
    -- in schema.lua's per-op validator), so this assertion is a
    -- defence-in-depth tripwire for direct callers that bypass the
    -- schema layer — it should be unreachable from any LLM-facing path.
    assert(
        result.start_line ~= nil and result.end_line ~= nil,
        'modifier wrapping a multi-range base (occurrence: "all") reached the resolver — '
            .. "schema validation should have refused this with `occurrence_all_disallowed`. "
            .. "If you hit this from a direct Lua call, route your input through schema.validate first."
    )

    return apply_edge(by, result), nil
end

return M
