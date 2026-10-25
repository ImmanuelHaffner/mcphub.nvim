-- Tests for mcphub.native.neovim.files.view_image.resize and the downscaling
-- pipeline in the `view_image` handler.
--
-- Run with `make test`, or just this file with
-- `make test_file FILE=tests/native/neovim/files/view_image/test_resize.lua`.
-- `MCPHUB_VIEW_IMAGE_BACKEND=magick` forces the backend, so the real resizes can
-- be checked against ImageMagick on a machine that has `sips`.
local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local NativeServer = require("mcphub.native.utils.server")
local header = require("mcphub.native.neovim.files.view_image.header")
local resize = require("mcphub.native.neovim.files.view_image.resize")
local view_image = require("mcphub.native.neovim.files.view_image")

local FORCED_BACKEND = os.getenv("MCPHUB_VIEW_IMAGE_BACKEND")
local MEMORY_MODULE = "codecompanion.memory"

local real = {}

--- Every name `vim.fn.tempname` handed out during the case.
---@type string[]
local temp_names

---@param haystack string
---@param fragments string[]
local function expect_contains(haystack, fragments)
    for _, fragment in ipairs(fragments) do
        if not haystack:find(fragment, 1, true) then
            error(("expected %q to contain %q"):format(haystack, fragment), 2)
        end
    end
end

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

--- Generate an image with ImageMagick.
---@param path string
---@param args string[] Arguments between `magick` and the output path
---@return string path
local function sample(path, args)
    local cmd = vim.list_extend({ "magick" }, args)
    table.insert(cmd, path)
    local result = vim.system(cmd):wait(60000)
    assert(result.code == 0, ("magick failed: %s"):format(result.stderr))
    return path
end

--- Call `view_image` on `path` from a chat whose working directory is `cwd`.
---@param path string
---@param cwd string
---@return { content: MCPContent[], isError?: boolean } result
local function call(path, cwd)
    ---@diagnostic disable-next-line: missing-fields
    local server = setmetatable(
        { name = "fake", status = "connected", capabilities = { tools = { view_image.definition } } },
        NativeServer
    )
    local response, err, done
    server:call_tool("view_image", { path = path }, {
        caller = { type = "codecompanion", codecompanion = { chat = { cwd = cwd } } },
        callback = function(r, e)
            response, err, done = r, e, true
        end,
    })
    assert(
        vim.wait(60000, function()
            return done
        end, 10),
        "view_image did not answer"
    )
    return assert(response and response.result, err)
end

--- The header of the image a successful result carries.
---@param result table
---@return MCPHub.ImageHeader
local function sent_header(result)
    eq(result.isError, nil)
    eq(result.content[2].type, "image")
    return assert(header.parse_string(vim.base64.decode(result.content[2].data)))
end

--- The number of frames in a GIF, by walking its blocks.
---@param bytes string
---@return integer
local function gif_frames(bytes)
    local pos = 14
    local flags = bytes:byte(11)
    if flags >= 128 then
        pos = pos + 3 * 2 ^ (flags % 8 + 1)
    end
    local function skip_sub_blocks()
        while true do
            local n = bytes:byte(pos)
            pos = pos + 1
            if not n or n == 0 then
                return
            end
            pos = pos + n
        end
    end
    local frames = 0
    while pos <= #bytes do
        local byte = bytes:byte(pos)
        if byte == 0x2C then
            frames = frames + 1
            local local_flags = bytes:byte(pos + 9)
            pos = pos + 10
            if local_flags >= 128 then
                pos = pos + 3 * 2 ^ (local_flags % 8 + 1)
            end
            pos = pos + 1
            skip_sub_blocks()
        elseif byte == 0x21 then
            pos = pos + 2
            skip_sub_blocks()
        else
            break
        end
    end
    return frames
end

--- Run `resize.resize` and wait for its callback.
---@return MCPHub.ViewImageResized|nil result
---@return string|nil err
local function run_resize(src, info, long_edge)
    local result, err, done
    resize.resize(src, info, long_edge, function(r, e)
        result, err, done = r, e, true
    end)
    assert(vim.wait(10000, function()
        return done
    end, 10))
    return result, err
end

--- Replace the backend's command for the rest of the case.
---@param build fun(dst: string): string[]
local function stub_command(build)
    ---@diagnostic disable-next-line: duplicate-set-field
    resize.backend = function()
        return "sips"
    end
    ---@diagnostic disable-next-line: duplicate-set-field
    resize.argv = function(_, _, dst, _, info)
        return build(dst), resize.output_mime(info.mime)
    end
end

