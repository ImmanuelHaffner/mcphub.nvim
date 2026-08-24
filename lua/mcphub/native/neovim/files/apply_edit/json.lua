--- mcphub.native.neovim.files.apply_edit.json — UTF-8-safe JSON encoding for tool responses.
---
--- The MCP tool handlers (`apply_edit`, `read_with_fingerprint`) encode
--- their response table to a JSON string and hand it back to mcphub →
--- CodeCompanion → the LLM provider. That string travels, verbatim,
--- into the provider's request body on the *next* HTTP submit.
---
--- ## The bug this module exists to prevent
---
--- Neovim's `vim.json.encode` is **lenient about UTF-8**: it copies raw
--- string bytes into the JSON output without validating that they form
--- well-formed UTF-8. In particular, a byte sequence that decodes to a
--- UTF-16 *surrogate* code point (U+D800–U+DFFF), which shows up in the
--- wild as WTF-8 / CESU-8 encoded text (bytes `0xED 0xA0..0xBF
--- 0x80..0xBF`), is passed straight through unescaped.
---
--- Our responses echo file content back to the LLM — anchor candidates,
--- surrounding-context snippets, rejected-hunk previews, error
--- `message`/`hint` fields. If the edited file contains such bytes
--- (common with Java/Windows-origin text, CESU-8 data, or corrupted
--- UTF-8), they end up verbatim inside a JSON string.
---
--- `vim.json.encode` does **not** raise on this — it returns a string
--- and reports success — so a `pcall` guard around it is useless. The
--- failure is *deferred*: the poisoned tool result is stored in the chat
--- history, and only when the provider's strict JSON parser (e.g.
--- Anthropic's `serde_json`) receives the next request does it reject
--- the whole body with:
---
---   The request body is not valid JSON: str is not valid UTF-8:
---   surrogates not allowed
---
--- Once poisoned, *every* subsequent turn in that chat fails until the
--- offending message is removed. The symptom looks like "apply_edit
--- broke the chat" even though apply_edit itself returned fine.
---
--- ## The fix
---
--- Before encoding, recursively scrub every string in the response to
--- well-formed UTF-8, replacing each byte that is not part of a valid
--- UTF-8 sequence with the Unicode replacement character U+FFFD (`�`,
--- bytes `EF BF BD`). Valid UTF-8 — ASCII, accented Latin, CJK, emoji
--- and other astral-plane characters — passes through byte-for-byte
--- untouched; only genuinely malformed bytes (surrogate encodings,
--- overlong forms, stray continuation bytes, truncated sequences) are
--- replaced.
---
--- `M.safe_encode` bundles "scrub then encode" so both handlers get the
--- fix through one tested seam. Keeping this in the pure engine (no
--- mcphub, no MCP) makes it unit-testable in isolation.
---
--- ## Why U+FFFD rather than escaping or erroring
---
---   * Erroring would turn a cosmetic content-echo problem into a hard
---     tool failure — the edit itself may have succeeded, and refusing to
---     report that is worse than a `�` in a context snippet.
---   * Emitting `\uFFFD`-style escapes is what a strict encoder would do,
---     but we don't control `vim.json.encode`'s escaping; scrubbing the
---     input to already-valid UTF-8 is the robust, encoder-agnostic move.
---   * U+FFFD is the standard "this byte was undecodable" sentinel, so
---     the LLM sees a clear, conventional marker rather than silently
---     dropped bytes.
---
--- @module "mcphub.native.neovim.files.apply_edit.json"

local M = {}

--- The UTF-8 encoding of U+FFFD REPLACEMENT CHARACTER (`�`).
local REPLACEMENT = "\239\191\189" -- EF BF BD

