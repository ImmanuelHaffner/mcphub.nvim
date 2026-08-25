# `apply_edit` — structured, batch-atomic file edits for LLMs

A replacement for SEARCH/REPLACE-style edit tooling. The LLM submits a batch
of structured operations against existing files. Each operation locates its
target with an **anchor** (line range, unique text, or a positional modifier
that places an insertion seam) and either replaces, inserts, or deletes. Ambiguous or
missing anchors return structured candidates the LLM can act on, not silent
wrong-location edits. Every operation carries a **baseline fingerprint** of
the file's content so concurrent modifications between read and apply are
detected.

This file is the reference for **using** the tool — what to send, what comes
back, how to interpret errors. For design rationale and maintenance notes,
see [`AGENTS.md`](AGENTS.md).

## Contents

- [What this provides](#what-this-provides)
- [Quick start](#quick-start)
- [The protocol](#the-protocol)
  - [Anchors](#anchors)
  - [Operations](#operations)
    - [Batch ordering](#batch-ordering)
  - [Content sources](#content-sources)
  - [Baseline fingerprints](#baseline-fingerprints)
- [The response](#the-response)
- [Errors and recovery](#errors-and-recovery)
- [`neovim__read_with_fingerprint`](#neovim__read_with_fingerprint)
- [Configuration](#configuration)
- [Limitations](#limitations)

## What this provides

Two MCP tools on mcphub's built-in `neovim` native server, registered
from `files/init.lua` alongside the other file tools:

| Tool                              | What it does                                              |
| --------------------------------- | --------------------------------------------------------- |
| `neovim__apply_edit`              | Apply a batch of structured edits across one or more files. |
| `neovim__read_with_fingerprint`   | Read a file and return content + a baseline fingerprint.    |

And one Lua entry point for direct (non-MCP) use:

```lua
require'mcphub.native.neovim.files.apply_edit.engine'.apply(input, drive_file, on_complete)
```

The tool surface in [`init.lua`](init.lua) wraps this with a `drive_file`
that opens mcphub's hunk-review UI (`EditUI`, shared with `edit_file`);
direct Lua callers can pass any conforming driver.

## Quick start

A minimal `apply_edit` call that replaces line 2 of a small file:

```json
{
  "ops": [
    {
      "kind": "replace_range",
      "path": "/tmp/example.txt",
      "baseline_fingerprint": "a1b2c3d",
      "anchor": { "by": "line_range", "start": 2, "end": 2 },
      "content": "the new line 2",
      "indent": "match_anchor"
    }
  ]
}
```

You get the fingerprint by calling `neovim__read_with_fingerprint` first:

```json
{ "path": "/tmp/example.txt" }
```

which returns

```json
{
  "status": "ok",
  "path": "/tmp/example.txt",
  "content": "line 1\nline 2\nline 3\n",
  "baseline_fingerprint": "a1b2c3d",
  "start_line": 1,
  "end_line": 3,
  "returned_lines": 3,
  "total_lines": 3
}
```

On failure (file missing, unreadable, etc.) you get:

```json
{
  "status": "failed",
  "summary": "...",
  "failed": [ { "reason": "io_error", "path": "...", "message": "...", "hint": "..." } ]
}
```

Successful apply returns

```json
{
  "status":   "applied",
  "summary":  "applied 1, rejected 0, failed 0 across 1 file(s)",
  "applied":  [ { "op_index": 1, "kind": "replace_range", "path": "...", "range": { "start_line": 2, "end_line": 2 } } ],
  "rejected": [],
  "failed":   [],
  "files":    [ { "path": "...", "status": "completed", "diagnostics": [], "ui_summary": "..." } ],
  "warnings": []
}
```

**Lua callers** pass a Lua table with the same shape:

```lua
require'mcphub.native.neovim.files.apply_edit.engine'.apply(
  {
    ops = {
      {
        kind = 'replace_range',
        path = '/tmp/example.txt',
        baseline_fingerprint = 'a1b2c3d',
        anchor = { by = 'line_range', start = 2, ['end'] = 2 },
        content = 'the new line 2',
        indent = 'match_anchor',
      },
    },
  },
  require'mcphub.native.neovim.files.apply_edit.ui_backend'.drive_file,
  function(response) vim.print(response) end)
```

The `['end'] = ...` form is required because `end` is a Lua keyword.

## The protocol

### Anchors

An anchor selects **where in the file** an operation acts. There are two
base anchor kinds — `line_range` and `unique_text` — plus three positional
modifiers: `before` and `after` (which wrap a base anchor) and `between`
(which names the two texts framing an insertion seam).

#### `line_range`

Locate by 1-based inclusive line numbers.

```json
{ "by": "line_range", "start": 10, "end": 12 }
```

The line numbers refer to the file content at the time you computed the
baseline fingerprint. Use `line_range` when you have exact line numbers
from a recent read.

Lua: `{ by = 'line_range', start = 10, ['end'] = 12 }`

#### `unique_text`

Locate by searching for a verbatim substring. Must match exactly once by
default; matches are returned as candidates if zero or many are found.

```json
{ "by": "unique_text", "text": "function greet(name)" }
```

Whitespace inside `text` is significant. Newlines inside `text` are
allowed and let you anchor on multi-line patterns.

`text` must **not start with a newline**: a leading `\n` belongs to the
preceding line, so it silently widens the matched range backward by one
line (your edit would clobber one line too many). This is rejected. A
**trailing** newline, by contrast, is allowed and useful — it anchors to
end-of-line, so `"foo\n"` matches the whole line `foo` but not the `foo`
inside `foobar`.

To pin to a specific match when more than one exists:

```json
{ "by": "unique_text", "text": "render", "occurrence": { "nth": 2 } }
```

`nth` is 1-based: `1` is the first match, `2` the second, and so on.
Use this on any op kind when the text genuinely repeats but you want a
specific instance.

To target every match (delete only):

```json
{ "by": "unique_text", "text": "obsolete", "occurrence": "all" }
```

`occurrence: "all"` is valid **only on `delete_range`**. The schema
rejects it on `replace_range` and `insert` (including modifier-wrapped
`insert` where the `unique_text` lives inside `anchor.of`) — broadcasting
one piece of content or one zero-width position across multiple match
sites would force the engine to silently pick one or apply ambiguously.
Use a separate op per match, or pin a specific match with
`occurrence: { nth: N }`.

Lua: `{ by = 'unique_text', text = 'function greet(name)' }`

#### `before`, `after`, `between`

Wrap a base anchor (`before` / `after`) or name two adjacent texts
(`between`) to produce a zero-width insertion position.

```json
{ "by": "before", "of": { "by": "line_range", "start": 5, "end": 5 } }
```

`before` resolves to the position **immediately before** the base
anchor's span (above its first line); `after` resolves to the position
**immediately after** it (below its last line). The wrapped span exists
only to be located uniquely — the seam is always one of its two outer
edges. Use these when all the context you need to pin the location sits
on one side of the insertion point: put that context in the span and
insert `before` it or `after` it.

```json
{ "by": "between",
  "before_text": "function foo(x)",
  "after_text": "    if x > 42 then" }
```

`between` names the two sides of the seam directly. `before_text` is the
existing text immediately **before** the insertion point; `after_text`
is the existing text immediately **after** it. These are descriptive
verbatim slices of the file that frame the seam — not directions for
placing content. The engine matches `before_text` and `after_text` as
one contiguous block (`before_text` then `after_text` on consecutive
lines) and inserts at the join between them.

Use `between` when the context that makes the location unique
**straddles** the seam — some lines above the insertion point and the
disambiguating line(s) below it (or vice versa). Because the seam is
interior to the matched block, `between` is the only modifier that can
keep both-sides context in the match while still inserting in the middle
of it. Their **concatenation** must be unique; neither side need be
unique on its own. Example: to insert after `bar()` where `foo()`/`bar()`
repeats but `foo()`/`bar()`/`baz()` is unique, use
`before_text: "foo()\nbar()"`, `after_text: "baz()"` — the seam lands
after `bar()` while `baz()` stays in the match for uniqueness.

`before`/`after` may only wrap `line_range` or `unique_text` bases.
Modifier-of-modifier (e.g. `before of before of ...`) is rejected by the
schema.

`insert` requires a positional modifier — a bare base anchor on `insert`
is rejected, because an insert into a non-zero-width range would have
ambiguous semantics.

Lua: `{ by = 'before', of = { by = 'line_range', start = 5, ['end'] = 5 } }`
Lua: `{ by = 'between', before_text = 'foo()\nbar()', after_text = 'baz()' }`

### Operations

Three operation kinds. Each carries `path`, `baseline_fingerprint`,
`anchor`, and (for replace/insert) content.

The anchor plays one of two roles. For `replace_range` and `delete_range`
the anchor **is the edit extent**: the op acts on exactly the line(s) the
anchor resolves to and never expands to the surrounding block. Anchoring
on the first line of a paragraph, function, or list edits only that one
line — to act on a whole block the anchor must cover all of its lines (a
`line_range` spanning them, or a `unique_text` matching the entire block).
For `insert` the anchor is a position only (it must be modifier-wrapped);
the span's own line(s) are left unchanged and content is placed adjacent.

#### `replace_range`

Replace the lines covered by the anchor with new content.

```json
{
  "kind": "replace_range",
  "path": "/tmp/foo.lua",
  "baseline_fingerprint": "a1b2c3d",
  "anchor": { "by": "line_range", "start": 5, "end": 7 },
  "content": "-- replacement body\nreturn true",
  "indent": "match_anchor"
}
```

`replace_range` is line-granular: the anchor selects whole line(s), and
all of them are replaced by `content`. A `unique_text` anchor only
*locates* the line(s) — it does not narrow the replacement to the matched
substring. So `content` must be the complete new line(s), including any
unchanged text on the line.

`content` (for both `replace_range` and `insert`) is the body of the
line(s). A leading or trailing newline adds a blank line at that edge:
a leading `\n` puts a blank line **before** your text, a trailing `\n`
puts one **after** it. This is allowed and useful — append `\n` to a
newly inserted function or test case to leave a blank separator line —
so use a boundary newline deliberately and omit it when you do not want
a blank line. Interior newlines are fine for multi-line content.

#### `insert`

Insert new content at a zero-width position. Requires a positional
modifier on the anchor.

```json
{
  "kind": "insert",
  "path": "/tmp/foo.lua",
  "baseline_fingerprint": "a1b2c3d",
  "anchor": { "by": "before", "of": { "by": "line_range", "start": 1, "end": 1 } },
  "content": "--- @module foo",
  "indent": "match_anchor"
}
```

#### `delete_range`

Remove the lines covered by the anchor. Carries no content.

```json
{
  "kind": "delete_range",
  "path": "/tmp/foo.lua",
  "baseline_fingerprint": "a1b2c3d",
  "anchor": { "by": "unique_text", "text": "// TODO: remove this" }
}
```

### Batch ordering

Every op in one call is resolved against the **same original file** — the
snapshot your `baseline_fingerprint` pins — and then all ops are applied
together, with line-shift bookkeeping handled internally. Line numbers
always refer to that original file: an earlier op that grows or shrinks
the file does **not** move the line numbers a later op should use.

So submit ops in any order, using original line numbers throughout. Do
**not** pre-sort ops descending by line, and do **not** hand-adjust line
numbers to compensate for the net line-count change of other edits in the
batch — the engine already does this. (Overlapping edits are a different
matter: two ops whose ranges touch the same lines are refused with
`range_conflict`; see Errors below.)


### Content sources

For `replace_range` and `insert`, the content goes inline as `content`
(short, single-line) or by reference as `content_ref` (longer, multi-line).
The two are mutually exclusive on a single op.

Reference form moves bulk text into a top-level `contents` sidecar so op
bodies stay readable:

```json
{
  "contents": {
    "greet_body": "    print(string.format('hello, %s!', name))\n    return true",
    "docstring":  "--- Say goodbye.\n--- @param name string"
  },
  "ops": [
    {
      "kind": "replace_range",
      "path": "/tmp/foo.lua",
      "baseline_fingerprint": "a1b2c3d",
      "anchor": { "by": "line_range", "start": 3, "end": 4 },
      "content_ref": "greet_body",
      "indent": "preserve"
    },
    {
      "kind": "insert",
      "path": "/tmp/foo.lua",
      "baseline_fingerprint": "a1b2c3d",
      "anchor": { "by": "before", "of": { "by": "line_range", "start": 6, "end": 6 } },
      "content_ref": "docstring",
      "indent": "match_anchor"
    }
  ]
}
```

`contents` keys must match `^[a-zA-Z_][a-zA-Z0-9_]*$`. A declared label
not referenced by any op produces a warning, not an error. A `content_ref`
that doesn't resolve is a hard error.

Every content-producing op (`replace_range`, `insert`) **must** carry an
`indent` mode — it is required, not optional. `delete_range` has no
content and takes no `indent`. The field is mandatory because the engine
cannot tell whether you already indented `content` yourself; forcing an
explicit choice removes the most common failure, where a caller leaves
the mode implicit *and* hand-indents the content, doubling the
indentation.

| `indent`        | Meaning                                                              |
| --------------- | -------------------------------------------------------------------- |
| `match_anchor`  | Prepend the leading whitespace of the anchor line to every non-blank line of `content`. Write `content` starting at column 0; its internal relative indentation is preserved and the whole block is shifted to the anchor's depth. Blank lines stay blank. |
| `preserve`      | Insert `content` verbatim. The caller has already indented correctly. |
| `detect`        | Currently parsed and accepted but downgraded to `match_anchor` with a warning; reserved for a future `.editorconfig`/treesitter-driven mode. |

`match_anchor` applies one prefix — the anchor line's — to every content
line. That is ideal for a single-line replace or an insert, where you
want a column-0 block placed at the anchor's depth. For a multi-line
`replace_range` over a region whose lines are indented differently from
each other, prefer `indent: "preserve"` and supply the exact bytes: one
shared prefix cannot fit lines at different depths. `match_anchor` does
not convert between tabs and spaces — the prefix is applied as raw bytes.

### Baseline fingerprints

Every op carries a `baseline_fingerprint`: a 7-character lowercase-hex
SHA-256 prefix of the file content at the time you decided what to edit.
Format: `^[0-9a-f]{7}$`. Get it from
[`neovim__read_with_fingerprint`](#neovim__read_with_fingerprint).

Before applying any op, the planner re-hashes the live buffer content
the same way and compares. If they differ, the op is failed with
`stale_fingerprint`. The response carries the live fingerprint and the
live content so the LLM can re-plan against the current state without a
second read.

The mechanism closes the inter-batch race: between the LLM's read and
its apply, the file may have been modified (by the user, by formatters,
by another tool). Without baseline fingerprints, an edit anchored at
"line 47" could silently land on the wrong line.

Fingerprints are computed from buffer content (joined with `\n`, plus
a trailing `\n` iff `endofline` is set), not from disk content. Modified
buffers take precedence over their on-disk file at every read and apply.

## The response

The top-level shape:

```
{
  status:   "applied" | "partial" | "failed" | "cancelled",
  summary:  string,                                  // human-readable
  applied:  [ AppliedEntry, ... ],
  rejected: [ RejectedEntry, ... ],
  failed:   [ FailedEntry, ... ],
  files:    [ FileEntry, ... ],
  warnings: [ Warning, ... ],
}
```

The status reflects what actually happened:

| `status`     | Meaning                                                            |
| ------------ | ------------------------------------------------------------------ |
| `"applied"`  | Every op applied successfully.                                     |
| `"partial"`  | Some ops applied, some rejected or failed.                         |
| `"failed"`   | No ops applied; one or more failed.                                |
| `"cancelled"`| User cancelled the review session and no ops landed.               |

### `applied[]`

One entry per op whose changes landed on disk:

```
{ op_index: int, kind: string, path: string, range: { start_line, end_line } }
```

`op_index` is 1-based — matches the position in your input `ops` array
(the JSON wire form uses 0-based; the response is 1-based).

`range` is the **resolved** range from the planner — for `line_range`
anchors it matches what you sent, for `unique_text` it tells you which
line(s) the text was found at.

### `rejected[]`

One entry per op the user rejected during hunk review:

```
{ op_index, kind, path, range, reason: "rejected" | "partially_rejected" | "cancelled" }
```

| `reason`              | Meaning                                                  |
| --------------------- | -------------------------------------------------------- |
| `rejected`            | User explicitly rejected the hunk(s) for this op.        |
| `partially_rejected`  | The op produced multiple hunks; some accepted, some not. |
| `cancelled`           | User closed the review session before deciding.          |

### `failed[]`

One entry per op the engine refused to apply. Carries the failure
reason and the data the LLM needs to recover. See
[Errors and recovery](#errors-and-recovery) for the full taxonomy.

### `files[]`

One entry per file the batch touched:

```
{
  path:          string,
  status:        "completed" | "cancelled" | "no_changes" | "precondition_failed",
  cancel_reason: string?,
  ui_summary:    string?,     // mcphub's human-readable per-file summary
  diagnostics:   [ Diagnostic, ... ],
}
```

`diagnostics` is the structured LSP-diagnostic view for the file at
completion time. Empty array means "collected, nothing to report"; the
field is never absent (always `[]`, not `null`).

Each `Diagnostic`:

```
{
  severity: "error" | "warn" | "info" | "hint",
  line:     int,          // 1-based
  end_line: int,
  col:      int,
  end_col:  int,
  message:  string,
  source:   string?,      // e.g. "lua_ls"
  code:     (string|int)?,
}
```

The default severity threshold is `WARN` — `HINT` and `INFO` are
filtered out. Diagnostics are read after a per-LSP wait (300ms for
lua_ls, 5000ms for metals, etc.) so the language server has time to
publish post-write findings.

### `warnings[]`

Non-fatal issues — unused `contents` labels, `indent: detect`
fallbacks, etc. The batch still applies; warnings are informational.

## Errors and recovery

Every `failed[]` entry carries a `reason` from a stable enum. Each reason
suggests a specific recovery action.

### Schema and validation

Every schema-level failure surfaces with top-level `reason: 'schema_invalid'`
and a `sub_reason` carrying the specific taxonomy below. Schema errors
are detected before any file is touched, so no partial state can leak.

| `sub_reason`                  | Meaning                                                              |
| ----------------------------- | -------------------------------------------------------------------- |
| `missing_field`               | A required field is absent.                                          |
| `wrong_type`                  | A field has the wrong JSON type.                                     |
| `out_of_range`                | A numeric value is outside its allowed range (e.g. `start < 1`).     |
| `bad_pattern`                 | A string field violates its pattern (e.g. malformed fingerprint, non-identifier `content_ref`). |
| `unknown_kind`                | `kind` or `anchor.by` is not a recognised value.                     |
| `mutually_exclusive`          | Both `content` and `content_ref` are set on one op.                  |
| `missing_content`             | Neither `content` nor `content_ref` is set on a `replace_range` / `insert`. |
| `dangling_content_ref`        | A `content_ref` label does not resolve in `contents`.                |
| `content_boundary_newline`    | _(currently disabled)_ `content` started or ended with a newline. A boundary newline now adds a blank line at that edge instead of being rejected. |
| `anchor_leading_newline`      | A `unique_text` anchor starts with a newline (would widen the range backward). A *trailing* newline is allowed. |
| `occurrence_all_disallowed`   | `occurrence: "all"` used on a `replace_range`.                       |
| `bad_modifier_target`         | `insert` op with a bare base anchor (must be modifier-wrapped).      |
| `unsupported_op_kind`         | `kind` is a v2 value (`rename_symbol`, `lsp_code_action`) not yet implemented. |
| `unsupported_anchor_kind`     | `anchor.by` is a v2 value (`treesitter`, `lsp_symbol`) not yet implemented. |

Each entry also carries `message`, `hint`, `expected`, and `got`
fields so the LLM can correct without guessing. Recovery is the same
for every sub-reason: fix the structural error and resubmit.

### Anchor resolution

| `reason`              | Meaning                                                    | Recovery                                                                    |
| --------------------- | ---------------------------------------------------------- | --------------------------------------------------------------------------- |
| `anchor_not_found`    | `unique_text` matched zero times in the file.              | The text doesn't exist as written. Read the file with `neovim__read_with_fingerprint`, re-anchor against the actual content, or use a different anchor kind. |
| `anchor_ambiguous`    | `unique_text` matched more than once (and `occurrence: "all"` was not set). | Tighten the anchor: include surrounding context to make it unique. The entry carries `candidates[]` with up to 3 matches and `total_matches` (integer or `">3"`). |

### File state

| `reason`              | Meaning                                                    | Recovery                                                                    |
| --------------------- | ---------------------------------------------------------- | --------------------------------------------------------------------------- |
| `stale_fingerprint`   | The file changed between your read and your apply.         | The entry carries `live_fingerprint` (the current hash) and `live_content` (the current bytes). Re-plan against `live_content` and resubmit with `baseline_fingerprint = live_fingerprint`. |
| `io_error`            | Could not load the file (path doesn't exist, not readable, etc.). | Verify the path. If you intended to create a new file, use `neovim__write_file` instead — `apply_edit` only modifies existing files. |
| `invalid_range`       | `read_with_fingerprint` was called with `start_line > end_line` (both explicit). | Swap the values, or pick a single-line range with `start_line == end_line`. |
| `start_after_eof`     | `read_with_fingerprint` was called with a `start_line` past the file's actual end. | The file is shorter than you assumed. Re-read without `start_line` first to learn `total_lines`. The entry carries `total_lines` for the recovery. |

### Inter-op conflicts

| `reason`              | Meaning                                                    | Recovery                                                                    |
| --------------------- | ---------------------------------------------------------- | --------------------------------------------------------------------------- |
| `range_conflict`      | Two ops in the same file would touch overlapping ranges, or a delete-to-end-of-file would clobber an adjacent op. | Split the batch into multiple separate calls, or rewrite one op to anchor elsewhere. The entry carries `conflicting_op_indices`. |
| `not_attempted`       | An earlier file in the batch was cancelled; this op was never reached. | Recoverable by retrying the batch (or just the not-attempted ops) once the cancelled file is resolved. |

## `neovim__read_with_fingerprint`

The companion read tool, and **the canonical path** for reading text
files when an LLM may go on to edit them. Returns file content along
with a baseline fingerprint suitable for use in subsequent `apply_edit`
calls. Prefer this tool over `execute_command` + `sed` / `head` / `awk`
/ `cat` even for verification reads after an edit — those bypass the
fingerprint binding and the buffer-first semantics.

### Basic read

```json
{ "path": "/abs/path/to/file" }
```

Returns:

```json
{
  "status": "ok",
  "path": "/abs/path/to/file",
  "content": "line 1\nline 2\n...",
  "baseline_fingerprint": "a1b2c3d",
  "start_line": 1,
  "end_line": 42,
  "returned_lines": 42,
  "total_lines": 42
}
```

### Range projection

Pass optional `start_line` and/or `end_line` (1-based, inclusive) to
restrict the returned `content` to a slice of the file:

```json
{ "path": "/abs/path/to/file", "start_line": 100, "end_line": 150 }
```

The response carries the **echoed** range (clamped to file bounds), the
number of lines actually returned, and the total file size:

```json
{
  "status": "ok",
  "path": "/abs/path/to/file",
  "content": "...lines 100..150...",
  "baseline_fingerprint": "a1b2c3d",
  "start_line": 100,
  "end_line": 150,
  "returned_lines": 51,
  "total_lines": 942
}
```

Defaults: `start_line = 1`, `end_line = total_lines`. Either field may
be omitted independently.

**The fingerprint is always whole-file**, regardless of the range — it
has to be, because `apply_edit` re-hashes the whole buffer at apply
time; a partial-fingerprint would always mismatch. The range parameter
is purely a content-projection knob on the response, not a way to
"pin" a sub-region of the file independently from the rest.

### Edge cases

| Case                                       | Behaviour                                                                        |
| ------------------------------------------ | -------------------------------------------------------------------------------- |
| `end_line > total_lines`                   | Clamped silently to `total_lines`. The "read from line N to end" idiom.          |
| `start_line > total_lines`                 | Refused with `start_after_eof`. Your view of the file's length is stale.         |
| Both `start_line` and `end_line` explicit, with `start_line > end_line` | Refused with `invalid_range`. Malformed pair.       |
| Only `start_line` explicit, exceeds the engine's `total_lines` default for `end_line` | Refused with `start_after_eof` (no LLM-side inversion to flag). |
| Empty file                                 | Treated as one empty line (Neovim convention). `total_lines = 1`, `content = "\n"`. `start_line = 2` refuses with `start_after_eof`. |
| `start_line` or `end_line` < 1             | Refused at schema-validation time with `out_of_range` (no I/O performed).        |
| Either field non-integer                   | Refused with `wrong_type`.                                                       |

### Coexistence policy

These tools recommend — but do not enforce — that you disable
mcphub's generic `neovim__read_file` while `apply_edit` is in use:
toggle it off in the MCPHub UI, which persists it in the `neovim`
server's `disabled_tools` list. Leaving both enabled lets the LLM
read without a fingerprint and then have its `apply_edit` calls
refused for `stale_fingerprint` / missing baseline; disabling forces
it through the fingerprint-emitting read path by construction.

Always read with this tool before editing. The fingerprint is what
makes the edit safe under concurrent modification.

## Configuration

Set under `builtin_tools.apply_edit` in mcphub's `setup()`. The values
below are the defaults:

```lua
require("mcphub").setup({
    builtin_tools = {
        apply_edit = {
            -- Hunk-review UI. `apply_edit` reviews with the same UI as
            -- `edit_file` but reads its own settings, so rebinding one
            -- does not affect the other.
            ui = {
                auto_navigate = true,            -- move to the next hunk after a decision
                go_to_origin_on_complete = true, -- return to the window you started in
                keybindings = {
                    accept = ".",
                    reject = ",",
                    next = "n",
                    prev = "p",
                    accept_all = "ga",
                    reject_all = "gr",
                },
            },
            -- Per-client ceilings (ms) on the post-write wait for LSP
            -- diagnostics. Merged OVER the curated per-client defaults,
            -- so naming one client keeps the ceilings for the others.
            lsp_wait_ms = {}, -- e.g. { metals = 8000 }
            default_lsp_wait_ms = 1000, -- clients with no curated entry
            diagnostic_context_lines = 10, -- report diagnostics within N lines of an edit
        },
    },
})
```

Only those three `ui` fields have any effect here. `apply_edit` reports
diagnostics itself, so `EditUI`'s `send_diagnostics`,
`wait_for_diagnostics` and `diagnostic_severity` are never read on this
path.

## Limitations

### Whole-file delete is unsupported

A `delete_range` that covers every line of a file is refused with
`range_conflict`. The tool exists to modify existing files; deleting
the entire content is closer to "delete the file", which is what
`neovim__delete_items` is for.

### No fuzzy matching

`unique_text` requires an exact substring match. If the LLM's anchor is
*almost* right (one space off, slightly different quote style), we
refuse with `anchor_not_found` rather than guessing. Re-read the file
and re-anchor.

### Indentation is whitespace-only, not semantic

`indent: "match_anchor"` prepends the anchor line's leading whitespace to
each content line; it does not understand syntax. It will not infer that
an insert after an opening `(` should sit one level deeper, nor convert
between tabs and spaces (the prefix is applied as raw bytes). For content
the engine cannot indent correctly this way — a multi-line `replace_range`
over a mixed-indent region, or an insert that must dedent — use
`indent: "preserve"` and supply the exact bytes. A future `detect` mode is
reserved for `.editorconfig`/treesitter-driven re-indentation.

### Per-file refusal, not batch-level atomicity across files

Within a single file, the batch is atomic: all ops apply or none do.
**Across** files in a multi-file batch, atomicity is best-effort: the
applier processes one file at a time, and a cancellation in file B
leaves file A's already-accepted changes in place. The response
honestly reports what landed and what didn't via `applied[]`,
`rejected[]`, and `failed[]`.

### v2 anchor and op kinds are accepted but not implemented

The schema recognises `treesitter` and `lsp_symbol` as valid anchor
`by` values, and `rename_symbol` / `lsp_code_action` as valid op
`kind` values. All four are refused at validation time
(`unsupported_anchor_kind` / `unsupported_op_kind`) and reserved for a
future revision. Use `line_range` or `unique_text` anchors and the
three implemented ops (`replace_range`, `insert`, `delete_range`) for
now.
