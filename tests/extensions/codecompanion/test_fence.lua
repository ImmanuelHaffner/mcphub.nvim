-- Tests for mcphub.utils.fence and for the three CodeCompanion output wrappers in
-- mcphub.extensions.codecompanion.core that use it.
--
-- The chat buffer is rendered as Markdown, so the measurement instrument here is
-- Tree-sitter: what it sees is what the user sees. A wrapper whose fence is a fixed
-- four backticks is closed early by any payload line starting with four or more
-- backticks, which truncates the payload and turns the wrapper's own closing fence
-- into an opening one — inverting fence parity for everything below it, up to and
-- including the next `## <user>` header, whose loss makes CodeCompanion submit
-- without the prompt the user typed.
--
-- CodeCompanion is not a test dependency of this repository, so `mcphub.utils.fence`
-- exercises its local fallback throughout; the "delegation" group stubs
-- `codecompanion.utils.markdown` into `package.loaded` to cover the other path.
--
-- Run with `make test`, or just this file with
-- `make test_file FILE=tests/extensions/codecompanion/test_fence.lua`.
local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local fence = require("mcphub.utils.fence")
local spill = require("mcphub.utils.spill")

--- What a Markdown reader actually sees in `markdown`: how many fenced blocks it
--- contains, and the content of the first one.
---@param markdown string
---@return { count: integer, first: string|nil }
local function blocks(markdown)
    -- The chat buffer always holds whole lines, and a closing fence at end-of-string
    -- with no trailing newline is not recognised as a closer — an artefact of the
    -- harness rather than a defect, so complete the final line first.
    if markdown:sub(-1) ~= "\n" then
        markdown = markdown .. "\n"
    end
    local parser = vim.treesitter.get_string_parser(markdown, "markdown")
    local tree = parser:parse()[1]
    local query = vim.treesitter.query.parse("markdown", "[(fenced_code_block) @block (code_fence_content) @content]")
    local count, first = 0, nil
    for id, node in query:iter_captures(tree:root(), markdown) do
        if query.captures[id] == "block" then
            count = count + 1
        elseif first == nil then
            first = vim.treesitter.get_node_text(node, markdown)
        end
    end
    return { count = count, first = first }
end

--- A payload that would close a fixed four-backtick wrapper, and then reopen it.
local COLLIDING = table.concat({
    "opened with three:",
    "```lua",
    "local x = 1",
    "````",
    "four backticks, bare",
    "`````js",
    "five backticks with an info string",
}, "\n")

--------------------------------------------------------------------------------
local T = new_set()

--------------------------------------------------------------------------------
T["fence"] = new_set()

T["fence"]["defaults to four backticks"] = function()
    eq(fence.fence("plain text"), "````")
end

T["fence"]["ignores backticks that do not start a line"] = function()
    eq(fence.fence("a `b` and ``c`` inline"), "````")
end

T["fence"]["outgrows a four-backtick run in the payload"] = function()
    eq(fence.fence("a\n````\nb"), "`````")
end

T["fence"]["measures the longest run, not the last"] = function()
    eq(fence.fence("`````\nthen\n````"), "``````")
end

T["fence"]["honours a floor above what the content needs"] = function()
    eq(fence.fence("plain text", 6), "``````")
end

T["fence"]["overrides a floor below what the content needs"] = function()
    eq(fence.fence("`````", 4), "``````")
end

T["fence"]["treats nil as empty"] = function()
    eq(fence.fence(nil), "````")
end

--------------------------------------------------------------------------------
T["code_block"] = new_set()

T["code_block"]["wraps plain content byte-for-byte as before"] = function()
    eq(fence.code_block("hello"), "````\nhello\n````")
end

T["code_block"]["keeps a colliding payload inside exactly one block"] = function()
    local out = blocks(fence.code_block(COLLIDING))
    eq(out.count, 1)
    eq(out.first, COLLIDING .. "\n")
end

T["code_block"]["never rewrites the payload"] = function()
    -- The payload appears verbatim between the two fences: nothing is escaped, no
    -- backtick run is shortened, no line is dropped.
    local f = fence.fence(COLLIDING)
    eq(fence.code_block(COLLIDING), f .. "\n" .. COLLIDING .. "\n" .. f)
