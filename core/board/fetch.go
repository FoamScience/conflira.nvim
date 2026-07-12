package board

import (
	"encoding/json"
	"strings"
)

// Fetcher abstracts the REST calls the board orchestration needs. api.Client
// satisfies it via a thin adapter; tests inject a fake.
type Fetcher interface {
	Search(jql string) ([]byte, error)
	GetIssue(key string) ([]byte, error)
}

// SectionQuery is a named involvement-section query (Reviewing, …).
type SectionQuery struct {
	Name string `json:"name"`
	JQL  string `json:"jql"`
}

// InvolvementQuery is a relationship-tagged query for the merged board. Every
// issue a query returns is stamped with Kind (assigned/reporter/watching/review/
// additional); a single board is built from the union, each issue carrying the
// set of kinds that matched it.
type InvolvementQuery struct {
	Kind string `json:"kind"`
	JQL  string `json:"jql"`
}

// FetchOptions drives the board pipeline. Two modes:
//   - Queries set  → merged involvement board (icons per relationship).
//   - else         → legacy MainJQL + Sections (separate section groups).
type FetchOptions struct {
	Project    string             `json:"project"`
	Group      string             `json:"group"`
	DoneFilter string             `json:"done_filter"`
	Icons      string             `json:"icons"` // involvement icon style
	MainJQL    string             `json:"main_jql"`
	Sections   []SectionQuery     `json:"sections"`
	Queries    []InvolvementQuery `json:"queries"`
	// Value-based review/additional detection — for Reviewer/Additional fields
	// that aren't JQL-searchable. Membership is read from the field VALUES of
	// fetched issues, matching MyAccountID.
	MyAccountID        string   `json:"my_account_id"`
	ReviewFieldIDs     []string `json:"review_field_ids"`
	AdditionalFieldIDs []string `json:"additional_field_ids"`
}

// userInFields reports whether accountID appears in any of the given people-type
// custom fields of a raw issue (each value is a user object or an array of them).
func userInFields(raw json.RawMessage, fieldIDs []string, accountID string) bool {
	if accountID == "" || len(fieldIDs) == 0 {
		return false
	}
	var r struct {
		Fields map[string]json.RawMessage `json:"fields"`
	}
	if json.Unmarshal(raw, &r) != nil {
		return false
	}
	type user struct {
		AccountID string `json:"accountId"`
	}
	for _, id := range fieldIDs {
		v := r.Fields[id]
		if len(v) == 0 || string(v) == "null" {
			continue
		}
		var arr []user
		if json.Unmarshal(v, &arr) == nil {
			for _, u := range arr {
				if u.AccountID == accountID {
					return true
				}
			}
			continue
		}
		var one user
		if json.Unmarshal(v, &one) == nil && one.AccountID == accountID {
			return true
		}
	}
	return false
}

// lvl2 issue types — their parents are epics, which are not bubbled.
var lvl2Types = map[string]bool{"feature": true, "bug": true, "issue": true}

func parseIssues(raw []byte) []*Issue {
	var resp struct {
		Issues []json.RawMessage `json:"issues"`
	}
	if json.Unmarshal(raw, &resp) != nil {
		return nil
	}
	out := make([]*Issue, 0, len(resp.Issues))
	for _, r := range resp.Issues {
		if is, err := ParseIssue(r); err == nil {
			out = append(out, is)
		}
	}
	return out
}

// bubbleParents fetches parent issues missing from the set (context bubbling),
// stopping at level 1 (epics). Mirrors board/init.lua bubble_parents.
func bubbleParents(f Fetcher, issues []*Issue) []*Issue {
	byKey := map[string]bool{}
	for _, is := range issues {
		byKey[is.Key] = true
	}
	var missing []string
	seen := map[string]bool{}
	for _, is := range issues {
		if is.Parent != "" && !byKey[is.Parent] && !seen[is.Parent] {
			if !lvl2Types[strings.ToLower(is.Type)] { // lvl2's parent is an epic — skip
				seen[is.Parent] = true
				missing = append(missing, is.Parent)
			}
		}
	}
	if len(missing) == 0 {
		return issues
	}
	combined := append([]*Issue{}, issues...)
	for _, key := range missing {
		if raw, err := f.GetIssue(key); err == nil {
			if is, perr := ParseIssue(raw); perr == nil {
				combined = append(combined, is)
			}
		}
	}
	return bubbleParents(f, combined)
}

