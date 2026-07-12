package fields

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

// Resolve must reproduce the Lua ensure_custom_fields_resolved output (empty
// config → auto-discovery + Acceptance Criteria fuzzy match).
func TestResolveParity(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("..", "testdata", "logic", "fields.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Fields   []Field             `json:"fields"`
		Resolved map[string][]string `json:"resolved"`
		Sections []struct {
			Name  string   `json:"name"`
			Match []string `json:"match"`
			IDs   []string `json:"ids"`
		} `json:"sections"`
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}

	got := Resolve(fixture.Fields, nil, nil)
	if !reflect.DeepEqual(got, fixture.Resolved) {
		t.Errorf("resolved mismatch:\n got: %#v\nwant: %#v", got, fixture.Resolved)
	}

	// Build sections from the fixture's config and verify field bucketing.
	var sections []Section
	for _, s := range fixture.Sections {
		sections = append(sections, Section{Name: s.Name, Match: s.Match})
	}
	gotIDs := SenseSections(fixture.Fields, sections)
	for i, s := range fixture.Sections {
		want := s.IDs
		if len(want) == 0 {
			want = []string{}
		}
		if !reflect.DeepEqual(gotIDs[i], want) {
			t.Errorf("section %q ids:\n got: %#v\nwant: %#v", s.Name, gotIDs[i], want)
		}
	}

	// The shipped DefaultSections must match config.lua's defaults.
	if !reflect.DeepEqual(DefaultSections, []Section{
		{Name: "Reviewing", Match: []string{"review"}},
		{Name: "Additional Assignees", Match: []string{"additional", "assignee"}},
	}) {
		t.Errorf("DefaultSections drifted from config.lua: %#v", DefaultSections)
	}
}

// Configured headings merge with discovered IDs (unit check of the non-empty path).
func TestResolveConfigured(t *testing.T) {
	fs := []Field{
		{ID: "customfield_1", Name: "Reviewer", Custom: true, Schema: Schema{Type: "doc"}},
		{ID: "customfield_2", Name: "Reviewer", Custom: true, Schema: Schema{Type: "doc"}},
	}
	got := Resolve(fs, map[string][]string{"Reviewer": {"customfield_1"}}, nil)
	want := map[string][]string{"Reviewer": {"customfield_1", "customfield_2"}}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got %#v, want %#v", got, want)
	}
}
