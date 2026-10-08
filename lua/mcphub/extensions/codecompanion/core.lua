local M = {}
local async = require("plenary.async")
local exec_ui = require("mcphub.extensions.codecompanion.exec_ui")
local fence = require("mcphub.utils.fence")
local shared = require("mcphub.extensions.shared")
local size_guard = require("mcphub.extensions.codecompanion.size_guard")
local utils = require("mcphub.utils")

--- Core MCP tool execution logic
---@param params MCPHub.ToolCallArgs | MCPHub.ResourceAccessArgs
---@param agent CodeCompanion.Agent The Editor tool
---@param output_handler function Callback for asynchronous calls
---@param context MCPHub.ToolCallContext
---@return nil|{ status: "success"|"error", data: string }
function M.execute_mcp_tool(params, tools, output_handler, context)
    context = context or {}
    ---@diagnostic disable-next-line: missing-parameter
    async.run(function()
        -- Reuse existing validation logic
        local parsed_params = shared.parse_params(params, context.action)
        if #parsed_params.errors > 0 then
            return output_handler({
                status = "error",
                data = table.concat(parsed_params.errors, "\n"),
            })
        end

        -- Before the approval gate, so the command is in the chat while the window is open.
        exec_ui.show_command(tools, parsed_params)

        local result = shared.handle_auto_approval_decision(parsed_params)

        if result.error then
            return output_handler({
                status = "error",
                data = result.error,
            })
        end

        local hub = require("mcphub").get_hub_instance()
        if not hub then
            return output_handler({
                status = "error",
                data = "MCP Hub is not ready yet",
            })
        end

        -- Call appropriate hub method
        if parsed_params.action == "access_mcp_resource" then
            hub:access_resource(parsed_params.server_name, parsed_params.uri, {
                caller = {
                    type = "codecompanion",
                    codecompanion = tools,
                    auto_approve = result.approve,
                },
                parse_response = true,
                callback = function(res, err)
                    if err or not res then
                        output_handler({
                            status = "error",
                            data = err and tostring(err)
                                or "No response from accessing the resource " .. parsed_params.uri,
                        })
                    elseif res then
                        -- Guarded here, not in the output handler, because this is
                        -- where the capability's real identity is known.
                        size_guard.apply(res, { server_name = parsed_params.server_name, uri = parsed_params.uri })
                        output_handler({ status = "success", data = res })
                    end
                end,
            })
        elseif parsed_params.action == "use_mcp_tool" then
            local arguments = result.arguments or parsed_params.arguments
            hub:call_tool(parsed_params.server_name, parsed_params.tool_name, arguments, {
                caller = {
                    type = "codecompanion",
                    codecompanion = tools,
                    auto_approve = result.approve,
                    -- Resources run no process worth stopping, so only tools get it.
                    register_job = context.register_job,
                    on_job = function(job)
                        exec_ui.attach(tools, job)
                    end,
                },
                parse_response = true,
                callback = function(res, err)
                    if err or not res then
                        output_handler({ status = "error", data = tostring(err) or "No response from tool call" })
                    elseif res.error then
                        output_handler({ status = "error", data = res.error })
                    else
                        size_guard.apply(
                            res,
                            { server_name = parsed_params.server_name, tool_name = parsed_params.tool_name }
                        )
                        output_handler({ status = "success", data = res })
                    end
                end,
            })
        else
            return output_handler({
                status = "error",
                data = "Invalid action type: " .. parsed_params.action,
            })
        end
    end)
end

---@param display_name string
---@param tool CodeCompanion.Agent.Tool
---@param chat any
---@param llm_msg string
---@param is_error boolean
---@param has_function_calling boolean
---@param opts MCPHub.Extensions.CodeCompanionConfig
---@param user_msg string?
---@param images table
-- Helper function for tool output formatting
local function add_tool_output(
    display_name,
    tool,
    chat,
    llm_msg,
    is_error,
    has_function_calling,
    opts,
    user_msg,
    images
)
    local config = require("codecompanion.config")
    local show_result_in_chat = opts.show_result_in_chat == true
    local text = llm_msg
    local formatted_name = opts.format_tool and opts.format_tool(display_name, tool) or display_name

    if has_function_calling then
        chat:add_tool_output(
            tool,
            text,
            (user_msg or show_result_in_chat or is_error) and (user_msg or text)
                or string.format("**`%s` Tool**: Successfully finished", formatted_name)
        )
        for _, image in ipairs(images) do
            chat:add_image_message(image)
        end
    else
        if show_result_in_chat or is_error then
            chat:add_buf_message({
                role = config.constants.USER_ROLE,
                content = text,
            })
        else
            chat:add_message({
                role = config.constants.USER_ROLE,
                content = text,
            })
            chat:add_buf_message({
                role = config.constants.USER_ROLE,
                content = string.format("I've shared the result of the `%s` tool with you.\n", formatted_name),
            })
        end
    end
