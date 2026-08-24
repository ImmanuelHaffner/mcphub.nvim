--- mcphub.native.neovim.files.apply_edit.anchors.unique_text — resolver for the `unique_text` anchor kind.
---
--- Locates anchor positions by **plain-text substring match** (no Lua
--- patterns, no regex). The default policy is "must be unique": if the
--- text occurs more than once and no `occurrence` was specified, the
--- resolver returns a structured `anchor_ambiguous` failure with up to
--- three candidate locations so the LLM can refine its query or pick by
--- `occurrence.nth`.
---
--- ## Why plain text, not patterns
---
--- The LLM emits anchor text as a verbatim slice of the file. Pattern
--- interpretation would silently treat metacharacters (`.` `*` `(` `[`
--- `%` etc.) as regex syntax — sometimes matching what the LLM intended,
--- sometimes not, with no obvious way to debug. Plain-text matching gives
--- one rule the LLM can rely on: "the bytes you sent must match the bytes
--- in the file."
---
--- ## Candidate cap (locked: 3)
---
--- When the text matches >1 location and no disambiguator was given, we
--- return up to **3** candidate ranges, sorted ascending by `start_line`.
--- The resolver early-exits after finding `cap + 1 = 4` matches — we need
--- exactly one beyond the cap to know "more exist" without paying for a
--- full scan. The failure reports `total_matches` as the integer count
--- when bounded, or the string `">3"` when unbounded.
---
--- Smaller cap means smaller failure-response payloads and less LLM
--- context bloat; the LLM should refine its query rather than scan a list
--- of candidates.
---
--- ## Non-overlapping matches
---
--- Searching `"aa"` in `"aaaa"` finds positions 1 and 3 (two matches),
--- not 1, 2, 3 (three overlapping). Matches the convention of every
--- text-editing tool (`:s///g`, `sed -e`, etc.) and avoids the
--- combinatorial explosion of "find all overlapping copies of a pattern"
--- — which is rarely what an LLM editing code actually wants.
---
--- ## Multi-line matches
---
--- The anchor text may contain `\n`. The byte→line translation handles
--- this transparently: the match's start byte and end byte are each
--- translated independently via `file_record.byte_to_line`, yielding a
--- multi-line `{start_line, end_line}` range.
---
--- @module "mcphub.native.neovim.files.apply_edit.anchors.unique_text"

local fr = require("mcphub.native.neovim.files.apply_edit.file_record")
local schema = require("mcphub.native.neovim.files.apply_edit.schema")

local M = {}

--- The maximum number of candidates surfaced in an ambiguous-match
--- failure. Locked at 3. See module doc for rationale.
M.CANDIDATE_CAP = 3

