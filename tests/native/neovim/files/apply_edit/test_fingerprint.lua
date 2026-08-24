--- Tests for mcphub.native.neovim.files.apply_edit.fingerprint.
---
--- Run headless:
---   make test

local assert = require("tests.native.neovim.files.apply_edit.busted_assert")

local fingerprint = require("mcphub.native.neovim.files.apply_edit.fingerprint")

describe("mcphub.native.neovim.files.apply_edit.fingerprint", function()
    describe("LEN constant", function()
        it("is 7", function()
            assert.is.equal(7, fingerprint.LEN)
        end)
    end)

    describe("compute", function()
        it("produces a 7-character fingerprint", function()
            assert.is.equal(7, #fingerprint.compute("hello\n"))
        end)

        it("is deterministic — same input → same fingerprint", function()
            local f1 = fingerprint.compute("content")
            local f2 = fingerprint.compute("content")
            assert.is.equal(f1, f2)
        end)

        it("different content → different fingerprint (almost always)", function()
            -- Not strictly required by the hash, but for any two
            -- realistic strings the 28-bit prefix will differ.
            local f1 = fingerprint.compute("content one")
            local f2 = fingerprint.compute("content two")
            assert.is_truthy(f1 ~= f2)
        end)

        it("handles empty content", function()
            assert.is.equal(7, #fingerprint.compute(""))
        end)

        it("handles content with embedded newlines", function()
            assert.is.equal(7, #fingerprint.compute("a\nb\nc\n"))
        end)

        it("emits lowercase hex only", function()
            -- vim.fn.sha256 returns lowercase; verify we don't accidentally
            -- introduce case via the substring.
            for _, content in ipairs({ "", "a", "ABC", string.rep("x", 100) }) do
                local f = fingerprint.compute(content)
                assert.is_truthy(f:match("^[0-9a-f]+$"))
            end
        end)

        it("matches the first 7 hex chars of vim.fn.sha256 directly", function()
            local content = "verification check"
            local expected = vim.fn.sha256(content):sub(1, 7)
            assert.is.equal(expected, fingerprint.compute(content))
        end)

        it("asserts on non-string input", function()
            assert.is_falsy(pcall(fingerprint.compute, 42))
            assert.is_falsy(pcall(fingerprint.compute, nil))
            assert.is_falsy(pcall(fingerprint.compute, { "not", "a", "string" }))
        end)
    end)

    describe("matches", function()
        it("true when fingerprint matches content", function()
            local content = "hello world"
            local fp = fingerprint.compute(content)
            assert.is_truthy(fingerprint.matches(fp, content))
        end)

        it("false when fingerprint does not match (content mutated)", function()
            local fp = fingerprint.compute("original")
            assert.is_falsy(fingerprint.matches(fp, "mutated"))
        end)

        it("false when fingerprint is the wrong length", function()
            assert.is_falsy(fingerprint.matches("abc", "hello"))
            assert.is_falsy(fingerprint.matches("abcdefgh", "hello"))
        end)

        it("false when fingerprint is nil", function()
            assert.is_falsy(fingerprint.matches(nil, "content"))
        end)

        it("false when fingerprint is a non-string", function()
            assert.is_falsy(fingerprint.matches(42, "content"))
            assert.is_falsy(fingerprint.matches({}, "content"))
        end)
    end)

    describe("is_valid_format", function()
        it("accepts a well-formed fingerprint", function()
            assert.is_truthy(fingerprint.is_valid_format("a3f9d2c"))
        end)

        it("accepts all-zero fingerprint", function()
            assert.is_truthy(fingerprint.is_valid_format("0000000"))
        end)

        it("rejects uppercase hex", function()
            -- vim.fn.sha256 emits lowercase; any uppercase fingerprint did
            -- not come from compute() and we refuse it for clarity.
            assert.is_falsy(fingerprint.is_valid_format("ABCDEF0"))
            assert.is_falsy(fingerprint.is_valid_format("aB3dEf0"))
        end)

        it("rejects wrong length", function()
            assert.is_falsy(fingerprint.is_valid_format("abc")) -- too short
            assert.is_falsy(fingerprint.is_valid_format("abcdef01")) -- too long
            assert.is_falsy(fingerprint.is_valid_format("")) -- empty
        end)

        it("rejects non-hex characters", function()
            assert.is_falsy(fingerprint.is_valid_format("abcdefg")) -- "g" is not hex
            assert.is_falsy(fingerprint.is_valid_format("zzzzzzz"))
            assert.is_falsy(fingerprint.is_valid_format("!!!!!!!"))
        end)

        it("rejects non-string input", function()
            assert.is_falsy(fingerprint.is_valid_format(nil))
            assert.is_falsy(fingerprint.is_valid_format(42))
            assert.is_falsy(fingerprint.is_valid_format({}))
        end)

        it("a freshly computed fingerprint always passes is_valid_format", function()
            for _, content in ipairs({ "", "a", "a\nb\nc\n", string.rep("x", 1000) }) do
                local f = fingerprint.compute(content)
                assert.is_truthy(fingerprint.is_valid_format(f))
            end
        end)
    end)
end)
