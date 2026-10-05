local M = {}
local NuiLine = require("mcphub.utils.nuiline")
local State = require("mcphub.state")
local Text = require("mcphub.utils.text")
local confirmation = require("mcphub.native.utils.confirmation")
local native = require("mcphub.native")
local ui_utils = require("mcphub.utils.ui")
local utils = require("mcphub.utils")

---@class MCPHub.ParsedParams
---@field errors string[] List of errors encountered during parsing
---@field action MCPHub.ActionType Action type, either "use_mcp_tool" or "access_mcp_resource"
---@field server_name string Name of the server to call the tool/resource on
---@field tool_name string Name of the tool to call (nil for resources)
---@field arguments table Input arguments for the tool call (empty table for resources)
---@field uri string URI of the resource to access (nil for tools)
---@field is_auto_approved_in_server boolean Whether the tool autoApproved in the servers.json
---@field needs_confirmation_window boolean Whether the tool call needs a confirmation window
---@field forced_reason string? Why the call must be confirmed whatever the auto-approve settings say

---@class MCPHub.ToolCallArgs
---@field server_name string Name of the server to call the tool on.
---@field tool_name string Name of the tool to call.
---@field tool_input table | string Input for the tool call. Must be an object for `use_mcp_tool` action.

---@class MCPHub.ResourceAccessArgs
---@field server_name string Name of the server to call the resource on.
---@field uri string URI of the resource to access.

---@param server_name string Name of the server to check
---@param tool_name string Name of the tool to check
---@return boolean Whether the tool is auto-approved in the server
function M.is_auto_approved_in_server(server_name, tool_name)
    local config_manager = require("mcphub.utils.config_manager")
    local server_config = config_manager.get_server_config(server_name) or {}
    local auto_approve = server_config.autoApprove
    if not auto_approve then
        return false
    end
    -- If autoApprove is true, approve everything for this server
    if auto_approve == true then
        return true
    end
    -- If autoApprove is an array, check if tool is in the list
    if type(auto_approve) == "table" and vim.islist(auto_approve) then
        return vim.tbl_contains(auto_approve, tool_name)
    end
    return false
end

---@param params MCPHub.ToolCallArgs | MCPHub.ResourceAccessArgs
---@param action_name MCPHub.ActionType
---@return MCPHub.ParsedParams
function M.parse_params(params, action_name)
    params = params or {}

    local server_name = params.server_name
    local tool_name = params.tool_name
    local uri = params.uri
    local arguments = params.tool_input or {}
    if type(arguments) == "string" then
        local json_ok, decode_result = utils.json_decode(arguments or "{}")
        if json_ok then
            arguments = decode_result or {}
        else
            arguments = {}
        end
    end
    local errors = {}
    if not vim.tbl_contains({ "use_mcp_tool", "access_mcp_resource" }, action_name) then
        table.insert(errors, "Action must be one of `use_mcp_tool` or `access_mcp_resource`")
    end
    if not server_name then
        table.insert(errors, "server_name is required")
    end
    if action_name == "use_mcp_tool" and not tool_name then
        table.insert(errors, "tool_name is required")
    end
    if action_name == "use_mcp_tool" and type(arguments) ~= "table" then
        table.insert(errors, "tool_input must be an object")
    end

    if action_name == "access_mcp_resource" and not uri then
        table.insert(errors, "uri is required")
    end

    return {
        errors = errors,
        action = action_name or "nil",
        server_name = server_name or "nil",
        tool_name = tool_name or "nil",
        arguments = arguments or {},
        uri = uri or "nil",
        needs_confirmation_window = M.needs_confirmation_window(server_name, tool_name),
        is_auto_approved_in_server = M.is_auto_approved_in_server(server_name, tool_name),
        forced_reason = action_name == "use_mcp_tool"
                and M.forced_confirmation_reason(server_name, tool_name, arguments)
            or nil,
    }
end

--- The definition of a native tool, or nil for anything else (remote tools, resources).
---@param server_name string?
---@param tool_name string?
---@return MCPTool?
local function find_native_tool(server_name, tool_name)
    local server = server_name and native.is_native_server(server_name)
    if not server then
        return nil
    end
    for _, tool in ipairs(server.capabilities.tools) do
        if tool.name == tool_name then
            return tool
        end
    end
    return nil
