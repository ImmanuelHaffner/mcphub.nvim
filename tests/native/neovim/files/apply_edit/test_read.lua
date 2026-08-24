--- Tests for mcphub.native.neovim.files.apply_edit.read.
---
--- Run headless:
---   make test

local assert = require("tests.native.neovim.files.apply_edit.busted_assert")

local edit_read = require("mcphub.native.neovim.files.apply_edit.read")
local fingerprint = require("mcphub.native.neovim.files.apply_edit.fingerprint")
local schema = require("mcphub.native.neovim.files.apply_edit.schema")

--- Write a fresh tempfile and return the path in the form the engine reports:
--- absolute *and* symlink-resolved. The engine is buffer-first, and Neovim
--- canonicalises buffer names through `realpath`, so the record carries the
--- resolved name. `:p` alone does not resolve symlinks — on macOS the two forms
--- differ, because `$TMPDIR` sits under the `/var` -> `/private/var` symlink.
local function write_tempfile(content)
    local tmp = vim.fn.tempname()
    local f = assert(io.open(tmp, "wb"), "tempfile open failed")
    f:write(content)
    f:close()
    return vim.fn.resolve(vim.fn.fnamemodify(tmp, ":p"))
end

--- Wipe the buffer attached to `path` and delete the file.
local function cleanup(path)
    local bufnr = vim.fn.bufnr(path)
    if bufnr > 0 then
        pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
    vim.fn.delete(path)
end

