package jql

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// TestJQLParity verifies each Go builder reproduces the JQL the frozen Lua emits.
func TestJQLParity(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("..", "testdata", "logic", "jql.json"))
	if err != nil {
		t.Fatal(err)
	}
	var want map[string]string
	if err := json.Unmarshal(data, &want); err != nil {
		t.Fatal(err)
	}

	got := map[string]string{
		"assigned_to_me":       AssignedToMe(),
		"created_by_me":        CreatedByMe(),
		"assigned_not_created": AssignedNotCreated(),
		"by_project":           ByProject("PROJ"),
		"by_status":            ByStatus("In Progress"),
		"by_type":              ByType("Bug"),
		"by_level_1":           ByLevel(1, "PROJ"),
		"by_level_2":           ByLevel(2, "PROJ"),
		"by_level_3_noproj":    ByLevel(3, ""),
		"by_label":             ByLabel("ready", "PROJ"),
		"by_label_noproj":      ByLabel("operational", ""),
		"children_of":          ChildrenOf("PROJ-7"),
		"overdue":              Overdue("PROJ"),
		"due_today":            DueToday("PROJ"),
		"due_this_week":        DueThisWeek("PROJ"),
		"due_soon":             DueSoon("PROJ"),
		"by_duedate":           ByDuedate("PROJ"),
		"combine":              Combine("project = PROJ ORDER BY updated DESC", "assignee = currentUser()"),
		"combine_noorder":      Combine("project = PROJ", "status = Done"),
	}

	for name, exp := range want {
		g, ok := got[name]
		if !ok {
			t.Errorf("%s: no Go builder mapped", name)
			continue
		}
		if g != exp {
			t.Errorf("%s:\n got: %q\nwant: %q", name, g, exp)
		}
	}
	if len(got) != len(want) {
		t.Errorf("builder count: got %d, want %d", len(got), len(want))
	}
}

// Main and Reviewing must match the real build_queries output (captured from Lua).
func TestBoardQueries(t *testing.T) {
	if got := Main(); got != `assignee = currentUser() AND issuetype NOT IN ("Epic") ORDER BY updated DESC` {
		t.Errorf("main: %q", got)
	}

	want := `("customfield_10006" = currentUser() OR "customfield_10008" = currentUser()) AND assignee != currentUser() AND issuetype NOT IN ("Epic") ORDER BY updated DESC`
	if got := InvolvementSection([]string{"customfield_10006", "customfield_10008"}); got != want {
		t.Errorf("section:\n got: %q\nwant: %q", got, want)
	}
	if InvolvementSection(nil) != "" {
		t.Errorf("empty field list should yield empty query")
	}
}
