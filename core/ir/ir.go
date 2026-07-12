// Package ir defines the Projection IR — the editor-agnostic contract emitted by
// the renderer. The Lua plugin produces this JSON today (atlassian.editor.ir);
// this Go package decodes/validates/re-encodes the exact same shape, and is the
// foundation for a future Go core that produces it.
//
// The wire shape (see atlassian/editor/ir.lua):
//
//	{
//	  "lines": ["..."],
//	  "marks": [ { "line", "col", "kind", ...kind-specific } ],
//	  "spans": [ { "line", "col_start", "col_end", "path", "field", "editable" } ]
//	}
//
// Styles are semantic tokens ("heading.2", "strong", "diff.add"), never Neovim
// highlight groups — see atlassian/editor/theme.lua.
package ir

import (
	"encoding/json"
	"fmt"
)

// Chunk is a [text, styleToken] tuple, serialized as a JSON array. The style
// element may be absent (length 1) when the producer attached no style.
type Chunk = []string

// Mark is a neutral decoration descriptor. Kind selects which fields apply:
//
//	highlight    : Hl, EndCol
//	inline_text  : Chunks, Pos
//	eol_text     : Chunks, Align
//	sign         : Text, Hl
//	virt_lines   : Lines, Above
type Mark struct {
	Line int    `json:"line"`
	Col  int    `json:"col"`
	Kind string `json:"kind"`

	Hl     string  `json:"hl,omitempty"`
	Text   string  `json:"text,omitempty"`
	EndCol *int    `json:"end_col,omitempty"`
	Align  string  `json:"align,omitempty"`
	Pos    string  `json:"pos,omitempty"`
	Chunks []Chunk `json:"chunks,omitempty"`
	Lines  []Line  `json:"lines,omitempty"`
	Above  *bool   `json:"above,omitempty"`
}

// Line is one virtual line: a sequence of styled chunks.
type Line = []Chunk

// Span maps a buffer text range back to its ADF node path (for edit sync).
type Span struct {
	Line     int    `json:"line"`
	ColStart int    `json:"col_start"`
	ColEnd   int    `json:"col_end"`
	Path     []int  `json:"path"`
	Field    string `json:"field"`
	Editable bool   `json:"editable"`
}

// ProjectionIR is the wire-serializable build output.
type ProjectionIR struct {
	Lines []string `json:"lines"`
	Marks []Mark   `json:"marks"`
	Spans []Span   `json:"spans"`
}

// Decode parses wire JSON into a ProjectionIR.
func Decode(data []byte) (*ProjectionIR, error) {
	var p ProjectionIR
	if err := json.Unmarshal(data, &p); err != nil {
		return nil, fmt.Errorf("decode IR: %w", err)
	}
	return &p, nil
}

// Encode serializes a ProjectionIR to wire JSON.
func Encode(p *ProjectionIR) ([]byte, error) {
	return json.Marshal(p)
}

// validKinds is the closed set of neutral decoration kinds.
var validKinds = map[string]bool{
	"highlight":   true,
	"inline_text": true,
	"eol_text":    true,
	"virt_lines":  true,
	"sign":        true,
	"unknown":     true,
}

// Validate checks structural invariants of the IR and returns all problems found.
func (p *ProjectionIR) Validate() []error {
	var errs []error
	if p.Lines == nil {
		errs = append(errs, fmt.Errorf("lines is null"))
	}
	for i, m := range p.Marks {
		if !validKinds[m.Kind] {
			errs = append(errs, fmt.Errorf("mark[%d]: unknown kind %q", i, m.Kind))
		}
		if m.Line < 0 || m.Col < 0 {
			errs = append(errs, fmt.Errorf("mark[%d]: negative line/col (%d,%d)", i, m.Line, m.Col))
		}
		if m.Line >= len(p.Lines) {
			errs = append(errs, fmt.Errorf("mark[%d]: line %d out of range (%d lines)", i, m.Line, len(p.Lines)))
		}
	}
	return errs
}

// MarksByKind counts marks grouped by their decoration kind.
func (p *ProjectionIR) MarksByKind() map[string]int {
	out := make(map[string]int)
	for _, m := range p.Marks {
		out[m.Kind]++
	}
	return out
}

// StyleTokens returns the set of distinct style tokens referenced anywhere in
// the IR (highlight/sign hl, plus chunk and virtual-line styles).
func (p *ProjectionIR) StyleTokens() map[string]bool {
	out := make(map[string]bool)
	add := func(s string) {
		if s != "" {
			out[s] = true
		}
	}
	addChunks := func(cs []Chunk) {
		for _, c := range cs {
			if len(c) >= 2 {
				add(c[1])
			}
		}
	}
	for _, m := range p.Marks {
		add(m.Hl)
		addChunks(m.Chunks)
		for _, ln := range m.Lines {
			addChunks(ln)
		}
	}
	return out
}