local T = new_set({
    hooks = {
        pre_case = function()
            real.tempname, real.backend, real.argv = vim.fn.tempname, resize.backend, resize.argv
            real.max_base64 = view_image.MAX_BASE64_BYTES
            temp_names = {}
            vim.fn.tempname = function()
                local name = real.tempname()
                table.insert(temp_names, name)
                return name
            end
            if FORCED_BACKEND then
                ---@diagnostic disable-next-line: duplicate-set-field
                resize.backend = function()
                    return FORCED_BACKEND
                end
            end
            -- CodeCompanion isn't on the test runtimepath; this stands in for its memory module
            package.loaded[MEMORY_MODULE] = {
                chat_cwd = function(chat)
                    return chat.cwd
                end,
            }
        end,
        post_case = function()
            vim.fn.tempname, resize.backend, resize.argv = real.tempname, real.backend, real.argv
            view_image.MAX_BASE64_BYTES = real.max_base64
            package.loaded[MEMORY_MODULE] = nil
            for _, name in ipairs(temp_names) do
                eq(vim.fn.glob(name .. "*", true, true), {})
            end
        end,
    },
})

T["argv"] = new_set()

local WIDE = { width = 5120, height = 2160 }

---@param mime string
---@return MCPHub.ImageHeader
local function wide(mime)
    return { mime = mime, width = WIDE.width, height = WIDE.height }
end

T["argv"]["for sips keeps PNG and GIF as they are"] = function()
    eq(
        { resize.argv("sips", "/s.png", "/d.png", 2576, wide("image/png")) },
        { { "sips", "-Z", "2576", "/s.png", "--out", "/d.png" }, "image/png" }
    )
    eq(
        { resize.argv("sips", "/s.gif", "/d.gif", 2576, wide("image/gif")) },
        { { "sips", "-Z", "2576", "/s.gif", "--out", "/d.gif" }, "image/gif" }
    )
end

T["argv"]["for sips writes JPEG at quality 90"] = function()
    eq(
        { resize.argv("sips", "/s.jpg", "/d.jpg", 2576, wide("image/jpeg")) },
        { { "sips", "-Z", "2576", "-s", "formatOptions", "90", "/s.jpg", "--out", "/d.jpg" }, "image/jpeg" }
    )
end

T["argv"]["for sips turns WebP into PNG"] = function()
    eq(
        { resize.argv("sips", "/s.webp", "/d.png", 2576, wide("image/webp")) },
        { { "sips", "-Z", "2576", "-s", "format", "png", "/s.webp", "--out", "/d.png" }, "image/png" }
    )
end

T["argv"]["for ImageMagick takes the first frame and only shrinks"] = function()
    eq(
        { resize.argv("magick", "/s.png", "/d.png", 2576, wide("image/png")) },
        { { "magick", "/s.png[0]", "-resize", "2576x2576>", "/d.png" }, "image/png" }
    )
    eq(
        { resize.argv("magick", "/s.jpg", "/d.jpg", 2576, wide("image/jpeg")) },
        { { "magick", "/s.jpg[0]", "-resize", "2576x2576>", "-quality", "90", "/d.jpg" }, "image/jpeg" }
    )
    eq(
        { resize.argv("magick", "/s.webp", "/d.png", 2576, wide("image/webp")) },
        { { "magick", "/s.webp[0]", "-resize", "2576x2576>", "png:/d.png" }, "image/png" }
    )
    eq(resize.argv("convert", "/s.gif", "/d.gif", 2576, wide("image/gif"))[1], "convert")
end

T["argv"]["refuses to enlarge"] = function()
    eq(pcall(resize.argv, "sips", "/s.png", "/d.png", 5120, wide("image/png")), false)
    eq(pcall(resize.argv, "magick", "/s.png", "/d.png", 6000, wide("image/png")), false)
end

T["resize"] = new_set()

local SMALL = { mime = "image/png", width = 200, height = 100 }

T["resize"]["surfaces a failing backend's stderr"] = function()
    stub_command(function()
        return { "sh", "-c", "echo boom >&2; exit 13" }
    end)

    local result, err = run_resize("/no/such.png", SMALL, 100)

    eq(result, nil)
    expect_contains(assert(err), { "exited with 13", "boom" })
end

T["resize"]["refuses a backend that exits 0 but writes nothing"] = function()
    stub_command(function()
        return { "true" }
    end)

    local result, err = run_resize("/no/such.png", SMALL, 100)

    eq(result, nil)
    expect_contains(assert(err), { "wrote no readable image" })
end

