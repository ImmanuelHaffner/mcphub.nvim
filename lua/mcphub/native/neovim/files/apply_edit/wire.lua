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
--- `format` produces that flattened table; `render` turns it into the plain
--- text the model receives, for the reason `read.render` gives: excerpts,
--- candidates and previews are file text the model builds its next anchors
--- from, and inside JSON every line break, tab and quote in them is escaped.
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
    available_range = true,
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
    out.available_lines = M.lines(e.available_range)
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

--------------------------------------------------------------------------------
-- Rendering
--------------------------------------------------------------------------------

-- The lists a response groups by file, in the order a file's section shows them.
local LISTS = { "planned", "applied", "rejected", "failed" }

-- Keys of a failure or warning that its first line or its numbered lines show.
local SHOWN = {
    op = true,
    kind = true,
    lines = true,
    reason = true,
    file = true,
    field = true,
    message = true,
    candidates = true,
}

local function plural(n, noun)
    return n .. " " .. noun .. (n == 1 and "" or "s")
end

local function value_text(v)
    if type(v) ~= "table" then
        return tostring(v)
    elseif vim.islist(v) then
        return table.concat(vim.tbl_map(value_text, v), ", ")
    end
    return vim.json.encode(v)
end

--- `op 2 replace_range 10-12`
local function op_text(e)
    local words = {}
    if e.op then
        words[#words + 1] = "op " .. e.op
    end
    words[#words + 1] = e.kind
    words[#words + 1] = e.lines
    return table.concat(words, " ")
end

--- Lines labelled like `rows`' first column, right-aligned, then a tab and the text.
--- @param rows { label: string, text: string }[]
local function labelled(rows, out)
    local width = 0
    for _, r in ipairs(rows) do
        width = math.max(width, #r.label)
    end
    for _, r in ipairs(rows) do
        out[#out + 1] = string.rep(" ", width - #r.label) .. r.label .. "\t" .. r.text
    end
end

--- A failure or warning: its first line names the op, the reason and where,
--- then one indented line per detail, then any candidates numbered like a read.
local function problem(label, e, out)
    local head = label .. ": " .. (e.op and ("op " .. e.op .. " ") or "") .. tostring(e.reason)
    if e.lines then
        head = head .. " (lines " .. e.lines .. ")"
    end
    if e.field then
        head = head .. " in " .. e.field
    end
    -- With no message, the hint is what there is to say about it.
    local said = e.message and "message" or (e.hint and "hint")
    if said then
        head = head .. ": " .. e[said]
    end
    out[#out + 1] = head

    local keys = {}
    for k in pairs(e) do
        if not SHOWN[k] and k ~= said then
            keys[#keys + 1] = k
        end
    end
    table.sort(keys, function(x, y)
        return (x == "hint" and "" or x) < (y == "hint" and "" or y)
    end)
    for _, k in ipairs(keys) do
        out[#out + 1] = "  " .. k .. ": " .. value_text(e[k])
    end
    if type(e.candidates) == "table" then
        labelled(
            vim.tbl_map(function(c)
                return { label = c.lines, text = c.text }
            end, e.candidates),
            out
        )
    end
end

--- `applied: 2 ops in 1 file`, or each list's count when several are present.
local function headline(out, n_files)
    local counts = {}
    for _, list in ipairs(LISTS) do
        local ops, n = {}, 0
        for _, e in ipairs(out[list] or {}) do
            if e.op == nil or not ops[e.op] then
                n = n + 1
            end
            if e.op ~= nil then
                ops[e.op] = true
            end
        end
        if n > 0 then
            counts[#counts + 1] = { list = list, n = n }
        end
    end
    local text
    if #counts == 1 then
        text = plural(counts[1].n, "op")
    else
        text = table.concat(
            vim.tbl_map(function(c)
                return c.n .. " " .. c.list
            end, counts),
            ", "
        )
    end
    if n_files > 0 then
        text = text .. " in " .. plural(n_files, "file")
    end
    return text == "" and tostring(out.status) or (out.status .. ": " .. text)
end

local function diagnostic_lines(info, out)
    local counts = info.diagnostic_counts
    if counts then
        out[#out + 1] = string.format(
            "diagnostics: %s, %s in the file",
            plural(counts.errors or 0, "error"),
            plural(counts.warnings or 0, "warning")
        )
    end
    if info.diagnostics then
        out[#out + 1] = "near the edits:"
        for _, d in ipairs(info.diagnostics) do
            local origin = d.source and (" (" .. d.source .. (d.code and (" " .. d.code) or "") .. ")") or ""
            local message = tostring(d.message):gsub("\n", " ")
            out[#out + 1] = string.format("  %d:%d %s: %s%s", d.line, d.col, d.severity, message, origin)
        end
    end
end

--- One file's section: its path, its state and outcomes, then its excerpts.
local function file_section(name, f)
    local info = f.info or {}
    local out = { name }
    if info.fingerprint then
        out[#out + 1] = "fingerprint: " .. info.fingerprint .. (info.changes and "" or " (unchanged)")
    end
    if info.note then
        out[#out + 1] = "note: " .. info.note
    end
    if info.status then
        out[#out + 1] = "status: " .. info.status .. (info.cancel_reason and (" (" .. info.cancel_reason .. ")") or "")
    end
    for _, e in ipairs(f.planned) do
        out[#out + 1] = "planned: " .. op_text(e)
        out[#out + 1] = e.preview
    end
    if #f.applied > 0 then
        out[#out + 1] = "applied: " .. table.concat(vim.tbl_map(op_text, f.applied), ", ")
    end
    if #f.rejected > 0 then
        out[#out + 1] = "rejected: "
            .. table.concat(
                vim.tbl_map(function(e)
                    return op_text(e) .. " (" .. tostring(e.reason) .. ")"
                end, f.rejected),
                ", "
            )
    end
    for _, e in ipairs(f.failed) do
        problem("failed", e, out)
    end
    if info.changes then
        out[#out + 1] = "changes: "
            .. table.concat(
                vim.tbl_map(function(c)
                    return c.was .. " → " .. c.now
                end, info.changes),
                ", "
            )
    end
    diagnostic_lines(info, out)
    local blocks = { table.concat(out, "\n") }
    vim.list_extend(blocks, info.excerpts or {})
    return table.concat(blocks, "\n\n")
end

--- The text the model receives for a `format`ted response: a status line and
--- whatever concerns the request as a whole, then one section per file.
--- Every line of file text is numbered, so the unnumbered lines between them,
--- blank ones included, can never be mistaken for the file's.
---
--- @param out table  A `format`ted response.
--- @return string
function M.render(out)
    local files, order, loose = {}, {}, {}
    local function file(name)
        if not files[name] then
            files[name] = { planned = {}, applied = {}, rejected = {}, failed = {} }
            order[#order + 1] = name
        end
        return files[name]
    end
    for _, f in ipairs(out.files or {}) do
        file(f.file).info = f
    end
    for _, list in ipairs(LISTS) do
        for _, e in ipairs(out[list] or {}) do
            if e.file then
                table.insert(file(e.file)[list], e)
            else
                loose[#loose + 1] = e
            end
        end
    end

    local top = { headline(out, #order) }
    if out.note then
        top[#top + 1] = "note: " .. out.note
    end
    for _, e in ipairs(loose) do
        problem("failed", e, top)
    end
    for _, w in ipairs(out.warnings or {}) do
        problem("warning", w, top)
    end
    local sections = { table.concat(top, "\n") }
    for _, name in ipairs(order) do
        sections[#sections + 1] = file_section(name, files[name])
    end
    return table.concat(sections, "\n\n")
end

return M
