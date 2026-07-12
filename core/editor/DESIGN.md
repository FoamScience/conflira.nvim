# Projection Editor — Go Core API Design

Status: **design** (no code yet). Target package: `core/editor`.

The goal is to move the rich ADF editor out of Neovim-only Lua
(`lua/atlassian/editor/`, ~3.1k LOC) into the editor-agnostic Go core, so every
thin client (Sublime, VS Code, Neovim-via-core, …) drives the *same* editing
engine and only owns buffer I/O + key routing.

The board/issue-view path is render-only (ADF → IR, one way). This adds the
**reverse path**: buffer edits → ADF mutations → IR re-render → submit to Jira/
Confluence.

---

## 1. Goals / non-goals

**Goals**
- ADF tree is the single source of truth; the buffer holds only clean editable
  text; all structure/decoration is IR marks.
- One deterministic, testable core engine. Clients are thin: render IR, forward
  edits, route structural keys, set the cursor the core returns.
- Full node coverage: paragraph, heading, lists (bullet/ordered/task),
  codeBlock, blockquote, panel, rule, table, mention, media, inline marks.
- Lossless round-trip: open → edit → submit preserves untouched nodes exactly.
- Confluence parity via the existing ADF↔storage bridge.

**Non-goals (v1)**
- Collaborative/multi-cursor editing.
- Operational-transform conflict resolution (use optimistic version check).
- Rendering images inline (clients keep their own preview, as today).

---

## 2. Architecture

```
        thin client (Sublime/VSCode/…)                 core/editor (Go)
   ┌───────────────────────────────────┐        ┌──────────────────────────────┐
   │ buffer (clean text + decorations) │        │ Session                      │
   │  • render EditorIR                │ open   │  doc  *Doc (ADF source)      │
   │  • forward text edits  ───────────┼───────▶│  ir   *EditorIR (cache)      │
   │  • route structural keys (Op) ────┼───────▶│  base *adf.Node (for dirty)  │
   │  • apply returned IR + set cursor │◀───────┤  Apply(op) / ApplyText(Δ)    │
   │  • submit on command              │ ir,cur │   → pure adfedit mutations   │
   └───────────────────────────────────┘        └──────────────────────────────┘
```

**Stateful sessions** (recommended). The core holds the ADF per open editor
between RPC calls, keyed by a session id from `editor.open`. Rationale:
interactive typing should not round-trip a full ADF blob per keystroke, and the
op model is cleanest when the core owns the tree. Underlying mutations are *pure
functions* on `*adf.Node` so they stay unit-testable independent of the session.

A **stateless** variant (client echoes the ADF blob each call) is possible and
simpler to reason about, but pays an ADF (de)serialize per keystroke and needs
the client to store an opaque blob — rejected for the interactive path, kept as
a fallback for one-shot edits.

Session lifecycle: `editor.open` creates, `editor.close` frees. The store is an
LRU with a hard cap (e.g. 32) so a crashed client can't leak unbounded memory.

---

## 3. Data model

Reuses `core/ir` (already has `Span{Line, ColStart, ColEnd, Path []int, Field,
Editable}` — the render-map primitive the board renderer leaves empty) and
`core/adf` (`Node`, `Mark`, `Decode`).

```go
package editor

import (
	"conflira/core/adf"
	"conflira/core/ir"
)

// Path locates a node in the ADF tree by content-array indices.
//   {}      → root doc
//   {2}     → doc.Content[2]
//   {2,1,3} → doc.Content[2].Content[1].Content[3]
type Path = []int

// EditorIR is the projection-editor render output: the standard Projection IR
// plus a fully-populated Spans render-map (block + inline, with editability).
// Clients render Lines+Marks exactly like the board; Spans drives cursor↔node
// mapping and edit gating.
type EditorIR struct {
	*ir.ProjectionIR // Lines, Marks, Spans
}

// Meta identifies what is being edited and how to submit it.
type Meta struct {
	Kind    string `json:"kind"`    // "jira" | "confluence"
	Key     string `json:"key"`     // issue key (jira)
	ID      string `json:"id"`      // page id (confluence)
	Field   string `json:"field"`   // jira field, e.g. "description" | customfield_X
	Version int    `json:"version"` // confluence page version (optimistic concurrency)
	Title   string `json:"title"`   // confluence page title (required on update)
}

// Doc is the editing source of truth.
type Doc struct {
	Root *adf.Node
	Meta Meta
}

// Cursor is a buffer position (byte column, like the IR). Ops resolve it to a
// (Path, offset) via the render-map and return the post-edit Cursor.
type Cursor struct {
	Line int `json:"line"`
	Col  int `json:"col"`
}

// Selection is an inclusive-start, exclusive-end buffer range (for mark ops).
type Selection struct {
	Anchor Cursor `json:"anchor"`
	Head   Cursor `json:"head"`
}
```

