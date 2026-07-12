package editor

import (
	"testing"

	"conflira/core/adf"
)

func para(text string) *adf.Node {
	return &adf.Node{Type: "paragraph", Content: []*adf.Node{{Type: "text", Text: text}}}
}

func docOf(blocks ...*adf.Node) *adf.Node {
	return &adf.Node{Type: "doc", Content: blocks}
}

// blockText concatenates a block's text-node content.
func blockText(n *adf.Node) string {
	s := ""
	for _, c := range n.Content {
		if c.Type == "text" {
			s += c.Text
		} else if c.Type == "hardBreak" {
			s += "\n"
		}
	}
	return s
}

func TestSplitParagraph(t *testing.T) {
	st := NewStore(2)
	s := st.Open(&Doc{Root: docOf(para("HelloWorld"))})
	// cursor after "Hello" (col 5) on line 0.
	ir, cur, err := s.Apply(Op{Kind: "split", Cursor: Cursor{Line: 0, Col: 5}})
	if err != nil {
		t.Fatal(err)
	}
	root := s.ADF()
	if len(root.Content) != 2 {
		t.Fatalf("want 2 paragraphs, got %d", len(root.Content))
	}
	if blockText(root.Content[0]) != "Hello" || blockText(root.Content[1]) != "World" {
		t.Fatalf("split text: %q | %q", blockText(root.Content[0]), blockText(root.Content[1]))
	}
	// caret should be at start of the new (second) block.
	if cur.Col != 0 {
		t.Errorf("caret col = %d, want 0", cur.Col)
	}
	if len(ir.Lines) < 2 {
		t.Errorf("expected ≥2 lines after split, got %d", len(ir.Lines))
	}
}

func TestMergeParagraphs(t *testing.T) {
	st := NewStore(2)
	s := st.Open(&Doc{Root: docOf(para("Hello"), para("World"))})
	// merge the second paragraph (line index of "World") into the first.
	wi := -1
	for i, l := range s.IR().Lines {
		if l == "World" {
			wi = i
		}
	}
	_, cur, err := s.Apply(Op{Kind: "merge", Cursor: Cursor{Line: wi, Col: 0}})
	if err != nil {
		t.Fatal(err)
	}
	root := s.ADF()
	if len(root.Content) != 1 || blockText(root.Content[0]) != "HelloWorld" {
		t.Fatalf("merge result: %d blocks, text=%q", len(root.Content), blockText(root.Content[0]))
	}
	if cur.Col != 5 { // caret at the join (end of "Hello")
		t.Errorf("caret col = %d, want 5", cur.Col)
	}
}

func TestToggleTask(t *testing.T) {
	item := &adf.Node{Type: "taskItem", Attrs: map[string]any{"state": "TODO"},
		Content: []*adf.Node{para("do it")}}
	list := &adf.Node{Type: "taskList", Content: []*adf.Node{item}}
	st := NewStore(2)
	s := st.Open(&Doc{Root: docOf(list)})
	if _, _, err := s.Apply(Op{Kind: "toggleTask", Cursor: Cursor{Line: 0, Col: 1}}); err != nil {
		t.Fatal(err)
	}
	if got := s.ADF().Content[0].Content[0].AttrStr("state", ""); got != "DONE" {
		t.Fatalf("state = %q, want DONE", got)
	}
	// toggling again returns to TODO
	_, _, _ = s.Apply(Op{Kind: "toggleTask", Cursor: Cursor{Line: 0, Col: 1}})
	if got := s.ADF().Content[0].Content[0].AttrStr("state", ""); got != "TODO" {
		t.Fatalf("state = %q, want TODO", got)
	}
}

func TestToggleMarkAddsAndRemoves(t *testing.T) {
	st := NewStore(2)
	s := st.Open(&Doc{Root: docOf(para("hello world"))})
	sel := &Selection{Anchor: Cursor{Line: 0, Col: 0}, Head: Cursor{Line: 0, Col: 5}} // "hello"
	if _, _, err := s.Apply(Op{Kind: "toggleMark", Mark: "strong", Sel: sel}); err != nil {
		t.Fatal(err)
	}
	p := s.ADF().Content[0]
	// expect: ["hello"(strong)] + [" world"]
	if len(p.Content) != 2 || !hasMark(p.Content[0].Marks, "strong") || hasMark(p.Content[1].Marks, "strong") {
		t.Fatalf("after add: %+v", p.Content)
	}
	if p.Content[0].Text != "hello" {
		t.Errorf("bolded text = %q", p.Content[0].Text)
	}
	// toggle again removes it
	if _, _, err := s.Apply(Op{Kind: "toggleMark", Mark: "strong", Sel: sel}); err != nil {
		t.Fatal(err)
	}
	p = s.ADF().Content[0]
	for _, n := range p.Content {
		if hasMark(n.Marks, "strong") {
			t.Fatalf("strong should be gone: %+v", p.Content)
		}
	}
}

func TestSplitListItem(t *testing.T) {
	item := &adf.Node{Type: "listItem", Content: []*adf.Node{para("ab")}}
	list := &adf.Node{Type: "bulletList", Content: []*adf.Node{item}}
	st := NewStore(2)
	s := st.Open(&Doc{Root: docOf(list)})
	// split the single item between 'a' and 'b' → two items.
	if _, _, err := s.Apply(Op{Kind: "split", Cursor: Cursor{Line: 0, Col: 1}}); err != nil {
		t.Fatal(err)
	}
	l := s.ADF().Content[0]
	if l.Type != "bulletList" || len(l.Content) != 2 {
		t.Fatalf("want 2 list items, got %d", len(l.Content))
	}
	if blockText(l.Content[0].Content[0]) != "a" || blockText(l.Content[1].Content[0]) != "b" {
		t.Fatalf("item split: %q | %q", blockText(l.Content[0].Content[0]), blockText(l.Content[1].Content[0]))
	}
}