end

T["code_block"]["puts the info string on the opening fence"] = function()
    eq(fence.code_block("x", { info = "lua" }), "````lua\nx\n````")
end

T["code_block"]["uses only the first line of the info string"] = function()
    eq(fence.code_block("x", { info = "lua\nnot this" }), "````lua\nx\n````")
end

T["code_block"]["does not double a trailing newline"] = function()
    eq(fence.code_block("x\n"), "````\nx\n````")
end

T["code_block"]["still emits a block for empty content"] = function()
    eq(fence.code_block(""), "````\n````")
end

--------------------------------------------------------------------------------
-- CodeCompanion owns the authoritative implementation; the local one exists only
-- for versions that predate it (DD6). Both directions need covering, because the
-- fallback is otherwise dead code in this repository's test environment.
T["delegation"] = new_set({
    hooks = {
        pre_case = function()
            package.loaded["codecompanion.utils.markdown"] = nil
            fence.reset()
        end,
        post_case = function()
            package.loaded["codecompanion.utils.markdown"] = nil
            fence.reset()
        end,
    },
})

T["delegation"]["prefers CodeCompanion's helper when it is present"] = function()
    package.loaded["codecompanion.utils.markdown"] = {
        fence = function()
            return "FENCE"
        end,
        code_block = function()
            return "BLOCK"
        end,
    }
    fence.reset()
    eq(fence.fence("x"), "FENCE")
    eq(fence.code_block("x"), "BLOCK")
end

T["delegation"]["passes the content, floor and info string through unchanged"] = function()
    local seen = {}
    package.loaded["codecompanion.utils.markdown"] = {
        fence = function(content, min)
            seen.fence = { content, min }
            return "FENCE"
        end,
        code_block = function(content, opts)
            seen.code_block = { content, opts }
            return "BLOCK"
        end,
    }
    fence.reset()
    fence.fence("payload", 6)
    fence.code_block("payload", { info = "diff", min = 6 })
    eq(seen.fence, { "payload", 6 })
    eq(seen.code_block, { "payload", { info = "diff", min = 6 } })
end

T["delegation"]["falls back when CodeCompanion has no such module"] = function()
    -- The environment this suite runs in: no CodeCompanion on the runtimepath.
    eq(pcall(require, "codecompanion.utils.markdown"), false)
    eq(fence.code_block("a\n````\nb"), "`````\na\n````\nb\n`````")
end

T["delegation"]["falls back when the module lacks the expected functions"] = function()
    -- An older CodeCompanion, or one that renamed things: a partial module must be
    -- treated as absent rather than called and crashed into.
    package.loaded["codecompanion.utils.markdown"] = { fence = function() end }
    fence.reset()
    eq(fence.code_block("hello"), "````\nhello\n````")
end

--------------------------------------------------------------------------------
-- The three wrappers, driven through the real output handlers.
T["wrappers"] = new_set({
    hooks = {
        pre_case = function()
            -- `add_tool_output` reaches for CodeCompanion's constants; the extension
            -- is never loaded without CodeCompanion in production.
            package.loaded["codecompanion.config"] = {
                constants = { USER_ROLE = "user", LLM_ROLE = "llm" },
            }
        end,
        post_case = function()
            package.loaded["codecompanion.config"] = nil
            package.loaded["mcphub.utils.image_cache"] = nil
        end,
    },
})

--- A chat that records what the handlers hand it instead of rendering it.
local function chat_stub()
    local recorded = { output = {}, images = {} }
    local chat = {
        add_tool_output = function(_, _, for_llm, for_user)
            table.insert(recorded.output, { for_llm = for_llm, for_user = for_user })
        end,
        add_image_message = function(_, image)
            table.insert(recorded.images, image)
        end,
        add_message = function() end,
        add_buf_message = function() end,
    }
    return chat, recorded
end

