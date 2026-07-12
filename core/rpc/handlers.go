package rpc

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"

	"conflira/core/adf"
	"conflira/core/api"
	"conflira/core/board"
	"conflira/core/editor"
	"conflira/core/fields"
	"conflira/core/ir"
	"conflira/core/jql"
	"conflira/core/render"
)

var safeName = regexp.MustCompile(`[^A-Za-z0-9._-]`)

// FetcherFactory builds a board.Fetcher from request auth (URL + credentials).
// The stdio binary uses a curl-backed client; tests inject a fake.
type FetcherFactory func(auth AuthParams) board.Fetcher

// ClientFactory builds an api.Client from request auth, for the issue action
// methods (transition/assign/comment). May be nil to disable them.
type ClientFactory func(auth AuthParams) *api.Client

// AuthParams are the per-request credentials.
type AuthParams struct {
	URL   string `json:"url"`
	Email string `json:"email"`
	Token string `json:"token"`
}

func unmarshal(params json.RawMessage, v any) error {
	if len(params) == 0 {
		return nil
	}
	return json.Unmarshal(params, v)
}

// Register binds every core method on the server. newFetcher (board fetch) and
// newClient (issue actions) may each be nil to disable their network methods.
func Register(s *Server, newFetcher FetcherFactory, newClient ClientFactory) {
	registerIssueActions(s, newClient)
	s.Register("ping", func(json.RawMessage) (any, error) {
		return "pong", nil
	})

	// render.adf: ADF document → Projection IR.
	s.Register("render.adf", func(p json.RawMessage) (any, error) {
		doc, err := adf.Decode(p)
		if err != nil {
			return nil, err
		}
		return render.Build(doc), nil
	})

	// render.board: board input → Projection IR.
	s.Register("render.board", func(p json.RawMessage) (any, error) {
		in, err := board.DecodeInput(p)
		if err != nil {
			return nil, err
		}
		return board.Build(board.BuildState(in)), nil
	})

	// adf.toText: ADF document → plain text.
	s.Register("adf.toText", func(p json.RawMessage) (any, error) {
		doc, err := adf.Decode(p)
		if err != nil {
			return nil, err
		}
		return map[string]string{"text": adf.ToText(doc)}, nil
	})

	// issue.parse: raw Jira issue → Issue.
	s.Register("issue.parse", func(p json.RawMessage) (any, error) {
		return board.ParseIssue(p)
	})

	// jql.main: the board's main (assigned) query.
	s.Register("jql.main", func(json.RawMessage) (any, error) {
		return map[string]string{"jql": jql.Main()}, nil
	})

	// jql.section: an involvement-section query for the given field IDs.
	s.Register("jql.section", func(p json.RawMessage) (any, error) {
		var args struct {
			FieldIDs []string `json:"field_ids"`
		}
		if err := unmarshal(p, &args); err != nil {
			return nil, err
		}
		return map[string]string{"jql": jql.InvolvementSection(args.FieldIDs)}, nil
	})

	// fields.resolve: /field response → resolved heading→IDs map.
	s.Register("fields.resolve", func(p json.RawMessage) (any, error) {
		var args struct {
			Fields     []fields.Field      `json:"fields"`
			Configured map[string][]string `json:"configured"`
			ACNames    []string            `json:"ac_names"`
		}
		if err := unmarshal(p, &args); err != nil {
			return nil, err
		}
		return fields.Resolve(args.Fields, args.Configured, args.ACNames), nil
	})

	// fields.senseSections: bucket user-valued fields into involvement sections.
	s.Register("fields.senseSections", func(p json.RawMessage) (any, error) {
		var args struct {
			Fields   []fields.Field   `json:"fields"`
			Sections []fields.Section `json:"sections"`
		}
		if err := unmarshal(p, &args); err != nil {
			return nil, err
		}
		if args.Sections == nil {
			args.Sections = fields.DefaultSections
		}
		return fields.SenseSections(args.Fields, args.Sections), nil
	})

	// board.open: the thin-client entry point — resolve fields, auto-sense
	// involvement sections, build queries, fetch, and render → Projection IR.
	s.Register("board.open", func(p json.RawMessage) (any, error) {
		if newFetcher == nil {
			return nil, fmt.Errorf("board.open unavailable: no fetcher configured")
		}
		var args struct {
			Auth AuthParams `json:"auth"`
			board.OpenOptions
		}
		if err := unmarshal(p, &args); err != nil {
			return nil, err
		}
		f, ok := newFetcher(args.Auth).(board.FieldFetcher)
		if !ok {
			return nil, fmt.Errorf("board.open: fetcher does not support field fetching")
		}
		st, err := board.Open(f, args.OpenOptions)
		if err != nil {
			return nil, err
		}
		doc, lineKeys := board.BuildWithKeys(st)
		return map[string]any{"ir": doc, "line_keys": lineKeys}, nil
	})

	// board.fetch: run the board pipeline from prebuilt queries → Projection IR.
	s.Register("board.fetch", func(p json.RawMessage) (any, error) {
		if newFetcher == nil {
			return nil, fmt.Errorf("board.fetch unavailable: no fetcher configured")
		}
		var args struct {
			Auth AuthParams `json:"auth"`
			board.FetchOptions
		}
		if err := unmarshal(p, &args); err != nil {
			return nil, err
		}
		st, err := board.Fetch(newFetcher(args.Auth), args.FetchOptions)
		if err != nil {
			return nil, err
		}
		return board.Build(st), nil
	})

	registerEditor(s, newFetcher, newClient)
}

