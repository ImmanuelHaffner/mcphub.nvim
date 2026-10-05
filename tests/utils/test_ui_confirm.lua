-- Tests for the decline choices of mcphub.utils.ui.confirm.
--
-- Run with `make test`, or just this file with
-- `make test_file FILE=tests/utils/test_ui_confirm.lua`.
local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local async = require("plenary.async")
local ui = require("mcphub.utils.ui")

local CHOICES = {
    { key = "w", label = "Wrong command", id = "wrong" },
    { key = "d", label = "Don't execute", id = "dont" },
    { key = "o", label = "Other…", id = "other", input = true },
}

--- Open a confirmation window, focused, without waiting for its answer.
---@param opts? table
---@return fun(): boolean, boolean, table? wait Waits for the window's answer and returns it
local function open(opts)
    local result
    async.run(function()
        local confirmed, cancelled, choice = ui.confirm("Run it?", opts or { choices = CHOICES })
        result = { confirmed, cancelled, choice }
    end)
    return function()
        assert(
            vim.wait(1000, function()
                return result ~= nil
            end, 10),
            "confirm did not return"
        )
        return result[1], result[2], result[3]
    end
end

---@param keys string
local function press(keys)
    vim.api.nvim_feedkeys(vim.keycode(keys), "x", false)
end

local T = new_set({
    hooks = {
        post_case = function()
            vim.cmd("stopinsert")
            for _, win in ipairs(vim.api.nvim_list_wins()) do
                if vim.api.nvim_win_get_config(win).relative ~= "" then
                    vim.api.nvim_win_close(win, true)
                end
            end
        end,
    },
})

T["a reason key declines with its id"] = function()
    local wait = open()
    press("w")
    local confirmed, cancelled, choice = wait()
    eq({ confirmed, cancelled, choice }, { false, false, { id = "wrong" } })
end

T["an uppercase key works the same"] = function()
    local wait = open()
    press("D")
    eq(select(3, wait()), { id = "dont" })
end

T["Other declines with the text typed"] = function()
    local wait = open()
    press("o")
    press("itoo broad<Esc><CR>")
    local confirmed, cancelled, choice = wait()
    eq({ confirmed, cancelled, choice }, { false, false, { id = "other", text = "too broad" } })
end

T["Other without text returns to the window"] = function()
    local wait = open()
    local win = vim.api.nvim_get_current_win()
    press("o")
    press("<CR>")
    eq(vim.api.nvim_win_is_valid(win), true)
    eq(vim.api.nvim_get_current_win(), win)
    press("o")
    press("<Esc>")
    eq(vim.api.nvim_get_current_win(), win)
    press("n")
    local confirmed, cancelled, choice = wait()
    eq({ confirmed, cancelled, choice }, { false, false, nil })
end

T["plain No and Cancel carry no choice"] = function()
    local wait = open()
    press("n")
    eq({ wait() }, { false, false })
    wait = open()
    press("c")
    eq({ wait() }, { false, true })
end

T["choices wrap between entries within the window"] = function()
    local choices = {}
    for i, key in ipairs({ "a", "b", "d", "e", "f", "g", "h", "i", "j" }) do
        table.insert(choices, { key = key, label = "Reason number " .. i, id = key })
    end
    open({ choices = choices })
    local win = vim.api.nvim_get_current_win()
    local width = vim.api.nvim_win_get_width(win)
    local text = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
    local rows = 0
    for _, line in ipairs(text) do
        eq(vim.fn.strdisplaywidth(line) <= width, true)
        rows = rows + (line:find("[", 1, true) and 1 or 0)
    end
    eq(rows > 1, true)
    for _, choice in ipairs(choices) do
        local entry = ("[%s] %s"):format(choice.key, choice.label)
        eq(#vim.tbl_filter(function(line)
            return line:find(entry, 1, true) ~= nil
        end, text), 1)
    end
end

T["a colliding key raises"] = function()
    for _, key in ipairs({ "y", "Q" }) do
        MiniTest.expect.error(function()
            ui.confirm("Run it?", { choices = { { key = key, label = "Clash", id = "clash" } } })
        end, "collides")
    end
    MiniTest.expect.error(function()
        ui.confirm("Run it?", { choices = { CHOICES[1], { key = "W", label = "Twice", id = "twice" } } })
    end, "collides")
end

return T
