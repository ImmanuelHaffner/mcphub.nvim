--- Tests for mcphub.native.neovim.files.apply_edit.wire — the LLM-facing response shape.

local assert = require("tests.native.neovim.files.apply_edit.busted_assert")

local wire = require("mcphub.native.neovim.files.apply_edit.wire")

local HOME_FILE = vim.fn.expand("~") .. "/proj/a.lua"

describe("mcphub.native.neovim.files.apply_edit.wire", function()
    describe("lines", function()
        it("renders single lines, spans and insertion positions", function()
            assert.is.equal("12", wire.lines({ start_line = 12, end_line = 12 }))
            assert.is.equal("12-14", wire.lines({ start_line = 12, end_line = 14 }))
            assert.is.equal("before 12", wire.lines({ start_line = 12, end_line = 11 }))
            assert.is_nil(wire.lines(nil))
        end)
    end)

    describe("planned", function()
        it("numbers a dry run's preview and marks a skipped middle", function()
            local out = wire.format({
                status = "dry_run",
                planned = {
                    {
                        op_index = 1,
                        path = HOME_FILE,
                        kind = "delete_range",
                        range = { start_line = 9, end_line = 12 },
                        preview = { { line = 9, text = "a" }, { line = 12, text = "b" } },
                    },
                },
            })
            assert.are.same({
                op = 0,
                file = "~/proj/a.lua",
                kind = "delete_range",
                lines = "9-12",
                preview = " 9\ta\n...\n12\tb",
            }, out.planned[1])
        end)
    end)

    describe("format", function()
        it("drops empty lists and files that add nothing", function()
            local out = wire.format({
                status = "applied",
                summary = "applied 1, rejected 0, failed 0 across 1 file(s)",
                applied = {
                    { op_index = 1, path = HOME_FILE, kind = "insert", range = { start_line = 5, end_line = 4 } },
                },
                rejected = {},
                failed = {},
                warnings = {},
                files = {
                    {
                        path = HOME_FILE,
                        status = "completed",
                        diagnostics = {},
                        diagnostic_counts = { errors = 0, warnings = 0 },
                        ui_summary = "All 1 block(s) were successfully applied to `" .. HOME_FILE .. "`",
                    },
                },
            })
            assert.are.same({
                status = "applied",
                summary = "applied 1, rejected 0, failed 0 across 1 file(s)",
                applied = { { op = 0, file = "~/proj/a.lua", kind = "insert", lines = "before 5" } },
            }, out)
        end)

        it("keeps per-file diagnostics and a review breakdown", function()
            local diag = { severity = "error", line = 3, end_line = 3, col = 1, end_col = 2, message = "boom" }
            local out = wire.format({
                status = "partial",
                files = {
                    {
                        path = HOME_FILE,
                        status = "completed",
                        diagnostics = { diag },
                        diagnostic_counts = { errors = 1, warnings = 0 },
                        ui_summary = "1 of 2 block(s) were applied",
                    },
                },
            })
            assert.are.same({
                {
                    file = "~/proj/a.lua",
                    diagnostics = { diag },
                    diagnostic_counts = { errors = 1, warnings = 0 },
                    ui_summary = "1 of 2 block(s) were applied",
                },
            }, out.files)
        end)

        it("offers a fingerprint for a file the model has seen as it is now", function()
            local changed = {
                fingerprint = "def5678",
                changed = true,
                changes = {
                    { old = { start_line = 4, end_line = 4 }, new = { start_line = 4, end_line = 5 } },
                    { old = { start_line = 9, end_line = 9 }, new = { start_line = 11, end_line = 10 } },
                },
                excerpts = { { start_line = 9, lines = { "x", "y" } } },
            }
            local too_big = { fingerprint = "0123456", changed = true, changes = changed.changes }
            local out = wire.format({
                status = "partial",
                note = "n",
                files = {
                    { path = HOME_FILE, status = "completed", readback = { fingerprint = "abc1234", changed = false } },
                    { path = HOME_FILE, status = "completed", readback = changed },
                    { path = HOME_FILE, status = "completed", readback = too_big },
                },
            })
            assert.is.equal("n", out.note)
            assert.are.same({
                { file = "~/proj/a.lua", fingerprint = "abc1234" },
                {
                    file = "~/proj/a.lua",
                    fingerprint = "def5678",
                    changes = { { was = "4", now = "4-5" }, { was = "9", now = "before 11" } },
                    excerpts = { " 9\tx\n10\ty" },
                },
                { file = "~/proj/a.lua", note = "changed too much to show here; re-read it before editing it again" },
            }, out.files)
        end)

        it("flattens an anchor failure and drops the echoed anchor", function()
            local out = wire.format({
                status = "failed",
                failed = {
                    {
                        op_index = 2,
                        path = HOME_FILE,
                        reason = "anchor_ambiguous",
                        anchor = { by = "unique_text", text = "end\n" },
                        hint = "pick one",
                        total_matches = 2,
                        candidates = {
                            { start_line = 7, end_line = 7, text = "end" },
                            { start_line = 9, end_line = 9, text = "  end" },
                        },
                    },
                },
            })
            assert.are.same({
                op = 1,
                file = "~/proj/a.lua",
                reason = "anchor_ambiguous",
                hint = "pick one",
                total_matches = 2,
                candidates = { { lines = "7", text = "end" }, { lines = "9", text = "  end" } },
            }, out.failed[1])
        end)

        it("names a schema error by its own reason and its field", function()
            local out = wire.format({
                status = "failed",
                failed = {
                    {
                        op_index = 1,
                        reason = "schema_invalid",
                        sub_reason = "bad_modifier_target",
                        path = "ops[0].anchor",
                        message = "insert requires a positional anchor",
                        got = "base anchor",
                    },
                },
            })
            assert.are.same({
                op = 0,
                reason = "bad_modifier_target",
                field = "ops[0].anchor",
                message = "insert requires a positional anchor",
                got = "base anchor",
            }, out.failed[1])
        end)

        it("omits a request-level error's null op", function()
            local out = wire.format({
                status = "failed",
                failed = { { op_index = vim.NIL, reason = "schema_invalid", sub_reason = "wrong_type", path = "ops" } },
            })
            assert.are.same({ reason = "wrong_type", field = "ops" }, out.failed[1])
        end)

        it("renumbers conflict peers from 0 and drops the stale baseline", function()
            local out = wire.format({
                status = "failed",
                failed = {
                    {
                        op_index = 3,
                        path = HOME_FILE,
                        reason = "range_conflict",
                        range = { start_line = 4, end_line = 4 },
                        conflict_op_index = 1,
                        conflict_range = { start_line = 4, end_line = 5 },
                        conflicting_op_indices = { 1, 2 },
                    },
                    {
                        op_index = 1,
                        path = HOME_FILE,
                        reason = "stale_fingerprint",
                        baseline_fingerprint = "0000000",
                        live_fingerprint = "abcdef0",
                    },
                },
            })
            assert.are.same({
                op = 2,
                file = "~/proj/a.lua",
                reason = "range_conflict",
                lines = "4",
                conflict_op = 0,
                conflict_lines = "4-5",
                conflict_ops = { 0, 1 },
            }, out.failed[1])
            assert.are.same(
                { op = 0, file = "~/proj/a.lua", reason = "stale_fingerprint", live_fingerprint = "abcdef0" },
                out.failed[2]
            )
        end)
    end)
end)
