--- mcphub.native.neovim.files.apply_edit.ui_backend — `drive_file` callback driven by mcphub's `EditUI`.
---
--- ## Why this file is separate from the engine
---
--- The pure engine (`…apply_edit.engine` and its submodules) deliberately does
--- not import anything from mcphub. This file is the bridge: it implements the
--- `drive_file` shape documented in
--- `mcphub.native.neovim.files.apply_edit.applier.apply_plan` against mcphub's
--- `EditUI`. Any caller wanting a non-mcphub backend (CLI batch mode, a
--- synthetic test driver, etc.) can write a sibling that conforms to the
--- same call contract.
---
--- ## What we reuse from mcphub
---
--- Only `EditUI` itself — not `EditSession`, `DiffParser`, or
--- `BlockLocator`. Those comprise the SEARCH/REPLACE protocol layer we're
--- replacing. `EditUI` is the reusable piece: open file → apply changes →
--- per-hunk review (when interactive) → write. We feed it pre-resolved
--- `LocatedBlock`s constructed from the applier's `Block[]` request.
---
--- Load-bearing observations about `EditUI`'s shape, established by reading it:
--- `interactive` propagation, `completed_hunks` snapshot timing, `cleanup()`
--- nils state, `get_summary` is async, and `_apply_all_changes` sorts ascending
--- internally.
---
--- @module "mcphub.native.neovim.files.apply_edit.ui_backend"

local M = {}

