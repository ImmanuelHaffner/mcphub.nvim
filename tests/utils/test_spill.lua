-- Tests for mcphub.utils.spill — budgets, spill files, summaries and GC.
--
-- Run with `make test`, or just this file with
-- `make test_file FILE=tests/utils/test_spill.lua`.
local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local spill = require("mcphub.utils.spill")

--- Per-case scratch directory, so no case can see another's spill files and the
--- real cache dir is never touched.
local dir

--- Text large enough to trip the default byte budget on its own (one line).
local function big_bytes()
    return string.rep("x", spill.DEFAULT_MAX_BYTES + 1)
end

--- Text with more lines than the default budget but far below the byte budget.
local function big_lines()
    return string.rep("y\n", spill.DEFAULT_MAX_LINES + 1)
end

--- A token counter that always claims `n` tokens.
local function counter_of(n)
    return function()
        return n
    end
end

local T = new_set({
    hooks = {
        pre_case = function()
            dir = vim.fn.tempname()
            vim.fn.mkdir(dir, "p")
        end,
        post_case = function()
            vim.fn.delete(dir, "rf")
            dir = nil
        end,
    },
})

--------------------------------------------------------------------------------
T["defaults"] = new_set()

T["defaults"]["spill dir is under the cache path and mcphub-named"] = function()
    eq(spill.DIR, vim.fn.stdpath("cache") .. "/mcphub-spill")
end

T["defaults"]["byte and line budgets are set, token budget is opt-in"] = function()
    eq(spill.DEFAULT_MAX_BYTES, 96 * 1024)
    eq(spill.DEFAULT_MAX_LINES, 2000)
    eq(spill.DEFAULT_MAX_TOKENS, nil)
end

T["defaults"]["gc defaults are 24h swept hourly"] = function()
    eq(spill.DEFAULT_GC_MAX_AGE_HOURS, 24)
    eq(spill.DEFAULT_GC_PERIOD_MINUTES, 60)
end

--------------------------------------------------------------------------------
T["too_large"] = new_set()

T["too_large"]["treats nil and empty as small"] = function()
    eq({ spill.too_large(nil) }, { false, nil })
    eq({ spill.too_large("") }, { false, nil })
end

T["too_large"]["passes text within every budget"] = function()
    eq({ spill.too_large("just a little text") }, { false, nil })
end

T["too_large"]["trips on the default byte budget"] = function()
    eq({ spill.too_large(big_bytes()) }, { true, "bytes" })
end

T["too_large"]["trips on the default line budget"] = function()
    eq({ spill.too_large(big_lines()) }, { true, "lines" })
end

T["too_large"]["honours an explicit byte budget"] = function()
    eq({ spill.too_large("0123456789", { max_bytes = 5 }) }, { true, "bytes" })
    eq({ spill.too_large("0123456789", { max_bytes = 100 }) }, { false, nil })
end

T["too_large"]["honours an explicit line budget"] = function()
    eq({ spill.too_large("a\nb\nc\nd", { max_lines = 2 }) }, { true, "lines" })
    eq({ spill.too_large("a\nb\nc\nd", { max_lines = 99 }) }, { false, nil })
end

T["too_large"]["max_bytes = false disables only the byte budget"] = function()
    -- One huge line: over bytes, but a single line.
    eq({ spill.too_large(big_bytes(), { max_bytes = false }) }, { false, nil })
    -- Lines still enforced independently.
    eq({ spill.too_large(big_lines(), { max_bytes = false }) }, { true, "lines" })
end

T["too_large"]["max_lines = false disables only the line budget"] = function()
    eq({ spill.too_large(big_lines(), { max_lines = false }) }, { false, nil })
    eq({ spill.too_large(big_bytes(), { max_lines = false }) }, { true, "bytes" })
end

T["too_large"]["both budgets false lets anything through"] = function()
    eq({ spill.too_large(big_bytes(), { max_bytes = false, max_lines = false }) }, { false, nil })
    eq({ spill.too_large(big_lines(), { max_bytes = false, max_lines = false }) }, { false, nil })
end

