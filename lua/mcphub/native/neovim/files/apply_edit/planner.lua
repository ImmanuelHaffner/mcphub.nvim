--- mcphub.native.neovim.files.apply_edit.planner — orchestrate file reads + anchor resolution + conflict detection.
---
--- The planner is the read-only middle phase of `apply_edit`:
---
---   1. Schema (`schema.lua`)   →  validated `parsed_input`  →
---   2. Planner (this module)   →  located ops + records      →
---   3. Applier (later)         →  buffer mutations + review UI.
---
--- The planner never writes to a buffer or to disk. It only reads files
--- (via `file_record.read` — buffer-first; see `file_record.lua`),
--- resolves anchors (via `anchors.resolve`), and detects cross-op range
--- conflicts within the same batch.
---
--- ## Output shape
---
--- On success, returns a `Plan`:
---   {
---     located_ops = LocatedOp[],
---     records     = { [abs_path] = FileRecord },
---     warnings    = Warning[],            -- forwarded from schema + planner-added
---   }
---
--- where each `LocatedOp` is:
---   {
---     op_index = 1-based integer (Lua-native; matches parsed_input.ops[op_index]),
---     kind     = 'replace_range' | 'insert' | 'delete_range',
---     path     = absolute path (matches a key in records),
---     range    = { start_line, end_line }            -- single-range case
---     ranges   = { ResolvedRange, ... }              -- only for delete_range + occurrence:"all"
---     content  = string?                              -- resolved content for replace/insert
---     indent   = 'match_anchor' | 'preserve' | 'detect',
---   }
---
--- `range` and `ranges` are mutually exclusive — exactly one is present.
---
--- On failure, returns `(nil, { failures = Failure[], warnings = Warning[] })`.
--- Failures are per-op; the planner accumulates all of them before
--- returning, so the LLM sees every problem in one round-trip rather
--- than fixing one at a time.
---
--- ## Range conflict semantics (MVP, conservative)
---
--- Two ops in the same file conflict iff their **inclusive line sets**
--- intersect. The line set of a range `[s, e]` is `{s, s+1, ..., e}`;
--- for a zero-width position `[s, s-1]` (an insertion) the line set is
--- `{s}` — i.e. the insertion is treated as "touching the line it sits
--- before".
---
--- This rule is conservative: it flags some technically-safe edits as
--- conflicts (e.g. `replace_range [3..5]` plus `insert after line 5`
--- would be flagged because both touch line 5, even though the insert
--- actually places content between lines 5 and 6). Conservative is the
--- right call for MVP — false positives are clear errors the LLM can
--- fix by reordering or splitting into two batches; false negatives
--- would be silent corruption. Relax later if real usage shows the rule
--- is too restrictive.
---
--- ## Fingerprint validation
---
--- For each op, the planner computes the live file's fingerprint and
--- compares it against `op.baseline_fingerprint`. Mismatch produces a
--- `stale_fingerprint` failure carrying both the live fingerprint and
--- the content, so the LLM can replan in its next turn without an
--- extra read round-trip. The check runs between `read_files` and
--- `resolve_anchors` because there's no point resolving anchors
--- against bytes the LLM didn't see.
---
--- The check is gated on `opts.bypass_fingerprint`. When true (a
--- test-only bypass), the planner skips the fingerprint phase entirely
--- — useful for spec files that exercise anchor / conflict logic
--- without threading synthetic fingerprints. The bypass is per-call
--- and never reaches `mcphub.native.neovim.files.apply_edit.engine.apply(input)`, the LLM-facing seal.
---
--- @module "mcphub.native.neovim.files.apply_edit.planner"

--- ## Indexing convention
---
--- `op_index` everywhere in this module is **1-based Lua-native** —
--- the same `op_index` you'd use as `parsed_input.ops[op_index]`. The
--- 0-based JSON form is produced only by `response.lua` when emitting
--- the wire output. See `schema.lua`'s header for the load-bearing
--- rationale.

local anchors = require("mcphub.native.neovim.files.apply_edit.anchors")
local file_record = require("mcphub.native.neovim.files.apply_edit.file_record")
local fingerprint = require("mcphub.native.neovim.files.apply_edit.fingerprint")
local indent = require("mcphub.native.neovim.files.apply_edit.indent")
local schema = require("mcphub.native.neovim.files.apply_edit.schema")

local M = {}