// registerEditor binds the projection-editor session methods: open a session
// (ADF → IR + render-map), reconcile text edits, submit back to Jira, close.
func registerEditor(s *Server, newFetcher FetcherFactory, newClient ClientFactory) {
	store := editor.NewStore(32)

	// editor.open: {auth, key, field?} -> {session, ir} — fetch the field's ADF,
	// create a session, return the first editor IR (lines + marks + render-map).
	s.Register("editor.open", func(p json.RawMessage) (any, error) {
		if newFetcher == nil {
			return nil, fmt.Errorf("editor.open unavailable: no fetcher configured")
		}
		var a struct {
			Auth  AuthParams `json:"auth"`
			Key   string     `json:"key"`
			Field string     `json:"field"`
		}
		if err := unmarshal(p, &a); err != nil {
			return nil, err
		}
		doc, err := editor.OpenJira(newFetcher(a.Auth), a.Key, a.Field)
		if err != nil {
			return nil, err
		}
		sess := store.Open(doc)
		return map[string]any{"session": sess.ID, "ir": sess.IR(), "dirty": sess.Dirty()}, nil
	})

	// editor.applyText: {session, lines} -> {ir, dirty} — reconcile the full
	// edited buffer back into the ADF (text edits; same line count).
	s.Register("editor.applyText", func(p json.RawMessage) (any, error) {
		var a struct {
			Session string        `json:"session"`
			Lines   []string      `json:"lines"`
			Cursor  editor.Cursor `json:"cursor"`
		}
		if err := unmarshal(p, &a); err != nil {
			return nil, err
		}
		sess, ok := store.Get(a.Session)
		if !ok {
			return nil, fmt.Errorf("editor.applyText: unknown session %q", a.Session)
		}
		ir, cur, err := sess.ApplyText(a.Lines, a.Cursor)
		if err != nil {
			return nil, err
		}
		return map[string]any{"ir": ir, "cursor": cur, "dirty": sess.Dirty()}, nil
	})

	// editor.op: {session, op} -> {ir, cursor, dirty} — a structural edit
	// (split/merge/toggleTask/toggleMark).
	s.Register("editor.op", func(p json.RawMessage) (any, error) {
		var a struct {
			Session string    `json:"session"`
			Op      editor.Op `json:"op"`
		}
		if err := unmarshal(p, &a); err != nil {
			return nil, err
		}
		sess, ok := store.Get(a.Session)
		if !ok {
			return nil, fmt.Errorf("editor.op: unknown session %q", a.Session)
		}
		ir, cur, err := sess.Apply(a.Op)
		if err != nil {
			return nil, err
		}
		return map[string]any{"ir": ir, "cursor": cur, "dirty": sess.Dirty()}, nil
	})

	// editor.submit: {auth, session} -> {ok} — PUT the edited field back to Jira.
	s.Register("editor.submit", func(p json.RawMessage) (any, error) {
		if newClient == nil {
			return nil, fmt.Errorf("editor.submit unavailable: no client configured")
		}
		var a struct {
			Auth    AuthParams `json:"auth"`
			Session string     `json:"session"`
		}
		if err := unmarshal(p, &a); err != nil {
			return nil, err
		}
		sess, ok := store.Get(a.Session)
		if !ok {
			return nil, fmt.Errorf("editor.submit: unknown session %q", a.Session)
		}
		if err := editor.Submit(sess, newClient(a.Auth)); err != nil {
			return nil, err
		}
		return map[string]bool{"ok": true}, nil
	})

	// editor.close: {session} -> {ok}
	s.Register("editor.close", func(p json.RawMessage) (any, error) {
		var a struct {
			Session string `json:"session"`
		}
		if err := unmarshal(p, &a); err != nil {
			return nil, err
		}
		store.Close(a.Session)
		return map[string]bool{"ok": true}, nil
	})
}

