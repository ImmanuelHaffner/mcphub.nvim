-- Tests for forced confirmation: the approval gate in mcphub.extensions.shared
-- and its enforcement in NativeServer:call_tool.
--
-- Run with `make test`, or just this file with
-- `make test_file FILE=tests/extensions/test_shared.lua`.
local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local NativeServer = require("mcphub.native.utils.server")
local State = require("mcphub.state")
local confirmation = require("mcphub.native.utils.confirmation")
local exec_command = require("mcphub.native.neovim.exec_command")
local native = require("mcphub.native")
local shared = require("mcphub.extensions.shared")

local real = {}

--- Every call that opened the approval window, with the reason it showed.
---@type { forced_reason?: string }[]
local prompts

--- Answer of the stubbed approval window, and the decline reason it returns.
local answer, choice

--- Serve `tool` as the only tool of the native server "fake".
---@param tool table
local function serve(tool)
    native.is_native_server = function(name)
        return name == "fake" and { capabilities = { tools = { tool } } } or nil
    end
end

---@param arguments table
---@return MCPHub.ParsedParams
local function parse(arguments)
    return shared.parse_params(
        { server_name = "fake", tool_name = "execute_command", tool_input = arguments },
        "use_mcp_tool"
    )
end

--- A connected native server whose `execute_command` records the params it
--- was called with instead of running anything.
---@return NativeServer server
---@return table[] calls
local function recording_server()
    local calls = {}
    local tool = vim.tbl_extend("force", exec_command.definition, {
        handler = function(req, res)
            table.insert(calls, req.params)
            return res:text("ran"):send()
        end,
    })
    local server =
        setmetatable({ name = "fake", status = "connected", capabilities = { tools = { tool } } }, NativeServer)
    return server, calls
end

---@param server NativeServer
---@param arguments table
---@return any result
---@return string? err
local function call(server, arguments)
    local result, err, done
    server:call_tool("execute_command", arguments, {
        callback = function(r, e)
            result, err, done = r, e, true
        end,
    })
    assert(vim.wait(1000, function()
        return done
    end, 10))
    return result, err
end

local T = new_set({
    hooks = {
        pre_case = function()
            real.is_native_server = native.is_native_server
            real.is_auto_approved_in_server = shared.is_auto_approved_in_server
            real.show_mcp_tool_prompt = shared.show_mcp_tool_prompt
            real.auto_approve = State.config.auto_approve
            real.builtin_tools = State.config.builtin_tools
            State.config.builtin_tools = nil
            prompts, answer, choice = {}, true, nil
            shared.is_auto_approved_in_server = function()
                return false
            end
            shared.show_mcp_tool_prompt = function(params)
                table.insert(prompts, { forced_reason = params.forced_reason })
                return answer, false, choice
            end
            serve(exec_command.definition)
        end,
        post_case = function()
            native.is_native_server = real.is_native_server
            shared.is_auto_approved_in_server = real.is_auto_approved_in_server
            shared.show_mcp_tool_prompt = real.show_mcp_tool_prompt
            State.config.auto_approve = real.auto_approve
            State.config.builtin_tools = real.builtin_tools
        end,
    },
})

T["gate"] = new_set()