### Editability (the critical gate)

Every `Span` carries `Editable`. Text nodes → `Editable:true`. Virtual prefixes
(bullets `● `, `1. `, checkboxes, tree borders, table delimiters `│`, code
borders) are IR *marks* (inline_text / virt_lines) and are **not** in the buffer
text at all, so they can't be typed into. Block attrs (heading level, panel
type) are non-editable spans changed only via `setAttr` ops.

The client uses `Editable:false` spans to **reject** caret edits there (or the
core's `ApplyText` rejects a change that touches a non-editable span and the
client re-renders to snap back).

---

## 4. Pure mutation layer (`adfedit.go`)

Pure functions on the ADF tree — no session, no IR. Each returns the resulting
caret as a `(Path, offset)` so the session can re-render and translate to a
buffer `Cursor`. These are the unit-test surface.

```go
// Resolve / navigate
func NodeAt(root *adf.Node, p Path) *adf.Node
func ParentOf(root *adf.Node, p Path) (*adf.Node, int) // parent, index-in-parent

// Text
func SetText(root *adf.Node, textPath Path, s string) error
func SplitBlock(root *adf.Node, p Path, offset int) (caret Path, err error) // Enter
func MergeBlocks(root *adf.Node, p Path) (caret Path, off int, err error)   // Backspace at BOL

// Lists
func Indent(root *adf.Node, p Path) (Path, error)   // Tab
func Outdent(root *adf.Node, p Path) (Path, error)  // Shift-Tab
func ToggleTask(root *adf.Node, p Path) error       // [ ] ↔ [x]

// Inline marks (bold/em/code/strike/link)
func ToggleMark(root *adf.Node, sel SelPath, mark string, attrs map[string]any) error

// Block lifecycle
func InsertBlock(root *adf.Node, after Path, spec BlockSpec) (Path, error)
func DeleteBlock(root *adf.Node, p Path) (Path, error)
func SetAttr(root *adf.Node, p Path, key string, val any) error // heading level, panel type, lang

// Tables
func TableInsertRow(root *adf.Node, p Path, below bool) (Path, error)
func TableDeleteRow(root *adf.Node, p Path) (Path, error)
func TableInsertCol(root *adf.Node, p Path, right bool) (Path, error)
func TableDeleteCol(root *adf.Node, p Path) (Path, error)

// SelPath is a selection expressed in tree coordinates (resolved from buffer
// Selection via the render-map before mutation).
type SelPath struct {
	Start Path; StartOff int
	End   Path; EndOff   int
}

// BlockSpec describes a block to insert.
type BlockSpec struct {
	Type  string         // "heading"|"paragraph"|"codeBlock"|"panel"|"bulletList"|"orderedList"|"taskList"|"table"|"rule"|"blockquote"
	Attrs map[string]any // level, panelType, language, table rows×cols, …
}
```

---

## 5. Session API (`session.go`)

```go
type Session struct {
	ID   string
	doc  *Doc
	ir   *EditorIR
	base *adf.Node // deep copy at open, for dirty/diff
}

func (s *Session) IR() *EditorIR
func (s *Session) ADF() *adf.Node
func (s *Session) Dirty() bool

// Apply a structural operation; returns refreshed IR + new caret.
func (s *Session) Apply(op Op) (*EditorIR, Cursor, error)

// ApplyText reconciles plain-text buffer edits (the typing fast path).
func (s *Session) ApplyText(changes []TextChange, at Cursor) (*EditorIR, Cursor, error)

// Store is the LRU session registry held by the RPC server.
type Store struct{ /* id → *Session, cap, mutex */ }
func (st *Store) Open(d *Doc) *Session
func (st *Store) Get(id string) (*Session, bool)
func (st *Store) Close(id string)
```

### Op (the structural-edit envelope)

