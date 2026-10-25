--- Downscaling for `view_image`: an external backend, `sips` on macOS or else
--- ImageMagick, shrinks an image to a long edge, keeping its format except that
--- WebP becomes PNG. Every result is read back and checked before it is used.
local header = require("mcphub.native.neovim.files.view_image.header")

local M = {}

--- JPEG quality for a re-encoded JPEG, high enough not to blur text in screenshots.
M.JPEG_QUALITY = 90

local EXTENSIONS = { ["image/png"] = "png", ["image/jpeg"] = "jpg", ["image/gif"] = "gif" }

---@type string|false|nil false: looked, found none
local cached_backend

--- The resize backend on this machine, resolved once.
---@return "sips"|"magick"|"convert"|nil
function M.backend()
    if cached_backend == nil then
        cached_backend = false
        if vim.fn.has("mac") == 1 and vim.fn.executable("sips") == 1 then
            cached_backend = "sips"
        elseif vim.fn.executable("magick") == 1 then
            cached_backend = "magick"
        elseif vim.fn.executable("convert") == 1 then
            cached_backend = "convert"
        end
    end
    return cached_backend or nil
end

--- The type an image is written as: its own, except WebP, which `sips` cannot
--- write and which therefore becomes PNG on every backend.
---@param mime string
---@return string
function M.output_mime(mime)
    return mime == "image/webp" and "image/png" or mime
end

--- The command that writes `src`, shrunk to `long_edge`, to `dst`.
---@param backend "sips"|"magick"|"convert"
---@param src string
---@param dst string
---@param long_edge integer
---@param info MCPHub.ImageHeader The header of `src`
---@return string[] argv
---@return string mime The type `dst` is written as
function M.argv(backend, src, dst, long_edge, info)
    -- `sips -Z` enlarges as readily as it shrinks
    assert(long_edge < math.max(info.width, info.height), "refusing to enlarge an image")
    local mime = M.output_mime(info.mime)
    if backend == "sips" then
        local argv = { "sips", "-Z", tostring(long_edge) }
        if info.mime == "image/webp" then
            vim.list_extend(argv, { "-s", "format", "png" })
        elseif mime == "image/jpeg" then
            vim.list_extend(argv, { "-s", "formatOptions", tostring(M.JPEG_QUALITY) })
        end
        return vim.list_extend(argv, { src, "--out", dst }), mime
    end
    -- `[0]` keeps only the first frame of a GIF; `>` only ever shrinks
    local argv = { backend, src .. "[0]", "-resize", ("%dx%d>"):format(long_edge, long_edge) }
    if mime == "image/jpeg" then
        vim.list_extend(argv, { "-quality", tostring(M.JPEG_QUALITY) })
    end
    table.insert(argv, info.mime == "image/webp" and "png:" .. dst or dst)
    return argv, mime
end

---@class MCPHub.ViewImageResized
---@field path string A temp file the caller must delete
---@field header MCPHub.ImageHeader Read back from `path`

--- Shrink `src` to `long_edge` without blocking the editor. `cb` runs on the
--- main loop with the result or an error; on error no temp file is left behind.
---@param src string
---@param info MCPHub.ImageHeader The header of `src`
---@param long_edge integer
---@param cb fun(result: MCPHub.ViewImageResized|nil, err: string|nil)
function M.resize(src, info, long_edge, cb)
    local backend = M.backend()
    if not backend then
        return vim.schedule(function()
            cb(nil, "no resize backend: install `sips` or ImageMagick")
        end)
    end
    local dst = vim.fn.tempname() .. "." .. EXTENSIONS[M.output_mime(info.mime)]
    local built, argv, mime = pcall(M.argv, backend, src, dst, long_edge, info)
    if not built then
        return vim.schedule(function()
            cb(nil, tostring(argv))
        end)
    end

    local function fail(message)
        os.remove(dst)
        cb(nil, message)
    end
    local started, err = pcall(vim.system, argv, { text = true }, function(done)
        vim.schedule(function()
            if done.code ~= 0 then
                return fail(("%s exited with %d: %s"):format(argv[1], done.code, vim.trim(done.stderr or "")))
            end
            local out, read_err = header.read(dst)
            if not out then
                return fail(("%s wrote no readable image: %s"):format(argv[1], read_err))
            end
            if out.mime ~= mime or math.max(out.width, out.height) > long_edge then
                return fail(
                    ("%s wrote %s %d×%d, not %s within %d px"):format(
                        argv[1],
                        out.mime,
                        out.width,
                        out.height,
                        mime,
                        long_edge
                    )
                )
            end
            cb({ path = dst, header = out })
        end)
    end)
    if not started then
        vim.schedule(function()
            fail(("cannot run %s: %s"):format(argv[1], err))
        end)
    end
end

return M
