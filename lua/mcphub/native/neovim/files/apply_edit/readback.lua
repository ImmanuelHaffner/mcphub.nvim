--- mcphub.native.neovim.files.apply_edit.readback — what a file looks like once its edits are done.
---
--- A fingerprint certifies "you have seen this file". Handing the model a
--- fresh one for content it has not seen would bless stale line numbers on
--- its next edit, exactly the hole the fingerprint closes. So the state is
--- read back from the buffer after the review and the write (including
--- format-on-save and anything the user changed meanwhile), never derived
--- from the request, and compared with the content the model's
--- `baseline_fingerprint` pins.
---
--- A changed file's fingerprint therefore travels with the diff from what
--- the model read and numbered excerpts of every changed region: with its
--- earlier read, those show it the file as it is now. When the excerpts
--- would be too long, both are withheld and the model re-reads.
---
--- @module "mcphub.native.neovim.files.apply_edit.readback"

local file_record = require("mcphub.native.neovim.files.apply_edit.file_record")
local fingerprint = require("mcphub.native.neovim.files.apply_edit.fingerprint")

local M = {}

--- Unchanged lines shown on each side of a change.
M.CONTEXT = 2

--- Most excerpt lines returned per file. Beyond it the excerpts, and with
--- them the fingerprint, are withheld: the model re-reads instead.
M.MAX_EXCERPT_LINES = 100

--- @class mcphub.edit.Readback
--- @field fingerprint string   Fingerprint of the file now.
--- @field changed     boolean  Whether it differs from the content the model read.
--- @field changes     { old: mcphub.edit.ResolvedRange, new: mcphub.edit.ResolvedRange }[]?
---                    Present when changed. Zero-width ranges `{ N, N-1 }` mark an
---                    insertion (in `old`) or a deletion (in `new`) before line N.
--- @field excerpts    { start_line: integer, lines: string[] }[]?
---                    The changed regions of the file now, with context. Absent when
---                    unchanged or over `MAX_EXCERPT_LINES`.

--- `vim.diff` gives a zero count's start as the line *after which* the change sits.
local function hunk_range(start, count)
    if count == 0 then
        return { start_line = start + 1, end_line = start }
    end
    return { start_line = start, end_line = start + count - 1 }
end

--- @param content string
--- @return string[]
local function split_lines(content)
    local lines = vim.split(content, "\n", { plain = true })
    if lines[#lines] == "" then
        lines[#lines] = nil
    end
    return lines
end

--- The diff from what the model read to what is there now, and excerpts of
--- the result: the diff fully determines the new file from the old, so a
--- model holding both has in effect seen the file as it is now.
---
--- @param before string
--- @param after  string
--- @return table changes
--- @return table? excerpts
local function diff(before, after)
    local changes, windows = {}, {}
    for _, h in ipairs(vim.diff(before, after, { result_type = "indices" })) do
        local old, new = hunk_range(h[1], h[2]), hunk_range(h[3], h[4])
        changes[#changes + 1] = { old = old, new = new }
        local lo, hi = new.start_line - M.CONTEXT, new.end_line + M.CONTEXT
        local last = windows[#windows]
        if last and lo <= last[2] + 1 then
            last[2] = hi
        else
            windows[#windows + 1] = { lo, hi }
        end
    end

    local lines = split_lines(after)
    local excerpts, total = {}, 0
    for _, w in ipairs(windows) do
        local lo, hi = math.max(w[1], 1), math.min(w[2], #lines)
        if lo <= hi then
            excerpts[#excerpts + 1] = { start_line = lo, lines = vim.list_slice(lines, lo, hi) }
            total = total + hi - lo + 1
        end
    end
    if total > M.MAX_EXCERPT_LINES then
        return changes, nil
    end
    return changes, excerpts
end

--- @param path   string  Absolute path.
--- @param before string  The content the planner located the ops in.
--- @return mcphub.edit.Readback?  nil when the file cannot be read back.
function M.compare(path, before)
    if vim.fn.filereadable(path) ~= 1 then
        return nil
    end
    local rec = file_record.read(path)
    if not rec then
        return nil
    end
    local out = { fingerprint = fingerprint.compute(rec.content), changed = rec.content ~= before }
    if out.changed then
        out.changes, out.excerpts = diff(before, rec.content)
    end
    return out
end

return M
