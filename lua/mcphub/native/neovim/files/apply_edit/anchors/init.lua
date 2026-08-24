--- mcphub.native.neovim.files.apply_edit.anchors — public dispatcher for anchor resolvers.
---
--- One entry point — `M.resolve(anchor, record)` — that switches on
--- `anchor.by` and dispatches to the right resolver. The planner calls
--- this once per op; it never has to switch on `by` itself.
---
--- Every anchor resolver has the same signature
---   `(anchor, record) → (resolved, nil) | (nil, failure)`
--- where `resolved` is either a single `mcphub.edit.ResolvedRange` or, for
--- `unique_text` with `occurrence: "all"`, the multi-range shape
--- `{ ranges = { ResolvedRange, ... } }`.
---
--- Dispatch table:
---
---   * `line_range`                  → `anchors.line_range.resolve`
---   * `unique_text`                 → `anchors.unique_text.resolve`
---   * `before` / `after` / `between` → `anchors.modifier.resolve`
---
--- ## Note on internal dispatch
---
--- `modifier.lua` carries its own small private dispatch table for the
--- base anchor it wraps (i.e. `anchor.of`). That duplication is
--- deliberate — it avoids a require cycle (this module imports
--- `modifier`, so `modifier` cannot import this module without care)
--- and the duplication is two lines for two base kinds. When v2 adds
--- treesitter / lsp_symbol the dispatch tables grow; revisit
--- centralisation then.
---
--- @module "mcphub.native.neovim.files.apply_edit.anchors"

local line_range = require("mcphub.native.neovim.files.apply_edit.anchors.line_range")
local modifier = require("mcphub.native.neovim.files.apply_edit.anchors.modifier")
local unique_text = require("mcphub.native.neovim.files.apply_edit.anchors.unique_text")

local M = {}

--- Dispatch any validated anchor (base or modifier) to its resolver.
---
--- @param anchor table                Validated parsed anchor.
--- @param record mcphub.edit.FileRecord
--- @return mcphub.edit.ResolvedRange|{ranges: mcphub.edit.ResolvedRange[]}|nil
--- @return mcphub.edit.AnchorFailure|nil
function M.resolve(anchor, record)
    assert(type(anchor) == "table", "resolve: anchor must be a table")
    local by = anchor.by
    if by == "line_range" then
        return line_range.resolve(anchor, record)
    end
    if by == "unique_text" then
        return unique_text.resolve(anchor, record)
    end
    if by == "before" or by == "after" or by == "between" then
        return modifier.resolve(anchor, record)
    end
    -- v2 kinds (treesitter, lsp_symbol) are caught upstream by the
    -- schema's `unsupported_anchor_kind` rejection, so we should never
    -- see them here.
    error(string.format("resolve: unknown anchor kind %q", tostring(by)))
end

return M
