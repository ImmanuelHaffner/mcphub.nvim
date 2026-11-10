--- Regression tests for the range conflicts that widening introduces.
---
--- # The issue these specs pin
---
--- `ui_backend._test.widen_for_editui` widens a pure delete or a pure insert
--- by borrowing a neighbouring line, and a delete-to-EOF borrows the line
--- **before** the deleted range. If another op in the same batch targets that
--- borrowed line, the planner's no-conflict invariant — which held over the
--- original (unwidened) ranges — would silently break at the EditUI seam:
---
---   * Op A: replace_range on line N         (planner range { N, N })
---   * Op B: delete_range on line N+1 (last) (planner range { N+1, N+1 })
---
--- After widening, op B would become `{ N, N+1 }` with `replace_lines =
--- [buf[N]]`, the line op A is already replacing, and EditUI's ascending sort
--- would apply B after A, undoing A.
---
--- # What prevents it
---
--- The applier joins touching ops (A and B above) into one block, which needs
--- no widening. Ops one line apart can still collide once widened, as when an
--- insertion before line N borrows N forward and a delete-to-EOF from N+1
--- borrows N backward; `drive_file` joins those too, keeping line N. Only a
--- block with no line to borrow at all is refused, as a `precondition_failed`
--- outcome with one `range_conflict` failure per op and no mutation.
---
--- # Why this lives in its own file
---
--- It isn't testing `widen_for_editui` in isolation (that's
--- `tests/native/neovim/files/apply_edit/test_ui_backend.lua`) and it isn't a
--- general e2e flow (that's `tests/native/neovim/files/apply_edit/test_e2e.lua`, which uses the
--- synthetic accept_all driver and so doesn't exercise widening at
--- all). It is specifically about the conflict the widening introduces
--- at the EditUI seam — a category of its own.
---
--- @module "tests.native.neovim.files.apply_edit.test_widen_conflict"

-- The positive-control case drives the applier all the way through EditUI in
-- headless `interactive = false` mode, which transitively requires the sibling
-- `edit_file.edit_ui` module. In-tree that needs no runtimepath search: the repo
-- itself is on `rtp` (see `scripts/minimal_init.lua`), so a plain `require`
-- resolves. This spec used to locate mcphub through lazy.nvim's data directory,
-- which is precisely the cross-plugin coupling that moving in-tree removed.
local assert = require("tests.native.neovim.files.apply_edit.busted_assert")

local applier = require("mcphub.native.neovim.files.apply_edit.applier")
local fingerprint = require("mcphub.native.neovim.files.apply_edit.fingerprint")
local planner = require("mcphub.native.neovim.files.apply_edit.planner")
local schema = require("mcphub.native.neovim.files.apply_edit.schema")
local ui_backend = require("mcphub.native.neovim.files.apply_edit.ui_backend")

--- Same fixture helper as `test_e2e.lua` — write a tempfile, load into a
--- buffer, compute the baseline fingerprint the same way the engine does.
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

--- Drive the input through schema → planner → applier → ui_backend with
--- `interactive = false`, mirroring `mcphub.native.neovim.files.apply_edit.engine.apply` but bypassing the
--- LLM-facing seal so we can pass `opts.interactive = false`. Returns the
--- response synchronously after waiting on the async on_complete chain.
---
--- EditUI fires `on_complete` via `vim.schedule`, plus `get_summary` is
--- itself async (it waits up to `wait_for_diagnostics` ms). Our ui_backend
--- sets `wait_for_diagnostics = 0`, so the total async budget is one
--- scheduler tick per file. 500 ms is plenty of headroom.
--- Run `fn` with Vim's messages suppressed.
---
--- EditUI saves through `vim.cmd.write`, which prints `"<file>" 3L, 10B written`.
--- Headless, that lands in the middle of MiniTest's one-character-per-case
--- progress line. No `shortmess` flag removes it — `W` only drops the word
--- "written" and leaves the file info — so `:silent` is the only mechanism, and it
--- still writes the file.
---
--- The save happens on a scheduler tick inside the `vim.wait` below rather than
--- during `apply_plan`, so the silent window has to cover the whole body:
--- `msg_silent` stays set for the duration of the `:lua` command, including the
--- event processing `vim.wait` performs inside it. The thunk must be a global
--- because a `:lua` chunk sees only globals.
---
--- The synthetic drivers in `drivers.lua` avoid this by passing
--- `mods = { silent = true }` to their own writes. We cannot, because the write
--- here is EditUI's.
local function silently(fn)
    _G.__apply_edit_silent_thunk = fn
    local ok, err = pcall(
        vim.api.nvim_cmd,
        { cmd = "lua", args = { "_G.__apply_edit_silent_thunk()" }, mods = { silent = true } },
        {}
    )
    _G.__apply_edit_silent_thunk = nil
    if not ok then
        error(err, 0)
    end
