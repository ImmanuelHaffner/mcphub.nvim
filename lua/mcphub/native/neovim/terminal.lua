local api = vim.api
local mcphub = require("mcphub")

-- Tool to execute Lua code using nvim_exec2
mcphub.add_tool("neovim", {
    name = "execute_lua",
    description = [[Execute Lua code in Neovim using nvim_exec2 with lua heredoc.]],
    inputSchema = {
        type = "object",
        properties = {
            code = {
                type = "string",
                description = [[
Lua code to execute:

String Formatting Guide:
1. Newlines in Code:
   - Use \n for new lines in your code
   - Example: "local x = 1\nprint(x)"

2. Newlines in Output:
   - Use \\n when you want to print newlines
   - Example: print('Line 1\\nLine 2')

3. Complex Data:
   - Use vim.print() for formatted output
   - Use vim.inspect() for complex structures
   - Both handle escaping automatically

4. String Concatenation:
   - Prefer '..' over string.format()
   - Example: print('Count: ' .. vim.api.nvim_buf_line_count(0))
          ]],
                examples = {
                    -- Simple multiline code
                    "local bufnr = vim.api.nvim_get_current_buf()\nprint('Current buffer:', bufnr)",

                    -- Output with newlines
                    "print('Buffer Info:\\nNumber: ' .. vim.api.nvim_get_current_buf())",

                    -- Complex info with proper formatting
                    [[local bufnr = vim.api.nvim_get_current_buf()
local name = vim.api.nvim_buf_get_name(bufnr)
local ft = vim.bo[bufnr].filetype
local lines = vim.api.nvim_buf_line_count(bufnr)
print('Buffer Info:\\nBuffer Number: ' .. bufnr .. '\\nFile Name: ' .. name .. '\\nFiletype: ' .. ft .. '\\nTotal Lines: ' .. lines)]],

                    -- Using vim.print for complex data
                    [[local info = {
  buffer = vim.api.nvim_get_current_buf(),
  name = vim.api.nvim_buf_get_name(0),
  lines = vim.api.nvim_buf_line_count(0)
}
vim.print(info)]],
                },
            },
        },
        required = { "code" },
    },
    handler = function(req, res)
        local code = req.params.code
        if not code then
            return res:error("code field is required."):send()
        end

        -- Construct Lua heredoc
        local src = string.format(
            [[
lua << EOF
%s
EOF]],
            code
        )

        -- Execute with output capture
        local result = api.nvim_exec2(src, { output = true })

        if result.output then
            return res:text(result.output):send()
        else
            return res:text("Code executed successfully. (No output)"):send()
        end
    end,
})

mcphub.add_tool("neovim", require("mcphub.native.neovim.exec_command").definition)