T["too_large"]["trips on tokens when a budget and counter are given"] = function()
    local opts = { max_tokens = 100, token_counter = counter_of(101) }
    eq({ spill.too_large("small", opts) }, { true, "tokens" })
end

T["too_large"]["passes when the token estimate is within budget"] = function()
    local opts = { max_tokens = 100, token_counter = counter_of(100) }
    eq({ spill.too_large("small", opts) }, { false, nil })
end

T["too_large"]["ignores tokens without a counter"] = function()
    eq({ spill.too_large("small", { max_tokens = 1 }) }, { false, nil })
end

T["too_large"]["ignores tokens without a budget"] = function()
    eq({ spill.too_large("small", { token_counter = counter_of(10 ^ 9) }) }, { false, nil })
end

T["too_large"]["max_tokens = false disables the token budget"] = function()
    local opts = { max_tokens = false, token_counter = counter_of(10 ^ 9) }
    eq({ spill.too_large("small", opts) }, { false, nil })
end

T["too_large"]["reports bytes before lines before tokens"] = function()
    local text = big_bytes() .. string.rep("\n", spill.DEFAULT_MAX_LINES + 1)
    local opts = { max_tokens = 1, token_counter = counter_of(10 ^ 9) }
    eq({ spill.too_large(text, opts) }, { true, "bytes" })
    opts.max_bytes = false
    eq({ spill.too_large(text, opts) }, { true, "lines" })
    opts.max_lines = false
    eq({ spill.too_large(text, opts) }, { true, "tokens" })
end

--------------------------------------------------------------------------------
T["estimate_tokens"] = new_set()

T["estimate_tokens"]["returns nil without a counter"] = function()
    eq(spill.estimate_tokens("text"), nil)
    eq(spill.estimate_tokens("text", {}), nil)
end

T["estimate_tokens"]["floors the counter's result"] = function()
    eq(spill.estimate_tokens("text", { token_counter = counter_of(7.9) }), 7)
end

T["estimate_tokens"]["degrades to nil when the counter errors"] = function()
    local boom = function()
        error("counter exploded")
    end
    eq(spill.estimate_tokens("text", { token_counter = boom }), nil)
end

T["estimate_tokens"]["degrades to nil when the counter returns a non-number"] = function()
    -- Deliberately violating the counter's annotated return type.
    ---@diagnostic disable-next-line: return-type-mismatch
    eq(
        spill.estimate_tokens("text", {
            token_counter = function()
                return "lots"
            end,
        }),
        nil
    )
end

--------------------------------------------------------------------------------
T["write"] = new_set()

T["write"]["writes the payload verbatim to the given dir"] = function()
    local path = spill.write("hello\nworld", { dir = dir, label = "probe" })
    eq(vim.fn.filereadable(path), 1)
    eq(vim.fn.fnamemodify(path, ":h"), dir)
    eq(table.concat(vim.fn.readfile(path), "\n"), "hello\nworld")
end

T["write"]["creates the directory when missing"] = function()
    local nested = dir .. "/deep/deeper"
    local path = spill.write("x", { dir = nested })
    eq(vim.fn.isdirectory(nested), 1)
    eq(vim.fn.filereadable(path), 1)
end

T["write"]["picks the extension from a content sniff"] = function()
    eq(vim.fn.fnamemodify(spill.write('{"a":1}', { dir = dir }), ":e"), "json")
    eq(vim.fn.fnamemodify(spill.write("[1,2]", { dir = dir }), ":e"), "json")
    eq(vim.fn.fnamemodify(spill.write("<root/>", { dir = dir }), ":e"), "xml")
    eq(vim.fn.fnamemodify(spill.write("plain words", { dir = dir }), ":e"), "txt")
end

T["write"]["reports the detected format"] = function()
    local _, _, format = spill.write('{"a":1}', { dir = dir })
    eq(format, "json")
end

T["write"]["slugifies the label and defaults it"] = function()
    local path = spill.write("x", { dir = dir, label = "neovim__read_file (v2)/../etc" })
    local name = vim.fn.fnamemodify(path, ":t")
    eq(name:match("^neovim__read_file_v2_etc%-") ~= nil, true)
    eq(vim.fn.fnamemodify(spill.write("x", { dir = dir }), ":t"):match("^output%-") ~= nil, true)
