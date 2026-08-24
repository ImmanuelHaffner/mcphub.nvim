--- Tests for mcphub.native.neovim.files.apply_edit.json — UTF-8-safe JSON encoding.
---
--- Run headless:
---   make test

local assert = require("tests.native.neovim.files.apply_edit.busted_assert")

local json = require("mcphub.native.neovim.files.apply_edit.json")

-- Byte-sequence fixtures. `char` is a terse alias.
local char = string.char

-- WTF-8 / CESU-8 encoding of the lone surrogate U+D800 (ED A0 80). This is
-- the exact class that trips strict downstream JSON parsers.
local SURROGATE_D800 = char(0xED, 0xA0, 0x80)
-- U+DFFF, the top of the surrogate range (ED BF BF).
local SURROGATE_DFFF = char(0xED, 0xBF, 0xBF)
-- The UTF-8 encoding of U+FFFD REPLACEMENT CHARACTER.
local FFFD = char(0xEF, 0xBF, 0xBD)

describe("mcphub.native.neovim.files.apply_edit.json", function()
    describe("scrub_string", function()
        it("passes ASCII through unchanged with zero replacements", function()
            local s, n = json.scrub_string("hello world")
            assert.is.equal("hello world", s)
            assert.is.equal(0, n)
        end)

        it("passes valid multi-byte UTF-8 through unchanged", function()
            for _, valid in ipairs({ "café", "☕", "😀", "日本語", "Ω≈ç√" }) do
                local s, n = json.scrub_string(valid)
                assert.is.equal(valid, s)
                assert.is.equal(0, n)
            end
        end)

        it("replaces a lone surrogate (U+D800 as WTF-8) with U+FFFD", function()
            local s, n = json.scrub_string("a" .. SURROGATE_D800 .. "b")
            -- Each of the 3 surrogate bytes becomes one U+FFFD.
            assert.is.equal("a" .. FFFD .. FFFD .. FFFD .. "b", s)
            assert.is.equal(3, n)
        end)

        it("replaces the top-of-range surrogate (U+DFFF)", function()
            local _, n = json.scrub_string(SURROGATE_DFFF)
            assert.is.equal(3, n)
        end)

        it("replaces a stray continuation byte", function()
            local s, n = json.scrub_string("x" .. char(0x80) .. "y")
            assert.is.equal("x" .. FFFD .. "y", s)
            assert.is.equal(1, n)
        end)

        it("replaces a lone 0xFF byte", function()
            local s, n = json.scrub_string(char(0xFF))
            assert.is.equal(FFFD, s)
            assert.is.equal(1, n)
        end)

        it("replaces overlong lead bytes 0xC0 / 0xC1", function()
            local _, n0 = json.scrub_string(char(0xC0, 0x80))
            local _, n1 = json.scrub_string(char(0xC1, 0x80))
            -- Only the lead byte is replaced; the 0x80 that follows is then
            -- itself a stray continuation → a second replacement.
            assert.is_truthy(n0 >= 1)
            assert.is_truthy(n1 >= 1)
        end)

        it("replaces a truncated 2-byte sequence at end of string", function()
            local s, n = json.scrub_string("ok" .. char(0xC3))
            assert.is.equal("ok" .. FFFD, s)
            assert.is.equal(1, n)
        end)

        it("replaces a truncated 3-byte sequence at end of string", function()
            -- E2 is a 3-byte lead; with only one following byte the lead is
            -- replaced, then the stray 0x82 continuation is replaced too.
            local _, n = json.scrub_string(char(0xE2, 0x82)) -- € missing last byte
            assert.is.equal(2, n)
        end)

        it("replaces an overlong 3-byte form (E0 with 2nd byte < A0)", function()
            local _, n = json.scrub_string(char(0xE0, 0x80, 0x80))
            assert.is_truthy(n >= 1)
        end)

        it("replaces an out-of-range 4-byte form (F4 with 2nd byte > 8F)", function()
            local _, n = json.scrub_string(char(0xF4, 0x90, 0x80, 0x80))
            assert.is_truthy(n >= 1)
        end)

        it("preserves valid 4-byte astral chars adjacent to bad bytes", function()
            -- 😀 (F0 9F 98 80) sandwiched around a surrogate.
            local s, n = json.scrub_string("😀" .. SURROGATE_D800 .. "😀")
            assert.is.equal("😀" .. FFFD .. FFFD .. FFFD .. "😀", s)
            assert.is.equal(3, n)
        end)

        it("handles the empty string", function()
            local s, n = json.scrub_string("")
            assert.is.equal("", s)
            assert.is.equal(0, n)
        end)
    end)

    describe("scrub", function()
        it("scrubs strings nested in tables and counts across the whole value", function()
            local input = {
                a = "clean",
                b = SURROGATE_D800, -- 3 bad bytes
                nested = { c = char(0x80) }, -- 1 bad byte
            }
            local out, n = json.scrub(input)
            assert.is.equal("clean", out.a)
            assert.is.equal(FFFD .. FFFD .. FFFD, out.b)
            assert.is.equal(FFFD, out.nested.c)
            assert.is.equal(4, n)
        end)

        it("scrubs ill-formed string keys", function()
            local input = { [SURROGATE_D800] = "value" }
            local out, n = json.scrub(input)
            assert.is.equal(3, n)
            -- The key was rewritten to U+FFFD*3; the value is intact.
            assert.is.equal("value", out[FFFD .. FFFD .. FFFD])
        end)

        it("does not mutate the input table", function()
            local input = { bad = SURROGATE_D800 }
            json.scrub(input)
            assert.is.equal(SURROGATE_D800, input.bad)
        end)

        it("passes numbers, booleans, and nil through unchanged", function()
            local out, n = json.scrub({ x = 42, y = true, z = false })
            assert.is.equal(42, out.x)
            assert.is.equal(true, out.y)
            assert.is.equal(false, out.z)
            assert.is.equal(0, n)
        end)

        it("is cycle-safe", function()
            local t = { name = "self" }
            t.loop = t
            local out, n = json.scrub(t)
            assert.is.equal("self", out.name)
            assert.is.equal(out, out.loop) -- cycle preserved in the copy
            assert.is.equal(0, n)
        end)

        it("returns 0 for a fully-clean value", function()
            local _, n = json.scrub({ a = "one", b = { "two", "three" } })
            assert.is.equal(0, n)
        end)
    end)

    describe("safe_encode", function()
        it("encodes a clean value and reports zero replacements", function()
            local ok, encoded, n = json.safe_encode({ hello = "world" })
            assert.is_truthy(ok)
            assert.is.equal('{"hello":"world"}', encoded)
            assert.is.equal(0, n)
        end)

        it("produces surrogate-free output for ill-formed input", function()
            local ok, encoded, n = json.safe_encode({ s = SURROGATE_D800 })
            assert.is_truthy(ok)
            assert.is.equal(3, n)
            -- The encoded bytes must contain no raw surrogate encoding.
            assert.is_falsy(encoded:find(SURROGATE_D800, 1, true))
            -- And the output must itself be valid UTF-8 (re-scrubbing is a no-op).
            local _, again = json.scrub_string(encoded)
            assert.is.equal(0, again)
        end)

        it("the output round-trips back through vim.json.decode", function()
            local _, encoded = json.safe_encode({ s = "a" .. SURROGATE_D800 .. "b" })
            local decoded = vim.json.decode(encoded)
            assert.is.equal("a" .. FFFD .. FFFD .. FFFD .. "b", decoded.s)
        end)

        it("mirrors pcall contract: (false, err, 0) on encode failure", function()
            -- A function value cannot be JSON-encoded → structural failure.
            local ok, _, n = json.safe_encode({ fn = function() end })
            assert.is_falsy(ok)
            assert.is.equal(0, n)
        end)
    end)
end)
