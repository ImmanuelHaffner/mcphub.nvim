--- Tests for `apply_edit`'s user-configuration seam
--- (`State.config.builtin_tools.apply_edit`).
---
--- Two layers, because the config crosses two boundaries:
---
---   1. `ui_backend._test.resolve_config` — normalisation in isolation: what a
---      nil or partial table becomes, and in particular that `lsp_wait_ms`
---      entries are merged *over* the curated per-client table rather than
---      replacing it. Losing the curated ceilings because you tuned one client
---      would be a silent latency/correctness regression.
---   2. `drive_file` → `EditUI.new` — that the `ui` sub-table actually reaches
---      the review UI. This is the half a user notices: before it was wired,
---      `apply_edit` always used `EditUI`'s hardcoded defaults, so rebinding the
---      review keys took effect for `edit_file` and silently did nothing here.
---
--- The integration cases spy on `edit_ui.new` — capturing the argument, then
--- delegating to the real constructor — rather than stubbing the module, so the
--- rest of the flow is genuinely exercised. They run with
--- `interactive = false`, where no keymaps are installed at all, which is why
--- the assertion is on the constructor argument and not on `maparg`.
---
--- @module "tests.native.neovim.files.apply_edit.test_ui_backend_config"

local applier = require("mcphub.native.neovim.files.apply_edit.applier")
local assert = require("tests.native.neovim.files.apply_edit.busted_assert")
local edit_ui = require("mcphub.native.neovim.files.edit_file.edit_ui")
local fingerprint = require("mcphub.native.neovim.files.apply_edit.fingerprint")
local planner = require("mcphub.native.neovim.files.apply_edit.planner")
local schema = require("mcphub.native.neovim.files.apply_edit.schema")
local ui_backend = require("mcphub.native.neovim.files.apply_edit.ui_backend")

local resolve_config = ui_backend._test.resolve_config

--- Write a tempfile, load it into a buffer, and compute the baseline
--- fingerprint the same way the engine does. Same helper as
--- `test_widen_conflict.lua`.
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

--- Run `fn` with Vim's messages suppressed. `EditUI` saves through
--- `vim.cmd.write`, whose file-info message would otherwise land inside
--- MiniTest's one-character-per-case progress line. See the long note in
--- `test_widen_conflict.lua` for why `:silent` is the only mechanism and why
--- the window must cover the whole body.
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

--- Drive `input` through schema → planner → applier → `ui_backend.drive_file`
--- with the given `config`, while spying on `EditUI.new`.
---
--- @param input table                        the apply_edit request
--- @param config MCPHub.ApplyEditConfig|nil   passed to `drive_file` verbatim
--- @return table response      the applier's response
--- @return table|nil captured  the table `EditUI.new` was called with
local function run_with_config(input, config)
    local response, captured
    local real_new = edit_ui.new
    edit_ui.new = function(cfg)
        captured = vim.deepcopy(cfg)
        return real_new(cfg)
    end
    local ok, err = pcall(silently, function()
        local valid, parsed_or_errors = schema.validate(input)
        assert(valid, "schema validation failed: " .. vim.inspect(parsed_or_errors))
        local plan, plan_fail = planner.plan(parsed_or_errors)
        assert(plan, "planner failed: " .. vim.inspect(plan_fail))

        local driver = function(request, file_cb)
            return ui_backend.drive_file(request, file_cb, config)
        end
        applier.apply_plan(plan, { interactive = false }, driver, function(r)
            response = r
        end)
        local completed = vim.wait(500, function()
            return response ~= nil
        end, 5)
        assert(completed, "apply did not complete within 500ms")
    end)
    -- Restore before propagating, so one failure cannot poison later cases.
    edit_ui.new = real_new
    if not ok then
        error(err, 0)
    end
    return response, captured
end

--- A single-op request replacing line 2 of the fixture.
local function replace_line_2(path, fp, content)
    return {
        ops = {
            {
                kind = "replace_range",
                path = path,
                baseline_fingerprint = fp,
                anchor = { by = "line_range", start = 2, ["end"] = 2 },
                content = content,
                indent = "preserve",
            },
        },
    }
end

