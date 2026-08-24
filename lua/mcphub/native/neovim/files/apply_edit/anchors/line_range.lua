--- mcphub.native.neovim.files.apply_edit.anchors.line_range — resolver for the `line_range` anchor kind.
---
--- Trivial by design: the schema has already validated that `start` and
--- `end_` are positive integers with `end_ >= start`. The resolver's only
--- job is to bounds-check against the actual file's line count and emit a
--- structured `anchor_not_found` failure if either endpoint is past EOF.
---
--- Why a separate resolver for the trivial case? Two reasons:
---   1. Uniform interface: every anchor kind exposes `M.resolve(anchor,
---      record)` returning the same `(range, nil) | (nil, failure)` shape,
---      so the planner can dispatch without case analysis on the failure
---      reason.
---   2. The bounds check belongs in the planner phase, not the schema. The
---      schema runs before any file is read; it cannot know `n_lines`.
---
--- @module "mcphub.native.neovim.files.apply_edit.anchors.line_range"

local schema = require("mcphub.native.neovim.files.apply_edit.schema")

local M = {}

--- The shape a resolver returns on success: a single resolved range.
--- @class mcphub.edit.ResolvedRange
--- @field start_line integer 1-based, inclusive.
--- @field end_line   integer 1-based, inclusive, >= start_line.

--- The shape a resolver returns on failure. Echoes the parsed anchor back
--- to the LLM together with a structured reason and an actionable hint.
--- The planner enriches this with `op_index` and `path` before surfacing it
--- in the response.
--- @class mcphub.edit.AnchorFailure
--- @field reason          string                   See schema.ERROR_REASONS.
--- @field anchor          table                    The parsed anchor that failed to resolve.
--- @field hint            string                   What the LLM should do next.
--- @field available_range table?                   `{ start_line = 1, end_line = n_lines }` for out-of-bounds reports.
--- @field candidates      mcphub.edit.ResolvedRange[]? Used by `unique_text`; absent for `line_range`.
--- @field total_matches   (integer|string)?         Used by `unique_text`; absent for `line_range`.

--- Resolve a `line_range` anchor against a file record.
---
--- @param anchor table                Validated anchor: `{ by = 'line_range', start = N, end = M }`.
---                                    (Field is `end_` after schema's reserved-word rewrite — see note.)
--- @param record mcphub.edit.FileRecord
--- @return mcphub.edit.ResolvedRange|nil range  On success.
--- @return mcphub.edit.AnchorFailure|nil failure  On failure.
function M.resolve(anchor, record)
    assert(type(anchor) == "table", "resolve: anchor must be a table")
    assert(anchor.by == "line_range", 'resolve: anchor.by must be "line_range", got: ' .. tostring(anchor.by))
    assert(
        type(record) == "table" and type(record.n_lines) == "number",
        "resolve: record must be a FileRecord (n_lines required)"
    )

    -- The schema stores the user's `end` field under Lua's `['end']` key
    -- because `end` is a reserved word and `t.end` is a syntax error.
    -- Other anchor consumers (and the response) should also use `['end']`
    -- on the parsed-anchor table.
    local start_line = anchor.start
    local end_line = anchor["end"]

    -- The schema guarantees start >= 1 and end >= start (both integers).
    -- We re-assert internally to harden against a planner bug or a
    -- hand-constructed anchor that bypassed validation.
    assert(
        type(start_line) == "number" and start_line >= 1,
        "line_range: start must be an integer >= 1, got: " .. tostring(start_line)
    )
    assert(
        type(end_line) == "number" and end_line >= start_line,
        string.format("line_range: end (%s) must be >= start (%s)", tostring(end_line), tostring(start_line))
    )

    local n_lines = record.n_lines

    -- An empty file has zero lines. Any line_range anchor against it
    -- fails — there is no "line 1" to anchor to.
    if n_lines == 0 then
        return nil,
            {
                reason = schema.ERROR_REASONS.anchor_not_found,
                anchor = anchor,
                hint = "the file has zero lines; no line_range anchor can resolve. Use `neovim__write_file` to create content.",
                available_range = { start_line = 0, end_line = 0 },
            }
    end

    -- Out-of-bounds: either endpoint past the last line of the file.
    -- We report a single failure that names both endpoints; the LLM does
    -- not need two separate errors for "start too high" and "end too
    -- high" — they're the same self-correction (re-read the file, pick
    -- valid line numbers).
    if start_line > n_lines or end_line > n_lines then
        return nil,
            {
                reason = schema.ERROR_REASONS.anchor_not_found,
                anchor = anchor,
                hint = string.format(
                    "line_range { start=%d, end=%d } is out of bounds; the file has %d line(s). "
                        .. "Re-read the file with neovim__read_with_fingerprint to see current line numbers.",
                    start_line,
                    end_line,
                    n_lines
                ),
                available_range = { start_line = 1, end_line = n_lines },
            }
    end

    return { start_line = start_line, end_line = end_line }, nil
end

return M