describe("mcphub.native.neovim.files.apply_edit.read.read_with_fingerprint", function()
    describe("success path", function()
        it("returns status=ok with content, baseline_fingerprint, range fields, absolute path", function()
            local tmp = write_tempfile("alpha\nbeta\ngamma\n")
            local r = edit_read.read_with_fingerprint(tmp)
            assert.is.equal("ok", r.status)
            assert.is.equal(tmp, r.path)
            assert.is.equal("alpha\nbeta\ngamma\n", r.content)
            assert.is.equal(3, r.total_lines)
            assert.is.equal(3, r.returned_lines)
            assert.is.equal(1, r.start_line)
            assert.is.equal(3, r.end_line)
            assert.is_truthy(fingerprint.is_valid_format(r.baseline_fingerprint))
            cleanup(tmp)
        end)

        it("baseline_fingerprint is the same one fingerprint.compute would produce", function()
            local tmp = write_tempfile("exact\n")
            local r = edit_read.read_with_fingerprint(tmp)
            assert.is.equal(fingerprint.compute(r.content), r.baseline_fingerprint)
            cleanup(tmp)
        end)

        it("handles empty files", function()
            -- Neovim has no "zero-line buffer" — an empty file loads as
            -- one empty line. With endofline=true (the default), the
            -- normalised content is a single '\n'. The fingerprint
            -- mechanism works either way; what matters is that read and
            -- re-compute use the same routine.
            local tmp = write_tempfile("")
            local r = edit_read.read_with_fingerprint(tmp)
            assert.is.equal("ok", r.status)
            assert.is.equal("\n", r.content)
            assert.is.equal(1, r.total_lines)
            assert.is.equal(1, r.returned_lines)
            assert.is_truthy(fingerprint.is_valid_format(r.baseline_fingerprint))
            cleanup(tmp)
        end)

        it("handles single-line file without trailing newline", function()
            local tmp = write_tempfile("one")
            local r = edit_read.read_with_fingerprint(tmp)
            assert.is.equal("ok", r.status)
            -- Buffer-loaded reads through Neovim's normal pipeline. Whether
            -- the trailing newline is added or not depends on 'endofline'
            -- detection; we just assert the fingerprint is well-formed.
            assert.is_truthy(fingerprint.is_valid_format(r.baseline_fingerprint))
            cleanup(tmp)
        end)

        it("normalises relative-form paths to absolute in the response", function()
            local abs = write_tempfile("x\n")
            local rel = vim.fn.fnamemodify(abs, ":~")
            local r = edit_read.read_with_fingerprint(rel)
            assert.is.equal("ok", r.status)
            assert.is.equal(abs, r.path)
            cleanup(abs)
        end)

        it("two reads of the same unchanged file produce the same fingerprint", function()
            local tmp = write_tempfile("stable\n")
            local r1 = edit_read.read_with_fingerprint(tmp)
            local r2 = edit_read.read_with_fingerprint(tmp)
            assert.is.equal(r1.baseline_fingerprint, r2.baseline_fingerprint)
            cleanup(tmp)
        end)

        it("reflects buffer content when a modified buffer holds unsaved changes", function()
            -- The whole point of buffer-first reads: the LLM must see what
            -- the user sees, not what's on disk.
            local tmp = write_tempfile("disk_content\n")
            local bufnr = vim.fn.bufadd(tmp)
            vim.fn.bufload(bufnr)
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "buffer_content" })

            local r = edit_read.read_with_fingerprint(tmp)
            assert.is.equal("ok", r.status)
            -- The content we see is the buffer's, not the disk's.
            assert.is.equal("buffer_content\n", r.content)
            -- And the fingerprint reflects that content.
            assert.is.equal(fingerprint.compute("buffer_content\n"), r.baseline_fingerprint)
            cleanup(tmp)
        end)
    end)

    describe("range projection", function()
        it("start_line only reads from N to EOF (with clamping defaulting end_line to total_lines)", function()
            local tmp = write_tempfile("a\nb\nc\nd\ne\n")
            local r = edit_read.read_with_fingerprint(tmp, { start_line = 3 })
            assert.is.equal("ok", r.status)
            assert.is.equal("c\nd\ne\n", r.content)
            assert.is.equal(3, r.start_line)
            assert.is.equal(5, r.end_line)
            assert.is.equal(3, r.returned_lines)
            assert.is.equal(5, r.total_lines)
            cleanup(tmp)
        end)

        it("end_line only reads from line 1 to M", function()
            local tmp = write_tempfile("a\nb\nc\nd\ne\n")
            local r = edit_read.read_with_fingerprint(tmp, { end_line = 2 })
            assert.is.equal("ok", r.status)
            assert.is.equal("a\nb\n", r.content)
            assert.is.equal(1, r.start_line)
            assert.is.equal(2, r.end_line)
            assert.is.equal(2, r.returned_lines)
            assert.is.equal(5, r.total_lines)
            cleanup(tmp)
        end)

        it("both start_line and end_line project an inclusive interior range", function()
            local tmp = write_tempfile("a\nb\nc\nd\ne\n")
            local r = edit_read.read_with_fingerprint(tmp, { start_line = 2, end_line = 4 })
            assert.is.equal("ok", r.status)
            assert.is.equal("b\nc\nd\n", r.content)
            assert.is.equal(2, r.start_line)
            assert.is.equal(4, r.end_line)
            assert.is.equal(3, r.returned_lines)
            assert.is.equal(5, r.total_lines)
            cleanup(tmp)
        end)

        it("start_line == end_line returns a single line", function()
            local tmp = write_tempfile("alpha\nbeta\ngamma\n")
            local r = edit_read.read_with_fingerprint(tmp, { start_line = 2, end_line = 2 })
            assert.is.equal("ok", r.status)
            assert.is.equal("beta\n", r.content)
            assert.is.equal(1, r.returned_lines)
            assert.is.equal(3, r.total_lines)
            cleanup(tmp)
        end)

        it("end_line > total_lines silently clamps to total_lines", function()
            local tmp = write_tempfile("a\nb\nc\n")
            local r = edit_read.read_with_fingerprint(tmp, { start_line = 2, end_line = 99999 })
            assert.is.equal("ok", r.status)
            assert.is.equal("b\nc\n", r.content)
            assert.is.equal(2, r.start_line)
            assert.is.equal(3, r.end_line) -- clamped from 99999
            assert.is.equal(2, r.returned_lines)
            assert.is.equal(3, r.total_lines)
            cleanup(tmp)
        end)

        it("omitted opts behaves identically to a full-range request", function()
            local tmp = write_tempfile("one\ntwo\nthree\n")
            local r_implicit = edit_read.read_with_fingerprint(tmp)
            local r_explicit = edit_read.read_with_fingerprint(tmp, { start_line = 1, end_line = 3 })
            assert.is.equal(r_implicit.content, r_explicit.content)
            assert.is.equal(r_implicit.start_line, r_explicit.start_line)
            assert.is.equal(r_implicit.end_line, r_explicit.end_line)
            assert.is.equal(r_implicit.baseline_fingerprint, r_explicit.baseline_fingerprint)
            cleanup(tmp)
        end)

        it("baseline_fingerprint is ALWAYS whole-file, independent of the range", function()
            -- This is the load-bearing invariant: apply_edit re-hashes the
            -- whole buffer at apply time, so any range-scoped fingerprint
            -- would always mismatch. The range is purely a content
            -- projection knob on the response.
            local tmp = write_tempfile("a\nb\nc\nd\ne\n")
            local r_full = edit_read.read_with_fingerprint(tmp)
            local r_range = edit_read.read_with_fingerprint(tmp, { start_line = 2, end_line = 4 })
            assert.is.equal(r_full.baseline_fingerprint, r_range.baseline_fingerprint)
            -- And distinct from the fingerprint of the projected slice:
            local slice_fp = fingerprint.compute(r_range.content)
            assert.is_true(
                slice_fp ~= r_range.baseline_fingerprint,
                "expected slice-only fingerprint to differ from whole-file baseline"
            )
            cleanup(tmp)
        end)

        it("range projection respects buffer-first: modified buffer wins over disk", function()
            local tmp = write_tempfile("disk_a\ndisk_b\ndisk_c\n")
            local bufnr = vim.fn.bufadd(tmp)
            vim.fn.bufload(bufnr)
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "buf_1", "buf_2", "buf_3" })

            local r = edit_read.read_with_fingerprint(tmp, { start_line = 2, end_line = 3 })
            assert.is.equal("ok", r.status)
            assert.is.equal("buf_2\nbuf_3\n", r.content)
            cleanup(tmp)
        end)

        it("preserves trailing newline within an interior range", function()
            -- An interior projection always keeps the trailing '\n' on its
            -- last line; the file's overall endofline flag is irrelevant
            -- because we're not at EOF.
            local tmp = write_tempfile("one\ntwo\nthree") -- no trailing newline on disk
            local r = edit_read.read_with_fingerprint(tmp, { start_line = 1, end_line = 2 })
            assert.is.equal("ok", r.status)
            assert.is.equal("one\ntwo\n", r.content)
            cleanup(tmp)
        end)

        it("empty file + explicit { start_line = 1, end_line = 1 } projects the single empty line", function()
            -- Neovim has no "zero-line buffer": an empty file loads as one
            -- empty line (total_lines = 1, content = '\n'). An explicit
            -- single-line range on that file must succeed, not refuse.
            local tmp = write_tempfile("")
            local r = edit_read.read_with_fingerprint(tmp, { start_line = 1, end_line = 1 })
            assert.is.equal("ok", r.status)
            assert.is.equal("\n", r.content)
            assert.is.equal(1, r.start_line)
            assert.is.equal(1, r.end_line)
            assert.is.equal(1, r.returned_lines)
            assert.is.equal(1, r.total_lines)
            cleanup(tmp)
        end)

        it("empty file + { start_line = 1 } (open-ended) projects the single empty line", function()
            -- With end_line defaulted to total_lines (1), this is equivalent
            -- to the explicit case above. Pins that the defaulting logic
            -- works at the empty-file boundary.
            local tmp = write_tempfile("")
            local r = edit_read.read_with_fingerprint(tmp, { start_line = 1 })
            assert.is.equal("ok", r.status)
            assert.is.equal("\n", r.content)
            assert.is.equal(1, r.returned_lines)
            assert.is.equal(1, r.total_lines)
            cleanup(tmp)
        end)
    end)

    describe("range refusal shapes", function()
        it("start_line > total_lines → start_after_eof refusal naming total_lines", function()
            local tmp = write_tempfile("a\nb\nc\n") -- 3 lines
            local r = edit_read.read_with_fingerprint(tmp, { start_line = 10 })
            assert.is.equal("failed", r.status)
            assert.is.equal(1, #r.failed)
            assert.is.equal(schema.ERROR_REASONS.start_after_eof, r.failed[1].reason)
            assert.is.equal(3, r.failed[1].total_lines)
            assert.is.equal(10, r.failed[1].start_line)
            assert.is_string(r.failed[1].hint)
            cleanup(tmp)
        end)

        it("start_line > end_line → invalid_range refusal", function()
            local tmp = write_tempfile("a\nb\nc\nd\ne\n")
            local r = edit_read.read_with_fingerprint(tmp, { start_line = 4, end_line = 2 })
            assert.is.equal("failed", r.status)
            assert.is.equal(schema.ERROR_REASONS.invalid_range, r.failed[1].reason)
            assert.is.equal(4, r.failed[1].start_line)
            assert.is.equal(2, r.failed[1].end_line)
            cleanup(tmp)
        end)

        it("start_line < 1 → out_of_range refusal at shape-validation time (no I/O)", function()
            -- No file is created; shape-validation must reject before I/O.
            local r = edit_read.read_with_fingerprint("/nonexistent/path", { start_line = 0 })
            assert.is.equal("failed", r.status)
            assert.is.equal(schema.ERROR_REASONS.out_of_range, r.failed[1].reason)
        end)

        it("end_line < 1 → out_of_range refusal", function()
            local r = edit_read.read_with_fingerprint("/nonexistent/path", { end_line = 0 })
            assert.is.equal("failed", r.status)
            assert.is.equal(schema.ERROR_REASONS.out_of_range, r.failed[1].reason)
        end)

        it("non-integer start_line → wrong_type refusal", function()
            local r = edit_read.read_with_fingerprint("/nonexistent/path", { start_line = 1.5 })
            assert.is.equal("failed", r.status)
            assert.is.equal(schema.ERROR_REASONS.wrong_type, r.failed[1].reason)
        end)

        it("non-integer end_line → wrong_type refusal", function()
            local r = edit_read.read_with_fingerprint("/nonexistent/path", { end_line = 2.5 })
            assert.is.equal("failed", r.status)
            assert.is.equal(schema.ERROR_REASONS.wrong_type, r.failed[1].reason)
        end)

        it("string end_line → wrong_type refusal", function()
            ---@diagnostic disable-next-line: assign-type-mismatch
            local r = edit_read.read_with_fingerprint("/nonexistent/path", { end_line = "10" })
            assert.is.equal("failed", r.status)
            assert.is.equal(schema.ERROR_REASONS.wrong_type, r.failed[1].reason)
        end)

        it("non-table opts → wrong_type refusal", function()
            ---@diagnostic disable-next-line: param-type-mismatch
            local r = edit_read.read_with_fingerprint("/nonexistent/path", "not a table")
            assert.is.equal("failed", r.status)
            assert.is.equal(schema.ERROR_REASONS.wrong_type, r.failed[1].reason)
        end)

        it("empty file + start_line = 2 → start_after_eof (the file has 1 line)", function()
            -- An empty file has total_lines = 1; start_line = 2 is past EOF.
            -- This is the "0 lines" boundary case once you accept Neovim's
            -- one-empty-line convention.
            local tmp = write_tempfile("")
            local r = edit_read.read_with_fingerprint(tmp, { start_line = 2 })
            assert.is.equal("failed", r.status)
            assert.is.equal(schema.ERROR_REASONS.start_after_eof, r.failed[1].reason)
            assert.is.equal(1, r.failed[1].total_lines)
            assert.is.equal(2, r.failed[1].start_line)
            cleanup(tmp)
        end)

        it("explicit invalid_range and start_after_eof both apply → invalid_range wins", function()
            -- When BOTH start_line and end_line are explicit AND inverted,
            -- the LLM clearly made a request-shape mistake; that takes
            -- priority over the (also-true) state-level mismatch, because
            -- it's recoverable without re-reading the file.
            -- Contrast with the case where only start_line is explicit and
            -- exceeds total_lines: that fires start_after_eof, since the
            -- engine itself defaulted end_line (no LLM inversion).
            local tmp = write_tempfile("a\nb\nc\n")
            local r = edit_read.read_with_fingerprint(tmp, { start_line = 100, end_line = 50 })
            assert.is.equal("failed", r.status)
            assert.is.equal(schema.ERROR_REASONS.invalid_range, r.failed[1].reason)
            cleanup(tmp)
        end)
    end)

    describe("failure shape", function()
        it("missing file → status=failed with single io_error", function()
            local r = edit_read.read_with_fingerprint("/nonexistent/never/exists")
            assert.is.equal("failed", r.status)
            assert.is.equal(1, #r.failed)
            assert.is.equal(schema.ERROR_REASONS.io_error, r.failed[1].reason)
            assert.is.equal("/nonexistent/never/exists", r.failed[1].path)
            assert.is_string(r.failed[1].message)
            assert.is_string(r.failed[1].hint)
        end)

        it("hint mentions neovim__write_file for file creation", function()
            local r = edit_read.read_with_fingerprint("/nonexistent/path")
            assert.is_truthy(r.failed[1].hint:find("neovim__write_file", 1, true))
        end)

        it("directory path → io_error", function()
            local r = edit_read.read_with_fingerprint("/tmp")
            assert.is.equal("failed", r.status)
            assert.is.equal(schema.ERROR_REASONS.io_error, r.failed[1].reason)
        end)

        it("empty path → missing_field failure", function()
            local r = edit_read.read_with_fingerprint("")
            assert.is.equal("failed", r.status)
            assert.is.equal(schema.ERROR_REASONS.missing_field, r.failed[1].reason)
        end)

        it("non-string path → wrong_type failure", function()
            local r = edit_read.read_with_fingerprint(42)
            assert.is.equal("failed", r.status)
            assert.is.equal(schema.ERROR_REASONS.wrong_type, r.failed[1].reason)
        end)

        it("nil path → wrong_type failure", function()
            local r = edit_read.read_with_fingerprint(nil)
            assert.is.equal("failed", r.status)
            assert.is.equal(schema.ERROR_REASONS.wrong_type, r.failed[1].reason)
        end)

        it("failure response always carries a non-empty summary", function()
            local r = edit_read.read_with_fingerprint("/nonexistent/q")
            assert.is_string(r.summary)
            assert.is_truthy(#r.summary > 0)
        end)
    end)

    describe("response shape uniformity", function()
        it("success response carries no `failed` / `summary` fields", function()
            local tmp = write_tempfile("x\n")
            local r = edit_read.read_with_fingerprint(tmp)
            assert.is_nil(r.failed)
            assert.is_nil(r.summary)
            cleanup(tmp)
        end)

        it("failure response carries no content / fingerprint / range fields", function()
            local r = edit_read.read_with_fingerprint("/nonexistent")
            assert.is_nil(r.content)
            assert.is_nil(r.baseline_fingerprint)
            assert.is_nil(r.start_line)
            assert.is_nil(r.end_line)
            assert.is_nil(r.returned_lines)
            assert.is_nil(r.total_lines)
        end)
    end)
end)
