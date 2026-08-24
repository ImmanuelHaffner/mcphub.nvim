--- mcphub.native.neovim.files.apply_edit.read — the engine behind `neovim__read_with_fingerprint`.
---
--- One function — `M.read_with_fingerprint(path, opts)` — that
--- buffer-loads a file (via `FileRecord.read`, the same buffer-first
--- pipeline the planner uses), computes a baseline fingerprint over
--- its whole content (via `mcphub.native.neovim.files.apply_edit.fingerprint`), and returns both —
--- optionally restricting the returned `content` to a line range.
---
--- The LLM then carries the fingerprint verbatim on every `apply_edit`
--- op against that file (in the op's `baseline_fingerprint` field); the
--- planner re-computes and refuses the batch on mismatch.
---
--- ## Why this exists
---
--- Without fingerprints, an LLM that read a file at t0 and called
--- `apply_edit` at t2 against anchors planned against t0's content
--- has no way to detect that the file mutated at t1. Anchors may
--- resolve to the wrong location silently. With required fingerprints,
--- the planner detects the drift and aborts with `stale_fingerprint`.
---
--- This is the **canonical** read path for text files. The legacy
--- `neovim__read_file` is removed from the LLM-facing surface (by
--- user-side mcphub config) so every edit is anchored against a known
--- baseline. There is no bypass.
---
--- ## Range projection (`start_line` / `end_line`)
---
--- Both fields are optional, 1-based, inclusive — matching the rest of
--- the engine's range convention. `start_line` defaults to 1; `end_line`
--- defaults to the file's total line count.
---
--- The fingerprint is **always** computed over the whole file regardless
--- of the range. This is load-bearing: if `apply_edit` re-fingerprints
--- the whole buffer at apply time (which it does), a range-scoped
--- fingerprint would always mismatch. The range is purely a content
--- projection knob on the response.
---
--- ### Edge-case policy
---
--- * `end_line > total_lines` — silently clamped to `total_lines`. This
---   is the common "read from line N to end" pattern with a deliberately-
---   large `end_line` (e.g. 99999); clamping is the right default.
--- * `start_line > total_lines` — refused with `start_after_eof`. This
---   indicates the LLM held a stale view of the file's length and the
---   request is recoverable in one round-trip by reading without a
---   `start_line` first to discover `total_lines`.
--- * `start_line > end_line` (both **explicitly** provided) — refused
---   with `invalid_range`. Malformed pair; not a state mismatch. When
---   only `start_line` is provided and it happens to exceed the engine's
---   `total_lines` default for `end_line`, `start_after_eof` is the
---   reported reason — the user did not actually provide a backwards
---   range.
--- * Both omitted — behaviour identical to a whole-file read.
---
--- ## What it returns
---
--- Success:
---   { status               = 'ok',
---     path                 = '<absolute path>',
---     content              = '<projected bytes>',     -- the range, or whole file
---     baseline_fingerprint = '<7-hex chars>',         -- ALWAYS whole-file
---     start_line           = N,                       -- echoed, clamped to bounds
---     end_line             = M,                       -- echoed, clamped to bounds
---     returned_lines       = M - N + 1,               -- lines in `content`
---     total_lines          = K }                      -- whole-file line count
---
--- Failure:
---   { status   = 'failed',
---     summary  = '<one-line summary>',
---     failed   = { { reason, path, message, hint, ... } } }
---
--- The failure shape mirrors `apply_edit`'s `failed[]` entries so the
--- LLM sees a uniform error structure across both tools.
---
--- @module "mcphub.native.neovim.files.apply_edit.read"

local file_record = require("mcphub.native.neovim.files.apply_edit.file_record")
local fingerprint = require("mcphub.native.neovim.files.apply_edit.fingerprint")
local schema = require("mcphub.native.neovim.files.apply_edit.schema")

local M = {}

--- Build a single-entry failure response. Mirrors apply_edit's failed[] shape.
---
--- @param summary string  One-line summary for the response.
--- @param entry table  The single failure record. Required keys: `reason`, `path`, `message`. Optional: `hint`, and any reason-specific fields.
--- @return table response
local function failure(summary, entry)
    return {
        status = "failed",
        summary = summary,
        failed = { entry },
    }
end

--- Validate the optional `start_line` / `end_line` fields.
---
--- This is **schema-shape** validation only (type, minimum). State-level
--- checks against the actual file (start_after_eof, invalid_range with
--- known total_lines, clamping) happen after the file is loaded.
---
--- Returns `(failure, _, _)` on a validation error (where `failure` is a
--- complete response table the caller should return verbatim), or
--- `(nil, start, end)` on success — where `start` and `end` are either
--- `nil` (the field was omitted) or a positive integer.
---
--- @param raw_path string  The original path argument; used in error responses.
--- @param opts table  The (already-confirmed-table) opts argument.
--- @return table|nil failure  Non-nil on validation error; nil on success.
--- @return integer|nil start_line  The parsed start_line, or nil if omitted.
--- @return integer|nil end_line  The parsed end_line, or nil if omitted.
local function validate_range_shape(raw_path, opts)
    --- @param name string
    --- @param value any
    --- @return table|nil failure  Non-nil on error.
    --- @return integer|nil parsed  Set iff failure is nil.
    local function check_int(name, value)
        if value == nil then
            return nil, nil
        end
        if type(value) ~= "number" or value ~= math.floor(value) then
            return failure(string.format("invalid `%s` argument", name), {
                reason = schema.ERROR_REASONS.wrong_type,
                path = raw_path,
                message = string.format("%s must be an integer, got: %s", name, type(value)),
                hint = "line numbers are integers (whole numbers with no fractional part)",
            }),
                nil
        end
        if value < 1 then
            return failure(string.format("`%s` out of range", name), {
                reason = schema.ERROR_REASONS.out_of_range,
                path = raw_path,
                message = string.format("%s must be >= 1, got: %d", name, value),
                hint = "line numbers are 1-based and inclusive; the first line is 1",
            }),
                nil
        end
        return nil, value
    end

    local fail_s, start_line = check_int("start_line", opts.start_line)
    if fail_s then
        return fail_s, nil, nil
    end
    local fail_e, end_line = check_int("end_line", opts.end_line)
    if fail_e then
        return fail_e, nil, nil
    end

    return nil, start_line, end_line
end

--- Project a range of lines from a file's full content. Inclusive, 1-based.
---
--- The projection is byte-exact: every line keeps its terminating "\n"
--- when there is one, including the last line of the file if the file
--- ends with a newline. If the range ends at the last line AND the file
--- has no trailing newline, the projection has no trailing newline.
--- This matches how `nvim_buf_get_lines` would interact with the
--- buffer's `endofline` setting.
---
--- @param rec mcphub.edit.FileRecord  The loaded file record.
--- @param start_line integer  1-based inclusive.
--- @param end_line integer  1-based inclusive. Must be <= rec.n_lines.
--- @return string content
local function project_lines(rec, start_line, end_line)
    -- Fast path: whole file.
    if start_line == 1 and end_line == rec.n_lines then
        return rec.content
    end

    -- Use FileRecord's offsets array: offsets[i] is the byte position
    -- (1-based) of the first byte of line i. The end of line i is the
    -- byte before offsets[i+1], or the end of content for the last line.
    local from = rec.offsets[start_line]
    local to
    if end_line < rec.n_lines then
        -- Up to but not including the next line's first byte. This keeps
        -- the trailing '\n' on the last projected line.
        to = rec.offsets[end_line + 1] - 1
    else
        -- end_line == n_lines: take everything to the end of content.
        -- This preserves the file's actual EOF behaviour (trailing '\n'
        -- present iff endofline was set on the buffer).
        to = #rec.content
    end
    return rec.content:sub(from, to)
