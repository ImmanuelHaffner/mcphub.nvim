--- End-to-end tests for `mcphub.native.neovim.files.apply_edit.engine.apply(input, drive_file, on_complete)`.
---
--- Exercises the full pipeline: schema → planner → applier → drive_file. We
--- use the synthetic `tests.native.neovim.files.apply_edit.drivers.accept_all` driver, which mirrors
--- the headless `interactive = false` behaviour of mcphub's `EditUI` without
--- the UI dependency. Reject-path tests are deferred until we have a
--- synthetic reject driver.
---
--- Fingerprints are real (no bypass) — these tests construct the fingerprint
--- from the file content they wrote, the same way the LLM constructs it
--- from a `neovim__read_with_fingerprint` response. That makes them genuine
--- end-to-end smoke tests of the production seal `mcphub.native.neovim.files.apply_edit.engine.apply`.
---
--- @module "tests.native.neovim.files.apply_edit.test_e2e"

local assert = require("tests.native.neovim.files.apply_edit.busted_assert")

local drivers = require("tests.native.neovim.files.apply_edit.drivers")
local edit = require("mcphub.native.neovim.files.apply_edit.engine")
local fingerprint = require("mcphub.native.neovim.files.apply_edit.fingerprint")

--- Wait for the async `on_complete` callback. Returns the response.
---
--- The accept_all driver is synchronous-with-`vim.schedule` (no I/O beyond
--- `:write`), so completion should occur in sub-millisecond wall time per
--- file. 100ms is tight enough to scream if a regression accidentally pulls
--- in an async waiter (e.g. EditUI's 500ms-default diagnostic settle), but
--- still ~1000× the realistic budget.
local function await_apply(input)
    local response
    edit.apply(input, drivers.accept_all, function(r)
        response = r
    end)
    local ok = vim.wait(100, function()
        return response ~= nil
    end, 1)
    assert(ok, "edit.apply did not complete within 100ms")
    return response
end

--- Like `await_apply`, but lets the caller pick the synthetic driver (e.g.
--- `accept_all_ascending` to mirror mcphub's apply traversal).
local function await_apply_with(input, drive_file)
    local response
    edit.apply(input, drive_file, function(r)
        response = r
    end)
    local ok = vim.wait(100, function()
        return response ~= nil
    end, 1)
    assert(ok, "edit.apply did not complete within 100ms")
    return response
end

--- Write `lines` to a tempfile, load it into a buffer (mirrors the
--- buffer-first read path used by `read_with_fingerprint`), and return
--- `(path, bufnr, fingerprint)`.
local function fixture_file(lines, suffix)
    local path = vim.fn.tempname() .. (suffix or ".txt")
    vim.fn.writefile(lines, path)
    local bufnr = vim.fn.bufadd(path)
    vim.fn.bufload(bufnr)
    -- Match the engine's content normalisation:
    -- nvim_buf_get_lines joined by '\n', plus trailing '\n' iff endofline.
    local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local content = table.concat(buf_lines, "\n")
    if vim.bo[bufnr].endofline then
        content = content .. "\n"
    end
    return path, bufnr, fingerprint.compute(content)
end

--- Tear down a fixture: delete the buffer and remove the file. Safe under
--- the test runner's per-spec isolation; this prevents stale buffers from
--- the previous spec affecting the next.
local function cleanup_fixture(path, bufnr)
    if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
    end
    os.remove(path)
end

describe("mcphub.native.neovim.files.apply_edit.engine.apply end-to-end (accept_all driver)", function()
    it("applies a single replace_range and writes to disk", function()
        local path, bufnr, fp = fixture_file({ "alpha", "beta", "gamma" })
        local response = await_apply({
            ops = {
                {
                    kind = "replace_range",
                    path = path,
                    baseline_fingerprint = fp,
                    anchor = { by = "line_range", start = 2, ["end"] = 2 },
                    content = "BETA",
                    indent = "match_anchor",
                },
            },
        })
        assert(response.status == "applied", "expected status=applied, got " .. tostring(response.status))
        assert(#response.applied == 1, "expected 1 applied entry")
        assert(#response.rejected == 0, "expected 0 rejected")
        assert(#response.failed == 0, "expected 0 failed")

        local on_disk = vim.fn.readfile(path)
        assert.is.equal("alpha", on_disk[1])
        assert.is.equal("BETA", on_disk[2])
        assert.is.equal("gamma", on_disk[3])

        cleanup_fixture(path, bufnr)
    end)

    it("applies replace + insert + delete in one batch", function()
        local path, bufnr, fp = fixture_file({ "one", "two", "three", "four" })
        local response = await_apply({
            ops = {
                {
                    kind = "replace_range",
                    path = path,
                    baseline_fingerprint = fp,
                    anchor = { by = "line_range", start = 2, ["end"] = 2 },
                    content = "TWO-a\nTWO-b",
                    indent = "match_anchor",
                },
                {
                    kind = "insert",
                    path = path,
                    baseline_fingerprint = fp,
                    anchor = {
                        by = "before",
                        of = { by = "line_range", start = 4, ["end"] = 4 },
                    },
                    content = "INSERTED",
                    indent = "match_anchor",
                },
                {
                    kind = "delete_range",
                    path = path,
                    baseline_fingerprint = fp,
                    anchor = { by = "line_range", start = 1, ["end"] = 1 },
                },
            },
        })
        assert.is.equal("applied", response.status)
        assert.is.equal(3, #response.applied)

        local on_disk = vim.fn.readfile(path)
        -- Expected after all three: ["TWO-a", "TWO-b", "three", "INSERTED", "four"]
        assert.is.equal("TWO-a", on_disk[1])
        assert.is.equal("TWO-b", on_disk[2])
        assert.is.equal("three", on_disk[3])
        assert.is.equal("INSERTED", on_disk[4])
        assert.is.equal("four", on_disk[5])
        assert.is.equal(5, #on_disk)

        cleanup_fixture(path, bufnr)
    end)

    it("applies a between insert, placing content at the seam (straddling uniqueness)", function()
        -- foo/bar is not unique; foo/bar/baz is. Insert after the FIRST bar
        -- by naming before_text="foo\nbar" and after_text="baz" (the
        -- disambiguating line sits below the seam).
        local path, bufnr, fp = fixture_file({
            "foo",
            "bar",
            "baz",
            "qux",
            "foo",
            "bar",
            "quux",
        })
        local response = await_apply({
            ops = {
                {
                    kind = "insert",
                    path = path,
                    baseline_fingerprint = fp,
                    anchor = {
                        by = "between",
                        before_text = "foo\nbar",
                        after_text = "baz",
                    },
                    content = "INSERTED",
                    indent = "preserve",
                },
            },
        })
        assert.is.equal("applied", response.status)
        assert.is.equal(1, #response.applied)

        local on_disk = vim.fn.readfile(path)
        -- INSERTED lands between bar (line 2) and baz (line 3).
        assert.is.equal("foo", on_disk[1])
        assert.is.equal("bar", on_disk[2])
        assert.is.equal("INSERTED", on_disk[3])
        assert.is.equal("baz", on_disk[4])
        assert.is.equal("qux", on_disk[5])
        assert.is.equal("foo", on_disk[6])
        assert.is.equal("bar", on_disk[7])
        assert.is.equal("quux", on_disk[8])
        assert.is.equal(8, #on_disk)

        cleanup_fixture(path, bufnr)
    end)

    it("returns failed[] with schema_invalid for malformed input", function()
        local response = await_apply({
            ops = {
                -- Missing baseline_fingerprint → schema rejects.
                {
                    kind = "replace_range",
                    path = "/tmp/nonexistent",
                    anchor = { by = "line_range", start = 1, ["end"] = 1 },
                    content = "x",
                    indent = "match_anchor",
                },
            },
        })
        assert.is.equal("failed", response.status)
        assert(#response.failed >= 1, "expected at least one failed entry")
        local entry = response.failed[1]
        assert.is.equal("schema_invalid", entry.reason)
    end)

    it("returns failed[] with stale_fingerprint when the file mutated", function()
        local path, bufnr, fp = fixture_file({ "live", "content" })
        -- Mutate the buffer behind the LLM's back.
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "mutated", "content" })

        local response = await_apply({
            ops = {
                {
                    kind = "replace_range",
                    path = path,
                    baseline_fingerprint = fp,
                    anchor = { by = "line_range", start = 1, ["end"] = 1 },
                    content = "never_applied",
                    indent = "match_anchor",
                },
            },
        })
        assert.is.equal("failed", response.status)
        assert.is.equal(1, #response.failed)
        local entry = response.failed[1]
        assert.is.equal("stale_fingerprint", entry.reason)
        assert(entry.live_fingerprint ~= nil, "stale failure should carry live_fingerprint")
        assert(entry.live_content ~= nil, "stale failure should carry live_content")

        cleanup_fixture(path, bufnr)
    end)

    it("sequences ops across two files, both applied", function()
        local path_a, buf_a, fp_a = fixture_file({ "A1", "A2" }, "_a.txt")
        local path_b, buf_b, fp_b = fixture_file({ "B1", "B2" }, "_b.txt")
        local response = await_apply({
            ops = {
                {
                    kind = "replace_range",
                    path = path_a,
                    baseline_fingerprint = fp_a,
                    anchor = { by = "line_range", start = 1, ["end"] = 1 },
                    content = "A1-edited",
                    indent = "match_anchor",
                },
                {
                    kind = "replace_range",
                    path = path_b,
                    baseline_fingerprint = fp_b,
                    anchor = { by = "line_range", start = 2, ["end"] = 2 },
                    content = "B2-edited",
                    indent = "match_anchor",
                },
            },
        })
        assert.is.equal("applied", response.status)
        assert.is.equal(2, #response.applied)

        local on_disk_a = vim.fn.readfile(path_a)
        assert.is.equal("A1-edited", on_disk_a[1])
        assert.is.equal("A2", on_disk_a[2])
        local on_disk_b = vim.fn.readfile(path_b)
        assert.is.equal("B1", on_disk_b[1])
        assert.is.equal("B2-edited", on_disk_b[2])

        cleanup_fixture(path_a, buf_a)
        cleanup_fixture(path_b, buf_b)
    end)
end)

--- ## Line-drift regression
---
--- These pin the guarantee that a batch of `replace_range` / `insert` /
--- `delete_range` ops within one file does NOT drift later ops when an
--- earlier op changes the line count. The planner resolves every anchor
--- against one pre-edit snapshot; the apply phase must compensate for the
--- net line delta so each op lands at its intended (pre-edit) location.
---
--- Two things are pinned:
---
---   1. The on-disk result is correct under the bottom-up `accept_all`
---      driver (no offset bookkeeping needed by construction).
---   2. The on-disk result is *byte-identical* under the
---      `accept_all_ascending` driver, which mirrors mcphub's real
---      `EditUI:_apply_all_changes` (ascending sort + running
---      `base_line_offset`). This is the production traversal, so this
---      assertion is what actually guards against a mcphub-side or
---      block-construction regression reintroducing drift.
describe("mcphub.native.neovim.files.apply_edit.engine.apply line-drift regression", function()
    -- The canonical scenario from the design discussion: an early op grows
    -- the file (net +N lines), and a second op targets a line further down.
    -- If positions drifted, the second op would land in the wrong place.
    local function net_positive_input(path, fp)
        return {
            ops = {
                -- Replace 1 line (line 2) with 4 lines: net +3.
                {
                    kind = "replace_range",
                    path = path,
                    baseline_fingerprint = fp,
                    anchor = { by = "line_range", start = 2, ["end"] = 2 },
                    content = "two-a\ntwo-b\ntwo-c\ntwo-d",
                    indent = "match_anchor",
                },
                -- Target a line well below the growth point. Pre-edit line 6.
                {
                    kind = "replace_range",
                    path = path,
                    baseline_fingerprint = fp,
                    anchor = { by = "line_range", start = 6, ["end"] = 6 },
                    content = "SIX",
                    indent = "match_anchor",
                },
            },
        }
    end

    -- The mirror scenario: an early op shrinks the file (net -N), and a
    -- later op must still land correctly despite the contraction above it.
    local function net_negative_input(path, fp)
        return {
            ops = {
                -- Delete lines 2-4: net -3.
                {
                    kind = "delete_range",
                    path = path,
                    baseline_fingerprint = fp,
                    anchor = { by = "line_range", start = 2, ["end"] = 4 },
                },
                -- Target pre-edit line 6, below the deletion.
                {
                    kind = "replace_range",
                    path = path,
                    baseline_fingerprint = fp,
                    anchor = { by = "line_range", start = 6, ["end"] = 6 },
                    content = "SIX",
                    indent = "match_anchor",
                },
            },
        }
    end

    it("net-positive earlier op does not drift a later op (bottom-up driver)", function()
        local path, bufnr, fp = fixture_file({ "one", "two", "three", "four", "five", "six", "seven" })
        local response = await_apply_with(net_positive_input(path, fp), drivers.accept_all)
        assert.is.equal("applied", response.status)
        assert.is.equal(2, #response.applied)

        -- Expected: line 2 expanded to four lines, original line 6 ("six")
        -- replaced by "SIX", everything else intact.
        local on_disk = vim.fn.readfile(path)
        assert.is.equal("one", on_disk[1])
        assert.is.equal("two-a", on_disk[2])
        assert.is.equal("two-b", on_disk[3])
        assert.is.equal("two-c", on_disk[4])
        assert.is.equal("two-d", on_disk[5])
        assert.is.equal("three", on_disk[6])
        assert.is.equal("four", on_disk[7])
        assert.is.equal("five", on_disk[8])
        assert.is.equal("SIX", on_disk[9]) -- the load-bearing line
        assert.is.equal("seven", on_disk[10])
        assert.is.equal(10, #on_disk)

        cleanup_fixture(path, bufnr)
    end)

    it("net-negative earlier op does not drift a later op (bottom-up driver)", function()
        local path, bufnr, fp = fixture_file({ "one", "two", "three", "four", "five", "six", "seven" })
        local response = await_apply_with(net_negative_input(path, fp), drivers.accept_all)
        assert.is.equal("applied", response.status)
        assert.is.equal(2, #response.applied)

        -- Expected: lines 2-4 gone, original line 6 ("six") replaced by "SIX".
        local on_disk = vim.fn.readfile(path)
        assert.is.equal("one", on_disk[1])
        assert.is.equal("five", on_disk[2])
        assert.is.equal("SIX", on_disk[3]) -- the load-bearing line
        assert.is.equal("seven", on_disk[4])
        assert.is.equal(4, #on_disk)

        cleanup_fixture(path, bufnr)
    end)

    -- The production guard: mcphub applies ascending with a running offset.
    -- Prove that traversal lands byte-identical to the bottom-up reference
    -- for both net-positive and net-negative batches. If mcphub's offset
    -- bookkeeping (or our block construction feeding it) ever regresses,
    -- this fails while the bottom-up tests above still pass — isolating the
    -- fault to the apply traversal.
    it("mcphub-style ascending+offset traversal agrees with bottom-up (net +)", function()
        local lines = { "one", "two", "three", "four", "five", "six", "seven" }

        local p1, b1, fp1 = fixture_file(lines, "_botup.txt")
        await_apply_with(net_positive_input(p1, fp1), drivers.accept_all)
        local botup = vim.fn.readfile(p1)

        local p2, b2, fp2 = fixture_file(lines, "_asc.txt")
        await_apply_with(net_positive_input(p2, fp2), drivers.accept_all_ascending)
        local ascending = vim.fn.readfile(p2)

        assert.is.equal(table.concat(botup, "\n"), table.concat(ascending, "\n"))

        cleanup_fixture(p1, b1)
        cleanup_fixture(p2, b2)
    end)

    it("mcphub-style ascending+offset traversal agrees with bottom-up (net -)", function()
        local lines = { "one", "two", "three", "four", "five", "six", "seven" }

        local p1, b1, fp1 = fixture_file(lines, "_botup.txt")
        await_apply_with(net_negative_input(p1, fp1), drivers.accept_all)
        local botup = vim.fn.readfile(p1)

        local p2, b2, fp2 = fixture_file(lines, "_asc.txt")
        await_apply_with(net_negative_input(p2, fp2), drivers.accept_all_ascending)
        local ascending = vim.fn.readfile(p2)

        assert.is.equal(table.concat(botup, "\n"), table.concat(ascending, "\n"))

        cleanup_fixture(p1, b1)
        cleanup_fixture(p2, b2)
    end)

    -- An insert (net +1) above a later replace, mixing op kinds. The insert
    -- is a zero-width position { N, N-1 } pre-widen; this confirms the
    -- mixed-kind batch composes correctly under the production traversal.
    it("insert above a later replace does not drift it (ascending+offset)", function()
        local path, bufnr, fp = fixture_file({ "one", "two", "three", "four", "five" }, "_mix.txt")
        local response = await_apply_with({
            ops = {
                {
                    kind = "insert",
                    path = path,
                    baseline_fingerprint = fp,
                    anchor = {
                        by = "before",
                        of = { by = "line_range", start = 2, ["end"] = 2 },
                    },
                    content = "inserted",
                    indent = "match_anchor",
                },
                {
                    kind = "replace_range",
                    path = path,
                    baseline_fingerprint = fp,
                    anchor = { by = "line_range", start = 4, ["end"] = 4 },
                    content = "FOUR",
                    indent = "match_anchor",
                },
            },
        }, drivers.accept_all_ascending)
        assert.is.equal("applied", response.status)
        assert.is.equal(2, #response.applied)

        -- Expected: 'inserted' before line 2, original line 4 ('four') → 'FOUR'.
        local on_disk = vim.fn.readfile(path)
        assert.is.equal("one", on_disk[1])
        assert.is.equal("inserted", on_disk[2])
        assert.is.equal("two", on_disk[3])
        assert.is.equal("three", on_disk[4])
        assert.is.equal("FOUR", on_disk[5]) -- the load-bearing line
        assert.is.equal("five", on_disk[6])
        assert.is.equal(6, #on_disk)

        cleanup_fixture(path, bufnr)
    end)
end)
