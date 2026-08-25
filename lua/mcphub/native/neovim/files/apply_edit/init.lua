--- In-tree `neovim` native-server tools backed by the structured-edit engine
--- in `mcphub.native.neovim.files.apply_edit.engine`:
---
---   * `neovim__apply_edit`              — structured batch edits
---   * `neovim__read_with_fingerprint`   — read + baseline-fingerprint emission
---
--- These are intended to ship together. `apply_edit` requires every op
--- to carry a `baseline_fingerprint` field; the only legitimate source
--- of those fingerprints is `read_with_fingerprint`. Once both are
--- registered, the user should disable the legacy `neovim__read_file`
--- tool from mcphub's config — required fingerprints make any other
--- read path a footgun.
---
--- Registration does NOT happen here. Like every other tool module under
--- `files/`, this one only *returns* its tools and `files/init.lua` adds
--- them to the `neovim` server. The engine modules underneath stay pure
--- Lua and remain unit-testable in isolation.
---
--- @module "mcphub.native.neovim.files.apply_edit"

local State = require("mcphub.state")
local edit = require("mcphub.native.neovim.files.apply_edit.engine")
local edit_json = require("mcphub.native.neovim.files.apply_edit.json")
local edit_read = require("mcphub.native.neovim.files.apply_edit.read")

--------------------------------------------------------------------------------
-- Anchor schemas
--------------------------------------------------------------------------------

-- An Anchor selects a location or range in a file. Base anchors resolve to a
-- range; positional modifiers (before/after wrap a base anchor; between names
-- two adjacent texts) produce a position. The schema admits a 3-level nesting
-- cap implicitly via `Anchor → Modifier → BaseAnchor`; deeper nesting is
-- unreachable because modifiers only wrap base anchors, not other modifiers.

local base_anchor_schema = {
    oneOf = {
        -- line_range: by absolute, 1-based, inclusive line numbers.
        {
            type = "object",
            properties = {
                by = { type = "string", const = "line_range" },
                start = { type = "integer", minimum = 1 },
                ["end"] = { type = "integer", minimum = 1 },
            },
            required = { "by", "start", "end" },
            additionalProperties = false,
        },
        -- unique_text: by a substring of file content. Must resolve to a single
        -- range unless `occurrence` disambiguates. `"all"` is valid only on
        -- delete_range; the engine enforces that at validation time.
        {
            type = "object",
            properties = {
                by = { type = "string", const = "unique_text" },
                text = { type = "string", minLength = 1 },
                occurrence = {
                    oneOf = {
                        { type = "string", const = "all" },
                        {
                            type = "object",
                            properties = { nth = { type = "integer", minimum = 1 } },
                            required = { "nth" },
                            additionalProperties = false,
                        },
                    },
                },
            },
            required = { "by", "text" },
            additionalProperties = false,
        },
        -- treesitter: by a query capture and optional name predicate. (v2)
        {
            type = "object",
            properties = {
                by = { type = "string", const = "treesitter" },
                query = { type = "string", minLength = 1 },
                name = { type = "string" },
            },
            required = { "by", "query" },
            additionalProperties = false,
        },
        -- lsp_symbol: by an LSP document symbol. (v2)
        {
            type = "object",
            properties = {
                by = { type = "string", const = "lsp_symbol" },
                name = { type = "string", minLength = 1 },
                kind = { type = "string" },
            },
            required = { "by", "name" },
            additionalProperties = false,
        },
    },
}

local modifier_anchor_schema = {
    oneOf = {
        -- before / after: position immediately before/after a base anchor.
        {
            type = "object",
            properties = {
                by = { type = "string", enum = { "before", "after" } },
                of = base_anchor_schema,
            },
            required = { "by", "of" },
            additionalProperties = false,
        },
        -- between: a position at the seam between two adjacent texts. The two
        -- texts are matched as one contiguous block
        -- (before_text .. "\n" .. after_text); the seam falls at the join. Use
        -- this when the context that makes the location unique straddles the
        -- insertion point.
        {
            type = "object",
            properties = {
                by = { type = "string", const = "between" },
                before_text = { type = "string", minLength = 1 },
                after_text = { type = "string", minLength = 1 },
            },
            required = { "by", "before_text", "after_text" },
            additionalProperties = false,
        },
    },
}

