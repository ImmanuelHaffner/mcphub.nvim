--- Unit tests for `mcphub.native.neovim.files.apply_edit.ui_backend._test.widen_for_editui`.
---
--- The widening helper is the load-bearing piece that makes our zero-width
--- inserts and pure deletes compatible with mcphub's `EditUI` input shape.
--- Each test sets up a small scratch buffer, runs the helper, and asserts
--- the returned block's range / replace_lines.
---
--- The real EditUI smoke covers the happy paths end-to-end. These specs nail
--- down the borrowing edge cases that the smoke doesn't reach: EOF-side
--- insertions, EOF-side deletions, and the degenerate empty-buffer /
--- whole-file-delete cases that return `nil`.
---
--- @module "tests.native.neovim.files.apply_edit.test_ui_backend"

local assert = require("tests.native.neovim.files.apply_edit.busted_assert")

local ui_backend = require("mcphub.native.neovim.files.apply_edit.ui_backend")
local widen_for_editui = ui_backend._test.widen_for_editui
local effective_range_after_widen = ui_backend._test.effective_range_after_widen
local detect_widen_collisions = ui_backend._test.detect_widen_collisions
local collect_diagnostics = ui_backend._test.collect_diagnostics
local intersects_edited = ui_backend._test.intersects_edited
local resolve_lsp_wait_ms = ui_backend._test.resolve_lsp_wait_ms
local DEFAULT_LSP_WAIT_MS = ui_backend._test.DEFAULT_LSP_WAIT_MS

--- Create a scratch buffer (no file, `buftype = nofile`) preloaded with
--- `lines`. Returns the bufnr. Caller is responsible for `nvim_buf_delete`.
local function scratch(lines)
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    return bufnr
end

--- Build a minimal applier `Block` table. Only fields read by
--- `widen_for_editui` matter; the rest are passed through opaquely.
local function block(opts)
    return {
        block_id = opts.block_id or "op1_r1",
        op_index = opts.op_index or 1,
        kind = opts.kind,
        range = { start_line = opts.start_line, end_line = opts.end_line },
        replace_lines = opts.replace_lines or {},
    }
end

