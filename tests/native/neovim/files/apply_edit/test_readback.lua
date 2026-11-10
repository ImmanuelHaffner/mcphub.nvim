--- Tests for mcphub.native.neovim.files.apply_edit.readback.

local assert = require("tests.native.neovim.files.apply_edit.busted_assert")

local fingerprint = require("mcphub.native.neovim.files.apply_edit.fingerprint")
local readback = require("mcphub.native.neovim.files.apply_edit.readback")

local SEVEN = "a\nb\nc\nd\ne\nf\ng\n"

--- Write `after` to a fresh file and compare it with `before`.
local function compare(before, after)
    local path = vim.fn.tempname()
    local f = assert(io.open(path, "wb"))
    f:write(after)
    f:close()
    local rb = readback.compare(path, before)
    local bufnr = vim.fn.bufnr(path)
    if bufnr > 0 then
        vim.api.nvim_buf_delete(bufnr, { force = true })
    end
    vim.fn.delete(path)
    return rb
end

describe("mcphub.native.neovim.files.apply_edit.readback", function()
    it("reports an unchanged file without a diff", function()
        assert.are.same({ fingerprint = fingerprint.compute(SEVEN), changed = false }, compare(SEVEN, SEVEN))
    end)

    it("maps a replacement to its lines before and after, with context", function()
        local rb = compare(SEVEN, "a\nb\nc\nD1\nD2\ne\nf\ng\n")
        assert.is.equal(true, rb.changed)
        assert.are.same({
            { old = { start_line = 4, end_line = 4 }, new = { start_line = 4, end_line = 5 } },
        }, rb.changes)
        assert.are.same({ { start_line = 2, lines = { "b", "c", "D1", "D2", "e", "f" } } }, rb.excerpts)
    end)

    it("marks a deletion as a zero-width range and clamps context to the file", function()
        local rb = compare("a\nb\nc\n", "b\nc\n")
        assert.are.same({
            { old = { start_line = 1, end_line = 1 }, new = { start_line = 1, end_line = 0 } },
        }, rb.changes)
        assert.are.same({ { start_line = 1, lines = { "b", "c" } } }, rb.excerpts)
    end)

    it("merges the excerpts of nearby changes", function()
        local rb = compare(SEVEN, "a\nB\nc\nd\nE\nf\ng\n")
        assert.is.equal(2, #rb.changes)
        assert.are.same({ { start_line = 1, lines = { "a", "B", "c", "d", "E", "f", "g" } } }, rb.excerpts)
    end)

    it("withholds excerpts beyond the cap", function()
        local cap = readback.MAX_EXCERPT_LINES
        readback.MAX_EXCERPT_LINES = 3
        local rb = compare(SEVEN, "a\nb\nc\nD\ne\nf\ng\n")
        readback.MAX_EXCERPT_LINES = cap
        assert.is.equal(1, #rb.changes)
        assert.is_nil(rb.excerpts)
    end)

    it("cannot read back a file that is gone", function()
        assert.is_nil(readback.compare("/nonexistent/readback", SEVEN))
    end)
end)
