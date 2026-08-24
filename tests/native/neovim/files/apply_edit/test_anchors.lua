--- Tests for mcphub.native.neovim.files.apply_edit.anchors.*.
---
--- Run headless:
---   make test
---
--- Or one file at a time:
---   make test_file FILE=tests/native/neovim/files/apply_edit/test_anchors.lua

local assert = require("tests.native.neovim.files.apply_edit.busted_assert")

local anchors = require("mcphub.native.neovim.files.apply_edit.anchors")
local fr = require("mcphub.native.neovim.files.apply_edit.file_record")
local line_range = require("mcphub.native.neovim.files.apply_edit.anchors.line_range")
local modifier = require("mcphub.native.neovim.files.apply_edit.anchors.modifier")
local schema = require("mcphub.native.neovim.files.apply_edit.schema")
local unique_text = require("mcphub.native.neovim.files.apply_edit.anchors.unique_text")

--- Build a parsed `line_range` anchor with the schema's key shape.
--- The schema uses `['end']` because `end` is a reserved word.
local function lr(s, e)
    return { by = "line_range", start = s, ["end"] = e }
end

--- Build a parsed `unique_text` anchor. `occurrence` is optional.
local function ut(text, occurrence)
    local a = { by = "unique_text", text = text }
    if occurrence ~= nil then
        a.occurrence = occurrence
    end
    return a
end