--- Scrub a string to well-formed UTF-8.
---
--- Walks the string byte-by-byte, validating each UTF-8 sequence against
--- the Unicode well-formedness rules (RFC 3629 / the Unicode "Table 3-7"
--- byte-sequence constraints). A valid sequence is copied verbatim; any
--- byte that cannot begin or continue a valid sequence is replaced by a
--- single U+FFFD and scanning resumes at the next byte.
---
--- The validation rejects, and therefore replaces:
---   * stray continuation bytes (0x80–0xBF with no lead byte),
---   * lead bytes 0xC0/0xC1 (only produce overlong 2-byte forms),
---   * overlong 3-byte forms (0xE0 with a second byte < 0xA0),
---   * **surrogate encodings** (0xED with a second byte >= 0xA0 → the
---     U+D800–U+DFFF range) — the specific class that trips strict JSON
---     parsers downstream,
---   * overlong / out-of-range 4-byte forms (0xF0 < 0x90; 0xF4 > 0x8F;
---     lead bytes 0xF5–0xFF),
---   * truncated sequences (a valid lead byte with too few following
---     continuation bytes before end-of-string).
---
--- (always valid UTF-8) and is returned unchanged without allocating.
---
--- @param s string  The (possibly ill-formed) input string.
--- @return string   A well-formed UTF-8 string.
--- @return integer  How many bytes were replaced with U+FFFD (0 if the
---   input was already well-formed).
function M.scrub_string(s)
    -- Fast path: pure ASCII (no high bit set anywhere) is valid as-is.
    if not s:find("[\128-\255]") then
        return s, 0
    end

    local out = {}
    local replaced = 0
    local i, n = 1, #s
    local byte = string.byte
    while i <= n do
        local c = byte(s, i)
        if c < 0x80 then
            -- ASCII.
            out[#out + 1] = s:sub(i, i)
            i = i + 1
        elseif c >= 0xC2 and c <= 0xDF then
            -- 2-byte sequence: lead C2..DF, one continuation 80..BF.
            local c1 = byte(s, i + 1)
            if c1 and c1 >= 0x80 and c1 <= 0xBF then
                out[#out + 1] = s:sub(i, i + 1)
                i = i + 2
            else
                out[#out + 1] = REPLACEMENT
                replaced = replaced + 1
                i = i + 1
            end
        elseif c == 0xE0 then
            -- 3-byte, lead E0: second byte A0..BF (reject overlong < A0).
            local c1, c2 = byte(s, i + 1), byte(s, i + 2)
            if c1 and c2 and c1 >= 0xA0 and c1 <= 0xBF and c2 >= 0x80 and c2 <= 0xBF then
                out[#out + 1] = s:sub(i, i + 2)
                i = i + 3
            else
                out[#out + 1] = REPLACEMENT
                replaced = replaced + 1
                i = i + 1
            end
        elseif c >= 0xE1 and c <= 0xEC then
            -- 3-byte, lead E1..EC: two continuations 80..BF.
            local c1, c2 = byte(s, i + 1), byte(s, i + 2)
            if c1 and c2 and c1 >= 0x80 and c1 <= 0xBF and c2 >= 0x80 and c2 <= 0xBF then
                out[#out + 1] = s:sub(i, i + 2)
                i = i + 3
            else
                out[#out + 1] = REPLACEMENT
                replaced = replaced + 1
                i = i + 1
            end
        elseif c == 0xED then
            -- 3-byte, lead ED: second byte 80..9F ONLY. A0..BF would
            -- encode a UTF-16 surrogate (U+D800..U+DFFF) — the exact
            -- class strict JSON parsers reject. Replace it.
            local c1, c2 = byte(s, i + 1), byte(s, i + 2)
            if c1 and c2 and c1 >= 0x80 and c1 <= 0x9F and c2 >= 0x80 and c2 <= 0xBF then
                out[#out + 1] = s:sub(i, i + 2)
                i = i + 3
            else
                out[#out + 1] = REPLACEMENT
                replaced = replaced + 1
                i = i + 1
            end
        elseif c >= 0xEE and c <= 0xEF then
            -- 3-byte, lead EE..EF: two continuations 80..BF.
            local c1, c2 = byte(s, i + 1), byte(s, i + 2)
            if c1 and c2 and c1 >= 0x80 and c1 <= 0xBF and c2 >= 0x80 and c2 <= 0xBF then
                out[#out + 1] = s:sub(i, i + 2)
                i = i + 3
            else
                out[#out + 1] = REPLACEMENT
                replaced = replaced + 1
                i = i + 1
            end
        elseif c == 0xF0 then
            -- 4-byte, lead F0: second byte 90..BF (reject overlong < 90).
            local c1, c2, c3 = byte(s, i + 1), byte(s, i + 2), byte(s, i + 3)
            if
                c1
                and c2
                and c3
                and c1 >= 0x90
                and c1 <= 0xBF
                and c2 >= 0x80
                and c2 <= 0xBF
                and c3 >= 0x80
                and c3 <= 0xBF
            then
                out[#out + 1] = s:sub(i, i + 3)
                i = i + 4
            else
                out[#out + 1] = REPLACEMENT
                replaced = replaced + 1
                i = i + 1
            end
        elseif c >= 0xF1 and c <= 0xF3 then
            -- 4-byte, lead F1..F3: three continuations 80..BF.
            local c1, c2, c3 = byte(s, i + 1), byte(s, i + 2), byte(s, i + 3)
            if
                c1
                and c2
                and c3
                and c1 >= 0x80
                and c1 <= 0xBF
                and c2 >= 0x80
                and c2 <= 0xBF
                and c3 >= 0x80
                and c3 <= 0xBF
            then
                out[#out + 1] = s:sub(i, i + 3)
                i = i + 4
            else
                out[#out + 1] = REPLACEMENT
                replaced = replaced + 1
                i = i + 1
            end
        elseif c == 0xF4 then
            -- 4-byte, lead F4: second byte 80..8F (U+10FFFF is the max
            -- code point; F4 90.. would exceed it).
            local c1, c2, c3 = byte(s, i + 1), byte(s, i + 2), byte(s, i + 3)
            if
                c1
                and c2
                and c3
                and c1 >= 0x80
                and c1 <= 0x8F
                and c2 >= 0x80
                and c2 <= 0xBF
                and c3 >= 0x80
                and c3 <= 0xBF
            then
                out[#out + 1] = s:sub(i, i + 3)
                i = i + 4
            else
                out[#out + 1] = REPLACEMENT
                replaced = replaced + 1
                i = i + 1
            end
        else
            -- Stray continuation byte (80..BF), overlong lead (C0/C1),
            -- or out-of-range lead (F5..FF).
            out[#out + 1] = REPLACEMENT
            replaced = replaced + 1
            i = i + 1
        end
    end
    return table.concat(out), replaced
end

--- Recursively scrub every string in a value to well-formed UTF-8.
---
--- Strings are scrubbed via `M.scrub_string`. Tables are copied — both
--- their keys and values are scrubbed (a table key can be an ill-formed
--- string too). Numbers, booleans, and nil pass through unchanged. Other
--- types (functions, userdata, threads) are not expected in a response
--- table and are returned as-is; `vim.json.encode` would reject them
--- anyway, which is the correct signal.
---
--- The input is never mutated — a fresh table is returned for table
--- inputs — so callers can safely scrub a response they still hold a
--- reference to (e.g. to pass into `res:error` on encode failure).
---
--- Cycle-safe: a `seen` map guards against self-referential tables so a
--- cyclic response can't spin forever (it would fail to JSON-encode
--- regardless, but we must not hang before reaching that error).
---
--- @param value any  The value to scrub.
--- @param seen? table  Internal: map of already-visited tables → copy.
--- @return any  A scrubbed copy (for tables/strings) or the value itself.
--- @return integer  Total number of bytes replaced with U+FFFD across the
---   whole value (0 if nothing was ill-formed).
function M.scrub(value, seen)
    local t = type(value)
    if t == "string" then
        return M.scrub_string(value)
    elseif t == "table" then
        seen = seen or {}
        if seen[value] then
            -- Already-visited table: return the in-progress copy and
            -- count no further replacements (its own were tallied when
            -- first visited).
            return seen[value], 0
        end
        local copy = {}
        seen[value] = copy
        local replaced = 0
        for k, v in pairs(value) do
            local sk = k
            if type(k) == "string" then
                local sk2, kr = M.scrub_string(k)
                sk = sk2
                replaced = replaced + kr
            end
            local sv, vr = M.scrub(v, seen)
            copy[sk] = sv
            replaced = replaced + vr
        end
        return copy, replaced
    else
        return value, 0
    end
end

--- Scrub `value` to well-formed UTF-8, then JSON-encode it.
---
--- Drop-in replacement for `pcall(vim.json.encode, value)` at the MCP
--- handler boundary. Guarantees the returned string is well-formed UTF-8
--- so a strict downstream JSON parser cannot reject it for surrogate /
--- invalid-byte reasons.
---
--- The third return value reports how many bytes had to be replaced with
--- U+FFFD. A non-zero count means the response echoed ill-formed UTF-8
--- from the file (or elsewhere); the caller can surface this to the LLM
--- as a warning ("N undecodable byte(s) in the affected file were shown
--- as \226\143\191 replacement characters") so the model knows the content
--- it sees is lossy, rather than trusting it verbatim.
---
--- Mirrors `pcall`'s return contract for the first two values:
--- `(true, encoded, n)` on success, `(false, err, 0)` on failure.
--- Encoding can still fail for legitimate structural reasons
--- (unsupported value types, cycles) — those errors are surfaced
--- unchanged so the handler's existing error path fires.
---
--- @param value any  The response value to encode.
--- @return boolean ok  True on success.
--- @return string encoded_or_error  The JSON string, or the error message.
--- @return integer replaced  Bytes replaced with U+FFFD (0 on encode failure).
function M.safe_encode(value)
    local scrubbed, replaced = M.scrub(value)
    local ok, encoded_or_error = pcall(vim.json.encode, scrubbed)
    if not ok then
        return false, encoded_or_error, 0
    end
    return true, encoded_or_error, replaced
end

return M