---@param handler string "success" or "error"
---@param payload table|string The MCP result, or the stderr entry
---@return table recorded
local function run(handler, payload)
    local core = require("mcphub.extensions.codecompanion.core")
    ---@diagnostic disable-next-line: missing-fields
    local handlers = core.create_output_handlers("neovim__execute_command", true, { show_result_in_chat = true })
    local chat, recorded = chat_stub()
    handlers[handler]({}, { payload }, { tools = { chat = chat } })
    return recorded
end

T["wrappers"]["a clean result is one balanced block"] = function()
    local recorded = run("success", { text = "Exit Code: 0", images = {} })
    local out = blocks(recorded.output[1].for_user)
    eq(out.count, 1)
    eq(out.first, "Exit Code: 0\n")
end

T["wrappers"]["a clean result is still fenced with four backticks"] = function()
    -- DD8: every converted site keeps its previous fence length as a floor, so
    -- non-colliding output stays byte-identical to what shipped before.
    local recorded = run("success", { text = "Exit Code: 0", images = {} })
    local header = "**`neovim__execute_command` Tool**: Returned the following:"
    eq(recorded.output[1].for_llm, header .. "\n\n````\nExit Code: 0\n````")
end

T["wrappers"]["a colliding result survives in one block"] = function()
    local recorded = run("success", { text = COLLIDING, images = {} })
    local out = blocks(recorded.output[1].for_user)
    eq(out.count, 1)
    eq(out.first, COLLIDING .. "\n")
end

T["wrappers"]["a five-backtick line promotes the fence to six"] = function()
    local recorded = run("success", { text = "`````\nfive\n`````", images = {} })
    local out = blocks(recorded.output[1].for_user)
    eq(out.count, 1)
    eq(out.first, "`````\nfive\n`````\n")
end

T["wrappers"]["the LLM and the buffer get the same wrapped text"] = function()
    local recorded = run("success", { text = COLLIDING, images = {} })
    eq(recorded.output[1].for_llm, recorded.output[1].for_user)
end

T["wrappers"]["a colliding error is one balanced block"] = function()
    local recorded = run("error", "boom\n````\nstill the error")
    local out = blocks(recorded.output[1].for_user)
    eq(out.count, 1)
    eq(out.first, "boom\n````\nstill the error\n")
end

T["wrappers"]["an inspected error table is one balanced block"] = function()
    local recorded = run("error", { code = 1, detail = "````" })
    local out = blocks(recorded.output[1].for_user)
    eq(out.count, 1)
end

T["wrappers"]["the image-count fallback is one balanced block"] = function()
    package.loaded["mcphub.utils.image_cache"] = {
        save_image = function()
            return "/tmp/mcphub-test-image.png"
        end,
    }
    local recorded = run("success", { text = "", images = { { data = "x", mimeType = "image/png" } } })
    local out = blocks(recorded.output[1].for_llm)
    eq(out.count, 1)
    eq(out.first, "1 image returned\n")
end

T["wrappers"]["a spilled result is fenced on the notice, not the payload"] = function()
    -- The size guard rewrites oversized text into a spill notice *before* this
    -- wrapping, so the fence has to be computed from the final string. That ordering
    -- is not a theoretical concern: the notice quotes the payload's first line
    -- inline, so a payload whose first line is a four-backtick fence produces a
    -- notice containing a *six*-backtick run — a longer run than the payload itself
    -- ever had. Fencing the payload and then spilling would get this wrong.
    local guard = require("mcphub.extensions.codecompanion.size_guard")
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    guard.setup({ dir = dir, gc = false })

    local payload = "````\n" .. string.rep("x", spill.DEFAULT_MAX_BYTES) .. "\n````"
    local result = { text = payload, images = {} }
    eq(guard.apply(result, { server_name = "neovim", tool_name = "execute_command" }), true)

    local recorded = run("success", result)
    local out = blocks(recorded.output[1].for_user)
    eq(out.count, 1)
    eq(out.first, result.text .. "\n")
    local opening = recorded.output[1].for_user:match("\n\n(`+)\n")
    eq(opening, fence.fence(result.text))
    eq(#opening > #fence.fence(payload), true)

    guard.reset()
    vim.fn.delete(dir, "rf")
end

return T
