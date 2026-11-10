--- mcphub.native.neovim.files.apply_edit.engine — structured, batch-atomic file-edit engine.
---
--- The pure engine behind the MCP tool `neovim__apply_edit`. Deliberately
--- client-agnostic: no mcphub, no LLM, no MCP, no UI imports. Inputs are
--- typed Lua tables; outputs are typed Lua tables. The tool surface at
--- `lua/mcphub/native/neovim/files/apply_edit/init.lua` is the only file
--- that bridges this engine to the MCP world.
---
--- @module "mcphub.native.neovim.files.apply_edit.engine"

local applier = require("mcphub.native.neovim.files.apply_edit.applier")
local planner = require("mcphub.native.neovim.files.apply_edit.planner")
local schema = require("mcphub.native.neovim.files.apply_edit.schema")

local M = {}

-- Both failure paths below fail before any buffer is touched. Saying so spares
-- the model a re-read it would otherwise do just to refresh its fingerprints.
local NOTHING_APPLIED = "Nothing was applied, so every file without a stale_fingerprint failure is exactly "
    .. "as you read it: fix the failed ops and resubmit with the same baseline_fingerprint, "
    .. "without re-reading."

--- Render a list of schema errors as `failed[]` entries in the canonical
--- response shape. Each error becomes one entry with `reason = "schema_invalid"`
--- and the structured field details promoted to top-level keys.
local function errors_to_failed(errors)
    local failed = {}
    for _, e in ipairs(errors) do
        table.insert(failed, {
            op_index = e.op_index ~= nil and e.op_index or vim.NIL,
            reason = "schema_invalid",
            path = e.path,
            sub_reason = e.reason, -- the schema's own taxonomy (missing_field, wrong_type, …)
            message = e.message,
            hint = e.hint,
            expected = e.expected,
            got = e.got,
        })
    end
    return failed
end

