--- Synthetic `drive_file` implementations for applier specs.
---
--- The real driver — `mcphub.native.neovim.files.apply_edit.ui_backend.drive_file` — depends on
--- mcphub's `EditUI` and is callback-driven through `vim.schedule`, making
--- it awkward for unit tests of the applier. The applier's `drive_file`
--- contract (see `mcphub.native.neovim.files.apply_edit.applier.apply_plan`) is small enough that we can
--- supply minimal synthetic implementations here:
---
---   * `accept_all` — applies every block to the buffer, writes the file,
---     and reports every block as `'accepted'`. Mirrors the headless
---     `interactive = false` path of `EditUI`.
---   * `reject_all` — does not touch the buffer, does not write, and reports
---     every block as `'rejected'`. Mirrors what a user would see after
---     pressing `gr` on every hunk in interactive `EditUI`.
---   * `make_selective(decisions)` — factory that returns a driver applying
---     only the accepted blocks. Caller supplies `{ [block_id|op_index] =
---     'accept'|'reject' }`. The mixed acceptance path is where the
---     applier's `classify_outcome` does its most interesting work.
---   * `accept_all_ascending` — like `accept_all`, but applies blocks the
---     way mcphub's `EditUI:_apply_all_changes` does (ascending sort +
---     running line offset) instead of bottom-up. Used to pin that the
---     two traversals agree byte-for-byte on net-line-delta batches.
---   * `cancel_at(file_path)` — factory returning a driver that reports
---     `status = 'cancelled'` for one specific file. Useful for testing
---     the `not_attempted` cascade.
---
--- ## Scope of these mocks
---
--- They test the **applier's reaction** to outcome shapes, not mcphub's
--- production of those outcomes. We rely on the real-EditUI smoke (run
--- manually) to verify mcphub honours the `LocatedBlock` contract on the
--- reject path. If you suspect a regression in mcphub's `_reject_current_hunk`
--- against our shape, that's a smoke-test concern, not a unit-test one.
---
--- These drivers are **non-interactive** by construction: they apply blocks
--- synchronously inside their request handler, then invoke `file_cb` via
--- `vim.schedule` so that the applier's sequencing — which assumes the
--- callback fires from a scheduled context — sees the same timing it
--- gets from the production driver.
---
--- @module "tests.native.neovim.files.apply_edit.drivers"

local M = {}

--- Apply a list of blocks to a buffer in bottom-up order. Within a single
--- file, applying ranges from highest `start_line` to lowest means earlier
--- blocks' line numbers are unaffected by later mutations — no offset
--- bookkeeping needed.
---
--- @param bufnr  integer
--- @param blocks mcphub.edit.applier.Block[]
local function apply_blocks(bufnr, blocks)
    -- Sort a shallow copy descending by start_line. For zero-width insertions
    -- (end_line < start_line), `start_line` is still the insertion point —
    -- ordering by it works the same way.
    local ordered = {}
    for i, b in ipairs(blocks) do
        ordered[i] = b
    end
    table.sort(ordered, function(a, b)
        return a.range.start_line > b.range.start_line
    end)
    for _, b in ipairs(ordered) do
        local s, e = b.range.start_line, b.range.end_line
        local start_0, end_excl
        if e < s then
            -- Zero-width position { s, s-1 }: insert at line s.
            start_0, end_excl = s - 1, s - 1
        else
            start_0, end_excl = s - 1, e
        end
        vim.api.nvim_buf_set_lines(bufnr, start_0, end_excl, false, b.replace_lines)
    end
end