--- A located op — anchor resolved, content materialised. Ready for the
--- applier to convert into a `LocatedBlock` for `EditUI`.
--- @class mcphub.edit.LocatedOp
--- @field op_index integer
--- @field kind     string                              'replace_range' | 'insert' | 'delete_range'
--- @field path     string                              Absolute path (matches a `records` key).
--- @field range    mcphub.edit.ResolvedRange?             Single-range case (mutually exclusive with `ranges`).
--- @field ranges   mcphub.edit.ResolvedRange[]?           Multi-range case for delete_range + occurrence:"all".
--- @field content  string?                             For replace_range / insert, the resolved content string.
--- @field indent   string                              'match_anchor' | 'preserve' | 'detect'.

--- A planner Plan — what the applier consumes.
--- @class mcphub.edit.Plan
--- @field located_ops mcphub.edit.LocatedOp[]
--- @field records     table<string, mcphub.edit.FileRecord>
--- @field warnings    table[]

--- A planner failure — produced when at least one op cannot be resolved
--- or when ops conflict on ranges within the same file.
--- @class mcphub.edit.PlanFailure
--- @field failures   table[]
--- @field warnings   table[]

--- Resolve `op.content` / `op.content_ref` to a single content string.
---
--- The schema has already validated that exactly one is set and (for
--- `content_ref`) that the label resolves in `contents`. This function
--- just performs the lookup.
---
--- @param op       table
--- @param contents table<string, string>
--- @return string?  nil if the op produces no content (delete_range).
local function resolve_content(op, contents)
    if op.content ~= nil then
        return op.content
    end
    if op.content_ref ~= nil then
        return contents[op.content_ref]
    end
    return nil -- delete_range
end

--- Test whether two resolved ranges conflict (share any line in their
--- inclusive line sets, per the MVP conservative rule).
---
--- @param a mcphub.edit.ResolvedRange
--- @param b mcphub.edit.ResolvedRange
--- @return boolean
local function ranges_conflict(a, b)
    local as, ae = a.start_line, a.end_line
    local bs, be = b.start_line, b.end_line
    -- Normalise zero-width into a single line marker.
    local a_lo, a_hi = as, (ae < as) and as or ae
    local b_lo, b_hi = bs, (be < bs) and bs or be
    return a_lo <= b_hi and b_lo <= a_hi
end

--- Read all files referenced by `ops`, returning a `{path → FileRecord}`
--- map and per-op IO failures.
---
--- Each unique absolute path is read exactly once. The `bufadd` +
--- `bufload` machinery inside `file_record.read` is itself idempotent,
--- but de-duplicating here saves one `nvim_buf_get_lines` per duplicate
--- reference.
---
--- @param ops table[]  Validated parsed ops.
--- @return table<string, mcphub.edit.FileRecord> records
--- @return table[]                            io_failures  One entry per op whose path failed to load.
local function read_files(ops)
    local records, io_failures = {}, {}
    local tried = {} -- abs path → 'failed' marker once we've seen it can't load
    for op_index, op in ipairs(ops) do
        local raw = op.path
        local abs = vim.fn.fnamemodify(raw, ":p")

        if records[abs] == nil and tried[abs] ~= "failed" then
            local rec, err = file_record.read(abs)
            if rec then
                records[abs] = rec
            else
                tried[abs] = "failed"
                -- Record this failure and skip; subsequent ops with the same
                -- path will get their own failure entry pointing at the
                -- same root cause.
                io_failures[#io_failures + 1] = {
                    op_index = op_index,
                    path = raw,
                    reason = schema.ERROR_REASONS.io_error,
                    message = err or "file_record.read returned nil with no error",
                    hint = "verify the path exists and is readable; " .. "use neovim__write_file to create new files.",
                }
            end
        elseif tried[abs] == "failed" then
            -- Subsequent op referencing the same broken path. Still surface
            -- it so the LLM doesn't have to re-derive that all ops on this
            -- path failed together.
            io_failures[#io_failures + 1] = {
                op_index = op_index,
                path = raw,
                reason = schema.ERROR_REASONS.io_error,
                message = string.format("file %q could not be loaded (see earlier op)", raw),
                hint = "this op shares its target path with an earlier failed op; fix that one first.",
            }
        end
    end
    return records, io_failures
end

