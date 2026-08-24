--- mcphub.native.neovim.files.apply_edit.applier — execute a planner Plan, one file at a time.
---
--- The applier is the final phase of `apply_edit`:
---
---   1. Schema   →  parsed_input
---   2. Planner  →  Plan { located_ops, records, warnings }
---   3. Applier (this module) → response { applied[], rejected[], failed[], ... }
---
--- ## What this module does
---
---   * Groups `plan.located_ops` by path, preserving op order.
---   * Sequences files: drives one file at a time, awaiting each file's
---     outcome before starting the next.
---   * Classifies per-file outcomes into `applied[]` / `rejected[]` entries
---     in the response.
---   * Implements cancel semantics: if any file is cancelled, remaining
---     files' ops are emitted as `not_attempted` failures.
---   * Composes the final structured response and delivers it via `on_done`.
---
--- ## What this module does NOT do
---
--- This module never touches a buffer, opens a window, talks to mcphub, or
--- knows about `EditUI`. It is pure plan-execution logic over Lua tables.
--- The actual buffer mutation + per-hunk review UI is delegated to a
--- caller-provided `drive_file` callback (see the `apply_plan` docstring
--- for its call contract).
---
--- This keeps `mcphub.native.neovim.files.apply_edit.engine` usable as a library by any
--- caller that wants
--- structured anchor-based edits: the default integration is mcphub's
--- `EditUI`, but tests can pass a synthetic `drive_file` that applies edits
--- non-interactively, and future callers (CLI batch mode, Telescope
--- workflow, etc.) can supply their own driver.
---
--- ## Async by design
---
--- The driver of choice — mcphub's `EditUI` — is callback-driven (delivers
--- its outcome via `vim.schedule`). `apply_plan` is therefore async: the
--- response is delivered via `on_done`, never returned. Tests `vim.wait(...)`
--- on a local flag set by `on_done`.
---
--- ## Sequential per file
---
--- Files are driven one at a time. This is non-negotiable for the mcphub
--- backend (`EditUI` installs global keymaps for its duration; two
--- simultaneous instances would conflict). Synthetic test backends are
--- free to ignore the sequencing — they'll just see one `drive_file` call
--- finish before the next starts.
---
--- Cross-file atomicity is therefore best-effort: a user rejecting file B
--- cannot roll back the write already accepted on file A. Earlier design
--- sketches with tmpfile + rename promised cross-file atomicity but were
--- incompatible with reusing `EditUI`. The response shape reflects reality
--- (`applied[]` and `rejected[]` per op).
---
--- @module "mcphub.native.neovim.files.apply_edit.applier"

--- One unit of work for `drive_file`: a single (op_index, range) pair, with
--- the bytes that should replace the range. Pure data — no mcphub or UI
--- types. For `delete_range + occurrence:"all"`, a single planner op
--- produces multiple blocks, one per resolved range.
--- @class mcphub.edit.applier.Block
--- @field block_id      string       Stable id of the form "opN_rM".
--- @field op_index      integer      1-based Lua op index from the parsed input.
--- @field kind          string       'replace_range' | 'insert' | 'delete_range'.
--- @field range         { start_line: integer, end_line: integer }  1-based inclusive; insertion is { N, N-1 }.
--- @field replace_lines string[]     Bytes to insert; `{}` for `delete_range`.

--- Per-file request passed to `drive_file`.
--- @class mcphub.edit.applier.FileRequest
--- @field file_path        string
--- @field bufnr            integer
--- @field original_content string
--- @field blocks           mcphub.edit.applier.Block[]
--- @field interactive      boolean

