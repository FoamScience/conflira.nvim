# conflira/core

The editor-agnostic core for conflira, in Go. This is the Phase 2 foundation of
the cross-editor plan: a headless module that speaks the same **Projection IR**
the Neovim plugin already produces, so the rendering/logic can eventually live
here and drive Neovim, VSCode, Sublime, … through thin per-editor appliers.

The Lua plugin is the reference implementation and is **not modified** by this
module. This package currently consumes and validates the IR; a later step ports
the ADF→IR build itself to Go.

## The contract

`atlassian/editor/ir.lua` (Lua) emits this JSON; `ir` (Go) decodes the identical
shape:

```json
{
  "lines": ["Title", "", "hello bold and code"],
  "marks": [
    {"line":0,"col":0,"kind":"highlight","hl":"heading.2","end_col":5},
    {"line":0,"col":0,"kind":"sign","hl":"heading.2","text":"󰲣 "},
    {"line":2,"col":6,"kind":"highlight","hl":"strong","end_col":10}
  ],
  "spans": [{"line":0,"col_start":0,"col_end":5,"path":[1,1],"field":"text","editable":true}]
}
```

- **Decoration kinds**: `highlight`, `inline_text`, `eol_text`, `virt_lines`, `sign`, `unknown`.
- **Styles are semantic tokens** (`heading.2`, `strong`, `diff.add`), never Neovim
  highlight groups. Each editor's applier maps tokens to its own theme
  (`atlassian/editor/theme.lua` is the Neovim resolver).

See `lua/atlassian/editor/ir.lua` and `theme.lua` for the producer side.

## Layout

```
core/
  adf/             ADF model + ToText/ExtractSection (port of atlassian/adf.lua)
  ir/              IR types, decode/encode, validation, summaries
  render/          ADF → Projection IR (port of editor/render.lua)
  board/           issues → tree → grouped → IR (port of board/state.lua + render.lua)
                   + ParseIssue (raw Jira JSON → Issue, port of types.lua)
  jql/             JQL builders (port of jira-interface/filters.lua)
  fields/          custom-field resolution + involvement-section sensing
  queue/           offline edit queue (Lua-format-compatible queue.json)
  cache/           file-backed TTL cache (Lua-format-compatible cache.json)
  api/             auth, URL, vim-compatible URI encoder, endpoints, Client+Transport
  rpc/             JSON-RPC 2.0 server + method handlers (the editor-facing surface)
  cmd/conflira-core/ stdio JSON-RPC server (render, board.fetch, jql, fields, adf)
  cmd/render/      CLI: ADF (or -board) on stdin → IR JSON  (the headless producer)
  cmd/parity/      CLI: validate an IR JSON document, print a structural summary
  testdata/        wire JSON captured from the Lua producer (parity oracle)
    cases/         editor ADF→IR fixtures      (+ gen.lua)
    cases_board/   board issues→IR fixtures     (+ gen_board.lua)
    logic/         JQL / ADF-text / request / parse fixtures (+ gen_logic.lua)
```

## Usage

Run the tests — parity asserts the Go renderers reproduce the frozen Lua IR for
every fixture (19 editor + 6 board cases), plus IR round-trip and shape:

```sh
cd core && go test ./...
```

Produce IR with the Go core (the headless producer):

```sh
go run ./cmd/render        < testdata/cases/marks.adf.json
go run ./cmd/render -board < testdata/cases_board/simple.board.json
```

Validate any IR document — a fixture, the Go core, or the Lua build piped live:

```sh
go run ./cmd/render < testdata/cases/code.adf.json | go run ./cmd/parity
```

## Refreshing the fixtures

The `testdata/*.json` files are golden IR captured from the (frozen) Lua build.
Regenerate them by piping `atlassian.editor.ir.encode(build_ir(...))` to the
file — keep the fixtures in sync if the Lua IR shape ever changes.

## Roadmap (Phase 2)

1. **Done** — IR types + validation + parity harness.
2. **Done** — ADF model + editor renderer port (`adf`, `render`): all 19 editor
   fixtures byte-identical to the Lua IR.
3. **Done** — board pipeline port (`board`: tree build, urgency, grouping,
   readiness, stats, renderer): all 6 board fixtures byte-identical.
4. **Done** — `cmd/render` producer: `ADF|board → IR JSON`, the headless core.
5. **Done** — non-rendering pure logic: JQL builders (`jql`), ADF→text (`adf`),
   request building + vim-compatible URI encoder (`api`), issue parsing
   (`board.ParseIssue`), and custom-field resolution (`fields`). All parity-verified
   against `testdata/logic`.
6. **Done** — offline queue (`queue`): file-backed, on-disk format identical to
   the Lua plugin's `queue.json` (verified), so the Go core and Neovim share it.
7. **Partial** — REST client (`api.Client` + `Transport`): request construction,
   endpoints, and error parsing are ported; live HTTP runs via `CurlTransport`
   (not parity-testable — behind the `Transport` interface for fakes).
8. **Done** — JSON-RPC server (`rpc` + `cmd/conflira-core`): newline-delimited
   JSON-RPC 2.0 over stdio exposing `render.adf`, `render.board`, `adf.toText`,
   `issue.parse`, `jql.main`, `jql.section`, `fields.resolve`,
   `fields.senseSections`, and `board.fetch` (full server-side board pipeline:
   search → parse → bubble parents → tree → sections → IR). Verified end-to-end
   against live Jira.
9. **Done** — file-backed TTL cache (`cache`): memory+disk layers, `get_or_fetch`,
   scope invalidation; on-disk format identical to the Lua `cache.json`.
10. Next — thin per-editor clients (Neovim/VSCode/Sublime) that spawn
    `conflira-core` and render the IR it returns. The Go core is feature-complete.

## JSON-RPC server

```sh
go build -o conflira-core ./cmd/conflira-core
echo '{"jsonrpc":"2.0","id":1,"method":"jql.main"}' | ./conflira-core
```

`board.fetch` runs the whole board server-side and returns the Projection IR:

```json
{"jsonrpc":"2.0","id":1,"method":"board.fetch","params":{
  "auth":{"url":"…","email":"…","token":"…"},
  "project":"","group":"none","done_filter":"leaves",
  "main_jql":"assignee = currentUser() …",
  "sections":[{"name":"Reviewing","jql":"(…) AND assignee != currentUser() …"}]}}
```

A per-editor client builds the queries (via `jql.main`, `fields.senseSections`,
`jql.section`), calls `board.fetch`, and renders the returned IR with its own
decoration API — the Neovim `apply_ir` equivalent.

### Parity scope & notes

- Byte-for-byte parity is verified by `go test ./...` (struct equality) and by
  diffing `cmd/render` output against the captured `*.ir.json` fixtures.
- Board fixtures keep leaf **status counts distinct**: the Lua status-breakdown
  sort is unstable for equal counts (hash-ordered), which isn't reproducible
  cross-language. Distinct counts exercise the deterministic behaviour.
- `displayWidth` (table/board alignment) approximates Neovim `strdisplaywidth`;
  CJK/wide ranges are handled, but exotic widths may differ. Fixtures use text
  where it matches exactly.
- Date-dependent urgency (overdue/due_soon/stale) is ported but fixtures avoid
  due dates / stale timestamps so results are deterministic.
