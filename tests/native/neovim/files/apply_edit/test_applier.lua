--- Unit-level tests for `mcphub.native.neovim.files.apply_edit.applier.apply_plan`.
---
--- The applier's job is to take a `Plan` (already validated and located by
--- the planner), drive each file through a caller-supplied `drive_file`
--- callback in plan order, and aggregate per-file outcomes into a single
--- response. The e2e spec covers the happy path through the `accept_all`
--- synthetic driver. This spec covers every other outcome shape the
--- applier knows how to produce:
---
---   * all blocks rejected → `status='failed'`, populated `rejected[]`
---   * mixed accept/reject  → `status='partial'`, split correctly
---   * partial blocks       → `rejected[]` with `reason='partially_rejected'`
---   * mid-batch cancel     → `not_attempted` cascade for later files
---   * precondition_failed  → all blocks in `failed[]`, batch continues
---
--- All tests use synthetic drivers from `tests.native.neovim.files.apply_edit.drivers`. They do not
--- touch mcphub or EditUI. The drivers test the applier's reaction to
--- outcome shapes; mcphub's *production* of those outcomes is verified
--- separately by the real-EditUI smoke (manual).
---
--- @module "tests.native.neovim.files.apply_edit.test_applier"

local assert = require("tests.native.neovim.files.apply_edit.busted_assert")

local applier = require("mcphub.native.neovim.files.apply_edit.applier")
local drivers = require("tests.native.neovim.files.apply_edit.drivers")
local fingerprint = require("mcphub.native.neovim.files.apply_edit.fingerprint")
local planner = require("mcphub.native.neovim.files.apply_edit.planner")
local schema = require("mcphub.native.neovim.files.apply_edit.schema")

--- Write `lines` to a tempfile, load it into a buffer, and return
--- `(path, bufnr, fingerprint)`. Mirrors the e2e spec's fixture helper.
local function fixture_file(lines, suffix)
    local path = vim.fn.tempname() .. (suffix or ".txt")
    vim.fn.writefile(lines, path)
    local bufnr = vim.fn.bufadd(path)
    vim.fn.bufload(bufnr)
    local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local content = table.concat(buf_lines, "\n")
    if vim.bo[bufnr].endofline then
        content = content .. "\n"
    end
    return path, bufnr, fingerprint.compute(content)
end

local function cleanup_fixture(path, bufnr)
    if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
    end
    os.remove(path)
end

--- Build a plan synchronously, then drive it through the applier with the
--- given driver. Returns the response. Bypasses the LLM-facing seal so
--- we can pass `opts.interactive = false`.
local function run(input, driver, interactive)
    local ok, parsed_or_errors = schema.validate(input)
    assert(ok, "schema validation failed: " .. vim.inspect(parsed_or_errors))
    local plan, plan_fail = planner.plan(parsed_or_errors)
    assert(plan, "planner failed: " .. vim.inspect(plan_fail))

    local response
    applier.apply_plan(plan, { interactive = interactive == nil and false or interactive }, driver, function(r)
        response = r
    end)
    -- All synthetic drivers fire `file_cb` via `vim.schedule`; the applier
    -- also schedules between files. 200ms is generous for a typical 1-3
    -- file batch but still tight enough to scream on regressions.
    local ok_wait = vim.wait(200, function()
        return response ~= nil
    end, 1)
    assert(ok_wait, "apply_plan did not complete within 200ms")
    return response
end