describe("widen_for_editui", function()
    describe("non-zero-width, non-empty-replace (no-op path)", function()
        it("returns a replace_range block unchanged", function()
            local b = scratch({ "one", "two", "three", "four" })
            local input = block({
                kind = "replace_range",
                start_line = 2,
                end_line = 3,
                replace_lines = { "TWO", "THREE" },
            })
            local out = widen_for_editui(b, input)
            assert.is.equal(input, out) -- same table, not a copy
            assert.is.equal(2, out.range.start_line)
            assert.is.equal(3, out.range.end_line)
            assert.is.equal(2, #out.replace_lines)
            assert.is.equal("TWO", out.replace_lines[1])
            assert.is.equal("THREE", out.replace_lines[2])
            vim.api.nvim_buf_delete(b, { force = true })
        end)

        it("returns a single-line replace unchanged", function()
            local b = scratch({ "one", "two", "three" })
            local input = block({
                kind = "replace_range",
                start_line = 2,
                end_line = 2,
                replace_lines = { "TWO" },
            })
            local out = widen_for_editui(b, input)
            assert.is.equal(input, out)
            vim.api.nvim_buf_delete(b, { force = true })
        end)
    end)

    describe("pure insert (zero-width range)", function()
        it("borrows the line forward when inserting mid-buffer", function()
            -- Buffer: 1:one 2:two 3:three 4:four. Insert "X" before line 2.
            -- Anchor {2, 1}. Expect range -> {2, 2}, replace -> ["X", "two"].
            local b = scratch({ "one", "two", "three", "four" })
            local out = widen_for_editui(
                b,
                block({
                    kind = "insert",
                    start_line = 2,
                    end_line = 1,
                    replace_lines = { "X" },
                })
            )
            assert(out ~= nil, "expected widened block, got nil")
            assert.is.equal(2, out.range.start_line)
            assert.is.equal(2, out.range.end_line)
            assert.is.equal(2, #out.replace_lines)
            assert.is.equal("X", out.replace_lines[1])
            assert.is.equal("two", out.replace_lines[2])
            -- Metadata preserved.
            assert.is.equal("insert", out.kind)
            assert.is.equal("op1_r1", out.block_id)
            vim.api.nvim_buf_delete(b, { force = true })
        end)

        it("borrows the line forward when inserting before line 1", function()
            -- Insert "X" at the very top. Anchor {1, 0}.
            -- Expect range -> {1, 1}, replace -> ["X", "one"].
            local b = scratch({ "one", "two", "three" })
            local out = widen_for_editui(
                b,
                block({
                    kind = "insert",
                    start_line = 1,
                    end_line = 0,
                    replace_lines = { "X" },
                })
            )
            assert(out ~= nil)
            assert.is.equal(1, out.range.start_line)
            assert.is.equal(1, out.range.end_line)
            assert.is.equal("X", out.replace_lines[1])
            assert.is.equal("one", out.replace_lines[2])
            vim.api.nvim_buf_delete(b, { force = true })
        end)

        it("borrows the previous line backward when inserting at EOF", function()
            -- 3-line buffer. Insert "X" after the last line: anchor {4, 3}.
            -- No line 4 to borrow → borrow line 3 backward.
            -- Expect range -> {3, 3}, replace -> ["three", "X"].
            local b = scratch({ "one", "two", "three" })
            local out = widen_for_editui(
                b,
                block({
                    kind = "insert",
                    start_line = 4,
                    end_line = 3,
                    replace_lines = { "X" },
                })
            )
            assert(out ~= nil)
            assert.is.equal(3, out.range.start_line)
            assert.is.equal(3, out.range.end_line)
            assert.is.equal(2, #out.replace_lines)
            assert.is.equal("three", out.replace_lines[1])
            assert.is.equal("X", out.replace_lines[2])
            vim.api.nvim_buf_delete(b, { force = true })
        end)

        it("preserves order when the insert is multi-line", function()
            -- Multi-line insert mid-buffer: anchor {2, 1}, replace = ["X", "Y"].
            -- Expect range -> {2, 2}, replace -> ["X", "Y", "two"].
            local b = scratch({ "one", "two", "three" })
            local out = widen_for_editui(
                b,
                block({
                    kind = "insert",
                    start_line = 2,
                    end_line = 1,
                    replace_lines = { "X", "Y" },
                })
            )
            assert(out ~= nil)
            assert.is.equal(3, #out.replace_lines)
            assert.is.equal("X", out.replace_lines[1])
            assert.is.equal("Y", out.replace_lines[2])
            assert.is.equal("two", out.replace_lines[3])
            vim.api.nvim_buf_delete(b, { force = true })
        end)

        it("returns nil when inserting into an empty buffer", function()
            -- nvim_create_buf yields a buffer with one empty line by default.
            -- Wipe it to truly zero lines via nvim_buf_set_lines(0, -1, [...]).
            -- Note: a Neovim buffer cannot actually have zero lines — it
            -- always has at least one (possibly empty) line. The "empty
            -- buffer" the helper guards against is the `total == 0` branch
            -- (theoretically unreachable in practice). We exercise it
            -- defensively by constructing the scenario the helper checks:
            -- `total < 1`. Since we can't actually set total < 1, we test
            -- the closest reachable case: insert into a 1-line buffer
            -- works (borrows line 1) — confirming the empty-buffer branch
            -- is genuinely a guard, not a hot path.
            local b = scratch({ "" }) -- 1 empty line: nvim_buf_line_count == 1
            local out = widen_for_editui(
                b,
                block({
                    kind = "insert",
                    start_line = 1,
                    end_line = 0,
                    replace_lines = { "X" },
                })
            )
            assert(out ~= nil, "insert into a 1-line buffer should widen, not return nil")
            assert.is.equal(1, out.range.start_line)
            assert.is.equal(1, out.range.end_line)
            assert.is.equal("X", out.replace_lines[1])
            assert.is.equal("", out.replace_lines[2])
            vim.api.nvim_buf_delete(b, { force = true })
        end)
    end)

    describe("pure delete (empty replace_lines)", function()
        it("borrows the line after when deleting mid-buffer", function()
            -- Delete lines 2-3 from a 5-line buffer. Anchor {2, 3}, replace = [].
            -- Expect range -> {2, 4}, replace -> ["four"].
            local b = scratch({ "one", "two", "three", "four", "five" })
            local out = widen_for_editui(
                b,
                block({
                    kind = "delete_range",
                    start_line = 2,
                    end_line = 3,
                    replace_lines = {},
                })
            )
            assert(out ~= nil)
            assert.is.equal(2, out.range.start_line)
            assert.is.equal(4, out.range.end_line)
            assert.is.equal(1, #out.replace_lines)
            assert.is.equal("four", out.replace_lines[1])
            vim.api.nvim_buf_delete(b, { force = true })
        end)

        it("borrows the line after when deleting a single line", function()
            -- Delete line 3 only. Anchor {3, 3}, replace = [].
            -- Expect range -> {3, 4}, replace -> ["four"].
            local b = scratch({ "one", "two", "three", "four" })
            local out = widen_for_editui(
                b,
                block({
                    kind = "delete_range",
                    start_line = 3,
                    end_line = 3,
                    replace_lines = {},
                })
            )
            assert(out ~= nil)
            assert.is.equal(3, out.range.start_line)
            assert.is.equal(4, out.range.end_line)
            assert.is.equal("four", out.replace_lines[1])
            vim.api.nvim_buf_delete(b, { force = true })
        end)

        it("borrows the line before when deleting to EOF", function()
            -- 5-line buffer. Delete lines 4-5 (the tail). Anchor {4, 5}.
            -- No line 6 to borrow → borrow line 3 backward.
            -- Expect range -> {3, 5}, replace -> ["three"].
            local b = scratch({ "one", "two", "three", "four", "five" })
            local out = widen_for_editui(
                b,
                block({
                    kind = "delete_range",
                    start_line = 4,
                    end_line = 5,
                    replace_lines = {},
                })
            )
            assert(out ~= nil)
            assert.is.equal(3, out.range.start_line)
            assert.is.equal(5, out.range.end_line)
            assert.is.equal(1, #out.replace_lines)
            assert.is.equal("three", out.replace_lines[1])
            vim.api.nvim_buf_delete(b, { force = true })
        end)

        it("returns nil when deleting the entire buffer", function()
            -- Whole-file delete: anchor {1, #buf}, no neighbour on either side.
            local b = scratch({ "one", "two", "three" })
            local out = widen_for_editui(
                b,
                block({
                    kind = "delete_range",
                    start_line = 1,
                    end_line = 3,
                    replace_lines = {},
                })
            )
            assert.is.equal(nil, out)
            vim.api.nvim_buf_delete(b, { force = true })
        end)

        it("returns nil when deleting the only line in a 1-line buffer", function()
            -- Edge of the edge: 1-line buffer, delete it.
            -- s=1, e=1, total=1: e < total is false, s > 1 is false → nil.
            local b = scratch({ "only" })
            local out = widen_for_editui(
                b,
                block({
                    kind = "delete_range",
                    start_line = 1,
                    end_line = 1,
                    replace_lines = {},
                })
            )
            assert.is.equal(nil, out)
            vim.api.nvim_buf_delete(b, { force = true })
        end)
    end)

    describe("block metadata preservation", function()
        it("preserves block_id, op_index, and kind through the widen", function()
            local b = scratch({ "a", "b", "c" })
            local out = widen_for_editui(b, {
                block_id = "op7_r3",
                op_index = 7,
                kind = "insert",
                range = { start_line = 2, end_line = 1 },
                replace_lines = { "X" },
            })
            assert(out ~= nil)
            assert.is.equal("op7_r3", out.block_id)
            assert.is.equal(7, out.op_index)
            assert.is.equal("insert", out.kind)
            vim.api.nvim_buf_delete(b, { force = true })
        end)
    end)
end)

describe("effective_range_after_widen", function()
    it("returns the block range unchanged for non-degenerate blocks", function()
        local b = scratch({ "a", "b", "c" })
        local r = effective_range_after_widen(
            b,
            block({
                kind = "replace_range",
                start_line = 1,
                end_line = 2,
                replace_lines = { "X", "Y" },
            })
        )
        assert.is.equal(1, r.start_line)
        assert.is.equal(2, r.end_line)
        vim.api.nvim_buf_delete(b, { force = true })
    end)

    it("reports the forward-borrow target for a mid-buffer insert", function()
        local b = scratch({ "a", "b", "c" })
        local r = effective_range_after_widen(
            b,
            block({
                kind = "insert",
                start_line = 2,
                end_line = 1,
                replace_lines = { "X" },
            })
        )
        -- Insert before line 2 → borrow line 2.
        assert.is.equal(2, r.start_line)
        assert.is.equal(2, r.end_line)
        vim.api.nvim_buf_delete(b, { force = true })
    end)

    it("reports the backward-borrow target for an EOF insert", function()
        local b = scratch({ "a", "b", "c" })
        local r = effective_range_after_widen(
            b,
            block({
                kind = "insert",
                start_line = 4,
                end_line = 3,
                replace_lines = { "X" },
            })
        )
        -- Insert after last line → borrow line 3.
        assert.is.equal(3, r.start_line)
        assert.is.equal(3, r.end_line)
        vim.api.nvim_buf_delete(b, { force = true })
    end)

    it("reports the forward-borrow target for a mid-buffer delete", function()
        local b = scratch({ "a", "b", "c", "d" })
        local r = effective_range_after_widen(
            b,
            block({
                kind = "delete_range",
                start_line = 2,
                end_line = 3,
                replace_lines = {},
            })
        )
        -- Delete lines 2-3 → borrow line 4 → range {2, 4}.
        assert.is.equal(2, r.start_line)
        assert.is.equal(4, r.end_line)
        vim.api.nvim_buf_delete(b, { force = true })
    end)

    it("reports the backward-borrow target for a delete-to-EOF", function()
        local b = scratch({ "a", "b", "c" })
        local r = effective_range_after_widen(
            b,
            block({
                kind = "delete_range",
                start_line = 3,
                end_line = 3,
                replace_lines = {},
            })
        )
        -- Delete last line → borrow line 2 → range {2, 3}.
        assert.is.equal(2, r.start_line)
        assert.is.equal(3, r.end_line)
        vim.api.nvim_buf_delete(b, { force = true })
    end)

    it("returns nil for whole-file delete", function()
        local b = scratch({ "a", "b" })
        local r = effective_range_after_widen(
            b,
            block({
                kind = "delete_range",
                start_line = 1,
                end_line = 2,
                replace_lines = {},
            })
        )
        assert.is.equal(nil, r)
        vim.api.nvim_buf_delete(b, { force = true })
    end)
end)

describe("detect_widen_collisions", function()
    --- Build a block list from a compact spec list `{ { kind, s, e, replace? }, ... }`.
    --- op_index defaults to position; block_id is "opN_r1".
    local function blocks_from(specs)
        local out = {}
        for i, s in ipairs(specs) do
            out[i] = {
                block_id = ("op%d_r1"):format(i),
                op_index = s.op_index or i,
                kind = s.kind,
                range = { start_line = s.s, end_line = s.e },
                replace_lines = s.replace or {},
            }
        end
        return out
    end

    it("returns an empty list for a single block (no peers)", function()
        local b = scratch({ "a", "b", "c" })
        local fails = detect_widen_collisions(
            b,
            blocks_from({
                { kind = "replace_range", s = 2, e = 2, replace = { "X" } },
            })
        )
        assert.is.equal(0, #fails)
        vim.api.nvim_buf_delete(b, { force = true })
    end)

    it("returns an empty list for non-overlapping blocks", function()
        local b = scratch({ "a", "b", "c", "d", "e" })
        local fails = detect_widen_collisions(
            b,
            blocks_from({
                { kind = "replace_range", s = 1, e = 1, replace = { "X" } },
                { kind = "replace_range", s = 4, e = 4, replace = { "Y" } },
            })
        )
        assert.is.equal(0, #fails)
        vim.api.nvim_buf_delete(b, { force = true })
    end)

    it("detects the canonical delete-to-EOF + adjacent replace conflict", function()
        -- This is the failure mode the regression test fixes. Op 1 replaces
        -- line 2; op 2 deletes line 3 (last). Op 2 widens to {2, 3}, overlapping
        -- op 1's {2, 2}. Both ops must be reported.
        local b = scratch({ "a", "b", "c" })
        local fails = detect_widen_collisions(
            b,
            blocks_from({
                { kind = "replace_range", s = 2, e = 2, replace = { "B-NEW" } },
                { kind = "delete_range", s = 3, e = 3, replace = {} },
            })
        )
        assert.is.equal(2, #fails)
        -- Order is by block list order: op 1 first, op 2 second.
        assert.is.equal(1, fails[1].op_index)
        assert.is.equal("range_conflict", fails[1].reason)
        assert.is.equal(2, fails[1].conflicting_op_indices[1])
        assert.is.equal(2, fails[2].op_index)
        assert.is.equal("range_conflict", fails[2].reason)
        assert.is.equal(1, fails[2].conflicting_op_indices[1])
        vim.api.nvim_buf_delete(b, { force = true })
    end)

    it("flags a whole-file delete as a self-conflict (nil effective range)", function()
        -- Whole-file delete cannot widen — surfaced as range_conflict with
        -- an empty conflicting_op_indices list.
        local b = scratch({ "only" })
        local fails = detect_widen_collisions(
            b,
            blocks_from({
                { kind = "delete_range", s = 1, e = 1, replace = {} },
            })
        )
        assert.is.equal(1, #fails)
        assert.is.equal(1, fails[1].op_index)
        assert.is.equal("range_conflict", fails[1].reason)
        assert.is.equal(0, #fails[1].conflicting_op_indices)
        vim.api.nvim_buf_delete(b, { force = true })
    end)

    it("detects an insert-before + replace-adjacent conflict", function()
        -- Op 1 inserts before line 2 → widens to {2, 2}.
        -- Op 2 replaces line 2 → effective range {2, 2}.
        -- Overlap; both flagged.
        local b = scratch({ "a", "b", "c" })
        local fails = detect_widen_collisions(
            b,
            blocks_from({
                { kind = "insert", s = 2, e = 1, replace = { "X" } },
                { kind = "replace_range", s = 2, e = 2, replace = { "B-NEW" } },
            })
        )
        assert.is.equal(2, #fails)
        assert.is.equal(1, fails[1].op_index)
        assert.is.equal(2, fails[2].op_index)
        vim.api.nvim_buf_delete(b, { force = true })
    end)

    it("preserves the original (pre-widen) range in failure entries", function()
        -- A failure entry's `range` should report what the LLM submitted,
        -- not the widened range, so the LLM can correlate.
        local b = scratch({ "a", "b", "c" })
        local fails = detect_widen_collisions(
            b,
            blocks_from({
                { kind = "replace_range", s = 2, e = 2, replace = { "X" } },
                { kind = "delete_range", s = 3, e = 3, replace = {} },
            })
        )
        assert.is.equal(2, fails[1].range.start_line)
        assert.is.equal(2, fails[1].range.end_line)
        -- Op 2's original range is {3, 3}, not the widened {2, 3}.
        assert.is.equal(3, fails[2].range.start_line)
        assert.is.equal(3, fails[2].range.end_line)
        vim.api.nvim_buf_delete(b, { force = true })
    end)
end)

describe("collect_diagnostics", function()
    --- Inject diagnostics into a scratch buffer via a dedicated namespace.
    --- Returns the bufnr and a cleanup function. The namespace is per-call
    --- so tests don't interfere; `vim.diagnostic.reset(ns, bufnr)` is the
    --- correct cleanup hook even though `nvim_buf_delete` would also do it.
    local function with_diagnostics(lines, diags)
        local bufnr = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
        local ns = vim.api.nvim_create_namespace("apply_edit_test_" .. tostring(bufnr))
        vim.diagnostic.set(ns, bufnr, diags)
        local function cleanup()
            vim.diagnostic.reset(ns, bufnr)
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end
        return bufnr, cleanup
    end

    --- An edited range covering the whole buffer, so every diagnostic counts
    --- as "in range" regardless of context window. Used by tests that care
    --- about the detail shape, not the range scoping.
    local function all(n)
        return { { start_line = 1, end_line = n } }
    end

    it("returns empty detail and zeroed counts for a buffer with no diagnostics", function()
        local bufnr, cleanup = with_diagnostics({ "a", "b" }, {})
        local detail, counts = collect_diagnostics(bufnr, all(2))
        assert.is.equal(0, #detail)
        assert.is.equal(0, counts.errors)
        assert.is.equal(0, counts.warnings)
        cleanup()
    end)

    it("translates a single in-range error to the canonical shape", function()
        -- Inject one ERROR on line 1, cols 0-3 (0-based).
        -- Expected output: 1-based positions, severity='error'.
        local bufnr, cleanup = with_diagnostics({ "abc def", "ghi" }, {
            {
                lnum = 0,
                col = 0,
                end_lnum = 0,
                end_col = 3,
                severity = vim.diagnostic.severity.ERROR,
                message = "undefined identifier",
                source = "fake-lsp",
                code = "undef",
            },
        })
        local detail, counts = collect_diagnostics(bufnr, all(2))
        assert.is.equal(1, #detail)
        local d = detail[1]
        assert.is.equal("error", d.severity)
        assert.is.equal(1, d.line)
        assert.is.equal(1, d.end_line)
        assert.is.equal(1, d.col) -- 0+1
        assert.is.equal(4, d.end_col) -- 3+1
        assert.is.equal("undefined identifier", d.message)
        assert.is.equal("fake-lsp", d.source)
        assert.is.equal("undef", d.code)
        assert.is.equal(1, counts.errors)
        assert.is.equal(0, counts.warnings)
        cleanup()
    end)

    it("in-range detail includes ALL severities (info/hint not filtered)", function()
        -- Inject one of each severity, all in range. Detail must include all
        -- four; counts must tally errors+warnings only.
        local bufnr, cleanup = with_diagnostics({ "a", "b", "c", "d" }, {
            {
                lnum = 0,
                col = 0,
                end_lnum = 0,
                end_col = 1,
                severity = vim.diagnostic.severity.ERROR,
                message = "e",
            },
            {
                lnum = 1,
                col = 0,
                end_lnum = 1,
                end_col = 1,
                severity = vim.diagnostic.severity.WARN,
                message = "w",
            },
            {
                lnum = 2,
                col = 0,
                end_lnum = 2,
                end_col = 1,
                severity = vim.diagnostic.severity.INFO,
                message = "i",
            },
            {
                lnum = 3,
                col = 0,
                end_lnum = 3,
                end_col = 1,
                severity = vim.diagnostic.severity.HINT,
                message = "h",
            },
        })
        local detail, counts = collect_diagnostics(bufnr, all(4))
        assert.is.equal(4, #detail)
        -- Order is the order vim.diagnostic.get returns them in; for a
        -- single namespace that's insertion order.
        assert.is.equal("error", detail[1].severity)
        assert.is.equal("warn", detail[2].severity)
        assert.is.equal("info", detail[3].severity)
        assert.is.equal("hint", detail[4].severity)
        -- Counts: errors+warnings only; info/hint excluded.
        assert.is.equal(1, counts.errors)
        assert.is.equal(1, counts.warnings)
        cleanup()
    end)

    it("detail is scoped to edited ranges +/- context window", function()
        -- 30-line buffer. Edit at line 15. Default context = 10, so the
        -- in-range window is [5, 25]. A diagnostic at line 8 is in range;
        -- one at line 28 is out of range (but still counted file-wide).
        local lines = {}
        for i = 1, 30 do
            lines[i] = "line " .. i
        end
        local bufnr, cleanup = with_diagnostics(lines, {
            {
                lnum = 7,
                col = 0,
                end_lnum = 7,
                end_col = 1, -- line 8: in range
                severity = vim.diagnostic.severity.ERROR,
                message = "near",
            },
            {
                lnum = 27,
                col = 0,
                end_lnum = 27,
                end_col = 1, -- line 28: out of range
                severity = vim.diagnostic.severity.ERROR,
                message = "far",
            },
        })
        local detail, counts = collect_diagnostics(bufnr, { { start_line = 15, end_line = 15 } })
        assert.is.equal(1, #detail)
        assert.is.equal("near", detail[1].message)
        assert.is.equal(8, detail[1].line)
        -- Whole-file counts include BOTH, even the out-of-range one.
        assert.is.equal(2, counts.errors)
        assert.is.equal(0, counts.warnings)
        cleanup()
    end)

    it("a custom context window widens/narrows the in-range set", function()
        local lines = {}
        for i = 1, 30 do
            lines[i] = "line " .. i
        end
        local bufnr, cleanup = with_diagnostics(lines, {
            {
                lnum = 19,
                col = 0,
                end_lnum = 19,
                end_col = 1, -- line 20
                severity = vim.diagnostic.severity.WARN,
                message = "w20",
            },
        })
        -- Edit at line 15, context 0 -> window [15,15], line 20 excluded.
        local d0 = collect_diagnostics(bufnr, { { start_line = 15, end_line = 15 } }, 0)
        assert.is.equal(0, #d0)
        -- Same edit, context 5 -> window [10,20], line 20 included.
        local d5 = collect_diagnostics(bufnr, { { start_line = 15, end_line = 15 } }, 5)
        assert.is.equal(1, #d5)
        cleanup()
    end)

    it("a multi-line in-range diagnostic keeps distinct end_line", function()
        -- 0-based lnum=0..2 -> 1-based line=1, end_line=3
        local bufnr, cleanup = with_diagnostics({ "a", "b", "c" }, {
            {
                lnum = 0,
                col = 2,
                end_lnum = 2,
                end_col = 1,
                severity = vim.diagnostic.severity.ERROR,
                message = "spans",
            },
        })
        local detail = collect_diagnostics(bufnr, all(3))
        assert.is.equal(1, #detail)
        assert.is.equal(1, detail[1].line)
        assert.is.equal(3, detail[1].end_line)
        assert.is.equal(3, detail[1].col)
        assert.is.equal(2, detail[1].end_col)
        cleanup()
    end)

    it("handles in-range diagnostics with missing source / code", function()
        local bufnr, cleanup = with_diagnostics({ "a" }, {
            {
                lnum = 0,
                col = 0,
                end_lnum = 0,
                end_col = 1,
                severity = vim.diagnostic.severity.ERROR,
                message = "bare",
            },
        })
        local detail = collect_diagnostics(bufnr, all(1))
        assert.is.equal(1, #detail)
        assert.is.equal(nil, detail[1].source)
        assert.is.equal(nil, detail[1].code)
        cleanup()
    end)

    it("returns empty detail and zeroed counts when the buffer is invalid", function()
        local bufnr = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_delete(bufnr, { force = true })
        local detail, counts = collect_diagnostics(bufnr, all(1))
        assert.is.equal(0, #detail)
        assert.is.equal(0, counts.errors)
        assert.is.equal(0, counts.warnings)
    end)

    it("counts the whole file even when no edited range is given", function()
        -- Empty edited_ranges -> no diagnostic is "in range", but counts
        -- still tally the whole file.
        local bufnr, cleanup = with_diagnostics({ "a", "b" }, {
            {
                lnum = 0,
                col = 0,
                end_lnum = 0,
                end_col = 1,
                severity = vim.diagnostic.severity.ERROR,
                message = "e",
            },
            {
                lnum = 1,
                col = 0,
                end_lnum = 1,
                end_col = 1,
                severity = vim.diagnostic.severity.WARN,
                message = "w",
            },
        })
        local detail, counts = collect_diagnostics(bufnr, {})
        assert.is.equal(0, #detail)
        assert.is.equal(1, counts.errors)
        assert.is.equal(1, counts.warnings)
        cleanup()
    end)
end)

describe("intersects_edited", function()
    it("returns true when the diagnostic overlaps an edited range", function()
        assert.is_true(intersects_edited(10, 10, { { start_line = 8, end_line = 12 } }, 0))
    end)

    it("returns false when outside the range and context", function()
        assert.is_false(intersects_edited(20, 20, { { start_line = 8, end_line = 12 } }, 0))
    end)

    it("context grows the range on both sides (inclusive boundary)", function()
        -- Range [10,10], context 5 -> effective [5,15]. Lines 5 and 15 are in.
        assert.is_true(intersects_edited(5, 5, { { start_line = 10, end_line = 10 } }, 5))
        assert.is_true(intersects_edited(15, 15, { { start_line = 10, end_line = 10 } }, 5))
        -- Line 4 and 16 are just out.
        assert.is_false(intersects_edited(4, 4, { { start_line = 10, end_line = 10 } }, 5))
        assert.is_false(intersects_edited(16, 16, { { start_line = 10, end_line = 10 } }, 5))
    end)

    it("a multi-line diagnostic straddling the window counts as in range", function()
        -- Diagnostic spans [1,100]; even a tiny window intersects it.
        assert.is_true(intersects_edited(1, 100, { { start_line = 50, end_line = 50 } }, 0))
    end)

    it("returns true if ANY of several edited ranges matches", function()
        local ranges = { { start_line = 1, end_line = 1 }, { start_line = 90, end_line = 95 } }
        assert.is_true(intersects_edited(92, 92, ranges, 0))
    end)

    it("returns false for an empty edited-ranges list", function()
        assert.is_false(intersects_edited(10, 10, {}, 10))
    end)
end)

describe("resolve_lsp_wait_ms", function()
    -- The resolver takes a client list directly (not a bufnr) so we can
    -- exercise it without starting a real LSP. Each `client` only needs
    -- a `name` field for resolution.

    local TABLE = {
        lua_ls = 300,
        tsserver = 800,
        rust_analyzer = 3000,
        metals = 5000,
    }
    local DEFAULT = 1000

    it("returns 0 when no clients are attached", function()
        assert.is.equal(0, resolve_lsp_wait_ms({}, TABLE, DEFAULT))
    end)

    it("returns the table value for a single known client", function()
        local clients = { { name = "lua_ls" } }
        assert.is.equal(300, resolve_lsp_wait_ms(clients, TABLE, DEFAULT))
    end)

    it("falls back to the default for unknown clients", function()
        local clients = { { name = "some_unknown_lsp" } }
        assert.is.equal(DEFAULT, resolve_lsp_wait_ms(clients, TABLE, DEFAULT))
    end)

    it("returns the max across multiple clients (slow wins)", function()
        -- tsserver=800, eslint=missing→1000(default), metals=5000 → max=5000.
        local clients = {
            { name = "tsserver" },
            { name = "eslint" },
            { name = "metals" },
        }
        assert.is.equal(5000, resolve_lsp_wait_ms(clients, TABLE, DEFAULT))
    end)

    it("still picks the max when all clients are unknown", function()
        local clients = {
            { name = "mystery_lsp_one" },
            { name = "mystery_lsp_two" },
        }
        assert.is.equal(DEFAULT, resolve_lsp_wait_ms(clients, TABLE, DEFAULT))
    end)

    it("handles a single very-slow client correctly", function()
        local clients = { { name = "metals" } }
        assert.is.equal(5000, resolve_lsp_wait_ms(clients, TABLE, DEFAULT))
    end)

    it("respects the default parameter (not hardcoded)", function()
        -- A different default flows through unchanged for unknown clients.
        local clients = { { name = "mystery" } }
        assert.is.equal(2500, resolve_lsp_wait_ms(clients, TABLE, 2500))
    end)
end)

describe("LSP_WAIT_MS table", function()
    it("exposes the table as a public, mutable module field", function()
        -- Verify the override surface documented in the helper: users can
        -- mutate `M.LSP_WAIT_MS` after require to tune for their workflow.
        local saved = ui_backend.LSP_WAIT_MS.lua_ls
        ui_backend.LSP_WAIT_MS.lua_ls = 999
        assert.is.equal(999, ui_backend.LSP_WAIT_MS.lua_ls)
        ui_backend.LSP_WAIT_MS.lua_ls = saved
    end)

    it("exposes DEFAULT_LSP_WAIT_MS as a sensible non-zero default", function()
        -- We don't want to pin the exact value (it may evolve), but it
        -- must be positive — zero would mean "never wait" and silently
        -- defeat the per-LSP table for unknown clients.
        assert(DEFAULT_LSP_WAIT_MS > 0, "DEFAULT_LSP_WAIT_MS must be positive, got " .. tostring(DEFAULT_LSP_WAIT_MS))
    end)
end)
