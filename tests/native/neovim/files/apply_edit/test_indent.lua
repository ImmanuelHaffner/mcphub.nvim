--- Tests for mcphub.native.neovim.files.apply_edit.indent — the `match_anchor` reindentation rule.
---
--- Run headless:
---   make test

local assert = require("tests.native.neovim.files.apply_edit.busted_assert")

local fr = require("mcphub.native.neovim.files.apply_edit.file_record")
local indent = require("mcphub.native.neovim.files.apply_edit.indent")

describe("mcphub.native.neovim.files.apply_edit.indent", function()
    describe("leading_ws", function()
        it("returns the leading spaces", function()
            assert.is.equal("    ", indent.leading_ws("    foo"))
        end)

        it("returns the leading tabs", function()
            assert.is.equal("\t\t", indent.leading_ws("\t\tfoo"))
        end)

        it("returns mixed leading whitespace verbatim", function()
            assert.is.equal("\t  ", indent.leading_ws("\t  foo"))
        end)

        it("returns empty for a column-0 line", function()
            assert.is.equal("", indent.leading_ws("foo"))
        end)

        it("returns empty for the empty string", function()
            assert.is.equal("", indent.leading_ws(""))
        end)

        it("returns the whole string for a whitespace-only line", function()
            assert.is.equal("   ", indent.leading_ws("   "))
        end)
    end)

    describe("apply", function()
        it("prepends the prefix to a single column-0 line", function()
            local out = indent.apply({ "arg1" }, "    ")
            assert.is.equal("    arg1", out[1])
        end)

        it("is additive — pre-indented content rides on top of the prefix", function()
            -- LLM emits 2 spaces, anchor at 4 → 6 spaces total.
            local out = indent.apply({ "  arg1" }, "    ")
            assert.is.equal("      arg1", out[1])
        end)

        it("preserves internal relative structure across lines", function()
            local out = indent.apply({ "if cond then", "    doThing()", "end" }, "    ")
            assert.is.equal("    if cond then", out[1])
            assert.is.equal("        doThing()", out[2])
            assert.is.equal("    end", out[3])
        end)

        it("leaves blank lines truly blank (no prefix, no trailing ws)", function()
            local out = indent.apply({ "a", "", "b" }, "    ")
            assert.is.equal("    a", out[1])
            assert.is.equal("", out[2])
            assert.is.equal("    b", out[3])
        end)

        it("treats a whitespace-only (non-empty) line as non-blank", function()
            -- Only the exact empty string is special-cased. A line that is
            -- spaces gets the prefix prepended.
            local out = indent.apply({ "  " }, "\t")
            assert.is.equal("\t  ", out[1])
        end)

        it("prepends tabs as raw bytes (no whitespace conversion)", function()
            local out = indent.apply({ "    spaces" }, "\t")
            assert.is.equal("\t    spaces", out[1])
        end)

        it("is a no-op (shallow copy) when the prefix is empty", function()
            local input = { "a", "b" }
            local out = indent.apply(input, "")
            assert.is.equal("a", out[1])
            assert.is.equal("b", out[2])
            assert.is_truthy(out ~= input) -- fresh table
        end)

        it("does not mutate the input table", function()
            local input = { "x" }
            indent.apply(input, "  ")
            assert.is.equal("x", input[1])
        end)
    end)

    describe("anchor_line", function()
        it("returns the first line of a non-zero-width range", function()
            assert.is.equal(5, indent.anchor_line({ start_line = 5, end_line = 8 }, 100))
        end)

        it("returns the single line of a one-line range", function()
            assert.is.equal(5, indent.anchor_line({ start_line = 5, end_line = 5 }, 100))
        end)

        it("returns line S for a zero-width insert {S, S-1} when S exists", function()
            -- before line 5 → {5, 4}; the attach line is 5.
            assert.is.equal(5, indent.anchor_line({ start_line = 5, end_line = 4 }, 100))
        end)

        it("falls back to S-1 for an insert-at-EOF position", function()
            -- after the last line (line 10) → {11, 10}; S=11 > n_lines=10,
            -- so attach to the final existing line, 10.
            assert.is.equal(10, indent.anchor_line({ start_line = 11, end_line = 10 }, 10))
        end)

        it("clamps to >= 1", function()
            -- before line 1 → {1, 0}; attach line is 1.
            assert.is.equal(1, indent.anchor_line({ start_line = 1, end_line = 0 }, 10))
        end)
    end)

    describe("reindent (end-to-end over a FileRecord)", function()
        -- A small file: line 2 is indented 4 spaces.
        local content = "function foo()\n    local x = 0\n    return x\nend\n"
        local function rec()
            return fr.from_content("/tmp/f.lua", content)
        end

        it("reindents column-0 content to the anchor first line (replace_range)", function()
            -- Replace line 2 (4 spaces) with column-0 content.
            local out = indent.reindent("local y = 1", rec(), { start_line = 2, end_line = 2 })
            assert.is.equal("    local y = 1", out)
        end)

        it("returns content unchanged when the anchor is at column 0", function()
            -- Anchor on line 1 (`function foo()`, column 0) → prefix "".
            local out = indent.reindent("local z = 2", rec(), { start_line = 1, end_line = 1 })
            assert.is.equal("local z = 2", out)
        end)

        it("reindents multi-line content, preserving internal structure", function()
            local out = indent.reindent("if x then\n    bar()\nend", rec(), { start_line = 2, end_line = 2 })
            assert.is.equal("    if x then\n        bar()\n    end", out)
        end)

        it("reindents at an insert position (before line 2)", function()
            -- before line 2 → {2, 1}; attach line is 2 (4 spaces).
            local out = indent.reindent("local w = 3", rec(), { start_line = 2, end_line = 1 })
            assert.is.equal("    local w = 3", out)
        end)

        it("round-trips a trailing newline in content", function()
            local out = indent.reindent("a\n", rec(), { start_line = 2, end_line = 2 })
            -- 'a\n' → lines {'a', ''}; reindent → {'    a', ''}; rejoined.
            assert.is.equal("    a\n", out)
        end)
    end)
end)