--- Scan `content` for all (non-overlapping) occurrences of `text`, stopping
--- once `cap + 1` matches have been seen.
---
--- @param content string
--- @param text    string  Must be non-empty.
--- @param cap     integer Stop after collecting `cap + 1` matches.
--- @return {byte_start: integer, byte_end: integer}[] matches  Up to `cap + 1` entries.
local function scan(content, text, cap)
    local matches = {}
    local pos = 1
    local limit = cap + 1
    while pos <= #content do
        local s, e = content:find(text, pos, true)
        if not s then
            break
        end
        matches[#matches + 1] = { byte_start = s, byte_end = e }
        if #matches >= limit then
            break
        end
        -- Non-overlapping: advance past the end of this match.
        pos = e + 1
    end
    return matches
end

--- Translate a byte-offset match into a 1-based inclusive line range.
---
--- @param record mcphub.edit.FileRecord
--- @param match  {byte_start: integer, byte_end: integer}
--- @return mcphub.edit.ResolvedRange
local function match_to_range(record, match)
    return {
        start_line = fr.byte_to_line(record, match.byte_start),
        end_line = fr.byte_to_line(record, match.byte_end),
    }
end

--- Resolve a `unique_text` anchor against a file record.
---
--- Return shapes:
---   * Success, single match (default policy or `occurrence.nth`):
---     `{ start_line = N, end_line = M }, nil`
---   * Success, multi match (`occurrence = "all"`):
---     `{ ranges = { {start_line=...,end_line=...}, ... } }, nil`
---   * Failure: `nil, AnchorFailure`
---
--- The planner is the consumer of both shapes and dispatches based on
--- the presence of `ranges`.
---
--- @param anchor table                Validated parsed anchor.
--- @param record mcphub.edit.FileRecord
--- @return mcphub.edit.ResolvedRange|{ranges: mcphub.edit.ResolvedRange[]}|nil
--- @return mcphub.edit.AnchorFailure|nil
function M.resolve(anchor, record)
    assert(type(anchor) == "table", "resolve: anchor must be a table")
    assert(anchor.by == "unique_text", 'resolve: anchor.by must be "unique_text", got: ' .. tostring(anchor.by))
    assert(type(anchor.text) == "string" and anchor.text ~= "", "resolve: anchor.text must be a non-empty string")
    assert(
        type(record) == "table" and type(record.n_lines) == "number",
        "resolve: record must be a FileRecord (n_lines required)"
    )

    local matches = scan(record.content, anchor.text, M.CANDIDATE_CAP)
    local n_matches = #matches
    local occurrence = anchor.occurrence -- nil | 'all' | { nth = N }

    -- Zero matches: anchor_not_found, regardless of occurrence policy.
    if n_matches == 0 then
        return nil,
            {
                reason = schema.ERROR_REASONS.anchor_not_found,
                anchor = anchor,
                hint = "the text was not found in the file. "
                    .. "Re-read with neovim__read_with_fingerprint, or use a shorter / more characteristic substring.",
                candidates = {},
                total_matches = 0,
            }
    end

    -- Branch on `occurrence` policy.
    if occurrence == nil then
        -- Default: must be unique.
        if n_matches == 1 then
            return match_to_range(record, matches[1]), nil
        end
        -- Ambiguous.
        local candidates = {}
        local capped = math.min(n_matches, M.CANDIDATE_CAP)
        for i = 1, capped do
            candidates[i] = match_to_range(record, matches[i])
        end
        local total = n_matches > M.CANDIDATE_CAP and string.format(">%d", M.CANDIDATE_CAP) or n_matches
        local hint
        if n_matches > M.CANDIDATE_CAP then
            hint = string.format(
                "more than %d occurrences found. Make `text` more specific by including surrounding context, "
                    .. "set `occurrence.nth`, or switch to a `line_range` anchor by inspecting the file at the candidate lines.",
                M.CANDIDATE_CAP
            )
        else
            hint = string.format(
                "%d occurrences found. Either make `text` more specific by including surrounding context, "
                    .. "set `occurrence.nth` (1..%d), or switch to a `line_range` anchor.",
                n_matches,
                n_matches
            )
        end
        return nil,
            {
                reason = schema.ERROR_REASONS.anchor_ambiguous,
                anchor = anchor,
                hint = hint,
                candidates = candidates,
                total_matches = total,
            }
    elseif occurrence == "all" then
        -- Return every match as a list of ranges. Note: scan() stopped at
        -- cap+1 matches, so for very-frequent texts we may be telling the
        -- planner about only the first 4 ranges. The schema restricts
        -- `"all"` to delete_range and the LLM that asks for "delete every
        -- TODO" is unlikely to be surprised that the resolver caps; if
        -- this proves wrong in practice, lift the cap selectively for
        -- "all" (see TODO).
        -- TODO: consider lifting the cap when occurrence == "all" — that
        -- query is explicitly "give me all", so capping is the wrong call
        -- semantically. Defer until we see real usage; the resolver
        -- contract stays the same.
        local ranges = {}
        for i, m in ipairs(matches) do
            ranges[i] = match_to_range(record, m)
        end
        return { ranges = ranges }, nil
    else
        -- occurrence = { nth = N }
        local nth = occurrence.nth
        assert(
            type(nth) == "number" and nth >= 1,
            "resolve: occurrence.nth must be an integer >= 1, got: " .. tostring(nth)
        )

        -- If nth <= cap, we already have it. If nth > cap, we have to keep
        -- scanning. The early-exit-at-cap+1 strategy was tuned for the
        -- "must be unique" path. For nth, we may need a fuller scan.
        if nth <= #matches then
            return match_to_range(record, matches[nth]), nil
        end

        -- We early-exited at cap+1 matches but the LLM asked for nth > cap+1.
        -- Resume scanning from past the last seen match. (In practice the
        -- LLM rarely uses nth > 3; this is the careful path.)
        if nth > M.CANDIDATE_CAP + 1 and #matches == M.CANDIDATE_CAP + 1 then
            -- Continue scanning until we find the Nth match or exhaust.
            local pos = matches[#matches].byte_end + 1
            local found = #matches
            local last_match
            while found < nth and pos <= #record.content do
                local s, e = record.content:find(anchor.text, pos, true)
                if not s then
                    break
                end
                found = found + 1
                last_match = { byte_start = s, byte_end = e }
                pos = e + 1
            end
            if found >= nth then
                return match_to_range(record, last_match), nil
            end
            -- Fall through to not-found with `found` as total.
            return nil,
                {
                    reason = schema.ERROR_REASONS.anchor_not_found,
                    anchor = anchor,
                    hint = string.format(
                        "occurrence.nth = %d but only %d occurrence(s) found. "
                            .. "Re-read with neovim__read_with_fingerprint or pick nth in 1..%d.",
                        nth,
                        found,
                        found
                    ),
                    total_matches = found,
                }
        end

        -- nth > n_matches and we did NOT hit the cap — so `n_matches` is exact.
        return nil,
            {
                reason = schema.ERROR_REASONS.anchor_not_found,
                anchor = anchor,
                hint = string.format(
                    "occurrence.nth = %d but only %d occurrence(s) found. "
                        .. "Re-read with neovim__read_with_fingerprint or pick nth in 1..%d.",
                    nth,
                    n_matches,
                    n_matches
                ),
                total_matches = n_matches,
            }
    end
end

return M