T["gate"]["forces confirmation despite auto_approve = true"] = function()
    State.config.auto_approve = true
    local decision = shared.handle_auto_approval_decision(parse({ command = "true", cwd = "/tmp", timeout = 601 }))
    eq(#prompts, 1)
    eq(prompts[1].forced_reason, "timeout 601 s exceeds the 600 s soft limit")
    eq(decision.approve, true)
end

T["gate"]["forces confirmation despite servers.json autoApprove"] = function()
    shared.is_auto_approved_in_server = function()
        return true
    end
    shared.handle_auto_approval_decision(parse({ command = "true", cwd = "/tmp", timeout = 0 }))
    eq(#prompts, 1)
    eq(prompts[1].forced_reason, "no timeout requested (timeout = 0)")
end

T["gate"]["forces confirmation despite a custom auto_approve function"] = function()
    State.config.auto_approve = function()
        return true
    end
    shared.handle_auto_approval_decision(parse({ command = "true", cwd = "/tmp", timeout = 0 }))
    eq(#prompts, 1)
end

T["gate"]["does not force within the soft limit"] = function()
    State.config.auto_approve = true
    local decision = shared.handle_auto_approval_decision(parse({ command = "true", cwd = "/tmp", timeout = 600 }))
    eq(#prompts, 0)
    eq(decision.approve, true)
end

T["gate"]["declining rejects"] = function()
    State.config.auto_approve = true
    answer = false
    local decision = shared.handle_auto_approval_decision(parse({ command = "true", cwd = "/tmp", timeout = 0 }))
    eq(decision.approve, false)
    eq(decision.error, "User cancelled the operation")
end

T["gate"]["a throwing confirm_if forces confirmation"] = function()
    State.config.auto_approve = true
    serve({
        name = "execute_command",
        confirm_if = function()
            error("boom")
        end,
        handler = function() end,
    })
    shared.handle_auto_approval_decision(parse({}))
    eq(#prompts, 1)
    eq(vim.startswith(prompts[1].forced_reason, "confirm_if failed"), true)
end

T["decline reasons"] = new_set()

T["decline reasons"]["keys are unique and avoid the window's own"] = function()
    local taken = {}
    for _, key in ipairs(require("mcphub.utils.ui").CONFIRM_RESERVED_KEYS) do
        taken[key:lower()] = "reserved"
    end
    for _, reason in ipairs(shared.DECLINE_REASONS) do
        eq({ reason.id, taken[reason.key:lower()] }, { reason.id, nil })
        taken[reason.key:lower()] = reason.id
    end
end

---@param decision_choice MCPHub.ConfirmChoiceResult
---@return string
local function declined_with(decision_choice)
    answer, choice = false, decision_choice
    local decision = shared.handle_auto_approval_decision(parse({ command = "ls", cwd = "/tmp" }))
    eq(decision.approve, false)
    return decision.error
end

T["decline reasons"]["each reason's message reaches the LLM"] = function()
    eq(declined_with({ id = "wrong" }), "The user says this command is wrong. Reconsider it before retrying.")
    eq(declined_with({ id = "dont" }), "The user declined to run this command. Do not retry it.")
    eq(declined_with({ id = "scope" }):find("this command's scope is too broad", 1, true) ~= nil, true)
    eq(
        declined_with({ id = "cwd" }),
        "The user says the working directory `/tmp` is wrong for this command. Reconsider `cwd` before retrying."
    )
    eq(declined_with({ id = "ask" }):find("why this command is needed", 1, true) ~= nil, true)
    eq(declined_with({ id = "myself" }):find("will run this command themselves", 1, true) ~= nil, true)
    eq(declined_with({ id = "other", text = "use git mv instead" }), "The user declined: use git mv instead")
    eq(#prompts, 7)
end

T["decline reasons"]["other tools are a call"] = function()
    serve({ name = "execute_command", handler = function() end })
    eq(declined_with({ id = "wrong" }), "The user says this call is wrong. Reconsider it before retrying.")
end

---@param parsed MCPHub.ParsedParams
---@return table<string, string> labels by id
local function offered(parsed)
    local labels = {}
    for _, c in ipairs(shared.decline_choices(parsed)) do
        labels[c.id] = c.label
    end
    return labels
end

T["decline reasons"]["Wrong cwd only for tools that declare cwd_param"] = function()
    local labels = offered(parse({ command = "ls", cwd = "/tmp" }))
    eq(labels.cwd, "Wrong cwd")
    eq(labels.wrong, "Wrong command")

    serve({ name = "execute_command", handler = function() end })
    labels = offered(parse({ command = "ls", cwd = "/tmp" }))
    eq(labels.cwd, nil)
    eq(labels.wrong, "Wrong call")
    eq(vim.tbl_count(labels), #shared.DECLINE_REASONS - 1)
end

T["decline reasons"]["the approval window offers them"] = function()
    shared.show_mcp_tool_prompt = real.show_mcp_tool_prompt
    local ui = require("mcphub.utils.ui")
    local confirm = ui.confirm
    local seen
    ui.confirm = function(_, opts)
        seen = opts.choices
        return false, false, { id = "dont" }
    end
    local ok, err = pcall(function()
        eq(declined_with({ id = "dont" }), "The user declined to run this command. Do not retry it.")
    end)
    ui.confirm = confirm
    assert(ok, err)
    eq(seen, shared.decline_choices(parse({ command = "ls", cwd = "/tmp" })))
end

T["enforcement"] = new_set()

T["enforcement"]["refuses an exemption the gate never approved"] = function()
    local server, calls = recording_server()
    for _, timeout in ipairs({ 0, 601, math.huge }) do
        local _, err = call(server, { command = "true", cwd = "/tmp", timeout = timeout })
        eq(err ~= nil and err:find("needs the user's confirmation", 1, true) ~= nil, true)
    end
    eq(#calls, 0)
end

T["enforcement"]["runs a call within the soft limit without a grant"] = function()
    local server, calls = recording_server()
    local _, err = call(server, { command = "true", cwd = "/tmp", timeout = 600 })
    eq(err, nil)
    eq(#calls, 1)
end

T["enforcement"]["runs the exact arguments the gate approved, once"] = function()
    local server, calls = recording_server()
    State.config.auto_approve = true
    local parsed = parse({ command = "true", cwd = "/tmp", timeout = 0 })
    eq(shared.handle_auto_approval_decision(parsed).approve, true)

    eq(select(2, call(server, vim.deepcopy(parsed.arguments))) ~= nil, true)
    eq(select(2, call(server, parsed.arguments)), nil)
    eq(select(2, call(server, parsed.arguments)) ~= nil, true)
    eq(#calls, 1)
end

T["enforcement"]["a declined call stays refused"] = function()
    local server, calls = recording_server()
    State.config.auto_approve = true
    answer = false
    local parsed = parse({ command = "true", cwd = "/tmp", timeout = 0 })
    shared.handle_auto_approval_decision(parsed)
    eq(select(2, call(server, parsed.arguments)) ~= nil, true)
    eq(#calls, 0)
end

T["enforcement"]["a manual grant is honoured"] = function()
    local server, calls = recording_server()
    local arguments = { command = "true", cwd = "/tmp", timeout = 0 }
    confirmation.grant(arguments)
    eq(select(2, call(server, arguments)), nil)
    eq(#calls, 1)
end

return T
