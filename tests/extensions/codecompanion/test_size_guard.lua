-- Tests for mcphub.extensions.codecompanion.size_guard — every configuration
-- option, the skip policy, and the effect on a tool result.
--
-- Run with `make test`, or just this file with
-- `make test_file FILE=tests/extensions/codecompanion/test_size_guard.lua`.
local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local guard = require("mcphub.extensions.codecompanion.size_guard")
local spill = require("mcphub.utils.spill")

--- Per-case scratch spill directory.
local dir

--- Configure the guard for a case. `gc = false` by default so no case leaves a
--- background timer or a deferred sweep behind; one dedicated group covers GC.
local function setup(opts)
    opts = vim.tbl_extend("force", { dir = dir, gc = false }, opts or {})
    guard.setup(opts)
end

--- A result table shaped like a parsed MCP response.
local function result_of(text)
    return { text = text, images = {} }
end

--- Text that trips the default byte budget.
local function oversized()
    return string.rep("x", spill.DEFAULT_MAX_BYTES + 1)
end

local T = new_set({
    hooks = {
        pre_case = function()
            dir = vim.fn.tempname()
            vim.fn.mkdir(dir, "p")
        end,
        post_case = function()
            guard.reset()
            vim.fn.delete(dir, "rf")
            dir = nil
        end,
    },
})

--------------------------------------------------------------------------------
T["defaults"] = new_set()

T["defaults"]["are enabled"] = function()
    setup()
    eq(guard.get_config().enabled, true)
end

T["defaults"]["carry a 20k token budget"] = function()
    setup()
    eq(guard.DEFAULT_MAX_TOKENS, 20000)
    eq(guard.get_config().max_tokens, 20000)
end

T["defaults"]["leave byte and line budgets to the spill defaults"] = function()
    setup()
    local config = guard.get_config()
    eq(config.max_bytes, nil)
    eq(config.max_lines, nil)
end

T["defaults"]["skip exactly the seven contract-bearing native tools"] = function()
    eq(guard.DEFAULT_SKIP, {
        "neovim__apply_edit",
        "neovim__delete_items",
        "neovim__edit_file",
        "neovim__list_directory",
        "neovim__move_item",
        "neovim__read_with_fingerprint",
        "neovim__write_file",
    })
end

--------------------------------------------------------------------------------
T["enabled"] = new_set()