```go
type Op struct {
	Kind   string     `json:"kind"`   // see catalog §7
	Cursor Cursor     `json:"cursor"`
	Sel    *Selection `json:"sel,omitempty"`   // range ops
	Mark   string     `json:"mark,omitempty"`  // toggleMark: strong|em|code|strike|link
	Attrs  map[string]any `json:"attrs,omitempty"` // link href, setAttr value, block spec
	Block  *BlockSpec `json:"block,omitempty"` // insertBlock
	Text   string     `json:"text,omitempty"`  // setText fast path
}
```

### TextChange (client-reported buffer delta)

```go
// A contiguous line range [StartLine,EndLine) replaced by NewLines — the
// editor-agnostic shape of nvim on_lines / Sublime on_modified diffs.
type TextChange struct {
	StartLine int      `json:"start_line"`
	EndLine   int      `json:"end_line"`
	NewLines  []string `json:"new_lines"`
}
```

### Reconciliation (`sync.go`) — how text edits map to ADF

1. **Fast path** — the change is within a single line and lands entirely on one
   editable text span: `SetText(textPath, newLineSlice)`. No structure change;
   only that line's inline marks are recomputed.
2. **Rejected** — the change touches a non-editable span (typed into a bullet /
   border / delimiter): no mutation; return the unchanged IR so the client snaps
   the buffer back.
3. **Structural fallback** — line count changed or the change crosses block
   boundaries: diff `prev.Lines` (the session re-renders the *old* ADF) against
   the post-change buffer, map hunks to `SplitBlock`/`MergeBlocks`/`InsertBlock`/
   `DeleteBlock`, then re-render. If unmappable, full re-render from ADF (text is
   authoritative for the touched text nodes only).

Clients SHOULD route `Enter`/`Backspace`/`Tab` through explicit `Op`s (§7), so
`ApplyText` mostly handles intra-line typing — keeping the fragile structural
diff off the hot path.

---

## 6. JSON-RPC method contracts

All under the `editor.*` namespace, alongside the existing stateless methods.

| Method | Params | Result |
|---|---|---|
| `editor.open` | `{auth, kind, key, field?}` | `{session, ir}` |
| `editor.applyText` | `{session, changes:[TextChange], cursor}` | `{ir, cursor, dirty}` |
| `editor.op` | `{session, op:Op}` | `{ir, cursor, dirty}` |
| `editor.state` | `{session}` | `{dirty, diff_summary}` |
| `editor.submit` | `{session}` | `{ok, version?}` |
| `editor.close` | `{session}` | `{ok}` |

- `editor.open` fetches the issue/page, decodes the target field's ADF (Jira:
  `description` or a custom field; Confluence: storage→ADF via bridge), creates a
  session, returns the first `EditorIR`.
- `editor.submit` serializes `doc.Root` back: Jira `PUT /issue/{key}
  {fields:{<field>: adf}}`; Confluence `PUT /content/{id}` with adf→storage and
  `version+1` (returns the new version; 409 → surface a reload prompt).
- Errors are standard JSON-RPC; a stale Confluence version returns a typed
  `conflict` error the client can act on.

---

## 7. Operation catalog

Each row: trigger (client default) → `Op.Kind` → ADF effect → returned caret.