describe("mcphub.native.neovim.files.apply_edit.anchors.line_range", function()
    describe("happy path: in-bounds anchors resolve to themselves", function()
        local rec = fr.from_content("t", "a\nb\nc\nd\ne\n") -- 5 lines

        it("single-line at the start of file", function()
            local range, fail = line_range.resolve(lr(1, 1), rec)
            assert.is_nil(fail)
            assert.are.same({ start_line = 1, end_line = 1 }, range)
        end)

        it("single-line in the middle", function()
            local range, fail = line_range.resolve(lr(3, 3), rec)
            assert.is_nil(fail)
            assert.are.same({ start_line = 3, end_line = 3 }, range)
        end)

        it("single-line at the last line", function()
            local range, fail = line_range.resolve(lr(5, 5), rec)
            assert.is_nil(fail)
            assert.are.same({ start_line = 5, end_line = 5 }, range)
        end)

        it("multi-line range", function()
            local range, fail = line_range.resolve(lr(2, 4), rec)
            assert.is_nil(fail)
            assert.are.same({ start_line = 2, end_line = 4 }, range)
        end)

        it("whole-file range (1..n_lines)", function()
            local range, fail = line_range.resolve(lr(1, 5), rec)
            assert.is_nil(fail)
            assert.are.same({ start_line = 1, end_line = 5 }, range)
        end)
    end)

    describe("single-line file", function()
        local rec = fr.from_content("t", "only") -- 1 line, no trailing newline

        it("line 1 resolves", function()
            local range, fail = line_range.resolve(lr(1, 1), rec)
            assert.is_nil(fail)
            assert.are.same({ start_line = 1, end_line = 1 }, range)
        end)

        it("line 2 is out of bounds", function()
            local range, fail = line_range.resolve(lr(2, 2), rec)
            assert.is_nil(range)
            assert.is.equal(schema.ERROR_REASONS.anchor_not_found, fail.reason)
            assert.are.same({ start_line = 1, end_line = 1 }, fail.available_range)
        end)
    end)

    describe("out-of-bounds: anchor_not_found", function()
        local rec = fr.from_content("t", "a\nb\nc\n") -- 3 lines

        it("start past EOF", function()
            local range, fail = line_range.resolve(lr(4, 4), rec)
            assert.is_nil(range)
            assert.is.equal(schema.ERROR_REASONS.anchor_not_found, fail.reason)
            assert.are.same({ start_line = 1, end_line = 3 }, fail.available_range)
            assert.is_truthy(fail.hint:find("out of bounds", 1, true))
            assert.is_truthy(fail.hint:find("3 line", 1, true))
        end)

        it("end past EOF (start in bounds)", function()
            local range, fail = line_range.resolve(lr(2, 10), rec)
            assert.is_nil(range)
            assert.is.equal(schema.ERROR_REASONS.anchor_not_found, fail.reason)
            assert.are.same({ start_line = 1, end_line = 3 }, fail.available_range)
        end)

        it("echoes the anchor back unchanged on failure", function()
            local anchor = lr(99, 100)
            local _, fail = line_range.resolve(anchor, rec)
            assert.are.same(anchor, fail.anchor)
        end)

        it("hint points at neovim__read_with_fingerprint for re-reading", function()
            local _, fail = line_range.resolve(lr(99, 99), rec)
            assert.is_truthy(fail.hint:find("neovim__read_with_fingerprint", 1, true))
        end)
    end)

    describe("empty file", function()
        local rec = fr.from_content("t", "") -- 0 lines

        it("any line_range fails with available_range zero", function()
            local range, fail = line_range.resolve(lr(1, 1), rec)
            assert.is_nil(range)
            assert.is.equal(schema.ERROR_REASONS.anchor_not_found, fail.reason)
            assert.are.same({ start_line = 0, end_line = 0 }, fail.available_range)
            assert.is_truthy(fail.hint:find("zero lines", 1, true))
        end)

        it("hint suggests neovim__write_file for creating content", function()
            local _, fail = line_range.resolve(lr(1, 1), rec)
            assert.is_truthy(fail.hint:find("neovim__write_file", 1, true))
        end)
    end)

    describe("invariant assertions (planner-bug catches)", function()
        local rec = fr.from_content("t", "a\nb\n")

        it("rejects a non-table anchor", function()
            local ok = pcall(line_range.resolve, "not-a-table", rec)
            assert.is_falsy(ok)
        end)

        it('rejects an anchor whose `by` is not "line_range"', function()
            local ok = pcall(line_range.resolve, { by = "unique_text", text = "x" }, rec)
            assert.is_falsy(ok)
        end)

        it("rejects an anchor with start < 1 (schema-bypass)", function()
            local ok = pcall(line_range.resolve, lr(0, 0), rec)
            assert.is_falsy(ok)
        end)

        it("rejects an anchor with end < start (schema-bypass)", function()
            local ok = pcall(line_range.resolve, lr(3, 2), rec)
            assert.is_falsy(ok)
        end)

        it("rejects a non-FileRecord record", function()
            local ok = pcall(line_range.resolve, lr(1, 1), { not_a = "record" })
            assert.is_falsy(ok)
        end)
    end)

    describe("integration with FileRecord helpers", function()
        -- The whole point of resolving a line_range is to feed the result
        -- to FileRecord.byte_range / line_text. Verify the contract.
        local rec = fr.from_content("t", "alpha\nbeta\ngamma\n")

        it("resolved range round-trips through line_text", function()
            local range = assert(line_range.resolve(lr(2, 2), rec))
            assert.is.equal("beta", fr.line_text(rec, range.start_line, range.end_line))
        end)

        it("multi-line resolved range round-trips through line_text", function()
            local range = assert(line_range.resolve(lr(1, 3), rec))
            assert.is.equal("alpha\nbeta\ngamma", fr.line_text(rec, range.start_line, range.end_line))
        end)
    end)
end)

