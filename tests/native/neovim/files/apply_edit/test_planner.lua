--- Tests for mcphub.native.neovim.files.apply_edit.planner.
---
--- Run headless:
---   make test
---
--- Or one file at a time:
---   make test_file FILE=tests/native/neovim/files/apply_edit/test_planner.lua

local assert = require("tests.native.neovim.files.apply_edit.busted_assert")

local helpers = require("tests.native.neovim.files.apply_edit.helpers")
local schema = require("mcphub.native.neovim.files.apply_edit.schema")

--- Build the parsed-input shape the schema would produce, without
--- actually running validation. Tests are about planner behaviour, not
--- about retesting schema. The shape mirrors `schema.validate`'s return.
---
--- @param ops      table[]
--- @param contents table?
--- @return table parsed_input
local function parsed_input(ops, contents)
    return {
        ops = ops,
        contents = contents or {},
        dry_run = false,
        warnings = {},
    }
end

--- Anchor builders matching the schema's parsed shape.
local function lr(s, e)
    return { by = "line_range", start = s, ["end"] = e }
end
local function ut(t, occ)
    local a = { by = "unique_text", text = t }
    if occ ~= nil then
        a.occurrence = occ
    end
    return a
end
local function before(base)
    return { by = "before", of = base }
end
local function after_(base)
    return { by = "after", of = base }
end

--- Build an op of a given kind. Default kind is replace_range; pass
--- `kind = 'insert' | 'delete_range'` to override.
local function op(t)
    return {
        kind = t.kind or "replace_range",
        path = t.path,
        anchor = t.anchor,
        content = t.content,
        content_ref = t.content_ref,
        indent = t.indent or "match_anchor",
    }
end

--- Write a tempfile with the given content and return its absolute
--- path. Cleanup is the test's responsibility (or test exit; the
--- tempfile lives until process end).
local function tempfile(content)
    local tmp = vim.fn.tempname()
    local f = assert(io.open(tmp, "wb"), "tempfile open failed")
    f:write(content)
    f:close()
    return vim.fn.fnamemodify(tmp, ":p")
end

--- Wipe the buffer attached to `path` and delete the file.
local function cleanup(path)
    local bufnr = vim.fn.bufnr(path)
    if bufnr > 0 then
        pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
    vim.fn.delete(path)
end