--- Widen a zero-width-range or empty-replace block by borrowing one
--- neighbouring buffer line, so that the `LocatedBlock` handed to mcphub's
--- `EditUI` has both `found_lines` and `replace_lines` non-empty.
---
--- ## Why this exists
---
--- `EditUI._generate_hunk_blocks` constructs the inputs to `vim.diff` as
--- `table.concat(lines, "\n") .. "\n"`. For an empty list this is `"\n"`,
--- which `vim.diff` interprets as a **single empty line**, not zero lines.
--- That breaks two ways:
---
---   * **Pure deletion** (our `delete_range`, `replace_lines == []`):
---     `vim.diff` reports `new_count = 1` instead of `0`. The hunk is
---     classified as `"change"` instead of `"deletion"`; the "change"
---     branch in `_highlight_hunk_block` then calls `nvim_buf_set_extmark`
---     with an `end_row` past the (now-shorter) buffer, crashing with
---     `E5111: Invalid 'end_row': out of range`.
---
---   * **Pure insertion** (zero-width range, `found_lines == []`):
---     `vim.diff` reports `old_count = 1` instead of `0`. Hunk becomes
---     `"change"` instead of `"addition"`; the highlighted row is off by
---     one. (Doesn't crash, but mishighlights.)
---
--- The principled fix is in mcphub. The pragmatic fix is here: synthesise
--- a non-zero-width pair by borrowing one adjacent buffer line. `vim.diff`
--- then naturally splits the resulting pair into a clean addition or
--- deletion sub-hunk (the borrowed line becomes context), so the user
--- sees correct highlighting and `EditUI`'s apply path produces the
--- byte-identical buffer state.
---
--- ## Borrowing strategy
---
---   * **Pure insert** (`range = { N, N-1 }`, `replace_lines = R`):
---     borrow line `N` if it exists, else line `N-1` (insert-at-EOF case).
---     Widen the range to cover the borrowed line and append/prepend it
---     to `replace_lines` so the net buffer effect is unchanged.
---
---   * **Pure delete** (`range = { S, E }`, `replace_lines = []`):
---     borrow line `E+1` if it exists, else line `S-1` (delete-to-EOF).
---     Widen the range to cover the borrowed line; `replace_lines`
---     becomes `[borrowed]`.
---
---   * **Pure delete of the entire buffer** (`S == 1`, `E == #buf`,
---     `replace_lines = []`): no line to borrow on either side. Returns
---     `nil`; the caller must apply this block via a direct
---     `nvim_buf_set_lines` path instead of going through `EditUI`. (Not
---     reachable from the MVP anchor set in practice — would require a
---     user-issued `delete_range` covering all lines.)
---
--- @param bufnr integer
--- @param block mcphub.edit.applier.Block
--- @return mcphub.edit.applier.Block?  Widened block, or `nil` for the
---     degenerate whole-file-delete case.
local function widen_for_editui(bufnr, block)
    local s, e = block.range.start_line, block.range.end_line
    local replace_lines = block.replace_lines

    local is_pure_insert = e < s -- zero-width position
    local is_pure_delete = #replace_lines == 0 and not is_pure_insert

    if not is_pure_insert and not is_pure_delete then
        return block -- nothing to widen
    end

    local total = vim.api.nvim_buf_line_count(bufnr)

    if is_pure_insert then
        -- Anchor `{N, N-1}` (insert before line N).
        local insert_at = s -- the line that would shift down
        if insert_at <= total then
            -- Borrow line N forward: range becomes {N, N}, replace becomes [...R, line_N].
            local borrowed = vim.api.nvim_buf_get_lines(bufnr, insert_at - 1, insert_at, false)[1]
            local new_replace = {}
            for _, l in ipairs(replace_lines) do
                new_replace[#new_replace + 1] = l
            end
            new_replace[#new_replace + 1] = borrowed
            return {
                block_id = block.block_id,
                op_index = block.op_index,
                kind = block.kind,
                range = { start_line = insert_at, end_line = insert_at },
                replace_lines = new_replace,
            }
        elseif total >= 1 then
            -- Insert-at-EOF: borrow line `total` backward.
            -- Range becomes {total, total}, replace becomes [line_total, ...R].
            local borrowed = vim.api.nvim_buf_get_lines(bufnr, total - 1, total, false)[1]
            local new_replace = { borrowed }
            for _, l in ipairs(replace_lines) do
                new_replace[#new_replace + 1] = l
            end
            return {
                block_id = block.block_id,
                op_index = block.op_index,
                kind = block.kind,
                range = { start_line = total, end_line = total },
                replace_lines = new_replace,
            }
        else
            -- Empty buffer; nothing to borrow. Fall through to nil-return.
            return nil
        end
    end

    -- is_pure_delete
    if e < total then
        -- Borrow line E+1 forward: range becomes {S, E+1}, replace becomes [line_{E+1}].
        local borrowed = vim.api.nvim_buf_get_lines(bufnr, e, e + 1, false)[1]
        return {
            block_id = block.block_id,
            op_index = block.op_index,
            kind = block.kind,
            range = { start_line = s, end_line = e + 1 },
            replace_lines = { borrowed },
        }
    elseif s > 1 then
        -- Delete-to-EOF: borrow line S-1 backward.
        -- Range becomes {S-1, E}, replace becomes [line_{S-1}].
        local borrowed = vim.api.nvim_buf_get_lines(bufnr, s - 2, s - 1, false)[1]
        return {
            block_id = block.block_id,
            op_index = block.op_index,
            kind = block.kind,
            range = { start_line = s - 1, end_line = e },
            replace_lines = { borrowed },
        }
    else
        -- Whole-file delete: S == 1, E == total, nothing to borrow.
        return nil
    end
end

--- Compute the line range a block will occupy in the buffer **after**
--- widening, without actually performing the widen. Used by
--- `detect_widen_collisions` to find inter-block conflicts the planner
--- could not have caught because they only exist post-widen.
---
--- Returns `nil` for blocks the helper would refuse outright (whole-file
--- delete with no neighbour to borrow). Callers should treat `nil` as a
--- collision-equivalent — the block cannot be expressed to EditUI.
---
--- @param bufnr integer
--- @param block mcphub.edit.applier.Block
--- @return { start_line: integer, end_line: integer }?  Inclusive 1-based.
local function effective_range_after_widen(bufnr, block)
    local s, e = block.range.start_line, block.range.end_line
    local replace_lines = block.replace_lines

    local is_pure_insert = e < s
    local is_pure_delete = #replace_lines == 0 and not is_pure_insert

    if not is_pure_insert and not is_pure_delete then
        -- No widening: range stays as-is.
        return { start_line = s, end_line = e }
    end

    local total = vim.api.nvim_buf_line_count(bufnr)

    if is_pure_insert then
        if s <= total then
            return { start_line = s, end_line = s } -- borrow line s forward
        elseif total >= 1 then
            return { start_line = total, end_line = total } -- borrow line total backward
        else
            return nil
        end
    end

    -- is_pure_delete
    if e < total then
        return { start_line = s, end_line = e + 1 } -- borrow line e+1 forward
    elseif s > 1 then
        return { start_line = s - 1, end_line = e } -- borrow line s-1 backward
    else
        return nil
    end
end

--- Detect inter-block range conflicts that the planner could not have
--- caught because they only exist after `widen_for_editui` has run.
---
--- ## The conflict shape
---
--- Two blocks' **post-widen** effective ranges overlap. The planner saw
--- the pre-widen ranges (which were non-overlapping by its own
--- conflict-detection guarantee), so it had no chance to refuse the
--- batch. EditUI's `_apply_all_changes` would then apply both blocks in
--- whatever order Lua's non-stable `table.sort` picks for ties, with
--- the later block clobbering the earlier one's changes. Result: silent
--- wrong output and a dishonest `applied` response — the very failure
--- mode the structured-anchor design exists to eliminate.
---
--- The refusal is at-file granularity, not at-batch: a batch with two
--- files where only one has a collision still gets the other file
--- processed. Each colliding op surfaces as `failed[]` with reason
--- `range_conflict` and the conflicting op's index in
--- `conflicting_op_indices` so the LLM can re-issue the batch in a way
--- the applier can handle (e.g. split into two batches).
---
--- ## What counts as a collision
---
---   * Two effective ranges overlap on any line.
---   * A block's effective range was `nil` (widening would have refused
---     it — whole-file delete with no neighbour). Reported as a self-
---     collision with `conflicting_op_indices = {}`.
---
--- @param bufnr  integer
--- @param blocks mcphub.edit.applier.Block[]
--- @return table[]  failures   One entry per affected op (each side of every
---                  detected conflict appears once). Empty list means no
---                  collisions.
local function detect_widen_collisions(bufnr, blocks)
    -- Compute every block's post-widen effective range.
    local ranges = {}
    for i, b in ipairs(blocks) do
        ranges[i] = effective_range_after_widen(bufnr, b)
    end

    -- For each block, find the set of other blocks whose effective range
    -- overlaps. We track conflicts by block index, then translate to
    -- op_index + block_id for the response.
    --
    -- Range A = [aS..aE], B = [bS..bE] overlap iff aS <= bE and bS <= aE.
    -- For "nil range" (widening would refuse), treat as self-conflict.
    local conflicts_by_block = {} -- block-index → list of other block indices
    for i = 1, #blocks do
        conflicts_by_block[i] = {}
    end

    -- Collect block indices whose effective range is `nil` (whole-file
    -- delete with no neighbour to borrow). We can't use `ipairs(ranges)`
    -- here: `ipairs` stops at the first `nil`, but we specifically want
    -- to find those nils. A numeric loop over `#blocks` is the correct
    -- traversal of this sparse-by-design array.
    local nil_blocks = {}
    for i = 1, #blocks do
        if ranges[i] == nil then
            nil_blocks[#nil_blocks + 1] = i
        end
    end

    for i = 1, #blocks do
        if ranges[i] then
            for j = i + 1, #blocks do
                if ranges[j] then
                    local ai, ae = ranges[i].start_line, ranges[i].end_line
                    local bj, be = ranges[j].start_line, ranges[j].end_line
                    if ai <= be and bj <= ae then
                        conflicts_by_block[i][#conflicts_by_block[i] + 1] = j
                        conflicts_by_block[j][#conflicts_by_block[j] + 1] = i
                    end
                end
            end
        end
    end

    -- Build failure entries. One per affected op, listing every other op
    -- it collides with. Stable order: by block list order.
    local failures = {}
    for i, b in ipairs(blocks) do
        local peers = conflicts_by_block[i]
        if #peers > 0 then
            local peer_op_indices = {}
            for _, j in ipairs(peers) do
                peer_op_indices[#peer_op_indices + 1] = blocks[j].op_index
            end
            failures[#failures + 1] = {
                op_index = b.op_index,
                reason = "range_conflict",
                message = string.format(
                    "op %d cannot be applied in this batch: its effective range after "
                        .. "EditUI widening overlaps with op(s) %s. Re-issue the ops in "
                        .. "separate batches, or change the anchor of one to a non-adjacent "
                        .. "location.",
                    b.op_index,
                    table.concat(peer_op_indices, ", ")
                ),
                range = { start_line = b.range.start_line, end_line = b.range.end_line },
                conflicting_op_indices = peer_op_indices,
            }
        end
    end

    -- Surface widening-refused blocks (nil range) as their own failures.
    -- These don't have peers — they fail in isolation.
    for _, i in ipairs(nil_blocks) do
        local b = blocks[i]
        local already_listed = false
        for _, f in ipairs(failures) do
            if f.op_index == b.op_index then
                already_listed = true
                break
            end
        end
        if not already_listed then
            failures[#failures + 1] = {
                op_index = b.op_index,
                reason = "range_conflict",
                message = string.format(
                    "op %d cannot be applied by the EditUI driver: %s",
                    b.op_index,
                    (b.kind == "delete_range") and "whole-file deletion has no neighbouring line to borrow"
                        or "insertion into an empty buffer has no neighbouring line to borrow"
                ),
                range = { start_line = b.range.start_line, end_line = b.range.end_line },
                conflicting_op_indices = {},
            }
        end
    end

    return failures
end

--- Build the `LocatedBlock`-shaped table `EditUI` expects, from one of the
--- applier's `Block`s. `EditUI` needs:
---
---   * `block_id`               — scopes the per-hunk IDs generated by
---                                `_generate_hunk_blocks`.
---   * `search_content` / lines — used by `_generate_block_summary` for the
---                                LLM-facing report. Not load-bearing for
---                                the apply path.
---   * `replace_content` / lines — what gets inserted by `_apply_all_changes`.
---   * `location_result`        — `{ found = true, start_line, end_line,
---                                found_lines, ... }`. `_apply_all_changes`
---                                reads `start_line` / `end_line`;
---                                `_generate_hunk_blocks` reads `found_lines`.
---
--- The other `BlockLocationResult` fields are informational (the SEARCH/
--- REPLACE locator emits them for fuzzy-match feedback). We provide
--- harmless defaults so any field reads don't crash on nil.
---
--- @param bufnr      integer
--- @param block      mcphub.edit.applier.Block
--- @return table     LocatedBlock-shaped table (mcphub's types.lua).
local function to_located_block(bufnr, block)
    local start_line, end_line = block.range.start_line, block.range.end_line

    -- `end_line < start_line` would be a zero-width insertion, but the
    -- caller (`drive_file`) has already widened pure inserts and pure
    -- deletes via `widen_for_editui` before calling us. We assert that
    -- the post-widen range is non-zero-width and has non-empty replace
    -- content — anything else would crash `EditUI` downstream.
    assert(end_line >= start_line, "to_located_block: zero-width range slipped past widen_for_editui")
    assert(#block.replace_lines > 0, "to_located_block: empty replace_lines slipped past widen_for_editui")

    local found_lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)

    local search_text = table.concat(found_lines, "\n")
    local replace_lines = block.replace_lines
    local replace_text = table.concat(replace_lines, "\n")

    return {
        block_id = block.block_id,
        search_content = search_text,
        search_lines = found_lines,
        replace_content = replace_text,
        replace_lines = replace_lines,
        location_result = {
            found = true,
            start_line = start_line,
            end_line = end_line,
            found_lines = found_lines,
            -- Informational defaults — EditUI's summary code reads these
            -- but treats them as additive; nil would be fine in practice
            -- but explicit defaults keep the contract obvious.
            overall_score = 1.0,
            overall_match_type = "exact",
            confidence = 100,
            found_content = search_text,
            line_details = {},
            search_metadata = {
                method = "exact_scan",
                iterations = 0,
                search_strategy = "auto",
                search_bounds = { start_line, end_line < start_line and start_line or end_line },
                early_termination = false,
            },
        },
    }
end

--- Default wait time (ms) for an LSP without a curated entry in
--- `M.LSP_WAIT_MS`. 1000ms matches mcphub's historical default and is on
--- the slow side of what most LSPs need — missing diagnostics is a
--- correctness gap, over-waiting is just latency, so we err high.
local DEFAULT_LSP_WAIT_MS = 1000

--- Per-LSP wait-time ceilings for post-write diagnostic publication, in
--- milliseconds. Each value is the **upper bound** on how long
--- `drive_file` blocks waiting for `textDocument/publishDiagnostics`
--- notifications to arrive after a `:write`. We pick the **max** over
--- all clients attached to the buffer, so a buffer with both `tsserver`
--- and `eslint` waits the longer of the two.
---
--- These are intentionally generous; ms-shaving belongs in a future
--- debounce-with-event-driven-early-exit layer that respects each entry
--- here as the ceiling. Until that layer lands, the value here *is* the
--- wall-clock cost on every apply against a buffer attached to the
--- named client.
---
--- ## How to override
---
--- Preferred: `builtin_tools.apply_edit.lsp_wait_ms` in mcphub's
--- `setup()`. Its entries are merged *over* this table, so overriding
--- one client keeps the curated ceilings for all the others:
---
---     require("mcphub").setup({
---         builtin_tools = { apply_edit = { lsp_wait_ms = { metals = 8000 } } },
---     })
---
--- Also supported: mutating this table after requiring the module. That
--- is the only route for a caller driving `drive_file` without a config
--- table (the specs, or any non-mcphub embedder):
---
---     local backend = require("mcphub.native.neovim.files.apply_edit.ui_backend")
---     backend.LSP_WAIT_MS.metals = 8000
---
--- Unknown clients fall back to `DEFAULT_LSP_WAIT_MS`, itself overridable
--- as `builtin_tools.apply_edit.default_lsp_wait_ms`.
---
--- @type table<string, integer>
M.LSP_WAIT_MS = {
    -- Fast — small ASTs or aggressive incremental analysis.
    lua_ls = 300,
    gopls = 500,
    pyright = 600,
    basedpyright = 600,
    pylance = 600,
    -- Medium.
    tsserver = 1000,
    ["typescript-tools"] = 1000,
    vtsls = 1000,
    eslint = 1000,
    clangd = 1000,
    -- Slow — heavy semantic passes, often multi-stage publication.
    rust_analyzer = 3000,
    metals = 5000,
}

--- Compute the wait-time ceiling for a buffer given its attached LSP
--- clients. Pure function: takes a client list rather than calling
--- `vim.lsp.get_clients` itself, so tests can drive it with synthetic
--- client tables.
---
--- ## Resolution rule
---
---   * Empty client list → 0 ms (no LSP, no diagnostics to wait for).
---   * Otherwise → the **maximum** of `wait_table[client.name]` (or
---     `default_ms` when unknown) across all clients. A buffer with
---     multiple LSPs waits long enough for every one of them.
---
--- @param clients    { name: string }[]   typically from `vim.lsp.get_clients`
--- @param wait_table table<string, integer>
--- @param default_ms integer
--- @return integer
local function resolve_lsp_wait_ms(clients, wait_table, default_ms)
    if #clients == 0 then
        return 0
    end
    local max_wait = 0
    for _, client in ipairs(clients) do
        local wait = wait_table[client.name] or default_ms
        if wait > max_wait then
            max_wait = wait
        end
    end
    return max_wait
end

--- Map a `vim.diagnostic.severity` integer enum to our stable
--- lowercase string convention.
---
--- The numeric enum (`ERROR=1, WARN=2, INFO=3, HINT=4`) is the canonical
--- form inside Neovim, but it's an awkward shape on the wire — LLMs read
--- "warn" more reliably than "2", and the integer mapping is a Neovim
--- implementation detail the response shouldn't leak.
local SEVERITY_NAME = {
    [vim.diagnostic.severity.ERROR] = "error",
    [vim.diagnostic.severity.WARN] = "warn",
    [vim.diagnostic.severity.INFO] = "info",
    [vim.diagnostic.severity.HINT] = "hint",
}

--- Default number of context lines to extend each edited range by when
--- deciding whether a diagnostic is "in range". A diagnostic counts as
--- in-range if it intersects any edited range grown by this many lines on
--- each side. 10 LOC is a pragmatic window: wide enough to catch a
--- diagnostic the edit *caused* a few lines away (e.g. an unbalanced brace
--- reported at the next statement), narrow enough to exclude the file's
--- pre-existing unrelated noise.
local DEFAULT_DIAGNOSTIC_CONTEXT_LINES = 10

--- Does diagnostic line-span [d_s, d_e] intersect any edited range grown by
--- `context` lines on each side? Inputs are 1-based inclusive.
---
--- @param d_s integer  diagnostic start line (1-based)
--- @param d_e integer  diagnostic end line (1-based)
--- @param edited_ranges { start_line: integer, end_line: integer }[]
--- @param context integer
--- @return boolean
local function intersects_edited(d_s, d_e, edited_ranges, context)
    for _, r in ipairs(edited_ranges) do
        local lo = r.start_line - context
        local hi = r.end_line + context
        -- Overlap test: [d_s, d_e] vs [lo, hi].
        if d_s <= hi and lo <= d_e then
            return true
        end
    end
    return false
end

--- Collect diagnostics for the response: detailed entries for diagnostics
--- *near the edit*, plus whole-file counts.
---
--- ## When to call this
---
--- Call after the LSP server(s) have had time to publish post-`:write`
--- diagnostics. We previously relied on mcphub's `get_summary` to honour
--- that wait (via `send_diagnostics = true` + `wait_for_diagnostics`), but
--- we now suppress mcphub's prose diagnostic block (`send_diagnostics =
--- false`) and own the settle wait ourselves — see `finalise`. So the
--- caller must `vim.defer_fn` this by the per-LSP wait before invoking.
---
--- ## Two views, by design
---
---   * `detail` — full `mcphub.edit.Diagnostic[]`, **all severities**, but only
---     for diagnostics intersecting an edited range ±`context_lines`. This
---     is the actionable set: "did my edit break (or fix) anything right
---     here?" Bounded by the edit footprint, not the file size, so it can't
---     explode on a file that's already full of unrelated errors.
---   * `counts` — whole-file tally of **errors and warnings only**
---     (`{ errors = N, warnings = M }`). Info/hint are deliberately excluded:
---     they're typically too chatty to be worth a number. This is the
---     orientation signal: "the file as a whole has N errors" without
---     serialising all N.
---
--- ## Position conventions
---
--- `vim.diagnostic.Diagnostic` uses 0-based positions exclusively. We
--- translate every field to 1-based to match the rest of the response
--- shape (line ranges in `applied[]` / `rejected[]` are 1-based inclusive
--- everywhere).
---
--- @param bufnr         integer
--- @param edited_ranges  { start_line: integer, end_line: integer }[]  1-based inclusive
--- @param context_lines integer?  defaults to DEFAULT_DIAGNOSTIC_CONTEXT_LINES
--- @return mcphub.edit.Diagnostic[]                detail  (in-range, all severities)
--- @return { errors: integer, warnings: integer } counts  (whole-file, error+warn only)
local function collect_diagnostics(bufnr, edited_ranges, context_lines)
    local counts = { errors = 0, warnings = 0 }
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return {}, counts
    end
    context_lines = context_lines or DEFAULT_DIAGNOSTIC_CONTEXT_LINES
    edited_ranges = edited_ranges or {}

    local all = vim.diagnostic.get(bufnr)
    local detail = {}
    for _, d in ipairs(all) do
        -- Whole-file counts: errors and warnings only.
        if d.severity == vim.diagnostic.severity.ERROR then
            counts.errors = counts.errors + 1
        elseif d.severity == vim.diagnostic.severity.WARN then
            counts.warnings = counts.warnings + 1
        end

        -- In-range detail: all severities, but only near an edited range.
        local d_s = (d.lnum or 0) + 1
        local d_e = (d.end_lnum or d.lnum or 0) + 1
        if intersects_edited(d_s, d_e, edited_ranges, context_lines) then
            detail[#detail + 1] = {
                severity = SEVERITY_NAME[d.severity] or "error",
                line = d_s,
                end_line = d_e,
                col = (d.col or 0) + 1,
                end_col = (d.end_col or d.col or 0) + 1,
                message = d.message or "",
                source = d.source,
                code = d.code,
            }
        end
    end
    return detail, counts
end

--- Walk `EditUI.state.completed_hunks` and aggregate hunk-level statuses up
--- to the block level (`per_block[block_id]`). `EditUI` generates hunk IDs
--- of the form `<block_id>_hunk_<N>`, so we scan by prefix.
---
--- Aggregation rule:
---   * any hunk rejected and any hunk accepted → 'partial'
---   * any hunk rejected, none accepted        → 'rejected'
---   * no hunks (block produced no diff)       → absent (treated as accepted by classify_outcome)
---   * all hunks accepted/skipped              → 'accepted'
---
--- `EditUI` uses status `'skipped'` for hunks that couldn't be navigated
--- (e.g. content already matched). For our purposes that's a successful
--- no-op — group it with `'accepted'`.
---
--- @param completed_hunks table<string, string>
--- @param block_ids       string[]
--- @return table<string, string>
local function aggregate_per_block(completed_hunks, block_ids)
    local per_block = {}
    for _, block_id in ipairs(block_ids) do
        local prefix = block_id .. "_"
        local any_rejected, any_accepted = false, false
        local n = 0
        for hunk_id, status in pairs(completed_hunks) do
            if hunk_id:sub(1, #prefix) == prefix then
                n = n + 1
                if status == "rejected" then
                    any_rejected = true
                elseif status == "accepted" or status == "skipped" then
                    any_accepted = true
                end
            end
        end
        if n == 0 then
            -- absent: classify_outcome treats this as accepted on a completed
            -- file and as cancelled on a cancelled file. Don't set anything.
        elseif any_rejected and any_accepted then
            per_block[block_id] = "partial"
        elseif any_rejected then
            per_block[block_id] = "rejected"
        else
            per_block[block_id] = "accepted"
        end
    end
    return per_block
end

--- User-facing configuration for `apply_edit`, declared in `mcphub/config.lua`
--- under `builtin_tools.apply_edit` and handed to `drive_file` by the tool.
---
--- It arrives through the *driver* rather than through `engine.apply`, which is
--- deliberately opts-free — see the "LLM-facing seal" note in `engine.lua`.
--- Every field is optional, and every absent field falls back to this module's
--- own default, which is what keeps the two-argument
--- `drive_file(request, file_cb)` form working for the specs and for any
--- non-mcphub embedder.
---
--- @class MCPHub.ApplyEditConfig
--- @field ui table?                            Passed to `EditUI.new`. `EditUI` reads only `keybindings`, `auto_navigate` and `go_to_origin_on_complete`; its other defaults are inert here because this driver owns diagnostics reporting.
--- @field lsp_wait_ms table<string, integer>?  Per-client ceilings, merged *over* `M.LSP_WAIT_MS`.
--- @field default_lsp_wait_ms integer?         Ceiling for clients with no curated entry.
--- @field diagnostic_context_lines integer?    Context window around an edited range for in-range diagnostic detail.

--- Normalise a possibly-nil, possibly-partial config into the concrete values
--- `drive_file` needs.
---
--- `lsp_wait_ms` is *merged over* the curated table rather than replacing it: a
--- user overriding one client should not silently lose the ceilings for every
--- other client. `M.LSP_WAIT_MS` is read here, at call time, so the documented
--- post-require mutation recipe keeps working alongside the config table.
---
--- @param config MCPHub.ApplyEditConfig?
--- @return { ui: table, lsp_wait_ms: table<string, integer>, default_lsp_wait_ms: integer, diagnostic_context_lines: integer }
local function resolve_config(config)
    config = config or {}
    return {
        ui = config.ui or {},
        lsp_wait_ms = vim.tbl_extend("force", M.LSP_WAIT_MS, config.lsp_wait_ms or {}),
        default_lsp_wait_ms = config.default_lsp_wait_ms or DEFAULT_LSP_WAIT_MS,
        diagnostic_context_lines = config.diagnostic_context_lines or DEFAULT_DIAGNOSTIC_CONTEXT_LINES,
    }
end

--- Drive one file's edits through `EditUI`. Implements the `drive_file`
--- contract from `mcphub.native.neovim.files.apply_edit.applier.apply_plan`.
---
--- @param request  mcphub.edit.applier.FileRequest
--- @param file_cb  fun(outcome: mcphub.edit.applier.FileOutcome)
--- @param config   MCPHub.ApplyEditConfig?  Optional. Absent fields fall back to this module's defaults.
function M.drive_file(request, file_cb, config)
    local cfg = resolve_config(config)

    -- Note: `EditUI` is required lazily below (just before instantiation),
    -- not at function entry, so collision-detection and no-changes paths
    -- can complete without mcphub's full plugin tree on `runtimepath`.
    -- Useful for tests that exercise refusal semantics under `-u NONE`.

    -- Refuse the batch up-front if any post-widen ranges would overlap.
    -- Widening adapts our zero-width / empty-replace blocks to EditUI's
    -- input shape by borrowing one neighbouring buffer line — that
    -- borrowing can introduce conflicts the planner could not have seen
    -- in the original (unwidened) ranges. Applying anyway would let
    -- EditUI's `_apply_all_changes` sort the colliding blocks by
    -- `start_line` (with ties resolved by Lua's non-stable sort), so
    -- one block would clobber the other silently. We surface this as
    -- a per-file `precondition_failed` outcome carrying one
    -- `range_conflict` failure per affected op; the applier turns
    -- those into `failed[]` response entries. The batch continues
    -- with subsequent files.
    do
        local failures = detect_widen_collisions(request.bufnr, request.blocks)
        if #failures > 0 then
            return file_cb({
                status = "precondition_failed",
                failures = failures,
                per_block = {},
                ui_summary = string.format(
                    "refused %d block(s) in `%s` due to post-widen range conflicts",
                    #failures,
                    request.file_path
                ),
            })
        end
    end

    -- Collisions have been ruled out; widening is now safe per-block.
    -- The previous nil-return guard for whole-file delete is no longer
    -- reachable here (collision detection catches it upstream), but we
    -- keep the assertion to lock in that invariant.
    local located_blocks, block_ids = {}, {}
    for _, b in ipairs(request.blocks) do
        local widened = widen_for_editui(request.bufnr, b)
        assert(
            widened ~= nil,
            "drive_file: widen_for_editui returned nil for block "
                .. b.block_id
                .. " after collision detection accepted the batch — invariant violated"
        )
        located_blocks[#located_blocks + 1] = to_located_block(request.bufnr, widened)
        block_ids[#block_ids + 1] = b.block_id
    end

    -- Guard against the degenerate "no blocks" case. The applier shouldn't
    -- send us this (planner emits at least one located op per included
    -- file), but a defensive return keeps the contract well-defined.
    if #located_blocks == 0 then
        return file_cb({ status = "no_changes", per_block = {} })
    end

    -- Origin window for "return-to-origin on complete". The current window
    -- is fine: `EditUI.open_file_in_editor` filters by `buftype == ""` when
    -- picking a target split, so the CodeCompanion chat (buftype = "acwrite")
    -- is structurally excluded — see spelunking notes.
    local origin_winnr = vim.api.nvim_get_current_win()

    -- Lazy require: we only need EditUI now that we're about to instantiate
    -- one. The collision-detection and no-changes early-returns above
    -- complete without touching mcphub's plugin tree.
    local EditUI = require("mcphub.native.neovim.files.edit_file.edit_ui")

    -- `EditUI.new` deep-merges its argument over its own DEFAULT_CONFIG, so a
    -- partial table (or an empty one) is the correct way to say "defaults for
    -- everything I did not mention". mcphub's UIConfig annotation marks every
    -- field as required, which is wrong for this entry point — silence the
    -- diagnostic.
    ---@diagnostic disable-next-line: missing-fields
    local ui = EditUI.new(cfg.ui)

    -- Both completion paths share the same epilogue: snapshot state, fetch
    -- summary (async), cleanup, hand outcome to file_cb. We must read
    -- everything from `ui.state` BEFORE `ui:cleanup()` because cleanup nils
    -- the state table. The diagnostic snapshot is keyed off `request.bufnr`
    -- (== `ui.state.bufnr`) for the same reason — accessing it later via
    -- `ui.state` would crash.
    local bufnr_for_diagnostics = request.bufnr

    local function finalise(status, cancel_reason)
        local completed_hunks = vim.deepcopy(ui.state and ui.state.completed_hunks or {})
        local per_block = aggregate_per_block(completed_hunks, block_ids)

        -- ## Diagnostics: own the settle wait, suppress mcphub's prose block
        --
        -- We pass `send_diagnostics = false` to `get_summary`. That does two
        -- things in mcphub's `EditUI:_add_diagnostic_feedback`:
        --   1. It suppresses the `## CURRENT DIAGNOSTICS FOR ...` prose block
        --      that mcphub would otherwise append to the summary string. That
        --      block is whole-file, unbounded, and (for us) redundant with the
        --      structured `diagnostics`/`diagnostic_counts` we emit ourselves.
        --      On a file already full of unrelated errors it dominated the
        --      response payload.
        --   2. As a side effect, it also disables mcphub's internal
        --      `vim.defer_fn(..., wait_for_diagnostics)` settle wait — that
        --      wait lives *inside* the same `send_diagnostics`-gated branch.
        --
        -- Because (2) means mcphub no longer waits for the LSP to publish, we
        -- own the settle wait here: `get_summary`'s callback fires promptly,
        -- and we `vim.defer_fn` our own `collect_diagnostics` by the per-LSP
        -- ceiling so we still read a fresh diagnostic set.
        --
        -- The wait time is selected per-LSP via `cfg.lsp_wait_ms` (this
        -- module's curated table plus any user overrides). When the
        -- buffer has no LSP attached the resolver returns 0 — no publisher
        -- exists, so the wait is dead time (felt as latency in headless tests
        -- and on untyped-file edits). With multiple LSPs attached the
        -- resolver picks the max so we hear from all of them.
        local lsp_wait_ms = resolve_lsp_wait_ms(
            vim.lsp.get_clients({ bufnr = bufnr_for_diagnostics }),
            cfg.lsp_wait_ms,
            cfg.default_lsp_wait_ms
        )
        local summary_config = {
            include_session_summary = true,
            include_final_diff = false,
            send_diagnostics = false,
        }

        -- Edited ranges (pre-edit / planner line numbers) used to scope the
        -- in-range diagnostic detail. NOTE: these are the ranges as the
        -- planner saw them, not the post-edit positions — a multi-block edit
        -- earlier in the file can shift later blocks by the net line delta.
        -- The ±context window in `collect_diagnostics` absorbs small shifts;
        -- computing true post-edit ranges is a tracked follow-up.
        local edited_ranges = {}
        for _, b in ipairs(request.blocks) do
            edited_ranges[#edited_ranges + 1] = {
                start_line = b.range.start_line,
                end_line = b.range.end_line,
            }
        end

        ui:get_summary(summary_config, function(summary_text)
            -- mcphub no longer waits for diagnostics (send_diagnostics =
            -- false), so we own the LSP settle wait here before collecting.
            -- A 0ms wait still schedules onto the next tick, which is fine.
            vim.defer_fn(function()
                -- Snapshot diagnostics BEFORE cleanup. `cleanup()` may detach
                -- the buffer from view; `vim.diagnostic.get` still works on
                -- the bufnr, but reading before cleanup keeps the temporal
                -- order obvious and avoids surprises if mcphub ever clears
                -- diagnostic state in `cleanup`.
                local diagnostics, diagnostic_counts =
                    collect_diagnostics(bufnr_for_diagnostics, edited_ranges, cfg.diagnostic_context_lines)

                ui:cleanup()
                file_cb({
                    status = status,
                    cancel_reason = cancel_reason,
                    per_block = per_block,
                    ui_summary = summary_text ~= "" and summary_text or nil,
                    diagnostics = diagnostics,
                    diagnostic_counts = diagnostic_counts,
                })
            end, lsp_wait_ms)
        end)
    end
    ui:start_interactive_editing({
        interactive = request.interactive ~= false,
        is_replacing_entire_file = false,
        origin_winnr = origin_winnr,
        file_path = request.file_path,
        located_blocks = located_blocks,
        original_content = request.original_content,
        on_complete = function()
            finalise("completed", nil)
        end,
        on_cancel = function(reason)
            finalise("cancelled", reason)
        end,
    })
end

--- Test-only surface. Exposes file-local helpers so specs can exercise the
--- borrowing edge cases (mid-buffer / EOF / whole-file) without needing to
--- stand up `EditUI` itself. Not part of the module's public contract — any
--- caller outside `tests/` reaching into this table is on their own.
M._test = {
    widen_for_editui = widen_for_editui,
    effective_range_after_widen = effective_range_after_widen,
    detect_widen_collisions = detect_widen_collisions,
    collect_diagnostics = collect_diagnostics,
    intersects_edited = intersects_edited,
    DEFAULT_DIAGNOSTIC_CONTEXT_LINES = DEFAULT_DIAGNOSTIC_CONTEXT_LINES,
    resolve_lsp_wait_ms = resolve_lsp_wait_ms,
    DEFAULT_LSP_WAIT_MS = DEFAULT_LSP_WAIT_MS,
    resolve_config = resolve_config,
}

return M