-- The top-level Anchor admits either a base anchor (resolves to a range) or a
-- modifier-wrapped anchor (resolves to a position).
local anchor_schema = {
    oneOf = { base_anchor_schema, modifier_anchor_schema },
}

--------------------------------------------------------------------------------
-- Common op fragments
--------------------------------------------------------------------------------

local indent_schema = { type = "string", enum = { "match_anchor", "preserve", "detect" } }

-- baseline_fingerprint: a 7-character lowercase-hex content fingerprint
-- previously issued by neovim__read_with_fingerprint. The planner re-computes
-- and compares; mismatch → stale_fingerprint failure. See mcphub.native.neovim.files.apply_edit.fingerprint
-- for the format.
local baseline_fingerprint_schema = { type = "string", pattern = "^[0-9a-f]{7}$" }

-- Ops that introduce content (replace_range, insert) must supply EXACTLY ONE
-- of `content` or `content_ref`. Expressed as `oneOf` over two required sets.
-- The shape below is meant to be `allOf`-merged with the per-op base.
local content_xor_schema = {
    oneOf = {
        {
            required = { "content" },
            properties = { content = { type = "string" } },
            not_ = { required = { "content_ref" } }, -- documentation only; JSON Schema "not" added at runtime if validator supports it
        },
        {
            required = { "content_ref" },
            properties = { content_ref = { type = "string", pattern = "^[a-zA-Z_][a-zA-Z0-9_]*$" } },
        },
    },
}
-- Note: the `not_` key above is descriptive only — mcphub's validator may or
-- may not support the JSON-Schema `not` keyword. The engine re-validates
-- mutual exclusivity in Lua, which is authoritative.

--------------------------------------------------------------------------------
-- Per-op schemas
--------------------------------------------------------------------------------

local replace_range_schema = {
    type = "object",
    properties = {
        kind = { type = "string", const = "replace_range" },
        path = { type = "string", minLength = 1 },
        anchor = anchor_schema,
        content = { type = "string" },
        content_ref = { type = "string", pattern = "^[a-zA-Z_][a-zA-Z0-9_]*$" },
        indent = indent_schema,
        baseline_fingerprint = baseline_fingerprint_schema,
    },
    required = { "kind", "path", "anchor", "indent" },
    additionalProperties = false,
    allOf = { content_xor_schema },
}

local insert_schema = {
    type = "object",
    properties = {
        kind = { type = "string", const = "insert" },
        path = { type = "string", minLength = 1 },
        anchor = anchor_schema,
        content = { type = "string" },
        content_ref = { type = "string", pattern = "^[a-zA-Z_][a-zA-Z0-9_]*$" },
        indent = indent_schema,
        baseline_fingerprint = baseline_fingerprint_schema,
    },
    required = { "kind", "path", "anchor", "indent" },
    additionalProperties = false,
    allOf = { content_xor_schema },
}

local delete_range_schema = {
    type = "object",
    properties = {
        kind = { type = "string", const = "delete_range" },
        path = { type = "string", minLength = 1 },
        anchor = anchor_schema,
        baseline_fingerprint = baseline_fingerprint_schema,
    },
    required = { "kind", "path", "anchor" },
    additionalProperties = false,
}

-- v2: LSP-backed rename.
local rename_symbol_schema = {
    type = "object",
    properties = {
        kind = { type = "string", const = "rename_symbol" },
        path = { type = "string", minLength = 1 },
        position = {
            type = "object",
            properties = {
                line = { type = "integer", minimum = 0 },
                character = { type = "integer", minimum = 0 },
            },
            required = { "line", "character" },
            additionalProperties = false,
        },
        new_name = { type = "string", minLength = 1 },
        baseline_fingerprint = baseline_fingerprint_schema,
    },
    required = { "kind", "path", "position", "new_name" },
    additionalProperties = false,
}