// Fetch runs the full board pipeline server-side: main query → tree → groups,
// plus each section query (deduped client-side against main and earlier
// sections), appended as trailing groups. Mirrors board/init.lua open+show.
func Fetch(f Fetcher, opts FetchOptions) (*State, error) {
	doneFilter := opts.DoneFilter
	if doneFilter == "" {
		doneFilter = "leaves"
	}

	// Merged involvement board: run each tagged query, union by key, stamp the
	// relationship kinds, build a single board. Native kinds (assigned/reporter/
	// watching) come from the query; review/additional are detected from field
	// VALUES (those fields aren't JQL-searchable). A "discovery" query only
	// contributes issues that match review/additional by value.
	if len(opts.Queries) > 0 {
		byKey := map[string]*Issue{}
		var order []*Issue
		for _, q := range opts.Queries {
			raw, err := f.Search(q.JQL)
			if err != nil {
				if q.Kind == "assigned" {
					return nil, err // the primary query failing is fatal
				}
				continue // a single involvement query failing just omits its icon
			}
			var resp struct {
				Issues []json.RawMessage `json:"issues"`
			}
			if json.Unmarshal(raw, &resp) != nil {
				continue
			}
			for _, r := range resp.Issues {
				is, perr := ParseIssue(r)
				if perr != nil {
					continue
				}
				review := userInFields(r, opts.ReviewFieldIDs, opts.MyAccountID)
				additional := userInFields(r, opts.AdditionalFieldIDs, opts.MyAccountID)
				// Discovery only surfaces reviewer/additional-only issues.
				if q.Kind == "discovery" && !review && !additional {
					continue
				}
				ex, ok := byKey[is.Key]
				if !ok {
					byKey[is.Key] = is
					order = append(order, is)
					ex = is
				}
				if q.Kind != "" && q.Kind != "discovery" {
					ex.AddInvolvement(q.Kind)
				}
				if review {
					ex.AddInvolvement("review")
				}
				if additional {
					ex.AddInvolvement("additional")
				}
			}
		}
		issues := bubbleParents(f, order)
		tree := FilterForDisplay(BuildTree(issues), doneFilter)
		st := &State{Issues: issues, Tree: tree, Project: opts.Project, Icons: opts.Icons}
		st.Groups = GroupNodes(tree, opts.Group)
		return st, nil
	}

	mainRaw, err := f.Search(opts.MainJQL)
	if err != nil {
		return nil, err
	}
	mainIssues := bubbleParents(f, parseIssues(mainRaw))
	tree := FilterForDisplay(BuildTree(mainIssues), doneFilter)

	st := &State{Issues: mainIssues, Tree: tree, Project: opts.Project, Icons: opts.Icons}
	st.Groups = GroupNodes(tree, opts.Group)

	seen := map[string]bool{}
	for _, is := range mainIssues {
		seen[is.Key] = true
	}
	for _, sec := range opts.Sections {
		raw, serr := f.Search(sec.JQL)
		if serr != nil {
			continue
		}
		var fresh []*Issue
		for _, is := range bubbleParents(f, parseIssues(raw)) {
			if !seen[is.Key] {
				fresh = append(fresh, is)
				seen[is.Key] = true
			}
		}
		if len(fresh) == 0 {
			continue
		}
		stree := FilterForDisplay(BuildTree(fresh), doneFilter)
		if len(stree) == 0 {
			continue
		}
		st.Groups = append(st.Groups, Group{Name: sec.Name, Nodes: stree})
	}

	return st, nil
}
