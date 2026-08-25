-- Tests for the soft-deprecation policy helpers (`mcphub.utils.deprecation`).
--
-- Run with `make test`, or just this file with
-- `make test_file FILE=tests/utils/test_deprecation.lua`.
local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local deprecation = require("mcphub.utils.deprecation")

--- Notifications captured during the current case.
local notes
local real_notify

--- Notifications are emitted from a `vim.schedule` callback, so a case has to
--- let the loop run before counting them.
local function flush()
    vim.wait(20)
end

local T = new_set({
    hooks = {
        pre_case = function()
            notes = {}
            real_notify = vim.notify
            vim.notify = function(msg, level, opts)
                table.insert(notes, { msg = msg, level = level, opts = opts })
            end
            -- `warned` is module state shared with the running editor; every case
            -- starts and ends with it empty.
            deprecation.reset()
        end,
        post_case = function()
            vim.notify = real_notify
            deprecation.reset()
        end,
    },
})

T["registry"] = new_set()

T["registry"]["keys the notices by their own name"] = function()
    for key, notice in pairs(deprecation.notices) do
        eq(key, notice.name)
    end
end

T["registry"]["populates every field of every notice"] = function()
    for _, notice in pairs(deprecation.notices) do
        eq(type(notice.name), "string")
        eq(type(notice.replacement), "string")
        eq(type(notice.reason), "string")
        eq(notice.reason ~= "", true)
        eq(notice.name ~= notice.replacement, true)
    end
end

T["registry"]["covers edit_file and read_file"] = function()
    eq(deprecation.notices["neovim__edit_file"], deprecation.EDIT_FILE)
    eq(deprecation.notices["neovim__read_file"], deprecation.READ_FILE)
end

T["for_tool"] = new_set()

T["for_tool"]["resolves a deprecated tool"] = function()
    eq(deprecation.for_tool("neovim", "edit_file"), deprecation.EDIT_FILE)
    eq(deprecation.for_tool("neovim", "read_file"), deprecation.READ_FILE)
end

T["for_tool"]["returns nil for a tool that is not deprecated"] = function()
    eq(deprecation.for_tool("neovim", "apply_edit"), nil)
    eq(deprecation.for_tool("neovim", "read_with_fingerprint"), nil)
    eq(deprecation.for_tool("neovim", "write_file"), nil)
end

T["for_tool"]["is scoped by server name"] = function()
    eq(deprecation.for_tool("other", "read_file"), nil)
end

T["for_tool"]["tolerates non-string arguments"] = function()
    -- Deliberately violating the annotated signature: the guard inside
    -- `for_tool` exists because the UI may hand it a nil capability id.
    ---@diagnostic disable: param-type-mismatch
    eq(deprecation.for_tool(nil, "read_file"), nil)
    eq(deprecation.for_tool("neovim", nil), nil)
    eq(deprecation.for_tool(42, {}), nil)
    ---@diagnostic enable: param-type-mismatch
end

T["banner"] = new_set()

T["banner"]["names the replacement, the deprecated tool and the reason"] = function()
    local banner = deprecation.banner(deprecation.READ_FILE)
    eq(banner:match("^DEPRECATED: prefer `neovim__read_with_fingerprint` over `neovim__read_file`%.") ~= nil, true)
    eq(banner:find(deprecation.READ_FILE.reason, 1, true) ~= nil, true)
end

T["banner"]["ends with a paragraph break"] = function()
    eq(deprecation.banner(deprecation.EDIT_FILE):sub(-2), "\n\n")
end

T["notify_once"] = new_set()

T["notify_once"]["warns on the first call only"] = function()
    deprecation.notify_once(deprecation.READ_FILE)
    deprecation.notify_once(deprecation.READ_FILE)
    deprecation.notify_once(deprecation.READ_FILE)
    flush()
    eq(#notes, 1)
end

T["notify_once"]["rate-limits per tool, not globally"] = function()
    deprecation.notify_once(deprecation.READ_FILE)
    deprecation.notify_once(deprecation.EDIT_FILE)
    deprecation.notify_once(deprecation.READ_FILE)
    deprecation.notify_once(deprecation.EDIT_FILE)
    flush()
    eq(#notes, 2)
end

T["notify_once"]["warns at WARN level under the MCPHub title"] = function()
    deprecation.notify_once(deprecation.EDIT_FILE)
    flush()
    eq(notes[1].level, vim.log.levels.WARN)
    eq(notes[1].opts.title, "MCPHub")
end

T["notify_once"]["names both the tool and its replacement"] = function()
    deprecation.notify_once(deprecation.EDIT_FILE)
    flush()
    eq(notes[1].msg:find("neovim__edit_file", 1, true) ~= nil, true)
    eq(notes[1].msg:find("neovim__apply_edit", 1, true) ~= nil, true)
end

T["notify_once"]["is re-armed by reset"] = function()
    deprecation.notify_once(deprecation.READ_FILE)
    flush()
    eq(#notes, 1)
    deprecation.reset()
    deprecation.notify_once(deprecation.READ_FILE)
    flush()
    eq(#notes, 2)
end

T["notify_enabled"] = new_set()

T["notify_enabled"]["warns every time, since enabling is deliberate"] = function()
    deprecation.notify_enabled(deprecation.EDIT_FILE)
    deprecation.notify_enabled(deprecation.EDIT_FILE)
    flush()
    eq(#notes, 2)
end

T["notify_enabled"]["says the tool was just enabled"] = function()
    deprecation.notify_enabled(deprecation.READ_FILE)
    flush()
    eq(notes[1].msg:find("just enabled", 1, true) ~= nil, true)
    eq(notes[1].level, vim.log.levels.WARN)
end

T["notify_enabled"]["does not consume notify_once's one warning"] = function()
    deprecation.notify_enabled(deprecation.READ_FILE)
    deprecation.notify_once(deprecation.READ_FILE)
    flush()
    eq(#notes, 2)
end

T["tool wiring"] = new_set()

--- Find a tool by name in an `MCPTool[]` array.
local function find_tool(tools, name)
    for _, tool in ipairs(tools) do
        if tool.name == name then
            return tool
        end
    end
    return nil
end

T["tool wiring"]["read_file's description opens with its banner"] = function()
    local tools = require("mcphub.native.neovim.files.operations")
    local tool = assert(find_tool(tools, "read_file"), "read_file tool not found")
    local banner = deprecation.banner(deprecation.READ_FILE)
    eq(tool.description:sub(1, #banner), banner)
end

T["tool wiring"]["edit_file's description opens with its banner"] = function()
    local tool = require("mcphub.native.neovim.files.edit_file")
    local banner = deprecation.banner(deprecation.EDIT_FILE)
    eq(tool.description:sub(1, #banner), banner)
end

T["tool wiring"]["leaves the replacement tools undeprecated"] = function()
    for _, tool in ipairs(require("mcphub.native.neovim.files.apply_edit")) do
        eq(tool.description:match("^DEPRECATED"), nil)
        eq(deprecation.for_tool("neovim", tool.name), nil)
    end
end

return T
