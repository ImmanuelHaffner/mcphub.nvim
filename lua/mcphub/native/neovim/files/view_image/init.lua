--- The `view_image` native tool, which shows the model an image file. Kept apart
--- from `files/init.lua`, which registers it only when it is enabled, so the
--- definition can be exercised without a running hub.
local State = require("mcphub.state")
local header = require("mcphub.native.neovim.files.view_image.header")
local paths = require("mcphub.native.neovim.files.view_image.paths")
local resize = require("mcphub.native.neovim.files.view_image.resize")

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
--- How many times an image is shrunk to fit the base64 cap before giving up.
M.MAX_ATTEMPTS = 3

---@param bytes integer
---@return integer
local function base64_size(bytes)
    return 4 * math.ceil(bytes / 3)
end

--- The long edge to try next for an image whose base64 is `encoded` bytes at
--- long edge `edge`: the area scaled to the cap, with a margin for encoders
--- that do not shrink in proportion.
---@param edge integer
---@param encoded integer
---@return integer
local function next_edge(edge, encoded)
    return math.floor(edge * 0.9 * math.sqrt(M.MAX_BASE64_BYTES / encoded))
end

---@param path string
---@return string|nil b64
---@return string|nil err
local function read_base64(path)
    local file, err = io.open(path, "rb")
    if not file then
        return nil, err
    end
    local bytes = file:read("*a")
    file:close()
    return vim.base64.encode(bytes)
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

--- The line for an image that was shrunk before it was sent.
---@param given string
---@param info MCPHub.ImageHeader The original
---@param sent MCPHub.ImageHeader What was sent
---@param b64_bytes integer
---@return string
function M.resized_geometry(given, info, sent, b64_bytes)
    return ("Image `%s`: %s, %d×%d, sent as %s %d×%d (scale %.3f, %d bytes base64)."):format(
        given,
        info.mime,
        info.width,
        info.height,
        sent.mime,
        sent.width,
        sent.height,
        sent.width / info.width,
        b64_bytes
    )
end

--- Shrink the image until it fits both caps, then send it. Each attempt starts
--- from the original, so the losses of a re-encoded JPEG do not compound.
---@param target MCPHub.ViewImagePath
---@param info MCPHub.ImageHeader
---@param encoded integer The original's size as base64
---@param res ToolResponse
local function send_resized(target, info, encoded, res)
    local long_edge = math.max(info.width, info.height)
    local function attempt(edge, n)
        resize.resize(target.real, info, edge, function(out, err)
            local ok, failure = pcall(function()
                if not out then
                    return res:error(("%s: %s"):format(target.given, err))
                end
                local b64, read_err = read_base64(out.path)
                os.remove(out.path)
                if not b64 then
                    return res:error(("%s: cannot read the resized image: %s"):format(target.given, read_err))
                end
                if #b64 <= M.MAX_BASE64_BYTES then
                    local line = M.resized_geometry(target.given, info, out.header, #b64)
                    return res:text(line):image(b64, out.header.mime):send()
                end
                local smaller = next_edge(math.max(out.header.width, out.header.height), #b64)
                if n >= M.MAX_ATTEMPTS or smaller < 1 then
                    return res:error(
                        ("%s is %d×%d and %d bytes as base64; shrunk to %d×%d it is still %d bytes, over the %d byte limit"):format(
                            target.given,
                            info.width,
                            info.height,
                            encoded,
                            out.header.width,
                            out.header.height,
                            #b64,
                            M.MAX_BASE64_BYTES
                        )
                    )
                end
                attempt(smaller, n + 1)
            end)
            if not ok then
                res:error(("%s: %s"):format(target.given, failure))
            end
        end)
    end
    attempt(long_edge > M.MAX_LONG_EDGE and M.MAX_LONG_EDGE or next_edge(long_edge, encoded), 1)
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
    local stat = vim.uv.fs_stat(target.real)
    local encoded = base64_size(stat and stat.size or 0)

    if long_edge <= M.MAX_LONG_EDGE and encoded <= M.MAX_BASE64_BYTES then
        local b64, read_err = read_base64(target.real)
        if not b64 then
            return res:error(("cannot open %s: %s"):format(target.given, read_err))
        end
        return res:text(M.geometry(target.given, info, #b64)):image(b64, info.mime):send()
    end

    if not resize.backend() then
        return res:error(
            ("%s is %d×%d and %d bytes as base64, over the %d px or %d byte limit, and shrinking it needs `sips` or ImageMagick, neither of which is installed"):format(
                target.given,
                info.width,
                info.height,
                encoded,
                M.MAX_LONG_EDGE,
                M.MAX_BASE64_BYTES
            )
        )
    end
    -- Answers from the backend's callback, so a resize never blocks the editor
    send_resized(target, info, encoded, res)
end

M.definition = {
    name = "view_image",
    description = "Show yourself an image file, so you can look at it. Supports PNG, JPEG, GIF and WebP; an image over 2576 px on its long edge or 5 MB is downscaled first, and the result names the size that was sent.",
    inputSchema = M.input_schema,
    label = M.label,
    call_noun = "image",
    handler = M.handler,
}

return M
