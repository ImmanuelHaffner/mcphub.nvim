-- Tests for mcphub.native.neovim.files.view_image, the `view_image` tool:
-- its registration behind `builtin_tools.view_image.enabled`, and its handler.
--
-- Run with `make test`, or just this file with
-- `make test_file FILE=tests/native/neovim/files/view_image/test_view_image.lua`.
local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local NativeServer = require("mcphub.native.utils.server")
local State = require("mcphub.state")
local core = require("mcphub.extensions.codecompanion.core")
local image_cache = require("mcphub.utils.image_cache")
local mcphub = require("mcphub")
local paths = require("mcphub.native.neovim.files.view_image.paths")
local prompt = require("mcphub.utils.prompt")
local resize = require("mcphub.native.neovim.files.view_image.resize")
local view_image = require("mcphub.native.neovim.files.view_image")

local FILES_MODULE = "mcphub.native.neovim.files"

--- Names of the tools `files/init.lua` registers with the `neovim` server when
--- loaded afresh under `builtin_tools`.
---@param builtin_tools table?
---@return string[]
local function registered_tools(builtin_tools)
    local real_add_tool, real_add_resource = mcphub.add_tool, mcphub.add_resource
    local real_builtin_tools = State.config.builtin_tools
    local names = {}
    mcphub.add_tool = function(server, tool)
        if server == "neovim" then
            table.insert(names, tool.name)
        end
    end
    mcphub.add_resource = function() end
    State.config.builtin_tools = builtin_tools
    package.loaded[FILES_MODULE] = nil

    local ok, err = pcall(require, FILES_MODULE)

    package.loaded[FILES_MODULE] = nil
    mcphub.add_tool, mcphub.add_resource = real_add_tool, real_add_resource
    State.config.builtin_tools = real_builtin_tools
    assert(ok, err)
    return names
end

--- Call `view_image` through a native server that serves only it.
---@param arguments table
---@param caller table?
---@return { content: MCPContent[], isError?: boolean }? result
---@return string? err
local function call(arguments, caller)
    ---@diagnostic disable-next-line: missing-fields
    local server = setmetatable(
        { name = "fake", status = "connected", capabilities = { tools = { view_image.definition } } },
        NativeServer
    )
    local response, err, done
    server:call_tool("view_image", arguments, {
        caller = caller,
        callback = function(r, e)
            response, err, done = r, e, true
        end,
    })
    assert(vim.wait(1000, function()
        return done
    end, 10))
    return response and response.result, err
end

local T = new_set()

T["registration"] = new_set()

T["registration"]["is absent by default"] = function()
    local names = registered_tools(nil)
    eq(vim.tbl_contains(names, "view_image"), false)
    -- Guards against a vacuous pass: the module did register its other tools
    eq(vim.tbl_contains(names, "write_file"), true)
end

T["registration"]["is absent when disabled explicitly"] = function()
    eq(vim.tbl_contains(registered_tools({ view_image = { enabled = false } }), "view_image"), false)
end

T["registration"]["is present when enabled"] = function()
    eq(vim.tbl_contains(registered_tools({ view_image = { enabled = true } }), "view_image"), true)
end

T["registration"]["defaults to disabled in the config"] = function()
    local defaults = require("mcphub.config").setup({})
    eq(defaults.builtin_tools.view_image, { enabled = false })
end

T["definition"] = new_set()

T["definition"]["declares one required path"] = function()
    local def = view_image.definition
    eq(def.name, "view_image")
    eq(def.call_noun, "image")
    eq(def.inputSchema.required, { "path" })
    eq(def.inputSchema.properties.path.type, "string")
end

T["definition"]["labels a call with its path"] = function()
    eq(view_image.definition.label({ path = "a/b.png" }), "a/b.png")
    eq(view_image.definition.label({ path = "" }), nil)
    eq(view_image.definition.label({}), nil)
end

---@param n integer
---@return string
local function u32be(n)
    local function u16be(m)
        return string.char(math.floor(m / 256), m % 256)
    end
    return u16be(math.floor(n / 65536)) .. u16be(n % 65536)
end