--- Apply blocks the way mcphub's `EditUI:_apply_all_changes` does: sort
--- **ascending** by `start_line`, apply top-down, and carry a running
--- `base_line_offset` so each block's planner (pre-edit) line numbers are
--- shifted by the net line delta of every block applied before it.
---
--- This is deliberately the *opposite* traversal of `apply_blocks` above
--- (which goes bottom-up and needs no offset). It exists to pin the
--- assumption that mcphub's offset-compensation strategy produces a
--- byte-identical result to the bottom-up strategy — i.e. that a batch of
--- ops with a net line-count change does not drift later ops. We reproduce
--- mcphub's algorithm here rather than import `EditUI` so the spec stays
--- inside the `tests/native/neovim/files/apply_edit/` module boundary (no mcphub imports). If this
--- ever diverges from `edit_ui.lua:_apply_all_changes`, the real-EditUI
--- smoke is the backstop.
---
--- @param bufnr  integer
--- @param blocks mcphub.edit.applier.Block[]
local function apply_blocks_ascending_with_offset(bufnr, blocks)
    local ordered = {}
    for i, b in ipairs(blocks) do
        ordered[i] = b
    end
    table.sort(ordered, function(a, b)
        return a.range.start_line < b.range.start_line
    end)

    local base_line_offset = 0
    for _, b in ipairs(ordered) do
        local s, e = b.range.start_line, b.range.end_line
        local start_0, end_excl, original_span
        if e < s then
            -- Zero-width position { s, s-1 }: insert at line s, spans 0 lines.
            start_0, end_excl, original_span = s - 1, s - 1, 0
        else
            start_0, end_excl, original_span = s - 1, e, e - s + 1
        end
        start_0 = start_0 + base_line_offset
        end_excl = end_excl + base_line_offset
        vim.api.nvim_buf_set_lines(bufnr, start_0, end_excl, false, b.replace_lines)
        base_line_offset = base_line_offset + (#b.replace_lines - original_span)
    end
end

--- Ascending-with-offset synthetic driver. Conforms to the `drive_file`
--- contract. Identical to `accept_all` except it applies blocks via
--- `apply_blocks_ascending_with_offset` (mirroring mcphub's traversal)
--- rather than the bottom-up `apply_blocks`. Reports every block as
--- `'accepted'`.
---
--- @param request mcphub.edit.applier.FileRequest
--- @param file_cb fun(outcome: mcphub.edit.applier.FileOutcome)
function M.accept_all_ascending(request, file_cb)
    local ok, err = pcall(function()
        apply_blocks_ascending_with_offset(request.bufnr, request.blocks)
        if vim.bo[request.bufnr].modified then
            vim.api.nvim_buf_call(request.bufnr, function()
                vim.cmd.write({ args = { request.file_path }, mods = { silent = true } })
            end)
        end
    end)

    local per_block = {}
    if ok then
        for _, b in ipairs(request.blocks) do
            per_block[b.block_id] = "accepted"
        end
    end

    vim.schedule(function()
        if ok then
            file_cb({
                status = "completed",
                per_block = per_block,
                ui_summary = string.format(
                    "accept_all_ascending: applied %d block(s) to %s",
                    #request.blocks,
                    request.file_path
                ),
            })
        else
            file_cb({
                status = "cancelled",
                cancel_reason = "accept_all_ascending driver failed: " .. tostring(err),
                per_block = {},
            })
        end
    end)
end

--- Accept-all synthetic driver. Conforms to the `drive_file` contract from
--- `mcphub.native.neovim.files.apply_edit.applier.apply_plan`.
---
--- Applies every block in the request's buffer, writes the file, and reports
--- `status = 'completed'` with `per_block[block_id] = 'accepted'` for every
--- block. Errors during apply/write surface as `status = 'cancelled'` with
--- `cancel_reason` carrying the message — that path is unlikely in practice
--- (the planner has already validated the buffer and ranges) but it keeps
--- the contract well-defined.
---
--- @param request mcphub.edit.applier.FileRequest
--- @param file_cb fun(outcome: mcphub.edit.applier.FileOutcome)
function M.accept_all(request, file_cb)
    local ok, err = pcall(function()
        apply_blocks(request.bufnr, request.blocks)
        -- Mirror EditUI:write_if_modified — write only if modified.
        if vim.bo[request.bufnr].modified then
            vim.api.nvim_buf_call(request.bufnr, function()
                vim.cmd.write({ args = { request.file_path }, mods = { silent = true } })
            end)
        end
    end)

    local per_block = {}
    if ok then
        for _, b in ipairs(request.blocks) do
            per_block[b.block_id] = "accepted"
        end
    end

    -- Schedule the callback so the applier's sequencing sees the same
    -- "fires under vim.schedule" timing as the production driver.
    vim.schedule(function()
        if ok then
            file_cb({
                status = "completed",
                per_block = per_block,
                ui_summary = string.format("accept_all: applied %d block(s) to %s", #request.blocks, request.file_path),
            })
        else
            file_cb({
                status = "cancelled",
                cancel_reason = "accept_all driver failed: " .. tostring(err),
                per_block = {},
            })
        end
    end)
end

--- Reject-all synthetic driver. Conforms to the `drive_file` contract.
---
--- Does **not** modify the buffer and does **not** write. Reports
--- `status = 'completed'` with `per_block[block_id] = 'rejected'` for every
--- block — the applier translates these into `rejected[]` response entries
--- with `reason = 'rejected'`.
---
--- The `status` is `'completed'`, not `'cancelled'`, because the user
--- did review every hunk; they just chose to reject each one. From the
--- applier's perspective the file's session ran to completion.
---
--- @param request mcphub.edit.applier.FileRequest
--- @param file_cb fun(outcome: mcphub.edit.applier.FileOutcome)
function M.reject_all(request, file_cb)
    local per_block = {}
    for _, b in ipairs(request.blocks) do
        per_block[b.block_id] = "rejected"
    end
    vim.schedule(function()
        file_cb({
            status = "completed",
            per_block = per_block,
            ui_summary = string.format("reject_all: rejected %d block(s) in %s", #request.blocks, request.file_path),
        })
    end)
end

--- Build a driver that applies blocks selectively based on caller decisions.
---
--- `decisions` maps either `block_id` (string) or `op_index` (integer) to
--- the string `'accept'`, `'reject'`, or `'partial'`. A block missing from
--- the map defaults to `'accept'` so omitting an entry behaves like
--- `accept_all` for that block.
---
--- Both keying flavours coexist — `block_id` takes precedence when both
--- are present. The op_index form is convenient for one-range-per-op
--- batches (the common case) where the block_id `opN_r1` is just noise.
---
--- ## Status semantics
---
---   * `'accept'`   → apply the block, mark `per_block[block_id] = 'accepted'`.
---   * `'reject'`   → do not apply, mark `per_block[block_id] = 'rejected'`.
---   * `'partial'`  → do not apply, mark `per_block[block_id] = 'partial'`.
---                     The applier surfaces this as `rejected[]` with
---                     `reason = 'partially_rejected'`. Useful for testing
---                     the multi-hunk-per-block partial-acceptance path
---                     without actually splitting into sub-hunks.
---
--- @param decisions table<string|integer, 'accept'|'reject'|'partial'>
--- @return fun(request: mcphub.edit.applier.FileRequest, file_cb: fun(outcome: mcphub.edit.applier.FileOutcome))
function M.make_selective(decisions)
    return function(request, file_cb)
        local accepted = {} -- blocks to actually apply
        local per_block = {}

        for _, b in ipairs(request.blocks) do
            local decision = decisions[b.block_id] or decisions[b.op_index] or "accept"
            if decision == "accept" then
                accepted[#accepted + 1] = b
                per_block[b.block_id] = "accepted"
            elseif decision == "reject" then
                per_block[b.block_id] = "rejected"
            elseif decision == "partial" then
                per_block[b.block_id] = "partial"
            else
                error("make_selective: unknown decision " .. tostring(decision) .. " for block " .. b.block_id)
            end
        end

        local ok, err = pcall(function()
            if #accepted > 0 then
                apply_blocks(request.bufnr, accepted)
                if vim.bo[request.bufnr].modified then
                    vim.api.nvim_buf_call(request.bufnr, function()
                        vim.cmd.write({ args = { request.file_path }, mods = { silent = true } })
                    end)
                end
            end
        end)

        vim.schedule(function()
            if ok then
                file_cb({
                    status = "completed",
                    per_block = per_block,
                    ui_summary = string.format(
                        "make_selective: applied %d / rejected %d in %s",
                        #accepted,
                        #request.blocks - #accepted,
                        request.file_path
                    ),
                })
            else
                file_cb({
                    status = "cancelled",
                    cancel_reason = "make_selective driver failed: " .. tostring(err),
                    per_block = {},
                })
            end
        end)
    end
end

--- Build a driver that cancels at a specific file path. Files reached
--- before the cancel are passed through to `accept_all`; the named file
--- triggers `status = 'cancelled'`. Subsequent files are not driven
--- (the applier emits `not_attempted` entries for them).
---
--- @param cancel_path string  File path to cancel at.
--- @return fun(request: mcphub.edit.applier.FileRequest, file_cb: fun(outcome: mcphub.edit.applier.FileOutcome))
function M.cancel_at(cancel_path)
    return function(request, file_cb)
        if request.file_path == cancel_path then
            vim.schedule(function()
                file_cb({
                    status = "cancelled",
                    cancel_reason = "cancel_at: user cancelled at " .. cancel_path,
                    per_block = {},
                })
            end)
        else
            return M.accept_all(request, file_cb)
        end
    end
end

return M