-- v2: LSP code action (typically source.organizeImports, etc).
local lsp_code_action_schema = {
    type = "object",
    properties = {
        kind = { type = "string", const = "lsp_code_action" },
        path = { type = "string", minLength = 1 },
        range = {
            type = "object",
            properties = {
                start_line = { type = "integer", minimum = 1 },
                ["end_line"] = { type = "integer", minimum = 1 },
            },
            required = { "start_line", "end_line" },
            additionalProperties = false,
        },
        kind_filter = { type = "string", minLength = 1 },
        baseline_fingerprint = baseline_fingerprint_schema,
    },
    required = { "kind", "path", "range", "kind_filter" },
    additionalProperties = false,
}

local op_schema = {
    oneOf = {
        replace_range_schema,
        insert_schema,
        delete_range_schema,
        rename_symbol_schema,
        lsp_code_action_schema,
    },
}

--------------------------------------------------------------------------------
-- Top-level request schema
--------------------------------------------------------------------------------

local apply_edit_input_schema = {
    type = "object",
    properties = {
        ops = {
            description = "Array of edit operations, each with a kind (replace_range | insert | delete_range), path, anchor, baseline_fingerprint, and (for replace/insert) content + indent. See the tool description for the full op shape.",
            type = "array",
            minItems = 1,
            items = op_schema,
        },
        contents = {
            description = "Optional sidecar map of { label = string } for bulk multi-line content. An op references an entry via content_ref = label instead of inline content.",
            type = "object",
            -- Keys must match the identifier-shape label pattern. We declare it
            -- on `propertyNames`; values are plain strings.
            propertyNames = { pattern = "^[a-zA-Z_][a-zA-Z0-9_]*$" },
            additionalProperties = { type = "string" },
        },
        dry_run = { description = "Optional. If true, resolve and report without applying any edit.", type = "boolean" },
    },
    required = { "ops" },
    additionalProperties = false,
}

--------------------------------------------------------------------------------
-- Tool description (terse; the protocol is documented through the schema)
--------------------------------------------------------------------------------

