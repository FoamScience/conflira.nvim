package editor

import "fmt"

// Op is a structural edit the client routes from a key/command. The core
// resolves Cursor/Sel against the render-map, mutates the ADF, re-renders, and
// returns the new caret.
type Op struct {
	Kind   string     `json:"kind"` // split|merge|toggleTask|toggleMark|setAttr|insertBlock|deleteBlock
	Cursor Cursor     `json:"cursor"`
	Sel    *Selection `json:"sel,omitempty"`   // range ops (toggleMark)
	Mark   string     `json:"mark,omitempty"`  // toggleMark: strong|em|code|strike|link
	Attr   string     `json:"attr,omitempty"`  // setAttr: level|panelType|language
	Value  any        `json:"value,omitempty"` // setAttr value
	Block  *BlockSpec `json:"block,omitempty"` // insertBlock spec
	After  bool       `json:"after,omitempty"` // table row/col ops: below / to the right
}

// Apply runs a structural op and returns the refreshed IR + new caret.
func (s *Session) Apply(op Op) (*EditorIR, Cursor, error) {
	switch op.Kind {
	case "split":
		path, off, ok := resolveCursor(s.ir, op.Cursor)
		if !ok {
			return s.ir, op.Cursor, fmt.Errorf("split: cursor not on editable text")
		}
		cp, co := Split(s.doc.Root, path, off)
		s.rerender()
		return s.ir, caretCursor(s.ir, cp, co), nil

	case "merge":
		path, _, ok := resolveCursor(s.ir, op.Cursor)
		if !ok {
			return s.ir, op.Cursor, fmt.Errorf("merge: cursor not on editable text")
		}
		cp, co := Merge(s.doc.Root, path)
		s.rerender()
		return s.ir, caretCursor(s.ir, cp, co), nil

	case "toggleTask":
		path, _, ok := resolveCursor(s.ir, op.Cursor)
		if !ok {
			return s.ir, op.Cursor, fmt.Errorf("toggleTask: cursor not on editable text")
		}
		ToggleTask(s.doc.Root, path)
		s.rerender()
		return s.ir, op.Cursor, nil

	case "toggleMark":
		if op.Sel == nil {
			return s.ir, op.Cursor, fmt.Errorf("toggleMark: selection required")
		}
		sp, so, ok1 := resolveCursor(s.ir, op.Sel.Anchor)
		ep, eo, ok2 := resolveCursor(s.ir, op.Sel.Head)
		if !ok1 || !ok2 {
			return s.ir, op.Cursor, fmt.Errorf("toggleMark: selection not on editable text")
		}
		ToggleMark(s.doc.Root, sp, so, ep, eo, op.Mark)
		s.rerender()
		return s.ir, op.Cursor, nil

	case "setAttr":
		path, off, ok := resolveCursor(s.ir, op.Cursor)
		if !ok {
			return s.ir, op.Cursor, fmt.Errorf("setAttr: cursor not on editable text")
		}
		SetAttr(s.doc.Root, path, op.Attr, op.Value)
		s.rerender()
		return s.ir, caretCursor(s.ir, path, off), nil

	case "insertBlock":
		if op.Block == nil {
			return s.ir, op.Cursor, fmt.Errorf("insertBlock: block spec required")
		}
		path, _, ok := resolveCursor(s.ir, op.Cursor)
		if !ok {
			// allow inserting into an empty/blank doc with no resolvable cursor
			path = nil
		}
		cp, co := InsertBlock(s.doc.Root, path, *op.Block)
		s.rerender()
		return s.ir, caretCursor(s.ir, cp, co), nil

	case "deleteBlock":
		path, _, ok := resolveCursor(s.ir, op.Cursor)
		if !ok {
			return s.ir, op.Cursor, fmt.Errorf("deleteBlock: cursor not on editable text")
		}
		cp, co := DeleteBlock(s.doc.Root, path)
		s.rerender()
		return s.ir, caretCursor(s.ir, cp, co), nil

	case "tableRowInsert", "tableRowDelete", "tableColInsert", "tableColDelete":
		path, _, ok := resolveCursor(s.ir, op.Cursor)
		if !ok {
			return s.ir, op.Cursor, fmt.Errorf("%s: cursor not on a table cell", op.Kind)
		}
		var cp Path
		var co int
		switch op.Kind {
		case "tableRowInsert":
			cp, co = TableInsertRow(s.doc.Root, path, op.After)
		case "tableRowDelete":
			cp, co = TableDeleteRow(s.doc.Root, path)
		case "tableColInsert":
			cp, co = TableInsertCol(s.doc.Root, path, op.After)
		case "tableColDelete":
			cp, co = TableDeleteCol(s.doc.Root, path)
		}
		s.rerender()
		return s.ir, caretCursor(s.ir, cp, co), nil

	default:
		return s.ir, op.Cursor, fmt.Errorf("unknown op %q", op.Kind)
	}
}
