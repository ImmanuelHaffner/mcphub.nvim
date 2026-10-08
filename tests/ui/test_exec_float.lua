-- Tests for mcphub.ui.exec_float, the float showing an `execute_command`
-- job's log.
--
-- Run with `make test`, or just this file with
-- `make test_file FILE=tests/ui/test_exec_float.lua`.
local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local State = require("mcphub.state")
local exec = require("mcphub.native.neovim.utils.exec")
local exec_float = require("mcphub.ui.exec_float")
local spill = require("mcphub.utils.spill")

local real = {}

--- Real jobs a case started; `post_case` stops those still running.
---@type MCPHub.Exec.Job[]
local started = {}

---@param command string
---@return MCPHub.Exec.Job
local function start(command)
    local job = assert(exec.start({
        command = command,
        cwd = "/tmp",
        kill_ladder = { { "sigint", 200 }, { "sigterm", 200 } },
    }))
    table.insert(started, job)
    return job
end

---@param job MCPHub.Exec.Job
---@return boolean exited
local function wait_exit(job)
    return vim.wait(5000, function()
        return job.exited
    end, 10)
end

--- A job as the runner records it, whose log is a file the case writes itself.
---@param lines string[]
local function fake_job(lines)
    local path = vim.fn.tempname()
    vim.fn.writefile(lines, path)
    return {
        command = "tail -f",
        cwd = "/tmp",
        started_at = vim.uv.now(),
        exited = false,
        terminating = false,
        log_path = path,
        stats = { out_bytes = 0, out_lines = 0 },
    }
end

---@param f MCPHub.ExecFloat
local function lines(f)
    return vim.api.nvim_buf_get_lines(f.buf, 0, -1, false)
end

--- The bottom border's text.
---@param f MCPHub.ExecFloat
---@return string
local function footer(f)
    local text = {}
    for _, chunk in ipairs(vim.api.nvim_win_get_config(f.win).footer or {}) do
        text[#text + 1] = chunk[1]
    end
    return table.concat(text)
end

local T = new_set({
    hooks = {
        pre_case = function()
            real.builtin_tools = State.config.builtin_tools
            State.config.builtin_tools = { execute_command = { refresh_ms = 20 } }
            real.spill_dir = spill.DIR
            spill.DIR = vim.fn.tempname()
            real.win = vim.api.nvim_get_current_win()
        end,
        post_case = function()
            for _, job in ipairs(started) do
                job:terminate("stopped")
                wait_exit(job)
            end
            started = {}
            for _, win in ipairs(vim.api.nvim_list_wins()) do
                if vim.api.nvim_win_get_config(win).relative ~= "" then
                    vim.api.nvim_win_close(win, true)
                end
            end
            while vim.fn.tabpagenr("$") > 1 do
                vim.cmd("tabclose!")
            end
            vim.api.nvim_set_current_win(real.win)
            vim.fn.delete(spill.DIR, "rf")
            spill.DIR = real.spill_dir
            State.config.builtin_tools = real.builtin_tools
        end,
    },
})

T["open"] = new_set()

T["open"]["shows the command's log"] = function()
    local job = start("seq 1 50")
    local f = exec_float.open(job)
    eq(
        vim.wait(2000, function()
            return lines(f)[#lines(f)] == "50"
        end, 10),
        true
    )
    eq(#lines(f), 50)
end

T["open"]["follows the tail while the cursor is on the last line"] = function()
    local job = fake_job({ "1", "2", "3" })
    local f = exec_float.open(job)
    eq(vim.api.nvim_win_get_cursor(f.win)[1], 3)
    vim.fn.writefile({ "4", "5" }, job.log_path, "a")
    eq(
        vim.wait(1000, function()
            return vim.api.nvim_win_get_cursor(f.win)[1] == 5
        end, 10),
        true
    )
    vim.api.nvim_win_set_cursor(f.win, { 1, 0 })
    vim.fn.writefile({ "6" }, job.log_path, "a")
    eq(
        vim.wait(1000, function()
            return #lines(f) == 6
        end, 10),
        true
    )
    eq(vim.api.nvim_win_get_cursor(f.win)[1], 1)
    job.exited = true
    vim.fn.delete(job.log_path)
end

T["open"]["shows the log of a finished command, without a timer"] = function()
    local job = start("printf 'a\\nb\\n'")
    eq(wait_exit(job), true)
    local f = exec_float.open(job)
    eq(lines(f), { "a", "b" })
    eq(f.timer, nil)
end

T["open"]["stops its timer once the command has exited"] = function()
    local job = start("sleep 0.2; echo done")
    local f = exec_float.open(job)
    eq(f.timer ~= nil, true)
    eq(wait_exit(job), true)
    eq(
        vim.wait(1000, function()
            return f.timer == nil
        end, 10),
        true
    )
    eq(lines(f), { "done" })
end

T["open"]["focuses the float a command already has"] = function()
    local job = fake_job({ "x" })
    local f = exec_float.open(job)
    vim.api.nvim_set_current_win(real.win)
    eq(exec_float.open(job), f)
    eq(vim.api.nvim_get_current_win(), f.win)
    job.exited = true
    vim.fn.delete(job.log_path)
end

T["keys"] = new_set()

T["keys"]["<C-c> cancels the command and leaves other buffers' <C-c> alone"] = function()
    local other = vim.api.nvim_get_current_buf()
    vim.keymap.set("n", "<C-c>", "<Nop>", { buffer = other })
    local before = vim.fn.maparg("<C-c>", "n", false, true)
    local job = start("sleep 100")
    exec_float.open(job)
    vim.api.nvim_feedkeys(vim.keycode("<C-c>"), "x", false)
    eq(job.reason, "cancelled")
    eq(wait_exit(job), true)
    vim.api.nvim_set_current_win(real.win)
    eq(vim.fn.maparg("<C-c>", "n", false, true), before)
    vim.keymap.del("n", "<C-c>", { buffer = other })
end

T["keys"]["q closes the float"] = function()
    local f = exec_float.open(start("true"))
    vim.api.nvim_feedkeys("q", "x", false)
    eq(vim.api.nvim_win_is_valid(f.win), false)
end

T["keys"]["gF opens the full log in a tab"] = function()
    local job = start("echo hi")
    eq(wait_exit(job), true)
    local f = exec_float.open(job)
    vim.api.nvim_feedkeys("gF", "x", false)
    eq(vim.api.nvim_win_is_valid(f.win), false)
    eq(vim.fn.tabpagenr("$"), 2)
    eq(vim.api.nvim_buf_get_name(0), vim.fn.resolve(job.log_path))
end

T["keys"]["the bottom border hints at the keys that apply"] = function()
    local job = start("sleep 100")
    local f = exec_float.open(job, {
        footer = function()
            return { { "stats", "Comment" } }
        end,
    })
    eq(footer(f), " stats   q close   <C-c> cancel   gF full log ")
    job:terminate("cancelled")
    eq(wait_exit(job), true)
    eq(
        vim.wait(1000, function()
            return f.timer == nil
        end, 10),
        true
    )
    eq(footer(f), " stats   q close   gF full log ")
end

return T