--- Per-file outcome delivered by `drive_file` via its `file_cb`.
---
--- ## Statuses
---
---   * `'completed'` — `drive_file` ran the batch and `per_block` describes
---     the per-block acceptance. Any blocks absent from `per_block` are
---     treated as accepted.
---   * `'cancelled'` — the user closed the editor partway. `per_block`
---     may carry partial results; absent blocks are treated as cancelled
---     (surfaced as `rejected[]` with `reason='cancelled'`). Subsequent
---     files in the batch are not attempted.
---   * `'no_changes'` — driver had nothing to apply (e.g. no blocks).
---   * `'precondition_failed'` — the driver refused to run the batch
---     because of a structural limitation that would otherwise produce
---     a wrong result. `failures[]` describes the offending ops; every
---     block in this file is surfaced as `failed[]`, no blocks are
---     surfaced as `applied[]` or `rejected[]`. The batch continues
---     with subsequent files (this is a per-file refusal, not a
---     batch-level cancel).
---
--- @class mcphub.edit.applier.FileOutcome
--- @field status        string          'completed' | 'cancelled' | 'no_changes' | 'precondition_failed'
--- @field cancel_reason string?         Present on cancelled.
--- @field per_block     table<string, string>?  block_id → 'accepted' | 'rejected' | 'partial' | 'skipped'.
--- @field failures      table[]?        Present on precondition_failed. Each entry
---                                       carries at minimum `{ op_index, reason, message }`
---                                       and may carry reason-specific extras (e.g. `range`,
---                                       `conflicting_op_indices`). Driver-supplied.
--- @field ui_summary    string?         Free-form per-file summary for the LLM.
--- @field diagnostics   mcphub.edit.Diagnostic[]?  Structured LSP diagnostics **near the
---                                       edit** — those intersecting an edited range
---                                       ± a context window (driver's choice; the
---                                       mcphub backend uses ±10 lines). All severities.
---                                       Driver-supplied; absent means "not collected".
---                                       An empty array means "collected, nothing to
---                                       report near the edit". This is intentionally
---                                       NOT the whole-file set — see `diagnostic_counts`
---                                       for the file-wide tally. See `mcphub.edit.Diagnostic`.
--- @field diagnostic_counts mcphub.edit.DiagnosticCounts?  Whole-file tally of errors and
---                                       warnings (info/hint excluded as too chatty).
---                                       Driver-supplied; absent means "not collected".
---                                       Lets the LLM orient ("the file has N errors")
---                                       without serialising every one.
---
--- A single LSP-style diagnostic, normalised for LLM consumption.
---
--- The shape is intentionally a strict subset of `vim.diagnostic.Diagnostic`,
--- with positions translated from Neovim's 0-based to our project-wide
--- 1-based convention and severity rendered as a stable lowercase string
--- rather than the integer enum. Driver-supplied: the applier never
--- introspects these.
---
--- @class mcphub.edit.Diagnostic
--- @field severity 'error' | 'warn' | 'info' | 'hint'
--- @field line     integer   1-based start line
--- @field end_line integer   1-based end line (== line for single-line diagnostics)
--- @field col      integer   1-based start column
--- @field end_col  integer   1-based end column
--- @field message  string
--- @field source   string?   e.g. "Lua Diagnostics."
--- @field code     (string|integer)?  e.g. "missing-fields"

--- Whole-file diagnostic tally. Errors and warnings only — info/hint are
--- excluded as too chatty to be worth a count. Driver-supplied.
---
--- @class mcphub.edit.DiagnosticCounts
--- @field errors   integer  whole-file error count
--- @field warnings integer  whole-file warning count

local M = {}

--------------------------------------------------------------------------------
-- Internal helpers — grouping and per-block construction
--------------------------------------------------------------------------------

