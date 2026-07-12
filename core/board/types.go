// Package board ports the Lua outline-board pipeline (atlassian/board/state.lua
// and render.lua): issue list → tree → grouped/filtered → Projection IR. Verified
// to reproduce the frozen Lua board IR (see render_test.go, testdata/cases_board).
package board

import "encoding/json"

// Link is an issue link (e.g. "is blocked by").
type Link struct {
	LinkType    string `json:"link_type"`
	Direction   string `json:"direction"`
	Label       string `json:"label"`
	IssueKey    string `json:"issue_key"`
	IssueStatus string `json:"issue_status"`
}

// Issue mirrors the fields of JiraIssue the board renderer reads.
type Issue struct {
	Key                string          `json:"key"`
	Summary            string          `json:"summary"`
	Status             string          `json:"status"`
	Type               string          `json:"type"`
	Level              int             `json:"level"`
	Project            string          `json:"project,omitempty"`
	Parent             string          `json:"parent,omitempty"`
	Assignee           string          `json:"assignee,omitempty"`
	Description        string          `json:"description,omitempty"`
	AcceptanceCriteria string          `json:"acceptance_criteria,omitempty"`
	Priority           string          `json:"priority,omitempty"`
	Labels             []string        `json:"labels"`
	FixVersions        []string        `json:"fix_versions"`
	Links              []Link          `json:"links"`
	Duedate            string          `json:"duedate,omitempty"`
	Created            string          `json:"created,omitempty"`
	Updated            string          `json:"updated,omitempty"`
	CustomFieldsRaw    json.RawMessage `json:"custom_fields_raw,omitempty"`
	// Involvement is the set of relationship tags (assigned/reporter/review/
	// additional/watching) that matched the current user, in InvolvementKinds
	// order. Rendered as trailing icons next to the title.
	Involvement []string `json:"involvement,omitempty"`
}

// AddInvolvement records a relationship tag if not already present.
func (is *Issue) AddInvolvement(kind string) {
	for _, k := range is.Involvement {
		if k == kind {
			return
		}
	}
	is.Involvement = append(is.Involvement, kind)
}

// CustomFields decodes custom_fields_raw as an object. The Lua producer encodes
// an empty table as a JSON array ([]), so a non-object decodes to nil.
func (is *Issue) CustomFields() map[string]any {
	if len(is.CustomFieldsRaw) == 0 {
		return nil
	}
	var m map[string]any
	if err := json.Unmarshal(is.CustomFieldsRaw, &m); err != nil {
		return nil
	}
	return m
}

// Node is a board tree node wrapping an issue.
type Node struct {
	Issue           *Issue
	Children        []*Node
	Expanded        bool
	Depth           int
	IsContext       bool
	Urgency         string
	MaxPriorityRank int
}

// Group is a labelled set of root nodes.
type Group struct {
	Name  string
	Nodes []*Node
}

// State is the renderer input.
type State struct {
	Issues  []*Issue
	Tree    []*Node
	Groups  []Group
	Project string
	Icons   string // involvement icon style: "nerd" | "unicode" (default)
}

// BoardInput is the fixture/wire shape: raw issues + render options.
type BoardInput struct {
	Issues  []*Issue `json:"issues"`
	Project string   `json:"project"`
	Group   string   `json:"group"`
}

// DecodeInput parses a BoardInput from JSON.
func DecodeInput(data []byte) (*BoardInput, error) {
	var b BoardInput
	if err := json.Unmarshal(data, &b); err != nil {
		return nil, err
	}
	return &b, nil
}
