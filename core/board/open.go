package board

import (
	"encoding/json"
	"strings"

	"conflira/core/fields"
	"conflira/core/jql"
)

// FieldFetcher is a Fetcher that can also fetch field metadata and the current
// user, and request extra custom fields on its searches — needed to auto-sense
// involvement sections and detect Reviewer/Additional membership by value.
type FieldFetcher interface {
	Fetcher
	GetFields() ([]byte, error)
	GetMyself() ([]byte, error)
	RequestFields(ids []string) // include these custom fields in subsequent searches
}

// OpenOptions is the fully server-side board request: a thin client sends just
// this and renders the returned IR.
type OpenOptions struct {
	Project    string           `json:"project"`
	Group      string           `json:"group"`
	DoneFilter string           `json:"done_filter"`
	Icons      string           `json:"icons"`     // involvement icon style: "nerd" | "unicode"
	ScanDays   int              `json:"scan_days"` // discovery window for review/additional (0 → default 120)
	Sections   []fields.Section `json:"sections"`  // nil → fields.DefaultSections
}

// defaultScanDays bounds the discovery query for the non-JQL-searchable
// Reviewer/Additional fields.
const defaultScanDays = 120

// sectionKind maps a sensed involvement section to a relationship tag for the
// merged board: a "review"-matching section → "review", else "additional".
func sectionKind(sec fields.Section) string {
	for _, m := range sec.Match {
		if strings.Contains(strings.ToLower(m), "review") {
			return "review"
		}
	}
	return "additional"
}

// Open runs the entire board pipeline: fetch field metadata, auto-sense the
// involvement custom fields, build the relationship-tagged queries (assigned,
// reporter, watching, review, additional), and fetch/assemble ONE merged board
// where each issue carries icons for every relationship that matched.
func Open(f FieldFetcher, opts OpenOptions) (*State, error) {
	sections := opts.Sections
	if sections == nil {
		sections = fields.DefaultSections
	}

	var fieldList []fields.Field
	if raw, err := f.GetFields(); err == nil {
		_ = json.Unmarshal(raw, &fieldList)
	}
	sectionIDs := fields.SenseSections(fieldList, sections)

	// Split the sensed people fields into review vs additional. These fields
	// often have no JQL searcher, so we detect membership by VALUE, not JQL.
	var reviewIDs, additionalIDs []string
	for i, sec := range sections {
		if sectionKind(sec) == "review" {
			reviewIDs = append(reviewIDs, sectionIDs[i]...)
		} else {
			additionalIDs = append(additionalIDs, sectionIDs[i]...)
		}
	}
	people := append(append([]string{}, reviewIDs...), additionalIDs...)

	// Current account id, for value-based review/additional detection.
	myID := ""
	if raw, err := f.GetMyself(); err == nil {
		var me struct {
			AccountID string `json:"accountId"`
		}
		if json.Unmarshal(raw, &me) == nil {
			myID = me.AccountID
		}
	}
	// Request the people fields on every board search so their values are present.
	if len(people) > 0 {
		f.RequestFields(people)
	}

	// Native relationships (JQL-searchable).
	queries := []InvolvementQuery{
		{Kind: "assigned", JQL: jql.Main()},
		{Kind: "reporter", JQL: jql.Reporter()},
		{Kind: "watching", JQL: jql.Watching()},
	}
	// Discovery: review/additional fields aren't JQL-searchable, so scan a bounded
	// recent window and detect membership client-side from field values.
	scan := opts.ScanDays
	if scan == 0 {
		scan = defaultScanDays
	}
	if len(people) > 0 && myID != "" && scan > 0 {
		queries = append(queries, InvolvementQuery{Kind: "discovery", JQL: jql.RecentlyUpdated(scan)})
	}

	return Fetch(f, FetchOptions{
		Project:            opts.Project,
		Group:              opts.Group,
		DoneFilter:         opts.DoneFilter,
		Icons:              opts.Icons,
		Queries:            queries,
		MyAccountID:        myID,
		ReviewFieldIDs:     reviewIDs,
		AdditionalFieldIDs: additionalIDs,
	})
}