describe("apply_plan with synthetic drivers", function()
    describe("reject_all", function()
        it("returns status=failed with every block in rejected[]", function()
            local path, bufnr, fp = fixture_file({ "one", "two", "three" }, "_reject.txt")
            local response = run({
                ops = {
                    {
                        kind = "replace_range",
                        path = path,
                        baseline_fingerprint = fp,
                        anchor = { by = "line_range", start = 2, ["end"] = 2 },
                        content = "TWO-NEW",
                        indent = "match_anchor",
                    },
                    {
                        kind = "delete_range",
                        path = path,
                        baseline_fingerprint = fp,
                        anchor = { by = "line_range", start = 1, ["end"] = 1 },
                    },
                },
            }, drivers.reject_all)

            assert.is.equal("failed", response.status)
            assert.is.equal(0, #response.applied)
            assert.is.equal(2, #response.rejected)
            assert.is.equal(0, #response.failed)

            -- Every rejected entry carries reason='rejected', the op_index, and
            -- the resolved range. Order matches block order in the request.
            for _, r in ipairs(response.rejected) do
                assert.is.equal("rejected", r.reason)
                assert(r.op_index ~= nil, "rejected entry missing op_index")
                assert(r.range ~= nil, "rejected entry missing range")
            end

            -- The file on disk is unchanged.
            local on_disk = vim.fn.readfile(path)
            assert.is.equal(3, #on_disk)
            assert.is.equal("one", on_disk[1])
            assert.is.equal("two", on_disk[2])
            assert.is.equal("three", on_disk[3])
            assert.is.equal(false, vim.bo[bufnr].modified)

            cleanup_fixture(path, bufnr)
        end)

        it("reports a single-file `files[]` entry with completed status", function()
            local path, bufnr, fp = fixture_file({ "a", "b" }, "_reject2.txt")
            local response = run({
                ops = {
                    {
                        kind = "replace_range",
                        path = path,
                        baseline_fingerprint = fp,
                        anchor = { by = "line_range", start = 1, ["end"] = 1 },
                        content = "A-NEW",
                        indent = "match_anchor",
                    },
                },
            }, drivers.reject_all)

            assert.is.equal(1, #response.files)
            local f = response.files[1]
            assert.is.equal(path, f.path)
            assert.is.equal("completed", f.status)
            -- ui_summary echoes the reject_all driver's message.
            assert(
                f.ui_summary:find("rejected 1 block"),
                "expected ui_summary to mention rejection, got: " .. tostring(f.ui_summary)
            )

            cleanup_fixture(path, bufnr)
        end)
    end)

    describe("make_selective (mixed accept/reject)", function()
        it("returns status=partial with the right applied/rejected split", function()
            local path, bufnr, fp = fixture_file({ "one", "two", "three", "four" }, "_mixed.txt")
            -- Op 1: replace line 1 (accept).
            -- Op 2: replace line 3 (reject).
            -- Op 3: replace line 4 (accept).
            local response = run({
                ops = {
                    {
                        kind = "replace_range",
                        path = path,
                        baseline_fingerprint = fp,
                        anchor = { by = "line_range", start = 1, ["end"] = 1 },
                        content = "ONE-NEW",
                        indent = "match_anchor",
                    },
                    {
                        kind = "replace_range",
                        path = path,
                        baseline_fingerprint = fp,
                        anchor = { by = "line_range", start = 3, ["end"] = 3 },
                        content = "THREE-NEW",
                        indent = "match_anchor",
                    },
                    {
                        kind = "replace_range",
                        path = path,
                        baseline_fingerprint = fp,
                        anchor = { by = "line_range", start = 4, ["end"] = 4 },
                        content = "FOUR-NEW",
                        indent = "match_anchor",
                    },
                },
            }, drivers.make_selective({ [1] = "accept", [2] = "reject", [3] = "accept" }))

            assert.is.equal("partial", response.status)
            assert.is.equal(2, #response.applied)
            assert.is.equal(1, #response.rejected)
            assert.is.equal(0, #response.failed)

            -- applied[] carries op 1 and op 3 in input order; rejected[] has op 2.
            assert.is.equal(1, response.applied[1].op_index)
            assert.is.equal(3, response.applied[2].op_index)
            assert.is.equal(2, response.rejected[1].op_index)
            assert.is.equal("rejected", response.rejected[1].reason)

            -- The on-disk file shows accepted edits only.
            local on_disk = vim.fn.readfile(path)
            assert.is.equal("ONE-NEW", on_disk[1])
            assert.is.equal("two", on_disk[2])
            assert.is.equal("three", on_disk[3]) -- op 2 rejected, line unchanged
            assert.is.equal("FOUR-NEW", on_disk[4])

            cleanup_fixture(path, bufnr)
        end)

        it("returns status=applied when every block accepts via the selective driver", function()
            -- Sanity: the selective driver with all-accept decisions should
            -- behave identically to accept_all. Ensures the driver itself
            -- isn't accidentally rejecting unknown blocks.
            local path, bufnr, fp = fixture_file({ "a", "b" }, "_all_accept.txt")
            local response = run({
                ops = {
                    {
                        kind = "replace_range",
                        path = path,
                        baseline_fingerprint = fp,
                        anchor = { by = "line_range", start = 1, ["end"] = 1 },
                        content = "A-NEW",
                        indent = "match_anchor",
                    },
                    {
                        kind = "replace_range",
                        path = path,
                        baseline_fingerprint = fp,
                        anchor = { by = "line_range", start = 2, ["end"] = 2 },
                        content = "B-NEW",
                        indent = "match_anchor",
                    },
                },
            }, drivers.make_selective({ [1] = "accept", [2] = "accept" }))

            assert.is.equal("applied", response.status)
            assert.is.equal(2, #response.applied)
            assert.is.equal(0, #response.rejected)

            cleanup_fixture(path, bufnr)
        end)

        it("returns status=failed when every block rejects via the selective driver", function()
            -- Symmetric sanity check for the reject-all-via-selective case.
            local path, bufnr, fp = fixture_file({ "a", "b" }, "_all_reject.txt")
            local response = run({
                ops = {
                    {
                        kind = "replace_range",
                        path = path,
                        baseline_fingerprint = fp,
                        anchor = { by = "line_range", start = 1, ["end"] = 1 },
                        content = "A-NEW",
                        indent = "match_anchor",
                    },
                    {
                        kind = "replace_range",
                        path = path,
                        baseline_fingerprint = fp,
                        anchor = { by = "line_range", start = 2, ["end"] = 2 },
                        content = "B-NEW",
                        indent = "match_anchor",
                    },
                },
            }, drivers.make_selective({ [1] = "reject", [2] = "reject" }))

            assert.is.equal("failed", response.status)
            assert.is.equal(0, #response.applied)
            assert.is.equal(2, #response.rejected)

            cleanup_fixture(path, bufnr)
        end)

        it("surfaces partial blocks as rejected[] with reason=partially_rejected", function()
            -- A block reported `'partial'` (real EditUI emits this when one
            -- block produces multiple hunks and the user accepts some but
            -- not all) surfaces in `rejected[]` with a distinct reason.
            local path, bufnr, fp = fixture_file({ "a", "b", "c" }, "_partial.txt")
            local response = run({
                ops = {
                    {
                        kind = "replace_range",
                        path = path,
                        baseline_fingerprint = fp,
                        anchor = { by = "line_range", start = 2, ["end"] = 2 },
                        content = "B-NEW",
                        indent = "match_anchor",
                    },
                },
            }, drivers.make_selective({ [1] = "partial" }))

            -- A 'partial' block surfaces as failed (no applied to lift it
            -- to 'partial' at the response level).
            assert.is.equal("failed", response.status)
            assert.is.equal(0, #response.applied)
            assert.is.equal(1, #response.rejected)
            assert.is.equal("partially_rejected", response.rejected[1].reason)

            cleanup_fixture(path, bufnr)
        end)

        it("lifts status to partial when partial mixes with accepted", function()
            -- Same shape but one accepted block alongside the partial.
            -- Now the response status should be 'partial', not 'failed'.
            local path, bufnr, fp = fixture_file({ "a", "b", "c" }, "_partial_mix.txt")
            local response = run({
                ops = {
                    {
                        kind = "replace_range",
                        path = path,
                        baseline_fingerprint = fp,
                        anchor = { by = "line_range", start = 1, ["end"] = 1 },
                        content = "A-NEW",
                        indent = "match_anchor",
                    },
                    {
                        kind = "replace_range",
                        path = path,
                        baseline_fingerprint = fp,
                        anchor = { by = "line_range", start = 2, ["end"] = 2 },
                        content = "B-NEW",
                        indent = "match_anchor",
                    },
                },
            }, drivers.make_selective({ [1] = "accept", [2] = "partial" }))

            assert.is.equal("partial", response.status)
            assert.is.equal(1, #response.applied)
            assert.is.equal(1, #response.rejected)
            assert.is.equal("partially_rejected", response.rejected[1].reason)

            cleanup_fixture(path, bufnr)
        end)
    end)

    describe("cancel_at (mid-batch cancel)", function()
        it("emits not_attempted failures for files after the cancel point", function()
            -- Two files; cancel at the first. The second file should not
            -- be driven; its op surfaces as a `not_attempted` failure.
            local path_a, buf_a, fp_a = fixture_file({ "A1", "A2" }, "_cancel_a.txt")
            local path_b, buf_b, fp_b = fixture_file({ "B1", "B2" }, "_cancel_b.txt")

            local response = run({
                ops = {
                    {
                        kind = "replace_range",
                        path = path_a,
                        baseline_fingerprint = fp_a,
                        anchor = { by = "line_range", start = 1, ["end"] = 1 },
                        content = "A1-NEW",
                        indent = "match_anchor",
                    },
                    {
                        kind = "replace_range",
                        path = path_b,
                        baseline_fingerprint = fp_b,
                        anchor = { by = "line_range", start = 1, ["end"] = 1 },
                        content = "B1-NEW",
                        indent = "match_anchor",
                    },
                },
            }, drivers.cancel_at(path_a))

            -- The cancel of file A surfaces its op as rejected (reason=cancelled),
            -- and file B's op surfaces as failed (reason=not_attempted).
            assert.is.equal("cancelled", response.status)
            assert.is.equal(0, #response.applied)
            assert.is.equal(1, #response.rejected)
            assert.is.equal(1, #response.failed)

            assert.is.equal("cancelled", response.rejected[1].reason)
            assert.is.equal(path_a, response.rejected[1].path)
            assert.is.equal("not_attempted", response.failed[1].reason)
            assert.is.equal(path_b, response.failed[1].path)

            -- Neither file changed on disk: A was cancelled, B was never driven.
            local on_disk_a = vim.fn.readfile(path_a)
            assert.is.equal("A1", on_disk_a[1])
            local on_disk_b = vim.fn.readfile(path_b)
            assert.is.equal("B1", on_disk_b[1])

            cleanup_fixture(path_a, buf_a)
            cleanup_fixture(path_b, buf_b)
        end)

        it("preserves accepted earlier files when cancel happens mid-batch", function()
            -- Three files. Cancel at file B; expect file A's edit to land,
            -- file B's op as rejected (cancelled), file C's op as failed.
            -- This tests the `'partial'` response status path on a cancel.
            local path_a, buf_a, fp_a = fixture_file({ "A1" }, "_p_a.txt")
            local path_b, buf_b, fp_b = fixture_file({ "B1" }, "_p_b.txt")
            local path_c, buf_c, fp_c = fixture_file({ "C1" }, "_p_c.txt")

            local response = run({
                ops = {
                    {
                        kind = "replace_range",
                        path = path_a,
                        baseline_fingerprint = fp_a,
                        anchor = { by = "line_range", start = 1, ["end"] = 1 },
                        content = "A1-NEW",
                        indent = "match_anchor",
                    },
                    {
                        kind = "replace_range",
                        path = path_b,
                        baseline_fingerprint = fp_b,
                        anchor = { by = "line_range", start = 1, ["end"] = 1 },
                        content = "B1-NEW",
                        indent = "match_anchor",
                    },
                    {
                        kind = "replace_range",
                        path = path_c,
                        baseline_fingerprint = fp_c,
                        anchor = { by = "line_range", start = 1, ["end"] = 1 },
                        content = "C1-NEW",
                        indent = "match_anchor",
                    },
                },
            }, drivers.cancel_at(path_b))

            assert.is.equal("partial", response.status)
            assert.is.equal(1, #response.applied)
            assert.is.equal(1, #response.rejected)
            assert.is.equal(1, #response.failed)

            assert.is.equal(path_a, response.applied[1].path)
            assert.is.equal(path_b, response.rejected[1].path)
            assert.is.equal(path_c, response.failed[1].path)
            assert.is.equal("not_attempted", response.failed[1].reason)

            -- File A's edit landed; B and C are untouched on disk.
            assert.is.equal("A1-NEW", vim.fn.readfile(path_a)[1])
            assert.is.equal("B1", vim.fn.readfile(path_b)[1])
            assert.is.equal("C1", vim.fn.readfile(path_c)[1])

            cleanup_fixture(path_a, buf_a)
            cleanup_fixture(path_b, buf_b)
            cleanup_fixture(path_c, buf_c)
        end)
    end)

    describe("files[].diagnostics forwarding", function()
        it("forwards driver-supplied diagnostics into files[].diagnostics", function()
            -- A custom driver that returns a fixed Diagnostic[] array. The
            -- applier should forward verbatim — it never introspects the
            -- shape.
            local path, bufnr, fp = fixture_file({ "x" }, "_diag_fwd.txt")
            local driver = function(_request, file_cb)
                vim.schedule(function()
                    file_cb({
                        status = "completed",
                        per_block = { op1_r1 = "accepted" },
                        diagnostics = {
                            {
                                severity = "error",
                                line = 1,
                                end_line = 1,
                                col = 1,
                                end_col = 4,
                                message = "mock",
                                source = "test",
                                code = "mocked",
                            },
                            {
                                severity = "warn",
                                line = 1,
                                end_line = 1,
                                col = 1,
                                end_col = 2,
                                message = "also mock",
                            },
                        },
                    })
                end)
            end

            local response = run({
                ops = {
                    {
                        kind = "replace_range",
                        path = path,
                        baseline_fingerprint = fp,
                        anchor = { by = "line_range", start = 1, ["end"] = 1 },
                        content = "X",
                        indent = "match_anchor",
                    },
                },
            }, driver)

            assert.is.equal(1, #response.files)
            local diags = response.files[1].diagnostics
            assert(diags ~= nil, "expected diagnostics field on files[1]")
            assert.is.equal(2, #diags)
            assert.is.equal("error", diags[1].severity)
            assert.is.equal("mock", diags[1].message)
            assert.is.equal("warn", diags[2].severity)

            cleanup_fixture(path, bufnr)
        end)

        it("defaults diagnostics to an empty array when the driver omits it", function()
            -- accept_all does not emit diagnostics. The applier must still
            -- produce an empty array so the wire shape is `[]` not `null`.
            local path, bufnr, fp = fixture_file({ "a" }, "_diag_empty.txt")
            local response = run({
                ops = {
                    {
                        kind = "replace_range",
                        path = path,
                        baseline_fingerprint = fp,
                        anchor = { by = "line_range", start = 1, ["end"] = 1 },
                        content = "A",
                        indent = "match_anchor",
                    },
                },
            }, drivers.accept_all)

            assert.is.equal(1, #response.files)
            local diags = response.files[1].diagnostics
            assert(diags ~= nil, "expected diagnostics field to be an empty array, got nil")
            assert.is.equal(0, #diags)

            cleanup_fixture(path, bufnr)
        end)
    end)

    describe("precondition_failed", function()
        it("converts driver-supplied failures into the response failed[]", function()
            -- Custom driver returning precondition_failed. The applier should
            -- forward each failure into the response's failed[] and continue
            -- with subsequent files.
            local path, bufnr, fp = fixture_file({ "a", "b" }, "_precond.txt")
            local driver = function(_request, file_cb)
                vim.schedule(function()
                    file_cb({
                        status = "precondition_failed",
                        failures = {
                            {
                                op_index = 1,
                                reason = "range_conflict",
                                message = "synthetic test failure",
                                range = { start_line = 1, end_line = 1 },
                            },
                        },
                        per_block = {},
                    })
                end)
            end

            local response = run({
                ops = {
                    {
                        kind = "replace_range",
                        path = path,
                        baseline_fingerprint = fp,
                        anchor = { by = "line_range", start = 1, ["end"] = 1 },
                        content = "A-NEW",
                        indent = "match_anchor",
                    },
                },
            }, driver)

            assert.is.equal("failed", response.status)
            assert.is.equal(0, #response.applied)
            assert.is.equal(0, #response.rejected)
            assert.is.equal(1, #response.failed)

            local f = response.failed[1]
            assert.is.equal("range_conflict", f.reason)
            assert.is.equal("synthetic test failure", f.message)
            -- The applier filled in `path` from the request since the driver
            -- did not supply one.
            assert.is.equal(path, f.path)

            -- File on disk is untouched.
            assert.is.equal("a", vim.fn.readfile(path)[1])

            cleanup_fixture(path, bufnr)
        end)

        it("continues with subsequent files after a per-file precondition_failed", function()
            -- Two files. File A's driver returns precondition_failed; file B
            -- gets accept_all. The batch should continue past file A.
            local path_a, buf_a, fp_a = fixture_file({ "A1" }, "_pre_a.txt")
            local path_b, buf_b, fp_b = fixture_file({ "B1" }, "_pre_b.txt")

            local driver = function(request, file_cb)
                if request.file_path == path_a then
                    vim.schedule(function()
                        file_cb({
                            status = "precondition_failed",
                            failures = {
                                {
                                    op_index = 1,
                                    reason = "range_conflict",
                                    message = "refused A",
                                },
                            },
                            per_block = {},
                        })
                    end)
                else
                    return drivers.accept_all(request, file_cb)
                end
            end

            local response = run({
                ops = {
                    {
                        kind = "replace_range",
                        path = path_a,
                        baseline_fingerprint = fp_a,
                        anchor = { by = "line_range", start = 1, ["end"] = 1 },
                        content = "A1-NEW",
                        indent = "match_anchor",
                    },
                    {
                        kind = "replace_range",
                        path = path_b,
                        baseline_fingerprint = fp_b,
                        anchor = { by = "line_range", start = 1, ["end"] = 1 },
                        content = "B1-NEW",
                        indent = "match_anchor",
                    },
                },
            }, driver)

            -- Op 1 (file A) failed; op 2 (file B) applied.
            assert.is.equal("partial", response.status)
            assert.is.equal(1, #response.applied)
            assert.is.equal(0, #response.rejected)
            assert.is.equal(1, #response.failed)

            assert.is.equal(2, response.applied[1].op_index)
            assert.is.equal(path_b, response.applied[1].path)
            assert.is.equal(1, response.failed[1].op_index)
            assert.is.equal(path_a, response.failed[1].path)

            -- File A untouched, file B updated.
            assert.is.equal("A1", vim.fn.readfile(path_a)[1])
            assert.is.equal("B1-NEW", vim.fn.readfile(path_b)[1])

            cleanup_fixture(path_a, buf_a)
            cleanup_fixture(path_b, buf_b)
        end)
    end)
end)
