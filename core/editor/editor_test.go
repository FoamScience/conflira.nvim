package editor

import (
	"encoding/json"
	"testing"

	"conflira/core/adf"
)

// a small ADF doc: a heading + a paragraph.
func sampleADF() *adf.Node {
	return &adf.Node{Type: "doc", Content: []*adf.Node{
		{Type: "heading", Attrs: map[string]any{"level": float64(2)}, Content: []*adf.Node{
			{Type: "text", Text: "Title"},
		}},
		{Type: "paragraph", Content: []*adf.Node{
			{Type: "text", Text: "Hello world"},
		}},
	}}
}

func TestRenderProducesMap(t *testing.T) {
	ir := Render(&Doc{Root: sampleADF()})
	if ir == nil || ir.ProjectionIR == nil {
		t.Fatal("nil IR")
	}
	if len(ir.Lines) == 0 {
		t.Fatal("no lines rendered")
	}
	// The render-map must point at least one editable text span to the paragraph.
	var editable, paraText bool
	for _, sp := range ir.Spans {
		if sp.Editable {
			editable = true
		}
		if sp.Editable && sp.Field == "text" && len(sp.Path) > 0 && sp.Path[0] == 1 {
			paraText = true // doc.Content[1] = the paragraph
		}
	}
	if !editable {
		t.Error("no editable spans in render-map")
	}
	if !paraText {
		t.Errorf("no editable text span mapped to the paragraph; spans=%+v", ir.Spans)
	}
}

func TestSessionLifecycleAndDirty(t *testing.T) {
	st := NewStore(2)
	s := st.Open(&Doc{Root: sampleADF(), Meta: Meta{Kind: "jira", Key: "K-1", Field: "description"}})
	if s.ID == "" {
		t.Fatal("no session id")
	}
	if got, ok := st.Get(s.ID); !ok || got != s {
		t.Fatal("session not retrievable")
	}
	if s.Dirty() {
		t.Error("freshly opened session should not be dirty")
	}
	// Mutating the live tree (simulating a future edit) flips dirty.
	s.doc.Root.Content[1].Content[0].Text = "changed"
	if !s.Dirty() {
		t.Error("dirty should be true after the tree diverges from baseline")
	}
	st.Close(s.ID)
	if _, ok := st.Get(s.ID); ok {
		t.Error("session should be gone after close")
	}
}

func TestStoreLRUEviction(t *testing.T) {
	st := NewStore(2)
	a := st.Open(&Doc{Root: sampleADF()})
	b := st.Open(&Doc{Root: sampleADF()})
	_, _ = st.Get(a.ID) // touch a → b becomes LRU
	c := st.Open(&Doc{Root: sampleADF()})
	if _, ok := st.Get(b.ID); ok {
		t.Error("b should have been evicted as least-recently-used")
	}
	if _, ok := st.Get(a.ID); !ok {
		t.Error("a was touched and must survive")
	}
	if _, ok := st.Get(c.ID); !ok {
		t.Error("c just opened, must be present")
	}
}

// fakeFetcher returns a canned issue with a description field.
type fakeFetcher struct{ raw []byte }

func (f fakeFetcher) GetIssue(string) ([]byte, error) { return f.raw, nil }

func TestOpenJiraExtractsDescription(t *testing.T) {
	desc, _ := json.Marshal(sampleADF())
	raw, _ := json.Marshal(map[string]any{
		"key":    "K-1",
		"fields": map[string]json.RawMessage{"description": desc},
	})
	doc, err := OpenJira(fakeFetcher{raw: raw}, "K-1", "")
	if err != nil {
		t.Fatal(err)
	}
	if doc.Meta.Field != "description" || doc.Meta.Key != "K-1" {
		t.Errorf("meta: %+v", doc.Meta)
	}
	if doc.Root.Type != "doc" || len(doc.Root.Content) != 2 {
		t.Errorf("description not decoded: %+v", doc.Root)
	}
}

func TestApplyTextEditsParagraph(t *testing.T) {
	st := NewStore(4)
	s := st.Open(&Doc{Root: sampleADF(), Meta: Meta{Kind: "jira", Key: "K-1"}})
	lines := append([]string{}, s.IR().Lines...)
	// the paragraph "Hello world" is the last line (no-wrap → one line).
	pi := -1
	for i, l := range lines {
		if l == "Hello world" {
			pi = i
		}
	}
	if pi < 0 {
		t.Fatalf("paragraph line not found in %v", lines)
	}
	lines[pi] = "Hello there"
	if _, _, err := s.ApplyText(lines, Cursor{Line: pi, Col: 11}); err != nil {
		t.Fatal(err)
	}
	// ADF text node must now read "Hello there".
	para := NodeAt(s.ADF(), Path{2}) // doc.Content[1] = paragraph (1-based)
	if para == nil || para.Type != "paragraph" || len(para.Content) == 0 || para.Content[0].Text != "Hello there" {
		t.Fatalf("paragraph not updated: %+v", para)
	}
	if !s.Dirty() {
		t.Error("session should be dirty after an edit")
	}
}

func TestApplyTextRejectsLineCountChange(t *testing.T) {
	st := NewStore(4)
	s := st.Open(&Doc{Root: sampleADF()})
	short := s.IR().Lines[:len(s.IR().Lines)-1]
	if _, _, err := s.ApplyText(short, Cursor{}); err == nil {
		t.Error("expected error on line-count change (structural)")
	}
}

type fakeSubmitter struct {
	key    string
	fields map[string]any
}

func (f *fakeSubmitter) EditIssue(key string, fields map[string]any) error {
	f.key, f.fields = key, fields
	return nil
}

func TestSubmitSendsField(t *testing.T) {
	st := NewStore(4)
	s := st.Open(&Doc{Root: sampleADF(), Meta: Meta{Kind: "jira", Key: "K-9", Field: "description"}})
	sub := &fakeSubmitter{}
	if err := Submit(s, sub); err != nil {
		t.Fatal(err)
	}
	if sub.key != "K-9" {
		t.Errorf("key: %s", sub.key)
	}
	if _, ok := sub.fields["description"]; !ok {
		t.Errorf("description field not submitted: %v", sub.fields)
	}
}

func TestOpenJiraEmptyDescription(t *testing.T) {
	raw, _ := json.Marshal(map[string]any{"key": "K-1", "fields": map[string]any{}})
	doc, err := OpenJira(fakeFetcher{raw: raw}, "K-1", "description")
	if err != nil {
		t.Fatal(err)
	}
	if doc.Root.Type != "doc" {
		t.Errorf("expected empty doc, got %+v", doc.Root)
	}
}
