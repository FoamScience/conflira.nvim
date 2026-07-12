// Package queue ports the offline edit queue (jira-interface/queue.lua): a
// JSON-file-backed list of pending writes (transition/update/comment/create)
// replayed on sync. The on-disk format is identical to the Lua plugin's, so the
// Go core and the Neovim plugin can share the same queue.json.
package queue

import (
	"encoding/json"
	"fmt"
	"os"
)

// Edit is one queued operation. Data's shape depends on Type.
type Edit struct {
	ID          string          `json:"id"`
	Type        string          `json:"type"` // update | transition | comment | create
	IssueKey    string          `json:"issue_key,omitempty"`
	Data        json.RawMessage `json:"data"`
	Timestamp   int64           `json:"timestamp"`
	Description string          `json:"description"`
}

// Queue is a file-backed edit queue.
type Queue struct {
	Path string
	// Now/Rand back generate_id; injectable for deterministic tests.
	Now  func() int64
	Rand func() int64

	edits  []Edit
	loaded bool
}

// New creates a queue backed by path.
func New(path string) *Queue {
	return &Queue{Path: path}
}

func (q *Queue) now() int64 {
	if q.Now != nil {
		return q.Now()
	}
	return 0
}

func (q *Queue) rand() int64 {
	if q.Rand != nil {
		return q.Rand()
	}
	return 0
}

// Load reads the queue file (empty if absent).
func (q *Queue) Load() error {
	if q.loaded {
		return nil
	}
	q.loaded = true
	data, err := os.ReadFile(q.Path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	return json.Unmarshal(data, &q.edits)
}

func (q *Queue) save() error {
	data, err := json.Marshal(q.edits)
	if err != nil {
		return err
	}
	return os.WriteFile(q.Path, data, 0o644)
}

// Add stamps an id + timestamp, appends, and persists.
func (q *Queue) Add(e Edit) error {
	if err := q.Load(); err != nil {
		return err
	}
	e.ID = fmt.Sprintf("%d-%d", q.now(), q.rand())
	e.Timestamp = q.now()
	q.edits = append(q.edits, e)
	return q.save()
}

func marshal(v any) json.RawMessage {
	b, _ := json.Marshal(v)
	return b
}

// QueueTransition enqueues a workflow transition.
func (q *Queue) QueueTransition(issueKey, transitionID, transitionName string) error {
	return q.Add(Edit{
		Type:        "transition",
		IssueKey:    issueKey,
		Data:        marshal(map[string]string{"transition_id": transitionID}),
		Description: fmt.Sprintf("%s -> %s", issueKey, transitionName),
	})
}

// QueueUpdate enqueues a field update.
func (q *Queue) QueueUpdate(issueKey string, fields map[string]any, description string) error {
	return q.Add(Edit{
		Type:        "update",
		IssueKey:    issueKey,
		Data:        marshal(map[string]any{"fields": fields}),
		Description: description,
	})
}

// QueueComment enqueues a comment.
func (q *Queue) QueueComment(issueKey, bodyCSF string) error {
	return q.Add(Edit{
		Type:        "comment",
		IssueKey:    issueKey,
		Data:        marshal(map[string]string{"body_csf": bodyCSF}),
		Description: fmt.Sprintf("Comment on %s", issueKey),
	})
}

// QueueCreate enqueues an issue creation.
func (q *Queue) QueueCreate(project, issueType, summary, description, parentKey string) error {
	return q.Add(Edit{
		Type: "create",
		Data: marshal(map[string]any{
			"project": project, "issue_type": issueType, "summary": summary,
			"description": description, "parent_key": parentKey,
		}),
		Description: fmt.Sprintf("Create %s: %s", issueType, summary),
	})
}

// All returns the queued edits.
func (q *Queue) All() ([]Edit, error) {
	if err := q.Load(); err != nil {
		return nil, err
	}
	return q.edits, nil
}

// Count returns the number of queued edits.
func (q *Queue) Count() (int, error) {
	if err := q.Load(); err != nil {
		return 0, err
	}
	return len(q.edits), nil
}

// Remove deletes the edit with the given id and persists.
func (q *Queue) Remove(id string) error {
	if err := q.Load(); err != nil {
		return err
	}
	out := q.edits[:0]
	for _, e := range q.edits {
		if e.ID != id {
			out = append(out, e)
		}
	}
	q.edits = out
	return q.save()
}

// Clear empties the queue.
func (q *Queue) Clear() error {
	q.loaded = true
	q.edits = nil
	return q.save()
}
