package editor

import "conflira/core/ir"

// pathEqual reports whether two 1-based ADF paths are identical.
func pathEqual(a, b Path) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// pathHasPrefix reports whether p starts with prefix.
func pathHasPrefix(p, prefix Path) bool {
	if len(p) < len(prefix) {
		return false
	}
	for i := range prefix {
		if p[i] != prefix[i] {
			return false
		}
	}
	return true
}

// appendIdx returns a fresh path with idx appended (no aliasing).
func appendIdx(p Path, idx int) Path {
	out := make(Path, len(p)+1)
	copy(out, p)
	out[len(p)] = idx
	return out
}

// resolveCursor maps a buffer cursor to the editable text node it sits in and
// the byte offset within that node. Returns ok=false if the cursor isn't on an
// editable text span (e.g. on a virtual/decoration region).
func resolveCursor(eir *EditorIR, cur Cursor) (Path, int, bool) {
	var cand *ir.Span
	for i := range eir.Spans {
		sp := &eir.Spans[i]
		if sp.Line != cur.Line || !sp.Editable || sp.Field != "text" {
			continue
		}
		if cur.Col >= sp.ColStart && cur.Col <= sp.ColEnd {
			// Prefer a span that strictly contains the column (insert-before
			// semantics); fall back to a boundary match (end of line).
			if cand == nil || cur.Col < sp.ColEnd {
				cand = sp
			}
		}
	}
	if cand == nil {
		return nil, 0, false
	}
	return cand.Path, cur.Col - cand.ColStart, true
}

// caretCursor maps an ADF (text-node path, offset) back to a buffer cursor after
// a re-render. Falls back to the first span under a block path (for carets that
// target an empty/just-created block).
func caretCursor(eir *EditorIR, path Path, offset int) Cursor {
	for i := range eir.Spans {
		sp := &eir.Spans[i]
		if sp.Field == "text" && pathEqual(sp.Path, path) {
			return Cursor{Line: sp.Line, Col: sp.ColStart + offset}
		}
	}
	for i := range eir.Spans {
		sp := &eir.Spans[i]
		if sp.Field == "text" && pathHasPrefix(sp.Path, path) {
			return Cursor{Line: sp.Line, Col: sp.ColStart}
		}
	}
	return Cursor{Line: 0, Col: 0}
}