--- Resolve every op's anchor against its file record. Accumulates
--- failures rather than short-circuiting — the LLM sees all problems at
--- once.
---
--- Skips ops whose file failed to load (those already produced an
--- io_error failure in `read_files`).
---
--- @param ops      table[]
--- @param contents table<string, string>
--- @param records  table<string, mcphub.edit.FileRecord>
--- @return mcphub.edit.LocatedOp[]
--- @return table[]                       anchor_failures
local function resolve_anchors(ops, contents, records)
    local located, failures = {}, {}
    for op_index, op in ipairs(ops) do
        local abs = vim.fn.fnamemodify(op.path, ":p")
        local rec = records[abs]
        if rec == nil then
            -- IO failure already recorded; skip.
        else
            local result, fail = anchors.resolve(op.anchor, rec)
            if fail then
                -- Enrich the failure with op_index + path.
                fail.op_index = op_index
                fail.path = op.path
                failures[#failures + 1] = fail
            else
                local lop = {
                    op_index = op_index,
                    kind = op.kind,
                    path = abs,
                    content = resolve_content(op, contents),
                    indent = op.indent,
                }
                if result.ranges then
                    lop.ranges = result.ranges
                else
                    lop.range = result -- single ResolvedRange
                end
                -- Apply the `match_anchor` reindentation rule. Only
                -- content-producing ops with a single resolved range are
                -- eligible: `delete_range` has no content, and the
                -- multi-range `occurrence:"all"` shape is delete-only.
                -- `match_anchor` is also where `detect` lands (the schema
                -- downgrades `detect` to `match_anchor` with a warning);
                -- `preserve` keeps content verbatim.
                if lop.content ~= nil and lop.range ~= nil and lop.indent == "match_anchor" then
                    lop.content = indent.reindent(lop.content, rec, lop.range)
                end
                located[#located + 1] = lop
            end
        end
    end
    return located, failures
end

--- Detect cross-op range conflicts within each file.
---
--- For each file, compare every pair of resolved ranges across ops. If
--- two ranges share at least one line (inclusive set), emit a
--- `range_conflict` failure for the LATER op (higher op_index) — the
--- LLM should treat the earlier one as authoritative and reorder or
--- split. Conflicts within a single op's multi-range result (from
--- `occurrence: "all"`) are not flagged: those ranges came from the
--- same anchor and are inherently disjoint (non-overlapping match
--- scanning guarantees this).
---
--- O(N²) per file in the number of ops touching it. For an MVP this is
--- fine — typical batches have a handful of ops. If we ever care, sort
--- by start_line and sweep.
---
--- @param located_ops mcphub.edit.LocatedOp[]
--- @return table[] conflicts
local function detect_conflicts(located_ops)
    -- Group ops by path. Within each group, walk pairs.
    local by_path = {}
    for _, lop in ipairs(located_ops) do
        by_path[lop.path] = by_path[lop.path] or {}
        local list = by_path[lop.path]
        list[#list + 1] = lop
    end

    local conflicts = {}
    for path, ops in pairs(by_path) do
        for i = 1, #ops do
            for j = i + 1, #ops do
                local a, b = ops[i], ops[j]
                -- Compare every range of a against every range of b.
                local a_ranges = a.range and { a.range } or a.ranges
                local b_ranges = b.range and { b.range } or b.ranges
                local found = false
                for _, ar in ipairs(a_ranges) do
                    for _, br in ipairs(b_ranges) do
                        if ranges_conflict(ar, br) then
                            -- Emit the failure against the LATER op.
                            local later, earlier
                            local later_r, earlier_r
                            if a.op_index < b.op_index then
                                later, earlier = b, a
                                later_r, earlier_r = br, ar
                            else
                                later, earlier = a, b
                                later_r, earlier_r = ar, br
                            end
                            conflicts[#conflicts + 1] = {
                                op_index = later.op_index,
                                reason = schema.ERROR_REASONS.range_conflict,
                                path = path,
                                range = later_r,
                                conflict_op_index = earlier.op_index,
                                conflict_range = earlier_r,
                                hint = "two ops in this batch claim overlapping ranges in the same file. "
                                    .. "Reorder or merge them, or split into two separate apply_edit calls.",
                            }
                            found = true
                            break
                        end
                    end
                    if found then
                        break
                    end
                end
            end
        end
    end
    return conflicts
end

--- Verify every op's `baseline_fingerprint` against the live file
--- fingerprint. One failure per op whose file mutated since the LLM
--- read it.
---
--- The failure carries the **live** fingerprint and the **live**
--- content, so the LLM's next-turn replan does not need an extra
--- read round-trip. The op's claimed (stale) fingerprint is also
--- echoed back as `baseline_fingerprint` for symmetry with the
--- request shape.
---
--- Skips ops whose file failed to load (those produced an io_error
--- already; no point comparing fingerprints against bytes we don't
--- have).
---
--- @param ops     table[]
--- @param records table<string, mcphub.edit.FileRecord>
--- @return table[] stale_failures
local function validate_fingerprints(ops, records)
    local failures = {}
    for op_index, op in ipairs(ops) do
        local abs = vim.fn.fnamemodify(op.path, ":p")
        local rec = records[abs]
        if rec ~= nil then
            local live = fingerprint.compute(rec.content)
            if op.baseline_fingerprint ~= live then
                failures[#failures + 1] = {
                    op_index = op_index,
                    reason = schema.ERROR_REASONS.stale_fingerprint,
                    path = op.path,
                    baseline_fingerprint = op.baseline_fingerprint,
                    live_fingerprint = live,
                    live_content = rec.content,
                    hint = "the file has changed since you read it. "
                        .. "Re-read with neovim__read_with_fingerprint to get the "
                        .. "current fingerprint and content, then replan against "
                        .. "the new line numbers / substrings.",
                }
            end
        end
    end
    return failures
end

--- Plan a batch of ops.
---
--- ## Bypass for tests
---
--- `opts.bypass_fingerprint = true` skips the `validate_fingerprints`
--- phase, letting spec files exercise anchor resolution / range
--- conflict detection without threading synthetic fingerprints through
--- every fixture. The bypass is per-call and never reaches
--- `mcphub.native.neovim.files.apply_edit.engine.apply(input)`, the LLM-facing seal: that function takes
--- no opts and calls `M.plan(parsed)` with no opts, so production
--- paths cannot relax this check.
---
--- @param parsed_input table   Output of `schema.validate`.
--- @param opts? table  Internal. `{ bypass_fingerprint = boolean? }`. Tests only.
--- @return mcphub.edit.Plan|nil   plan      On success.
--- @return mcphub.edit.PlanFailure|nil      failure   On any per-op failure.
function M.plan(parsed_input, opts)
    assert(type(parsed_input) == "table", "plan: parsed_input must be a table")
    assert(type(parsed_input.ops) == "table", "plan: parsed_input.ops must be a table")

    opts = opts or {}
    local check_fingerprints = not (opts.bypass_fingerprint == true)

    local warnings = {}
    -- Forward warnings from schema validation through the plan/failure
    -- envelope — the response wants all warnings in one place.
    if parsed_input.warnings then
        for _, w in ipairs(parsed_input.warnings) do
            warnings[#warnings + 1] = w
        end
    end

    local contents = parsed_input.contents or {}

    -- Phase 1: read every referenced file.
    local records, io_failures = read_files(parsed_input.ops)

    -- Phase 2: validate per-op baseline_fingerprint against the live
    -- file fingerprint. Anchors resolved against bytes the LLM never
    -- saw are worse than useless — the planned anchors were
    -- meaningless. So this check runs before anchor resolution and
    -- inhibits it on failure (handled below via the all_failures
    -- collation).
    local stale_failures = {}
    if check_fingerprints then
        stale_failures = validate_fingerprints(parsed_input.ops, records)
    end

    -- Phase 3: resolve anchors. Skips ops whose file failed to load.
    -- We still resolve when there are stale_failures: the planner
    -- accumulates ALL problems in one pass so the LLM sees them
    -- together. Anchor resolution against stale content may itself
    -- produce additional failures (anchor_not_found / anchor_ambiguous
    -- because the content shifted), but those are real findings; the
    -- LLM gets the most-informative response we can construct in a
    -- single round-trip.
    local located_ops, anchor_failures = resolve_anchors(parsed_input.ops, contents, records)

    -- Phase 4: detect cross-op range conflicts. Only meaningful when ALL
    -- ops resolved — otherwise we'd report conflicts against ranges that
    -- might not even exist. Skip if there are unresolved ops, to keep
    -- the LLM's signal:noise high. Stale fingerprints also inhibit
    -- conflict detection: if the content shifted, the resolved ranges
    -- are based on bytes the LLM didn't see, so cross-op conflicts on
    -- those ranges are misleading.
    local conflicts = {}
    if #anchor_failures == 0 and #io_failures == 0 and #stale_failures == 0 then
        conflicts = detect_conflicts(located_ops)
    end

    -- Collate all failures. Order: io_errors first (root-cause), then
    -- stale_fingerprint (per-op race), then anchor failures (per-op),
    -- then conflicts (cross-op).
    local all_failures = {}
    for _, f in ipairs(io_failures) do
        all_failures[#all_failures + 1] = f
    end
    for _, f in ipairs(stale_failures) do
        all_failures[#all_failures + 1] = f
    end
    for _, f in ipairs(anchor_failures) do
        all_failures[#all_failures + 1] = f
    end
    for _, f in ipairs(conflicts) do
        all_failures[#all_failures + 1] = f
    end

    if #all_failures > 0 then
        return nil, {
            failures = all_failures,
            warnings = warnings,
        }
    end

    return {
        located_ops = located_ops,
        records = records,
        warnings = warnings,
    }, nil
end

return M
