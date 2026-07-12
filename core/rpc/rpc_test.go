package rpc

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strings"
	"testing"

	"conflira/core/api"
	"conflira/core/board"
	"conflira/core/ir"
)

// recTransport records the request and returns a canned response.
type recTransport struct {
	method, url string
	body        []byte
	resp        []byte
}

func (rt *recTransport) Do(method, url string, body []byte, auth api.Auth) (int, []byte, error) {
	rt.method, rt.url, rt.body = method, url, body
	return 200, rt.resp, nil
}

func clientWith(rt *recTransport) ClientFactory {
	return func(AuthParams) *api.Client {
		return &api.Client{BaseURL: "x", Transport: rt}
	}
}

func TestIssueTransitionsList(t *testing.T) {
	rt := &recTransport{resp: []byte(`{"transitions":[{"id":"31","name":"Finish","to":{"name":"Done"}}]}`)}
	s := NewServer()
	Register(s, nil, clientWith(rt))
	r := call(t, s, "issue.transitions", map[string]any{"auth": map[string]string{}, "key": "K-1"})
	if r.Error != nil {
		t.Fatal(r.Error)
	}
	var list []map[string]string
	remarshal(t, r.Result, &list)
	if len(list) != 1 || list[0]["id"] != "31" || list[0]["to"] != "Done" {
		t.Errorf("transitions: %v", list)
	}
	if !strings.Contains(rt.url, "/issue/K-1/transitions") {
		t.Errorf("url: %s", rt.url)
	}
}

func TestIssueTransitionApply(t *testing.T) {
	rt := &recTransport{resp: []byte(`{}`)}
	s := NewServer()
	Register(s, nil, clientWith(rt))
	r := call(t, s, "issue.transition", map[string]any{"auth": map[string]string{}, "key": "K-1", "transition_id": "31"})
	if r.Error != nil {
		t.Fatal(r.Error)
	}
	if rt.method != "POST" || !strings.Contains(rt.url, "/issue/K-1/transitions") {
		t.Errorf("req: %s %s", rt.method, rt.url)
	}
	if !strings.Contains(string(rt.body), `"transition":{"id":"31"}`) {
		t.Errorf("body: %s", rt.body)
	}
}

func TestIssueCommentBody(t *testing.T) {
	rt := &recTransport{resp: []byte(`{}`)}
	s := NewServer()
	Register(s, nil, clientWith(rt))
	r := call(t, s, "issue.comment", map[string]any{"auth": map[string]string{}, "key": "K-1", "text": "hi there"})
	if r.Error != nil {
		t.Fatal(r.Error)
	}
	if rt.method != "POST" || !strings.Contains(rt.url, "/issue/K-1/comment") {
		t.Errorf("req: %s %s", rt.method, rt.url)
	}
	if !strings.Contains(string(rt.body), `"text":"hi there"`) || !strings.Contains(string(rt.body), `"type":"doc"`) {
		t.Errorf("comment body: %s", rt.body)
	}
}

func TestIssueAssignDisabledWithoutClient(t *testing.T) {
	s := NewServer()
	Register(s, nil, nil) // no client factory
	r := call(t, s, "issue.transition", map[string]any{"key": "K-1"})
	if r.Error == nil {
		t.Error("issue actions should be disabled without a client factory")
	}
}

// call dispatches a method and returns the response.
func call(t *testing.T, s *Server, method string, params any) *Response {
	t.Helper()
	var raw json.RawMessage
	if params != nil {
		b, _ := json.Marshal(params)
		raw = b
	}
	return s.Dispatch(&Request{JSONRPC: "2.0", ID: json.RawMessage(`1`), Method: method, Params: raw})
}

func TestPingAndUnknown(t *testing.T) {
	s := NewServer()
	Register(s, nil, nil)

	if r := call(t, s, "ping", nil); r.Error != nil || r.Result != "pong" {
		t.Errorf("ping: %+v", r)
	}
	if r := call(t, s, "no.such", nil); r.Error == nil || r.Error.Code != -32601 {
		t.Errorf("unknown method should 404: %+v", r)
	}
}

