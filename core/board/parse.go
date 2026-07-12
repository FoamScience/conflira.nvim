package board

import (
	"encoding/json"

	"conflira/core/adf"
)

// levelByType reverses config.lua types.lvl1..lvl4 (mirrors types.get_level).
var levelByType = map[string]int{
	"Epic": 1, "Feature": 2, "Bug": 2, "Issue": 2, "Task": 3, "Sub-Task": 4,
}

func levelOf(typeName string) int {
	if l, ok := levelByType[typeName]; ok {
		return l
	}
	return 0
}

type rawNamed struct {
	Name string `json:"name"`
}
type rawKeyed struct {
	Key string `json:"key"`
}

type rawLinkIssue struct {
	Key    string `json:"key"`
	Fields struct {
		Summary string   `json:"summary"`
		Status  rawNamed `json:"status"`
	} `json:"fields"`
}

type rawLink struct {
	ID   string `json:"id"`
	Type struct {
		Name    string `json:"name"`
		Inward  string `json:"inward"`
		Outward string `json:"outward"`
	} `json:"type"`
	InwardIssue  *rawLinkIssue `json:"inwardIssue"`
	OutwardIssue *rawLinkIssue `json:"outwardIssue"`
}

type rawFields struct {
	Summary   string    `json:"summary"`
	IssueType rawNamed  `json:"issuetype"`
	Status    rawNamed  `json:"status"`
	Priority  *rawNamed `json:"priority"`
	Project   rawKeyed  `json:"project"`
	Assignee  *struct {
		DisplayName string `json:"displayName"`
	} `json:"assignee"`
	Parent      *rawKeyed       `json:"parent"`
	Labels      []string        `json:"labels"`
	FixVersions []rawNamed      `json:"fixVersions"`
	Duedate     string          `json:"duedate"`
	Created     string          `json:"created"`
	Updated     string          `json:"updated"`
	Description json.RawMessage `json:"description"`
	IssueLinks  []rawLink       `json:"issuelinks"`
}

type rawIssue struct {
	Key    string    `json:"key"`
	ID     string    `json:"id"`
	Fields rawFields `json:"fields"`
}

// ParseIssue maps a raw Jira REST issue into the board Issue model, mirroring
// jira-interface/types.lua parse_issue (board-relevant fields).
func ParseIssue(data []byte) (*Issue, error) {
	var r rawIssue
	if err := json.Unmarshal(data, &r); err != nil {
		return nil, err
	}
	f := r.Fields

	is := &Issue{
		Key:         r.Key,
		Summary:     f.Summary,
		Status:      f.Status.Name,
		Type:        f.IssueType.Name,
		Level:       levelOf(f.IssueType.Name),
		Project:     f.Project.Key,
		Duedate:     f.Duedate,
		Updated:     f.Updated,
		Created:     f.Created,
		Labels:      f.Labels,
		Description: parseDescription(f.Description),
	}
	if is.Labels == nil {
		is.Labels = []string{}
	}
	if f.Priority != nil {
		is.Priority = f.Priority.Name
	}
	if f.Assignee != nil {
		is.Assignee = f.Assignee.DisplayName
	}
	if f.Parent != nil {
		is.Parent = f.Parent.Key
	}
	is.FixVersions = []string{}
	for _, v := range f.FixVersions {
		if v.Name != "" {
			is.FixVersions = append(is.FixVersions, v.Name)
		}
	}
	is.Links = []Link{}
	for _, l := range f.IssueLinks {
		is.Links = append(is.Links, parseLink(l))
	}
	return is, nil
}

func parseDescription(raw json.RawMessage) string {
	if len(raw) == 0 {
		return ""
	}
	var s string
	if json.Unmarshal(raw, &s) == nil {
		return s
	}
	doc, err := adf.Decode(raw)
	if err != nil {
		return ""
	}
	return adf.ToText(doc)
}

func parseLink(l rawLink) Link {
	if l.InwardIssue != nil {
		return Link{
			LinkType:    l.Type.Name,
			Direction:   "inward",
			Label:       l.Type.Inward,
			IssueKey:    l.InwardIssue.Key,
			IssueStatus: l.InwardIssue.Fields.Status.Name,
		}
	}
	out := l.OutwardIssue
	if out == nil {
		out = &rawLinkIssue{}
	}
	return Link{
		LinkType:    l.Type.Name,
		Direction:   "outward",
		Label:       l.Type.Outward,
		IssueKey:    out.Key,
		IssueStatus: out.Fields.Status.Name,
	}
}
