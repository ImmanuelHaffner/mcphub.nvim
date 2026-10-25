-- Tests for how mcphub.extensions.codecompanion.core hands a tool's images to
-- CodeCompanion: nested in the tool's result for adapters that declare
-- `tool_result_images`, as sibling image messages otherwise, with dimensions
-- either way.
--
-- Run with `make test`, or just this file with
-- `make test_file FILE=tests/extensions/codecompanion/test_images.lua`.
local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local core = require("mcphub.extensions.codecompanion.core")
local image_cache = require("mcphub.utils.image_cache")

local real = {}

---@param n integer
---@return string
local function u32be(n)
    local function u16be(m)
        return string.char(math.floor(m / 256), m % 256)
    end
    return u16be(math.floor(n / 65536)) .. u16be(n % 65536)
end

--- The base64 of a PNG header for `width`×`height`.
---@param width integer
---@param height integer
---@return string
local function png64(width, height)
    local head = "\137PNG\r\n\26\n" .. u32be(13) .. "IHDR" .. u32be(width) .. u32be(height) .. "\8\6\0\0\0"
    return vim.base64.encode(head .. string.rep("\0", 32))
end

--- A chat stub recording what the extension adds to it.
---@param adapter_opts table?
---@return table chat
---@return { outputs: table[], images: table[] } calls
local function stub_chat(adapter_opts)
    local calls = { outputs = {}, images = {} }
    local chat = {
        adapter = adapter_opts and { opts = adapter_opts } or nil,
        add_tool_output = function(_, _, for_llm, for_user, opts)
            table.insert(calls.outputs, { for_llm = for_llm, for_user = for_user, opts = opts })
        end,
        add_image_message = function(_, image)
            table.insert(calls.images, image)
        end,
    }
    return chat, calls
end

--- Run the success handler of a function-calling tool on a parsed tool result.
---@param chat table
---@param images { data: string, mimeType: string }[]
local function succeed(chat, images)
    ---@diagnostic disable-next-line: missing-fields
    local handlers = core.create_output_handlers("neovim__view_image", true, {})
    handlers.success(
        { name = "neovim__view_image" },
        { { text = "Image `x.png`: image/png", images = images } },
        { tools = { chat = chat } }
    )
end

local NESTING = { tool_result_images = true, vision = true }

local T = new_set({
    hooks = {
        pre_case = function()
            real.cache_dir = image_cache.cache_dir
            real.config = package.loaded["codecompanion.config"]
            local dir = vim.fn.tempname()
            vim.fn.mkdir(dir, "p")
            image_cache.cache_dir = dir
            -- CodeCompanion isn't on the test runtimepath; this stands in for the config it reads
            package.loaded["codecompanion.config"] = { constants = { USER_ROLE = "user" } }
        end,
        post_case = function()
            vim.fn.delete(image_cache.cache_dir, "rf")
            image_cache.cache_dir = real.cache_dir
            package.loaded["codecompanion.config"] = real.config
        end,
    },
})

T["nests the images for an adapter that declares tool_result_images"] = function()
    local chat, calls = stub_chat(NESTING)
    succeed(chat, { { data = png64(64, 32), mimeType = "image/png" }, { data = png64(8, 8), mimeType = "image/png" } })

    eq(#calls.outputs, 1)
    local nested = calls.outputs[1].opts.images
    eq(#nested, 2)
    eq({ nested[1].base64, nested[1].mimetype }, { png64(64, 32), "image/png" })
    eq(#calls.images, 0)
end

T["adds sibling image messages for other adapters"] = function()
    local chat, calls = stub_chat({ vision = true })
    succeed(chat, { { data = png64(64, 32), mimeType = "image/png" }, { data = png64(8, 8), mimeType = "image/png" } })

    eq(#calls.outputs, 1)
    eq(calls.outputs[1].opts, nil)
    eq(#calls.images, 2)
    eq(calls.images[2].base64, png64(8, 8))
end

T["adds sibling image messages when the model has no vision"] = function()
    local chat, calls = stub_chat({ tool_result_images = true, vision = false })
    succeed(chat, { { data = png64(64, 32), mimeType = "image/png" } })

    eq(calls.outputs[1].opts, nil)
    eq(#calls.images, 1)
end

T["adds sibling image messages for a chat without an adapter"] = function()
    local chat, calls = stub_chat(nil)
    succeed(chat, { { data = png64(64, 32), mimeType = "image/png" } })

    eq(calls.outputs[1].opts, nil)
    eq(#calls.images, 1)
end

T["passes no images option when the result has none"] = function()
    local chat, calls = stub_chat(NESTING)
    succeed(chat, {})

    eq(calls.outputs[1].opts, nil)
    eq(#calls.images, 0)
end

T["attaches each image's dimensions on both paths"] = function()
    local nesting_chat, nesting = stub_chat(NESTING)
    succeed(nesting_chat, { { data = png64(64, 32), mimeType = "image/png" } })
    local sibling_chat, sibling = stub_chat({ vision = true })
    succeed(sibling_chat, { { data = png64(64, 32), mimeType = "image/png" } })

    eq(nesting.outputs[1].opts.images[1].dimensions, { width = 64, height = 32 })
    eq(sibling.images[1].dimensions, { width = 64, height = 32 })
end

T["leaves the dimensions out when the header cannot be read"] = function()
    local chat, calls = stub_chat(NESTING)
    succeed(chat, { { data = vim.base64.encode("not an image"), mimeType = "image/png" } })

    local image = calls.outputs[1].opts.images[1]
    eq(image.dimensions, nil)
    eq(image.mimetype, "image/png")
end

T["shows the user the same preview on both paths"] = function()
    local nesting_chat, nesting = stub_chat(NESTING)
    succeed(nesting_chat, { { data = png64(64, 32), mimeType = "image/png" } })
    local sibling_chat, sibling = stub_chat({ vision = true })
    succeed(sibling_chat, { { data = png64(64, 32), mimeType = "image/png" } })

    --- The cache names files by time and a counter, so compare with the names masked
    local function masked(text)
        return (text:gsub("%d+%.png", "N.png"))
    end
    local preview = nesting.outputs[1].for_user
    eq(preview:find("#### Preview Images", 1, true) ~= nil, true)
    eq(masked(preview), masked(sibling.outputs[1].for_user))
    eq(nesting.outputs[1].for_llm, sibling.outputs[1].for_llm)
end

return T