--- Forward planner failures as `failed[]` entries. Each planner failure
--- already carries `reason` (from `schema.ERROR_REASONS`), `op_index`,
--- `path`, and reason-specific fields (`candidates`, `live_fingerprint`,
--- etc.); we pass them through verbatim.
local function planner_failures_to_failed(failures)
    local failed = {}
    for _, f in ipairs(failures) do
        local entry = {}
        for k, v in pairs(f) do
            entry[k] = v
        end
        failed[#failed + 1] = entry
    end
    return failed
end

--- Text of line `n` of `rec`, without its newline.
local function line_at(rec, n)
    local to = (rec.offsets[n + 1] or #rec.content + 1) - 1
    return (rec.content:sub(rec.offsets[n], to):gsub("\n$", ""))
end

--- The lines that show where a range sits, which is where an off-by-one
--- shows: all of a short range, the first and last line of a long one, and
--- the two neighbours of an insertion seam.
---
--- @param rec   mcphub.edit.FileRecord
--- @param range mcphub.edit.ResolvedRange
--- @return { line: integer, text: string }[]
local function boundary_lines(rec, range)
    local s, e = range.start_line, range.end_line
    local picks = {}
    if e < s then
        picks = { s - 1, s }
    elseif e - s <= 2 then
        for n = s, e do
            picks[#picks + 1] = n
        end
    else
        picks = { s, e }
    end
    local out = {}
    for _, n in ipairs(picks) do
        if n >= 1 and n <= rec.n_lines then
            out[#out + 1] = { line = n, text = line_at(rec, n) }
        end
    end
    return out
end

--- The response to a `dry_run` whose plan resolved: where every op would
--- land, and nothing applied.
---
--- @param plan mcphub.edit.Plan
--- @return table
local function dry_run_response(plan)
    local planned = {}
    for _, lop in ipairs(plan.located_ops) do
        for _, range in ipairs(lop.range and { lop.range } or lop.ranges) do
            planned[#planned + 1] = {
                op_index = lop.op_index,
                path = lop.path,
                kind = lop.kind,
                range = { start_line = range.start_line, end_line = range.end_line },
                preview = boundary_lines(plan.records[lop.path], range),
            }
        end
    end
    return {
        status = "dry_run",
        summary = string.format("dry run: %d op(s) resolved", #plan.located_ops),
        note = "Nothing was applied, so every file is exactly as you read it: resubmit without "
            .. "`dry_run` and with the same baseline_fingerprint to apply.",
        planned = planned,
        applied = {},
        rejected = {},
        failed = {},
        files = {},
        warnings = plan.warnings or {},
    }
end

--- Apply a batch of edit operations.
---
--- ## LLM-facing seal (architectural invariant)
---
--- This function is the engine's **single LLM-facing entry point**. The
--- mcphub adapter calls it with the raw decoded request, a driver
--- callback, and a completion callback — nothing else. It deliberately
--- takes **no opts table**: the internal modules below this function
--- (`schema.validate`, `planner.plan`) accept opts including
--- `bypass_fingerprint = true` for test isolation, and threading that
--- through here would expose a production-side relaxation path. Keeping
--- `M.apply` opts-free is what makes "the LLM cannot bypass fingerprint
--- enforcement" a structural property rather than a code-review property.
---
--- `drive_file` and `on_complete` are continuations, not configuration —
--- they're caller-provided callable channels, not opts. They cannot be
--- expressed in the MCP tool's JSON Schema (which is the LLM-facing
--- surface), so an LLM cannot reach them.
---
--- ## Async by design
---
--- `M.apply` returns nothing. The response is delivered to `on_complete`
--- once the planner-or-applier phase finishes. Schema-only failures fire
--- `on_complete` synchronously from within `M.apply`; planner / applier
--- paths fire it from `vim.schedule` contexts. Callers needing
--- synchronous semantics `vim.wait(...)` on a flag set by `on_complete`.
---
--- @param input       table        Decoded request body (raw, untyped — validation happens here).
--- @param drive_file  fun(req: mcphub.edit.applier.FileRequest, file_cb: fun(o: mcphub.edit.applier.FileOutcome))
---                    The per-file driver. Conforms to the contract documented in
---                    `mcphub.native.neovim.files.apply_edit.applier.apply_plan`. Production callers pass
---                    `mcphub.native.neovim.files.apply_edit.ui_backend.drive_file`;
---                    tests pass a synthetic driver (e.g. an accept-all backend).
--- @param on_complete fun(response: table)  Delivers the structured response.
function M.apply(input, drive_file, on_complete)
    assert(type(drive_file) == "function", "apply: drive_file must be a function")
    assert(type(on_complete) == "function", "apply: on_complete must be a function")

    -- Phase 1: schema validation. On failure we deliver immediately with
    -- one `failed[]` entry per error. No opts are threaded through —
    -- see the seal note in this function's docstring.
    local ok, parsed_or_errors = schema.validate(input)
    if not ok then
        return on_complete({
            status = "failed",
            summary = schema.format_error_summary(parsed_or_errors),
            note = NOTHING_APPLIED,
            applied = {},
            rejected = {},
            failed = errors_to_failed(parsed_or_errors),
            files = {},
            warnings = {},
        })
    end
    local parsed = parsed_or_errors

    -- Phase 2: planning. Read files, validate fingerprints, resolve
    -- anchors, detect cross-op range conflicts. On any per-op failure
    -- we deliver before opening any UI — the LLM gets ALL problems in
    -- one round-trip.
    local plan, plan_fail = planner.plan(parsed)
    if not plan then
        assert(plan_fail, "planner.plan returned (nil, nil); invariant violated")
        return on_complete({
            status = "failed",
            summary = string.format("planning failed: %d issue(s)", #plan_fail.failures),
            note = NOTHING_APPLIED,
            applied = {},
            rejected = {},
            failed = planner_failures_to_failed(plan_fail.failures),
            files = {},
            warnings = plan_fail.warnings or {},
        })
    end

    -- A dry run stops here: the plan resolved, so report where each op would
    -- land without touching a buffer or opening a review.
    if parsed.dry_run then
        return on_complete(dry_run_response(plan))
    end

    -- Phase 3: apply. Async; the response is delivered via on_complete
    -- when every file has been driven.
    applier.apply_plan(plan, {}, drive_file, on_complete)
end

return M