end

local function run(input)
    local response
    silently(function()
        local ok, parsed_or_errors = schema.validate(input)
        assert(ok, "schema validation failed: " .. vim.inspect(parsed_or_errors))
        local plan, plan_fail = planner.plan(parsed_or_errors)
        assert(plan, "planner failed: " .. vim.inspect(plan_fail))

        applier.apply_plan(plan, { interactive = false }, ui_backend.drive_file, function(r)
            response = r
        end)
        -- Named `completed` rather than `ok` so it does not shadow the validate
        -- result above.
        local completed = vim.wait(500, function()
            return response ~= nil
        end, 5)
        assert(completed, "apply did not complete within 500ms")
    end)
    return response
end

local function lr(s, e)
    return { by = "line_range", start = s, ["end"] = e }
end

describe("widen-introduced range conflict", function()
    it("applies a replace next to a delete-to-EOF as one joined block", function()
        local path, bufnr, fp = fixture_file({ "A", "B", "C" }, "_widen_joined.txt")

        local response = run({
            ops = {
                {
                    kind = "replace_range",
                    path = path,
                    baseline_fingerprint = fp,
                    anchor = lr(2, 2),
                    content = "B-NEW",
                    indent = "match_anchor",
                },
                { kind = "delete_range", path = path, baseline_fingerprint = fp, anchor = lr(3, 3) },
            },
        })

        assert.is.equal("applied", response.status)
        assert.is.equal(2, #response.applied)
        assert.are.same({ "A", "B-NEW" }, vim.fn.readfile(path))

        cleanup_fixture(path, bufnr)
    end)

    it("joins an insert and a delete-to-EOF that would borrow the same line", function()
        -- The insert before line 2 borrows line 2 forward; deleting line 3,
        -- the last, borrows line 2 backward. Neither op touches line 2.
        local path, bufnr, fp = fixture_file({ "A", "B", "C" }, "_widen_gap.txt")

        local response = run({
            ops = {
                {
                    kind = "insert",
                    path = path,
                    baseline_fingerprint = fp,
                    anchor = { by = "before", of = lr(2, 2) },
                    content = "X",
                    indent = "preserve",
                },
                { kind = "delete_range", path = path, baseline_fingerprint = fp, anchor = lr(3, 3) },
            },
        })

        assert.is.equal("applied", response.status)
        assert.is.equal(2, #response.applied)
        assert.are.same({ "A", "X", "B" }, vim.fn.readfile(path))

        cleanup_fixture(path, bufnr)
    end)

    it("refuses deleting every line in touching ops, naming each op", function()
        local path, bufnr, fp = fixture_file({ "A", "B" }, "_widen_whole.txt")

        local response = run({
            ops = {
                { kind = "delete_range", path = path, baseline_fingerprint = fp, anchor = lr(1, 1) },
                { kind = "delete_range", path = path, baseline_fingerprint = fp, anchor = lr(2, 2) },
            },
        })

        assert.is.equal("failed", response.status)
        assert.is.equal(0, #response.applied)
        assert.is.equal(2, #response.failed)
        for i, f in ipairs(response.failed) do
            assert.is.equal(i, f.op_index)
            assert.is.equal("range_conflict", f.reason)
            assert.are.same({ start_line = i, end_line = i }, f.range)
        end

        -- No mutation: the refusal exists to preserve this.
        assert.is.equal(false, vim.bo[bufnr].modified)
        assert.are.same({ "A", "B" }, vim.fn.readfile(path))

        cleanup_fixture(path, bufnr)
    end)

    it("accepts a non-colliding mix of replace and delete-to-EOF", function()
        -- Negative control: same fixture, but the delete targets a non-
        -- adjacent line. Op 1 replaces line 2; op 2 deletes line 4
        -- (last). Op 2 widens to {3, 4} with replace = [line_3] — line 3
        -- doesn't overlap with op 1's {2, 2}, so no conflict.
        local path, bufnr, fp = fixture_file({ "A", "B", "C", "D" }, "_widen_ok.txt")

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
                {
                    kind = "delete_range",
                    path = path,
                    baseline_fingerprint = fp,
                    anchor = { by = "line_range", start = 4, ["end"] = 4 },
                },
            },
        })

        assert.is.equal("applied", response.status)
        assert.is.equal(2, #response.applied)
        assert.is.equal(0, #response.failed)

        local on_disk = vim.fn.readfile(path)
        assert.is.equal(3, #on_disk)
        assert.is.equal("A", on_disk[1])
        assert.is.equal("B-NEW", on_disk[2])
        assert.is.equal("C", on_disk[3])

        cleanup_fixture(path, bufnr)
    end)
end)