local apply_edit_description = [[
Apply a batch of structured edits to existing files. Use this for editing *inside* existing files; for file create / delete / rename use `neovim__write_file`, `neovim__delete_items`, `neovim__move_item`.

Failures are plan-atomic: if any op fails to resolve, no buffer is touched and the response lists every problem with candidates and a hint — no fuzzy guessing, no silent wrong-location edits. Otherwise the user reviews each hunk and accepts or rejects it; per-op outcomes come back in `applied[]` / `rejected[]`.

Each op has a `kind`, a `path`, a `baseline_fingerprint` (from `neovim__read_with_fingerprint`; a mismatch means the file changed under you and the op is refused), and an `anchor`.

ANCHORS locate by `line_range` (1-based inclusive `start`/`end`) or `unique_text` (a verbatim substring, which may span several lines, that must match exactly once unless `occurrence` selects `{nth}` or `all`). A base anchor resolves to a span of whole line(s) `[S..E]`.

The anchor plays one of two roles, depending on the op:

  * For `replace_range` and `delete_range` the anchor IS the edit extent. The op acts on exactly the line(s) `[S..E]` it resolves to and never expands to the surrounding block: anchoring on the first line of a paragraph, function, or list edits only that one line. To act on a whole block the anchor must cover all of its lines (a `line_range` spanning them, or a `unique_text` matching the entire block).
  * For `insert` the anchor must be wrapped in a positional MODIFIER that turns the span into an insertion position; the span's own line(s) are left unchanged and `content` is placed at that position.

MODIFIERS turn a location into an insertion seam. The seam is named directly, never derived by counting:

  * `before` → just above a base anchor's span (before its first line).
  * `after`  → just below a base anchor's span (after its last line).
  * `between` → at the seam between two adjacent texts you name as `before_text` and `after_text`. The two are matched as one contiguous block (`before_text` then `after_text` on consecutive lines), so their CONCATENATION must be unique — neither side need be unique alone — and the seam falls at the join.

`before`/`after` wrap a base anchor in `of` and pin to one of its OUTER edges; the span exists only to be unique. Use them when all the context you need to identify the location sits on one side of the seam: put that context in the span and insert `before` it or `after` it.

`between` is for when the context that makes the location unique STRADDLES the seam — some existing lines before the insertion point and the disambiguating line(s) after it (or vice versa). You show the seam by splitting the existing text into the part before it (`before_text`) and the part after it (`after_text`); the engine inserts exactly at that cut. These are DESCRIPTIVE slices of the file framing the seam, not directions for placing content. This is the only way to keep both-sides context in the match while still inserting in the middle of it. Example: to insert after `bar()` where `foo()`/`bar()` is not unique but `foo()`/`bar()`/`baz()` is, use `before_text: "foo()\nbar()"`, `after_text: "baz()"`.

These ops are line-granular: anchors resolve to whole lines, and edits add, replace, or remove whole lines. A `unique_text` match selects the whole line(s) it falls on, never just the matched substring — so for `replace_range`, `content` must be the complete new line(s), including any unchanged text on the matched line(s).

CONTENT for replace/insert is supplied as exactly one of `content` (inline, for short text) or `content_ref` → `contents[label]` (for multi-line bulk). `delete_range` takes no content.

NEWLINE OWNERSHIP: a newline separates lines; it is never part of a line's own text.
This has three consequences you must respect, because getting them wrong corrupts the file silently or changes where an edit lands.
(1) `content` is the body of the line(s); a leading or trailing `\n` adds a blank line at that edge (leading `\n` -> a blank line BEFORE your text, trailing `\n` -> a blank line AFTER it).
Use this deliberately to separate an inserted block from its surroundings — e.g. append `\n` to a new function or test case so a blank line follows it.
Do NOT add a boundary `\n` you did not intend: it becomes a real blank line in the file.
Interior newlines are fine and expected for multi-line content.
(2) A `unique_text` anchor must NOT start with `\n`: a leading newline belongs to the PREVIOUS line, so it silently pulls that line into the matched range and your edit would clobber one line too many — this is REJECTED.
A TRAILING `\n` in `unique_text`, by contrast, is allowed and useful: it anchors to end-of-line, so `text: "foo\n"` matches the whole line `foo` but not the `foo` inside `foobar`.
(3) For `between`, the engine supplies the seam newline itself (it matches `before_text` + newline + `after_text`), so `before_text` must not end with `\n` and `after_text` must not start with one.

BATCH ORDERING: every op in one call is resolved against the SAME original file (the snapshot your `baseline_fingerprint` pins), then all are applied together with line-shift bookkeeping handled internally. Line numbers always refer to that original file: an earlier op that grows or shrinks the file does NOT move the numbers a later op should use. Submit ops in any order with original line numbers throughout; do NOT pre-sort ops descending or hand-adjust line numbers to compensate for other edits in the batch.
To remove ADJACENT lines, use ONE `delete_range` spanning them rather than several single-line deletes: the review step needs a one-line gap between the regions two ops touch, so back-to-back deletes in one batch are refused with `range_conflict` even though their line ranges do not overlap.

INDENTATION: `replace_range` and `insert` REQUIRE an explicit `indent`, because the engine cannot tell whether you already indented `content` yourself. Choose by how you wrote `content`. `indent: "match_anchor"` prepends the anchor span's leading whitespace (taken from its first line) to each content line, so write `content` at column 0 — its internal relative indentation is preserved while the block is shifted to the anchor's depth, and blank lines stay blank. `indent: "preserve"` inserts `content` byte-for-byte, so write the full leading whitespace yourself; this is also the right choice for a multi-line `replace_range` over a mixed-indent region where a single prefix does not fit every line. Do not combine the two by hand: choosing `match_anchor` AND indenting `content` yourself doubles the indentation, the most common failure here.

EXAMPLES (anchors abbreviated; each op also needs `path` and `baseline_fingerprint`):

  Replace lines 10–12, letting the engine indent (content written at column 0):
    { kind: replace_range,
      anchor: { by: line_range, start: 10, end: 12 },
      content: "...", indent: "match_anchor" }

  Rewrite one whole line located by its text (content is the WHOLE line, already indented — so preserve it verbatim):
    { kind: replace_range,
      anchor: { by: unique_text, text: "  let total = subtotal" },
      content: "  let total = subtotal + tax", indent: "preserve" }

  Insert a guard after a function's opening line, where the signature alone is not unique but signature + first body line is. The disambiguating line sits after the seam, so use `between`: `before_text` is the opening line(s), `after_text` is the line the insert must precede. Content already indented, so preserve:
    { kind: insert,
      anchor: { by: between,
                before_text: "function foo(x)",
                after_text: "    if x > 42 then" },
      content: "    if x == nil then return 'dang' end", indent: "preserve" }

  Insert a line above a uniquely-identified line, written at column 0 for the engine to indent:
    { kind: insert,
      anchor: { by: before, of: { by: unique_text, text: "return result" } },
      content: "result = normalize(result)", indent: "match_anchor" }

  Delete a block by line range (no content, no indent):
    { kind: delete_range, anchor: { by: line_range, start: 40, end: 47 } }

  Two edits in one call, original line numbers, any order:
    [ { kind: replace_range, anchor: { by: line_range, start: 3, end: 3 },
        content: "...", indent: "match_anchor" },
      { kind: insert, anchor: { by: after,
          of: { by: line_range, start: 20, end: 20 } },
        content: "...", indent: "preserve" } ]
]]
--------------------------------------------------------------------------------

