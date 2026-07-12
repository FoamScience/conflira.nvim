package editor

import (
	"encoding/json"

	"conflira/core/adf"
)

// IssueFetcher fetches an issue's raw JSON (satisfied by board.Fetcher / the
// api client). RequestFields, when present, lets us pull a custom ADF field that
// isn't in the default field set.
type IssueFetcher interface {
	GetIssue(key string) ([]byte, error)
}

// fieldRequester is the optional capability to include extra custom fields in
// the fetch (implemented by the curl fetcher's client).
type fieldRequester interface {
	RequestFields(ids []string)
}

// OpenJira builds an editing Doc for a Jira issue field. field defaults to
// "description"; a customfield_* id is requested explicitly when the fetcher
// supports it. An absent/empty field yields an empty doc (a blank editor).
func OpenJira(f IssueFetcher, key, field string) (*Doc, error) {
	if field == "" {
		field = "description"
	}
	if field != "description" {
		if fr, ok := f.(fieldRequester); ok {
			fr.RequestFields([]string{field})
		}
	}

	raw, err := f.GetIssue(key)
	if err != nil {
		return nil, err
	}

	var r struct {
		Fields map[string]json.RawMessage `json:"fields"`
	}
	_ = json.Unmarshal(raw, &r)

	root := &adf.Node{Type: "doc", Content: []*adf.Node{}}
	if fv := r.Fields[field]; len(fv) > 0 && string(fv) != "null" {
		if n, derr := adf.Decode(fv); derr == nil && n.Type == "doc" {
			root = n
		}
	}

	return &Doc{Root: root, Meta: Meta{Kind: "jira", Key: key, Field: field}}, nil
}
