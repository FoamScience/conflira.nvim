package editor

import (
	"testing"

	"conflira/core/adf"
)

// a 2x2 table: header row [A,B], body row [c,d].
func sampleTable() *adf.Node {
	cell := func(typ, text string) *adf.Node {
		return &adf.Node{Type: typ, Content: []*adf.Node{
			{Type: "paragraph", Content: []*adf.Node{{Type: "text", Text: text}}}}}
	}
	return &adf.Node{Type: "table", Content: []*adf.Node{
		{Type: "tableRow", Content: []*adf.Node{cell("tableHeader", "A"), cell("tableHeader", "B")}},
		{Type: "tableRow", Content: []*adf.Node{cell("tableCell", "c"), cell("tableCell", "d")}},
	}}
}

// rowLineFor finds the buffer line index whose cells include `text`.
func cellLine(s *Session, text string) int {
	for _, sp := range s.IR().Spans {
		if sp.Field == "text" && sp.Editable {
			if n := NodeAt(s.ADF(), sp.Path); n != nil && (n.Type == "tableCell" || n.Type == "tableHeader") {
				if cellText(n) == text {
					return sp.Line
				}
			}
		}
	}
	return -1
}

func TestTableCellEditViaApplyText(t *testing.T) {
	st := NewStore(2)
	s := st.Open(&Doc{Root: docOf(sampleTable())})
	lines := append([]string{}, s.IR().Lines...)
	bodyLine := cellLine(s, "c")
	if bodyLine < 0 {
		t.Fatalf("body row line not found in %v", lines)
	}
	// Replace the body row's cell text: "c" → "hello", "d" → "world".
	lines[bodyLine] = " hello │ world "
	if _, _, err := s.ApplyText(lines, Cursor{}); err != nil {
		t.Fatal(err)
	}
	body := s.ADF().Content[0].Content[1] // table.rows[1]
	if cellText(body.Content[0]) != "hello" || cellText(body.Content[1]) != "world" {
		t.Fatalf("cells: %q | %q", cellText(body.Content[0]), cellText(body.Content[1]))
	}
	if !s.Dirty() {
		t.Error("expected dirty after cell edit")
	}
}

func TestTableInsertRow(t *testing.T) {
	st := NewStore(2)
	s := st.Open(&Doc{Root: docOf(sampleTable())})
	line := cellLine(s, "c") // cursor in the body row
	if _, _, err := s.Apply(Op{Kind: "tableRowInsert", Cursor: Cursor{Line: line, Col: 1}, After: true}); err != nil {
		t.Fatal(err)
	}
	tbl := s.ADF().Content[0]
	if len(tbl.Content) != 3 {
		t.Fatalf("want 3 rows, got %d", len(tbl.Content))
	}
	// new row has 2 cells
	if len(tbl.Content[2].Content) != 2 {
		t.Errorf("new row col count = %d", len(tbl.Content[2].Content))
	}
}

func TestTableInsertCol(t *testing.T) {
	st := NewStore(2)
	s := st.Open(&Doc{Root: docOf(sampleTable())})
	line := cellLine(s, "A")
	if _, _, err := s.Apply(Op{Kind: "tableColInsert", Cursor: Cursor{Line: line, Col: 1}, After: true}); err != nil {
		t.Fatal(err)
	}
	tbl := s.ADF().Content[0]
	for ri, row := range tbl.Content {
		if len(row.Content) != 3 {
			t.Fatalf("row %d col count = %d, want 3", ri, len(row.Content))
		}
	}
	// header row's new cell is a header
	if tbl.Content[0].Content[1].Type != "tableHeader" {
		t.Errorf("inserted header cell type = %s", tbl.Content[0].Content[1].Type)
	}
}

func TestTableDeleteColAndRow(t *testing.T) {
	st := NewStore(2)
	s := st.Open(&Doc{Root: docOf(sampleTable())})
	// delete the column containing "B"/"d"
	line := cellLine(s, "d")
	col := -1
	for _, sp := range s.IR().Spans {
		if sp.Line == line {
			if n := NodeAt(s.ADF(), sp.Path); n != nil && cellText(n) == "d" {
				col = sp.ColStart
			}
		}
	}
	if _, _, err := s.Apply(Op{Kind: "tableColDelete", Cursor: Cursor{Line: line, Col: col}}); err != nil {
		t.Fatal(err)
	}
	tbl := s.ADF().Content[0]
	for _, row := range tbl.Content {
		if len(row.Content) != 1 {
			t.Fatalf("after col delete, row has %d cells", len(row.Content))
		}
	}
	// delete a row (now single-col table, 2 rows) → 1 row
	line2 := cellLine(s, "c")
	if _, _, err := s.Apply(Op{Kind: "tableRowDelete", Cursor: Cursor{Line: line2, Col: 1}}); err != nil {
		t.Fatal(err)
	}
	if len(s.ADF().Content[0].Content) != 1 {
		t.Fatalf("after row delete, %d rows", len(s.ADF().Content[0].Content))
	}
}

func TestTableDeleteLastColIsNoop(t *testing.T) {
	one := &adf.Node{Type: "table", Content: []*adf.Node{
		{Type: "tableRow", Content: []*adf.Node{
			{Type: "tableCell", Content: []*adf.Node{{Type: "paragraph", Content: []*adf.Node{{Type: "text", Text: "x"}}}}}}}}}
	st := NewStore(2)
	s := st.Open(&Doc{Root: docOf(one)})
	line := cellLine(s, "x")
	_, _, _ = s.Apply(Op{Kind: "tableColDelete", Cursor: Cursor{Line: line, Col: 1}})
	if len(s.ADF().Content[0].Content[0].Content) != 1 {
		t.Error("deleting the only column should be a no-op")
	}
}