describe("resolve_config", function()
    it("falls back to the module defaults when given nil", function()
        local cfg = resolve_config(nil)
        assert.is.equal(cfg.default_lsp_wait_ms, ui_backend._test.DEFAULT_LSP_WAIT_MS)
        assert.is.equal(cfg.diagnostic_context_lines, ui_backend._test.DEFAULT_DIAGNOSTIC_CONTEXT_LINES)
        assert.is.equal(next(cfg.ui), nil)
    end)

    it("falls back to the module defaults when given an empty table", function()
        local cfg = resolve_config({})
        assert.is.equal(cfg.default_lsp_wait_ms, ui_backend._test.DEFAULT_LSP_WAIT_MS)
        assert.is.equal(cfg.diagnostic_context_lines, ui_backend._test.DEFAULT_DIAGNOSTIC_CONTEXT_LINES)
    end)

    it("starts from the curated per-client table", function()
        local cfg = resolve_config(nil)
        assert.are.same(cfg.lsp_wait_ms, ui_backend.LSP_WAIT_MS)
    end)

    it("merges lsp_wait_ms overrides over the curated table", function()
        local curated_lua_ls = ui_backend.LSP_WAIT_MS.lua_ls
        local cfg = resolve_config({ lsp_wait_ms = { some_exotic_ls = 4242 } })
        -- The override lands...
        assert.is.equal(cfg.lsp_wait_ms.some_exotic_ls, 4242)
        -- ...and every curated entry survives it.
        assert.is.equal(cfg.lsp_wait_ms.lua_ls, curated_lua_ls)
    end)

    it("does not mutate the curated table when merging", function()
        local before = ui_backend.LSP_WAIT_MS.some_exotic_ls
        resolve_config({ lsp_wait_ms = { some_exotic_ls = 4242 } })
        assert.is.equal(ui_backend.LSP_WAIT_MS.some_exotic_ls, before)
    end)

    it("honours scalar overrides", function()
        local cfg = resolve_config({ default_lsp_wait_ms = 250, diagnostic_context_lines = 3 })
        assert.is.equal(cfg.default_lsp_wait_ms, 250)
        assert.is.equal(cfg.diagnostic_context_lines, 3)
    end)

    it("passes the ui sub-table through untouched", function()
        local ui = { auto_navigate = false, keybindings = { accept = "<Tab>" } }
        local cfg = resolve_config({ ui = ui })
        assert.are.same(cfg.ui, ui)
    end)
end)

describe("drive_file config delivery", function()
    it("hands the configured ui table to EditUI", function()
        local path, bufnr, fp = fixture_file({ "A", "B", "C" }, "_cfg_ui.txt")
        local config = {
            ui = { auto_navigate = false, keybindings = { accept = "<Tab>", reject_all = "<C-r>" } },
        }

        local response, captured = run_with_config(replace_line_2(path, fp, "B2"), config)

        assert(captured ~= nil, "EditUI.new was never called")
        assert.is.equal(captured.keybindings.accept, "<Tab>")
        assert.is.equal(captured.keybindings.reject_all, "<C-r>")
        assert.is.equal(captured.auto_navigate, false)
        -- The edit still went through with the custom config in place.
        assert.is.equal(response.status, "applied")
        assert.are.same(vim.fn.readfile(path), { "A", "B2", "C" })

        cleanup_fixture(path, bufnr)
    end)

    it("hands EditUI an empty table when no config is supplied", function()
        local path, bufnr, fp = fixture_file({ "A", "B", "C" }, "_cfg_none.txt")

        local response, captured = run_with_config(replace_line_2(path, fp, "B2"), nil)

        assert(captured ~= nil, "EditUI.new was never called")
        -- Empty means "EditUI, use all your own defaults", which is what the
        -- two-argument `drive_file(request, file_cb)` form must keep doing.
        assert.is.equal(next(captured), nil)
        assert.is.equal(response.status, "applied")

        cleanup_fixture(path, bufnr)
    end)

    it("hands EditUI an empty table when the config omits ui", function()
        local path, bufnr, fp = fixture_file({ "A", "B", "C" }, "_cfg_no_ui.txt")

        local _, captured = run_with_config(replace_line_2(path, fp, "B2"), { default_lsp_wait_ms = 0 })

        assert(captured ~= nil, "EditUI.new was never called")
        assert.is.equal(next(captured), nil)

        cleanup_fixture(path, bufnr)
    end)
end)
