-- Tests for scoped forced confirmation: `view_image` asking before it reads
-- outside the chat's working directory, the *Allow … for this chat* choice in
-- mcphub.extensions.shared, and the per-chat store in
-- mcphub.native.utils.confirmation that the native server consults.
--
-- Run with `make test`, or just this file with
-- `make test_file FILE=tests/extensions/test_confirmation_scope.lua`.
---@diagnostic disable: duplicate-set-field, need-check-nil
local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local NativeServer = require("mcphub.native.utils.server")
local State = require("mcphub.state")
local confirmation = require("mcphub.native.utils.confirmation")
local native = require("mcphub.native")
local shared = require("mcphub.extensions.shared")
local view_image = require("mcphub.native.neovim.files.view_image")

local MEMORY_MODULE = "codecompanion.memory"
local real = {}

--- Every approval window that opened: its forced reason and the choices it offered.
---@type { forced_reason?: string, choices: table[] }[]
local prompts

--- Answer of the stubbed approval window, and the choice it returns.
local answer, choice

--- A fresh temp directory, removed after the case; its realpath.
---@return string
local function tempdir()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    MiniTest.finally(function()
        vim.fn.delete(dir, "rf")
    end)
    return assert(vim.uv.fs_realpath(dir))
end

--- Write a 10×10 PNG header to `path`, creating its directory.
---@param path string
---@return string path
local function image(path)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local file = assert(io.open(path, "wb"))
    file:write("\137PNG\r\n\26\n\0\0\0\13IHDR\0\0\0\10\0\0\0\10\8\6\0\0\0")
    file:close()
    return path
end

--- A chat whose working directory, as the stubbed memory module reports it, is `cwd`.
---@param cwd string
---@return table
local function new_chat(cwd)
    return { cwd = cwd }
end

---@param path string
---@param chat table?
---@return MCPHub.ParsedParams
local function parse(path, chat)
    return shared.parse_params(
        { server_name = "fake", tool_name = "view_image", tool_input = { path = path } },
        "use_mcp_tool",
        chat and { chat = chat } or nil
    )
end

--- Call `view_image` through the native server, as the CodeCompanion extension does.
---@param arguments table
---@param chat table?
---@return table? result
---@return string? err
local function call(arguments, chat)
    ---@diagnostic disable-next-line: missing-fields
    local server = setmetatable(
        { name = "fake", status = "connected", capabilities = { tools = { view_image.definition } } },
        NativeServer
    )
    local result, err, done
    server:call_tool("view_image", arguments, {
        caller = chat and { type = "codecompanion", codecompanion = { chat = chat } } or nil,
        callback = function(r, e)
            result, err, done = r, e, true
        end,
    })
    assert(vim.wait(1000, function()
        return done
    end, 10))
    return result, err
end

---@param choices table[]
---@param id string
---@return table?
local function find_choice(choices, id)
    for _, c in ipairs(choices) do
        if c.id == id then
            return c
        end
    end
end

local T = new_set({
    hooks = {
        pre_case = function()
            real.is_native_server = native.is_native_server
            real.is_auto_approved_in_server = shared.is_auto_approved_in_server
            real.show_mcp_tool_prompt = shared.show_mcp_tool_prompt
            real.auto_approve = State.config.auto_approve
            prompts, answer, choice = {}, true, nil
            native.is_native_server = function(name)
                return name == "fake" and { capabilities = { tools = { view_image.definition } } } or nil
            end
            shared.is_auto_approved_in_server = function()
                return false
            end
            shared.show_mcp_tool_prompt = function(params)
                table.insert(
                    prompts,
                    { forced_reason = params.forced_reason, choices = shared.decline_choices(params) }
                )
                return answer, false, choice
            end
            -- CodeCompanion isn't on the test runtimepath; this stands in for its memory module
            package.loaded[MEMORY_MODULE] = {
                chat_cwd = function(chat)
                    return chat.cwd
                end,
            }
        end,
        post_case = function()
            native.is_native_server = real.is_native_server
            shared.is_auto_approved_in_server = real.is_auto_approved_in_server
            shared.show_mcp_tool_prompt = real.show_mcp_tool_prompt
            State.config.auto_approve = real.auto_approve
            package.loaded[MEMORY_MODULE] = nil
        end,
    },
})