| Trigger | Op.Kind | Effect | Caret |
|---|---|---|---|
| `Enter` in paragraph | `split` | split text node at offset into two paragraphs | start of new block |
| `Enter` in list item | `split` | new sibling item; empty item → outdent/exit | new item |
| `Backspace` at BOL | `merge` | merge block into previous; first list item → outdent | join point |
| `Tab` in list | `indent` | nest item under previous sibling | same text |
| `Shift-Tab` in list | `outdent` | promote item one level | same text |
| `Enter` on task line | `toggleTask` | TODO ↔ DONE | unchanged |
| visual + `b`/`i`/`` ` `` | `toggleMark` | toggle strong/em/code over selection | selection kept |
| `gl` over link text | `toggleMark`+`Attrs.href` | wrap/unwrap link mark | selection |
| `<lead>sh/sp/sc/st/sl` | `insertBlock` | heading/panel/code/table/list/blockquote | into new block |
| `dd` on a block | `deleteBlock` | remove node (and empty parent list) | prev/next block |
| set heading level / panel type / code lang | `setAttr` | change `attrs.*` | unchanged |
| `Tab`/`S-Tab` in table | *(client-side caret move)* | — | next/prev cell |
| table row/col add/del | `tableInsertRow`/`tableDeleteRow`/`tableInsertCol`/`tableDeleteCol` | grid mutation | nearest cell |
| typing | *(applyText)* | `SetText` on the text node | after inserted text |

---

## 8. Node-type coverage

| ADF type | Buffer text | Editable | Notes |
|---|---|---|---|
| paragraph | the text | yes | split/merge |
| heading | the text | yes (text); level via `setAttr` | sign/level icon is a mark |
| text + marks | raw text | yes | marks → highlight spans; toggleMark |
| bulletList / orderedList | one line/item | yes | bullet/number = inline_text mark |
| taskList | one line/item | yes | checkbox = mark; toggleTask |
| codeBlock | code lines | yes | borders = virt_lines; lang via setAttr |
| blockquote | content | yes | `▎` prefix = inline mark |
| panel | content | yes (text); type via setAttr | icon/colour = sign |
| table | cell text | yes (cells) | borders virt_lines; `│` delimiters are marks, non-editable |
| rule | empty line | no | `────` virt_lines |
| mediaSingle | `[image: name]` | no | preview is client-side |
| mention | `@name` | no (atomic) | delete-as-unit |
| hardBreak | newline-in-paragraph | yes | within a paragraph |

---

## 9. Thin-client responsibilities (what Sublime/VSCode implement)

1. Render `EditorIR` (already done for read-only views; reuse the applier).
2. Buffer modifiable; gate edits on non-editable spans (reject or snap back).
3. Forward intra-line edits as `TextChange[]` (debounced ~30 ms) → `editor.applyText`.
4. Intercept structural keys (Enter/Backspace/Tab/mark toggles/insert/delete) →
   `editor.op`; do **not** let the buffer mutate structurally on its own.
5. On every response: replace buffer text + re-apply decorations + set the
   returned `cursor`. (Set `suppress` flag around programmatic writes so they
   don't echo back as edits.)
6. Draft indicator from `dirty`; submit via command → `editor.submit`.
7. `editor.close` on buffer close.

The Neovim client can keep its native Lua engine *or* migrate onto the core for
parity — both consume the identical `EditorIR`.

---

## 10. Submit & concurrency

- **Jira**: `PUT /issue/{key} {fields:{<Meta.Field>: <adf>}}`. No version field;
  last-write-wins (Jira has no per-field optimistic lock).
- **Confluence**: adf→storage via the existing bridge; `PUT /content/{id}` with
  `{version:{number: Meta.Version+1}, title, body.storage}`. On `409`, return a
  `conflict` error → client reloads.
- `editor.state.diff_summary` gives a human summary (e.g. "3 paragraphs changed,
  1 heading added") for a confirm dialog, computed by diffing `base` vs `Root`.

---

## 11. Phased implementation

1. **Render + map** — `editor.Render(doc) *EditorIR` with populated Spans;
   `editor.open`/`close`; read-only parity with `issue.view`. (Foundation.)
2. **Text editing** — `ApplyText` fast path + `setText`; `editor.applyText`;
   draft/dirty; `editor.submit` (Jira description). Buffer becomes editable.
3. **Structural** — `split`/`merge`/`indent`/`outdent`/`toggleMark`/`toggleTask`
   + `editor.op`. Paragraphs, lists, marks.
4. **Rich blocks** — codeBlock, blockquote, panel, rule, `insertBlock`/
   `deleteBlock`/`setAttr`.
5. **Tables** — render with `│` delimiters + border virt_lines; cell edit; row/
   col ops.
6. **Confluence + polish** — adf↔storage submit, version conflict handling,
   media/mention atoms, paste normalization, large-doc performance.

Each phase is parity-tested against fixtures captured from the frozen Lua editor
(same approach as the board/render parity suite).

---

## 12. Open decisions

- **Stateful vs stateless** — recommended stateful (above); revisit if session
  GC proves fiddly.
- **Where reconciliation lives** — core owns it (clients stay dumb) vs clients
  pre-classify edits. Recommend core-owns for a single source of truth.
- **Cursor identity across re-render** — return `(line,col)`; internally anchor
  on `(Path, offset)`. Sufficient unless we add multi-cursor.
- **Custom-field editing** — `Meta.Field` generalizes description to any
  ADF-valued field (e.g. Acceptance Criteria); confirm submit shape per field.