T["enabled"]["false leaves oversized text untouched"] = function()
    setup({ enabled = false })
    local result = result_of(oversized())
    local spilled = guard.apply(result, { server_name = "neovim", tool_name = "execute_command" })
    eq(spilled, false)
    eq(#result.text, spill.DEFAULT_MAX_BYTES + 1)
end

T["enabled"]["defaults to on when unset"] = function()
    setup({ enabled = nil })
    eq(guard.get_config().enabled, true)
end

T["enabled"]["an unconfigured guard is inert"] = function()
    guard.reset()
    local result = result_of(oversized())
    eq(guard.apply(result, { server_name = "neovim", tool_name = "execute_command" }), false)
    eq(#result.text, spill.DEFAULT_MAX_BYTES + 1)
end

--------------------------------------------------------------------------------
T["skip policy"] = new_set()

T["skip policy"]["skips every default entry"] = function()
    setup()
    for _, name in ipairs(guard.DEFAULT_SKIP) do
        local tool = name:gsub("^neovim__", "")
        eq(guard.is_skipped("neovim", tool), true)
    end
end

T["skip policy"]["guards the tools deliberately left out"] = function()
    setup()
    for _, tool in ipairs({
        "execute_command",
        "execute_lua",
        "read_file",
        "read_multiple_files",
        "find_files",
    }) do
        eq(guard.is_skipped("neovim", tool), false)
    end
end

T["skip policy"]["treats the user list as additive"] = function()
    setup({ skip = { "other__huge_tool" } })
    eq(guard.is_skipped("other", "huge_tool"), true)
    -- The correctness-critical default survives a user-supplied list.
    eq(guard.is_skipped("neovim", "read_with_fingerprint"), true)
end

T["skip policy"]["skip_defaults = false drops the built-ins"] = function()
    setup({ skip = { "other__huge_tool" }, skip_defaults = false })
    eq(guard.is_skipped("other", "huge_tool"), true)
    eq(guard.is_skipped("neovim", "read_with_fingerprint"), false)
end

T["skip policy"]["a server-qualified entry is scoped to that server"] = function()
    setup({ skip = { "alpha__shared_name" }, skip_defaults = false })
    eq(guard.is_skipped("alpha", "shared_name"), true)
    eq(guard.is_skipped("beta", "shared_name"), false)
end

T["skip policy"]["a bare entry applies to every server"] = function()
    setup({ skip = { "shared_name" }, skip_defaults = false })
    eq(guard.is_skipped("alpha", "shared_name"), true)
    eq(guard.is_skipped("beta", "shared_name"), true)
end

T["skip policy"]["matches resource URIs too"] = function()
    setup({ skip = { "neovim://buffer" }, skip_defaults = false })
    eq(guard.is_skipped("neovim", "neovim://buffer"), true)
end

T["skip policy"]["tolerates a missing name or server"] = function()
    setup()
    eq(guard.is_skipped("neovim", nil), false)
    eq(guard.is_skipped("neovim", ""), false)
    -- A server-qualified entry cannot match when the server is unknown, so the
    -- result is guarded rather than skipped. Unreachable in practice: every call
    -- site takes the name from `parsed_params.server_name`, which is validated
    -- before the tool runs.
    eq(guard.is_skipped(nil, "read_with_fingerprint"), false)
    eq(guard.is_skipped("neovim", "read_with_fingerprint"), true)
end

T["skip policy"]["a bare entry still matches without a server"] = function()
    setup({ skip = { "shared_name" }, skip_defaults = false })
    eq(guard.is_skipped(nil, "shared_name"), true)
end

--------------------------------------------------------------------------------
T["apply"] = new_set()

T["apply"]["replaces oversized text with a summary naming the file"] = function()
    setup()
    local result = result_of(oversized())
    local spilled, path = guard.apply(result, { server_name = "neovim", tool_name = "execute_command" })
    eq(spilled, true)
    eq(type(path), "string")
    path = assert(path)
    eq(vim.fn.filereadable(path), 1)
    eq(result.text:find(path, 1, true) ~= nil, true)
    eq(result.text:find("too large for the chat context", 1, true) ~= nil, true)
end

T["apply"]["writes the payload where it can be inspected"] = function()
    setup()
    local result = result_of("MARKER" .. oversized())
    local _, path = guard.apply(result, { server_name = "neovim", tool_name = "execute_command" })
    eq(table.concat(vim.fn.readfile(assert(path)), "\n"):find("MARKER", 1, true), 1)
end

T["apply"]["labels the spill file with the server and tool"] = function()
    setup()
    local result = result_of(oversized())
    local _, path = guard.apply(result, { server_name = "neovim", tool_name = "execute_command" })
    eq(vim.fn.fnamemodify(assert(path), ":t"):find("neovim__execute_command", 1, true), 1)
end

T["apply"]["spills into the configured directory"] = function()
    setup()
    local result = result_of(oversized())
    local _, path = guard.apply(result, { server_name = "neovim", tool_name = "execute_command" })
    eq(vim.fn.fnamemodify(assert(path), ":h"), dir)
end

T["apply"]["leaves a skipped tool alone"] = function()
    setup()
    local original = oversized()
    local result = result_of(original)
    eq(guard.apply(result, { server_name = "neovim", tool_name = "read_with_fingerprint" }), false)
    eq(result.text, original)
end

T["apply"]["leaves text within budget alone"] = function()
    setup()
    local result = result_of("a modest response")
    eq(guard.apply(result, { server_name = "neovim", tool_name = "execute_command" }), false)
    eq(result.text, "a modest response")
end

T["apply"]["never touches sibling fields"] = function()
    setup()
    local result = result_of(oversized())
    result.images = { "img" }
    guard.apply(result, { server_name = "neovim", tool_name = "execute_command" })
    eq(result.images, { "img" })
end

T["apply"]["ignores results with no usable text"] = function()
    -- Deliberately malformed results: the guard must tolerate anything the hub
    -- hands it rather than trusting the annotated shape.
    ---@diagnostic disable: missing-fields, assign-type-mismatch
    eq(guard.apply(nil, { server_name = "neovim", tool_name = "execute_command" }), false)
    eq(guard.apply({}, { server_name = "neovim", tool_name = "execute_command" }), false)
    eq(guard.apply(result_of(""), { server_name = "neovim", tool_name = "execute_command" }), false)
    eq(guard.apply({ text = 42 }, { server_name = "neovim", tool_name = "execute_command" }), false)
    ---@diagnostic enable: missing-fields, assign-type-mismatch
end

T["apply"]["works for a resource identified by uri"] = function()
    setup()
    local result = result_of(oversized())
    local spilled, path = guard.apply(result, { server_name = "neovim", uri = "neovim://buffer" })
    eq(spilled, true)
    eq(vim.fn.fnamemodify(assert(path), ":t"):find("neovim__neovim", 1, true), 1)
end

T["apply"]["degrades to a truncated preview when the write fails"] = function()
    setup({ dir = "/proc/definitely/not/writable" })
    local result = result_of(oversized())
    local spilled, path = guard.apply(result, { server_name = "neovim", tool_name = "execute_command" })
    eq(spilled, true)
    eq(path, nil)
    eq(result.text:find("[truncated]", 1, true) ~= nil, true)
end

T["apply"]["survives a token counter that raises"] = function()
    setup({
        max_tokens = 10,
        token_counter = function()
            error("counter exploded")
        end,
    })
    local result = result_of("small")
    eq(guard.apply(result, { server_name = "neovim", tool_name = "execute_command" }), false)
    eq(result.text, "small")
end

--------------------------------------------------------------------------------
T["budgets"] = new_set()

T["budgets"]["a custom byte budget spills a small payload"] = function()
    setup({ max_bytes = 8 })
    local result = result_of("0123456789")
    eq(guard.apply(result, { server_name = "neovim", tool_name = "execute_command" }), true)
end

T["budgets"]["a custom line budget spills a short payload"] = function()
    setup({ max_lines = 2 })
    local result = result_of("a\nb\nc\nd")
    eq(guard.apply(result, { server_name = "neovim", tool_name = "execute_command" }), true)
end

T["budgets"]["max_bytes = false disables only that budget"] = function()
    setup({ max_bytes = false })
    -- One huge line: over bytes, single line, so nothing trips.
    local result = result_of(oversized())
    eq(guard.apply(result, { server_name = "neovim", tool_name = "execute_command" }), false)
    -- Lines still enforced.
    local many = result_of(string.rep("y\n", spill.DEFAULT_MAX_LINES + 1))
    eq(guard.apply(many, { server_name = "neovim", tool_name = "execute_command" }), true)
end

T["budgets"]["max_lines = false disables only that budget"] = function()
    setup({ max_lines = false })
    local many = result_of(string.rep("y\n", spill.DEFAULT_MAX_LINES + 1))
    eq(guard.apply(many, { server_name = "neovim", tool_name = "execute_command" }), false)
    eq(guard.apply(result_of(oversized()), { server_name = "neovim", tool_name = "execute_command" }), true)
end

T["budgets"]["all budgets disabled lets everything inline"] = function()
    setup({ max_bytes = false, max_lines = false, max_tokens = false })
    local result = result_of(oversized())
    eq(guard.apply(result, { server_name = "neovim", tool_name = "execute_command" }), false)
end

T["budgets"]["a token budget spills a byte-small payload"] = function()
    setup({
        max_bytes = false,
        max_lines = false,
        max_tokens = 10,
        token_counter = function()
            return 11
        end,
    })
    local result = result_of("tiny")
    eq(guard.apply(result, { server_name = "neovim", tool_name = "execute_command" }), true)
end

T["budgets"]["max_tokens = false skips counter resolution entirely"] = function()
    setup({ max_tokens = false })
    local config = guard.get_config()
    eq(config.max_tokens, false)
    eq(config.token_counter, nil)
end

T["budgets"]["a user counter is preferred over the default"] = function()
    local mine = function()
        return 1
    end
    setup({ token_counter = mine })
    eq(guard.get_config().token_counter, mine)
end

--------------------------------------------------------------------------------
T["gc"] = new_set()

T["gc"]["false installs no timer"] = function()
    setup({ gc = false })
    eq(guard.get_config().gc, false)
end

T["gc"]["a table is passed through"] = function()
    setup({ gc = { max_age_hours = 1, period_minutes = 5 } })
    eq(guard.get_config().gc, { max_age_hours = 1, period_minutes = 5 })
    -- reset() must stop the timer this installed; a leaked timer would keep the
    -- test process alive.
    guard.reset()
end

T["gc"]["repeated setup does not stack timers"] = function()
    setup({ gc = { period_minutes = 5 } })
    setup({ gc = { period_minutes = 5 } })
    setup({ gc = false })
    eq(guard.get_config().gc, false)
end

--------------------------------------------------------------------------------
T["reset"] = new_set()

T["reset"]["clears configuration"] = function()
    setup({ max_bytes = 1 })
    guard.reset()
    eq(guard.get_config(), {})
end

T["reset"]["clears the skip set"] = function()
    setup()
    eq(guard.is_skipped("neovim", "read_with_fingerprint"), true)
    guard.reset()
    eq(guard.is_skipped("neovim", "read_with_fingerprint"), false)
end

return T
