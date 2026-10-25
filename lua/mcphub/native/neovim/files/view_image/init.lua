--- The `view_image` native tool, which shows the model an image file. Kept apart
--- from `files/init.lua`, which registers it only when it is enabled, so the
--- definition can be exercised without a running hub.
local State = require("mcphub.state")
local header = require("mcphub.native.neovim.files.view_image.header")
local paths = require("mcphub.native.neovim.files.view_image.paths")

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
            description = "Path of the image file: absolute, or relative to the chat's working directory",
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

--- Caps on what is sent: Anthropic's high-resolution long edge, and its 5 MB
--- limit on an image's base64.
M.MAX_LONG_EDGE = 2576
M.MAX_BASE64_BYTES = 5000000

---@param bytes integer
---@return integer
local function base64_size(bytes)
    return 4 * math.ceil(bytes / 3)
end

--- The line that tells the model what it is looking at.
---@param given string
---@param info MCPHub.ImageHeader
---@param b64_bytes integer
---@return string
function M.geometry(given, info, b64_bytes)
    return ("Image `%s`: %s, %d×%d, sent unchanged (%d bytes base64)."):format(
        given,
        info.mime,
        info.width,
        info.height,
        b64_bytes
    )
end

---@param req ToolRequest
---@param res ToolResponse
function M.handler(req, res)
    local target, err = paths.resolve(req.params.path, req.caller)
    if not target then
        ---@cast err string
        return res:error(err)
    end
    if not target.inside then
        return res:error(("%s is outside the chat's working directory %s"):format(target.given, target.cwd))
    end

    local info, header_err = header.read(target.real)
    if not info then
        return res:error(("%s: %s"):format(target.given, header_err))
    end
    local long_edge = math.max(info.width, info.height)
    if long_edge > M.MAX_LONG_EDGE then
        return res:error(
            ("%s is %d×%d: its long edge of %d px exceeds the %d px limit"):format(
                target.given,
                info.width,
                info.height,
                long_edge,
                M.MAX_LONG_EDGE
            )
        )
    end
    local stat = vim.uv.fs_stat(target.real)
    local encoded_size = base64_size(stat and stat.size or 0)
    if encoded_size > M.MAX_BASE64_BYTES then
        return res:error(
            ("%s is %d bytes as base64, over the %d byte limit"):format(target.given, encoded_size, M.MAX_BASE64_BYTES)
        )
    end

    local file, open_err = io.open(target.real, "rb")
    if not file then
        return res:error(("cannot open %s: %s"):format(target.given, open_err))
    end
    local bytes = file:read("*a")
    file:close()
    local b64 = vim.base64.encode(bytes)
    return res:text(M.geometry(target.given, info, #b64)):image(b64, info.mime):send()
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