describe("mcphub.native.neovim.files.apply_edit.planner", function()
    describe("happy path", function()
        it("returns a Plan with located_ops, records, warnings", function()
            local path = tempfile("alpha\nbeta\ngamma\n")
            local plan, fail = helpers.plan(parsed_input({
                op({ path = path, anchor = lr(2, 2), content = "NEW" }),
            }))
            assert.is_nil(fail)
            assert.is.equal(1, #plan.located_ops)
            assert.is_not_nil(plan.records[path])
            assert.are.same({}, plan.warnings)

            local lop = plan.located_ops[1]
            assert.is.equal(1, lop.op_index) -- 1-based Lua
            assert.is.equal("replace_range", lop.kind)
            assert.is.equal(path, lop.path)
            assert.are.same({ start_line = 2, end_line = 2 }, lop.range)
            assert.is.equal("NEW", lop.content)
            assert.is.equal("match_anchor", lop.indent)
            cleanup(path)
        end)

        it("forwards schema warnings through the plan", function()
            local path = tempfile("foo\n")
            local input = parsed_input({
                op({ path = path, anchor = lr(1, 1), content = "x" }),
            })
            input.warnings = {
                { path = "contents['unused']", reason = "unused_content_label", message = "x" },
            }
            local plan = assert(helpers.plan(input))
            assert.is.equal(1, #plan.warnings)
            assert.is.equal("unused_content_label", plan.warnings[1].reason)
            cleanup(path)
        end)

        it("resolves content_ref against the contents map", function()
            local path = tempfile("foo\n")
            local plan = assert(
                helpers.plan(
                    parsed_input(
                        { op({ path = path, anchor = lr(1, 1), content_ref = "body" }) },
                        { body = "BIG\nMULTI\nLINE\n" }
                    )
                )
            )
            assert.is.equal("BIG\nMULTI\nLINE\n", plan.located_ops[1].content)
            cleanup(path)
        end)

        it("delete_range carries no content (nil)", function()
            local path = tempfile("foo\nbar\n")
            local plan = assert(helpers.plan(parsed_input({
                op({ kind = "delete_range", path = path, anchor = lr(1, 1) }),
            })))
            assert.is_nil(plan.located_ops[1].content)
            cleanup(path)
        end)
    end)

    describe("file caching", function()
        it("multi-op same file reads only once", function()
            local path = tempfile("a\nb\nc\nd\ne\n")
            local plan = assert(helpers.plan(parsed_input({
                op({ path = path, anchor = lr(1, 1), content = "A" }),
                op({ path = path, anchor = lr(3, 3), content = "C" }),
                op({ path = path, anchor = lr(5, 5), content = "E" }),
            })))
            assert.is.equal(3, #plan.located_ops)
            -- All three ops share the same record (by identity).
            local rec = plan.records[path]
            assert.is_not_nil(rec)
            -- Only one record total.
            local count = 0
            for _ in pairs(plan.records) do
                count = count + 1
            end
            assert.is.equal(1, count)
            cleanup(path)
        end)

        it("different paths produce separate records", function()
            local p1 = tempfile("one\n")
            local p2 = tempfile("two\n")
            local plan = assert(helpers.plan(parsed_input({
                op({ path = p1, anchor = lr(1, 1), content = "X" }),
                op({ path = p2, anchor = lr(1, 1), content = "Y" }),
            })))
            assert.is_not_nil(plan.records[p1])
            assert.is_not_nil(plan.records[p2])
            assert.is_truthy(plan.records[p1] ~= plan.records[p2])
            cleanup(p1)
            cleanup(p2)
        end)

        it("relative and absolute path spellings dedupe to one record", function()
            -- Use lines 1 and 3 so the two ops don't range-conflict;
            -- the test is about path deduplication, not conflict logic.
            local abs = tempfile("one\ntwo\nthree\n")
            local home_form = vim.fn.fnamemodify(abs, ":~")

            local plan, fail = helpers.plan(parsed_input({
                op({ path = abs, anchor = lr(1, 1), content = "X" }),
                op({ path = home_form, anchor = lr(3, 3), content = "Y" }),
            }))
            assert.is_nil(fail)

            -- Exactly one record total — proves dedup happened.
            local count = 0
            for _ in pairs(plan.records) do
                count = count + 1
            end
            assert.is.equal(1, count)

            -- Both located ops point at the same abs path.
            assert.is.equal(2, #plan.located_ops)
            assert.is.equal(abs, plan.located_ops[1].path)
            assert.is.equal(abs, plan.located_ops[2].path)
            cleanup(abs)
        end)
    end)

    describe("IO failures", function()
        it("missing file → io_error with 1-based op_index and original path", function()
            local plan, fail = helpers.plan(parsed_input({
                op({ path = "/nonexistent/never/exists", anchor = lr(1, 1), content = "x" }),
            }))
            assert.is_nil(plan)
            assert.is.equal(1, #fail.failures)
            assert.is.equal(schema.ERROR_REASONS.io_error, fail.failures[1].reason)
            assert.is.equal(1, fail.failures[1].op_index) -- 1-based
            assert.is.equal("/nonexistent/never/exists", fail.failures[1].path)
        end)

        it("multiple ops on the same broken path each get their own failure", function()
            local _, fail = helpers.plan(parsed_input({
                op({ path = "/nonexistent/x", anchor = lr(1, 1), content = "a" }),
                op({ path = "/nonexistent/x", anchor = lr(2, 2), content = "b" }),
            }))
            assert.is.equal(2, #fail.failures)
            assert.is.equal(1, fail.failures[1].op_index)
            assert.is.equal(2, fail.failures[2].op_index)
            -- Both flagged as io_error.
            assert.is.equal(schema.ERROR_REASONS.io_error, fail.failures[1].reason)
            assert.is.equal(schema.ERROR_REASONS.io_error, fail.failures[2].reason)
        end)

        it("failing op does not prevent other files from being planned", function()
            local good = tempfile("alive\n")
            local _, fail = helpers.plan(parsed_input({
                op({ path = "/nonexistent/q", anchor = lr(1, 1), content = "a" }),
                op({ path = good, anchor = lr(1, 1), content = "B" }),
            }))
            -- Only the IO failure surfaces (op 1). Op 2 resolved cleanly
            -- but since the batch had a failure overall, plan returns nil.
            -- The contract: collect ALL failures so the LLM can fix them
            -- in one round-trip; do not surface op 2's success while op 1
            -- is broken.
            assert.is.equal(1, #fail.failures)
            assert.is.equal(1, fail.failures[1].op_index)
            cleanup(good)
        end)
    end)

    describe("anchor resolution failures", function()
        it("anchor_not_found enriched with 1-based op_index and original path", function()
            local path = tempfile("one\n")
            local _, fail = helpers.plan(parsed_input({
                op({ path = path, anchor = lr(10, 10), content = "X" }),
            }))
            assert.is.equal(1, #fail.failures)
            local f = fail.failures[1]
            assert.is.equal(schema.ERROR_REASONS.anchor_not_found, f.reason)
            assert.is.equal(1, f.op_index)
            assert.is.equal(path, f.path)
            cleanup(path)
        end)

        it("anchor_ambiguous bubbles up with candidates intact", function()
            local path = tempfile("X\nY\nX\n")
            local _, fail = helpers.plan(parsed_input({
                op({ path = path, anchor = ut("X"), content = "Z" }),
            }))
            local f = fail.failures[1]
            assert.is.equal(schema.ERROR_REASONS.anchor_ambiguous, f.reason)
            assert.is_not_nil(f.candidates)
            assert.is.equal(2, #f.candidates)
            cleanup(path)
        end)

        it("accumulates failures across ops (does not short-circuit)", function()
            local path = tempfile("a\nb\n")
            local _, fail = helpers.plan(parsed_input({
                op({ path = path, anchor = lr(99, 99), content = "x" }), -- not found
                op({ path = path, anchor = lr(100, 100), content = "y" }), -- not found
            }))
            assert.is.equal(2, #fail.failures)
            assert.is.equal(1, fail.failures[1].op_index)
            assert.is.equal(2, fail.failures[2].op_index)
            cleanup(path)
        end)

        it("IO failures and anchor failures are collated, IO first", function()
            local path = tempfile("alive\n")
            local _, fail = helpers.plan(parsed_input({
                op({ path = "/nonexistent/bad", anchor = lr(1, 1), content = "a" }),
                op({ path = path, anchor = lr(99, 99), content = "b" }),
            }))
            assert.is.equal(2, #fail.failures)
            -- IO failure (op_index=1) comes first.
            assert.is.equal(schema.ERROR_REASONS.io_error, fail.failures[1].reason)
            assert.is.equal(1, fail.failures[1].op_index)
            -- Anchor failure (op_index=2) comes second.
            assert.is.equal(schema.ERROR_REASONS.anchor_not_found, fail.failures[2].reason)
            assert.is.equal(2, fail.failures[2].op_index)
            cleanup(path)
        end)
    end)

    describe('multi-range ops (occurrence: "all")', function()
        it('delete_range with occurrence:"all" produces lop.ranges', function()
            local path = tempfile("TODO\nbody\nTODO\nmore\nTODO\n")
            local plan = assert(helpers.plan(parsed_input({
                op({ kind = "delete_range", path = path, anchor = ut("TODO", "all") }),
            })))
            local lop = plan.located_ops[1]
            assert.is_nil(lop.range)
            assert.is_not_nil(lop.ranges)
            assert.is.equal(3, #lop.ranges)
            cleanup(path)
        end)

        it('single-occurrence delete_range with "all" still uses ranges shape', function()
            local path = tempfile("UNIQUE\nrest\n")
            local plan = assert(helpers.plan(parsed_input({
                op({ kind = "delete_range", path = path, anchor = ut("UNIQUE", "all") }),
            })))
            assert.is_not_nil(plan.located_ops[1].ranges)
            assert.is.equal(1, #plan.located_ops[1].ranges)
            cleanup(path)
        end)
    end)

    describe("range conflict detection", function()
        it("two overlapping replace_range on same file → range_conflict on the later op", function()
            local path = tempfile("a\nb\nc\nd\ne\n")
            local _, fail = helpers.plan(parsed_input({
                op({ path = path, anchor = lr(2, 4), content = "X" }),
                op({ path = path, anchor = lr(3, 5), content = "Y" }),
            }))
            assert.is.equal(1, #fail.failures)
            local f = fail.failures[1]
            assert.is.equal(schema.ERROR_REASONS.range_conflict, f.reason)
            assert.is.equal(2, f.op_index) -- LATER op
            assert.is.equal(1, f.conflict_op_index) -- EARLIER op
            assert.are.same({ start_line = 3, end_line = 5 }, f.range)
            assert.are.same({ start_line = 2, end_line = 4 }, f.conflict_range)
            cleanup(path)
        end)

        it("non-overlapping ranges → no conflict", function()
            local path = tempfile("a\nb\nc\nd\ne\n")
            local plan = assert(helpers.plan(parsed_input({
                op({ path = path, anchor = lr(1, 2), content = "X" }),
                op({ path = path, anchor = lr(4, 5), content = "Y" }),
            })))
            assert.is.equal(2, #plan.located_ops)
            cleanup(path)
        end)

        it("overlap across different files → no conflict", function()
            local p1 = tempfile("a\nb\nc\n")
            local p2 = tempfile("d\ne\nf\n")
            local plan = assert(helpers.plan(parsed_input({
                op({ path = p1, anchor = lr(1, 3), content = "X" }),
                op({ path = p2, anchor = lr(1, 3), content = "Y" }),
            })))
            assert.is.equal(2, #plan.located_ops)
            cleanup(p1)
            cleanup(p2)
        end)

        it("insert at gap inside another op's range → conflict (conservative rule)", function()
            -- insert before line 3 → position {3, 2} → line set {3}.
            -- replace lines 2..4 → line set {2, 3, 4}. Both touch line 3.
            local path = tempfile("a\nb\nc\nd\ne\n")
            local _, fail = helpers.plan(parsed_input({
                op({ path = path, anchor = lr(2, 4), content = "REPL" }),
                op({ kind = "insert", path = path, anchor = before(lr(3, 3)), content = "INS" }),
            }))
            assert.is.equal(1, #fail.failures)
            assert.is.equal(schema.ERROR_REASONS.range_conflict, fail.failures[1].reason)
            cleanup(path)
        end)

        it("two inserts at the same gap → conflict", function()
            local path = tempfile("a\nb\nc\n")
            local _, fail = helpers.plan(parsed_input({
                op({ kind = "insert", path = path, anchor = before(lr(2, 2)), content = "A" }),
                op({ kind = "insert", path = path, anchor = before(lr(2, 2)), content = "B" }),
            }))
            assert.is.equal(1, #fail.failures)
            assert.is.equal(schema.ERROR_REASONS.range_conflict, fail.failures[1].reason)
            cleanup(path)
        end)

        it("two inserts at different gaps → no conflict", function()
            local path = tempfile("a\nb\nc\nd\n")
            local plan = assert(helpers.plan(parsed_input({
                op({ kind = "insert", path = path, anchor = before(lr(2, 2)), content = "A" }),
                op({ kind = "insert", path = path, anchor = before(lr(4, 4)), content = "B" }),
            })))
            assert.is.equal(2, #plan.located_ops)
            cleanup(path)
        end)

        it("insert after line N + replace_range starting at N+1 → conflict (conservative)", function()
            -- Conservative rule: insert after line 3 → position {4, 3} →
            -- line set {4}. replace_range lines 4..5 → line set {4, 5}.
            -- Both touch 4 → flagged as conflict. (Technically the insert
            -- places content between lines 3 and 4, and the replace
            -- overwrites the original 4..5; whether that's "really" a
            -- conflict depends on apply order. The conservative rule says
            -- yes — easier to relax later.)
            local path = tempfile("a\nb\nc\nd\ne\n")
            local _, fail = helpers.plan(parsed_input({
                op({ path = path, anchor = lr(4, 5), content = "REPL" }),
                op({ kind = "insert", path = path, anchor = after_(lr(3, 3)), content = "INS" }),
            }))
            assert.is.equal(1, #fail.failures)
            assert.is.equal(schema.ERROR_REASONS.range_conflict, fail.failures[1].reason)
            cleanup(path)
        end)

        it('multi-range (occurrence:"all") + single range that overlaps one of them → conflict', function()
            local path = tempfile("TODO\nbody\nTODO\nmore\nTODO\n")
            local _, fail = helpers.plan(parsed_input({
                op({ kind = "delete_range", path = path, anchor = ut("TODO", "all") }), -- lines 1, 3, 5
                op({ path = path, anchor = lr(3, 3), content = "X" }), -- line 3
            }))
            assert.is.equal(1, #fail.failures)
            assert.is.equal(schema.ERROR_REASONS.range_conflict, fail.failures[1].reason)
            cleanup(path)
        end)

        it('conflicts within a single multi-range op (occurrence:"all") are NOT flagged', function()
            -- "all" produces multiple ranges from one anchor by
            -- non-overlapping scan; they are inherently disjoint and
            -- belong to the same op. No conflict.
            local path = tempfile("TODO\nbody\nTODO\nmore\nTODO\n")
            local plan = assert(helpers.plan(parsed_input({
                op({ kind = "delete_range", path = path, anchor = ut("TODO", "all") }),
            })))
            assert.is.equal(3, #plan.located_ops[1].ranges)
            cleanup(path)
        end)

        it("skips conflict detection when anchor failures exist (high signal:noise)", function()
            -- Op 1 fails anchor resolution; op 2 resolves but would
            -- conflict with op 1 if op 1's resolved range existed.
            -- Planner should report ONLY the anchor failure — surfacing
            -- a "conflict with op_index 1" failure when op 1 doesn't have
            -- a resolved range is meaningless noise.
            local path = tempfile("a\nb\nc\nd\ne\n")
            local _, fail = helpers.plan(parsed_input({
                op({ path = path, anchor = lr(99, 99), content = "X" }), -- not found
                op({ path = path, anchor = lr(2, 4), content = "Y" }), -- would conflict if op 1 had resolved to [3..5]
            }))
            -- Exactly one failure: the anchor failure on op 1.
            assert.is.equal(1, #fail.failures)
            assert.is.equal(schema.ERROR_REASONS.anchor_not_found, fail.failures[1].reason)
            cleanup(path)
        end)
    end)

    describe("input validation (planner-bug catches)", function()
        it("rejects a non-table parsed_input", function()
            assert.is_falsy(pcall(helpers.plan, "nope"))
        end)

        it("rejects a parsed_input without ops", function()
            assert.is_falsy(pcall(helpers.plan, { contents = {} }))
        end)
    end)
end)
