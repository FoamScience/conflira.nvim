// Package editor is the editor-agnostic projection-editor engine: the ADF tree
// is the source of truth, the buffer holds clean editable text, and all
// structure is IR marks. It adds the reverse path the read-only renderer lacks
// — buffer edits → ADF mutations → IR re-render → submit.
//
// Phase 1 (this file set): read-only render + render-map + open/close sessions.
// See core/editor/DESIGN.md for the full plan.
package editor

import (
	"encoding/json"

	"conflira/core/adf"
	"conflira/core/ir"
	"conflira/core/render"
)

// Path locates a node in the ADF tree by content-array indices ({2,1} =
// doc.Content[2].Content[1]). Matches ir.Span.Path.
type Path = []int

// EditorIR is the projection-editor render output: the standard Projection IR
// (Lines + Marks + a fully-populated Spans render-map). Embeds the IR so it
// marshals to the same {lines, marks, spans} wire shape clients already render.
type EditorIR struct {
	*ir.ProjectionIR
}

// Meta identifies what is being edited and how to submit it.
type Meta struct {
	Kind    string `json:"kind"`              // "jira" | "confluence"
	Key     string `json:"key,omitempty"`     // issue key (jira)
	ID      string `json:"id,omitempty"`      // page id (confluence)
	Field   string `json:"field,omitempty"`   // jira field, e.g. "description"
	Version int    `json:"version,omitempty"` // confluence page version
	Title   string `json:"title,omitempty"`   // confluence page title
}

// Doc is the editing source of truth: an ADF document plus its submit metadata.
type Doc struct {
	Root *adf.Node
	Meta Meta
}

// Cursor is a buffer position (byte column, like the IR).
type Cursor struct {
	Line int `json:"line"`
	Col  int `json:"col"`
}

// Selection is an anchor→head buffer range (for future mark ops).
type Selection struct {
	Anchor Cursor `json:"anchor"`
	Head   Cursor `json:"head"`
}

// Render produces the editor IR (lines + marks + render-map spans) for a doc.
// The renderer (core/render) is path-aware and parity-tested against the frozen
// Lua editor, so this is a thin wrapper today.
func Render(d *Doc) *EditorIR {
	root := d.Root
	if root == nil {
		root = &adf.Node{Type: "doc"}
	}
	return &EditorIR{ProjectionIR: render.BuildEditable(root)}
}

// cloneADF deep-copies an ADF tree (via JSON) — used to snapshot the baseline
// for dirty/diff tracking without aliasing the live tree.
func cloneADF(n *adf.Node) *adf.Node {
	if n == nil {
		return nil
	}
	b, err := json.Marshal(n)
	if err != nil {
		return nil
	}
	var c adf.Node
	if json.Unmarshal(b, &c) != nil {
		return nil
	}
	return &c
}

// adfEqual reports structural equality (canonical JSON). Good enough for the
// dirty flag; not a hot path.
func adfEqual(a, b *adf.Node) bool {
	ja, ea := json.Marshal(a)
	jb, eb := json.Marshal(b)
	if ea != nil || eb != nil {
		return false
	}
	return string(ja) == string(jb)
}
