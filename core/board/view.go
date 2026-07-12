package board

import (
	"encoding/json"
	"strings"

	"conflira/core/adf"
)

func textNode(s string) *adf.Node { return &adf.Node{Type: "text", Text: s} }
func boldNode(s string) *adf.Node {
	return &adf.Node{Type: "text", Text: s, Marks: []adf.Mark{{Type: "strong"}}}
}
func heading(level int, text string) *adf.Node {
	return &adf.Node{Type: "heading", Attrs: map[string]any{"level": float64(level)},
		Content: []*adf.Node{textNode(text)}}
}
func para(nodes ...*adf.Node) *adf.Node {
	return &adf.Node{Type: "paragraph", Content: nodes}
}
func bulletList(items [][]*adf.Node) *adf.Node {
	var lis []*adf.Node
	for _, it := range items {
		lis = append(lis, &adf.Node{Type: "listItem", Content: []*adf.Node{para(it...)}})
	}
	return &adf.Node{Type: "bulletList", Content: lis}
}

func shortDate(s string) string {
	if len(s) >= 16 {
		return strings.Replace(s[:16], "T", " ", 1)
	}
	return s
}

// acSection returns an "Acceptance Criteria" heading + content for the first
// acFieldID that has a value, or nil when none is defined (epics, undefined
// fields — never show an empty section).
func acSection(raw []byte, acFieldIDs []string) []*adf.Node {
	if len(acFieldIDs) == 0 {
		return nil
	}
	var all struct {
		Fields map[string]json.RawMessage `json:"fields"`
	}
	if json.Unmarshal(raw, &all) != nil {
		return nil
	}
	for _, id := range acFieldIDs {
		v := all.Fields[id]
		if len(v) == 0 || string(v) == "null" {
			continue
		}
		var s string
		if json.Unmarshal(v, &s) == nil {
			if strings.TrimSpace(s) != "" {
				return []*adf.Node{heading(2, "Acceptance Criteria"), para(textNode(s))}
			}
			continue
		}
		var node adf.Node
		if json.Unmarshal(v, &node) == nil && len(node.Content) > 0 {
			return append([]*adf.Node{heading(2, "Acceptance Criteria")}, node.Content...)
		}
	}
	return nil
}

// IssueViewADF builds a read-only ADF document for an issue from its raw Jira
// JSON: summary, metadata, description, acceptance criteria (only when defined),
// attachments, links, and comments — matching (a subset of) the Neovim issue
// view. Rendering it with render.Build gives the in-editor view.
func IssueViewADF(raw []byte, acFieldIDs []string) *adf.Node {
	var r struct {
		Key    string `json:"key"`
		Fields struct {
			Summary   string    `json:"summary"`
			Status    rawNamed  `json:"status"`
			IssueType rawNamed  `json:"issuetype"`
			Priority  *rawNamed `json:"priority"`
			Assignee  *struct {
				DisplayName string `json:"displayName"`
			} `json:"assignee"`
			Duedate     string          `json:"duedate"`
			Description json.RawMessage `json:"description"`
			Attachment  []struct {
				Filename string `json:"filename"`
				MimeType string `json:"mimeType"`
			} `json:"attachment"`
			Comment struct {
				Comments []struct {
					Author struct {
						DisplayName string `json:"displayName"`
					} `json:"author"`
					Body    json.RawMessage `json:"body"`
					Created string          `json:"created"`
				} `json:"comments"`
				Total int `json:"total"`
			} `json:"comment"`
			IssueLinks []rawLink `json:"issuelinks"`
		} `json:"fields"`
	}
	_ = json.Unmarshal(raw, &r)
	f := r.Fields

	assignee := "Unassigned"
	if f.Assignee != nil && f.Assignee.DisplayName != "" {
		assignee = f.Assignee.DisplayName
	}
	meta := []string{r.Key, f.Status.Name, f.IssueType.Name, assignee}
	if f.Priority != nil && f.Priority.Name != "" {
		meta = append(meta, f.Priority.Name)
	}
	if f.Duedate != "" {
		meta = append(meta, "due "+f.Duedate)
	}

	content := []*adf.Node{
		heading(1, f.Summary),
		para(textNode(strings.Join(meta, "  ·  "))),
		{Type: "rule"},
	}

	// Description.
	if len(f.Description) > 0 {
		var desc adf.Node
		if json.Unmarshal(f.Description, &desc) == nil && len(desc.Content) > 0 {
			content = append(content, heading(2, "Description"))
			content = append(content, desc.Content...)
		}
	}

	// Acceptance Criteria — only when defined (never for epics/undefined).
	content = append(content, acSection(raw, acFieldIDs)...)

	// Attachments.
	if len(f.Attachment) > 0 {
		content = append(content, heading(2, "Attachments"))
		var items [][]*adf.Node
		for _, a := range f.Attachment {
			items = append(items, []*adf.Node{textNode(a.Filename + "  (" + a.MimeType + ")")})
		}
		content = append(content, bulletList(items))
	}

	// Links.
	if len(f.IssueLinks) > 0 {
		content = append(content, heading(2, "Links"))
		var items [][]*adf.Node
		for _, l := range f.IssueLinks {
			lk := parseLink(l)
			items = append(items, []*adf.Node{textNode(lk.Label + " " + lk.IssueKey)})
		}
		content = append(content, bulletList(items))
	}

	// Comments.
	if len(f.Comment.Comments) > 0 {
		content = append(content, heading(2, "Comments"))
		for i, cm := range f.Comment.Comments {
			if i > 0 {
				content = append(content, &adf.Node{Type: "rule"}) // separator between comments
			}
			content = append(content, para(
				boldNode(cm.Author.DisplayName),
				textNode("  ·  "+shortDate(cm.Created)),
			))
			if len(cm.Body) > 0 {
				var s string
				if json.Unmarshal(cm.Body, &s) == nil {
					content = append(content, para(textNode(s)))
				} else {
					var body adf.Node
					if json.Unmarshal(cm.Body, &body) == nil {
						content = append(content, body.Content...)
					}
				}
			}
		}
	}

	return &adf.Node{Type: "doc", Content: content}
}