end

T["write"]["never collides within a process"] = function()
    local seen = {}
    for _ = 1, 25 do
        local path = assert(spill.write("x", { dir = dir, label = "same" }))
        eq(seen[path], nil)
        seen[path] = true
    end
end

T["write"]["reports an error instead of raising when the path is unwritable"] = function()
    local path, err = spill.write("x", { dir = "/proc/definitely/not/writable" })
    eq(path, nil)
    eq(type(err), "string")
end

--------------------------------------------------------------------------------
T["summarize"] = new_set()

T["summarize"]["states size, path and format"] = function()
    local summary = spill.summarize("a\nb", "/tmp/x.txt")
    eq(summary:find("3 bytes, 2 lines", 1, true) ~= nil, true)
    eq(summary:find("/tmp/x.txt", 1, true) ~= nil, true)
    eq(summary:find("too large for the chat context", 1, true) ~= nil, true)
end

T["summarize"]["includes a token estimate only when a counter is given"] = function()
    eq(spill.summarize("a", "/tmp/x", { token_counter = counter_of(42) }):find("≈42 tokens", 1, true) ~= nil, true)
    eq(spill.summarize("a", "/tmp/x"):find("tokens", 1, true), nil)
end

T["summarize"]["hints jq for JSON and lists top-level keys"] = function()
    local summary = spill.summarize('{"beta":1,"alpha":2}', "/tmp/x.json")
    eq(summary:find("jq ", 1, true) ~= nil, true)
    eq(summary:find("Top-level JSON keys", 1, true) ~= nil, true)
    -- Keys are sorted for a stable message.
    eq(summary:find("`alpha`, `beta`", 1, true) ~= nil, true)
end

T["summarize"]["hints xmllint for XML"] = function()
    local summary = spill.summarize("<root><a/></root>", "/tmp/x.xml")
    eq(summary:find("xmllint", 1, true) ~= nil, true)
end

T["summarize"]["hints rg/head/tail for plain text and previews line one"] = function()
    local summary = spill.summarize("first line\nsecond", "/tmp/x.txt")
    eq(summary:find("rg <pattern>", 1, true) ~= nil, true)
    eq(summary:find("head -n 50", 1, true) ~= nil, true)
    eq(summary:find("First line: `first line`", 1, true) ~= nil, true)
end

T["summarize"]["falls back to a first-line preview for a JSON array"] = function()
    local summary = spill.summarize("[1,2,3]", "/tmp/x.json")
    eq(summary:find("Top-level JSON keys", 1, true), nil)
    eq(summary:find("First line:", 1, true) ~= nil, true)
end

T["summarize"]["truncates a very long first line"] = function()
    local summary = spill.summarize(string.rep("z", 500), "/tmp/x.txt")
    eq(summary:find("…", 1, true) ~= nil, true)
end

T["summarize"]["tells the model not to cat the file"] = function()
    eq(spill.summarize("a", "/tmp/x"):find("DO NOT `cat`", 1, true) ~= nil, true)
end

T["summarize"]["honours an explicit format over the sniff"] = function()
    local summary = spill.summarize("plain", "/tmp/x", { format = "json" })
    eq(summary:find("jq ", 1, true) ~= nil, true)
end

--------------------------------------------------------------------------------
T["spill"] = new_set()

T["spill"]["writes the payload and returns a summary naming it"] = function()
    local replacement, path = spill.spill("payload text", { dir = dir, label = "tool" })
    eq(type(path), "string")
    path = assert(path)
    eq(vim.fn.filereadable(path), 1)
    eq(replacement:find(path, 1, true) ~= nil, true)
end

T["spill"]["falls back to a truncated preview when the write fails"] = function()
    local replacement, path = spill.spill("abcdefghij", { dir = "/proc/nope", max_bytes = 4 })
    eq(path, nil)
    eq(replacement:find("spill-to-disk failed", 1, true) ~= nil, true)
    eq(replacement:find("[truncated]", 1, true) ~= nil, true)
    eq(replacement:find("abcd", 1, true) ~= nil, true)