T["gate"] = new_set()

T["gate"]["asks nothing inside the chat's cwd"] = function()
    local dir = tempdir()
    image(vim.fs.joinpath(dir, "x.png"))
    local chat = new_chat(dir)

    eq(parse("x.png", chat).forced_reason, nil)
    State.config.auto_approve = true
    eq(shared.handle_auto_approval_decision(parse("x.png", chat)).approve, true)
    eq(#prompts, 0)
end

T["gate"]["forces a prompt outside the cwd, despite autoApprove"] = function()
    local dir = tempdir()
    local cwd = vim.fs.joinpath(dir, "project")
    vim.fn.mkdir(cwd, "p")
    local path = image(vim.fs.joinpath(dir, "downloads", "x.png"))
    shared.is_auto_approved_in_server = function()
        return true
    end

    shared.handle_auto_approval_decision(parse(path, new_chat(cwd)))

    eq(#prompts, 1)
    eq(prompts[1].forced_reason, ("reads %s, outside the chat's working directory %s"):format(path, cwd))
    local allow = assert(find_choice(prompts[1].choices, "allow_scope"))
    eq(allow.key, "f")
    eq(allow.label, ("Allow %s for this chat"):format(vim.fn.fnamemodify(vim.fs.dirname(path), ":~")))
end

T["gate"]["approving once runs the call and nothing more"] = function()
    local dir = tempdir()
    local cwd = vim.fs.joinpath(dir, "project")
    vim.fn.mkdir(cwd, "p")
    local first = image(vim.fs.joinpath(dir, "downloads", "a.png"))
    local second = image(vim.fs.joinpath(dir, "downloads", "b.png"))
    local chat = new_chat(cwd)

    local parsed = parse(first, chat)
    eq(shared.handle_auto_approval_decision(parsed).approve, true)
    local result, err = call(parsed.arguments, chat)
    eq(err, nil)
    eq(result.result.isError, nil)

    eq(parse(second, chat).forced_reason ~= nil, true)
    eq(select(2, call({ path = second }, chat)) ~= nil, true)
end

T["gate"]["approving for the chat covers the directory and below"] = function()
    local dir = tempdir()
    local cwd = vim.fs.joinpath(dir, "project")
    vim.fn.mkdir(cwd, "p")
    local downloads = vim.fs.joinpath(dir, "downloads")
    local first = image(vim.fs.joinpath(downloads, "a.png"))
    local second = image(vim.fs.joinpath(downloads, "b.png"))
    local nested = image(vim.fs.joinpath(downloads, "shots", "c.png"))
    local chat = new_chat(cwd)
    answer, choice = false, { id = "allow_scope" }

    local parsed = parse(first, chat)
    local decision = shared.handle_auto_approval_decision(parsed)
    eq(decision.approve, true)
    eq(decision.arguments, parsed.arguments)
    eq(select(2, call(decision.arguments, chat)), nil)

    eq(confirmation.scope_allowed(chat, downloads), true)
    for _, path in ipairs({ second, nested }) do
        eq(parse(path, chat).forced_reason, nil)
        local result, err = call({ path = path }, chat)
        eq(err, nil)
        eq(result.result.isError, nil)
    end
    eq(#prompts, 1)
end

T["gate"]["a scope belongs to one chat"] = function()
    local dir = tempdir()
    local cwd = vim.fs.joinpath(dir, "project")
    vim.fn.mkdir(cwd, "p")
    local path = image(vim.fs.joinpath(dir, "downloads", "a.png"))
    local first, second = new_chat(cwd), new_chat(cwd)

    confirmation.allow_scope(first, vim.fs.dirname(path))

    eq(parse(path, first).forced_reason, nil)
    eq(parse(path, second).forced_reason ~= nil, true)
    eq(select(2, call({ path = path }, second)) ~= nil, true)
end

T["gate"]["a sibling directory is not covered"] = function()
    local dir = tempdir()
    local cwd = vim.fs.joinpath(dir, "project")
    vim.fn.mkdir(cwd, "p")
    local path = image(vim.fs.joinpath(dir, "ab", "x.png"))
    local chat = new_chat(cwd)

    confirmation.allow_scope(chat, vim.fs.joinpath(dir, "a"))

    eq(parse(path, chat).forced_reason ~= nil, true)
end

T["gate"]["without a chat there is no scope to offer"] = function()
    local dir = tempdir()
    local path = image(vim.fs.joinpath(dir, "x.png"))
    -- Without a chat the global cwd is the boundary, and the temp directory lies outside it
    local parsed = parse(path, nil)

    eq(parsed.forced_scope ~= nil, true)
    shared.handle_auto_approval_decision(parsed)
    eq(#prompts, 1)
    eq(find_choice(prompts[1].choices, "allow_scope"), nil)
    eq(find_choice(prompts[1].choices, "dont") ~= nil, true)
end

T["gate"]["declining leaves no scope behind"] = function()
    local dir = tempdir()
    local cwd = vim.fs.joinpath(dir, "project")
    vim.fn.mkdir(cwd, "p")
    local path = image(vim.fs.joinpath(dir, "downloads", "a.png"))
    local chat = new_chat(cwd)
    answer, choice = false, { id = "dont" }

    eq(shared.handle_auto_approval_decision(parse(path, chat)).approve, false)
    eq(confirmation.scope_allowed(chat, path), false)
end

T["enforcement"] = new_set()

T["enforcement"]["refuses an outside path the gate never approved"] = function()
    local dir = tempdir()
    local cwd = vim.fs.joinpath(dir, "project")
    vim.fn.mkdir(cwd, "p")
    local path = image(vim.fs.joinpath(dir, "downloads", "a.png"))

    local result, err = call({ path = path }, new_chat(cwd))

    eq(result, nil)
    eq(err ~= nil and err:find("needs the user's confirmation", 1, true) ~= nil, true)
end

T["enforcement"]["runs an outside path inside an approved scope without a grant"] = function()
    local dir = tempdir()
    local cwd = vim.fs.joinpath(dir, "project")
    vim.fn.mkdir(cwd, "p")
    local path = image(vim.fs.joinpath(dir, "downloads", "a.png"))
    local chat = new_chat(cwd)
    confirmation.allow_scope(chat, vim.fs.dirname(path))

    local result, err = call({ path = path }, chat)

    eq(err, nil)
    eq(result.result.content[2].mimeType, "image/png")
end

T["store"] = new_set()

T["store"]["covers a directory and what lies below it"] = function()
    local chat = {}
    confirmation.allow_scope(chat, "/x/a")
    eq(confirmation.scope_allowed(chat, "/x/a"), true)
    eq(confirmation.scope_allowed(chat, "/x/a/b.png"), true)
    eq(confirmation.scope_allowed(chat, "/x/a/b/c.png"), true)
    eq(confirmation.scope_allowed(chat, "/x/ab/c.png"), false)
    eq(confirmation.scope_allowed(chat, "/x/b.png"), false)
end

T["store"]["remembers nothing without a chat"] = function()
    confirmation.allow_scope(nil, "/x/a")
    eq(confirmation.scope_allowed(nil, "/x/a/b.png"), false)
end

T["store"]["passes a plain reason through unscoped"] = function()
    local reason, scope = confirmation.reason({
        confirm_if = function()
            return "because"
        end,
    }, {}, { chat = {} })
    eq({ reason, scope }, { "because", nil })
end

return T
