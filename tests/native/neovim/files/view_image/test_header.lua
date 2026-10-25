-- Tests for mcphub.native.neovim.files.view_image.header, which reads an
-- image's MIME type and dimensions from its header.
--
-- Run with `make test`, or just this file with
-- `make test_file FILE=tests/native/neovim/files/view_image/test_header.lua`.
local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local header = require("mcphub.native.neovim.files.view_image.header")

---@param n integer
---@return string
local function u16be(n)
    return string.char(math.floor(n / 256), n % 256)
end

---@param n integer
---@return string
local function u32be(n)
    return u16be(math.floor(n / 65536)) .. u16be(n % 65536)
end

--- A PNG header for `width`×`height`; the rest of the file is irrelevant to the parser.
local function png(width, height)
    return "\137PNG\r\n\26\n" .. u32be(13) .. "IHDR" .. u32be(width) .. u32be(height) .. "\8\6\0\0\0"
end

--- A baseline SOF0 segment for `width`×`height`.
local function sof0(width, height)
    return "\255\192" .. u16be(17) .. "\8" .. u16be(height) .. u16be(width) .. "\3" .. string.rep("\0", 9)
end

--- A segment with marker `marker` carrying `payload`.
local function segment(marker, payload)
    return "\255" .. string.char(marker) .. u16be(#payload + 2) .. payload
end

local SOI = "\255\216"

---@param bytes string
---@param fragment string Expected somewhere in the error message
local function expect_error(bytes, fragment)
    local result, err = header.parse_string(bytes)
    eq(result, nil)
    local message = assert(err, "expected an error message")
    if not message:find(fragment, 1, true) then
        error(("expected an error containing %q, got %q"):format(fragment, message), 2)
    end
end

local T = new_set()

T["real files"] = new_set({
    hooks = {
        pre_case = function()
            if vim.fn.executable("magick") ~= 1 then
                MiniTest.skip("ImageMagick (`magick`) is needed to generate the samples")
            end
        end,
    },
})

--- Generate a sample with ImageMagick into a temp directory and return its path.
---@param name string
---@param args string[] Arguments between `magick` and the output path
---@return string path
local function sample(name, args)
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    MiniTest.finally(function()
        vim.fn.delete(dir, "rf")
    end)
    local path = vim.fs.joinpath(dir, name)
    local cmd = vim.list_extend({ "magick" }, args)
    table.insert(cmd, path)
    local result = vim.system(cmd):wait(30000)
    assert(result.code == 0, ("magick failed: %s"):format(result.stderr))
    return path
end

---@param path string
---@return string
local function webp_chunk(path)
    local f = assert(io.open(path, "rb"))
    local bytes = f:read(16)
    f:close()
    return bytes:sub(13, 16)
end

local CASES = {
    { "a.png", { "-size", "301x203", "xc:red" }, "image/png" },
    { "b.jpg", { "-size", "301x203", "xc:red", "-quality", "90" }, "image/jpeg" },
    { "c.jpg", { "-size", "301x203", "xc:red", "-interlace", "JPEG" }, "image/jpeg" },
    { "d.gif", { "-size", "301x203", "xc:red", "xc:blue", "-loop", "0" }, "image/gif" },
    { "e.webp", { "-size", "301x203", "xc:red", "-quality", "80" }, "image/webp", "VP8 " },
    { "f.webp", { "-size", "301x203", "xc:red", "-define", "webp:lossless=true" }, "image/webp", "VP8L" },
    { "g.webp", { "-size", "301x203", "xc:rgba(255,0,0,0.5)", "-quality", "80" }, "image/webp", "VP8X" },
}

for _, case in ipairs(CASES) do
    local name, args, mime, chunk = case[1], case[2], case[3], case[4]
    T["real files"][name .. " (" .. (chunk or mime) .. ")"] = function()
        local path = sample(name, args)
        if chunk then
            -- Guards against a vacuous pass: each WebP sample exercises its own chunk
            eq(webp_chunk(path), chunk)
        end
        eq(header.read(path), { mime = mime, width = 301, height = 203 })
    end
end

T["real files"]["agrees with sips"] = function()
    if vim.fn.executable("sips") ~= 1 then
        MiniTest.skip("sips is macOS only")
    end
    local path = sample("wide.png", { "-size", "2560x1080", "xc:red" })
    local out = vim.system({ "sips", "-g", "pixelWidth", "-g", "pixelHeight", path }):wait().stdout or ""
    local info = assert(header.read(path))
    eq(
        { info.width, info.height },
        { tonumber(out:match("pixelWidth: (%d+)")), tonumber(out:match("pixelHeight: (%d+)")) }
    )
end

T["read"] = new_set()

T["read"]["reports a missing file"] = function()
    local result, err = header.read(vim.fn.tempname())
    eq(result, nil)
    eq(assert(err):find("cannot open", 1, true) ~= nil, true)
end

T["read"]["reads a file that is not an image"] = function()
    local path = vim.fn.tempname()
    vim.fn.writefile({ "hello" }, path)
    MiniTest.finally(function()
        vim.fn.delete(path)
    end)
    local result, err = header.read(path)
    eq(result, nil)
    eq(err, "not a PNG, JPEG, GIF or WebP image")
end

T["crafted"] = new_set()

T["crafted"]["PNG"] = function()
    eq(header.parse_string(png(2560, 1080)), { mime = "image/png", width = 2560, height = 1080 })
end

T["crafted"]["GIF"] = function()
    eq(header.parse_string("GIF89a\1\2\3\4\0\0"), { mime = "image/gif", width = 513, height = 1027 })
end

T["crafted"]["baseline JPEG"] = function()
    eq(header.parse_string(SOI .. sof0(640, 480)), { mime = "image/jpeg", width = 640, height = 480 })
end

T["crafted"]["JPEG with fill bytes before a marker"] = function()
    local bytes = SOI .. "\255\255\255" .. segment(0xE0, "JFIF\0") .. "\255\255" .. sof0(640, 480)
    eq(header.parse_string(bytes), { mime = "image/jpeg", width = 640, height = 480 })
end

T["crafted"]["JPEG with standalone markers"] = function()
    local bytes = SOI .. "\255\208" .. "\255\1" .. "\255\215" .. sof0(640, 480)
    eq(header.parse_string(bytes), { mime = "image/jpeg", width = 640, height = 480 })
end

T["crafted"]["JPEG with a 64 KB APP1 segment"] = function()
    local bytes = SOI .. segment(0xE1, string.rep("x", 65533)) .. sof0(640, 480)
    eq(header.parse_string(bytes), { mime = "image/jpeg", width = 640, height = 480 })
end

T["crafted"]["JPEG takes SOF2, but not DHT, as a frame"] = function()
    local sof2 = "\255\194" .. sof0(320, 200):sub(3)
    local bytes = SOI .. segment(0xC4, "\0\1\2\3") .. sof2
    eq(header.parse_string(bytes), { mime = "image/jpeg", width = 320, height = 200 })
end

T["crafted"]["JPEG whose scan starts before any frame"] = function()
    expect_error(SOI .. segment(0xDA, "\0"), "no SOF marker before the image data")
end

T["crafted"]["JPEG with a segment length below 2"] = function()
    expect_error(SOI .. "\255\224\0\1", "segment length below 2")
end

T["crafted"]["JPEG walks a bounded number of segments"] = function()
    expect_error(SOI .. string.rep(segment(0xE0, ""), 5000), "too many segments")
end

T["truncated"] = new_set()

T["truncated"]["PNG cut before its height"] = function()
    expect_error(png(10, 10):sub(1, 23), "truncated PNG")
end

T["truncated"]["GIF cut before its height"] = function()
    expect_error(("GIF89a\1\2\3\4"):sub(1, 9), "truncated GIF")
end

T["truncated"]["lossy WebP cut before its height"] = function()
    local bytes = "RIFF\0\0\0\0WEBPVP8 \0\0\0\0\0\0\0\157\1\42\45\1\203\0"
    eq(header.parse_string(bytes), { mime = "image/webp", width = 301, height = 203 })
    expect_error(bytes:sub(1, 29), "truncated WebP")
end

T["truncated"]["JPEG cut inside its SOF"] = function()
    expect_error((SOI .. sof0(640, 480)):sub(1, 10), "truncated JPEG")
end

T["truncated"]["JPEG cut before any SOF"] = function()
    expect_error(SOI .. segment(0xE0, "JFIF\0"), "truncated JPEG: no SOF marker")
end

T["truncated"]["a lone signature"] = function()
    expect_error("\137PNG\r\n\26\n", "truncated PNG")
    expect_error(SOI, "truncated JPEG")
end

T["rejected"] = new_set()

T["rejected"]["text"] = function()
    expect_error("hello world\n", "not a PNG, JPEG, GIF or WebP image")
end

T["rejected"]["SVG"] = function()
    expect_error('<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"/>', "not a PNG")
end

T["rejected"]["an empty file"] = function()
    expect_error("", "not a PNG")
end

T["rejected"]["a zero dimension"] = function()
    expect_error(png(0, 10), "zero dimension")
end

T["rejected"]["an unknown WebP chunk"] = function()
    expect_error("RIFF\0\0\0\0WEBPALPH" .. string.rep("\0", 16), "unsupported WebP chunk")
end

return T