T["resize"]["refuses an output larger than asked for"] = function()
    local dir = tempdir()
    local src = vim.fs.joinpath(dir, "s.png")
    local head = "\137PNG\r\n\26\n\0\0\0\13IHDR\0\0\0\200\0\0\0\100\8\6\0\0\0"
    local file = assert(io.open(src, "wb"))
    file:write(head)
    file:close()
    stub_command(function(dst)
        return { "cp", src, dst }
    end)

    local result, err = run_resize(src, SMALL, 100)

    eq(result, nil)
    expect_contains(assert(err), { "200×100", "within 100 px" })
end

T["resize"]["reports a missing backend"] = function()
    ---@diagnostic disable-next-line: duplicate-set-field
    resize.backend = function()
        return nil
    end

    local result, err = run_resize("/no/such.png", SMALL, 100)

    eq(result, nil)
    expect_contains(assert(err), { "`sips` or ImageMagick" })
end

T["resize"]["does not block the editor"] = function()
    stub_command(function()
        return { "sh", "-c", "sleep 0.3; exit 1" }
    end)
    local done = false
    resize.resize("/no/such.png", SMALL, 100, function()
        done = true
    end)
    local ticked = false
    vim.schedule(function()
        ticked = true
    end)

    eq(
        vim.wait(200, function()
            return ticked
        end, 5),
        true
    )
    eq(done, false)
    assert(vim.wait(5000, function()
        return done
    end, 10))
end

T["pipeline"] = new_set({
    hooks = {
        pre_case = function()
            if not resize.backend() then
                MiniTest.skip("no resize backend (`sips` or ImageMagick)")
            end
            if vim.fn.executable("magick") ~= 1 then
                MiniTest.skip("ImageMagick (`magick`) is needed to generate the samples")
            end
        end,
    },
})

T["pipeline"]["caps the long edge"] = function()
    local dir = tempdir()
    sample(vim.fs.joinpath(dir, "wide.png"), { "-size", "5120x2160", "gradient:red-blue" })

    local result = call("wide.png", dir)

    local sent = sent_header(result)
    eq({ sent.mime, sent.width }, { "image/png", 2576 })
    eq(math.abs(sent.height - 1087) <= 1, true)
    expect_contains(result.content[1].text, { "image/png, 5120×2160, sent as image/png 2576×", "scale 0.503" })
end

T["pipeline"]["turns WebP into PNG"] = function()
    local dir = tempdir()
    sample(vim.fs.joinpath(dir, "wide.webp"), { "-size", "3000x1000", "gradient:red-blue", "-quality", "80" })

    local result = call("wide.webp", dir)

    eq(sent_header(result).mime, "image/png")
    eq(result.content[2].mimeType, "image/png")
    expect_contains(result.content[1].text, { "image/webp, 3000×1000, sent as image/png 2576×" })
end

T["pipeline"]["keeps the first frame of a GIF"] = function()
    local dir = tempdir()
    local src = sample(vim.fs.joinpath(dir, "anim.gif"), { "-size", "3000x1000", "xc:red", "xc:blue", "-loop", "0" })
    local file = assert(io.open(src, "rb"))
    -- Guards the frame counter against a vacuous pass
    eq(gif_frames(file:read("*a")), 2)
    file:close()

    local result = call("anim.gif", dir)

    eq(sent_header(result).mime, "image/gif")
    eq(gif_frames(vim.base64.decode(result.content[2].data)), 1)
end

T["pipeline"]["shrinks an image until its base64 fits"] = function()
    local dir = tempdir()
    local src = sample(vim.fs.joinpath(dir, "noise.png"), { "-size", "2576x2576", "xc:", "+noise", "Random" })
    eq(4 * math.ceil(vim.uv.fs_stat(src).size / 3) > view_image.MAX_BASE64_BYTES, true)
    local attempts = 0
    local real_resize = resize.resize
    ---@diagnostic disable-next-line: duplicate-set-field
    resize.resize = function(...)
        attempts = attempts + 1
        return real_resize(...)
    end
    MiniTest.finally(function()
        resize.resize = real_resize
    end)

    local result = call("noise.png", dir)

    sent_header(result)
    eq(#result.content[2].data <= view_image.MAX_BASE64_BYTES, true)
    eq(attempts <= view_image.MAX_ATTEMPTS, true)
    expect_contains(result.content[1].text, { "image/png, 2576×2576, sent as image/png" })
end

T["pipeline"]["gives up naming the original and the last attempt"] = function()
    local dir = tempdir()
    sample(vim.fs.joinpath(dir, "red.png"), { "-size", "64x64", "xc:red" })
    view_image.MAX_BASE64_BYTES = 10

    local result = call("red.png", dir)

    eq(result.isError, true)
    expect_contains(result.content[1].text, { "red.png is 64×64", "shrunk to", "over the 10 byte limit" })
end

return T
