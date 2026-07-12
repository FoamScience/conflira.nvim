// Package fields ports custom-field resolution (jira-interface/api.lua
// ensure_custom_fields_resolved): given a /field response and an (optional)
// configured heading→IDs map, it auto-discovers rich-text custom fields and the
// Acceptance Criteria field by name. Pure; verified against a captured fixture.
package fields

import "strings"

// Schema is the relevant subset of a Jira field schema.
type Schema struct {
	Type   string `json:"type"`
	Custom string `json:"custom"`
	System string `json:"system"`
}

// Field is one entry from the /field response.
type Field struct {
	ID     string `json:"id"`
	Name   string `json:"name"`
	Custom bool   `json:"custom"`
	Schema Schema `json:"schema"`
}

func isRichText(s Schema) bool {
	return s.Type == "doc" || strings.Contains(s.Custom, "textarea")
}

// isUserPicker matches user-valued custom fields: userpicker / multiuserpicker
// and the multi-user "people" type (Reviewer, Additional Assignees, …).
func isUserPicker(s Schema) bool {
	return s.Type == "user" ||
		strings.Contains(s.Custom, "userpicker") ||
		strings.Contains(s.Custom, "people")
}

// Section is a configurable board involvement section: a name and the match
// substrings tested (case-insensitive) against custom-field names. Mirrors
// config.lua board.involvement_sections.
type Section struct {
	Name  string   `json:"name"`
	Match []string `json:"match"`
}

// DefaultSections mirrors the config.lua board.involvement_sections default.
var DefaultSections = []Section{
	{Name: "Reviewing", Match: []string{"review"}},
	{Name: "Additional Assignees", Match: []string{"additional", "assignee"}},
}

// SenseSections buckets user-valued custom fields into the FIRST section whose
// match substrings appear in the field name (first-match-wins → sections are
// mutually exclusive). Returns field-ID lists aligned with sections.
func SenseSections(fieldList []Field, sections []Section) [][]string {
	out := make([][]string, len(sections))
	for i := range out {
		out[i] = []string{}
	}
	seen := map[string]bool{}
	for _, f := range fieldList {
		if !f.Custom || f.Name == "" || !isUserPicker(f.Schema) || seen[f.ID] {
			continue
		}
		n := strings.ToLower(f.Name)
		for i, sec := range sections {
			matched := false
			for _, m := range sec.Match {
				if strings.Contains(n, strings.ToLower(m)) {
					matched = true
					break
				}
			}
			if matched {
				seen[f.ID] = true
				out[i] = append(out[i], f.ID)
				break // first matching section wins
			}
		}
	}
	return out
}

// dedupeAppend appends ids not already in dst (preserving order).
func dedupeAppend(dst []string, ids ...string) []string {
	seen := map[string]bool{}
	for _, id := range dst {
		seen[id] = true
	}
	for _, id := range ids {
		if !seen[id] {
			seen[id] = true
			dst = append(dst, id)
		}
	}
	return dst
}

// Resolve maps section headings → candidate field IDs.
//   - configured empty → auto-discover every rich-text field by name.
//   - configured non-empty → resolve each configured heading, merging discovered IDs.
//
// In both cases the Acceptance Criteria field is discovered by name (any alias
// whose words all appear in the field name) and merged under "Acceptance Criteria".
// acNames defaults to {"acceptance criteria"} when nil/empty.
func Resolve(fieldList []Field, configured map[string][]string, acNames []string) map[string][]string {
	if len(acNames) == 0 {
		acNames = []string{"acceptance criteria"}
	}

	nameToIDs := map[string][]string{}
	for _, f := range fieldList {
		if f.Custom && f.Name != "" && isRichText(f.Schema) {
			nameToIDs[f.Name] = append(nameToIDs[f.Name], f.ID)
		}
	}

	result := map[string][]string{}
	if len(configured) == 0 {
		for name, ids := range nameToIDs {
			result[name] = append([]string{}, ids...)
		}
	} else {
		for heading, cfgIDs := range configured {
			if ids, ok := nameToIDs[heading]; ok {
				merged := append([]string{}, cfgIDs...)
				result[heading] = dedupeAppend(merged, ids...)
			} else {
				result[heading] = append([]string{}, cfgIDs...)
			}
		}
	}

	// Acceptance Criteria discovery by name.
	matches := func(name string) bool {
		for _, alias := range acNames {
			all := true
			for _, word := range strings.Fields(strings.ToLower(alias)) {
				if !strings.Contains(name, word) {
					all = false
					break
				}
			}
			if all {
				return true
			}
		}
		return false
	}
	var acIDs []string
	seen := map[string]bool{}
	for _, f := range fieldList {
		if f.Custom && f.Name != "" && matches(strings.ToLower(f.Name)) && !seen[f.ID] {
			seen[f.ID] = true
			acIDs = append(acIDs, f.ID)
		}
	}
	if len(acIDs) > 0 {
		result["Acceptance Criteria"] = dedupeAppend(append([]string{}, result["Acceptance Criteria"]...), acIDs...)
	}

	return result
}