// CurlFetcher is the default FetcherFactory: a curl-backed api.Client.
func CurlFetcher(auth AuthParams) board.Fetcher {
	return clientFetcher{c: CurlClient(auth), max: 500}
}

// CurlClient is the default ClientFactory: a curl-backed api.Client.
func CurlClient(auth AuthParams) *api.Client {
	return &api.Client{
		BaseURL:   auth.URL,
		Auth:      api.Auth{Email: auth.Email, Token: auth.Token},
		Transport: api.CurlTransport{},
	}
}

// registerIssueActions binds the issue mutation/query methods (transition,
// assign, comment). No-ops when newClient is nil.
func registerIssueActions(s *Server, newClient ClientFactory) {
	client := func(p json.RawMessage, dst any) (*api.Client, error) {
		if newClient == nil {
			return nil, fmt.Errorf("issue actions unavailable: no client configured")
		}
		if err := unmarshal(p, dst); err != nil {
			return nil, err
		}
		return nil, nil
	}

	// issue.transitions: {auth, key} -> [{id, name, to}]
	s.Register("issue.transitions", func(p json.RawMessage) (any, error) {
		var a struct {
			Auth AuthParams `json:"auth"`
			Key  string     `json:"key"`
		}
		if _, err := client(p, &a); err != nil {
			return nil, err
		}
		raw, err := newClient(a.Auth).GetTransitions(a.Key)
		if err != nil {
			return nil, err
		}
		var resp struct {
			Transitions []struct {
				ID   string `json:"id"`
				Name string `json:"name"`
				To   struct {
					Name string `json:"name"`
				} `json:"to"`
			} `json:"transitions"`
		}
		if err := json.Unmarshal(raw, &resp); err != nil {
			return nil, err
		}
		out := make([]map[string]string, 0, len(resp.Transitions))
		for _, t := range resp.Transitions {
			out = append(out, map[string]string{"id": t.ID, "name": t.Name, "to": t.To.Name})
		}
		return out, nil
	})

	// issue.transition: {auth, key, transition_id}
	s.Register("issue.transition", func(p json.RawMessage) (any, error) {
		var a struct {
			Auth         AuthParams `json:"auth"`
			Key          string     `json:"key"`
			TransitionID string     `json:"transition_id"`
		}
		if _, err := client(p, &a); err != nil {
			return nil, err
		}
		if err := newClient(a.Auth).DoTransition(a.Key, a.TransitionID); err != nil {
			return nil, err
		}
		return map[string]bool{"ok": true}, nil
	})

	// issue.assignable: {auth, project} -> [{account_id, display_name}]
	s.Register("issue.assignable", func(p json.RawMessage) (any, error) {
		var a struct {
			Auth    AuthParams `json:"auth"`
			Project string     `json:"project"`
		}
		if _, err := client(p, &a); err != nil {
			return nil, err
		}
		raw, err := newClient(a.Auth).AssignableUsers(a.Project)
		if err != nil {
			return nil, err
		}
		var users []struct {
			AccountID   string `json:"accountId"`
			DisplayName string `json:"displayName"`
		}
		if err := json.Unmarshal(raw, &users); err != nil {
			return nil, err
		}
		out := make([]map[string]string, 0, len(users))
		for _, u := range users {
			out = append(out, map[string]string{"account_id": u.AccountID, "display_name": u.DisplayName})
		}
		return out, nil
	})

	// issue.assign: {auth, key, account_id}
	s.Register("issue.assign", func(p json.RawMessage) (any, error) {
		var a struct {
			Auth      AuthParams `json:"auth"`
			Key       string     `json:"key"`
			AccountID string     `json:"account_id"`
		}
		if _, err := client(p, &a); err != nil {
			return nil, err
		}
		if err := newClient(a.Auth).Assign(a.Key, a.AccountID); err != nil {
			return nil, err
		}
		return map[string]bool{"ok": true}, nil
	})

	// issue.attachments: {auth, key} -> [{filename, mime, url}]
	s.Register("issue.attachments", func(p json.RawMessage) (any, error) {
		var a struct {
			Auth AuthParams `json:"auth"`
			Key  string     `json:"key"`
		}
		if _, err := client(p, &a); err != nil {
			return nil, err
		}
		raw, err := newClient(a.Auth).GetIssue(a.Key)
		if err != nil {
			return nil, err
		}
		var r struct {
			Fields struct {
				Attachment []struct {
					Filename string `json:"filename"`
					MimeType string `json:"mimeType"`
					Content  string `json:"content"`
				} `json:"attachment"`
			} `json:"fields"`
		}
		if err := json.Unmarshal(raw, &r); err != nil {
			return nil, err
		}
		out := make([]map[string]string, 0, len(r.Fields.Attachment))
		for _, at := range r.Fields.Attachment {
			out = append(out, map[string]string{"filename": at.Filename, "mime": at.MimeType, "url": at.Content})
		}
		return out, nil
	})

	// media.download: {auth, url, name} -> {path} — fetch a binary attachment to
	// a local cache file (so the editor can preview/open it).
	s.Register("media.download", func(p json.RawMessage) (any, error) {
		var a struct {
			Auth AuthParams `json:"auth"`
			URL  string     `json:"url"`
			Name string     `json:"name"`
		}
		if _, err := client(p, &a); err != nil {
			return nil, err
		}
		if a.URL == "" {
			return nil, fmt.Errorf("media.download: url required")
		}
		name := safeName.ReplaceAllString(a.Name, "_")
		if name == "" {
			name = "attachment"
		}
		dir := filepath.Join(os.TempDir(), "conflira")
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return nil, err
		}
		dest := filepath.Join(dir, name)
		if err := newClient(a.Auth).DownloadFile(a.URL, dest); err != nil {
			return nil, err
		}
		// PDFs aren't previewable in most editors — convert the first page to PNG.
		dest = api.MaybeConvertPDF(dest)
		w, h := api.ImageDims(dest)
		return map[string]any{"path": dest, "width": w, "height": h}, nil
	})

	// Cache resolved Acceptance Criteria field IDs per host (the /field response
	// rarely changes), so the issue view doesn't refetch /field every time.
	acCache := map[string][]string{}
	resolveAC := func(c *api.Client, url string) []string {
		if v, ok := acCache[url]; ok {
			return v
		}
		var ids []string
		if fraw, err := c.GetFields(); err == nil {
			var fl []fields.Field
			if json.Unmarshal(fraw, &fl) == nil {
				ids = fields.Resolve(fl, nil, nil)["Acceptance Criteria"]
			}
		}
		acCache[url] = ids
		return ids
	}

	// issue.view: {auth, key} -> {ir} — a read-only rendered issue view. Includes
	// the Acceptance Criteria field only when it's defined (never for epics).
	s.Register("issue.view", func(p json.RawMessage) (any, error) {
		var a struct {
			Auth AuthParams `json:"auth"`
			Key  string     `json:"key"`
		}
		if _, err := client(p, &a); err != nil {
			return nil, err
		}
		c := newClient(a.Auth)
		acIDs := resolveAC(c, a.Auth.URL)
		c.CustomFieldIDs = acIDs // so GetIssue requests the AC field
		raw, err := c.GetIssue(a.Key)
		if err != nil {
			return nil, err
		}
		return map[string]any{"ir": render.Build(board.IssueViewADF(raw, acIDs)), "key": a.Key}, nil
	})

	// issue.comment: {auth, key, text}
	s.Register("issue.comment", func(p json.RawMessage) (any, error) {
		var a struct {
			Auth AuthParams `json:"auth"`
			Key  string     `json:"key"`
			Text string     `json:"text"`
		}
		if _, err := client(p, &a); err != nil {
			return nil, err
		}
		if err := newClient(a.Auth).AddComment(a.Key, api.TextToADF(a.Text)); err != nil {
			return nil, err
		}
		return map[string]bool{"ok": true}, nil
	})
}

type clientFetcher struct {
	c   *api.Client
	max int
}

func (cf clientFetcher) Search(jqlStr string) ([]byte, error) {
	return cf.c.Search(jqlStr, "", cf.max)
}

func (cf clientFetcher) GetIssue(key string) ([]byte, error) {
	return cf.c.GetIssue(key)
}

func (cf clientFetcher) GetFields() ([]byte, error) {
	return cf.c.GetFields()
}

func (cf clientFetcher) GetMyself() ([]byte, error) {
	return cf.c.GetMyself()
}

func (cf clientFetcher) RequestFields(ids []string) {
	cf.c.CustomFieldIDs = ids
}

// Ensure board IR encodes (compile-time guard against ir drift).
var _ = ir.ProjectionIR{}
