--- mcphub.native.neovim.files.apply_edit.file_record — canonical in-memory representation of a file
--- being read by the planner.
---
--- A FileRecord is the input shape every anchor resolver expects:
---
---   {
---     path      = "/abs/path/lua/foo.lua",  -- absolute, buffer-canonical
---     content   = "<raw bytes as a single Lua string>",
---     offsets   = { 1, 42, 117, ... },  -- 1-based; offsets[i] = first byte of line i
---     n_lines   = N,
---     bufnr     = 42,                  -- buffer the content was sourced from
---     endofline = true,                -- `:set endofline` for that buffer (affects EOL normalisation)
---   }
---
--- The string is canonical (multi-line `unique_text` matches need cross-line
--- scanning); offsets give O(1) line→byte slicing and O(log n) byte→line
--- translation.
---
--- ## Buffer-first reads
---
--- `M.read(path)` always sources content from a Neovim buffer. If a buffer
--- exists for the path (regardless of whether it's modified), that buffer is
--- the source. Otherwise the path is loaded into a fresh buffer via
--- `bufadd` + `bufload`. Reasons:
---
---   * Modified buffers carry unsaved changes the user is staring at. Reading
---     disk while ignoring them would lie to the LLM about the file's current
---     state. The fingerprint must be computed over what the LLM sees.
---   * mcphub's `EditUI` (which our applier reuses) operates on buffers. Using
---     buffers throughout means one consistent source of truth across read,
---     anchor resolution, and apply.
---   * `nvim_buf_get_lines` returns lines already split — no `string.gmatch`
---     pass, no encoding ambiguity. Fast for already-loaded buffers (memory)
---     and correct (it sees whatever Neovim has decoded, including BOM strip
---     and EOL conversion).
---
--- ## EOL normalisation
---
--- `nvim_buf_get_lines` strips line terminators. We rebuild `content` as
--- `table.concat(lines, '\n')` and append a final `\n` iff
--- `vim.bo[bufnr].endofline` is set (the default for files ending in `\n` on
--- disk). The `endofline` flag is captured in the record so the planner's
--- re-hash at apply time uses the same normalisation. Other newline
--- conventions (`\r\n`, `\r`) are out of scope for MVP — Neovim's
--- `'fileformat'` option already normalises these on load.
---
--- @module "mcphub.native.neovim.files.apply_edit.file_record"

local M = {}

--- A canonical file record.
--- @class mcphub.edit.FileRecord
--- @field path      string                 Absolute path as Neovim names the buffer (`realpath`-canonical).
--- @field content   string                 Raw bytes of the file as a single Lua string (EOL-normalised, see module doc).
--- @field offsets   integer[]              1-based; offsets[i] = first byte of line i. Always has at least { 1 }.
--- @field n_lines   integer                Number of lines in `content`. Derived from `#offsets`.
--- @field bufnr     integer                Buffer number the content was sourced from.
--- @field endofline boolean                Captured `vim.bo[bufnr].endofline` at read time.

--- Build the line-start offsets array for a string.
---
--- Convention: `offsets[i]` is the byte position (1-based) where line `i`
--- begins. The line-terminator `\n` is considered to belong to the line it
--- terminates, NOT to start a new (phantom) line. Consequently:
---
---   ""              → {}             (0 lines)
---   "\n"            → {1}            (1 empty line)
---   "foo"           → {1}            (1 line, no trailing newline)
---   "foo\n"         → {1}            (1 line, trailing newline conventional)
---   "foo\nbar"      → {1, 5}         (2 lines, last unterminated)
---   "foo\nbar\n"    → {1, 5}         (2 lines, both terminated)
---   "foo\n\n"       → {1, 5}         (2 lines, second empty)
---
--- The `pos = i + 1` step at the bottom of the loop may push `pos` one past
--- `#content` when the last byte of the file is a `\n`. Lua's `string.find`
--- treats `init > #s` as a guaranteed no-match (returns nil), so this is safe
--- and the loop terminates naturally on the next iteration.
---
--- @param content string
--- @return integer[]
function M.build_offsets(content)
    if content == "" then
        return {}
    end
    local offsets = { 1 }
    local pos = 1
    local n = #content
    while true do
        local i = content:find("\n", pos, true)
        if not i then
            break
        end
        -- A '\n' at the very last byte terminates the line it sits on; it
        -- does NOT open a new (phantom) line. Only register the next-line
        -- offset if there's actually content after the newline.
        if i < n then
            table.insert(offsets, i + 1)
        end
        pos = i + 1
    end
    return offsets
end

--- Reconstruct file content from a buffer's lines, applying EOL normalisation.
---
--- `nvim_buf_get_lines` returns lines without their `\n` terminators. We
--- join with `\n` and append a final `\n` iff `endofline` is set (the
--- default — meaning the file ends with a newline on disk). The same
--- routine runs at read time and at planner-rehash time, so the hash is
--- stable across the read → apply window for unchanged buffers.
---
--- @param bufnr integer
--- @return string content
--- @return boolean endofline
local function buffer_content(bufnr)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local endofline = vim.bo[bufnr].endofline
    local content = table.concat(lines, "\n")
    if endofline and #lines > 0 then
        content = content .. "\n"
    end
    return content, endofline
end

--- Build a record from an already-loaded buffer.
---
--- The caller owns the buffer's lifetime; this function only reads.
---
--- @param bufnr integer  Must satisfy `nvim_buf_is_loaded`.
--- @return mcphub.edit.FileRecord
function M.from_buffer(bufnr)
    assert(vim.api.nvim_buf_is_loaded(bufnr), string.format("from_buffer: bufnr %d is not loaded", bufnr))
    local content, endofline = buffer_content(bufnr)
    local offsets = M.build_offsets(content)
    return {
        path = vim.api.nvim_buf_get_name(bufnr),
        content = content,
        offsets = offsets,
        n_lines = #offsets,
        bufnr = bufnr,
        endofline = endofline,
    }
end

--- Load `path` into a buffer (or find an existing one) and build a canonical
--- record.
---
--- Buffer-first by design: the fingerprint the LLM sees must match what the
--- planner re-hashes, and `EditUI` (our applier) operates on buffers, so we
--- standardise on the buffer as the source of truth. See module doc.
---
--- The `path` argument is expanded with `:p` before the buffer lookup, so a
--- relative path resolves against the cwd. The record's own `path` is *not*
--- that string: `from_buffer` takes it from `nvim_buf_get_name`, which Neovim
--- canonicalises through `realpath`. The two forms differ whenever symlinks
--- are involved — on macOS `$TMPDIR` sits under the `/var` → `/private/var`
--- link — so never compare a `:p` path against a record's `path`.
---
--- Fresh buffers are `bufload`ed (which reads from disk through
--- Neovim's normal load pipeline — encoding, BOM, `'fileformat'`). Pre-checks
--- via `vim.uv.fs_stat` distinguish "file does not exist" from "file is
--- empty" so we don't pollute the buffer list with bogus names.
---
--- @param path string
--- @return mcphub.edit.FileRecord|nil record  On success.
--- @return string|nil err                  On failure, the I/O error message.
function M.read(path)
    if type(path) ~= "string" or path == "" then
        return nil, "path must be a non-empty string"
    end
    local abs_path = vim.fn.fnamemodify(path, ":p")

    -- Existence + type check before we touch the buffer list. `bufadd` on a
    -- nonexistent path silently succeeds — we don't want that.
    local stat = vim.uv.fs_stat(abs_path)
    if not stat then
        return nil, string.format("cannot open %q: file does not exist", abs_path)
    end
    if stat.type ~= "file" and stat.type ~= "link" then
        return nil, string.format("cannot open %q: not a regular file (type=%s)", abs_path, stat.type)
    end

    -- bufadd is idempotent: returns the existing bufnr if a buffer with that
    -- name is already in the list, otherwise creates a fresh unloaded one.
    local bufnr = vim.fn.bufadd(abs_path)
    if bufnr == 0 then
        return nil, string.format("cannot open %q: bufadd failed", abs_path)
    end
    if not vim.api.nvim_buf_is_loaded(bufnr) then
        -- bufload reads the file through Neovim's normal load pipeline:
        -- encoding detection, BOM handling, 'fileformat' normalisation,
        -- FileType autocmds. Errors here typically surface as messages
        -- rather than exceptions; we trust the resulting buffer state.
        local ok, err = pcall(vim.fn.bufload, bufnr)
        if not ok then
            return nil, string.format("cannot load %q: %s", abs_path, tostring(err))
        end
    end

    return M.from_buffer(bufnr), nil
end

--- Build a record from a path and an already-loaded content string.
---
--- This bypasses the buffer-first read pipeline. Intended for tests and for
--- callers that already have content from another source. The resulting
--- record has `bufnr = -1` and `endofline = true` (the conservative default).
---
--- @param path string
--- @param content string
--- @return mcphub.edit.FileRecord
function M.from_content(path, content)
    local offsets = M.build_offsets(content)
    return {
        path = path,
        content = content,
        offsets = offsets,
        n_lines = #offsets,
        bufnr = -1,
        endofline = true,
    }
end

--------------------------------------------------------------------------------
-- Query helpers
--------------------------------------------------------------------------------

--- Return the byte range `[lo, hi]` (inclusive, 1-based) covering lines
--- `start_line .. end_line` (inclusive). The terminating newline of `end_line`
--- is NOT included in `hi`; the byte at `hi` is the last non-newline byte of
--- the range. The caller can slice with `record.content:sub(lo, hi)`.
---
--- @param record  mcphub.edit.FileRecord
--- @param start_line integer 1-based.
--- @param end_line   integer 1-based, inclusive, must be >= start_line.
--- @return integer lo
--- @return integer hi
function M.byte_range(record, start_line, end_line)
    assert(
        start_line >= 1 and start_line <= record.n_lines,
        string.format("start_line %d out of range [1, %d]", start_line, record.n_lines)
    )
    assert(
        end_line >= start_line and end_line <= record.n_lines,
        string.format("end_line %d out of [start_line=%d, n_lines=%d]", end_line, start_line, record.n_lines)
    )

    local lo = record.offsets[start_line]
    local hi
    if end_line == record.n_lines then
        hi = #record.content
        -- Trim a trailing '\n' so the returned bytes are the line content
        -- alone. If the file is empty or just a single '\n', this is a no-op.
        if record.content:sub(hi, hi) == "\n" then
            hi = hi - 1
        end
    else
        -- offsets[end_line + 1] is the first byte of the next line, i.e. the
        -- byte just after the '\n' that terminates end_line. So our `hi` is
        -- two less: skip the '\n' and the off-by-one for "first byte of next".
        hi = record.offsets[end_line + 1] - 2
    end
    return lo, hi
end

--- Return the text of lines `start_line .. end_line` (1-based, inclusive)
--- as a single string, without a trailing newline.
---
--- @param record mcphub.edit.FileRecord
--- @param start_line integer
--- @param end_line   integer
--- @return string
function M.line_text(record, start_line, end_line)
    local lo, hi = M.byte_range(record, start_line, end_line)
    if hi < lo then
        return ""
    end -- empty trailing line
    return record.content:sub(lo, hi)
end

--- Translate a byte offset into `record.content` to the 1-based line number
--- it belongs to. Binary search over `offsets`; O(log n_lines).
---
--- A byte at the start of line k returns k. A byte in the middle of line k
--- also returns k. The '\n' character at the end of line k belongs to line k.
---
--- @param record mcphub.edit.FileRecord
--- @param byte_offset integer 1-based byte position into `record.content`.
--- @return integer line_number
function M.byte_to_line(record, byte_offset)
    local lo, hi = 1, record.n_lines
    while lo < hi do
        local mid = math.floor((lo + hi + 1) / 2)
        if record.offsets[mid] <= byte_offset then
            lo = mid
        else
            hi = mid - 1
        end
    end
    return lo
end

return M