func TestDeterministicMethods(t *testing.T) {
	s := NewServer()
	Register(s, nil, nil)

	// jql.main
	r := call(t, s, "jql.main", nil)
	var jm struct {
		JQL string `json:"jql"`
	}
	remarshal(t, r.Result, &jm)
	if !strings.HasPrefix(jm.JQL, "assignee = currentUser()") {
		t.Errorf("jql.main: %q", jm.JQL)
	}

	// render.adf → IR with a heading
	adfDoc := map[string]any{"type": "doc", "content": []any{
		map[string]any{"type": "heading", "attrs": map[string]any{"level": 2}, "content": []any{
			map[string]any{"type": "text", "text": "Hi"}}},
	}}
	r = call(t, s, "render.adf", adfDoc)
	if r.Error != nil {
		t.Fatalf("render.adf err: %v", r.Error)
	}
	var doc ir.ProjectionIR
	remarshal(t, r.Result, &doc)
	if len(doc.Lines) == 0 || doc.Lines[0] != "Hi" {
		t.Errorf("render.adf lines: %#v", doc.Lines)
	}

	// adf.toText
	r = call(t, s, "adf.toText", adfDoc)
	var txt struct {
		Text string `json:"text"`
	}
	remarshal(t, r.Result, &txt)
	if txt.Text != "## Hi" {
		t.Errorf("adf.toText: %q", txt.Text)
	}
}

// board.fetch orchestrates search → parse → bubble → tree → sections, server-side.
func TestBoardFetch(t *testing.T) {
	fake := fakeFetcher{
		searches: map[string][]byte{
			"MAIN": searchResp(rawIssue("T-1", "Task", "To Do", "FEAT-1")),
			"REV":  searchResp(rawIssue("R-1", "Task", "In Progress", "")),
		},
		issues: map[string][]byte{
			"FEAT-1": rawIssue("FEAT-1", "Feature", "In Progress", ""),
		},
	}
	s := NewServer()
	Register(s, func(AuthParams) board.Fetcher { return fake }, nil)

	r := call(t, s, "board.fetch", map[string]any{
		"auth":     map[string]string{"url": "x", "email": "e", "token": "t"},
		"project":  "P",
		"group":    "none",
		"main_jql": "MAIN",
		"sections": []map[string]string{{"name": "Reviewing", "jql": "REV"}},
	})
	if r.Error != nil {
		t.Fatalf("board.fetch err: %v", r.Error)
	}
	var doc ir.ProjectionIR
	remarshal(t, r.Result, &doc)

	joined := strings.Join(doc.Lines, "\n")
	for _, want := range []string{"FEAT-1", "T-1", "Reviewing", "R-1"} {
		if !strings.Contains(joined, want) {
			t.Errorf("board IR missing %q\n%s", want, joined)
		}
	}
	// FEAT-1 (bubbled parent) should be a root with T-1 nested under it.
	if !strings.Contains(joined, "FEAT-1") || !strings.Contains(joined, "T-1") {
		t.Errorf("bubble/tree failed:\n%s", joined)
	}
}

// board.open resolves fields, senses the Reviewer section, builds queries, and
// renders — the thin-client entry point.
func TestBoardOpen(t *testing.T) {
	fieldsJSON, _ := json.Marshal([]map[string]any{
		{"id": "customfield_1", "name": "Reviewer", "custom": true,
			"schema": map[string]string{"type": "user", "custom": "x:userpicker"}},
	})
	f := openFake{
		fields: fieldsJSON,
		main:   searchResp(rawIssue("A-1", "Task", "To Do", "")),
		// R-1 isn't assigned to me, but the Reviewer field (customfield_1) names
		// me — only discoverable by value, not JQL.
		discovery: searchResp(rawIssueWithField("R-1", "Task", "In Progress", "customfield_1", "ME")),
	}
	s := NewServer()
	Register(s, func(AuthParams) board.Fetcher { return f }, nil)

	r := call(t, s, "board.open", map[string]any{
		"auth": map[string]string{"url": "x"}, "group": "none", "done_filter": "none",
	})
	if r.Error != nil {
		t.Fatalf("board.open err: %v", r.Error)
	}
	var res struct {
		IR       ir.ProjectionIR   `json:"ir"`
		LineKeys map[string]string `json:"line_keys"`
	}
	remarshal(t, r.Result, &res)
	joined := strings.Join(res.IR.Lines, "\n")
	// Merged board: both issues on one board (no separate "Reviewing" section).
	for _, want := range []string{"A-1", "R-1"} {
		if !strings.Contains(joined, want) {
			t.Errorf("board.open IR missing %q\n%s", want, joined)
		}
	}
	if strings.Contains(joined, "Reviewing") {
		t.Errorf("merged board should have no section header, got:\n%s", joined)
	}
	// Involvement icons (default Unicode set): A-1 assigned (★), R-1 review (✓).
	icons := func(key string) string {
		var s string // concat ALL inline marks on the issue's line (type icon + involvement)
		for _, m := range res.IR.Marks {
			if m.Kind == "inline_text" && res.LineKeys[fmt.Sprint(m.Line)] == key {
				for _, ch := range m.Chunks {
					if len(ch) > 0 {
						s += ch[0]
					}
				}
			}
		}
		return s
	}
	if got := icons("A-1"); !strings.Contains(got, board.InvolvementIconsUnicode["assigned"]) {
		t.Errorf("A-1 missing assigned icon, inline=%q", got)
	}
	if got := icons("R-1"); !strings.Contains(got, board.InvolvementIconsUnicode["review"]) {
		t.Errorf("R-1 missing review icon, inline=%q", got)
	}
	// line_keys must resolve at least the A-1 and R-1 rows.
	keys := map[string]bool{}
	for _, k := range res.LineKeys {
		keys[k] = true
	}
	if !keys["A-1"] || !keys["R-1"] {
		t.Errorf("line_keys missing issue rows: %v", res.LineKeys)
	}
}

