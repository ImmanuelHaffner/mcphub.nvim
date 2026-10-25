--- The `view_image` native tool, which shows the model an image file. Kept apart
--- from `files/init.lua`, which registers it only when it is enabled, so the
--- definition can be exercised without a running hub.
local State = require("mcphub.state")

local M = {}

--- User-facing configuration for `view_image`, declared in `mcphub/config.lua`
--- under `builtin_tools.view_image`.
---
---@class MCPHub.ViewImageConfig
---@field enabled boolean? Register the tool in the `neovim` server; read once, when the hub starts

--- Whether the tool is registered. Asked when the `neovim` server registers its
--- tools, which happens after mcphub's `setup()` has filled `State.config`.
---@return boolean
function M.enabled()
    local cfg = (State.config.builtin_tools or {}).view_image or {}
    return cfg.enabled == true
end

M.input_schema = {
    type = "object",
    properties = {
        path = {
            type = "string",
            description = "Path of the image file: absolute, or relative to the working directory",
        },
    },
    required = { "path" },
}

--- What CodeCompanion shows after the tool's name on its label.
---@param args table
---@return string?
function M.label(args)
    local path = type(args) == "table" and args.path or nil
    return type(path) == "string" and path ~= "" and path or nil
end

---@param _ ToolRequest
---@param res ToolResponse
function M.handler(_, res)
    return res:error("view_image is not implemented yet")
end

M.definition = {
    name = "view_image",
    description = "Show yourself an image file, so you can look at it. Supports PNG, JPEG, GIF and WebP.",
    inputSchema = M.input_schema,
    label = M.label,
    call_noun = "image",
    handler = M.handler,
}

return M