--- A PNG header for `width`×`height`, padded to `size` bytes; the handler reads
--- only the header, and M3 sends the bytes unchanged.
---@param width integer
---@param height integer
---@param size? integer
---@return string
local function png(width, height, size)
    local head = "\137PNG\r\n\26\n" .. u32be(13) .. "IHDR" .. u32be(width) .. u32be(height) .. "\8\6\0\0\0"
    return head .. string.rep("\0", math.max((size or 64) - #head, 0))
end

--- A fresh temp directory, removed after the case. Its realpath, because macOS
--- temp paths run through a symlink to /private.
---@return string
local function tempdir()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    MiniTest.finally(function()
        vim.fn.delete(dir, "rf")
    end)
    return assert(vim.uv.fs_realpath(dir))
end

---@param path string
---@param bytes string
---@return string path
local function write(path, bytes)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local file = assert(io.open(path, "wb"))
    file:write(bytes)
    file:close()
    return path
end

--- The caller of a CodeCompanion chat whose working directory is `cwd`, as the
--- stubbed `codecompanion.memory` reports it.
---@param cwd string
---@return table
local function chat_caller(cwd)
    return { type = "codecompanion", codecompanion = { chat = { cwd = cwd } } }
end

---@param result table?
---@param err string?
---@param fragments string[] Each expected somewhere in the error message
local function expect_error(result, err, fragments)
    result = assert(result, err)
    eq(result.isError, true)
    eq(#result.content, 1)
    local text = result.content[1].text or ""
    for _, fragment in ipairs(fragments) do
        if not text:find(fragment, 1, true) then
            error(("expected an error containing %q, got %q"):format(fragment, text), 2)
        end
    end
end

local MEMORY_MODULE = "codecompanion.memory"

T["handler"] = new_set({
    hooks = {
        pre_case = function()
            -- CodeCompanion isn't on the test runtimepath; this stands in for its memory module
            package.loaded[MEMORY_MODULE] = {
                chat_cwd = function(chat)
                    return chat.cwd
                end,
            }
        end,
        post_case = function()
            package.loaded[MEMORY_MODULE] = nil
            package.preload[MEMORY_MODULE] = nil
        end,
    },
})

T["handler"]["sends an in-cap PNG inside the chat's cwd unchanged"] = function()
    local dir = tempdir()
    local bytes = png(64, 32)
    local path = write(vim.fs.joinpath(dir, "logo.png"), bytes)

    local result = assert(call({ path = path }, chat_caller(dir)))

    eq(result.isError, nil)
    eq(#result.content, 2)
    eq(result.content[1].type, "text")
    eq(result.content[1].text, view_image.geometry(path, { mime = "image/png", width = 64, height = 32 }, 88))
    eq(result.content[2].type, "image")
    eq(result.content[2].mimeType, "image/png")
    eq(vim.base64.decode(result.content[2].data), bytes)
end

T["handler"]["resolves a relative path against the chat's cwd"] = function()
    local dir = tempdir()
    write(vim.fs.joinpath(dir, "sub", "x.png"), png(10, 10))

    local result = assert(call({ path = "sub/x.png" }, chat_caller(dir)))

    eq(result.isError, nil)
    eq(result.content[2].mimeType, "image/png")
end

T["handler"]["falls back to the global cwd without a chat"] = function()
    local dir = tempdir()
    write(vim.fs.joinpath(dir, "x.png"), png(10, 10))
    local previous = vim.fn.chdir(dir)
    MiniTest.finally(function()
        vim.fn.chdir(previous)
    end)

    eq(paths.chat_cwd(nil), vim.fn.getcwd(-1, -1))
    eq(assert(call({ path = "x.png" })).isError, nil)
end

T["handler"]["falls back to the global cwd when CodeCompanion cannot tell"] = function()
    package.loaded[MEMORY_MODULE] = nil
    package.preload[MEMORY_MODULE] = function()
        error("no codecompanion.memory here")
    end

    eq(paths.chat_cwd(chat_caller("/elsewhere")), vim.fn.getcwd(-1, -1))
end

T["handler"]["refuses a path outside the chat's cwd"] = function()
    local dir = tempdir()
    local cwd = vim.fs.joinpath(dir, "a")
    vim.fn.mkdir(cwd, "p")
    local path = write(vim.fs.joinpath(dir, "b", "x.png"), png(10, 10))

    local result, err = call({ path = path }, chat_caller(cwd))

    expect_error(result, err, { path, "is outside the chat's working directory", cwd })
end

T["handler"]["counts a symlink pointing outside as outside"] = function()
    local dir = tempdir()
    local cwd = vim.fs.joinpath(dir, "a")
    vim.fn.mkdir(cwd, "p")
    local target = write(vim.fs.joinpath(dir, "b", "x.png"), png(10, 10))
    assert(vim.uv.fs_symlink(target, vim.fs.joinpath(cwd, "link.png")))

    local result, err = call({ path = "link.png" }, chat_caller(cwd))

    expect_error(result, err, { "is outside the chat's working directory" })
end

T["handler"]["does not take a shared prefix for containment"] = function()
    local dir = tempdir()
    local cwd = vim.fs.joinpath(dir, "a")
    vim.fn.mkdir(cwd, "p")
    local path = write(vim.fs.joinpath(dir, "ab", "i.png"), png(10, 10))

    local result, err = call({ path = path }, chat_caller(cwd))

    expect_error(result, err, { "is outside the chat's working directory" })
end

--- Stub the resize backend away for the rest of the case.
local function without_backend()
    local real_backend = resize.backend
    ---@diagnostic disable-next-line: duplicate-set-field
    resize.backend = function()
        return nil
    end
    MiniTest.finally(function()
        resize.backend = real_backend
    end)
end

T["handler"]["without a backend, refuses an image over the long-edge cap"] = function()
    without_backend()
    local dir = tempdir()
    write(vim.fs.joinpath(dir, "wide.png"), png(3000, 100))

    local result, err = call({ path = "wide.png" }, chat_caller(dir))

    expect_error(result, err, { "3000", "2576", "`sips` or ImageMagick" })
end

T["handler"]["without a backend, refuses an image over the base64 cap"] = function()
    without_backend()
    local dir = tempdir()
    -- 3,750,001 bytes encode to 5,000,004 bytes of base64
    write(vim.fs.joinpath(dir, "heavy.png"), png(100, 100, 3750001))

    local result, err = call({ path = "heavy.png" }, chat_caller(dir))

    expect_error(result, err, { "5000004", "5000000", "`sips` or ImageMagick" })
end

T["handler"]["without a backend, still sends an in-cap image"] = function()
    without_backend()
    local dir = tempdir()
    write(vim.fs.joinpath(dir, "x.png"), png(10, 10))

    local result = assert(call({ path = "x.png" }, chat_caller(dir)))

    eq(result.isError, nil)
    eq(result.content[2].mimeType, "image/png")
end

T["handler"]["refuses a file that is not an image"] = function()
    local dir = tempdir()
    write(vim.fs.joinpath(dir, "notes.png"), "hello\n")

    local result, err = call({ path = "notes.png" }, chat_caller(dir))

    expect_error(result, err, { "notes.png", "not a PNG, JPEG, GIF or WebP image" })
end

T["handler"]["reports a missing file"] = function()
    local dir = tempdir()

    local result, err = call({ path = "gone.png" }, chat_caller(dir))

    expect_error(result, err, { "gone.png does not exist" })
end

T["handler"]["refuses a directory"] = function()
    local dir = tempdir()
    vim.fn.mkdir(vim.fs.joinpath(dir, "shots"), "p")

    local result, err = call({ path = "shots" }, chat_caller(dir))

    expect_error(result, err, { "shots is not a regular file" })
end

T["handler"]["takes the type from the bytes, not the extension"] = function()
    local dir = tempdir()
    write(vim.fs.joinpath(dir, "x.jpg"), png(10, 10))

    local result = assert(call({ path = "x.jpg" }, chat_caller(dir)))

    eq(result.content[2].mimeType, "image/png")
end

T["handler"]["reaches the chat as an image through the CodeCompanion extension"] = function()
    local dir = tempdir()
    local bytes = png(64, 32)
    write(vim.fs.joinpath(dir, "logo.png"), bytes)
    local result = assert(call({ path = "logo.png" }, chat_caller(dir)))

    local real_save, real_config = image_cache.save_image, package.loaded["codecompanion.config"]
    ---@diagnostic disable-next-line: duplicate-set-field
    image_cache.save_image = function()
        return vim.fs.joinpath(dir, "cached.png")
    end
    package.loaded["codecompanion.config"] = { constants = { USER_ROLE = "user" } }
    MiniTest.finally(function()
        image_cache.save_image, package.loaded["codecompanion.config"] = real_save, real_config
    end)

    local added, images = {}, {}
    local chat = {
        add_tool_output = function(_, _, text)
            table.insert(added, text)
        end,
        add_image_message = function(_, image)
            table.insert(images, image)
        end,
    }
    ---@diagnostic disable-next-line: missing-fields
    local handlers = core.create_output_handlers("neovim__view_image", true, {})
    handlers.success({ name = "neovim__view_image" }, { prompt.parse_tool_response({ result = result }) }, {
        tools = { chat = chat },
    })

    eq(#added, 1)
    eq(added[1]:find("Image `logo.png`: image/png, 64×32", 1, true) ~= nil, true)
    eq(#images, 1)
    eq(images[1].mimetype, "image/png")
    eq(vim.base64.decode(images[1].base64), bytes)
end

return T