end

---@param display_name string
---@param has_function_calling boolean
---@param opts MCPHub.Extensions.CodeCompanionConfig
---@param identity? { server_name: string, tool_name: string } Set for an individual tool, whose `self.args` are the tool's own arguments
---@return {cmd_string: function, error: function, success: function}
function M.create_output_handlers(display_name, has_function_calling, opts, identity)
    return {
        --- What CodeCompanion shows after the tool's name on its label: the native
        --- tool's `label` for these arguments, if it declares one.
        ---@param self CodeCompanion.Tools.Tool The tool object
        ---@return string?
        cmd_string = function(self)
            local args = self.args or {}
            local server_name, tool_name, arguments = args.server_name, args.tool_name, args.tool_input
            if identity then
                server_name, tool_name, arguments = identity.server_name, identity.tool_name, args
            end
            if type(arguments) == "string" then
                local ok, decoded = utils.json_decode(arguments)
                arguments = ok and decoded or nil
            end
            local tool = shared.find_native_tool(server_name, tool_name)
            if not (tool and tool.label) then
                return nil
            end
            local ok, label = pcall(tool.label, arguments or {})
            return ok and label or nil
        end,

        ---@param self CodeCompanion.Tools.Tool The tool object
        ---@param stderr table|nil The error output from the command
        ---@param meta { cmd: table, tools: CodeCompanion.Tools } Metadata with tools coordinator
        error = function(self, stderr, meta)
            local chat = meta.tools.chat
            local err_data = stderr and (stderr[#stderr] or "") or ""
            if type(err_data) == "table" then
                err_data = vim.inspect(err_data)
            end
            local formatted_name = opts.format_tool and opts.format_tool(display_name, self) or display_name
            -- No trailing newline: CodeCompanion folds every line of a tool's output,
            -- and a trailing blank one would pull the separator before the next tool
            -- into the fold, hiding what hangs off it.
            local err_msg = string.format(
                [[**`%s` Tool**: Failed with the following error:

%s]],
                formatted_name,
                fence.code_block(err_data)
            )
            add_tool_output(display_name, self, chat, err_msg, true, has_function_calling, opts, nil, {})
        end,

        ---@param self CodeCompanion.Tools.Tool The tool object
        ---@param stdout table|nil The output from the command
        ---@param meta { cmd: table, tools: CodeCompanion.Tools } Metadata with tools coordinator
        success = function(self, stdout, meta)
            local chat = meta.tools.chat
            local image_cache = require("mcphub.utils.image_cache")
            ---@type MCPResponseOutput
            local result = stdout and stdout[#stdout] or {}
            local formatted_name = opts.format_tool and opts.format_tool(display_name, self) or display_name
            local to_llm = nil
            local to_user = nil
            local images = {}

            if result.text and result.text ~= "" then
                to_llm = string.format(
                    [[**`%s` Tool**: Returned the following:

%s]],
                    formatted_name,
                    fence.code_block(result.text)
                )
            end

            if result.images and #result.images > 0 then
                for _, image in ipairs(result.images) do
                    local cached_file_path = image_cache.save_image(image.data, image.mimeType)
                    local id = cached_file_path
                    table.insert(images, {
                        id = id,
                        base64 = image.data,
                        mimetype = image.mimeType,
                        cached_file_path = cached_file_path,
                    })
                end

                if not to_llm then
                    to_llm = string.format(
                        [[**`%s` Tool**: Returned the following:
%s]],
                        formatted_name,
                        fence.code_block(
                            string.format("%d image%s returned", #result.images, #result.images > 1 and "s" or "")
                        )
                    )
                end

                to_user = to_llm .. (#images > 0 and string.format("\n\n#### Preview Images\n") or "")
                for _, image in ipairs(images) do
                    local file = image.cached_file_path
                    if file then
                        local file_name = vim.fn.fnamemodify(file, ":t")
                        to_user = to_user .. string.format("\n![%s](%s)\n", file_name, vim.fn.fnameescape(file))
                    else
                        to_user = to_user .. string.format("\n![Image not saved properly](%s)\n", file)
                    end
                end
            end

            local fallback_to_llm = string.format("**`%s` Tool**: Completed with no output", formatted_name)
            if opts.show_result_in_chat == false and not to_user then
                to_user = string.format("**`%s` Tool**: Successfully finished", formatted_name)
            end
            add_tool_output(
                display_name,
                self,
                chat,
                to_llm or fallback_to_llm,
                false,
                has_function_calling,
                opts,
                to_user,
                images
            )
        end,
    }
end

return M
