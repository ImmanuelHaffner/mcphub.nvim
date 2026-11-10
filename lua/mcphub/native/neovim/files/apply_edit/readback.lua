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
--- @module "mcphub.native.neovim.files.apply_edit.readback"

local file_record = require("mcphub.native.neovim.files.apply_edit.file_record")
local fingerprint = require("mcphub.native.neovim.files.apply_edit.fingerprint")

local M = {}

--- @class mcphub.edit.Readback
--- @field fingerprint string   Fingerprint of the file now.
--- @field changed     boolean  Whether it differs from the content the model read.

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
    return { fingerprint = fingerprint.compute(rec.content), changed = rec.content ~= before }
end

return M