end

--- Why the call must be confirmed whatever the auto-approve settings say, if
--- its native tool declares `confirm_if` and objects to these arguments.
---@param server_name string?
---@param tool_name string?
---@param arguments table
---@return string? reason
function M.forced_confirmation_reason(server_name, tool_name, arguments)
    local tool = find_native_tool(server_name, tool_name)
    return tool and confirmation.reason(tool, arguments) or nil
end

---@class MCPHub.DeclineContext
---@field noun string The tool's `call_noun`, or "call"
---@field tool table The native tool definition, or an empty table
---@field arguments table
---@field text? string Free text from an `input` reason

---@class MCPHub.DeclineReason
---@field id string
---@field key string Hard-coded so muscle memory carries across tools; never reused
---@field label string May contain one `%s` for the noun
---@field input? boolean
---@field requires? string A tool field the reason needs; without it the reason is not offered
---@field message fun(ctx: MCPHub.DeclineContext): string What the LLM is told

--- Reasons the user can give for declining a call, in display order.
---@type MCPHub.DeclineReason[]
M.DECLINE_REASONS = {
    {
        id = "wrong",
        key = "w",
        label = "Wrong %s",
        message = function(ctx)
            return ("The user says this %s is wrong. Reconsider it before retrying."):format(ctx.noun)
        end,
    },
    {
        id = "dont",
        key = "d",
        label = "Don't execute",
        message = function(ctx)
            return ("The user declined to run this %s. Do not retry it."):format(ctx.noun)
        end,
    },
    {
        id = "scope",
        key = "s",
        label = "Scope too broad",
        message = function(ctx)
            return ("The user says this %s's scope is too broad. Narrow it (paths, filters, limits) and retry."):format(
                ctx.noun
            )
        end,
    },
    {
        id = "cwd",
        key = "x",
        label = "Wrong cwd",
        requires = "cwd_param",
        message = function(ctx)
            local param = ctx.tool.cwd_param
            return ("The user says the working directory `%s` is wrong for this %s. Reconsider `%s` before retrying."):format(
                tostring(ctx.arguments[param]),
                ctx.noun,
                param
            )
        end,
    },
    {
        id = "ask",
        key = "a",
        label = "Ask first",
        message = function(ctx)
            return ("The user wants to know why this %s is needed. Explain your reasoning and wait for their go-ahead before retrying."):format(
                ctx.noun
            )
        end,
    },
    {
        id = "myself",
        key = "m",
        label = "I'll run it myself",
        message = function(ctx)
            return ("The user will run this %s themselves. Do not retry it; wait for them to report back."):format(
                ctx.noun
            )
        end,
    },
    {
        id = "other",
        key = "o",
        label = "Other…",
        input = true,
        message = function(ctx)
            return "The user declined: " .. ctx.text
        end,
    },
}

---@param parsed_params MCPHub.ParsedParams
---@return MCPHub.DeclineContext
local function decline_context(parsed_params)
    local tool = find_native_tool(parsed_params.server_name, parsed_params.tool_name) or {}
    return { noun = tool.call_noun or "call", tool = tool, arguments = parsed_params.arguments or {} }
end

--- The decline choices the approval window offers for this call.
---@param parsed_params MCPHub.ParsedParams
---@return MCPHub.ConfirmChoice[]
function M.decline_choices(parsed_params)
    local ctx = decline_context(parsed_params)
    local choices = {}
    for _, reason in ipairs(M.DECLINE_REASONS) do
        if not reason.requires or ctx.tool[reason.requires] then
            table.insert(choices, {
                key = reason.key,
                id = reason.id,
                input = reason.input,
                label = reason.label:format(ctx.noun),
            })
        end
    end
    return choices
end

