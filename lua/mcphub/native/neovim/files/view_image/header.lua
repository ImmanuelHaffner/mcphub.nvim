--- The MIME type and dimensions of an image, read from its header.
---
--- The type comes from the file's signature, never its name: the Messages API
--- rejects an image whose declared `media_type` disagrees with its bytes. Every
--- read is length-checked, so a truncated file is an error, not a bad read.
local M = {}

---@class MCPHub.ImageHeader
---@field mime "image/png"|"image/jpeg"|"image/gif"|"image/webp"
---@field width integer
---@field height integer

--- Reads up to `length` bytes at the 0-based `offset`; fewer at the end of the source.
---@alias MCPHub.ImageHeader.Reader fun(offset: integer, length: integer): string

local PNG_SIGNATURE = "\137PNG\r\n\26\n"
local NOT_AN_IMAGE = "not a PNG, JPEG, GIF or WebP image"

--- Upper bound on JPEG segments walked before the first SOF, against a crafted
--- file that would otherwise keep the walk going.
local MAX_JPEG_SEGMENTS = 4096

---@param s string
---@param i integer 1-based
---@return integer
local function u16be(s, i)
    return s:byte(i) * 256 + s:byte(i + 1)
end

---@param s string
---@param i integer 1-based
---@return integer
local function u16le(s, i)
    return s:byte(i) + s:byte(i + 1) * 256
end

---@param s string
---@param i integer 1-based
---@return integer
local function u24le(s, i)
    return s:byte(i) + s:byte(i + 1) * 256 + s:byte(i + 2) * 65536
end

---@param s string
---@param i integer 1-based
---@return integer
local function u32be(s, i)
    return ((s:byte(i) * 256 + s:byte(i + 1)) * 256 + s:byte(i + 2)) * 256 + s:byte(i + 3)
end

---@param mime string
---@param width integer
---@param height integer
---@return MCPHub.ImageHeader|nil
---@return string|nil err
local function header(mime, width, height)
    if width == 0 or height == 0 then
        return nil, ("%s with a zero dimension (%d×%d)"):format(mime, width, height)
    end
    return { mime = mime, width = width, height = height }
end

---@param head string
local function parse_png(head)
    if #head < 24 then
        return nil, "truncated PNG"
    end
    if head:sub(13, 16) ~= "IHDR" then
        return nil, "malformed PNG: no IHDR chunk"
    end
    return header("image/png", u32be(head, 17), u32be(head, 21))
end

---@param head string
local function parse_gif(head)
    if #head < 10 then
        return nil, "truncated GIF"
    end
    return header("image/gif", u16le(head, 7), u16le(head, 9))
end

---@param head string
local function parse_webp(head)
    local chunk = head:sub(13, 16)
    if chunk == "VP8 " then
        if #head < 30 then
            return nil, "truncated WebP"
        end
        if head:sub(24, 26) ~= "\157\1\42" then
            return nil, "malformed WebP: no VP8 start code"
        end
        return header("image/webp", u16le(head, 27) % 16384, u16le(head, 29) % 16384)
    elseif chunk == "VP8L" then
        if #head < 25 then
            return nil, "truncated WebP"
        end
        if head:byte(21) ~= 0x2f then
            return nil, "malformed WebP: no VP8L signature"
        end
        local b1, b2, b3, b4 = head:byte(22, 25)
        local width = 1 + b1 + (b2 % 64) * 256
        local height = 1 + math.floor(b2 / 64) + b3 * 4 + (b4 % 16) * 1024
        return header("image/webp", width, height)
    elseif chunk == "VP8X" then
        if #head < 30 then
            return nil, "truncated WebP"
        end
        return header("image/webp", 1 + u24le(head, 25), 1 + u24le(head, 28))
    end
    if #head < 16 then
        return nil, "truncated WebP"
    end
    return nil, ("unsupported WebP chunk %q"):format(chunk)
end

--- Whether `marker` stands alone, without a length: TEM and RST0–RST7.
---@param marker integer
---@return boolean
local function standalone(marker)
    return marker == 0x01 or (marker >= 0xD0 and marker <= 0xD7)
end

--- Whether `marker` starts a frame: SOF0–SOF15, except DHT, JPG and DAC, which share the range.
---@param marker integer
---@return boolean
local function start_of_frame(marker)
    return marker >= 0xC0 and marker <= 0xCF and marker ~= 0xC4 and marker ~= 0xC8 and marker ~= 0xCC
end

--- Walk the segments after SOI to the first SOF, which carries the dimensions.
---@param read MCPHub.ImageHeader.Reader
local function parse_jpeg(read)
    local pos = 2
    for _ = 1, MAX_JPEG_SEGMENTS do
        if read(pos, 1) ~= "\255" then
            return nil, #read(pos, 1) == 0 and "truncated JPEG: no SOF marker" or "malformed JPEG: expected a marker"
        end
        -- Any number of FF fill bytes may precede a marker
        repeat
            pos = pos + 1
            local byte = read(pos, 1)
            if byte == "" then
                return nil, "truncated JPEG: no SOF marker"
            end
        until byte ~= "\255"
        local marker = read(pos, 1):byte()
        pos = pos + 1

        if not standalone(marker) then
            if marker == 0xD9 or marker == 0xDA then
                -- End of image, or start of scan: a frame header would have come first
                return nil, "malformed JPEG: no SOF marker before the image data"
            end
            local len = read(pos, 2)
            if #len < 2 then
                return nil, "truncated JPEG: no SOF marker"
            end
            local length = u16be(len, 1)
            if length < 2 then
                return nil, "malformed JPEG: segment length below 2"
            end
            if start_of_frame(marker) then
                local frame = read(pos + 2, 5)
                if #frame < 5 then
                    return nil, "truncated JPEG: incomplete SOF segment"
                end
                return header("image/jpeg", u16be(frame, 4), u16be(frame, 2))
            end
            pos = pos + length
        end
    end
    return nil, "malformed JPEG: too many segments before the SOF marker"
end

--- Parse an image header from a reader.
---@param read MCPHub.ImageHeader.Reader
---@return MCPHub.ImageHeader|nil header
---@return string|nil err
function M.parse(read)
    local head = read(0, 32)
    if head:sub(1, 8) == PNG_SIGNATURE then
        return parse_png(head)
    end
    local gif = head:sub(1, 6)
    if gif == "GIF87a" or gif == "GIF89a" then
        return parse_gif(head)
    end
    if head:sub(1, 4) == "RIFF" and head:sub(9, 12) == "WEBP" then
        return parse_webp(head)
    end
    if head:sub(1, 2) == "\255\216" then
        return parse_jpeg(read)
    end
    return nil, NOT_AN_IMAGE
end

--- Parse an image header from bytes in memory.
---@param bytes string
---@return MCPHub.ImageHeader|nil header
---@return string|nil err
function M.parse_string(bytes)
    return M.parse(function(offset, length)
        return bytes:sub(offset + 1, offset + length)
    end)
end

--- Read the header of the image file at `path`.
---@param path string
---@return MCPHub.ImageHeader|nil header
---@return string|nil err
function M.read(path)
    local file, open_err = io.open(path, "rb")
    if not file then
        return nil, ("cannot open %s: %s"):format(path, open_err)
    end
    local ok, result, err = pcall(M.parse, function(offset, length)
        file:seek("set", offset)
        return file:read(length) or ""
    end)
    file:close()
    if not ok then
        return nil, ("cannot read %s: %s"):format(path, result)
    end
    return result, err
end

return M