--- Group `located_ops` by `path`, preserving first-seen order across files
--- and within-file op order.
---
--- @param located_ops mcphub.edit.LocatedOp[]
--- @return string[]                              ordered_paths
--- @return table<string, mcphub.edit.LocatedOp[]>   by_path
local function group_by_path(located_ops)
    local ordered_paths, by_path = {}, {}
    for _, lop in ipairs(located_ops) do
        if by_path[lop.path] == nil then
            ordered_paths[#ordered_paths + 1] = lop.path
            by_path[lop.path] = {}
        end
        table.insert(by_path[lop.path], lop)
    end
    return ordered_paths, by_path
end

--- Split a content string into lines.
---
--- * `delete_range`: returns `{}` regardless of content (always nil).
--- * `replace_range` / `insert`: split on `\n` with `trimempty = false`
---   so that content with a trailing `\n` round-trips correctly.
---
--- @param op_kind string  'replace_range' | 'insert' | 'delete_range'
--- @param content string?
--- @return string[]
local function content_to_lines(op_kind, content)
    if op_kind == "delete_range" then
        return {}
    end
    if content == nil or content == "" then
        return { "" }
    end
    return vim.split(content, "\n", { plain = true, trimempty = false })
end

--- A planner LocatedOp may carry a single `range` or (only for
--- `delete_range + occurrence:"all"`) a `ranges[]`. This helper yields
--- one normalised entry per resolved range, so downstream code doesn't
--- have to keep distinguishing the two shapes.
---
--- @param lop mcphub.edit.LocatedOp
--- @return fun(): integer?, mcphub.edit.ResolvedRange?
local function each_range(lop)
    if lop.range then
        local done = false
        return function()
            if done then
                return nil
            end
            done = true
            return 1, lop.range
        end
    end
    local ranges = lop.ranges or {}
    local i = 0
    return function()
        i = i + 1
        if i > #ranges then
            return nil
        end
        return i, ranges[i]
    end
end

--- Build the `request.blocks` list for a file's ops.
---
--- A block represents one (op_index, range) pair. For `delete_range +
--- occurrence:"all"` one op produces multiple blocks. The block carries
--- everything the driver needs to mutate the buffer plus the back-
--- references the applier uses to classify the outcome.
---
--- The shape returned here is the **pure data contract** between the
--- applier and the `drive_file` callback. It contains no mcphub types.
---
--- @param file_ops mcphub.edit.LocatedOp[]
--- @return mcphub.edit.applier.Block[]
local function build_blocks(file_ops)
    local blocks = {}
    for _, lop in ipairs(file_ops) do
        for range_idx, range in each_range(lop) do
            local replace_lines = content_to_lines(lop.kind, lop.content)
            blocks[#blocks + 1] = {
                block_id = string.format("op%d_r%d", lop.op_index, range_idx),
                op_index = lop.op_index,
                kind = lop.kind,
                range = { start_line = range.start_line, end_line = range.end_line },
                replace_lines = replace_lines,
            }
        end
    end
    return blocks
end

--------------------------------------------------------------------------------
-- Outcome classification
--------------------------------------------------------------------------------

--- Convert a per-file outcome into `applied[]` / `rejected[]` entries.
---
--- For each block in the file, look up its status in `outcome.per_block`.
--- A status of `'accepted'` (or absent on a `'completed'` file — treated
--- as no-op accept) goes to `applied[]`; `'rejected'`, `'partial'`, and
--- any cancelled block go to `rejected[]` with a reason.
---
--- @param blocks    mcphub.edit.applier.Block[]
--- @param outcome   mcphub.edit.applier.FileOutcome
--- @param file_path string
--- @return table[]  applied
--- @return table[]  rejected
local function classify_outcome(blocks, outcome, file_path)
    local applied, rejected = {}, {}
    local per_block = outcome.per_block or {}

    for _, block in ipairs(blocks) do
        local status = per_block[block.block_id]
        local entry = {
            op_index = block.op_index,
            path = file_path,
            kind = block.kind,
            range = { start_line = block.range.start_line, end_line = block.range.end_line },
        }

        if outcome.status == "cancelled" and status == nil then
            entry.reason = "cancelled"
            rejected[#rejected + 1] = entry
        elseif status == "rejected" then
            entry.reason = "rejected"
            rejected[#rejected + 1] = entry
        elseif status == "partial" then
            entry.reason = "partially_rejected"
            rejected[#rejected + 1] = entry
        else
            -- 'accepted', 'skipped' (no-op), or absent on a completed file.
            applied[#applied + 1] = entry
        end
    end
    return applied, rejected
end

--------------------------------------------------------------------------------
-- Public entry: apply_plan
--------------------------------------------------------------------------------

--- Apply a planner Plan via a caller-supplied `drive_file` callback.
--- Asynchronous: the response is delivered via `on_done`.
---
--- ## `drive_file` call contract
---
--- `drive_file(request, file_cb)` is called once per file, in plan order.
--- The applier awaits `file_cb(outcome)` before starting the next file.
---
--- ### Request shape — `mcphub.edit.applier.FileRequest`
---
---   {
---     file_path        = string,                       -- absolute path
---     bufnr            = integer,                       -- the FileRecord's loaded buffer
---     original_content = string,                        -- content as the planner saw it
---     blocks           = mcphub.edit.applier.Block[],      -- ordered as the LLM submitted them
---     interactive      = boolean,                       -- true: full review UI; false: accept-all
---   }
---
--- ### Block shape — `mcphub.edit.applier.Block`
---
---   {
---     block_id      = string,                                  -- "opN_rM" stable id
---     op_index      = integer,                                 -- 1-based Lua op index
---     kind          = 'replace_range' | 'insert' | 'delete_range',
---     range         = { start_line, end_line },                -- 1-based inclusive; insertion is { N, N-1 }
---     replace_lines = string[],                                -- bytes to insert; '{}' for delete_range
---   }
---
--- ### Outcome shape — `mcphub.edit.applier.FileOutcome`
---
---   {
---     status        = 'completed' | 'cancelled' | 'no_changes',
---     cancel_reason = string?,                                 -- present on cancelled
---     per_block     = { [block_id] = 'accepted' | 'rejected'   -- absent ⇒ treated as
---                                  | 'partial'  | 'skipped' }, -- 'accepted' on completed,
---                                                              -- 'cancelled' on cancelled.
---     ui_summary    = string?,                                 -- LLM-facing per-file summary
---   }
---
--- ### Cancel semantics
---
--- If `drive_file` returns an outcome with `status = 'cancelled'`, the
--- applier records partial results from that file and emits
--- `not_attempted` failures for every op of every subsequent file.
---
--- @param plan    mcphub.edit.Plan
--- @param opts    table?      `{ interactive = boolean? }` (default true)
--- @param drive_file fun(request: table, file_cb: fun(outcome: table))
--- @param on_done fun(response: table)
function M.apply_plan(plan, opts, drive_file, on_done)
    assert(type(plan) == "table", "apply_plan: plan must be a table")
    assert(type(plan.located_ops) == "table", "apply_plan: plan.located_ops must be a table")
    assert(type(plan.records) == "table", "apply_plan: plan.records must be a table")
    assert(type(drive_file) == "function", "apply_plan: drive_file must be a function")
    assert(type(on_done) == "function", "apply_plan: on_done must be a function")
    opts = opts or {}
    local interactive = opts.interactive ~= false

    local ordered_paths, by_path = group_by_path(plan.located_ops)

    -- Response accumulators.
    local applied, rejected, failed = {}, {}, {}
    local files_summary = {}
    local warnings = {}
    for _, w in ipairs(plan.warnings or {}) do
        warnings[#warnings + 1] = w
    end

    local idx = 0
    local cancelled_batch = false

    -- Emit `not_attempted` failures for every op of every file in `paths`.
    local function emit_not_attempted(paths)
        for _, path in ipairs(paths) do
            for _, lop in ipairs(by_path[path]) do
                for _, range in each_range(lop) do
                    failed[#failed + 1] = {
                        op_index = lop.op_index,
                        path = path,
                        reason = "not_attempted",
                        range = { start_line = range.start_line, end_line = range.end_line },
                        message = "batch cancelled by user during an earlier file; " .. "this op was not attempted",
                    }
                end
            end
        end
    end

    local function finish()
        local status
        if cancelled_batch then
            status = (#applied > 0) and "partial" or "cancelled"
        elseif #failed > 0 or #rejected > 0 then
            status = (#applied > 0) and "partial" or "failed"
        else
            status = "applied"
        end
        on_done({
            status = status,
            summary = string.format(
                "applied %d, rejected %d, failed %d across %d file(s)",
                #applied,
                #rejected,
                #failed,
                #ordered_paths
            ),
            applied = applied,
            rejected = rejected,
            failed = failed,
            files = files_summary,
            warnings = warnings,
        })
    end

    local function step()
        idx = idx + 1
        if idx > #ordered_paths then
            return finish()
        end

        local path = ordered_paths[idx]
        local rec = plan.records[path]
        assert(rec, "apply_plan: missing FileRecord for path " .. tostring(path))

        local blocks = build_blocks(by_path[path])
        local request = {
            file_path = path,
            bufnr = rec.bufnr,
            original_content = rec.content,
            blocks = blocks,
            interactive = interactive,
        }

        drive_file(request, function(outcome)
            -- Defensive defaults: a misbehaving driver shouldn't crash the applier.
            outcome = outcome or {}
            outcome.status = outcome.status or "completed"
            outcome.per_block = outcome.per_block or {}

            files_summary[#files_summary + 1] = {
                path = path,
                status = outcome.status,
                cancel_reason = outcome.cancel_reason,
                ui_summary = outcome.ui_summary,
                -- Always emit `diagnostics` as a table (possibly empty) rather
                -- than nil. JSON-encoders distinguish `[]` from absent only
                -- via explicit `vim.json.array` markers; defaulting to `{}`
                -- here keeps the wire shape stable. A driver that doesn't
                -- collect diagnostics still produces `[]`, not `null`.
                diagnostics = outcome.diagnostics or {},
                -- Whole-file error/warning tally. Unlike `diagnostics` (an
                -- array that defaults to `[]`), this is an object; default to
                -- a zeroed tally so the wire shape is stable and the LLM never
                -- has to nil-check. A driver that doesn't collect still
                -- reports `{ errors = 0, warnings = 0 }`.
                diagnostic_counts = outcome.diagnostic_counts or { errors = 0, warnings = 0 },
            }

            if outcome.status == "precondition_failed" then
                -- The driver refused to run this file's batch. Every block
                -- in this file surfaces as `failed[]`; `applied[]` and
                -- `rejected[]` get nothing. We forward `outcome.failures`
                -- verbatim, with `path` filled in for any entry that
                -- didn't carry it. The batch continues with subsequent
                -- files — this is per-file, not a batch cancel.
                for _, f in ipairs(outcome.failures or {}) do
                    local entry = {}
                    for k, v in pairs(f) do
                        entry[k] = v
                    end
                    entry.path = entry.path or path
                    failed[#failed + 1] = entry
                end
                return vim.schedule(step)
            end

            local file_applied, file_rejected = classify_outcome(blocks, outcome, path)
            for _, a in ipairs(file_applied) do
                applied[#applied + 1] = a
            end
            for _, r in ipairs(file_rejected) do
                rejected[#rejected + 1] = r
            end

            if outcome.status == "cancelled" then
                cancelled_batch = true
                local remaining = {}
                for j = idx + 1, #ordered_paths do
                    remaining[#remaining + 1] = ordered_paths[j]
                end
                emit_not_attempted(remaining)
                return finish()
            end

            -- Schedule the next file. `vim.schedule` (rather than a direct
            -- call) keeps the stack shallow on long batches and matches
            -- the rhythm of callback-driven backends like EditUI.
            vim.schedule(step)
        end)
    end

    step()
end

return M