end

--------------------------------------------------------------------------------
T["maybe_spill"] = new_set()

T["maybe_spill"]["returns small text untouched"] = function()
    local text, path, spilled, reason = spill.maybe_spill("small", { dir = dir })
    eq(text, "small")
    eq(path, nil)
    eq(spilled, false)
    eq(reason, nil)
end

T["maybe_spill"]["handles nil text"] = function()
    local text, path, spilled = spill.maybe_spill(nil, { dir = dir })
    eq(text, "")
    eq(path, nil)
    eq(spilled, false)
end

T["maybe_spill"]["spills oversized text and reports the reason"] = function()
    local original = big_lines()
    local text, path, spilled, reason = spill.maybe_spill(original, { dir = dir })
    eq(spilled, true)
    eq(reason, "lines")
    eq(vim.fn.filereadable(path), 1)
    eq(text ~= original, true)
    eq(#text < #original, true)
end

T["maybe_spill"]["writes the original payload, not the summary"] = function()
    local original = "line one\n" .. big_lines()
    local _, path = spill.maybe_spill(original, { dir = dir })
    eq(table.concat(vim.fn.readfile(path), "\n"):find("line one", 1, true), 1)
end

T["maybe_spill"]["respects a disabled budget"] = function()
    local _, _, spilled = spill.maybe_spill(big_lines(), { dir = dir, max_lines = false, max_bytes = false })
    eq(spilled, false)
end

--------------------------------------------------------------------------------
T["gc"] = new_set()

--- Write a spill file and backdate it by `hours`.
local function aged_file(hours, contents)
    local path = spill.write(contents or "payload", { dir = dir, label = "aged" })
    local when = os.time() - math.floor(hours * 3600)
    vim.uv.fs_utime(path, when, when)
    return path
end

T["gc"]["deletes files older than the age cap"] = function()
    local old = aged_file(48)
    local stats = spill.gc({ dir = dir })
    eq(vim.fn.filereadable(old), 0)
    eq(stats.deleted, 1)
    eq(stats.scanned, 1)
    eq(stats.freed_bytes > 0, true)
end

T["gc"]["keeps files within the age cap"] = function()
    local fresh = aged_file(1)
    local stats = spill.gc({ dir = dir })
    eq(vim.fn.filereadable(fresh), 1)
    eq(stats.deleted, 0)
    eq(stats.kept_bytes > 0, true)
end

T["gc"]["honours a custom age cap"] = function()
    local path = aged_file(2)
    eq(spill.gc({ dir = dir, max_age_hours = 72 }).deleted, 0)
    eq(spill.gc({ dir = dir, max_age_hours = 1 }).deleted, 1)
    eq(vim.fn.filereadable(path), 0)
end

T["gc"]["never touches files it did not write"] = function()
    local foreign = dir .. "/notes.txt"
    vim.fn.writefile({ "mine" }, foreign)
    vim.uv.fs_utime(foreign, 0, 0)
    local stats = spill.gc({ dir = dir })
    eq(vim.fn.filereadable(foreign), 1)
    eq(stats.scanned, 0)
end

T["gc"]["is a no-op on a missing directory"] = function()
    local stats = spill.gc({ dir = dir .. "/absent" })
    eq(stats, { scanned = 0, deleted = 0, freed_bytes = 0, kept_bytes = 0 })
end

--------------------------------------------------------------------------------
T["start_periodic_gc"] = new_set()

T["start_periodic_gc"]["returns a stoppable handle"] = function()
    local handle = spill.start_periodic_gc({ dir = dir, period_minutes = 60 })
    eq(type(handle.stop), "function")
    handle.stop()
    -- Idempotent: a second stop must not raise.
    handle.stop()
end

T["start_periodic_gc"]["exposes the timer for introspection"] = function()
    local handle = spill.start_periodic_gc({ dir = dir })
    eq(handle.timer ~= nil, true)
    handle.stop()
end

return T
