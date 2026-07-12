package queue

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// The Go queue must read the exact on-disk format the Lua plugin writes.
func TestQueueFormatCompat(t *testing.T) {
	q := New(filepath.Join("..", "testdata", "logic", "queue.json"))
	edits, err := q.All()
	if err != nil {
		t.Fatal(err)
	}
	if len(edits) != 3 {
		t.Fatalf("entries: got %d, want 3", len(edits))
	}

	if edits[0].Type != "transition" || edits[0].IssueKey != "PROJ-1" {
		t.Errorf("edit[0]: %+v", edits[0])
	}
	var tr struct {
		TransitionID string `json:"transition_id"`
	}
	json.Unmarshal(edits[0].Data, &tr)
	if tr.TransitionID != "31" {
		t.Errorf("transition_id: %q", tr.TransitionID)
	}

	if edits[1].Type != "update" {
		t.Errorf("edit[1] type: %q", edits[1].Type)
	}
	var up struct {
		Fields map[string]any `json:"fields"`
	}
	json.Unmarshal(edits[1].Data, &up)
	if up.Fields["summary"] != "new title" {
		t.Errorf("update fields: %+v", up.Fields)
	}

	if edits[2].Type != "comment" {
		t.Errorf("edit[2] type: %q", edits[2].Type)
	}
}

// Add/Remove/Clear persist and reload correctly.
func TestQueueRoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "queue.json")
	q := New(path)
	q.Now = func() int64 { return 1717000000 }
	r := int64(41)
	q.Rand = func() int64 { r++; return r } // distinct per edit

	if err := q.QueueTransition("A-1", "11", "Done"); err != nil {
		t.Fatal(err)
	}
	if err := q.QueueComment("A-2", "<p>x</p>"); err != nil {
		t.Fatal(err)
	}

	// Reload from disk in a fresh queue.
	q2 := New(path)
	edits, _ := q2.All()
	if len(edits) != 2 {
		t.Fatalf("reload: got %d, want 2", len(edits))
	}
	if edits[0].ID != "1717000000-42" {
		t.Errorf("id: %q", edits[0].ID)
	}

	if err := q2.Remove(edits[0].ID); err != nil {
		t.Fatal(err)
	}
	q3 := New(path)
	if n, _ := q3.Count(); n != 1 {
		t.Errorf("after remove: %d, want 1", n)
	}

	if err := q3.Clear(); err != nil {
		t.Fatal(err)
	}
	data, _ := os.ReadFile(path)
	if string(data) != "null" && string(data) != "[]" {
		t.Errorf("cleared file: %q", data)
	}
}
