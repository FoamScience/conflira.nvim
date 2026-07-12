package board

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

// ParseIssue must reproduce the board-relevant fields of the Lua parse_issue.
func TestParseIssueParity(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("..", "testdata", "logic", "parse.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Raw    json.RawMessage `json:"raw"`
		Parsed Issue           `json:"parsed"`
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}

	got, err := ParseIssue(fixture.Raw)
	if err != nil {
		t.Fatal(err)
	}
	want := &fixture.Parsed

	eq := func(name string, a, b any) {
		if !reflect.DeepEqual(a, b) {
			t.Errorf("%s:\n got: %#v\nwant: %#v", name, a, b)
		}
	}
	eq("key", got.Key, want.Key)
	eq("summary", got.Summary, want.Summary)
	eq("status", got.Status, want.Status)
	eq("type", got.Type, want.Type)
	eq("level", got.Level, want.Level)
	eq("project", got.Project, want.Project)
	eq("parent", got.Parent, want.Parent)
	eq("assignee", got.Assignee, want.Assignee)
	eq("priority", got.Priority, want.Priority)
	eq("duedate", got.Duedate, want.Duedate)
	eq("created", got.Created, want.Created)
	eq("updated", got.Updated, want.Updated)
	eq("description", got.Description, want.Description)
	eq("labels", got.Labels, want.Labels)
	eq("fix_versions", got.FixVersions, want.FixVersions)
	eq("links", got.Links, want.Links)
}
