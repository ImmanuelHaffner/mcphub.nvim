local M = {}

---@alias MCPHub.Extensions.Type "avante" | "codecompanion" | "copilotchat"
---@alias MCPHub.ActionType "use_mcp_tool" | "access_mcp_resource"

---@class MCPHub.Extensions.AvanteConfig
---@field enabled boolean Whether the extension is enabled or not
---@field make_slash_commands boolean Whether to make slash commands or not

---@class MCPHub.Extensions.CodeCompanionConfig
---@field enabled boolean Whether the extension is enabled or not
---@field make_vars boolean Whether to make variables or not
---@field add_mcp_prefix_to_tool_names boolean Whether to add MCP prefix to tool names , resources and slash commands
---@field make_slash_commands boolean Whether to make slash commands or not
---@field make_tools boolean Whether to make individual tools and server groups or not
---@field show_server_tools_in_chat boolean Whether to show all tools in cmp or not
---@field show_result_in_chat boolean Whether to show the result in chat or not
---@field format_tool function(tool_name: string, tool: CodeCompanion.Agent.Tool): string
---@field size_guard MCPHub.Extensions.CodeCompanion.SizeGuardConfig Oversized-result spilling

---@class MCPHub.Extensions.CodeCompanion.SizeGuardConfig
---Keeps oversized MCP results out of the chat context by writing the payload to a
---file and replacing the inline text with a summary plus inspection hints.
---Every budget takes `nil` (use the default), `false` (disable that budget) or a
---number. A result is spilled when it exceeds ANY enabled budget.
---@field enabled? boolean Master switch. Default true.
---@field max_bytes? integer|false Byte budget. Default `mcphub.utils.spill.DEFAULT_MAX_BYTES` (96 KB).
---@field max_lines? integer|false Line budget. Default `mcphub.utils.spill.DEFAULT_MAX_LINES` (2000).
---@field max_tokens? integer|false Token budget. Default 20000; needs a counter, see `token_counter`.
---@field token_counter? fun(s: string): integer Token estimator. Defaults to `codecompanion.utils.tokens`.
---@field skip? string[] Capabilities never spilled, as `"<server>__<tool>"` or bare `"<tool>"`. ADDITIVE on top of the defaults.
---@field skip_defaults? boolean Keep the built-in skip list. Default true; `false` replaces it with `skip` alone.
---@field gc? boolean|{ max_age_hours?: integer, period_minutes?: integer } Spill-file cleanup. `true`/nil = 24h retention swept hourly; `false` = off.
---@field dir? string Spill directory. Default `stdpath("cache")/mcphub-spill`.

---@class MCPHub.Extensions.CopilotChatConfig
---@field enabled boolean Whether the extension is enabled or not
---@field convert_tools_to_functions boolean Whether to convert MCP tools to CopilotChat functions
---@field convert_resources_to_functions boolean Whether to convert MCP resources to CopilotChat functions
---@field add_mcp_prefix boolean Whether to add "mcp_" prefix to function names

---@class MCPHub.Extensions.Config
---@field avante MCPHub.Extensions.AvanteConfig Configuration for the Avante extension
---@field copilotchat MCPHub.Extensions.CopilotChatConfig Configuration for the CopilotChat extension
---NOTE: Codecompanion setup is handled via mcphub extensions for codecompanion

---@param config MCPHub.Extensions.Config
function M.setup(config)
    local avante_config = config.avante or {}
    if avante_config.enabled then
        require("mcphub.extensions.avante").setup(avante_config)
    end

    local copilotchat_config = config.copilotchat or {}
    if copilotchat_config.enabled then
        require("mcphub.extensions.copilotchat").setup(copilotchat_config)
    end
end

return M