end

--- Read a file and return its content plus a baseline fingerprint.
---
--- Reads via `FileRecord.read`, which is buffer-first: if the path is
--- open in a Neovim buffer (loaded), that buffer's content is the
--- source of truth (including unsaved changes); otherwise the file is
--- loaded into a fresh buffer. EOL normalisation is captured on the
--- record. The fingerprint is computed over the same byte sequence
--- the planner will re-compute at apply time.
---
--- @param path string  The file path. Will be absolutised via `:p`.
--- @param opts? { start_line?: integer, end_line?: integer }  Optional range projection. See the module docstring for the contract.
--- @return table response  Always a complete response, success or failure.
function M.read_with_fingerprint(path, opts)
    -- Input validation. Path-shape errors return as `failed[]` entries
    -- matching apply_edit's error format.
    if type(path) ~= "string" then
        return failure("invalid `path` argument", {
            reason = schema.ERROR_REASONS.wrong_type,
            path = "",
            message = "path must be a string, got: " .. type(path),
            hint = "pass the file path as a string",
        })
    end
    if path == "" then
        return failure("empty `path` argument", {
            reason = schema.ERROR_REASONS.missing_field,
            path = "",
            message = "path must not be empty",
            hint = "pass a non-empty file path",
        })
    end

    -- Validate opts shape (defensive: opts is optional, nil → empty table).
    if opts ~= nil and type(opts) ~= "table" then
        return failure("invalid `opts` argument", {
            reason = schema.ERROR_REASONS.wrong_type,
            path = path,
            message = "opts must be a table or nil, got: " .. type(opts),
            hint = "pass { start_line = N, end_line = M } or omit entirely",
        })
    end
    opts = opts or {}

    -- Shape-validate start_line / end_line (type, minimum).
    local range_failure, start_line, end_line = validate_range_shape(path, opts)
    if range_failure then
        return range_failure
    end

    local rec, err = file_record.read(path)
    if not rec then
        return failure(string.format("cannot read %q", path), {
            reason = schema.ERROR_REASONS.io_error,
            path = path,
            message = err or "file_record.read returned nil with no error",
            hint = "verify the path exists and is readable; " .. "use neovim__write_file to create new files.",
        })
    end

    local total_lines = rec.n_lines

    -- Apply defaults now that we know total_lines.
    local effective_start = start_line or 1
    local effective_end = end_line or total_lines

    -- State-level checks. The order matters:
    --
    --   1. `invalid_range`  — a malformed pair (start > end) that the LLM
    --      *explicitly provided*. This is a request-shape problem the LLM
    --      can fix without re-reading the file, so we surface it first.
    --      The check fires only when both fields were explicit; we do NOT
    --      flag invalid_range when the engine itself defaulted `end_line`
    --      to total_lines, because then the inversion came from the
    --      defaulting, not from the LLM's input.
    --
    --   2. `start_after_eof` — `start_line` exceeds the file's actual length.
    --      This is a state-level mismatch indicating the LLM held a stale
    --      view of the file; recoverable by re-reading.
    if start_line ~= nil and end_line ~= nil and start_line > end_line then
        return failure(string.format("invalid range: start_line (%d) > end_line (%d)", start_line, end_line), {
            reason = schema.ERROR_REASONS.invalid_range,
            path = path,
            message = string.format("start_line (%d) must be <= end_line (%d)", start_line, end_line),
            start_line = start_line,
            end_line = end_line,
            total_lines = total_lines,
            hint = "swap the values, or pick a single-line range with start_line == end_line",
        })
    end

    if effective_start > total_lines then
        return failure(string.format("start_line (%d) is past EOF (file has %d lines)", effective_start, total_lines), {
            reason = schema.ERROR_REASONS.start_after_eof,
            path = path,
            message = string.format("start_line (%d) exceeds total_lines (%d)", effective_start, total_lines),
            start_line = effective_start,
            end_line = effective_end,
            total_lines = total_lines,
            hint = "the file is shorter than you assumed. "
                .. "Re-read the file without `start_line` first to learn `total_lines`, "
                .. "then pick a range within bounds.",
        })
    end

    -- Silent clamp: end_line past EOF becomes total_lines. This is the
    -- "read from line N to end" pattern; clamping is the right default.
    if effective_end > total_lines then
        effective_end = total_lines
    end

    local content = project_lines(rec, effective_start, effective_end)

    return {
        status = "ok",
        path = rec.path, -- absolutised by FileRecord
        content = content,
        baseline_fingerprint = fingerprint.compute(rec.content), -- whole-file, ALWAYS
        start_line = effective_start,
        end_line = effective_end,
        returned_lines = effective_end - effective_start + 1,
        total_lines = total_lines,
    }
end

return M
