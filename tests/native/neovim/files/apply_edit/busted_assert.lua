--- Busted-style `assert` vocabulary for the `apply_edit` specs.
---
--- `mini.test` already emulates busted's *structure*: `MiniTest.collect()` runs
--- with `emulate_busted = true` by default, which installs `describe`, `it`,
--- `before_each` and friends for the duration of collection. What it does not
--- provide is busted's *assertion* vocabulary, which these specs use heavily —
--- `assert.is.equal` (675 call sites), `assert.are.same` (67), the `assert.is_*`
--- predicates (251) and plain `assert(cond, msg)` (85).
---
--- Rather than rewrite ~5,600 lines of specs onto `MiniTest.expect`, this module
--- supplies the vocabulary they were written against, with identical semantics.
--- Failures are raised with `error()`, which `mini.test` reports as a failed case
--- with a traceback, so no reporter integration is needed.
---
--- Usage — shadow the global per spec file, so nothing leaks into the other
--- suites sharing the same `make test` run:
---
---     local assert = require("tests.native.neovim.files.apply_edit.busted_assert")
---
--- The returned table is deliberately **callable**: its `__call` metamethod
--- delegates to Lua's builtin `assert`, because the specs (and the modules under
--- test) also use `assert(cond, msg)` for ordinary argument validation. Without
--- it, shadowing the name would break every one of those call sites.
---
--- Equality semantics match busted, and the split is load-bearing for the specs:
--- `is.equal` / `are.equal` compare with `==` (identity for tables), while
--- `is.same` / `are.same` compare deeply.
---
--- @module "tests.native.neovim.files.apply_edit.busted_assert"

--- Format a value for an assertion failure message.
local function fmt(v)
    local t = type(v)
    if t == "string" then
        return string.format("%q", v)
    end
    if t == "table" then
        local ok, s = pcall(vim.inspect, v)
        return ok and s or tostring(v)
    end
    return tostring(v)
end

--- Raise an assertion failure. Level 3 reports the position of the *caller* of
--- the assert helper rather than a line inside this module.
local function fail(msg, ctx)
    error(msg .. (ctx and ("\n  " .. ctx) or ""), 3)
end

--- Deep structural equality, used by `is.same` / `are.same`.
local function deep_equal(a, b)
    if a == b then
        return true
    end
    if type(a) ~= "table" or type(b) ~= "table" then
        return false
    end
    for k, v in pairs(a) do
        if not deep_equal(v, b[k]) then
            return false
        end
    end
    for k, _ in pairs(b) do
        if a[k] == nil then
            return false
        end
    end
    return true
end

--- Lua's builtin `assert`, captured before the returned table shadows the name.
local lua_assert = assert

local M = setmetatable({}, {
    __call = function(_, v, msg, ...)
        return lua_assert(v, msg, ...)
    end,
})

function M.is_true(v, ctx)
    if v ~= true then
        fail("expected true, got " .. fmt(v), ctx)
    end
end

function M.is_false(v, ctx)
    if v ~= false then
        fail("expected false, got " .. fmt(v), ctx)
    end
end

function M.is_nil(v, ctx)
    if v ~= nil then
        fail("expected nil, got " .. fmt(v), ctx)
    end
end

function M.is_not_nil(v, ctx)
    if v == nil then
        fail("expected non-nil value", ctx)
    end
end

function M.is_string(v, ctx)
    if type(v) ~= "string" then
        fail("expected a string, got " .. type(v) .. " (" .. fmt(v) .. ")", ctx)
    end
end

--- Truthy in the Lua sense: anything that is neither `nil` nor `false`.
function M.is_truthy(v, ctx)
    if v == nil or v == false then
        fail("expected a truthy value, got " .. fmt(v), ctx)
    end
end

function M.is_falsy(v, ctx)
    if v ~= nil and v ~= false then
        fail("expected a falsy value, got " .. fmt(v), ctx)
    end
end

--- `assert.is.*` namespace.
M.is = {}

function M.is.equal(expected, actual, ctx)
    if expected ~= actual then
        fail(string.format("expected %s, got %s", fmt(expected), fmt(actual)), ctx)
    end
end

function M.is.same(expected, actual, ctx)
    if not deep_equal(expected, actual) then
        fail(string.format("expected %s, got %s", fmt(expected), fmt(actual)), ctx)
    end
end

--- `assert.are.*` namespace.
M.are = {}

function M.are.same(expected, actual, ctx)
    if not deep_equal(expected, actual) then
        fail(string.format("expected %s, got %s", fmt(expected), fmt(actual)), ctx)
    end
end

function M.are.equal(expected, actual, ctx)
    if expected ~= actual then
        fail(string.format("expected %s, got %s", fmt(expected), fmt(actual)), ctx)
    end
end

return M
