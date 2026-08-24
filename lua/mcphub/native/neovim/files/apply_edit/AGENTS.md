# `apply_edit` — maintainer's guide

This file is for people changing the code. For *using* the protocol —
input shapes, response shapes, error reasons — see [`README.md`](README.md).

The goal here is to explain **why the code is shaped this way** so a
maintainer can edit it without re-deriving the design from first principles.

## Contents

- [Architecture and module boundaries](#architecture-and-module-boundaries)
- [Indexing conventions](#indexing-conventions)
- [Locked design decisions](#locked-design-decisions)
- [Module-by-module orientation](#module-by-module-orientation)
- [Test layout](#test-layout)
- [Footguns](#footguns)
- [Deferred work](#deferred-work)

## Architecture and module boundaries

One directory, with a strict one-way dependency between two groups of
files:

```
apply_edit/*.lua          ← pure engine: engine, schema, planner,
                            applier, read, file_record, fingerprint,
                            indent, json, anchors/*. No mcphub, no
                            MCP, no UI — they import only from
                            apply_edit/* and from vim.*.

apply_edit/init.lua       ← the MCP tool surface: the two tools' JSON
                            schemas, descriptions and handlers, which
                            files/init.lua registers. Requires nothing
                            from mcphub itself.

apply_edit/ui_backend.lua ← the mcphub bridge. The only file here that
                            reaches outside this directory, and it does
                            so exactly once, for EditUI.
```

The boundary is **grep-enforceable**: every `require` in this directory
resolves inside `apply_edit/*` except one.

```
rg 'require\("mcphub' lua/mcphub/native/neovim/files/apply_edit/ \
  | rg -v 'apply_edit\.'   # MUST match only ui_backend.lua's EditUI
```

Note that `init.lua` requires nothing from mcphub at all — not even
`mcphub.state`, which `edit_file`'s tool surface does use. The engine's
opts-free seal (see *Single LLM-facing entry point*) means there is no
per-tool configuration to read yet; when there is, it arrives as
`State.config.builtin_tools.apply_edit` like every other builtin tool.

Test layout mirrors the split: engine specs must not import mcphub,
bridge specs may. See *Test layout* below.

The reason for keeping the engine mcphub-free: it is the reusable asset.
The tool surface and `ui_backend` are one consumer; there could be others
(a CLI driver, a Telescope picker, a programmatic batch caller). Keeping
the engine free of mcphub imports means swapping the consumer does not
require touching the engine — and it is what let this whole subtree be
relocated here as a pure prefix rename.

## Indexing conventions

These trip up everyone, including future-you. Pin them in mind before
editing anything in `applier.lua`, `anchors/*.lua`, or `ui_backend.lua`.

| Quantity                          | Convention                                           |
| --------------------------------- | ---------------------------------------------------- |
| `op_index` (Lua and wire)         | 1-based **everywhere** in the response: matches the position of the op in the input `ops[]` array, counting from 1. The internal `parsed_ops[op_index]` table-lookup is therefore direct, no translation. |
| JSON-Pointer-style `path` strings inside `schema_invalid` errors | 0-based. `"ops[0].anchor.text"` refers to the first op. Matches RFC 6901. Built in `validate_op` as `string.format('ops[%d]', op_index - 1)`. |
| Line ranges in the engine         | 1-based inclusive everywhere.                        |
| Line ranges at `nvim_buf_set_lines` boundary | 0-based, end-exclusive. `start_0 = start_line - 1; end_excl = end_line`. |
| Zero-width position (insert)      | `{ start_line = N, end_line = N - 1 }`.              |
| Diagnostic positions in `vim.diagnostic.Diagnostic` | 0-based.                          |
| Diagnostic positions in the response | 1-based. Translation in `collect_diagnostics`.    |
| Severity in `vim.diagnostic`      | Integer enum (`ERROR=1, WARN=2, INFO=3, HINT=4`).    |
| Severity in the response          | Lowercase string. `SEVERITY_NAME` table in `ui_backend.lua`. |

The historical motivation for "JSON is 0-based" was the JSON Pointer
spec. We bend that here: `op_index` as a structured field is much more
useful to LLMs as a 1-based position (matches how they count
naturally) than as a 0-based offset. The 0-based form is preserved
only inside the JSON Pointer path strings, which the LLM reads as
location hints rather than indexing into.

The zero-width-position convention (`{N, N-1}`) is deliberate. It encodes
"insert before line N" as a regular range that:
- can pass through the same code as non-degenerate ranges,
- naturally maps to `nvim_buf_set_lines(N-1, N-1, ...)` (start == end == N-1),
- distinguishes from a single-line range `{N, N}` which selects line N for replacement.

## Locked design decisions

These are settled. Reopening any of them needs an explicit reason that
wasn't available at the time. The rationale is recorded here so a
reopening can be honest about what's changing.

### In-tree native tools, not an out-of-tree `add_tool` consumer

These tools first shipped in a separate plugin that bolted them onto
this `neovim` server from the outside via `add_tool("neovim", …)`. That
split was never engine-vs-plugin: the bridge already required
`mcphub.native.neovim.files.edit_file.edit_ui` and `mcphub.state`, and
it had to namespace-squat a `lua/mcphub/` directory of its own for
`require` to resolve at all — mcphub internals living in the wrong repo.

Registering from outside also forced three pokes at those internals
that an in-tree tool does not need, all three now deleted:
`mcphub.add_tool` at config time, `State:emit("tool_list_changed")` to
wake the CodeCompanion bridge, and
`State:notify_subscribers({ server_state = true }, "server")` — needed
only because `add_tool` mutates `capabilities.tools` in place, so
`State:update`'s deep-equal check reported "no change" and the UI never
refreshed. In-tree, registration is one `require` plus a loop in
`files/init.lua`, exactly like every other tool under `files/`.

### LLM-facing namespace `neovim__*`

`neovim__apply_edit` is a sibling of this server's existing
`neovim__edit_file`, and both now live here. Rollout path: ship
`apply_edit`, validate it in real use, then settle `edit_file`'s fate —
keep, deprecate, or remove. Still open.

### Batch-of-ops, not stream-of-ops

A single `apply_edit` call carries a list of operations. Batch atomicity
is implicit within a file; across files it is best-effort (see README's
*Limitations* section). The LLM benefits from grouping related edits in
one call because the response describes the whole set coherently.

### JSON wire format + `contents` labelled-sidecar

Bulk multi-line content moves to top-level `contents: { [label]: string }`
with ops referencing via `content_ref`. Inline `content` is for short
strings. The sidecar keeps op bodies scannable when content is long;
inline is cheaper when it's short.

### No fuzzy anchor matching

`unique_text` requires exact substring match. On zero or many matches,
we return structured candidates and refuse. This is a deliberate choice
over the SEARCH/REPLACE approach of "guess the closest match" — the
guess produces silent wrong-location edits, which is exactly what this
tool exists to eliminate.

### All ops resolve against one pre-edit snapshot; apply compensates for drift

Every op in a batch is resolved by the planner against the **same**
original `FileRecord` content. Anchors are never re-resolved against a
partially-mutated buffer. The applier then hands the whole block list to
`drive_file` at once; it does not apply one block and re-resolve the
next.

The shared `EditUI:_apply_all_changes` (`../edit_file/edit_ui.lua`)
applies blocks **ascending** by
`start_line` while carrying a running `base_line_offset` (`+= #replace
- original_span` after each block), so a later op's pre-edit line numbers
are shifted by the net line delta of everything applied before it. Net
effect: an earlier op that grows or shrinks the file does not drift a
later op. (Note: this is offset *compensation*, not bottom-up apply —
don't "simplify" the engine on the assumption that blocks are applied
last-first.)

This is pinned by `test_e2e.lua`'s line-drift regression
block: two specs assert the on-disk result is byte-identical under the
bottom-up `accept_all` driver and the ascending+offset
`accept_all_ascending` driver (which reproduces `EditUI`'s algorithm).
If that offset bookkeeping or our block construction regresses, the
equivalence specs fail while the bottom-up specs still pass, isolating
the fault to the apply traversal. The user-facing consequence is
documented in the README's *Batch ordering* section: submit ops in any
order with original line numbers; never pre-sort descending or
hand-offset.


### `unique_text` defaults to must-be-unique

Without `occurrence: "all"`, more than one match is `anchor_ambiguous`,
not "use the first one". `occurrence: "all"` is allowed only on
`delete_range`; everything else is rejected at validation time with
`occurrence_all_disallowed`. The check inspects both `anchor.occurrence`
(for `replace_range`) and `anchor.of.occurrence` (for modifier-wrapped
`insert`) so the schema covers both reachable shapes. The semantics of
broadcasting one piece of content or one zero-width position across
multiple match sites are ambiguous, and the resolver would either pick
silently or crash; the schema-level refusal preempts both.


### Newline ownership

One active schema-layer check plus one temporarily-disabled one:

* `content_boundary_newline` — **TEMPORARILY DISABLED (2026-07-15).** The
  check (`check_content_boundary_newline`) is gated behind an early
  `if true then return true end`; the rejection body and the
  `ERROR_REASONS` entry are kept intact so it can be re-enabled by
  removing that early return. Rationale: a boundary `\n` in `content` is a
  legitimate request to add a blank line at that edge (LLMs need to
  visually separate an inserted function or test case). The applier's
  `content_to_lines` splits on `\n` with `trimempty = false`, so `"foo\n"`
  -> `{"foo", ""}` — a deterministic trailing blank line, not corruption.
  We are baking this in prod before deciding whether to delete the check.
* `anchor_leading_newline` — (still active) a `unique_text` anchor may not
  *start* with `\n`. `byte_to_line` maps the leading `\n` (the previous
  line's terminator) onto that previous line, silently widening the
  resolved range backward so a `replace_range`/`delete_range` clobbers one
  line too many. A *trailing* `\n` is deliberately allowed — it is a
  load-bearing end-of-line disambiguator (`"foo\n"` matches the whole
  line `foo` but not the `foo` in `foobar`) and resolves to the correct
  range. Checked in `validate_base_anchor`'s `unique_text` branch.

The asymmetry is why these are two distinct reasons, not one: `content`
rejects both boundaries (it is pure output), `unique_text` rejects only
the leading one (a trailing newline is useful there).

### Baseline fingerprint is mandatory

Every op carries `baseline_fingerprint`. The LLM cannot bypass it.
`engine.apply(input, drive_file, on_complete)` takes no opts table,
so the production path can never thread `bypass_fingerprint = true`.
Tests bypass through wrapper helpers that call `schema.validate` /
`planner.plan` directly with opts; the LLM-facing entry point has no
analogue.

### Fingerprint format: 7-char lowercase-hex prefix of SHA-256

No version prefix. The tool's schema is initialised atomically per
session, so cross-version mixing is structurally impossible. Format
regex: `^[0-9a-f]{7}$`.

### Buffer-first I/O

Reads come from the loaded buffer if one exists, regardless of
modified state. Disk content is a fallback. Writes go through
`:write` (mcphub's `EditUI` does the actual write), which triggers
`BufWritePre` autocmds and any format-on-save hooks. Our code never
touches the filesystem directly.

### EOL normalisation

Hashing and reading both use: `nvim_buf_get_lines` joined with `\n`,
plus a trailing `\n` iff `vim.bo[bufnr].endofline`. Identical recipe
at read time, baseline-validation time, and any future re-hash so
fingerprints compare meaningfully.

### Single LLM-facing entry point, structurally sealed

`engine.apply(input, drive_file, on_complete)` is the only function
the MCP handler calls. The `drive_file` and `on_complete` parameters
are continuations, not configuration — they cannot be expressed in
the JSON schema, so the LLM has no way to inject them or anything
config-like. Internal entry points (`schema.validate`, `planner.plan`,
`applier.apply_plan`) accept opts; the seal is at `M.apply`.

This is also why `auto_approve` is honoured through the *driver* rather
than a config table. `edit_file` can pass
`interactive = req.caller.auto_approve ~= true` straight into its
`EditSession`; we cannot, so `init.lua` wraps `ui_backend.drive_file`
and sets `request.interactive = false` on the way through. Same
behaviour as `edit_file`, seal intact.

### `EditUI` reuse, not reimplementation

`edit_file`'s `EditUI` (`../edit_file/edit_ui.lua`) already provides
hunk-by-hunk review with
`./,/n/p/ga/gr` keybindings. We feed it pre-resolved `LocatedBlock`
shapes and bypass its `DiffParser` / `BlockLocator` (which implement
the SEARCH/REPLACE protocol we replace). This costs ~150 lines of
adapter code (`ui_backend.lua`) and saves rewriting the whole review
UI.

### Sequential per-file driving

`EditUI` installs global keymaps for the duration of a review;
running two instances simultaneously would have them fight. The
applier drives one file at a time. This also makes cross-file
atomicity inherently impossible — surfaced honestly in the response.

### Top-level `description` field was removed

The schema briefly accepted a top-level `description` string. Nothing
ever read it. We removed it. If we later want batch-level intent in
the response, adding it back as a pass-through is one commit. Don't
re-add it speculatively.

## Module-by-module orientation

### The engine

**`engine.lua`** — engine entry. `M.apply(input, drive_file, on_complete)`
is the sealed LLM-facing entry point. Wires schema → planner → applier.
Schema failures fire `on_complete` synchronously; planner and applier
results arrive via `vim.schedule`.

**`schema.lua`** — hand-rolled validator. ~900 lines, no external
validator dependency. Public surface: `M.validate(input, opts)`,
`M.ERROR_REASONS`, `M.WARNING_REASONS`, `M.format_error_summary`. Each
validation produces structured errors with `op_index`, `path` (JSON
Pointer), `reason`, `message`, `hint`, `expected`, `got`.

**`planner.lua`** — turns parsed ops into a `Plan`. Resolves anchors,
validates fingerprints, detects pre-widen range conflicts within a
file. Output is `{ records, located_ops, warnings }`.

**`anchors/init.lua`** — dispatcher. Calls into the appropriate
resolver based on `anchor.by`.

**`anchors/line_range.lua`** — trivial: validates bounds against the
file's line count, returns `{ start_line, end_line }`.

**`anchors/unique_text.lua`** — scan-based. Walks the file content
looking for the verbatim text. Caps at 3 candidates with early exit at
hit #4. Reports `total_matches` as an integer up to 3 or the string
`">3"`.

**`anchors/modifier.lua`** — resolves positional modifiers to zero-width
insertion positions. `before`/`after` wrap a base resolver and pin to its
outer edges; `between` matches `before_text .. "\n" .. after_text` as one
block (reusing the `unique_text` resolver) and places the seam at the join.
Rejects modifier-of-modifier at validation time.

**`file_record.lua`** — canonical "file as we see it" representation.
Buffer-first read; computes content normalisation and the fingerprint
the same way every time.

**`fingerprint.lua`** — SHA-256-based content-derived identifiers.
`M.compute(content) → "abc1234"`. Stateless.

**`read.lua`** — engine behind `neovim__read_with_fingerprint`. Loads
a file into a buffer, normalises content, computes fingerprint.

**`json.lua`** — UTF-8-safe JSON encoding for tool responses.
`M.scrub_string(s) → (clean, n)` scrubs one string to well-formed
UTF-8, replacing each ill-formed byte with U+FFFD and returning the
count. `M.scrub(value) → (copy, n)` does it recursively over a table
(keys and values), cycle-safe, without mutating the input.
`M.safe_encode(value) → (ok, encoded_or_err, n)` is the drop-in for
`pcall(vim.json.encode, …)`. Pure; no mcphub. See the *Footguns*
entry "vim.json.encode passes ill-formed UTF-8 through unescaped" for
why this exists.

**`applier.lua`** — sequences files, drives one at a time via the
caller-supplied `drive_file`, classifies per-block outcomes into
`applied[]` / `rejected[]` / `failed[]`. Knows nothing about mcphub.

### The mcphub-facing files

**`init.lua`** — the tool surface. Returns an `MCPTool[]` array declaring
`neovim__apply_edit` and `neovim__read_with_fingerprint` — JSON schemas,
descriptions and handlers — for `files/init.lua` to register; it never
calls `add_tool` itself. Calls `engine.apply` for apply and
`read.read_with_fingerprint` for read, scrubbing both responses through
`json.safe_encode`.

**`ui_backend.lua`** — the `drive_file` implementation backed by
`edit_file`'s `EditUI`. Contains:
- `widen_for_editui` — adapts zero-width / empty-replace blocks to
  EditUI's shape (which doesn't model them natively) by borrowing one
  neighbouring buffer line.
- `effective_range_after_widen` — pure prediction of the post-widen range.
- `detect_widen_collisions` — refuses batches where widening would
  produce overlaps that the planner couldn't have seen. Surfaces as
  `precondition_failed` with `range_conflict` failures.
- `collect_diagnostics` — translates `vim.diagnostic.Diagnostic` to our
  `Diagnostic` shape.
- `resolve_lsp_wait_ms` — per-LSP timeout table; max across attached
  clients; 0 when no LSP.
- `drive_file` — the orchestrator. Refuses early on collisions,
  otherwise widens, instantiates `EditUI`, snapshots state before
  cleanup, builds the `FileOutcome`.

## Test layout

Specs live under `tests/native/neovim/files/apply_edit/`, mirroring the
source layout, and are named `test_*.lua` because MiniTest's default
collector globs `tests/**/test_*.lua`.

> **Port status.** The specs are not in this repo yet — they are being
> ported from the bespoke runner they were written against onto
> MiniTest. The table below describes the layout they land in.

| File                               | What it covers                                                |
| ---------------------------------- | ------------------------------------------------------------- |
| `helpers.lua`                      | `schema.validate` / `planner.plan` wrappers with `bypass_fingerprint = true`. |
| `drivers.lua`                      | Synthetic `drive_file` implementations: `accept_all` (bottom-up apply), `accept_all_ascending` (`EditUI`-style ascending+offset apply), `reject_all`, `make_selective`, `cancel_at`. |
| `test_e2e.lua`                     | End-to-end through `engine.apply` with `accept_all`.          |
| `test_applier.lua`                 | Applier outcome shapes via synthetic drivers.                 |
| `test_fingerprint_enforcement.lua` | Direct calls to `schema.validate` / `planner.plan` *without* bypass — exercises the strict path. |
| `test_<module>.lua`                | One spec per engine module: `schema`, `planner`, `anchors`, `read`, `json`, `indent`, `file_record`, `fingerprint`. |
| `test_ui_backend.lua`              | Unit tests for the bridge helpers. May import mcphub.          |
| `test_widen_conflict.lua`          | Regression test for the post-widen collision class.           |

Engine specs must not import mcphub; the two bridge specs may. Nothing
enforces that beyond the grep in *Architecture and module boundaries*,
so keep it in mind when adding a spec.

The synthetic drivers test the **applier's reaction** to outcome shapes,
not `EditUI`'s *production* of those outcomes. `EditUI`'s contract
adherence on the reject path is verified by manual real-UI smokes, not
unit tests.

To add a regression test for a bug fix:

1. Write the spec asserting correct (post-fix) behaviour.
2. If the fix isn't in yet, make the case skip itself rather than
   deleting it — `MiniTest.skip('reason')` as its first statement.
3. When the fix lands, drop the skip.

To run the whole suite, or a single file:

```
make test
make test_file FILE=tests/native/neovim/files/apply_edit/test_schema.lua
```

Both go through `scripts/minimal_init.lua`, which puts the repo and
`deps/` on `rtp` and calls `MiniTest.setup()`; `make deps` clones
`mini.nvim` and `plenary.nvim` when missing. Specs that drive a real
`EditUI` need no runtimepath preamble any more — mcphub *is* the repo
under test.

## Footguns

These are real traps that have bitten us. Read before editing.

### Lua `ipairs` stops at the first `nil`

We compute "effective ranges per block" as an array `ranges[i]`, where
some entries are `nil` (e.g. for blocks that widening would refuse).
Iterating `for i, r in ipairs(ranges)` stops at the **first** nil
entry, skipping subsequent ones. Always use a numeric loop
(`for i = 1, #blocks`) when the array might be sparse. This bug was
caught by a regression test before commit.

### `ui.state` is nilled by `ui:cleanup()`

mcphub's `EditUI:cleanup` sets `self.state = nil`. Anything that reads
`ui.state.completed_hunks`, `ui.state.bufnr`, etc. must do so **before**
calling cleanup. Snapshot what you need; then cleanup.

### `EditUI.open_file_in_editor` and the CodeCompanion chat window

`open_file_in_editor` filters target windows by `buftype == ""`. The
CodeCompanion chat buffer has `buftype == "acwrite"`, so it's
structurally excluded from being displaced. Confirmed by reading
mcphub's source. Don't refactor this assumption away without
re-verifying.

### Zero-width range mapping

`{ start_line = N, end_line = N - 1 }` is a position, not a backwards
range. Code that treats it as an invalid range (e.g. asserting `e >= s`)
will crash on insert ops. Validate the position-vs-range distinction
explicitly: `e < s` is "zero-width position at line s"; `e >= s` is
"non-degenerate range".

### `nvim_buf_set_lines` is 0-based, end-exclusive

The single most common indexing bug in this code base would be passing
1-based-inclusive ranges to `nvim_buf_set_lines` directly. Always
translate at the boundary:

```lua
local start_0  = block.range.start_line - 1
local end_excl = block.range.end_line     -- not end_line + 1, because end_line is inclusive 1-based,
                                          -- so the 0-based end-exclusive is just end_line.
```

For zero-width inserts: `start_0 == end_excl == N - 1`.

### `vim.diff` interprets `"\n"` as one empty line, not zero lines

mcphub's `_generate_hunk_blocks` calls `vim.diff(table.concat(lines, "\n") .. "\n", ...)`.
For empty `lines`, this yields `"\n"`, which `vim.diff` reads as a
single empty line. That breaks both pure-delete (vim.diff reports
`new_count=1`) and pure-insert (reports `old_count=1`).

This is why `widen_for_editui` exists: we never hand mcphub a
zero-width or empty-replace `LocatedBlock`. The widening helper is
load-bearing, not an optimisation.

### Post-widen range conflicts

Widening can introduce range conflicts the planner couldn't see in
the pre-widen shapes. `detect_widen_collisions` runs at the bridge
*before* any widening, refusing the batch with `precondition_failed`
when collisions exist. This is correctness-critical: without it, a
delete-to-EOF adjacent to a replace silently loses the replace.

### Diagnostic wait is per-LSP, not flat

`resolve_lsp_wait_ms` picks the max across all attached LSP clients.
A buffer with both `tsserver` (1000 ms) and `metals` (5000 ms) waits
5000 ms. Tuning the table down for a single LSP can leave another
LSP under-served on shared buffers.

### Real LSP-attached LSPs vs none-attached

`resolve_lsp_wait_ms({})` returns 0 (no LSP, no wait). This is what
makes headless test runs fast — no LSPs attach to scratch buffers in
`-u NONE` mode. Don't refactor the empty-clients case away without
preserving this property; otherwise the suite slows by ~1s per
file-edit test.

### `vim.json.encode` passes ill-formed UTF-8 through unescaped

Neovim's `vim.json.encode` does NOT validate UTF-8. It copies raw
string bytes into the output verbatim, so a byte sequence that decodes
to a UTF-16 surrogate (U+D800–U+DFFF) — which appears in the wild as
WTF-8 / CESU-8 (`0xED 0xA0..0xBF 0x80..0xBF`) — lands in the JSON
string unescaped. It does NOT raise on this, so a `pcall` guard around
it catches nothing.

Our responses echo file content back (anchor candidates, context
snippets, rejected-hunk previews, error `message`/`hint`). If the
edited file contains such bytes, they flow into the tool result. The
failure is DEFERRED and brutal: the poisoned string is stored in the
CodeCompanion chat history, and the *next* HTTP submit — not the edit
itself — is rejected by the provider's strict JSON parser with "str is
not valid UTF-8: surrogates not allowed". Every subsequent turn then
fails until the message is removed. It looks like "apply_edit broke the
chat" even though apply_edit returned fine.

The fix lives in this directory's `json.lua`: both handlers in
`init.lua` scrub the response to well-formed UTF-8 (bad bytes →
U+FFFD) before encoding, and surface a
`content_encoding_lossy` warning to the LLM when any byte was replaced
(via `warnings[]` on apply_edit, `encoding_warning` on
read_with_fingerprint). Do NOT go back to a bare
`pcall(vim.json.encode, response)` at either handler — that reopens
this bug. Covered by `test_json.lua`.

## Deferred work

Things intentionally not done. Listed here so a maintainer doesn't
re-derive the design from scratch.

### Indentation: `detect` mode

`indent` is accepted by the schema with three modes: `match_anchor`,
`preserve`, and `detect`. The first two are implemented; `detect`
currently downgrades to `match_anchor`. The field is **required** on
every content-producing op (`replace_range`, `insert`) — there is no
schema default. Real bake-in showed an LLM would leave `indent` implicit
(inheriting the old `match_anchor` default) while *also* hand-indenting
`content`, doubling the indentation. Forcing an explicit choice between
"I wrote `content` at column 0, you indent it" (`match_anchor`) and "I
indented it myself, insert verbatim" (`preserve`) removes that footgun.
`delete_range` carries no content and takes no `indent`.

`match_anchor` is implemented in `indent.lua` (a pure module)
and wired into the planner's anchor-resolution step. The algorithm is
deliberately dead-simple — **prepend the anchor span's leading
whitespace (its first line's) to every non-blank content line; blank
lines stay blank**. It is additive: content is written relative to
column 0 and shifted to the anchor's depth, so internal relative
indentation is preserved. We rejected the earlier `min`-base /
following-line-inference heuristics as unpredictable.

`preserve` inserts content byte-for-byte and is the right choice for a
multi-line `replace_range` over a mixed-indent region, where one prefix
does not fit every line.

Still deferred: `detect` (infer the indent from `.editorconfig`,
treesitter, or a content heuristic). Trigger: real-usage signal that
neither `match_anchor` nor `preserve` fits common cases often enough to
justify the complexity.

### Event-driven diagnostic settle

Current diagnostic wait is a flat per-LSP timeout. A better approach:
listen for `DiagnosticChanged` autocmds with a debounce-on-quiet, exit
early when the server has actually published. Per-LSP table becomes
the upper-bound cap rather than the wait itself.

Trigger: real-usage signal that the latency matters. Until then, the
ceiling is correct and fast LSPs (lua_ls @ 300ms) already pay tolerable
latency.

### v2 anchor kinds

`treesitter`, `lsp_symbol`, `rename_symbol`, `lsp_code_action` are
recognised by the schema as `unsupported_anchor_kind`. The naming and
shape are reserved; implementation is deferred. Trigger: see which
ones LLMs actually want once `line_range` + `unique_text` are in use.

### Whole-file delete via direct apply

`delete_range` covering all lines of a file is currently refused with
`range_conflict`. A direct-apply path (bypass EditUI, do
`nvim_buf_set_lines(0, -1, {})` + `:write`) could support it, but
that's the same shape as "delete the file", which is what
`neovim__delete_items` is for. Defer until someone has a concrete use
case.

### Vim help page

A section in this repo's `doc/mcphub.txt`, plus a page under `doc/mcp/`
on the docs site, referenced from the terse MCP tool `description`,
would let the LLM look up the full protocol on demand without bloating
every tool-listing context. Concern: more surface to maintain, and the
LLM might not use it. Defer until there is signal that pointing at this
directory's `README.md` is insufficient.

### `State.config.builtin_tools.apply_edit`

`LSP_WAIT_MS` is a public field on `ui_backend`, mutated post-require
(`DEFAULT_LSP_WAIT_MS` is file-local). The house pattern for a builtin
tool is a `State.config.builtin_tools.<tool>` table with defaults
declared in `mcphub/config.lua` — how `edit_file` receives its options.
When we accumulate more knobs (LSP wait, diagnostic severity threshold,
EditUI keymaps, …) they fold in there. Premature for one knob, so the
seam is recorded rather than built.

### Coupling to `EditUI`

We depend on `edit_file`'s `EditUI` API surface — specifically
`open_file_in_editor`'s `buftype == ""` filter, `_handle_save`'s
`interactive == false` path, and the `state.completed_hunks` shape.
Being in-tree removes the cross-plugin version skew this section used to
warn about: a change to `edit_file/edit_ui.lua` now lands in the same
diff as the breakage it causes. It does not remove the coupling —
merging upstream changes to that file can still break us silently, and
nothing enforces the contract. The manual smoke test against a real
`EditUI` is the regression canary; the bridge specs cover the adapter
helpers only. If `EditUI` is ever reshaped out from under us, the honest
options are fixing `ui_backend` or growing our own review UI.
