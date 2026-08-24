--- Test helpers for the mcphub.native.neovim.files.apply_edit.engine suite.
---
--- The engine's two LLM-reachable functions — `schema.validate(input)`
--- and `planner.plan(parsed_input)` — both accept an internal
--- `opts.bypass_fingerprint` flag. The flag is invisible to the LLM
--- (the production seal `mcphub.native.neovim.files.apply_edit.engine.apply(input)` takes no opts and
--- never threads anything through), but it lets tests focus on the
--- behaviour they're actually exercising without constructing a real
--- `baseline_fingerprint` for every op.
---
--- This module wraps the two entry points with the bypass flag set
--- by default. Spec files import what they need:
---
---   local helpers = require'tests.native.neovim.files.apply_edit.helpers'
---   local plan, fail = helpers.plan(parsed_input)
---   local ok, parsed  = helpers.validate(input)
---
--- A dedicated `test_fingerprint_enforcement` calls
--- `schema.validate` / `planner.plan` directly (no bypass) to exercise
--- the strict path.
---
--- @module "tests.native.neovim.files.apply_edit.helpers"

local planner = require("mcphub.native.neovim.files.apply_edit.planner")
local schema = require("mcphub.native.neovim.files.apply_edit.schema")

local M = {}

--- Call `schema.validate` with `bypass_fingerprint = true`.
---
--- @param input table
--- @return boolean ok
--- @return table   parsed_or_errors
function M.validate(input)
    return schema.validate(input, { bypass_fingerprint = true })
end

--- Call `planner.plan` with `bypass_fingerprint = true`.
---
--- @param parsed_input table
--- @return table|nil plan
--- @return table|nil failure
function M.plan(parsed_input)
    return planner.plan(parsed_input, { bypass_fingerprint = true })
end

return M
