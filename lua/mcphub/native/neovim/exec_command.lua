--- The `execute_command` native tool. Kept apart from `terminal.lua`, which
--- registers it, so the definition can be exercised without a running hub.
local Path = require("plenary.path")
local exec = require("mcphub.native.neovim.utils.exec")

local M = {}

---@param job MCPHub.Exec.Job
---@return string
function M.format_result(job)
    local parts = {
        "Command: " .. job.command .. "\n",
        "Working Directory: " .. job.cwd .. "\n",
        "Exit Code: " .. tostring(job.exit_code) .. "\n",
    }
    if not job.stdout:is_empty() then
        table.insert(parts, "Output:\n\n" .. job.stdout:text())
    end
    if not job.stderr:is_empty() then
        table.insert(parts, "\nError Output:\n" .. job.stderr:text())
    end
    if job.stdout:is_empty() and job.stderr:is_empty() then
        table.insert(parts, "Command completed with no output.")
    end
    return table.concat(parts)
end

---@param req ToolRequest
---@param res ToolResponse
function M.handler(req, res)
    local command = req.params.command
    local cwd = req.params.cwd

    if not command or command == "" then
        return res:error("command field is required and cannot be empty.")
    end
    if not cwd or cwd == "" then
        return res:error("cwd field is required and cannot be empty.")
    end

    local path = Path:new(cwd)
    if not path:exists() then
        return res:error("Directory does not exist: " .. cwd)
    end
    if not path:is_dir() then
        return res:error("Path is not a directory: " .. cwd)
    end

    local _, err = exec.start({
        command = command,
        cwd = path:absolute(),
        on_exit = function(job)
            res:text(M.format_result(job)):send()
        end,
    })
    if err then
        return res:error(err)
    end
end

---@type MCPTool
M.definition = {
    name = "execute_command",
    description = [[Execute a shell command using vim.fn.jobstart and return the result.
    
Command Execution Guide:
1. Commands run in a separate process
2. Output is captured and returned when command completes
3. Environment is inherited from Neovim
4. Working directory must be specified]],

    inputSchema = {
        type = "object",
        properties = {
            command = {
                type = "string",
                description = "Shell command to execute",
                examples = { [["ls -la"]] },
            },
            cwd = {
                type = "string",
                description = "Working directory for the command",
                default = ".",
            },
        },
        required = { "command", "cwd" },
    },
    handler = M.handler,
}

return M