---@type MCPTool
local apply_edit_tool = {
    name = "apply_edit",
    description = apply_edit_description,
    inputSchema = apply_edit_input_schema,
    needs_confirmation_window = false, -- runs its own interactive hunk review, avoid double confirmations
    handler = function(req, res)
        if req.caller and req.caller.type == "hubui" then
            req.caller.hubui:cleanup()
        end
        -- The engine is async: `edit.apply` takes the request, a per-file
        -- driver, and a completion callback. The driver is the mcphub-side
        -- `EditUI` backend (the production driver). The completion callback
        -- encodes the response and dispatches it on the mcphub `res` channel.
        local ui_backend = require("mcphub.native.neovim.files.apply_edit.ui_backend")
        -- Per-tool user configuration. Read at call time rather than at module
        -- scope, because `State.config` is empty until mcphub's `setup()` runs.
        local config = (State.config.builtin_tools or {}).apply_edit
        local auto_approve = req.caller and req.caller.auto_approve == true
        -- Both the user config and `auto_approve` reach the engine through the
        -- DRIVER, never through an opts table: `edit.apply` is deliberately
        -- opts-free so that no configuration path (notably
        -- `bypass_fingerprint`) is reachable from the LLM-facing surface. See
        -- the "LLM-facing seal" note in `engine.lua`. A driver is a
        -- continuation, not configuration, so delivering both here keeps that
        -- invariant intact.
        local drive_file = function(request, file_cb)
            if auto_approve then
                -- Honour auto-approve by skipping per-hunk review.
                request.interactive = false
            end
            return ui_backend.drive_file(request, file_cb, config)
        end
        edit.apply(req.params or {}, drive_file, function(response)
            -- Scrub the response to well-formed UTF-8 before encoding.
            -- `vim.json.encode` passes ill-formed bytes (e.g. WTF-8
            -- surrogate encodings echoed from file content) through
            -- unescaped, which a strict downstream JSON parser rejects and
            -- which wedges the whole chat on the next request. `replaced`
            -- counts how many bytes were swapped for U+FFFD.
            local scrubbed, replaced = edit_json.scrub(response)
            if replaced > 0 then
                -- Surface the lossy echo to the LLM as a non-fatal warning
                -- so it knows the content it sees is not byte-faithful.
                scrubbed.warnings = scrubbed.warnings or {}
                table.insert(scrubbed.warnings, {
                    reason = "content_encoding_lossy",
                    message = string.format(
                        "%d byte(s) of ill-formed UTF-8 in the affected file "
                            .. "were shown as U+FFFD (\239\191\189) replacement "
                            .. "characters in this response.",
                        replaced
                    ),
                    hint = "the file contains bytes that are not valid UTF-8 "
                        .. "(e.g. WTF-8/CESU-8 surrogate encodings or corrupted "
                        .. "text); any content echoed back at those positions is "
                        .. "lossy, so do not treat it as byte-faithful.",
                })
            end
            local ok_json, encoded = pcall(vim.json.encode, scrubbed)
            if not ok_json then
                res:error("apply_edit: failed to encode response", { response = response })
                return
            end
            res:text(encoded):send()
        end)
    end,
}

--------------------------------------------------------------------------------
-- neovim__read_with_fingerprint — read a file and emit a baseline fingerprint
--------------------------------------------------------------------------------