describe("mcphub.native.neovim.files.apply_edit.anchors.unique_text", function()
    describe("happy path: single match", function()
        local rec = fr.from_content("t", "alpha\nbeta\ngamma\n")

        it("resolves a single-line single-match", function()
            local range, fail = unique_text.resolve(ut("beta"), rec)
            assert.is_nil(fail)
            assert.are.same({ start_line = 2, end_line = 2 }, range)
        end)

        it("resolved range round-trips through line_text", function()
            local range = assert(unique_text.resolve(ut("beta"), rec))
            assert.is.equal("beta", fr.line_text(rec, range.start_line, range.end_line))
        end)

        it("matches at the start of the file (line 1)", function()
            local range = assert(unique_text.resolve(ut("alpha"), rec))
            assert.are.same({ start_line = 1, end_line = 1 }, range)
        end)

        it("matches at the end of the file (last line)", function()
            local range = assert(unique_text.resolve(ut("gamma"), rec))
            assert.are.same({ start_line = 3, end_line = 3 }, range)
        end)

        it("matches a substring within a line (not just whole lines)", function()
            local range = assert(unique_text.resolve(ut("lpha"), rec))
            -- "lpha" lives on line 1.
            assert.are.same({ start_line = 1, end_line = 1 }, range)
        end)
    end)

    describe("multi-line matches", function()
        local rec = fr.from_content("t", "line1\nline2\nline3\nline4\n")

        it("match spans two lines", function()
            local range = assert(unique_text.resolve(ut("line2\nline3"), rec))
            assert.are.same({ start_line = 2, end_line = 3 }, range)
        end)

        it("match spans three lines", function()
            local range = assert(unique_text.resolve(ut("line1\nline2\nline3"), rec))
            assert.are.same({ start_line = 1, end_line = 3 }, range)
        end)

        it("partial multi-line match (starts mid-line, ends mid-line)", function()
            local rec2 = fr.from_content("t", "aaaXXX\nYYYbbb\n")
            local range = assert(unique_text.resolve(ut("XXX\nYYY"), rec2))
            assert.are.same({ start_line = 1, end_line = 2 }, range)
        end)
    end)

    describe("non-overlapping match semantics", function()
        it('finds 2 matches of "aa" in "aaaa", not 3', function()
            local rec = fr.from_content("t", "aaaa\n")
            -- Should be ambiguous with exactly 2 matches.
            local range, fail = unique_text.resolve(ut("aa"), rec)
            assert.is_nil(range)
            assert.is.equal(schema.ERROR_REASONS.anchor_ambiguous, fail.reason)
            assert.is.equal(2, fail.total_matches)
        end)

        it('finds 2 matches of "ab" in "ababab" — overlapping reading would find 3', function()
            local rec = fr.from_content("t", "ababab\n")
            local range, fail = unique_text.resolve(ut("ab"), rec)
            assert.is_nil(range)
            assert.is.equal(schema.ERROR_REASONS.anchor_ambiguous, fail.reason)
            assert.is.equal(3, fail.total_matches) -- ab|ab|ab — non-overlapping IS 3 here
        end)

        it('matches non-overlap at adjacency boundary: "aa" in "aaaaa" → 2', function()
            local rec = fr.from_content("t", "aaaaa\n")
            -- Non-overlapping: 1..2, 3..4. The 5th 'a' is left over.
            local range, fail = unique_text.resolve(ut("aa"), rec)
            assert.is_nil(range)
            assert.is.equal(2, fail.total_matches)
        end)
    end)

    describe("default policy: must be unique", function()
        it("exactly one match → success", function()
            local rec = fr.from_content("t", "foo\nbar\n")
            local range = assert(unique_text.resolve(ut("foo"), rec))
            assert.are.same({ start_line = 1, end_line = 1 }, range)
        end)

        it("two matches → anchor_ambiguous with 2 candidates", function()
            local rec = fr.from_content("t", "TODO\nthing\nTODO\n")
            local range, fail = unique_text.resolve(ut("TODO"), rec)
            assert.is_nil(range)
            assert.is.equal(schema.ERROR_REASONS.anchor_ambiguous, fail.reason)
            assert.is.equal(2, #fail.candidates)
            assert.is.equal(2, fail.total_matches)
            assert.are.same({ start_line = 1, end_line = 1 }, fail.candidates[1])
            assert.are.same({ start_line = 3, end_line = 3 }, fail.candidates[2])
        end)

        it("three matches → anchor_ambiguous with 3 candidates, total_matches=3 (exact)", function()
            local rec = fr.from_content("t", "X\nA\nX\nB\nX\n")
            local range, fail = unique_text.resolve(ut("X"), rec)
            assert.is_nil(range)
            assert.is.equal(schema.ERROR_REASONS.anchor_ambiguous, fail.reason)
            assert.is.equal(3, #fail.candidates)
            assert.is.equal(3, fail.total_matches) -- exact, not ">3"
        end)

        it('four+ matches → total_matches=">3", capped at 3 candidates', function()
            local rec = fr.from_content("t", "X\nX\nX\nX\nX\nX\n") -- 6 matches
            local range, fail = unique_text.resolve(ut("X"), rec)
            assert.is_nil(range)
            assert.is.equal(schema.ERROR_REASONS.anchor_ambiguous, fail.reason)
            assert.is.equal(3, #fail.candidates)
            assert.is.equal(">3", fail.total_matches)
        end)

        it("hint mentions occurrence.nth and line_range as remediations", function()
            local rec = fr.from_content("t", "X\nX\n")
            local _, fail = unique_text.resolve(ut("X"), rec)
            assert.is_truthy(fail.hint:find("occurrence", 1, true))
            assert.is_truthy(fail.hint:find("line_range", 1, true))
        end)

        it("candidates are sorted ascending by start_line", function()
            -- Plant matches in arbitrary file order; resolver should return
            -- them sorted (which they naturally are because scan() walks
            -- top-to-bottom).
            local rec = fr.from_content("t", "pad\nMATCH\npad\nMATCH\npad\n")
            local _, fail = unique_text.resolve(ut("MATCH"), rec)
            assert.is_truthy(fail.candidates[1].start_line < fail.candidates[2].start_line)
        end)
    end)

    describe("zero matches: anchor_not_found", function()
        local rec = fr.from_content("t", "alpha\nbeta\n")

        it("returns anchor_not_found with empty candidates", function()
            local range, fail = unique_text.resolve(ut("nonexistent"), rec)
            assert.is_nil(range)
            assert.is.equal(schema.ERROR_REASONS.anchor_not_found, fail.reason)
            assert.are.same({}, fail.candidates)
            assert.is.equal(0, fail.total_matches)
        end)

        it("hint points at neovim__read_with_fingerprint for re-reading", function()
            local _, fail = unique_text.resolve(ut("nonexistent"), rec)
            assert.is_truthy(fail.hint:find("neovim__read_with_fingerprint", 1, true))
        end)
    end)

    describe('occurrence: "all"', function()
        it("returns a ranges list with every match", function()
            local rec = fr.from_content("t", "A\nx\nA\ny\nA\n")
            local result, fail = unique_text.resolve(ut("A", "all"), rec)
            assert.is_nil(fail)
            assert.is_not_nil(result.ranges)
            assert.is.equal(3, #result.ranges)
            assert.are.same({ start_line = 1, end_line = 1 }, result.ranges[1])
            assert.are.same({ start_line = 3, end_line = 3 }, result.ranges[2])
            assert.are.same({ start_line = 5, end_line = 5 }, result.ranges[3])
        end)

        it("handles single match (1-element ranges list)", function()
            local rec = fr.from_content("t", "only\n")
            local result = assert(unique_text.resolve(ut("only", "all"), rec))
            assert.is.equal(1, #result.ranges)
        end)

        it("returns empty failure on zero matches", function()
            local rec = fr.from_content("t", "nothing\n")
            local result, fail = unique_text.resolve(ut("absent", "all"), rec)
            assert.is_nil(result)
            assert.is.equal(schema.ERROR_REASONS.anchor_not_found, fail.reason)
        end)
    end)

    describe("occurrence.nth — picking a specific match", function()
        local rec = fr.from_content("t", "X\nA\nX\nB\nX\n") -- 3 X's on lines 1, 3, 5

        it("nth = 1 returns the first match", function()
            local range = assert(unique_text.resolve(ut("X", { nth = 1 }), rec))
            assert.are.same({ start_line = 1, end_line = 1 }, range)
        end)

        it("nth = 2 returns the second match", function()
            local range = assert(unique_text.resolve(ut("X", { nth = 2 }), rec))
            assert.are.same({ start_line = 3, end_line = 3 }, range)
        end)

        it("nth = 3 returns the third (last) match", function()
            local range = assert(unique_text.resolve(ut("X", { nth = 3 }), rec))
            assert.are.same({ start_line = 5, end_line = 5 }, range)
        end)

        it("nth past total → anchor_not_found with exact total_matches", function()
            local range, fail = unique_text.resolve(ut("X", { nth = 5 }), rec)
            assert.is_nil(range)
            assert.is.equal(schema.ERROR_REASONS.anchor_not_found, fail.reason)
            assert.is.equal(3, fail.total_matches)
            assert.is_truthy(fail.hint:find("only 3 occurrence", 1, true))
        end)

        it("nth on zero-match text → anchor_not_found", function()
            local range, fail = unique_text.resolve(ut("absent", { nth = 1 }), rec)
            assert.is_nil(range)
            assert.is.equal(schema.ERROR_REASONS.anchor_not_found, fail.reason)
            assert.is.equal(0, fail.total_matches)
        end)
    end)

    describe("occurrence.nth — resume-scan past cap", function()
        -- Construct a file with more than cap+1 matches and ask for nth > cap.
        -- The scan early-exits at 4 matches; the resume path must keep going.
        it("nth = 5 with 6 matches finds the 5th match", function()
            local rec = fr.from_content("t", "X\nX\nX\nX\nX\nX\n") -- 6 matches on lines 1..6
            local range = assert(unique_text.resolve(ut("X", { nth = 5 }), rec))
            assert.are.same({ start_line = 5, end_line = 5 }, range)
        end)

        it("nth = 6 with 6 matches finds the last match", function()
            local rec = fr.from_content("t", "X\nX\nX\nX\nX\nX\n")
            local range = assert(unique_text.resolve(ut("X", { nth = 6 }), rec))
            assert.are.same({ start_line = 6, end_line = 6 }, range)
        end)

        it("nth = 7 with only 6 matches → anchor_not_found, total_matches=6", function()
            local rec = fr.from_content("t", "X\nX\nX\nX\nX\nX\n")
            local range, fail = unique_text.resolve(ut("X", { nth = 7 }), rec)
            assert.is_nil(range)
            assert.is.equal(schema.ERROR_REASONS.anchor_not_found, fail.reason)
            assert.is.equal(6, fail.total_matches)
        end)
    end)

    describe("CANDIDATE_CAP early-exit verification", function()
        -- A file with vastly more matches than the cap; resolver must
        -- not collect them all. We can't directly observe loop iterations,
        -- but we CAN observe that `total_matches` is `">3"` (the
        -- early-exit signal) and `#candidates` is exactly 3.
        it("does not collect more than cap+1 matches in the default-policy path", function()
            local huge_content = string.rep("X\n", 1000)
            local rec = fr.from_content("t", huge_content)
            local _, fail = unique_text.resolve(ut("X"), rec)
            assert.is.equal(">3", fail.total_matches)
            assert.is.equal(3, #fail.candidates)
        end)

        it("CANDIDATE_CAP is exposed as a module field for testability", function()
            -- Documents the API: callers (planner, tests) may reference
            -- the cap by name rather than hardcoding 3.
            assert.is.equal(3, unique_text.CANDIDATE_CAP)
        end)
    end)

    describe("invariant assertions (planner-bug catches)", function()
        local rec = fr.from_content("t", "foo\nbar\n")

        it("rejects a non-table anchor", function()
            assert.is_falsy(pcall(unique_text.resolve, "not-a-table", rec))
        end)

        it('rejects an anchor whose `by` is not "unique_text"', function()
            assert.is_falsy(pcall(unique_text.resolve, { by = "line_range", start = 1, ["end"] = 1 }, rec))
        end)

        it("rejects an empty `text`", function()
            assert.is_falsy(pcall(unique_text.resolve, ut(""), rec))
        end)

        it("rejects a non-string `text`", function()
            assert.is_falsy(pcall(unique_text.resolve, { by = "unique_text", text = 42 }, rec))
        end)

        it("rejects a non-FileRecord record", function()
            assert.is_falsy(pcall(unique_text.resolve, ut("foo"), { not_a = "record" }))
        end)

        it("rejects occurrence.nth < 1", function()
            assert.is_falsy(pcall(unique_text.resolve, ut("foo", { nth = 0 }), rec))
        end)
    end)
end)

describe("mcphub.native.neovim.files.apply_edit.anchors.modifier", function()
    --- Build modifier-wrapped anchors. The `base` is the inner parsed anchor.
    local function before(base)
        return { by = "before", of = base }
    end
    local function after_(base)
        return { by = "after", of = base }
    end
    local function between(bt, at)
        return { by = "between", before_text = bt, after_text = at }
    end

    describe("before / after on a line_range base", function()
        local rec = fr.from_content("t", "l1\nl2\nl3\nl4\nl5\n")

        it("before { line_range 3..3 } resolves to { 3, 2 } (zero-width above line 3)", function()
            local range, fail = modifier.resolve(before(lr(3, 3)), rec)
            assert.is_nil(fail)
            assert.are.same({ start_line = 3, end_line = 2 }, range)
        end)

        it("after { line_range 3..3 } resolves to { 4, 3 } (zero-width below line 3)", function()
            local range = assert(modifier.resolve(after_(lr(3, 3)), rec))
            assert.are.same({ start_line = 4, end_line = 3 }, range)
        end)

        it("before { line_range 1..1 } produces { 1, 0 } — insert at start of file", function()
            local range = assert(modifier.resolve(before(lr(1, 1)), rec))
            assert.are.same({ start_line = 1, end_line = 0 }, range)
        end)

        it("after { line_range last..last } produces { n+1, n } — insert at end of file", function()
            local range = assert(modifier.resolve(after_(lr(5, 5)), rec))
            assert.are.same({ start_line = 6, end_line = 5 }, range)
        end)

        it("before/after on a multi-line range use the first/last line of the range", function()
            local range_b = assert(modifier.resolve(before(lr(2, 4)), rec))
            assert.are.same({ start_line = 2, end_line = 1 }, range_b)
            local range_a = assert(modifier.resolve(after_(lr(2, 4)), rec))
            assert.are.same({ start_line = 5, end_line = 4 }, range_a)
        end)
    end)

    describe("between { before_text, after_text } names the seam directly", function()
        local rec = fr.from_content("t", "l1\nl2\nl3\nl4\nl5\n")

        it("seam between line 3 and line 4 → {4, 3}", function()
            local range = assert(modifier.resolve(between("l3", "l4"), rec))
            assert.are.same({ start_line = 4, end_line = 3 }, range)
        end)

        it("seam between line 1 and line 2 → {2, 1}", function()
            local range = assert(modifier.resolve(between("l1", "l2"), rec))
            assert.are.same({ start_line = 2, end_line = 1 }, range)
        end)

        it("multi-line before_text: seam after its LAST line", function()
            -- before_text spans l2..l3 (lines 2-3); after_text is l4 (line 4).
            -- Block l2\nl3\nl4 matches lines 2..4; seam after l3 → {4, 3}.
            local range = assert(modifier.resolve(between("l2\nl3", "l4"), rec))
            assert.are.same({ start_line = 4, end_line = 3 }, range)
        end)

        it("multi-line after_text: seam before its FIRST line", function()
            -- before_text is l2 (line 2); after_text spans l3..l4.
            -- Block l2\nl3\nl4 matches lines 2..4; seam after l2 → {3, 2}.
            local range = assert(modifier.resolve(between("l2", "l3\nl4"), rec))
            assert.are.same({ start_line = 3, end_line = 2 }, range)
        end)

        it("straddling-uniqueness case: keeps the disambiguating line in the match", function()
            -- foo/bar is NOT unique; foo/bar/baz IS. Insert after bar by putting
            -- the disambiguating baz in after_text (below the seam).
            local rec2 = fr.from_content("t", "foo\nbar\nbaz\nqux\nfoo\nbar\nquux\n")
            local range = assert(modifier.resolve(between("foo\nbar", "baz"), rec2))
            -- Block foo\nbar\nbaz matches lines 1..3; seam after bar (line 2)
            -- → insert at line 3 → {3, 2}.
            assert.are.same({ start_line = 3, end_line = 2 }, range)
        end)
    end)

    describe("modifiers on a unique_text base", function()
        local rec = fr.from_content("t", "before_section\nMARKER\nafter_section\n")

        it('before { unique_text "MARKER" } → { 2, 1 }', function()
            local range = assert(modifier.resolve(before(ut("MARKER")), rec))
            assert.are.same({ start_line = 2, end_line = 1 }, range)
        end)

        it('after { unique_text "MARKER" } → { 3, 2 }', function()
            local range = assert(modifier.resolve(after_(ut("MARKER")), rec))
            assert.are.same({ start_line = 3, end_line = 2 }, range)
        end)

        it('between { before_text "MARKER", after_text "after_section" } → { 3, 2 }', function()
            local range = assert(modifier.resolve(between("MARKER", "after_section"), rec))
            assert.are.same({ start_line = 3, end_line = 2 }, range)
        end)

        it('between { before_text "before_section", after_text "MARKER" } → { 2, 1 }', function()
            local range = assert(modifier.resolve(between("before_section", "MARKER"), rec))
            assert.are.same({ start_line = 2, end_line = 1 }, range)
        end)

        it("modifier on multi-line unique_text uses the spanning range", function()
            local rec2 = fr.from_content("t", "a\nb\nFROM\nTO\nc\n")
            local range_a = assert(modifier.resolve(after_(ut("FROM\nTO")), rec2))
            -- FROM\nTO spans lines 3..4; after → { 5, 4 }
            assert.are.same({ start_line = 5, end_line = 4 }, range_a)
        end)
    end)

    describe("failure propagation from the base resolver", function()
        local rec = fr.from_content("t", "a\nb\nc\n")

        it("base anchor_not_found bubbles up with modifier-wrapped anchor in echo-back", function()
            local mod = before(lr(99, 99))
            local range, fail = modifier.resolve(mod, rec)
            assert.is_nil(range)
            assert.is.equal(schema.ERROR_REASONS.anchor_not_found, fail.reason)
            -- The echo-back is the OUTER modifier shape, not the inner base.
            assert.are.same(mod, fail.anchor)
        end)

        it("base anchor_ambiguous bubbles up with modifier-wrapped anchor in echo-back", function()
            local rec2 = fr.from_content("t", "X\nY\nX\n")
            local mod = before(ut("X"))
            local range, fail = modifier.resolve(mod, rec2)
            assert.is_nil(range)
            assert.is.equal(schema.ERROR_REASONS.anchor_ambiguous, fail.reason)
            assert.are.same(mod, fail.anchor)
            -- Candidates from the base still surface — the LLM needs them.
            assert.is_not_nil(fail.candidates)
            assert.is.equal(2, #fail.candidates)
        end)
    end)

    describe('multi-range base (occurrence: "all") is refused', function()
        it("asserts when base resolves to {ranges=...}", function()
            local rec = fr.from_content("t", "A\nB\nA\n")
            -- "all" produces a {ranges=...} result, which modifiers can't use.
            local mod = before(ut("A", "all"))
            local ok = pcall(modifier.resolve, mod, rec)
            assert.is_falsy(ok)
        end)
    end)

    describe("invariant assertions (planner-bug catches)", function()
        local rec = fr.from_content("t", "a\nb\n")

        it("rejects a non-table anchor", function()
            assert.is_falsy(pcall(modifier.resolve, "not-a-table", rec))
        end)

        it("rejects an anchor whose `by` is not a modifier kind", function()
            assert.is_falsy(pcall(modifier.resolve, { by = "line_range", start = 1, ["end"] = 1, of = lr(1, 1) }, rec))
        end)

        it("rejects modifier without `of`", function()
            assert.is_falsy(pcall(modifier.resolve, { by = "before" }, rec))
        end)

        it("rejects between without `before_text`", function()
            assert.is_falsy(pcall(modifier.resolve, { by = "between", after_text = "x" }, rec))
        end)

        it("rejects between without `after_text`", function()
            assert.is_falsy(pcall(modifier.resolve, { by = "between", before_text = "x" }, rec))
        end)

        it("rejects a non-FileRecord record", function()
            assert.is_falsy(pcall(modifier.resolve, before(lr(1, 1)), { not_a = "record" }))
        end)
    end)

    describe("zero-width position convention is consistent", function()
        -- The zero-width invariant: end_line == start_line - 1. This is
        -- what the applier maps to "pure insert, replace nothing".
        local rec = fr.from_content("t", "a\nb\nc\n")

        it("every modifier output satisfies end_line == start_line - 1", function()
            local cases = {
                before(lr(2, 2)),
                after_(lr(2, 2)),
                between("b", "c"),
                between("a", "b"),
                before(lr(1, 3)),
                after_(lr(1, 3)),
            }
            for _, anchor in ipairs(cases) do
                local r = assert(modifier.resolve(anchor, rec))
                assert.is.equal(r.start_line - 1, r.end_line)
            end
        end)
    end)
end)

describe("mcphub.native.neovim.files.apply_edit.anchors (dispatcher)", function()
    --- Reuse the helpers defined in the resolver-spec blocks above.
    local function before(base)
        return { by = "before", of = base }
    end
    local function after_(base)
        return { by = "after", of = base }
    end
    local function between(bt, at)
        return { by = "between", before_text = bt, after_text = at }
    end

    local rec = fr.from_content("t", "a\nb\nc\nd\ne\n")

    describe("routes to the correct resolver based on anchor.by", function()
        it("line_range → line_range.resolve", function()
            local range, fail = anchors.resolve(lr(2, 3), rec)
            assert.is_nil(fail)
            -- Identical shape to calling line_range directly.
            local direct = assert(line_range.resolve(lr(2, 3), rec))
            assert.are.same(direct, range)
        end)

        it("unique_text → unique_text.resolve", function()
            local rec2 = fr.from_content("t", "foo\nbar\nbaz\n")
            local range, fail = anchors.resolve(ut("bar"), rec2)
            assert.is_nil(fail)
            local direct = assert(unique_text.resolve(ut("bar"), rec2))
            assert.are.same(direct, range)
        end)

        it("before → modifier.resolve", function()
            local range, fail = anchors.resolve(before(lr(2, 2)), rec)
            assert.is_nil(fail)
            local direct = assert(modifier.resolve(before(lr(2, 2)), rec))
            assert.are.same(direct, range)
        end)

        it("after → modifier.resolve", function()
            local range, fail = anchors.resolve(after_(lr(2, 2)), rec)
            assert.is_nil(fail)
            local direct = assert(modifier.resolve(after_(lr(2, 2)), rec))
            assert.are.same(direct, range)
        end)

        it("between → modifier.resolve", function()
            local range, fail = anchors.resolve(between("b", "c"), rec)
            assert.is_nil(fail)
            local direct = assert(modifier.resolve(between("b", "c"), rec))
            assert.are.same(direct, range)
        end)
    end)

    describe("return-shape passthrough", function()
        it('passes through the multi-range shape from unique_text + "all"', function()
            local rec2 = fr.from_content("t", "A\nB\nA\n")
            local result, fail = anchors.resolve(ut("A", "all"), rec2)
            assert.is_nil(fail)
            assert.is_not_nil(result.ranges)
            assert.is.equal(2, #result.ranges)
        end)

        it("passes through anchor_ambiguous failures unchanged", function()
            local rec2 = fr.from_content("t", "X\nY\nX\n")
            local range, fail = anchors.resolve(ut("X"), rec2)
            assert.is_nil(range)
            assert.is.equal(schema.ERROR_REASONS.anchor_ambiguous, fail.reason)
            assert.is.equal(2, #fail.candidates)
        end)

        it("passes through anchor_not_found failures unchanged", function()
            local range, fail = anchors.resolve(lr(99, 99), rec)
            assert.is_nil(range)
            assert.is.equal(schema.ERROR_REASONS.anchor_not_found, fail.reason)
        end)
    end)

    describe("rejects unknown anchor kinds", function()
        it("errors on a `by` value we do not recognise", function()
            -- Schema upstream catches `unknown_kind` / `unsupported_anchor_kind`;
            -- the dispatcher's assertion is defence-in-depth for planner bugs
            -- that might bypass schema validation.
            local ok = pcall(anchors.resolve, { by = "treesitter", query = "@function" }, rec)
            assert.is_falsy(ok)
        end)

        it("errors on a non-table anchor", function()
            assert.is_falsy(pcall(anchors.resolve, "not-a-table", rec))
        end)

        it("errors on a nil anchor", function()
            assert.is_falsy(pcall(anchors.resolve, nil, rec))
        end)
    end)
end)
