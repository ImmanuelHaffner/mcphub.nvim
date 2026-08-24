--- Tests for fingerprint enforcement in the strict (production) path.
---
--- These specs call `schema.validate` and `planner.plan` **directly**,
--- without the `bypass_fingerprint` flag. They exercise the contract
--- the LLM-facing tool `mcphub.native.neovim.files.apply_edit.engine.apply(input)` actually presents.
---
--- Every other spec file uses `tests.native.neovim.files.apply_edit.helpers`, which sets
--- `bypass_fingerprint = true`. This file is the dedicated counter-
--- example.
---
--- Run headless:
---   make test

local assert = require("tests.native.neovim.files.apply_edit.busted_assert")

local fingerprint = require("mcphub.native.neovim.files.apply_edit.fingerprint")
local planner = require("mcphub.native.neovim.files.apply_edit.planner")
local schema = require("mcphub.native.neovim.files.apply_edit.schema")

--- Anchor builders (matching the schema's parsed shape).
local function lr(s, e)
    return { by = "line_range", start = s, ["end"] = e }
end

--- Build a minimal valid op. `extra` overrides defaults.
local function op(extra)
    local o = {
        kind = "replace_range",
        path = "/some/file",
        anchor = lr(1, 1),
        content = "NEW",
        indent = "match_anchor",
    }
    for k, v in pairs(extra or {}) do
        o[k] = v
    end
    return o
end

--- Write a tempfile and return its absolute path.
local function write_tempfile(content)
    local tmp = vim.fn.tempname()
    local f = assert(io.open(tmp, "wb"), "tempfile open failed")
    f:write(content)
    f:close()
    return vim.fn.fnamemodify(tmp, ":p")
end

--- Wipe buffer + delete file.
local function cleanup(path)
    local bufnr = vim.fn.bufnr(path)
    if bufnr > 0 then
        pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
    vim.fn.delete(path)
end

--- Find the first error matching a (path, reason) pair, or nil.
local function find_error(errors, p, reason)
    for _, e in ipairs(errors) do
        if e.path == p and (reason == nil or e.reason == reason) then
            return e
        end
    end
    return nil
end

describe("mcphub.native.neovim.files.apply_edit.schema fingerprint enforcement (strict path)", function()
    describe("missing baseline_fingerprint", function()
        it("rejects an op with no baseline_fingerprint", function()
            local ok, errors = schema.validate({
                ops = { op({ baseline_fingerprint = nil }) },
            })
            assert.is_falsy(ok)
            local e = find_error(errors, "ops[0].baseline_fingerprint", schema.ERROR_REASONS.missing_field)
            assert.is_not_nil(e)
        end)

        it("hint mentions neovim__read_with_fingerprint", function()
            local _, errors = schema.validate({
                ops = { op({ baseline_fingerprint = nil }) },
            })
            local e = find_error(errors, "ops[0].baseline_fingerprint")
            assert.is_truthy(e.hint:find("neovim__read_with_fingerprint", 1, true))
        end)

        it("reports the failure per-op (not once globally)", function()
            local _, errors = schema.validate({
                ops = {
                    op({ baseline_fingerprint = nil }),
                    op({ baseline_fingerprint = nil }),
                },
            })
            -- Two failures, one per op.
            assert.is_not_nil(find_error(errors, "ops[0].baseline_fingerprint"))
            assert.is_not_nil(find_error(errors, "ops[1].baseline_fingerprint"))
        end)
    end)

    describe("malformed baseline_fingerprint", function()
        it("rejects a fingerprint that is too short", function()
            local _, errors = schema.validate({
                ops = { op({ baseline_fingerprint = "abc" }) },
            })
            local e = find_error(errors, "ops[0].baseline_fingerprint", schema.ERROR_REASONS.bad_pattern)
            assert.is_not_nil(e)
        end)

        it("rejects a fingerprint that is too long", function()
            local _, errors = schema.validate({
                ops = { op({ baseline_fingerprint = "abcdef01" }) },
            })
            assert.is_not_nil(find_error(errors, "ops[0].baseline_fingerprint", schema.ERROR_REASONS.bad_pattern))
        end)

        it("rejects uppercase hex (vim.fn.sha256 emits lowercase)", function()
            local _, errors = schema.validate({
                ops = { op({ baseline_fingerprint = "ABCDEF0" }) },
            })
            assert.is_not_nil(find_error(errors, "ops[0].baseline_fingerprint", schema.ERROR_REASONS.bad_pattern))
        end)

        it("rejects non-hex characters", function()
            local _, errors = schema.validate({
                ops = { op({ baseline_fingerprint = "abcdefg" }) },
            })
            assert.is_not_nil(find_error(errors, "ops[0].baseline_fingerprint", schema.ERROR_REASONS.bad_pattern))
        end)

        it("rejects a non-string fingerprint", function()
            local _, errors = schema.validate({
                ops = { op({ baseline_fingerprint = 42 }) },
            })
            assert.is_not_nil(find_error(errors, "ops[0].baseline_fingerprint", schema.ERROR_REASONS.bad_pattern))
        end)
    end)

    describe("well-formed baseline_fingerprint passes the schema", function()
        it("accepts an op with a well-formed fingerprint", function()
            -- Schema doesn't compare against live content (that's the
            -- planner's job). It only checks presence + format.
            local ok = schema.validate({
                ops = { op({ baseline_fingerprint = "a3f9d2c" }) },
            })
            assert.is_truthy(ok)
        end)
    end)

    describe("bypass_fingerprint = true (the test-only escape hatch)", function()
        it("skips presence check", function()
            -- This is what `tests.native.neovim.files.apply_edit.helpers` does for every other
            -- spec. Verifying that the bypass actually works.
            local ok = schema.validate({ ops = { op({ baseline_fingerprint = nil }) } }, { bypass_fingerprint = true })
            assert.is_truthy(ok)
        end)

        it("skips format check", function()
            local ok = schema.validate(
                { ops = { op({ baseline_fingerprint = "malformed" }) } },
                { bypass_fingerprint = true }
            )
            assert.is_truthy(ok)
        end)

        it("bypass = false is equivalent to omitting opts (default strict)", function()
            local _, errors = schema.validate(
                { ops = { op({ baseline_fingerprint = nil }) } },
                { bypass_fingerprint = false }
            )
            assert.is_not_nil(find_error(errors, "ops[0].baseline_fingerprint"))
        end)
    end)
end)

describe("mcphub.native.neovim.files.apply_edit.planner fingerprint enforcement (strict path)", function()
    describe("matching fingerprint allows the plan to proceed", function()
        it("a correctly-fingerprinted op resolves anchors and returns a Plan", function()
            local path = write_tempfile("hello\nworld\n")
            -- Read the file through the real FileRecord pipeline so the
            -- fingerprint matches whatever EOL normalisation FileRecord
            -- applies. This is what the LLM gets from
            -- neovim__read_with_fingerprint in production.
            local file_record = require("mcphub.native.neovim.files.apply_edit.file_record")
            local rec = assert(file_record.read(path))
            local fp = fingerprint.compute(rec.content)

            local parsed_input = {
                ops = {
                    {
                        kind = "replace_range",
                        path = path,
                        anchor = lr(1, 1),
                        content = "X",
                        indent = "match_anchor",
                        baseline_fingerprint = fp,
                    },
                },
                contents = {},
                warnings = {},
            }
            local plan, fail = planner.plan(parsed_input)
            assert.is_nil(fail)
            assert.is_not_nil(plan)
            assert.is.equal(1, #plan.located_ops)
            cleanup(path)
        end)
    end)

    describe("stale fingerprint aborts the plan", function()
        it("produces a stale_fingerprint failure with live fingerprint + content", function()
            local path = write_tempfile("original\n")
            local stale = "deadbee" -- guaranteed not to match

            local parsed_input = {
                ops = {
                    {
                        kind = "replace_range",
                        path = path,
                        anchor = lr(1, 1),
                        content = "X",
                        indent = "match_anchor",
                        baseline_fingerprint = stale,
                    },
                },
                contents = {},
                warnings = {},
            }
            local plan, fail = planner.plan(parsed_input)
            assert.is_nil(plan)
            assert.is_not_nil(fail)

            -- Find the stale_fingerprint failure.
            local stale_fail
            for _, f in ipairs(fail.failures) do
                if f.reason == schema.ERROR_REASONS.stale_fingerprint then
                    stale_fail = f
                    break
                end
            end
            assert.is_not_nil(stale_fail)
            assert.is.equal(path, stale_fail.path)
            assert.is.equal(stale, stale_fail.baseline_fingerprint)
            assert.is.equal(fingerprint.compute(stale_fail.live_content), stale_fail.live_fingerprint)
            assert.is_truthy(stale_fail.hint:find("neovim__read_with_fingerprint", 1, true))
            cleanup(path)
        end)

        it("one stale_fingerprint failure per op affected", function()
            local path = write_tempfile("content\n")
            local stale = "deadbee"

            local parsed_input = {
                ops = {
                    {
                        kind = "replace_range",
                        path = path,
                        anchor = lr(1, 1),
                        content = "A",
                        indent = "match_anchor",
                        baseline_fingerprint = stale,
                    },
                    {
                        kind = "replace_range",
                        path = path,
                        anchor = lr(1, 1),
                        content = "B",
                        indent = "match_anchor",
                        baseline_fingerprint = stale,
                    },
                },
                contents = {},
                warnings = {},
            }
            local _, fail = planner.plan(parsed_input)
            local stale_count = 0
            for _, f in ipairs(fail.failures) do
                if f.reason == schema.ERROR_REASONS.stale_fingerprint then
                    stale_count = stale_count + 1
                end
            end
            assert.is.equal(2, stale_count)
            cleanup(path)
        end)

        it("stale fingerprints inhibit range conflict detection", function()
            -- Two ops both touch line 1 (would conflict on conflict-detection),
            -- but both have stale fingerprints. We expect stale_fingerprint
            -- failures and NO range_conflict failure, because the resolved
            -- ranges are based on bytes the LLM didn't see.
            local path = write_tempfile("content\n")
            local stale = "deadbee"

            local parsed_input = {
                ops = {
                    {
                        kind = "replace_range",
                        path = path,
                        anchor = lr(1, 1),
                        content = "A",
                        indent = "match_anchor",
                        baseline_fingerprint = stale,
                    },
                    {
                        kind = "replace_range",
                        path = path,
                        anchor = lr(1, 1),
                        content = "B",
                        indent = "match_anchor",
                        baseline_fingerprint = stale,
                    },
                },
                contents = {},
                warnings = {},
            }
            local _, fail = planner.plan(parsed_input)
            for _, f in ipairs(fail.failures) do
                assert.is_truthy(f.reason ~= schema.ERROR_REASONS.range_conflict)
            end
            cleanup(path)
        end)
    end)

    describe("bypass_fingerprint = true skips planner enforcement", function()
        it("accepts a parsed op with no baseline_fingerprint", function()
            local path = write_tempfile("content\n")

            local parsed_input = {
                ops = {
                    {
                        kind = "replace_range",
                        path = path,
                        anchor = lr(1, 1),
                        content = "X",
                        indent = "match_anchor",
                        -- no baseline_fingerprint
                    },
                },
                contents = {},
                warnings = {},
            }
            local plan, fail = planner.plan(parsed_input, { bypass_fingerprint = true })
            assert.is_nil(fail)
            assert.is_not_nil(plan)
            cleanup(path)
        end)

        it("bypass = false is equivalent to omitting opts (default strict)", function()
            local path = write_tempfile("content\n")

            local parsed_input = {
                ops = {
                    {
                        kind = "replace_range",
                        path = path,
                        anchor = lr(1, 1),
                        content = "X",
                        indent = "match_anchor",
                        baseline_fingerprint = "deadbee", -- stale
                    },
                },
                contents = {},
                warnings = {},
            }
            local _, fail = planner.plan(parsed_input, { bypass_fingerprint = false })
            local stale = false
            for _, f in ipairs(fail.failures) do
                if f.reason == schema.ERROR_REASONS.stale_fingerprint then
                    stale = true
                end
            end
            assert.is_truthy(stale)
            cleanup(path)
        end)
    end)
end)