--- What the LLM is told when the user declines with `choice`.
---@param choice MCPHub.ConfirmChoiceResult
---@param parsed_params MCPHub.ParsedParams
---@return string
function M.decline_message(choice, parsed_params)
    local ctx = decline_context(parsed_params)
    ctx.text = choice.text
    for _, reason in ipairs(M.DECLINE_REASONS) do
        if reason.id == choice.id then
            return reason.message(ctx)
        end
    end
    return "User cancelled the operation"
end

--- For some built-in tools, we already show interactive diffs, before confirmation.
---@param server_name string Name of the server
---@param tool_name string Name of the tool to check
function M.needs_confirmation_window(server_name, tool_name)
    local server = native.is_native_server(server_name)
    if not server then
        return true
    end
    for _, tool in ipairs(server.capabilities.tools) do
        if tool.name == tool_name and tool.needs_confirmation_window == false then
            return false
        end
    end
    return true
end
---@param arguments MCPPromptArgument[]
---@param callback fun(values: string[])
function M.collect_arguments(arguments, callback)
    local values = {}
    local should_proceed = true

    local function collect_input(index)
        if index > #arguments and should_proceed then
            callback(values)
            return
        end

        local arg = arguments[index]
        local title = string.format("%s %s", arg.name, arg.required and "(required)" or "")
        local default = arg.default or ""

        local function submit_input(input)
            if arg.required and (input == nil or input == "") then
                vim.notify("Value for " .. arg.name .. " is required", vim.log.levels.ERROR)
                should_proceed = false
                return
            end

            values[arg.name] = input
            collect_input(index + 1)
        end

        local function cancel_input()
            if arg.required then
                vim.notify("Value for " .. arg.name .. " is required", vim.log.levels.ERROR)
                should_proceed = false
                return
            end
            values[arg.name] = nil
            collect_input(index + 1)
        end
        ui_utils.multiline_input(title, default, submit_input, { on_cancel = cancel_input })
    end

    if #arguments > 0 then
        vim.defer_fn(function()
            collect_input(1)
        end, 0)
    else
        callback(values)
    end
end

---Create the confirmation prompt for mcp tool
---@param params MCPHub.ParsedParams
---@return string
function M.get_mcp_tool_prompt(params)
    local action_name = params.action
    local server_name = params.server_name
    local tool_name = params.tool_name
    local uri = params.uri
    local arguments = params.arguments or {}

    local args = ""
    for k, v in pairs(arguments) do
        args = args .. k .. ":\n "
        if type(v) == "string" then
            local lines = vim.split(v, "\n")
            for _, line in ipairs(lines) do
                args = args .. line .. "\n"
            end
        else
            args = args .. vim.inspect(v) .. "\n"
        end
    end
    local msg = ""
    if action_name == "use_mcp_tool" then
        msg = string.format(
            [[Do you want to run the `%s` tool on the `%s` mcp server with arguments:
%s]],
            tool_name,
            server_name,
            args
        )
    elseif action_name == "access_mcp_resource" then
        msg = string.format("Do you want to access the resource `%s` on the `%s` server?", uri, server_name)
    end
    return msg
end

