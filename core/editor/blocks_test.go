package editor

import (
	"testing"

	"conflira/core/adf"
)

func heading(level int, text string) *adf.Node {
	return &adf.Node{Type: "heading", Attrs: map[string]any{"level": float64(level)},
		Content: []*adf.Node{{Type: "text", Text: text}}}
}

func TestSetAttrHeadingLevel(t *testing.T) {
	st := NewStore(2)
	s := st.Open(&Doc{Root: docOf(heading(2, "Title"))})
	if _, _, err := s.Apply(Op{Kind: "setAttr", Cursor: Cursor{Line: 0, Col: 2}, Attr: "level", Value: float64(4)}); err != nil {
		t.Fatal(err)
	}
	if got := s.ADF().Content[0].AttrInt("level", 0); got != 4 {
		t.Fatalf("heading level = %d, want 4", got)
	}
	// out-of-range clamps to 1..6
	_, _, _ = s.Apply(Op{Kind: "setAttr", Cursor: Cursor{Line: 0, Col: 2}, Attr: "level", Value: float64(99)})
	if got := s.ADF().Content[0].AttrInt("level", 0); got != 6 {
		t.Fatalf("clamp: level = %d, want 6", got)
	}
}

func TestSetAttrCodeLanguage(t *testing.T) {
	cb := &adf.Node{Type: "codeBlock", Content: []*adf.Node{{Type: "text", Text: "x=1"}}}
	st := NewStore(2)
	s := st.Open(&Doc{Root: docOf(cb)})
	if _, _, err := s.Apply(Op{Kind: "setAttr", Cursor: Cursor{Line: 0, Col: 1}, Attr: "language", Value: "python"}); err != nil {
		t.Fatal(err)
	}
	if got := s.ADF().Content[0].AttrStr("language", ""); got != "python" {
		t.Fatalf("language = %q, want python", got)
	}
}

func TestInsertBlockAfterCurrent(t *testing.T) {
	st := NewStore(2)
	s := st.Open(&Doc{Root: docOf(para("first"), para("second"))})
	// cursor in "first" (line 0); insert a heading after it.
	_, cur, err := s.Apply(Op{Kind: "insertBlock", Cursor: Cursor{Line: 0, Col: 2},
		Block: &BlockSpec{Type: "heading", Attrs: map[string]any{"level": float64(3)}}})
	if err != nil {
		t.Fatal(err)
	}
	root := s.ADF()
	if len(root.Content) != 3 || root.Content[1].Type != "heading" {
		t.Fatalf("blocks: %v", typesOf(root))
	}
	if root.Content[1].AttrInt("level", 0) != 3 {
		t.Errorf("inserted heading level wrong")
	}
	// caret should be on the new (empty) heading's line.
	if cur.Line == 0 {
		t.Errorf("caret should move into the new block, got %+v", cur)
	}
}

func TestInsertRuleAndPanel(t *testing.T) {
	st := NewStore(2)
	s := st.Open(&Doc{Root: docOf(para("x"))})
	_, _, _ = s.Apply(Op{Kind: "insertBlock", Cursor: Cursor{Line: 0, Col: 0}, Block: &BlockSpec{Type: "rule"}})
	_, _, _ = s.Apply(Op{Kind: "insertBlock", Cursor: Cursor{Line: 0, Col: 0},
		Block: &BlockSpec{Type: "panel", Attrs: map[string]any{"panelType": "warning"}}})
	types := typesOf(s.ADF())
	has := func(t string) bool {
		for _, x := range types {
			if x == t {
				return true
			}
		}
		return false
	}
	if !has("rule") || !has("panel") {
		t.Fatalf("expected rule+panel, got %v", types)
	}
}

func TestDeleteBlock(t *testing.T) {
	st := NewStore(2)
	s := st.Open(&Doc{Root: docOf(para("one"), para("two"), para("three"))})
	// delete "two" (line index where text == "two").
	ti := -1
	for i, l := range s.IR().Lines {
		if l == "two" {
			ti = i
		}
	}
	if _, _, err := s.Apply(Op{Kind: "deleteBlock", Cursor: Cursor{Line: ti, Col: 0}}); err != nil {
		t.Fatal(err)
	}
	root := s.ADF()
	if len(root.Content) != 2 || blockText(root.Content[0]) != "one" || blockText(root.Content[1]) != "three" {
		t.Fatalf("after delete: %d blocks (%q,%q)", len(root.Content),
			blockText(root.Content[0]), blockText(root.Content[len(root.Content)-1]))
	}
}

func TestDeleteLastBlockKeepsEmptyParagraph(t *testing.T) {
	st := NewStore(2)
	s := st.Open(&Doc{Root: docOf(para("only"))})
	if _, _, err := s.Apply(Op{Kind: "deleteBlock", Cursor: Cursor{Line: 0, Col: 0}}); err != nil {
		t.Fatal(err)
	}
	root := s.ADF()
	if len(root.Content) != 1 || root.Content[0].Type != "paragraph" {
		t.Fatalf("expected one empty paragraph, got %v", typesOf(root))
	}
}

func typesOf(doc *adf.Node) []string {
	var out []string
	for _, n := range doc.Content {
		out = append(out, n.Type)
	}
	return out
}
