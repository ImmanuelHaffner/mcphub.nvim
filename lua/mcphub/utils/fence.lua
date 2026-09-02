--[[
Fences for embedding arbitrary text in the CodeCompanion chat buffer.

The invariant: a fence returned by `fence()` is always longer than the longest run
of backticks in the content it will wrap, so the content cannot terminate it. That
is the CommonMark and GitHub nesting rule, and the one Tree-sitter implements —
which is what matters here, because the chat buffer is parsed as Markdown.

Wrapping an MCP result in a fixed four backticks corrupts that buffer whenever the
result contains a four-backtick line: the wrapper closes early, the payload is
truncated at that line, and the wrapper's own closing fence becomes an *opening*
fence, inverting fence parity for everything below it. That can go as far as
swallowing the next `## <user>` header, in which case CodeCompanion's parser finds
no user message and submits the conversation without the prompt that was typed.

The payload is never rewritten. A fenced code block has no escape mechanism, so
"fixing" the payload's own backticks would mean changing bytes the user reads and
copies, and it is not even well defined for a payload whose fences are already
unbalanced (a truncated file read, a diff hunk that starts mid-block). A longer
outer fence is robust to all of those.

CodeCompanion owns the authoritative implementation, `codecompanion.utils.markdown`,
and this module delegates to it whenever it is available. The local implementation
below is a DELIBERATE DUPLICATE, kept so the fork keeps working against released
CodeCompanion versions that predate that helper. Do not "clean up" either copy: if
the two ever disagree, CodeCompanion's is correct and this one must follow it.
--]]

local CONSTANTS = {
    MIN_FENCE = 4,
}

local M = {}

--- Resolution cache: `nil` when not yet attempted, `false` when CodeCompanion has
--- no such helper, otherwise the module itself.
local upstream = nil

---A fence long enough that `content` cannot terminate it. Local fallback.
---@param content string|nil
---@param min integer|nil
---@return string
local function local_fence(content, min)
    local longest = 0
    for run in tostring(content or ""):gmatch("`+") do
        longest = math.max(longest, #run)
    end
    return ("`"):rep(math.max(min or CONSTANTS.MIN_FENCE, longest + 1))
end

---Wrap `content` in a fenced block it cannot terminate. Local fallback.
---@param content string|nil
---@param opts { info?: string, min?: integer }|nil
---@return string
local function local_code_block(content, opts)
    opts = opts or {}
    content = content == nil and "" or tostring(content)
    -- The info string shares the opening fence's line, so only its first line can
    -- be used: a newline in it would end that line early and break the block.
    local info = tostring(opts.info or ""):match("^[^\r\n]*")
    local fence = local_fence(content, opts.min)
    local opening = fence .. info
    if content == "" then
        return opening .. "\n" .. fence
    end
    local separator = content:sub(-1) == "\n" and "" or "\n"
    return opening .. "\n" .. content .. separator .. fence
end

---CodeCompanion's helper, or `nil` when this version does not have it.
---
---Resolved on first use rather than at module load: this module is reached through
---CodeCompanion's extension mechanism, so load order is not ours to assume. The
---result is cached, including the negative one — whether the installed
---CodeCompanion carries the helper cannot change within a session.
---@return table|nil
local function resolve()
    if upstream == nil then
        local ok, md = pcall(require, "codecompanion.utils.markdown")
        local usable = ok and type(md) == "table" and type(md.fence) == "function" and type(md.code_block) == "function"
        upstream = usable and md or false
    end
    return upstream or nil
end

---Forget the cached resolution of CodeCompanion's helper.
---
---For tests, which need to exercise both the delegating and the fallback path.
---@return nil
function M.reset()
    upstream = nil
end

---A fence long enough that `content` cannot terminate it
---@param content string|nil The text that will be wrapped
---@param min integer|nil Minimum fence length; defaults to 4
---@return string
function M.fence(content, min)
    local md = resolve()
    if md then
        return md.fence(content, min)
    end
    return local_fence(content, min)
end

---Wrap `content` in a fenced code block it cannot terminate
---@param content string|nil The text to wrap
---@param opts { info?: string, min?: integer }|nil `info` is the info string (a filetype, "diff", ...); only its first line is used, since it shares the opening fence's line
---@return string
function M.code_block(content, opts)
    local md = resolve()
    if md then
        return md.code_block(content, opts)
    end
    return local_code_block(content, opts)
end

return M