---@param params MCPHub.ParsedParams
---@return boolean confirmed
---@return boolean cancelled
---@return MCPHub.ConfirmChoiceResult? choice The decline reason the user picked, if any
function M.show_mcp_tool_prompt(params)
    local action_name = params.action
    local server_name = params.server_name
    local tool_name = params.tool_name
    local uri = params.uri
    local arguments = params.arguments or {}

    local lines = {}
    local is_tool = action_name == "use_mcp_tool"

    -- Header as a question
    local header_line = NuiLine()
    header_line:append(Text.icons.event, Text.highlights.warn)
    header_line:append(" Do you want to ", Text.highlights.text)
    if is_tool then
        header_line:append("call ", Text.highlights.text)
        header_line:append(tool_name, Text.highlights.warn_italic)
    else
        header_line:append("access ", Text.highlights.text)
        header_line:append(uri, Text.highlights.link)
    end
    header_line:append(" on ", Text.highlights.text)
    header_line:append(server_name, Text.highlights.success_italic)
    header_line:append("?", Text.highlights.text)
    table.insert(lines, header_line)

    if params.forced_reason then
        local reason_line = NuiLine()
        reason_line:append(Text.icons.warn .. " Confirmation required: ", Text.highlights.warn)
        reason_line:append(params.forced_reason, Text.highlights.warn_italic)
        table.insert(lines, reason_line)
    end

    -- Parameters section
    if is_tool and next(arguments) then
        table.insert(lines, NuiLine():append(""))

        for key, value in pairs(arguments) do
            -- Parameter name
            local param_name_line = NuiLine()
            param_name_line:append(Text.icons.param, Text.highlights.info)
            param_name_line:append(" " .. key .. ":", Text.highlights.json_property)
            table.insert(lines, param_name_line)

            -- Parameter value
            local function add_value_lines(val)
                if type(val) == "string" then
                    local value_lines = val:find("\n") and vim.split(val, "\n", { plain = true })
                        or { '"' .. val .. '"' }
                    for _, line in ipairs(value_lines) do
                        local value_line = NuiLine()
                        value_line:append("    " .. line, Text.highlights.json_string)
                        table.insert(lines, value_line)
                    end
                elseif type(val) == "boolean" then
                    local value_line = NuiLine()
                    value_line:append("    " .. tostring(val), Text.highlights.json_boolean)
                    table.insert(lines, value_line)
                elseif type(val) == "number" then
                    local value_line = NuiLine()
                    value_line:append("    " .. tostring(val), Text.highlights.json_number)
                    table.insert(lines, value_line)
                else
                    for _, line in ipairs(vim.split(vim.inspect(val), "\n", { plain = true })) do
                        local value_line = NuiLine()
                        value_line:append("    " .. line, Text.highlights.muted)
                        table.insert(lines, value_line)
                    end
                end
            end

            add_value_lines(value)
            table.insert(lines, NuiLine():append(""))
        end
    end

    -- Fire event before showing confirmation window
    utils.fire("MCPHubApprovalWindowOpened", {
        action = action_name,
        server_name = server_name,
        tool_name = tool_name,
        uri = uri,
        arguments = arguments,
    })
    local confirmed, cancelled, choice = require("mcphub.utils.ui").confirm(lines, {
        min_width = 70,
        max_width = 100,
        choices = M.decline_choices(params),
    })
    -- Fire event after user makes decision
    utils.fire("MCPHubApprovalWindowClosed", {
        action = action_name,
        server_name = server_name,
        tool_name = tool_name,
        uri = uri,
        arguments = arguments,
        confirmed = confirmed,
        cancelled = cancelled,
    })

    return confirmed, cancelled, choice
end

---@param parsed_params MCPHub.ParsedParams
---@return {error?:string, approve:boolean}
function M.handle_auto_approval_decision(parsed_params)
    local auto_approve = State.config.auto_approve or false
    local status = { approve = false, error = nil }
    --- If user has a custom function that decides whether to auto-approve
    --- call that with params + saved autoApprove state as is_auto_approved_in_server field
    if type(auto_approve) == "function" then
        local ok, res = pcall(auto_approve, parsed_params)
        if not ok or type(res) == "string" then
            --- If auto_approve function throws an error, or returns a string, treat it as an error
            status = { approve = false, error = res }
        elseif type(res) == "boolean" then
            --- If auto_approve function returns a boolean, use that as the decision
            status = { approve = res, error = nil }
        end
    elseif type(auto_approve) == "boolean" then
        status = { approve = auto_approve, error = nil }
    end

    -- Check if auto-approval is enabled in servers.json
    if parsed_params.is_auto_approved_in_server then
        status = { approve = true, error = nil }
    end

    if status.error then
        return { error = status.error or "Something went wrong with auto-approval", approve = false }
    end

    if parsed_params.forced_reason or (status.approve == false and parsed_params.needs_confirmation_window) then
        local confirmed, _, choice = M.show_mcp_tool_prompt(parsed_params)
        if confirmed and parsed_params.forced_reason then
            confirmation.grant(parsed_params.arguments)
        end
        if choice then
            return { error = M.decline_message(choice, parsed_params), approve = false }
        end
        return { error = not confirmed and "User cancelled the operation", approve = confirmed }
    end
    return status
end

return M
