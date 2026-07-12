package editor

import "fmt"

// Submitter writes an edited field back. Satisfied by *api.Client (EditIssue).
// Confluence (page update) lands with Phase 6.
type Submitter interface {
	EditIssue(key string, fields map[string]any) error
}

// Submit persists the session's ADF to the remote field. Jira only for now.
func Submit(s *Session, sub Submitter) error {
	m := s.Meta()
	switch m.Kind {
	case "jira", "":
		field := m.Field
		if field == "" {
			field = "description"
		}
		return sub.EditIssue(m.Key, map[string]any{field: s.doc.Root})
	default:
		return fmt.Errorf("submit not implemented for kind %q", m.Kind)
	}
}