type openFake struct{ fields, main, discovery []byte }

func (o openFake) GetFields() ([]byte, error)      { return o.fields, nil }
func (o openFake) GetIssue(string) ([]byte, error) { return []byte(`{}`), nil }
func (o openFake) GetMyself() ([]byte, error)      { return []byte(`{"accountId":"ME"}`), nil }
func (o openFake) RequestFields([]string)          {}
func (o openFake) Search(jql string) ([]byte, error) {
	switch {
	case strings.Contains(jql, "assignee = currentUser()"):
		return o.main, nil
	case strings.Contains(jql, "updated >="): // bounded discovery scan
		return o.discovery, nil
	default: // reporter / watcher — no matches in this fixture
		return searchResp(), nil
	}
}

// rawIssueWithField is a raw issue carrying one people-type custom field value.
func rawIssueWithField(key, typ, status, fieldID, accountID string) []byte {
	m := map[string]any{
		"key": key,
		"fields": map[string]any{
			"summary":   key + " summary",
			"issuetype": map[string]string{"name": typ},
			"status":    map[string]string{"name": status},
			fieldID:     []map[string]string{{"accountId": accountID}},
		},
	}
	b, _ := json.Marshal(m)
	return b
}

func TestServeRoundTrip(t *testing.T) {
	s := NewServer()
	Register(s, nil, nil)
	in := strings.NewReader(`{"jsonrpc":"2.0","id":7,"method":"ping"}` + "\n" +
		`{"jsonrpc":"2.0","method":"ping"}` + "\n") // 2nd is a notification
	var out bytes.Buffer
	if err := s.Serve(in, &out); err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(out.String()), "\n")
	if len(lines) != 1 {
		t.Fatalf("expected 1 response (notification suppressed), got %d: %q", len(lines), out.String())
	}
	if !strings.Contains(lines[0], `"result":"pong"`) || !strings.Contains(lines[0], `"id":7`) {
		t.Errorf("response: %s", lines[0])
	}
}

// --- helpers ---

func remarshal(t *testing.T, v any, out any) {
	t.Helper()
	b, _ := json.Marshal(v)
	if err := json.Unmarshal(b, out); err != nil {
		t.Fatal(err)
	}
}

type fakeFetcher struct {
	searches map[string][]byte
	issues   map[string][]byte
}

func (f fakeFetcher) Search(jql string) ([]byte, error) { return f.searches[jql], nil }
func (f fakeFetcher) GetIssue(key string) ([]byte, error) {
	if b, ok := f.issues[key]; ok {
		return b, nil
	}
	return []byte(`{}`), nil
}

func rawIssue(key, typ, status, parent string) []byte {
	m := map[string]any{
		"key": key,
		"fields": map[string]any{
			"summary":   key + " summary",
			"issuetype": map[string]string{"name": typ},
			"status":    map[string]string{"name": status},
		},
	}
	if parent != "" {
		m["fields"].(map[string]any)["parent"] = map[string]string{"key": parent}
	}
	b, _ := json.Marshal(m)
	return b
}

func searchResp(issues ...[]byte) []byte {
	parts := make([]json.RawMessage, len(issues))
	for i, is := range issues {
		parts[i] = is
	}
	b, _ := json.Marshal(map[string]any{"issues": parts})
	return b
}
