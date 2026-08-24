--- mcphub.native.neovim.files.apply_edit.indent — the `match_anchor` reindentation rule.
---
--- ## The rule (KISS, locked)
---
--- `match_anchor` means exactly what it reads: **match the content's
--- indentation to that of the anchor.** Mechanically, that is a single
--- operation:
---
---   > Prepend the anchor's leading whitespace to every non-blank line of
---   > `content`.
---
--- There is deliberately no stripping, no content-base computation
--- (`min` / `max` / first-line), no following-line inference, and no
--- per-side special-casing for zero-width insert positions. The content
--- the LLM emits is treated as **relative to column 0**; the engine's
--- output is **additive** on top of the anchor's indentation:
---
---   * Anchor at 4 spaces, content `"arg1"`        → `"    arg1"`.
---   * Anchor at 4 spaces, content `"  arg1"` (2)  → `"      arg1"` (6).
---
--- The second case is intentional: if the LLM writes leading whitespace,
--- that is *its* relative structure and rides along on top of the anchor
--- prefix. Internal relative indentation across multiple content lines is
--- preserved for the same reason (each line keeps its own whitespace, and
--- the anchor prefix is added uniformly).
---
--- ## Why so simple
---
--- The contract has to be something an LLM can model perfectly in its head
--- from one sentence. Any rule that infers the *semantic* target depth
--- (e.g. "an `after` on an opening paren should indent into the call")
--- requires the LLM to know and trust a hidden heuristic, and every such
--- heuristic has counterexamples (block-end inserts, deliberate dedents
--- like `else` / closing punctuation). Predictability beats cleverness:
--- the LLM can always compute the exact output of "the anchor's indent is
--- prepended to each of my lines."
---
--- The one thing this rule gives up: for `after foo(` where `foo(` is at
--- column 0 but the inserted argument must sit one level deeper, the LLM
--- must supply that indentation itself in `content`. That is fine — the
--- contract is local and unambiguous, so the LLM gets it right by reading
--- one sentence rather than by guessing what the engine will infer.
---
--- ## Blank lines
---
--- A blank content line (empty string `""`) stays truly blank — the
--- prefix is NOT prepended. This avoids emitting lines that are nothing
--- but trailing whitespace (a lint smell most formatters strip anyway).
--- A line that is whitespace-only but non-empty is treated as non-blank
--- and receives the prefix; we only special-case the exact empty string,
--- which is what `vim.split` produces for a genuinely blank line.
---
--- ## Tabs vs spaces
---
--- The prefix is applied as raw bytes. If the anchor's leading whitespace
--- is tabs and the content's own leading whitespace is spaces (or vice
--- versa), the output mixes the two. `match_anchor` does NOT normalise —
--- whitespace-style conversion is reserved for a future `detect` mode.
--- This is a documented limitation, not a bug.
---
--- @module "mcphub.native.neovim.files.apply_edit.indent"

local fr = require("mcphub.native.neovim.files.apply_edit.file_record")

local M = {}

--- Extract the leading whitespace (spaces and tabs) of a string.
---
--- @param line string
--- @return string  The leading `[ \t]*` run; `""` if the line starts with
---                  a non-whitespace byte or is empty.
function M.leading_ws(line)
    return line:match("^[ \t]*") or ""
end

--- Determine the 1-based line number whose indentation a `match_anchor`
--- op should adopt, given the op's resolved range.
---
--- * Non-zero-width range `{S, E}` (E >= S) — a `replace_range`: the
---   range's FIRST line, `S`.
--- * Zero-width position `{S, S-1}` (E < S) — an `insert`: the line at
---   `S` (the line the new content is inserted *above* / pushed down) if
---   it exists, else `S - 1` (the insert-at-EOF case, where `S` is one
---   past the last line so we fall back to the final existing line).
---
--- The zero-width side choice is deliberately fixed for determinism; per
--- the locked design the *correctness* of `match_anchor` does not hinge on
--- which adjacent line is chosen, only on its being predictable and
--- documented.
---
--- @param range   mcphub.edit.ResolvedRange
--- @param n_lines integer  Number of lines in the file (range clamp bound).
--- @return integer line_number  Always in `[1, n_lines]`.
function M.anchor_line(range, n_lines)
    local s, e = range.start_line, range.end_line
    if e >= s then
        -- Non-zero-width range: first line.
        return math.min(math.max(s, 1), n_lines)
    end
    -- Zero-width position {S, S-1}: prefer line S, fall back to S-1 at EOF.
    if s <= n_lines then
        return math.max(s, 1)
    end
    return math.max(s - 1, 1)
end

--- Apply the `match_anchor` rule: prepend `anchor_prefix` to each non-blank
--- line of `content_lines`. Blank lines (`""`) pass through unchanged.
---
--- Pure: no buffer, no record access. Operates on already-split lines so
--- the caller controls the split convention (trailing-newline handling,
--- etc.).
---
--- @param content_lines string[]  Content split on `\n`.
--- @param anchor_prefix string    Leading whitespace to prepend.
--- @return string[]               New table; inputs are not mutated.
function M.apply(content_lines, anchor_prefix)
    if anchor_prefix == "" then
        -- Fast path: nothing to prepend. Return a shallow copy so callers
        -- can treat the result as freshly owned.
        local out = {}
        for i = 1, #content_lines do
            out[i] = content_lines[i]
        end
        return out
    end
    local out = {}
    for i = 1, #content_lines do
        local line = content_lines[i]
        if line == "" then
            out[i] = ""
        else
            out[i] = anchor_prefix .. line
        end
    end
    return out
end

--- Reindent a content string for a `match_anchor` op, deriving the anchor
--- prefix from `record` at the op's resolved `range`.
---
--- Convenience wrapper that ties `anchor_line` + `leading_ws` + `apply`
--- together over a single content string. Splits on `\n` (preserving a
--- trailing empty line so content with a trailing newline round-trips),
--- reindents, and rejoins.
---
--- @param content string             The op's raw content.
--- @param record  mcphub.edit.FileRecord
--- @param range   mcphub.edit.ResolvedRange  The op's resolved range/position.
--- @return string  Reindented content.
function M.reindent(content, record, range)
    local anchor_no = M.anchor_line(range, record.n_lines)
    local anchor_text = fr.line_text(record, anchor_no, anchor_no)
    local prefix = M.leading_ws(anchor_text)
    if prefix == "" then
        return content
    end
    local lines = vim.split(content, "\n", { plain = true, trimempty = false })
    local reindented = M.apply(lines, prefix)
    return table.concat(reindented, "\n")
end

return M
