--- mcphub.native.neovim.files.apply_edit.wire — the LLM-facing shape of an `apply_edit` response.
---
--- The engine's response is a Lua contract shared by the applier, the drivers
--- and the specs; this module flattens it into what the model reads, at the
--- MCP boundary only. Every rule here exists because the engine shape cost the
--- model tokens or misled it:
---
---   * Empty lists, zero diagnostic tallies and boilerplate per-file summaries
---     are dropped: on a failure they used to outnumber the actual problem.
---   * `op` is the **0-based** index into the request's `ops`, the same number
---     a schema error's `field` (`ops[0].anchor`) uses. The engine counts from
---     1 internally, and emitting both conventions side by side invited
---     off-by-one corrections.
---   * `path` meant a file in planner failures and a JSON path in schema
---     failures and warnings; they become `file` and `field`.
---   * Ranges become a `lines` string, because an insertion position is the
---     zero-width range `{ N, N-1 }`, which reads like an inverted range.
---   * The echoed `anchor` and `baseline_fingerprint` are dropped: the model
---     sent them, and a multi-line `unique_text` made the echo as long as the
---     edit itself.
---
--- @module "mcphub.native.neovim.files.apply_edit.wire"

local edit_read = require("mcphub.native.neovim.files.apply_edit.read")

local M = {}

local function display_path(path)
    if type(path) ~= "string" or path == "" then
        return path
    end
    return vim.fn.fnamemodify(path, ":~")
end

--- `"12"`, `"12-14"`, or `"before 12"` for a zero-width insertion position.
--- @param range { start_line: integer, end_line: integer }?
--- @return string?
function M.lines(range)
    if type(range) ~= "table" or range.start_line == nil then
        return nil
    end
    local s, e = range.start_line, range.end_line or range.start_line
    if e < s then
        return "before " .. s
    elseif e == s then
        return tostring(s)
    end
    return s .. "-" .. e
end

local function zero_based(index)
    return type(index) == "number" and index - 1 or nil
end

-- Keys that are renamed, reshaped or dropped; everything else is copied as is.
local HANDLED = {
    op_index = true,
    path = true,
    reason = true,
    sub_reason = true,
    range = true,
    candidates = true,
    anchor = true,
    baseline_fingerprint = true,
    conflict_op_index = true,
    conflict_range = true,
    conflicting_op_indices = true,
    preview = true,
}

