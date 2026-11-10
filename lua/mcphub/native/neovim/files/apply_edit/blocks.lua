--- mcphub.native.neovim.files.apply_edit.blocks — joining the applier's blocks.
---
--- The planner admits ops that touch without sharing a line: an insertion at the
--- seam just before or after a replaced range, two insertions at one seam,
--- ranges back to back. Applying such blocks one by one is order-dependent
--- (an insertion before line N and a replacement starting at N share a
--- `start_line`), and widening for EditUI makes them overlap outright. So touching
--- blocks are joined into one block with the combined replacement, and a joined
--- block lists the blocks it absorbed in `members`; drivers report one status per
--- block and the applier fans it out to every member.
---
--- Positions are expressed as seams: seam `p` sits just before line `p`. A range
--- `[s, e]` spans seams `s..e+1`, an insertion before line `p` spans just `p`.
---
--- @module "mcphub.native.neovim.files.apply_edit.blocks"

local M = {}

--- @param block mcphub.edit.applier.Block
--- @return boolean
local function is_insert(block)
    return block.range.end_line < block.range.start_line
end

--- The first and last seam a block touches.
---
--- @param block mcphub.edit.applier.Block
--- @return integer lo
--- @return integer hi
function M.seam_span(block)
    local r = block.range
    if is_insert(block) then
        return r.start_line, r.start_line
    end
    return r.start_line, r.end_line + 1
end

--- The blocks a block stands for: its `members` once joined, else itself.
---
--- @param block mcphub.edit.applier.Block
--- @return mcphub.edit.applier.Block[]
function M.members(block)
    return block.members or { block }
end

--- Order blocks by position. At one seam an insertion goes before a range that
--- starts there, and insertions keep their order in the batch (`order[block]`).
---
--- @param list  mcphub.edit.applier.Block[]
--- @param order table<mcphub.edit.applier.Block, integer>
local function sort_by_position(list, order)
    table.sort(list, function(x, y)
        local xl, yl = M.seam_span(x), M.seam_span(y)
        if xl ~= yl then
            return xl < yl
        end
        if is_insert(x) ~= is_insert(y) then
            return is_insert(x)
        end
        return order[x] < order[y]
    end)
end

--- Join disjoint blocks into one covering everything from the first to the last.
---
--- Lines between two of them are kept as they are, so they must be supplied in
--- `lines` (the buffer's lines, 1-based); without `lines` the blocks must touch.
--- Blocks that are themselves joined are flattened into their members.
---
--- @param list  mcphub.edit.applier.Block[]  In batch order.
--- @param lines string[]?
--- @return mcphub.edit.applier.Block
function M.join(list, lines)
    local flat, order = {}, {}
    for _, b in ipairs(list) do
        for _, m in ipairs(M.members(b)) do
            flat[#flat + 1] = m
            order[m] = #flat
        end
    end
    local first_in_batch = flat[1]
    sort_by_position(flat, order)

    local replace, ids, kinds = {}, {}, {}
    local start = M.seam_span(flat[1])
    local cursor = start -- the next original line not yet covered
    for _, m in ipairs(flat) do
        local lo, hi = M.seam_span(m)
        assert(lo >= cursor, "blocks.join: overlapping blocks " .. m.block_id)
        if lo > cursor then
            assert(lines, "blocks.join: blocks do not touch and no lines were given")
            for l = cursor, lo - 1 do
                replace[#replace + 1] = lines[l]
            end
        end
        vim.list_extend(replace, m.replace_lines)
        ids[#ids + 1] = m.block_id
        kinds[m.kind] = true
        cursor = hi
    end

    local kind = next(kinds)
    if next(kinds, kind) ~= nil then
        kind = "replace_range"
    end
    return {
        block_id = table.concat(ids, "+"),
        op_index = first_in_batch.op_index,
        kind = kind,
        range = { start_line = start, end_line = cursor - 1 },
        replace_lines = replace,
        members = flat,
    }
end

--- Join every block of a file that is empty on disk into one replacing line 1.
---
--- An empty buffer still holds one empty line, which a read shows and an anchor
--- can name, but which is not in the file: kept, it would add a blank line to
--- every insertion. So the joined block replaces it, whichever seam each
--- insertion named.
---
--- @param list mcphub.edit.applier.Block[]  In batch order.
--- @return mcphub.edit.applier.Block
function M.into_empty(list)
    local block = M.join(list, {}) -- the only line between blocks is that empty one
    block.range = { start_line = 1, end_line = 1 }
    return block
end

--- Join every run of touching blocks. Blocks that touch nothing come back as
--- they were, and the result keeps batch order: a joined block takes the place
--- of its earliest member.
---
--- @param list mcphub.edit.applier.Block[]  Pairwise free of shared lines, as the planner guarantees.
--- @return mcphub.edit.applier.Block[]
function M.merge_touching(list)
    if #list < 2 then
        return list
    end
    local order = {}
    for i, b in ipairs(list) do
        order[b] = i
    end
    local sorted = vim.list_slice(list)
    sort_by_position(sorted, order)

    -- `hi` of the current group: the last seam any of its blocks touches.
    local groups, current_hi = {}, -1
    for _, b in ipairs(sorted) do
        local lo, hi = M.seam_span(b)
        if lo <= current_hi then
            local current = groups[#groups]
            current[#current + 1] = b
            current_hi = math.max(current_hi, hi)
        else
            groups[#groups + 1] = { b }
            current_hi = hi
        end
    end

    local out = {}
    for _, g in ipairs(groups) do
        table.sort(g, function(x, y)
            return order[x] < order[y]
        end)
        out[#out + 1] = { first = order[g[1]], block = #g == 1 and g[1] or M.join(g) }
    end
    table.sort(out, function(x, y)
        return x.first < y.first
    end)
    for i, o in ipairs(out) do
        out[i] = o.block
    end
    return out
end

return M
