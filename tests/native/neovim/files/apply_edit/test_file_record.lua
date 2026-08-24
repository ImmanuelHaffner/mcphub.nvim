--- Tests for mcphub.native.neovim.files.apply_edit.file_record.
---
--- Run headless:
---   make test

local assert = require("tests.native.neovim.files.apply_edit.busted_assert")

local fr = require("mcphub.native.neovim.files.apply_edit.file_record")

describe("mcphub.native.neovim.files.apply_edit.file_record", function()
    describe("build_offsets — line-counting edge cases", function()
        it("an empty file has zero lines", function()
            assert.are.same({}, fr.build_offsets(""))
        end)

        it("a single newline is one empty line, not two", function()
            -- The terminator belongs to the line it terminates; a file
            -- consisting of one '\n' is "one empty line," not "an empty
            -- line followed by another empty line."
            assert.are.same({ 1 }, fr.build_offsets("\n"))
        end)

        it("a single line with no trailing newline has one line", function()
            assert.are.same({ 1 }, fr.build_offsets("foo"))
        end)

        it("a single line with a trailing newline has one line, not two", function()
            -- The POSIX-conventional "file ends with newline" case: the
            -- trailing '\n' terminates line 1, it does not begin a phantom
            -- line 2.
            assert.are.same({ 1 }, fr.build_offsets("foo\n"))
        end)

        it("two lines without a trailing newline", function()
            assert.are.same({ 1, 5 }, fr.build_offsets("foo\nbar"))
        end)

        it("two lines with a trailing newline (no phantom 3rd line)", function()
            assert.are.same({ 1, 5 }, fr.build_offsets("foo\nbar\n"))
        end)

        it("preserves empty lines in the middle", function()
            assert.are.same({ 1, 5, 6 }, fr.build_offsets("foo\n\nbar"))
        end)

        it("preserves an empty trailing line but does not double-count it", function()
            -- Two terminated lines; the second is empty.
            assert.are.same({ 1, 5 }, fr.build_offsets("foo\n\n"))
        end)
    end)

    describe("from_content", function()
        it("packages content + offsets + n_lines into a record", function()
            local rec = fr.from_content("test.lua", "foo\nbar")
            assert.is.equal("test.lua", rec.path)
            assert.is.equal("foo\nbar", rec.content)
            assert.are.same({ 1, 5 }, rec.offsets)
            assert.is.equal(2, rec.n_lines)
        end)

        it("produces n_lines=0 for an empty file", function()
            local rec = fr.from_content("empty", "")
            assert.is.equal(0, rec.n_lines)
            assert.are.same({}, rec.offsets)
        end)
    end)

    describe("byte_range — slicing single lines", function()
        local rec = fr.from_content("t", "foo\nbar\nqux")

        it("line 1", function()
            local lo, hi = fr.byte_range(rec, 1, 1)
            assert.is.equal(1, lo)
            assert.is.equal(3, hi)
        end)

        it("middle line", function()
            local lo, hi = fr.byte_range(rec, 2, 2)
            assert.is.equal(5, lo)
            assert.is.equal(7, hi)
        end)

        it("last line", function()
            local lo, hi = fr.byte_range(rec, 3, 3)
            assert.is.equal(9, lo)
            assert.is.equal(11, hi)
        end)
    end)

    describe("byte_range — multi-line ranges", function()
        local rec = fr.from_content("t", "foo\nbar\nqux")

        it("lines 1..2", function()
            local lo, hi = fr.byte_range(rec, 1, 2)
            assert.is.equal(1, lo)
            assert.is.equal(7, hi)
            assert.is.equal("foo\nbar", rec.content:sub(lo, hi))
        end)

        it("lines 2..3 (range ends at last line)", function()
            local lo, hi = fr.byte_range(rec, 2, 3)
            assert.is.equal(5, lo)
            assert.is.equal(11, hi)
            assert.is.equal("bar\nqux", rec.content:sub(lo, hi))
        end)

        it("whole file", function()
            local lo, hi = fr.byte_range(rec, 1, 3)
            assert.is.equal(1, lo)
            assert.is.equal(11, hi)
            assert.is.equal("foo\nbar\nqux", rec.content:sub(lo, hi))
        end)
    end)

    describe("byte_range — trailing-newline handling", function()
        it("strips the trailing newline when the last line is the last one in the range", function()
            local rec = fr.from_content("t", "foo\nbar\n")
            -- File has 2 lines (last terminated). Slicing the last line
            -- should return "bar" (not "bar\n").
            local lo, hi = fr.byte_range(rec, 2, 2)
            assert.is.equal("bar", rec.content:sub(lo, hi))
        end)

        it("still returns the inter-line newline when slicing multiple lines", function()
            local rec = fr.from_content("t", "foo\nbar\n")
            local lo, hi = fr.byte_range(rec, 1, 2)
            assert.is.equal("foo\nbar", rec.content:sub(lo, hi))
        end)
    end)

    describe("line_text", function()
        local rec = fr.from_content("t", "foo\nbar\nqux")

        it("returns single-line text without trailing newline", function()
            assert.is.equal("foo", fr.line_text(rec, 1, 1))
            assert.is.equal("bar", fr.line_text(rec, 2, 2))
            assert.is.equal("qux", fr.line_text(rec, 3, 3))
        end)

        it("returns multi-line text with inner newlines preserved", function()
            assert.is.equal("foo\nbar", fr.line_text(rec, 1, 2))
            assert.is.equal("foo\nbar\nqux", fr.line_text(rec, 1, 3))
        end)

        it("returns an empty string for an empty line", function()
            local rec_blank = fr.from_content("t", "foo\n\nbar")
            assert.is.equal("", fr.line_text(rec_blank, 2, 2))
        end)
    end)

    describe("byte_to_line", function()
        local rec = fr.from_content("t", "foo\nbar\nqux")
        -- offsets = {1, 5, 9}; #content = 11
        -- bytes 1..4: line 1 (4 is the '\n')
        -- bytes 5..8: line 2 (8 is the '\n')
        -- bytes 9..11: line 3

        it("byte at line start returns that line", function()
            assert.is.equal(1, fr.byte_to_line(rec, 1))
            assert.is.equal(2, fr.byte_to_line(rec, 5))
            assert.is.equal(3, fr.byte_to_line(rec, 9))
        end)

        it("byte mid-line returns that line", function()
            assert.is.equal(1, fr.byte_to_line(rec, 2)) -- 'o' of 'foo'
            assert.is.equal(2, fr.byte_to_line(rec, 6)) -- 'a' of 'bar'
            assert.is.equal(3, fr.byte_to_line(rec, 10)) -- 'u' of 'qux'
        end)

        it("the terminating newline belongs to the line it terminates", function()
            assert.is.equal(1, fr.byte_to_line(rec, 4)) -- '\n' after 'foo'
            assert.is.equal(2, fr.byte_to_line(rec, 8)) -- '\n' after 'bar'
        end)

        it("the last byte of the file returns the last line", function()
            assert.is.equal(3, fr.byte_to_line(rec, 11))
        end)
    end)

    describe("read — file I/O (buffer-first)", function()
        --- Helper: write a fresh tempfile and return the path in the form the
        --- engine reports — absolute *and* symlink-resolved, since the engine is
        --- buffer-first and Neovim canonicalises buffer names through `realpath`.
        --- `:p` alone does not resolve symlinks, and on macOS the two differ
        --- because `$TMPDIR` sits under the `/var` -> `/private/var` symlink.
        local function write_tempfile(content)
            local tmp = vim.fn.tempname()
            local f = assert(io.open(tmp, "wb"), "failed to open tempfile for write")
            f:write(content)
            f:close()
            return vim.fn.resolve(vim.fn.fnamemodify(tmp, ":p"))
        end

        --- Helper: wipe a buffer + delete its file.
        local function cleanup(path)
            local bufnr = vim.fn.bufnr(path)
            if bufnr > 0 then
                pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
            end
            vim.fn.delete(path)
        end

        it("reads an existing file via buffer and produces a record", function()
            local tmp = write_tempfile("line1\nline2\n")

            local rec, err = fr.read(tmp)
            assert.is_nil(err)
            assert.is.equal(tmp, rec.path)
            assert.is.equal("line1\nline2\n", rec.content)
            assert.is.equal(2, rec.n_lines)
            assert.is_truthy(rec.bufnr > 0)
            assert.is_truthy(rec.endofline)

            cleanup(tmp)
        end)

        it("normalises a relative path to an absolute path on the record", function()
            local tmp = write_tempfile("x\n")
            -- Ask via a non-absolute spelling. The record should hold the
            -- buffer-canonical (absolute, symlink-resolved) form.
            local rel = vim.fn.fnamemodify(tmp, ":~") -- e.g. ~/...
            local rec, err = fr.read(rel)
            assert.is_nil(err)
            assert.is.equal(tmp, rec.path)
            cleanup(tmp)
        end)

        it("returns nil + error when the file does not exist", function()
            local rec, err = fr.read("/nonexistent/path/that/should/not/exist")
            assert.is_nil(rec)
            assert.is_string(err)
            assert.is_truthy(err:find("does not exist", 1, true))
        end)

        it("rejects a directory", function()
            local rec, err = fr.read("/tmp")
            assert.is_nil(rec)
            assert.is_string(err)
            assert.is_truthy(err:find("not a regular file", 1, true))
        end)

        it("rejects an empty path", function()
            local rec, err = fr.read("")
            assert.is_nil(rec)
            assert.is.equal("path must be a non-empty string", err)
        end)

        it("reads from an already-loaded buffer instead of from disk", function()
            -- Create a file on disk, load it into a buffer, mutate the
            -- buffer without saving, then read. The record content should
            -- reflect the buffer state, not the disk state — this is the
            -- "fingerprint must match what the LLM sees" invariant.
            local tmp = write_tempfile("on_disk_line\n")
            local bufnr = vim.fn.bufadd(tmp)
            vim.fn.bufload(bufnr)
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "in_buffer_line" })

            local rec, err = fr.read(tmp)
            assert.is_nil(err)
            assert.is.equal(bufnr, rec.bufnr)
            -- We see the buffer's content, NOT the on-disk content.
            assert.is.equal("in_buffer_line\n", rec.content)
            assert.is.equal(1, rec.n_lines)

            cleanup(tmp)
        end)

        it("idempotency: two reads of the same path produce the same bufnr", function()
            local tmp = write_tempfile("hello\n")
            local rec1 = assert(fr.read(tmp))
            local rec2 = assert(fr.read(tmp))
            assert.is.equal(rec1.bufnr, rec2.bufnr)
            assert.is.equal(rec1.content, rec2.content)
            cleanup(tmp)
        end)
    end)

    describe("from_buffer", function()
        it("builds a record from a loaded buffer with endofline=true", function()
            local bufnr = vim.api.nvim_create_buf(false, true) -- nofile, scratch
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "alpha", "beta", "gamma" })
            vim.bo[bufnr].endofline = true

            local rec = fr.from_buffer(bufnr)
            assert.is.equal(bufnr, rec.bufnr)
            assert.is_truthy(rec.endofline)
            assert.is.equal("alpha\nbeta\ngamma\n", rec.content)
            assert.is.equal(3, rec.n_lines)

            pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
        end)

        it("omits the trailing newline when endofline=false", function()
            local bufnr = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "no_final_newline" })
            vim.bo[bufnr].endofline = false

            local rec = fr.from_buffer(bufnr)
            assert.is_falsy(rec.endofline)
            assert.is.equal("no_final_newline", rec.content)
            assert.is.equal(1, rec.n_lines)

            pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
        end)

        it("handles an empty buffer (no lines, endofline irrelevant)", function()
            local bufnr = vim.api.nvim_create_buf(false, true)
            -- nvim_create_buf gives a buffer with one empty line by default.
            -- Force it to zero lines.
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})

            local rec = fr.from_buffer(bufnr)
            -- Neovim normalises "zero lines" to "one empty line" on read-back.
            -- The record reflects whatever nvim_buf_get_lines returns.
            -- Just assert the invariant: content length is consistent with offsets.
            assert.is.equal(#rec.offsets, rec.n_lines)

            pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
        end)

        it("asserts when the buffer is not loaded", function()
            local bufnr = vim.fn.bufadd("/tmp/never-actually-loaded-" .. os.time())
            -- Don't bufload — bufadd alone leaves it unloaded.
            assert.is_falsy(vim.api.nvim_buf_is_loaded(bufnr))
            local ok = pcall(fr.from_buffer, bufnr)
            assert.is_falsy(ok)
            pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
        end)
    end)
end)