--- Flatten one `applied[]` / `rejected[]` / `failed[]` / `planned[]` / `warnings[]` entry.
--- @param e table
--- @return table
function M.entry(e)
    local out = { op = zero_based(e.op_index) }
    if e.reason == "schema_invalid" then
        -- A schema error's `path` is a JSON path into the request, and its
        -- own taxonomy (`missing_field`, …) says more than the umbrella reason.
        out.reason = e.sub_reason or e.reason
        out.field = e.path
    else
        out.reason = e.reason
        out.file = display_path(e.path)
    end
    out.lines = M.lines(e.range)
    if type(e.candidates) == "table" and #e.candidates > 0 then
        out.candidates = {}
        for i, c in ipairs(e.candidates) do
            out.candidates[i] = { lines = M.lines(c), text = c.text }
        end
    end
    out.conflict_op = zero_based(e.conflict_op_index)
    out.conflict_lines = M.lines(e.conflict_range)
    if type(e.conflicting_op_indices) == "table" and #e.conflicting_op_indices > 0 then
        out.conflict_ops = vim.tbl_map(zero_based, e.conflicting_op_indices)
    end
    if type(e.preview) == "table" and #e.preview > 0 then
        -- Numbered like a read; `...` marks the skipped middle of a long range.
        local fmt = "%" .. #tostring(e.preview[#e.preview].line) .. "d\t%s"
        local rows, prev = {}, nil
        for _, p in ipairs(e.preview) do
            if prev and p.line > prev + 1 then
                rows[#rows + 1] = "..."
            end
            rows[#rows + 1] = string.format(fmt, p.line, p.text)
            prev = p.line
        end
        out.preview = table.concat(rows, "\n")
    end
    for k, v in pairs(e) do
        if not HANDLED[k] and v ~= vim.NIL then
            out[k] = v
        end
    end
    return out
end

local function entries(list)
    if type(list) ~= "table" or #list == 0 then
        return nil
    end
    return vim.tbl_map(M.entry, list)
end

-- Every warning that has a `path` comes from schema validation, so it names a
-- field of the request, never a file.
local function warning_entries(list)
    if type(list) ~= "table" or #list == 0 then
        return nil
    end
    return vim.tbl_map(function(w)
        local out = M.entry(w)
        out.file, out.field = nil, w.path
        return out
    end, list)
end

--- Number an excerpt like a read, each omitted run as one unnumbered line naming it.
--- @param e { start_line: integer, lines: string[], omitted: mcphub.edit.ResolvedRange[]? }
--- @return string
local function render_excerpt(e)
    local last = e.start_line + #e.lines - 1
    local width = #tostring(last)
    local parts, from = {}, e.start_line
    local function number_upto(l)
        if l >= from then
            local slice = vim.list_slice(e.lines, from - e.start_line + 1, l - e.start_line + 1)
            parts[#parts + 1] = edit_read.number_lines(slice, from, width)
        end
    end
    for _, o in ipairs(e.omitted or {}) do
        number_upto(o.start_line - 1)
        parts[#parts + 1] = string.format(
            "%s⋮\t%d–%d: %d lines as you sent them",
            string.rep(" ", width - 1),
            o.start_line,
            o.end_line,
            o.end_line - o.start_line + 1
        )
        from = o.end_line + 1
    end
    number_upto(last)
    return table.concat(parts, "\n")
end

--- A per-file entry, or nil when it would say nothing `applied[]` does not.
--- @param f table
--- @return table?
local function file_entry(f)
    local out = {}
    if f.status ~= "completed" then
        out.status = f.status
        out.cancel_reason = f.cancel_reason
    end
    if type(f.diagnostics) == "table" and #f.diagnostics > 0 then
        out.diagnostics = f.diagnostics
    end
    local counts = f.diagnostic_counts
    if type(counts) == "table" and ((counts.errors or 0) > 0 or (counts.warnings or 0) > 0) then
        out.diagnostic_counts = counts
    end
    -- `ui_summary` is left out: EditUI's text restates `rejected[]` in its own
    -- terms (1-based block ids, an absolute path, the lines the model sent).
    -- A fingerprint only for a file the model has seen as it is now: one still
    -- exactly as it read it, or one whose every change is shown here. See
    -- `readback.lua`.
    local rb = f.readback
    if type(rb) == "table" then
        if rb.changed == false then
            out.fingerprint = rb.fingerprint
        elseif rb.excerpts then
            out.fingerprint = rb.fingerprint
            out.changes = vim.tbl_map(function(c)
                return { was = M.lines(c.old), now = M.lines(c.new) }
            end, rb.changes)
            if #rb.excerpts > 0 then
                out.excerpts = vim.tbl_map(render_excerpt, rb.excerpts)
            end
        else
            out.note = "changed too much to show here; re-read it before editing it again"
        end
    end
    if next(out) == nil then
        return nil
    end
    out.file = display_path(f.path)
    return out
end

--- @param response table  The engine's response.
--- @return table
function M.format(response)
    local out = {
        status = response.status,
        summary = response.summary,
        note = response.note,
        planned = entries(response.planned),
        applied = entries(response.applied),
        rejected = entries(response.rejected),
        failed = entries(response.failed),
        warnings = warning_entries(response.warnings),
    }
    local files = {}
    for _, f in ipairs(response.files or {}) do
        files[#files + 1] = file_entry(f)
    end
    out.files = #files > 0 and files or nil
    return out
end

return M