local read_input_schema = {
    type = "object",
    properties = {
        path = { description = "Absolute path of the file to read.", type = "string", minLength = 1 },
        -- Optional 1-based-inclusive range projection. The fingerprint is
        -- ALWAYS computed over the whole file; these fields only restrict
        -- the returned `content`. See `read_description` below for the
        -- edge-case policy. Cross-field validation (start_line <= end_line,
        -- start_line <= total_lines) lives in the engine, not here —
        -- JSON Schema can't express it cleanly and the engine's
        -- runtime check is authoritative.
        start_line = {
            description = "Optional. 1-based inclusive first line to return (default 1). Does not affect the whole-file fingerprint.",
            type = "integer",
            minimum = 1,
        },
        ["end_line"] = {
            description = "Optional. 1-based inclusive last line to return (default: last line; clamps past EOF). Does not affect the whole-file fingerprint.",
            type = "integer",
            minimum = 1,
        },
    },
    required = { "path" },
    additionalProperties = false,
}

local read_description = [[
Read a file and receive its content together with an opaque baseline fingerprint. The fingerprint is the LLM's receipt: pass it back verbatim in the `baseline_fingerprint` field of every `apply_edit` op against this file. The planner re-computes the fingerprint at apply time and refuses the batch on mismatch (`stale_fingerprint`), closing the race where the file mutates between read and edit.

This is the **canonical** read path for text files. Prefer it over `execute_command` + `sed`/`head`/`awk`/`cat` even for verification reads after an edit: those bypass the fingerprint binding and the buffer-first semantics, and route through the spill guard. Treat the fingerprint as opaque; do not parse or regenerate it.

Optional range projection: pass `start_line` and/or `end_line` (1-based, inclusive) to restrict the returned `content` to a slice of the file. Defaults: `start_line = 1`, `end_line = total_lines`. `end_line` past EOF clamps silently; `start_line` past EOF refuses with `start_after_eof` (your view of the file is stale). The `baseline_fingerprint` is always whole-file regardless of the range — do not assume a partial read pins only the part you read.

Returns on success: { status: "ok", path, content, baseline_fingerprint, start_line, end_line, returned_lines, total_lines }
On error: { status: "failed", summary, failed: [{ reason, path, message, hint, ... }] }
]]

---@type MCPTool
local read_with_fingerprint_tool = {
    name = "read_with_fingerprint",
    description = read_description,
    inputSchema = read_input_schema,
    handler = function(req, res)
        local params = req.params or {}
        local response =
            edit_read.read_with_fingerprint(params.path, { start_line = params.start_line, end_line = params.end_line })
        -- Scrub to well-formed UTF-8 before encoding. The file `content`
        -- echoed here can contain ill-formed bytes (WTF-8/CESU-8 surrogate
        -- encodings, corrupted text) that `vim.json.encode` would pass
        -- through unescaped, poisoning the chat's next request. `replaced`
        -- counts bytes swapped for U+FFFD.
        local scrubbed, replaced = edit_json.scrub(response)
        if replaced > 0 then
            -- This response shape has no `warnings[]` array; attach a
            -- top-level note so the LLM knows the returned content is lossy
            -- and must not be treated as byte-faithful (e.g. do not build a
            -- `unique_text` anchor from a span that includes a U+FFFD).
            scrubbed.encoding_warning = {
                reason = "content_encoding_lossy",
                message = string.format(
                    "%d byte(s) of ill-formed UTF-8 in this file were shown "
                        .. "as U+FFFD (\239\191\189) replacement characters in the "
                        .. "returned content.",
                    replaced
                ),
                hint = "the file is not valid UTF-8 at those positions; the "
                    .. "returned `content` is lossy there. Do not anchor edits "
                    .. "(unique_text) on a span containing a replacement "
                    .. "character \226\128\148 it will not match the real bytes.",
            }
        end
        local ok_json, encoded = pcall(vim.json.encode, scrubbed)
        if not ok_json then
            return res:error("read_with_fingerprint: failed to encode response", { response = response })
        end
        return res:text(encoded):send()
    end,
}

---@type MCPTool[]
return {
    apply_edit_tool,
    read_with_fingerprint_tool,
}
